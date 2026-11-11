// SPDX-License-Identifier: LGPL-3.0-or-later

// The references screen of a project: the reference curves in its `reference-fit/` folder
// (the depositor's CRYSOL or FoXS fit, ...), which the comparison of a run draws with the
// measured curve and the fits. `^n` adds one from any table (a path prompt, then the
// import screen of the data screen in its reference mode), `^r` deletes the highlighted
// one after the destructive question. Nothing is listed from memory: the folder is read
// again at every key and when the screen regains the focus, so another copy's change shows.

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { readSystem } from "../core/environment.js"
import { pick } from "../core/file-system.js"
import { shortNumber, truncate } from "../core/terminal.js"
import { dataErrorNote, readDataInfo, unitLabel } from "../store/data.js"
import { loadSource } from "../store/data-table.js"
import { checkPath, MAX_PATH_TYPED, pathSuggestions } from "../store/lists.js"
import type { ProjectRef } from "../store/projects.js"
import {
    deleteReference,
    IMPORT_DATA_FIRST,
    listReferences,
    type ReferenceEntry,
} from "../store/references.js"
import { Frame } from "../ui/frame.js"
import { type LegendItem, legendBack, legendFor, legendOf, moveLegend } from "../ui/grid.js"
import { destructiveQuestion, PathPrompt, questionLegend, useConfirm } from "../ui/input.js"
import {
    type KeyInput,
    keys,
    scrollWindow,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { type Column, DataTable, Panel, useTheme } from "../ui/theme.js"
import { DataImportScreen } from "./data-import.js"

/** What the screen is doing: the list, a path prompt or the picker window. */
type Mode = "list" | "path" | "picking"

/** The file extensions the path prompt hints (a typed path may have any name). */
const hintedExtensions: ReadonlySet<string> = new Set([
    "dat", "txt", "csv", "tsv", "tab", "xlsx",
])

/** The names the path prompt completes: folders and the usual data files. */
const acceptedHint = (name: string): boolean =>
    hintedExtensions.has(name.slice(name.lastIndexOf(".") + 1).toLowerCase())

/** The suggestions of the path prompt. */
const suggestPaths = (text: string) => pathSuggestions(text, acceptedHint)

/** The note while the picker window is open. */
const PICKING_NOTE = "choose a file in the picker window..."

/** The rows the table spends besides its curves: header, rule and the position line. */
const TABLE_ROWS = 3

/** The width of the points column (its title is the widest text). */
const POINTS_WIDTH = 8

/**
 * The cells of one row of the list: the name, the points and the q range, or `unusable`
 * (its reason is the note of the highlighted row).
 */
export function referenceCells(entry: ReferenceEntry): [string, string, string] {
    if (entry.unusable !== undefined) return [entry.name, "unusable", ""]
    return [
        entry.name,
        String(entry.points),
        `${shortNumber(entry.qMin as number)} to ${shortNumber(entry.qMax as number)}`,
    ]
}

/**
 * The summary line of the data screen: `2 (name1, name2)` (the unusable files do not
 * count), cut to `width` cells.
 *
 * @returns the text, `undefined` when there are no references.
 */
export function referenceSummary(
    entries: readonly ReferenceEntry[],
    width: number,
): string | undefined {
    const usable = entries.filter((e) => e.unusable === undefined)
    if (entries.length === 0) return undefined
    const names = usable.map((e) => e.name).join(", ")
    const bad = entries.length - usable.length
    const text = `${usable.length}${names === "" ? "" : ` (${names})`}`
    return truncate(bad > 0 ? `${text}, ${bad} unusable` : text, width)
}

/**
 * The note of the highlighted entry when nothing else is to be said: why an unusable
 * file is skipped, with its file name.
 */
export function referenceNote(entry: ReferenceEntry | undefined): string | undefined {
    return entry?.unusable === undefined ? undefined : `${entry.file}: ${entry.unusable}`
}

/**
 * The references of a project: a table of the curves in `reference-fit/` (name, points, q
 * range in the project's units), an unusable file listed as `unusable` with its reason as
 * the note (the program never deletes or changes it). Keys: up and down move, `^n` adds
 * (a path or, with an empty field, `o` for the file picker; the import screen then reads
 * q, I(q) and an optional sigma), `^r` (or Delete) deletes the highlighted one after the
 * question, `^x` goes back.
 *
 * @param props - the project.
 * @returns the screen.
 */
export function ReferencesScreen({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const active = useScreenActive()
    const confirm = useConfirm()
    const [mode, setMode] = useState<Mode>("list")
    const [note, setNote] = useState<{ text: string; error: boolean } | undefined>()
    const [problem, setProblem] = useState<string | undefined>()
    const [typed, setTyped] = useState("")
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
    // the path prompt is remounted to empty its field
    const [fieldKey, setFieldKey] = useState(0)
    // bumped to read the folder again: after a change and at every key of the list
    const [version, setVersion] = useState(0)
    // the highlighted file is kept by NAME, so a folder that changes under it keeps it
    const [selected, setSelected] = useState<string | undefined>()
    const [offset, setOffset] = useState(0)
    const dir = project.dir
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const entries = useMemo(() => listReferences(dir), [dir, nav.depth, active, version])
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const status = useMemo(() => readDataInfo(dir), [dir, nav.depth, active, version])
    const units = status?.kind === "ok" ? unitLabel(status.info.units) : undefined
    const columns = useBodyColumns()
    const pageSize = useBodyRows(TABLE_ROWS)
    const at = Math.max(
        entries.findIndex((e) => e.file === selected),
        0,
    )
    const here = entries[at]
    const top = scrollWindow(at, offset, pageSize, entries.length)

    const say = useCallback((text: string, error = false) => setNote({ text, error }), [])
    const refresh = useCallback(() => setVersion((v) => v + 1), [])
    const resetField = useCallback(() => {
        setTyped("")
        setFieldKey((k) => k + 1)
    }, [])
    const toList = useCallback(() => {
        setMode("list")
        setProblem(undefined)
    }, [])

    /** Moves the highlight to a row, keeping the window around it. */
    const step = (to: number): void => {
        const entry = entries[Math.min(Math.max(to, 0), entries.length - 1)]
        if (entry !== undefined) setSelected(entry.file)
        setOffset(top)
    }

    /**
     * Reads a file and opens the import screen on it in the reference mode.
     *
     * @returns what is wrong (nothing was changed), `undefined` on success.
     */
    const load = (path: string): string | undefined => {
        const bad = checkPath(path, 42)
        if (bad !== undefined) return bad
        try {
            if (readDataInfo(dir)?.kind !== "ok") return IMPORT_DATA_FIRST
            nav.push(
                <DataImportScreen
                    project={project}
                    path={path}
                    source={loadSource(path)}
                    reference
                    onDone={(points, dropped, name, warning) => {
                        // the table counts the points a run draws (I above 0)
                        const found = listReferences(dir).find((e) => e.name === name)
                        const drawn = found?.points
                        const count =
                            drawn === undefined || drawn === points
                                ? `${points} points`
                                : `${points} rows, ${drawn} drawn`
                        const extra = dropped > 0 ? `, dropped ${dropped}` : ""
                        // a warning (it may be the wrong file) is the one thing said
                        say(
                            warning === undefined
                                ? `added ${name}: ${count}${extra}`
                                : `added ${truncate(String(name), 16)}: ${warning}`,
                        )
                        if (name !== undefined) setSelected(`${name}.tsv`)
                        refresh()
                    }}
                />,
            )
            return undefined
        } catch (error) {
            return dataErrorNote(error)
        }
    }

    const submitPath = (text: string) => {
        const bad = load(text.trim()) // a typed or pasted path may end in blanks
        if (bad !== undefined) return setProblem(bad)
        resetField()
        toList()
    }

    const pickFile = async () => {
        setMode("picking")
        const result = await pick(readSystem(), readSystem().home, "data")
        if ("problem" in result) say(result.problem, true)
        else if (result.files[0] !== undefined) {
            const bad = load(result.files[0])
            if (bad !== undefined) say(bad, true)
            else {
                resetField()
                return toList()
            }
        } else say("nothing was picked")
        resetField()
        setMode("path")
    }

    /** `^n`: a path prompt, once the project has data. */
    const add = () => {
        if (readDataInfo(dir)?.kind !== "ok") return say(IMPORT_DATA_FIRST, true)
        setProblem(undefined)
        resetField()
        setMode("path")
    }

    /** `^r`: asks, and on Enter deletes the file that was highlighted when asked. */
    const askDelete = (entry: ReferenceEntry) =>
        confirm.ask(destructiveQuestion(`reference ${entry.name}`), () => {
            try {
                say(
                    deleteReference(dir, entry.file)
                        ? "reference deleted"
                        : `${entry.file} is already gone`,
                )
            } catch (error) {
                say(dataErrorNote(error), true)
            }
            refresh()
        })

    useKeys((press: KeyInput) => {
        if (confirm.handleKey(press)) return
        setNote(undefined)
        refresh()
        if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.up)) step(at - 1)
        else if (press.is(keys.down)) step(at + 1)
        else if (press.is(keys.addReference)) add()
        else if ((press.is(keys.remove) || press.is(keys.delete)) && here !== undefined)
            askDelete(here)
    }, mode === "list")

    // the path prompt's hotkey acts only while the field is empty
    useKeys((press: KeyInput) => {
        if (typed === "" && press.is(keys.pickFiles)) void pickFile()
    }, mode === "path")

    const onChange = useCallback((text: string) => {
        setTyped(text)
        setProblem(undefined)
        setNote(undefined)
    }, [])

    const legend: LegendItem[] = confirm.question
        ? questionLegend(confirm.question)
        : mode === "path"
            ? legendOf([
                typed === "" && legendFor("pick file", keys.pickFiles),
                ...promptKeys,
            ])
            : mode === "picking"
                ? []
                : legendOf([
                    legendBack,
                    legendFor("add", keys.addReference),
                    here !== undefined && legendFor("delete", keys.remove),
                    moveLegend({ up: at > 0, down: at < entries.length - 1 }),
                ])
    const shown =
        confirm.note !== undefined
            ? { text: confirm.note, error: false }
            : mode === "picking"
                ? { text: PICKING_NOTE, error: false }
                : (note ??
                    (referenceNote(here) === undefined
                        ? undefined
                        : { text: referenceNote(here) as string, error: false }))

    const table: Column<ReferenceEntry>[] = [
        { title: "name", text: (e) => referenceCells(e)[0] },
        {
            title: "points",
            width: POINTS_WIDTH,
            align: "right",
            text: (e) => referenceCells(e)[1],
        },
        {
            title: `q range${units === undefined ? "" : ` (${units})`}`,
            text: (e) => referenceCells(e)[2],
        },
    ]
    return (
        <Frame
            title="reference fit"
            subtitle={project.id}
            legend={legend}
            note={shown?.text}
            noteIsError={shown?.error}
        >
            {mode === "path" ? (
                <Box marginTop={1}>
                    <PathPrompt
                        key={fieldKey}
                        maxLength={MAX_PATH_TYPED}
                        placeholder="any table: .dat, .csv, .tsv, .txt, .xlsx, ..."
                        suggest={suggestPaths}
                        error={problem}
                        onSubmit={submitPath}
                        onCancel={() => {
                            resetField()
                            toList()
                        }}
                        onBack={nav.pop}
                        onChange={onChange}
                        take="open"
                        canTake={typed !== ""}
                        cancel="close"
                        onLegend={setPromptKeys}
                    />
                </Box>
            ) : (
                <Panel paddingX={1} flexDirection="column">
                    {entries.length === 0 ? (
                        <Text color={theme.mt}>
                            {`no reference fit yet (add: ${keys.addReference.label})`}
                        </Text>
                    ) : (
                        <DataTable
                            columns={table}
                            rows={entries}
                            cursor={at}
                            offset={top}
                            pageSize={pageSize}
                            mark={(e) => (e.unusable === undefined ? " " : "!")}
                            width={columns - 4}
                        />
                    )}
                </Panel>
            )}
        </Frame>
    )
}
