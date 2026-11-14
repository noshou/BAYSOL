// SPDX-License-Identifier: LGPL-3.0-or-later

// The data screen of a project: the files of its measured curve and the way to its
// reference curves. The import screen it opens is in `data-import.tsx`.

import { existsSync } from "node:fs"
import { basename } from "node:path"
import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { DATA_EXTENSIONS } from "../core/file-system.js"
import {
    parseNumber,
    plainNumber,
    shortNumber,
    truncateStart,
} from "../core/terminal.js"
import {
    type DataMapping,
    type DataStatus,
    DEFAULT_ENERGY_UNIT,
    DEFAULT_UNITS,
    dataErrorNote,
    ENERGY_PROBLEM,
    type EnergyUnit,
    energyUnitLabel,
    nextEnergyUnit,
    readDataInfo,
    resetData,
    setEnergy,
    setEnergyUnit,
    setUnits,
    type Units,
    unitLabel,
    unitsList,
} from "../store/data.js"
import { loadSource, roleLabel, roles } from "../store/data-table.js"
import { checkPath, MAX_PATH_TYPED, pathSuggestions } from "../store/lists.js"
import type { ProjectRef } from "../store/projects.js"
import { listReferences } from "../store/references.js"
import { Frame } from "../ui/frame.js"
import {
    cursorMoves,
    type LegendItem,
    legendBack,
    legendEnter,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import {
    PathPrompt,
    Prompt,
    questionLegend,
    useConfirm,
    useNote,
} from "../ui/input.js"
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
import { PICKING_NOTE, usePathField, usePathPick } from "../ui/prompt-flows.js"
import { Panel, useTheme } from "../ui/theme.js"
import { DataImportScreen } from "./data-import.js"
import { ReferencesScreen, referenceSummary } from "./references-screen.js"

/** What the screen is doing: the options, a path prompt, the picker window, the tabs of
 * the units of q or a number prompt for the energy (the import itself is its own
 * screen). */
type Mode = "menu" | "path" | "picking" | "energy"

/** The options of the screen, in order. */
const options = [
    { id: "load", label: "load a file" },
    { id: "mapping", label: "change the columns" },
    { id: "units", label: "q units" },
    { id: "energy", label: "energy" },
    { id: "reference fit", label: "reference fit" },
] as const

/** What is said when the columns are to be changed and none were recorded. */
const NO_SOURCE = "no source recorded: load a file"

/** The options that work without data. */
const alwaysOn: ReadonlySet<string> = new Set(["load", "reference fit"])

/** The width of the name column of the summary (`reference fit` is the longest). */
const LINE_NAME_WIDTH = 13

/** What is said when `units`, `energy` or the columns come before a file. */
const LOAD_FIRST = "load a file first"

/** What is said when a file is to be loaded over data files that cannot be used. */
/** What `^k` says on a row that has no unit. */
const UNIT_ROWS = "^k changes the unit of q units or energy"

const RESET_FIRST = `data files are unusable: reset them first (${keys.reset.label})`

/** The file extensions the path prompt hints (a typed path may have any name). */
const hintedExtensions: ReadonlySet<string> = new Set(DATA_EXTENSIONS)

/** The names the path prompt completes: folders and the usual data files. */
const acceptedHint = (name: string): boolean =>
    hintedExtensions.has(name.slice(name.lastIndexOf(".") + 1).toLowerCase())

/** The suggestions of the path prompt. */
const suggestDataPaths = (text: string) => pathSuggestions(text, acceptedHint)


/** The energy for the summary: the number as typed and its unit label. */
export function energyText(energy: number | null, unit: EnergyUnit): string {
    return energy === null ? "not set" : `${plainNumber(energy)} ${energyUnitLabel(unit)}`
}

/**
 * The lines that describe the data of a project.
 *
 * @param status - what [[readDataInfo]] found.
 * @param width - the cells a value may use.
 * @returns `name  value` pairs: the points, the q range in the units, the source, how it
 *     was read (when `data.json` remembers) and the energy; empty when there is no usable
 *     data. The q units are the unit of the q range line.
 */
function describe(status: DataStatus | undefined, width: number): [string, string][] {
    if (status?.kind !== "ok") return []
    const { info } = status
    const unit = unitLabel(info.units)
    const { mapping } = info
    const rows: [string, string][] = [
        ["points", String(info.points)],
        ["q range", `${shortNumber(status.qMin)} to ${shortNumber(status.qMax)} ${unit}`],
        ["source", truncateStart(basename(mapping?.path ?? info.source), width)],
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
    rows.push(["energy", energyText(info.energy, info.energyUnit)])
    return rows
}

/**
 * The data of a project: the measured curve. A path prompt takes any delimited text file
 * or `.xlsx` workbook (the first sheet) and opens the import screen on it (options of
 * how the file is read, the three columns, a live preview), which writes a clean
 * `data.tsv` into the project (the file itself is never touched). `change the columns`
 * opens the import again on the stored source with the stored choices (`data.json`
 * remembers them; data without them says so, a source that is gone is one line).
 * Two more options work once a file is loaded: the units of q (Enter or `^k` turns
 * `nm⁻¹` and `Å⁻¹` and saves at once; `^k` on `energy` turns its unit label)
 * and the X-ray energy in eV (a number above 0; there is no default and the project is
 * not ready for a run without it). Both are saved at once, to `data.json` only.
 *
 * Data files that cannot be used are told and never written over; `x` puts them aside
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
    // the unit of the energy prompt and the text it starts with (`^k` changes both)
    const [energyUnit, setEnergyUnitNow] = useState<EnergyUnit>(DEFAULT_ENERGY_UNIT)
    const [energyStart, setEnergyStart] = useState("")
    const { note, say, clear } = useNote()
    const field = usePathField(clear)
    const {
        typed,
        problem,
        setProblem,
        promptKeys,
        setPromptKeys,
        fieldKey,
        resetField,
        onChange,
    } = field
    // bumped to read the files again: after a save and at every key of the menu
    const [version, setVersion] = useState(0)
    const dir = project.dir
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const status = useMemo(() => readDataInfo(dir), [dir, nav.depth, active, version])
    const cursor = useListCursor(options.length, options.length)
    const columns = useBodyColumns()
    const lines = describe(status, columns - 22)
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const references = useMemo(() => listReferences(dir), [dir, nav.depth, active, version])
    const usable = references.filter((e) => e.unusable === undefined).length
    const referencesText = referenceSummary(references, columns - 22)
    const loaded = status?.kind === "ok"
    const unusable = status?.kind === "unusable"

    const refresh = useCallback(() => setVersion((v) => v + 1), [])
    const toMenu = useCallback(() => {
        setMode("menu")
        setProblem(undefined)
    }, [setProblem])

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
        onDone: (points: number, dropped: number, _name?: string, warning?: string) => {
            // the source is on the summary rows; with rows dropped the note says how many;
            // a warning (it may be the wrong file) is the one thing said
            const loaded = `loaded ${points} points`
            if (warning !== undefined) say(`${loaded}. ${warning}`)
            else if (dropped > 0) say(`${loaded}, dropped ${dropped} rows (bad q or sigma)`)
            else say(`${loaded} from ${truncateStart(basename(path), 30)}`)
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

    const { submitPath, pickFile } = usePathPick({
        field,
        load,
        say,
        setMode,
        leave: toMenu,
    })

    const submitEnergy = (text: string) => {
        const parsed = parseNumber(text, { above: { limit: 0, message: ENERGY_PROBLEM } })
        if ("error" in parsed) return setProblem(parsed.error)
        try {
            setEnergy(dir, parsed.value, energyUnit)
            say(`energy ${plainNumber(parsed.value)} ${energyUnitLabel(energyUnit)} saved`)
            refresh()
            toMenu()
        } catch (error) {
            setProblem(dataErrorNote(error))
        }
    }

    /** Enter or `^k` on `units`: the other unit of q, saved at once. */
    const turnUnits = (current: Units) => {
        const next = unitsList.find((u) => u !== current) ?? DEFAULT_UNITS
        try {
            setUnits(dir, next)
            // a reference has no units of its own: it is read in the data's
            const also = listReferences(dir).length > 0 ? ", reference fit too" : ""
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
        if (id === "reference fit") return nav.push(<ReferencesScreen project={project} />)
        if (status?.kind !== "ok") return say(unusable ? RESET_FIRST : LOAD_FIRST, true)
        setProblem(undefined)
        if (id === "mapping") return reopen(status.info.mapping)
        if (id === "units") turnUnits(status.info.units)
        else {
            setEnergyUnitNow(status.info.energyUnit)
            const { energy } = status.info
            setEnergyStart(energy === null ? "" : plainNumber(energy))
            setMode("energy")
        }
    }

    /** `^k` on the menu: the unit of the row under the cursor, saved at once. */
    const turnUnit = () => {
        const id = options[cursor.index]?.id
        if (id !== "units" && id !== "energy") return say(UNIT_ROWS)
        if (status?.kind !== "ok") return say(unusable ? RESET_FIRST : LOAD_FIRST, true)
        if (id === "units") return turnUnits(status.info.units)
        if (status.info.energy === null) return say("set the energy first", true)
        const next = nextEnergyUnit(status.info.energyUnit)
        try {
            setEnergyUnit(dir, next)
            say(`energy shown in ${energyUnitLabel(next)}`)
        } catch (error) {
            say(dataErrorNote(error), true)
        }
        refresh()
    }

    // the menu: move, do, back, and reset for files that cannot be used
    useKeys((press: KeyInput) => {
        if (confirm.handleKey(press)) return
        clear()
        refresh()
        if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.units)) turnUnit()
        else if (press.is(keys.enter)) {
            const option = options[cursor.index]
            if (option) choose(option.id)
        } else if (unusable && press.is(keys.reset)) {
            confirm.ask(
                {
                    text: "reset the data files? old ones kept as .corrupt",
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

    // `^k` in the energy prompt: the next unit label; the typed text is kept
    useKeys((press: KeyInput) => {
        if (press.is(keys.units)) setEnergyUnitNow(nextEnergyUnit(energyUnit))
    }, mode === "energy")

    /** The keys that work now, for the mode the screen is in. */
    const legendNow = (): LegendItem[] => {
        if (confirm.question) return questionLegend(confirm.question)
        if (mode === "menu")
            return legendOf([
                legendBack,
                legendEnter,
                moveLegend(cursorMoves(cursor.index, options.length)),
                unusable && legendFor("reset files", keys.reset),
                (options[cursor.index]?.id === "units" ||
                    options[cursor.index]?.id === "energy") &&
                    legendFor("unit", keys.units),
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
    const shownNote = confirm.note ?? (mode === "picking" ? PICKING_NOTE : note?.text)
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
                                    {"reference fit".padEnd(LINE_NAME_WIDTH)}
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
                                    {o.id === "reference fit" && usable > 0
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
                    <PathPrompt
                        key={fieldKey}
                        maxLength={MAX_PATH_TYPED}
                        placeholder="any table: .dat, .fit, .csv, .tsv, .txt, .xlsx, ..."
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
                        label={`energy (${energyUnitLabel(energyUnit)}):`}
                        initial={energyStart}
                        maxLength={20}
                        placeholder={`X-ray energy in ${energyUnitLabel(energyUnit)}`}
                        extras={[legendFor("unit", keys.units)]}
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
