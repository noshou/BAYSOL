// SPDX-License-Identifier: LGPL-3.0-or-later

// The data screen of a project: the files of its measured curve and the way to its
// reference curves. The import screen it opens is in `data-import.tsx`.

import { existsSync } from "node:fs"
import { basename } from "node:path"
import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { readSystem } from "../core/environment.js"
import { pick } from "../core/file-system.js"
import {
    parseNumber,
    plainNumber,
    shortNumber,
    truncateStart,
} from "../core/terminal.js"
import {
    type DataMapping,
    type DataStatus,
    dataErrorNote,
    ENERGY_PROBLEM,
    loadSource,
    readDataInfo,
    resetData,
    roleLabel,
    roles,
    setEnergy,
    setUnits,
    type Units,
    unitLabel,
    unitsList,
} from "../store/data.js"
import { checkPath, MAX_PATH_TYPED, pathSuggestions } from "../store/lists.js"
import type { ProjectRef } from "../store/projects.js"
import { listReferences } from "../store/references.js"
import { Frame } from "../ui/frame.js"
import {
    type LegendItem,
    legendBack,
    legendEnter,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import { Prompt, questionLegend, useConfirm } from "../ui/input.js"
import {
    CursorList,
    type KeyInput,
    keys,
    ListText,
    useBodyColumns,
    useKeys,
    useListCursor,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { Panel, useTheme } from "../ui/theme.js"
import { DataImportScreen } from "./data-import.js"
import { ReferencesScreen, referenceSummary } from "./references-screen.js"

/** What the screen is doing: the options, a path prompt, the picker window or a number
 * prompt for the energy (the import itself is its own screen). */
type Mode = "menu" | "path" | "picking" | "energy"

/** The options of the screen, in order. */
const options = [
    { id: "load", label: "load a file" },
    { id: "mapping", label: "change the columns" },
    { id: "units", label: "units" },
    { id: "energy", label: "energy" },
    { id: "references", label: "references" },
] as const

/** What is said when the columns are to be changed and none were recorded. */
const NO_SOURCE = "no source recorded: load a file"

/** The options that work without data. */
const alwaysOn: ReadonlySet<string> = new Set(["load", "references"])

/** The width of the name column of the summary (`references` is the longest). */
const LINE_NAME_WIDTH = 11

/** What is said when `units`, `energy` or the columns come before a file. */
const LOAD_FIRST = "load a file first"

/** What is said when a file is to be loaded over data files that cannot be used. */
const RESET_FIRST = `data files are unusable: reset them first (${keys.reset.label})`

/** The file extensions the path prompt hints (a typed path may have any name). */
const hintedExtensions: ReadonlySet<string> = new Set([
    "dat", "txt", "csv", "tsv", "tab", "xlsx",
])

/** The names the path prompt completes: folders and the usual data files. */
const acceptedHint = (name: string): boolean =>
    hintedExtensions.has(name.slice(name.lastIndexOf(".") + 1).toLowerCase())

/** The suggestions of the path prompt. */
const suggestDataPaths = (text: string) => pathSuggestions(text, acceptedHint)

/** The note while the picker window is open. */
const pickingNote = "choose a file in the picker window..."


/**
 * The lines that describe the data of a project.
 *
 * @param status - what [[readDataInfo]] found.
 * @param width - the cells a value may use.
 * @returns `name  value` pairs: the points, the q range in the units, the source, how it
 *     was read (when `data.json` remembers), the units and the energy; empty when there
 *     is no usable data.
 */
function describe(status: DataStatus | undefined, width: number): [string, string][] {
    if (status?.kind !== "ok") return []
    const { info } = status
    const unit = unitLabel(info.units)
    const { mapping } = info
    const rows: [string, string][] = [
        ["points", String(info.points)],
        ["q range", `${shortNumber(status.qMin)} to ${shortNumber(status.qMax)} ${unit}`],
        ["source", truncateStart(mapping?.path ?? info.source, width)],
    ]
    if (mapping)
        rows.push(
            [
                "columns",
                roles.map((r) => `${roleLabel[r]}=${mapping.columns[r].spec}`).join(", "),
            ],
            [
                "read as",
                [
                    mapping.sheet === "" ? mapping.separator : `sheet ${mapping.sheet}`,
                    `skip ${mapping.skipRows}`,
                    `comments ${mapping.comments ? "on" : "off"}`,
                    `header ${mapping.header}`,
                ].join(", "),
            ],
        )
    rows.push(
        ["units", unit],
        ["energy", info.energy === null ? "not set" : `${shortNumber(info.energy)} eV`],
    )
    return rows
}

/**
 * The data of a project: the measured curve. A path prompt takes any delimited text file
 * or `.xlsx` workbook (the first sheet) and opens the import screen on it (options of
 * how the file is read, the three columns, a live preview), which writes a clean
 * `data.tsv` into the project (the file itself is never touched). `change the columns`
 * opens the import again on the stored source with the stored choices (`data.json`
 * remembers them; an old file without them says so, a source that is gone is one line).
 * Two more options work once a file is loaded: the units of q (Enter turns them
 * between `nm⁻¹` and `Å⁻¹`)
 * and the X-ray energy in eV (a number above 0; there is no default and the project is
 * not ready for a run without it). Both are saved at once, to `data.json` only.
 *
 * Data files that cannot be used are told and never written over; `r` puts them aside
 * as `.corrupt`. The screen reads the files again at every key and when it regains the
 * focus, so another copy's change shows, and every failure of a save (project gone,
 * file in use) is a line of text.
 *
 * Keys: up and down move, Enter does it, Esc closes a prompt, `^x` goes
 * back.
 *
 * @param props - the project.
 * @returns the screen.
 */
export function DataScreen({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const active = useScreenActive()
    const confirm = useConfirm()
    const [mode, setMode] = useState<Mode>("menu")
    const [note, setNote] = useState<{ text: string; error: boolean } | undefined>()
    const [problem, setProblem] = useState<string | undefined>()
    const [typed, setTyped] = useState("")
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
    // the path prompt is remounted to empty its field (see the models screen)
    const [fieldKey, setFieldKey] = useState(0)
    // bumped to read the files again: after a save and at every key of the menu
    const [version, setVersion] = useState(0)
    const dir = project.dir
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const status = useMemo(() => readDataInfo(dir), [dir, nav.depth, active, version])
    const cursor = useListCursor(options.length, options.length)
    const columns = useBodyColumns()
    const lines = describe(status, columns - 20)
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const references = useMemo(() => listReferences(dir), [dir, nav.depth, active, version])
    const usable = references.filter((e) => e.unusable === undefined).length
    const referencesText = referenceSummary(references, columns - 20)
    const loaded = status?.kind === "ok"
    const unusable = status?.kind === "unusable"

    const say = useCallback((text: string, error = false) => setNote({ text, error }), [])
    const refresh = useCallback(() => setVersion((v) => v + 1), [])
    const resetField = useCallback(() => {
        setTyped("")
        setFieldKey((k) => k + 1)
    }, [])
    const toMenu = useCallback(() => {
        setMode("menu")
        setProblem(undefined)
    }, [])

    /**
     * Reads a file and opens the import screen on it (the options, the columns, the
     * preview); the project's data changes only when that screen imports.
     *
     * @returns what is wrong with the file (nothing was changed), `undefined` on success.
     */
    const load = (path: string): string | undefined => {
        const bad = checkPath(path, 42)
        if (bad !== undefined) return bad
        try {
            if (readDataInfo(dir)?.kind === "unusable") return RESET_FIRST
            nav.push(<DataImportScreen {...importProps(path)} />)
            return undefined
        } catch (error) {
            return dataErrorNote(error)
        }
    }

    /** What the import screen is given: the file read now, and what to say afterwards. */
    const importProps = (path: string, initial?: DataMapping) => ({
        project,
        path,
        source: loadSource(path),
        initial,
        onDone: (points: number, dropped: number) => {
            const note = dropped > 0 ? `, dropped ${dropped} rows with q or sigma <= 0` : ""
            say(`loaded ${points} points from ${basename(path)}${note}`)
            refresh()
        },
    })

    /** Opens the import again on the stored source with the stored choices. */
    const reopen = (mapping: DataMapping | undefined) => {
        if (mapping === undefined) return say(NO_SOURCE, true)
        if (!existsSync(mapping.path))
            return say(`source is gone: ${basename(mapping.path)}`, true)
        try {
            nav.push(<DataImportScreen {...importProps(mapping.path, mapping)} />)
        } catch (error) {
            say(dataErrorNote(error), true)
        }
    }

    const submitPath = (text: string) => {
        const bad = load(text.trim()) // a typed or pasted path may end in blanks
        if (bad !== undefined) return setProblem(bad)
        resetField()
        toMenu()
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
                return toMenu()
            }
        } else say("nothing was picked")
        resetField()
        setMode("path")
    }

    const submitEnergy = (text: string) => {
        const parsed = parseNumber(text, { above: { limit: 0, message: ENERGY_PROBLEM } })
        if ("error" in parsed) return setProblem(parsed.error)
        try {
            setEnergy(dir, parsed.value)
            say(`energy ${shortNumber(parsed.value)} eV saved`)
            refresh()
            toMenu()
        } catch (error) {
            setProblem(dataErrorNote(error))
        }
    }

    /** Enter on `units` turns q between the two units and saves at once. */
    const flipUnits = (current: Units) => {
        const next = unitsList[(unitsList.indexOf(current) + 1) % unitsList.length] as Units
        try {
            setUnits(dir, next)
            // a reference has no units of its own: it is read in the data's
            const also = listReferences(dir).length > 0 ? ", references too" : ""
            say(`units ${unitLabel(next)} saved${also}`)
        } catch (error) {
            say(dataErrorNote(error), true)
        }
        refresh()
    }

    const choose = (id: (typeof options)[number]["id"]) => {
        if (id === "load") {
            if (unusable) return say(RESET_FIRST, true)
            setProblem(undefined)
            resetField()
            return setMode("path")
        }
        // the references list opens without data (only adding one needs it)
        if (id === "references") return nav.push(<ReferencesScreen project={project} />)
        if (status?.kind !== "ok") return say(unusable ? RESET_FIRST : LOAD_FIRST, true)
        setProblem(undefined)
        if (id === "mapping") return reopen(status.info.mapping)
        if (id === "units") flipUnits(status.info.units)
        else setMode("energy")
    }

    // the menu: move, do, back, and reset for files that cannot be used
    useKeys((press: KeyInput) => {
        if (confirm.handleKey(press)) return
        setNote(undefined)
        refresh()
        if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.enter)) {
            const option = options[cursor.index]
            if (option) choose(option.id)
        } else if (unusable && press.is(keys.reset)) {
            confirm.ask(
                {
                    text: "reset the data files? the old ones are kept as .corrupt",
                    yes: "reset",
                    no: "keep",
                },
                () => {
                    try {
                        resetData(dir)
                        say("data files put aside as .corrupt")
                    } catch (error) {
                        say(dataErrorNote(error), true)
                    }
                    refresh()
                },
            )
        }
    }, mode === "menu")

    // the path prompt's hotkey acts only while the field is empty (an absolute path
    // starts with a slash, so it cannot be part of one)
    useKeys((press: KeyInput) => {
        if (typed === "" && press.is(keys.pickFiles)) void pickFile()
    }, mode === "path")

    const onChange = useCallback((text: string) => {
        setTyped(text)
        setProblem(undefined)
        setNote(undefined)
    }, [])

    /** The keys that work now, for the mode the screen is in. */
    const legendNow = (): LegendItem[] => {
        if (confirm.question) return questionLegend(confirm.question)
        if (mode === "menu")
            return legendOf([
                legendBack,
                legendEnter,
                moveLegend({
                    up: cursor.index > 0,
                    down: cursor.index < options.length - 1,
                }),
                unusable && legendFor("reset files", keys.reset),
            ])
        if (mode === "path")
            return legendOf([
                typed === "" && legendFor("pick file", keys.pickFiles),
                ...promptKeys,
            ])
        return mode === "energy" ? promptKeys : []
    }
    const legend = legendNow()

    // the line above the keys: a question, the picker's wait, or the last result
    const shownNote = confirm.note ?? (mode === "picking" ? pickingNote : note?.text)
    const noteIsError = !confirm.note && mode !== "picking" && note?.error
    return (
        <Frame
            title="data"
            subtitle={project.id}
            legend={legend}
            note={shownNote}
            noteIsError={noteIsError}
        >
            {mode === "path" ? null : (
                <>
                    <Panel paddingX={1} flexDirection="column">
                        {loaded ? (
                            lines.map(([name, value]) => (
                                <Box key={name} columnGap={1}>
                                    <Text color={theme.mt}>
                                        {name.padEnd(LINE_NAME_WIDTH)}
                                    </Text>
                                    <Text color={theme.fg}>{value}</Text>
                                </Box>
                            ))
                        ) : unusable ? (
                            <Text color={theme.er}>{status.message}</Text>
                        ) : (
                            <Text color={theme.mt}>no data yet</Text>
                        )}
                        {referencesText === undefined ? null : (
                            <Box columnGap={1}>
                                <Text color={theme.mt}>
                                    {"references".padEnd(LINE_NAME_WIDTH)}
                                </Text>
                                <Text color={theme.fg}>{referencesText}</Text>
                            </Box>
                        )}
                    </Panel>
                    <Box marginTop={1}>
                        <CursorList
                            items={options}
                            index={cursor.index}
                            offset={cursor.offset}
                            lines={options.length}
                            active={mode === "menu"}
                            row={(o, on) => (
                                <ListText on={on && (loaded || alwaysOn.has(o.id))}>
                                    {o.id === "references" && usable > 0
                                        ? `${o.label} (${usable})`
                                        : o.label}
                                </ListText>
                            )}
                        />
                    </Box>
                </>
            )}
            {mode === "path" ? (
                <Box marginTop={1}>
                    <Prompt
                        key={fieldKey}
                        label="path:"
                        maxLength={MAX_PATH_TYPED}
                        placeholder="any table: .dat, .csv, .tsv, .txt, .xlsx, ..."
                        suggest={suggestDataPaths}
                        error={problem}
                        onSubmit={submitPath}
                        onCancel={() => {
                            resetField()
                            toMenu()
                        }}
                        onBack={nav.pop}
                        onChange={onChange}
                        take="load"
                        canTake={typed !== ""}
                        cancel="close"
                        onLegend={setPromptKeys}
                    />
                </Box>
            ) : null}
            {mode === "energy" ? (
                <Box marginTop={1}>
                    <Prompt
                        label="energy (eV):"
                        initial={
                            status?.kind === "ok" && status.info.energy !== null
                                ? plainNumber(status.info.energy)
                                : ""
                        }
                        maxLength={20}
                        placeholder="X-ray energy in eV, above 0"
                        error={problem}
                        onSubmit={submitEnergy}
                        onCancel={toMenu}
                        onBack={nav.pop}
                        onChange={onChange}
                        take="save"
                        cancel="close"
                        onLegend={setPromptKeys}
                    />
                </Box>
            ) : null}
        </Frame>
    )
}
