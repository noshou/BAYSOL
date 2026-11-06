// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { pick } from "../core/file-picker.js"
import { readSystem } from "../core/system.js"
import { parseNumber, plainNumber } from "../core/text.js"
import {
    type DataStatus,
    DEFAULT_UNITS,
    dataErrorNote,
    ENERGY_PROBLEM,
    parseDataFile,
    readDataInfo,
    resetData,
    setEnergy,
    setUnits,
    type Units,
    unitLabel,
    unitsList,
    writeData,
} from "../store/data.js"
import { checkPath, MAX_PATH_TYPED, pathSuggestions } from "../store/path-input.js"
import type { ProjectRef } from "../store/scope.js"
import { ChoiceTabs } from "../ui/choice-tabs.js"
import { CursorList, ListText } from "../ui/cursor-list.js"
import { Frame } from "../ui/frame.js"
import { type KeyInput, keys } from "../ui/keys.js"
import {
    type LegendItem,
    legendBack,
    legendEnter,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/legend.js"
import { useNav, useScreenActive } from "../ui/nav.js"
import { Panel } from "../ui/panel.js"
import { Prompt } from "../ui/prompt.js"
import { useTheme } from "../ui/theme.js"
import { questionLegend, useConfirm } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"
import { useListCursor } from "../ui/use-list-cursor.js"

/** What the screen is doing: the options, a path prompt, the picker window, a choice of
 * units or a number prompt for the energy. */
type Mode = "menu" | "path" | "picking" | "units" | "energy"

/** The options of the screen, in order. */
const options = [
    { id: "load", label: "load a file" },
    { id: "units", label: "units" },
    { id: "energy", label: "energy" },
] as const

/** What is said when `units` or `energy` is chosen before a file is loaded. */
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
 * A number for the summary: five significant digits, no exponent for ordinary sizes.
 *
 * @param x - the number.
 * @returns the text.
 */
const short = (x: number): string => plainNumber(Number(x.toPrecision(5)))

/**
 * The lines that describe the data of a project.
 *
 * @param status - what [[readDataInfo]] found.
 * @returns `name  value` pairs: the points, the q range in the units, the source, the
 *     units and the energy; empty when there is no usable data.
 */
function describe(status: DataStatus | undefined): [string, string][] {
    if (status?.kind !== "ok") return []
    const { info } = status
    const unit = unitLabel(info.units)
    return [
        ["points", String(info.points)],
        ["q range", `${short(status.qMin)} to ${short(status.qMax)} ${unit}`],
        ["source", info.source],
        ["units", unit],
        ["energy", info.energy === null ? "not set" : `${short(info.energy)} eV`],
    ]
}

/**
 * The data of a project: the measured curve. A path prompt takes any delimited text file
 * or `.xlsx` workbook (the first sheet), checks it and COPIES it as a clean `data.tsv`
 * into the project at once (the file itself is never touched; a bad file shows its
 * message under the field and changes nothing). Two more options work once a file is
 * loaded: the units of q (`nm⁻¹` or `Å⁻¹`, tabs) and the X-ray energy in eV (a number
 * above 0; there is no default and the project is not ready for a run without it). Both
 * are saved at once, to `data.json` only.
 *
 * Data files that cannot be used are told and never written over; `r` puts them aside
 * as `.corrupt`. The screen reads the files again at every key and when it regains the
 * focus, so another copy's change shows, and every failure of a save (project gone,
 * file in use) is a line of text.
 *
 * Keys: up and down move, Enter does it, Esc closes a prompt or the units, `^x` goes
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
    const [unitsFocus, setUnitsFocus] = useState(0)
    // bumped to read the files again: after a save and at every key of the menu
    const [version, setVersion] = useState(0)
    const dir = project.dir
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const status = useMemo(() => readDataInfo(dir), [dir, nav.depth, active, version])
    const cursor = useListCursor(options.length, options.length)
    const lines = describe(status)
    const loaded = status?.kind === "ok"
    const currentUnits = status?.kind === "ok" ? status.info.units : DEFAULT_UNITS
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
     * Reads a file and, if it is a curve, writes it into the project.
     *
     * @returns what is wrong with the file (nothing was changed), `undefined` on success.
     */
    const load = (path: string): string | undefined => {
        const bad = checkPath(path, 42)
        if (bad !== undefined) return bad
        try {
            const current = readDataInfo(dir)
            if (current?.kind === "unusable") return RESET_FIRST
            const keep = current?.kind === "ok" ? current.info : undefined
            const data = parseDataFile(path)
            const units = keep?.units ?? DEFAULT_UNITS
            writeData(dir, data, path, units, keep?.energy ?? undefined)
            say(`loaded ${data.q.length} points from ${basename(path)}`)
            refresh()
            return undefined
        } catch (error) {
            return dataErrorNote(error)
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
        } else say("nothing was picked")
        resetField()
        setMode("path")
    }

    const submitEnergy = (text: string) => {
        const parsed = parseNumber(text, { above: { limit: 0, message: ENERGY_PROBLEM } })
        if ("error" in parsed) return setProblem(parsed.error)
        try {
            setEnergy(dir, parsed.value)
            say(`energy ${short(parsed.value)} eV saved`)
            refresh()
            toMenu()
        } catch (error) {
            setProblem(dataErrorNote(error))
        }
    }

    const chooseUnits = () => {
        const units: Units = unitsList[unitsFocus] ?? DEFAULT_UNITS
        try {
            setUnits(dir, units)
            say(`units ${unitLabel(units)} saved`)
        } catch (error) {
            say(dataErrorNote(error), true)
        }
        refresh()
        setMode("menu")
    }

    const choose = (id: (typeof options)[number]["id"]) => {
        if (id === "load") {
            if (unusable) return say(RESET_FIRST, true)
            setProblem(undefined)
            resetField()
            return setMode("path")
        }
        if (status?.kind !== "ok") return say(unusable ? RESET_FIRST : LOAD_FIRST, true)
        setProblem(undefined)
        if (id === "units") {
            setUnitsFocus(Math.max(0, unitsList.indexOf(status.info.units)))
            setMode("units")
        } else setMode("energy")
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

    // the units tabs: left, right and tab move, Enter saves, Esc closes
    useKeys((press: KeyInput) => {
        const last = unitsList.length - 1
        if (press.is(keys.left)) setUnitsFocus((f) => Math.max(0, f - 1))
        else if (press.is(keys.right)) setUnitsFocus((f) => Math.min(last, f + 1))
        else if (press.is(keys.tab)) setUnitsFocus((f) => (f >= last ? 0 : f + 1))
        else if (press.is(keys.enter)) chooseUnits()
        else if (press.is(keys.escape)) toMenu()
        else if (press.is(keys.back)) nav.pop()
    }, mode === "units")

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
        if (mode === "units")
            return [
                legendFor("choose", keys.enter),
                legendFor("move", [keys.left, keys.right]),
                legendFor("next", keys.tab),
                legendFor("close", keys.escape),
                legendBack,
            ]
        return mode === "energy" ? promptKeys : []
    }
    const legend = legendNow()

    /** The line above the keys: a question, the picker's wait, or the last result. */
    const noteNow = (): { text: string; error: boolean } | undefined => {
        if (confirm.note) return { text: confirm.note, error: false }
        if (mode === "picking") return { text: pickingNote, error: false }
        return note
    }
    const shownNote = noteNow()
    return (
        <Frame
            title="data"
            subtitle={project.id}
            legend={legend}
            note={shownNote?.text}
            noteIsError={shownNote?.error}
        >
            <Panel paddingX={1} flexDirection="column">
                {loaded ? (
                    lines.map(([name, value]) => (
                        <Box key={name} columnGap={1}>
                            <Text color={theme.mt}>{name.padEnd(8)}</Text>
                            <Text color={theme.fg}>{value}</Text>
                        </Box>
                    ))
                ) : unusable ? (
                    <Text color={theme.er}>{status.message}</Text>
                ) : (
                    <Text color={theme.mt}>no data yet</Text>
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
                        <ListText on={on && (o.id === "load" || loaded)}>
                            {o.label}
                        </ListText>
                    )}
                />
            </Box>
            {mode === "path" ? (
                <Box marginTop={1}>
                    <Prompt
                        key={fieldKey}
                        label="path:"
                        maxLength={MAX_PATH_TYPED}
                        placeholder="q | I(q) | σ (.csv, .xlsx, .dat, .tsv, ...)"
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
            {mode === "units" ? (
                <Box marginTop={1} columnGap={1}>
                    <Text color={theme.fg}>units:</Text>
                    <ChoiceTabs
                        options={unitsList.map(unitLabel)}
                        selected={new Set([unitLabel(currentUnits)])}
                        focus={unitsFocus}
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
