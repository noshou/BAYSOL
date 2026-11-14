// SPDX-License-Identifier: LGPL-3.0-or-later

// The solutes table of a buffer: the screen, the check of a draft against the loader's
// rules, and the add and edit flows that run under the table.
//
// Contents:
//   1. The check of a draft
//   2. `useSoluteFlow`: the add and edit flows drawn under the table
//   3. `SolutesTable`: the screen

import { basename } from "node:path"
import { isDeepStrictEqual } from "node:util"
import { Text } from "ink"
import {
    type ReactNode,
    useCallback,
    useEffect,
    useMemo,
    useReducer,
    useRef,
    useState,
} from "react"
import { appDir, RUN_FLOW, readSystem } from "../core/environment.js"
import { pick } from "../core/file-system.js"
import { formatNumber, parseNumber } from "../core/terminal.js"
import { AddFlow } from "../store/add-flow.js"
import {
    type AddEvent,
    type AddKind,
    basisNote,
    type DoneStep,
    type FlowStep,
    paramsCell,
    rowNote,
} from "../store/add-state.js"
import {
    type BufferRow,
    type Conditions,
    conditionLimits,
    rowProblem,
} from "../store/buffer.js"
import { type CustomEntry, customFile, readCustomSolutes } from "../store/custom.js"
import {
    isSequenceFile,
    isSequencePaste,
    pathSuggestions,
    type Row,
    rowValue,
} from "../store/lists.js"
import type { Note } from "../store/notes.js"
import { parseTemperature, TEMPERATURE_LABEL, temperatureStart } from "../store/run.js"
import {
    bufferRow,
    COLUMNS,
    type ConcUnit,
    concUnit,
    type EditField,
    firstDuplicate,
    firstProblem,
    formatConc,
    NO_MATCH,
    nextConcUnit,
    type RowProblem,
    rowOf,
    type Solute,
    soluteOf,
} from "../store/solutes.js"
import { cleanRow } from "../store/template-link.js"
import { Frame } from "../ui/frame.js"
import { type LegendItem, legendFor } from "../ui/grid.js"
import {
    DROPDOWN_CHROME,
    Dropdown,
    Entry,
    filterChoices,
    PathPrompt,
    PROMPT_ROWS,
    Prompt,
    questionLegend,
    type Suggestion,
    suggestionLines,
    useConfirm,
} from "../ui/input.js"
import { keyLabels, keys, scrollWindow, useKeys, useNav } from "../ui/interaction.js"
import { type Column, columnWidths, DataTable } from "../ui/theme.js"
import { useBufferTemplate } from "./buffer-template.js"
import { NotesList } from "./notes-list.js"
import {
    replaceBufferQuestion,
    type TableScreen,
    useTableScreen,
} from "./screen-rules.js"

// ========================================================================================
// 1. The check of a draft
// ========================================================================================

/** A row of a file as a draft, with its link to a buffer template checked. */
const draftFrom = (row: BufferRow): Solute => cleanRow(soluteOf(row))

/**
 * The loader's check of a draft, in the shape the table's `check` takes.
 *
 * @param s - the solute of the table.
 * @returns what the Julia loader would refuse in it, `undefined` when nothing.
 */
export const soluteProblem: RowProblem = (s) => rowProblem(bufferRow(s))

// ========================================================================================
// 2. The add and edit flows
// ========================================================================================

// The add and edit flows of the solutes table as a hook: the state machine of
// `store/add-flow.ts` (which knows what is asked and in what order) drawn with the kit
// under the table, and its result handed back to the table screen when it is done.
//
// While a flow is open the table shows the flow's own rows (the row being made is in them,
// with the cell being typed into showing what is typed), its cursor and a window that
// follows it; the screen's own keys are off and the prompt or dropdown below the table
// takes them. When the flow ends, what it changed is applied to the screen's drafts
// (`flowChanges`), so a cancelled add leaves no trace and an edit that was stopped keeps
// the cells already taken.

/**
 * The rows an open flow takes under the table: its label, the messages, the suggestions
 * (`suggestionLines`) and the status line.
 */
const FLOW_ROWS = suggestionLines + DROPDOWN_CHROME

/** The rows the box of the path prompt adds (its top and bottom border). */
const PATH_BOX_ROWS = 2

/** The fewest table rows left in view while a flow is open. */
const MIN_TABLE_ROWS = 3

/** The message when the custom solutes cannot be read: only built-in ones are offered. */
const customUnusable = (file: string) => `${file} unusable!`

/** What the path field says while nothing is typed. */
const PATH_PLACEHOLDER = "full path of a FASTA/FASTQ file, or the sequence itself"

/** The suggestions of the path prompt of a sequence file: folders and FASTA/FASTQ files. */
const suggestSequencePaths = (text: string) => pathSuggestions(text, isSequenceFile)

/** The note while the picker window is open. */
const PICKING_NOTE = "choose a file in the picker window..."

/** The legend item of the file picker, offered on an empty path field. */
const pickerLegend: LegendItem = legendFor("file picker", keys.pickFiles)

/**
 * The keys of an open step: what its entry reports (`move` only when the list has
 * several entries, `complete` only when one is highlighted, the file picker only on an
 * empty path field), except that a dropdown step that has nothing typed completes
 * nothing, so `tab` is dropped.
 *
 * @param step - what is drawn.
 * @param items - the legend its entry reported.
 * @returns the legend items.
 */
function flowLegend(step: FlowStep, items: LegendItem[]): LegendItem[] {
    const completes = step.type === "dropdown" && step.label !== "path"
    if (!completes || step.typed !== undefined) return items
    return items.filter((i) => i.keys !== keys.tab.label)
}

/**
 * What a screen takes from the hook.
 *
 * @property open - a flow is open (the screen's own keys are off).
 * @property rows - the rows to draw: the flow's while it is open, else the table's.
 * @property cursor - the row the cursor is on.
 * @property offset - the first row shown.
 * @property pageSize - how many rows are shown (fewer while a flow is open).
 * @property cell - the text the cell being typed into shows, `undefined` for none: the
 *     row and the field.
 * @property note - what the flow says, `undefined` for nothing.
 * @property legend - the keys of the open step, empty when closed.
 * @property entry - the prompt or dropdown to draw under the table, `null` when closed.
 * @property add - starts the flow of an add key.
 * @property edit - starts the edit of the row under the cursor.
 */
type SoluteFlow = {
    open: boolean
    rows: Row<Solute>[]
    cursor: number
    offset: number
    pageSize: number
    cell: { row: number; field: EditField; text: string } | undefined
    note: string | undefined
    legend: LegendItem[]
    entry: ReactNode
    add: (kind: AddKind) => void
    edit: () => void
}

/**
 * The flows of a table of solutes.
 *
 * @param t - the table screen the flows change (from `useTableScreen`).
 * @param root - the BAYSOL data folder, where the custom solutes are read from.
 * @returns what to draw and how to start a flow, see [[SoluteFlow]].
 */
function useSoluteFlow(t: TableScreen<Solute>, root: string = appDir()): SoluteFlow {
    // the flow is a mutable object: it lives in a ref and a counter redraws after it moves
    const tRef = useRef(t)
    tRef.current = t
    const run = useRef<AddFlow | undefined>(undefined)
    const [, redraw] = useReducer((n: number) => n + 1, 0)
    // a new key empties a prompt: its text is read once, when it opens
    const [fieldKey, setFieldKey] = useState(0)
    const [picking, setPicking] = useState(false)
    // the basis of the highlighted solute's molarity (`mM per monomer unit`)
    const [basis, setBasis] = useState<string | undefined>(undefined)
    // the keys the open step's entry reports
    const [stepKeys, setStepKeys] = useState<LegendItem[]>([])

    const finish = useCallback((done: DoneStep) => {
        const current = run.current
        run.current = undefined
        if (!current) return
        tRef.current.adopt(done.table, done.added.length > 0)
        redraw()
    }, [])

    const send = useCallback(
        (event: AddEvent) => {
            const current = run.current
            if (!current) return
            const step = current.send(event)
            if (step.type === "done") return finish(step)
            // what was taken moves on to a new field; a refused one keeps its text
            const advancing = event.type === "submit" || event.type === "pick"
            const accepted = advancing && !step.problem
            if (accepted || event.type === "files") setFieldKey((k) => k + 1)
            redraw()
        },
        [finish],
    )

    const begin = useCallback(
        (flow: AddFlow) => {
            if (flow.done) return
            run.current = flow
            setBasis(undefined)
            redraw()
        },
        [],
    )

    const add = useCallback(
        (kind: AddKind) => {
            let customs: CustomEntry[] = []
            let problem: string | undefined
            if (kind === "nonbio" || kind === "polymer") {
                try {
                    customs = readCustomSolutes(root)
                } catch {
                    problem = customUnusable(basename(customFile(root)))
                }
            }
            const table = tRef.current
            const cursor = table.cursor.index
            begin(AddFlow.add(table.drafts, kind, { customs, cursor, problem }))
        },
        [begin, root],
    )

    const edit = useCallback(() => {
        const table = tRef.current
        begin(AddFlow.edit(table.drafts, table.cursor.index))
    }, [begin])

    // the stable handlers the entries are given (a new one per render would make an
    // entry report its text again and again)
    const onText = useCallback((text: string) => send({ type: "text", text }), [send])
    const onSubmit = useCallback(() => send({ type: "submit" }), [send])
    const onCancel = useCallback(() => send({ type: "cancel" }), [send])
    const onHighlight = useCallback((s: (Suggestion & { value: number }) | undefined) => {
        const state = run.current?.state
        const entry = state?.kind === "name" && s ? state.matches[s.value] : undefined
        setBasis(basisNote(entry?.basis))
    }, [])

    const current = run.current
    const step = current?.step
    const typed = step?.type === "dropdown" ? step.typed : undefined
    const canPick = step?.type === "dropdown" && step.filePicker === true && typed === ""

    // `e` on an empty path field asks the desktop for a file; the field has the `e` by
    // then, so it is emptied and the picked path put in
    useKeys((press) => {
        if (!press.is(keys.pickFiles) || !current) return
        void (async () => {
            setPicking(true)
            const system = readSystem()
            const result = await pick(system, system.home, "sequence")
            if (run.current === current) {
                send({ type: "text", text: "" })
                send({ type: "files", result })
                setFieldKey((k) => k + 1)
            }
            setPicking(false)
        })()
    }, canPick && !picking)

    if (!current || !step || step.type === "done") {
        return {
            open: false,
            rows: t.rows,
            cursor: t.cursor.index,
            offset: t.cursor.offset,
            pageSize: t.pageSize,
            cell: undefined,
            note: undefined,
            legend: [],
            entry: null,
            add,
            edit,
        }
    }

    const rows = [...current.table.rows]
    const cursor = current.cursor
    const boxed = step.type === "dropdown" && step.label === "path" ? PATH_BOX_ROWS : 0
    const pageSize = Math.max(MIN_TABLE_ROWS, t.pageSize - FLOW_ROWS - boxed)
    const { row, column } = step.cell
    const key = (label: string) => `${row}:${column}:${label}:${fieldKey}`

    let entry: ReactNode
    let cell: SoluteFlow["cell"]
    let note: string | undefined
    if (step.type === "prompt") {
        const field = COLUMNS[step.cell.column] as EditField
        cell = { row: step.cell.row, field, text: step.shown }
        note = step.note
        entry = (
            <Prompt
                key={key(step.label)}
                label={`${step.label}:`}
                initial={step.typed}
                maxLength={step.maxLength}
                error={step.problem}
                onChange={onText}
                onSubmit={onSubmit}
                onCancel={onCancel}
                onLegend={setStepKeys}
            />
        )
    } else if (step.label === "name") {
        cell = { row: step.cell.row, field: "name", text: step.typed ?? "" }
        note = basis ?? step.note
        const choices = step.items.map((item, value) => ({
            label: item.text,
            tag: item.tag,
            value,
        }))
        entry = (
            <Entry<Suggestion & { value: number }>
                key={key("name")}
                label="name:"
                initial={step.typed}
                maxLength={step.maxLength}
                placeholder={step.status}
                suggest={() => choices}
                pick
                noMatch={NO_MATCH}
                error={step.problem}
                onChange={onText}
                onSubmit={(_text, s) => s && send({ type: "pick", index: s.value })}
                onCancel={onCancel}
                onHighlight={onHighlight}
                onLegend={setStepKeys}
            />
        )
    } else if (step.label === "path") {
        note = picking ? PICKING_NOTE : step.status
        entry = (
            <PathPrompt
                key={key("path")}
                initial={step.typed}
                maxLength={step.maxLength}
                placeholder={PATH_PLACEHOLDER}
                suggest={suggestSequencePaths}
                onPaste={(text, room) => {
                    if (!isSequencePaste(text, room)) return false
                    send({ type: "paste", text })
                    return true
                }}
                error={step.problem}
                active={!picking}
                extras={canPick ? [pickerLegend] : []}
                onLegend={setStepKeys}
                onChange={onText}
                onSubmit={onSubmit}
                onCancel={onCancel}
            />
        )
    } else {
        const choices = step.items.map((item, value) => ({ label: item.text, value }))
        entry = (
            <Dropdown<number>
                key={key(step.label)}
                label={`${step.label}:`}
                search={filterChoices(choices)}
                onPick={(index) => send({ type: "pick", index })}
                onCancel={onCancel}
                onLegend={setStepKeys}
            />
        )
    }

    return {
        open: true,
        rows,
        cursor,
        offset: scrollWindow(cursor, t.cursor.offset, pageSize, rows.length),
        pageSize,
        cell,
        note,
        legend: picking ? [] : flowLegend(step, stepKeys),
        entry,
        add,
        edit,
    }
}

// ========================================================================================
// 3. The solutes table
// ========================================================================================

/**
 * What the table of the buffer (or of one recipe) edits and where it saves.
 *
 * @property title - the screen's title: `buffer` when left out, a recipe's name.
 * @property subtitle - what it is about (the project), shown while nothing is unsaved.
 * @property items - the rows the buffer holds now, as the file has them.
 * @property draftRows - rows the table starts with as unsaved ones (a recipe loaded into
 *     the buffer): nothing of them is written before `^w`, which then replaces the target's
 *     rows with the rows of the table.
 * @property conditions - the pH and σ the buffer holds now, `undefined` for none yet.
 * @property draftConditions - a pH, σ and temperature the table starts with as an unsaved
 *     change (the recipe's; a recipe without a temperature keeps the table's); `undefined`
 *     leaves the buffer's own.
 * @property notes - the notes the buffer (or recipe) holds now, none when left out.
 * @property draftNotes - notes the table starts with as an unsaved change (a recipe's, when
 *     it has any, loaded into the buffer: the whole buffer is a draft then); `undefined`
 *     leaves the buffer's own.
 * @property onNotes - writes the notes of the list `shift+n` opens at once (it may throw):
 *     notes are never a draft of the table, only the loaded recipe's are, until then.
 * @property hint - a note for the bottom line until the first `^w`.
 * @property idleNote - what the bottom line says when it has nothing else to say.
 * @property replace - when set, the first `^w` asks `replace N solutes with recipe
 *     "NAME"?` (the buffer has N solutes that the recipe's rows replace; `and notes` is
 *     said when the recipe's notes replace the buffer's).
 * @property save - writes the rows, the pH and σ and the notes the buffer is to have
 *     (`^w`, after the check; the conditions are `undefined` while none is set, the notes
 *     an empty list); it throws if it
 *     cannot (the note is then `could not save!`) and the unit shown; it is called with
 *     complete rows only.
 * @property onUnit - called when `^k` turns the unit (the buffer keeps it at once; it is
 *     no unsaved change).
 */
type SolutesTableProps = {
    title?: string
    subtitle?: string
    items: readonly BufferRow[]
    draftRows?: readonly BufferRow[]
    conditions?: Conditions
    draftConditions?: Conditions
    notes?: readonly Note[]
    draftNotes?: readonly Note[]
    onNotes: (notes: Note[]) => void
    hint?: string
    idleNote?: string
    replace?: { count: number; recipe: string; notes?: boolean; template?: boolean }
    save: (
        rows: BufferRow[],
        conditions: Conditions | undefined,
        unit: ConcUnit,
        notes: Note[],
    ) => void
    onUnit?: (unit: ConcUnit) => void
}

/** The add keys and the pH key of the legend, in order (also what the footer reserves). */
const ADDS: LegendItem[] = [
    legendFor("add solute", keys.addNonbio),
    legendFor("add polymer", keys.addPolymer),
    legendFor("add protein", keys.addProtein),
    legendFor("add DNA/RNA", keys.addNucleotide),
    legendFor("buffer template", keys.bufferTemplate),
    legendFor("new template", keys.newTemplate),
    legendFor("rows to template", keys.convertTemplate),
    legendFor("pH, σ, T", keys.editPh),
    legendFor("units", keys.units),
    legendFor("notes", keys.notesList),
]

/** The rows the pH row takes above the table: its header, its rule, the row, a blank. */
const CONDITIONS_ROWS = 4

/** The most characters of a typed pH and σ together. */
const PH_MAX_LENGTH = 21

/** What the empty solutes table says. */
const EMPTY_HINT = `no solutes: ${keyLabels(
    keys.addNonbio, keys.addPolymer, keys.addProtein, keys.addNucleotide
)}`

/** A pH or σ typed: a number from the minimum to the maximum. */
function parseRanged(
    text: string,
    title: string,
    { min, max }: { min: number; max: number },
) {
    const range = `${title} from ${min} to ${max}`
    const parsed = parseNumber(text, { atLeast: { limit: min, message: range } })
    return "error" in parsed || parsed.value <= max ? parsed : { error: range }
}

/** The width of a cell of the pH row. */
const CONDITIONS_CELL = 10

/**
 * The pH row as a table of its own: the headers `pH`, `σ` and `T °C`, one row, no cursor.
 *
 * @param c - the pH, σ and temperature now, `undefined` for none yet.
 * @returns the columns and the one row.
 */
function conditionsTable(c: Conditions | undefined): {
    columns: Column<string>[]
    rows: string[]
} {
    const ph = c === undefined ? "not set" : formatNumber(c.pH)
    const sigma = c === undefined ? "" : formatNumber(c.sigmaPh)
    const temperature =
        c?.temperature === undefined ? "not set" : formatNumber(c.temperature)
    return {
        columns: [
            { title: "pH", width: CONDITIONS_CELL, text: () => ph },
            { title: "σ", width: CONDITIONS_CELL, text: () => sigma },
            { title: "T °C", width: CONDITIONS_CELL, text: () => temperature },
        ],
        rows: [""],
    }
}

/**
 * The unsaved pH, σ and temperature a table starts with: the ones a loaded recipe has,
 * none when it has none (the buffer's own stay) or when they are the buffer's already. A
 * recipe without a temperature leaves the buffer's temperature as it is.
 *
 * @param loaded - the pH, σ and temperature of the recipe, `undefined` for none.
 * @param saved - the pH, σ and temperature of the buffer now.
 * @returns the draft, `undefined` for no change.
 */
export function draftOf(
    loaded: Conditions | undefined,
    saved: Conditions | undefined,
): Conditions | undefined {
    const kept =
        loaded && loaded.temperature === undefined && saved?.temperature !== undefined
            ? { ...loaded, temperature: saved.temperature }
            : loaded
    return isDeepStrictEqual(kept, saved) ? undefined : kept
}

/** A field the table shows. */
type Field = "name" | "params" | "mM" | "sigmaMM"

/**
 * One row of the table as the table draws it: the row and its place, which the cell being
 * typed into is found by.
 */
type View = { row: Row<Solute>; i: number }

/**
 * The columns of the table: solute, params, `[unit]` and `±[unit]`.
 *
 * @param cellText - the text of a cell: the row, then the field.
 * @param widths - the width of every column (the text of a cell is made to fit).
 * @returns the columns.
 */
function columnsOf(
    cellText: (v: View, field: Field, width: number) => string,
    widths: number[],
): Column<View>[] {
    const w = (i: number) => widths[i] ?? 0
    const unit = concUnit()
    return [
        { title: "solute", grow: 3, text: (v) => cellText(v, "name", w(0)) },
        { title: "params", grow: 4, text: (v) => cellText(v, "params", w(1)) },
        {
            title: `[${unit}]`,
            grow: 1,
            align: "right",
            text: (v) => cellText(v, "mM", w(2)),
        },
        {
            title: `±[${unit}]`,
            grow: 1,
            align: "right",
            text: (v) => cellText(v, "sigmaMM", w(3)),
        },
    ]
}

/**
 * The table of the buffer of a project. One row for each solute
 * with the columns name, params (the numbers of a polymer, the summary of a sequence),
 * mM and ±. A row that is new or edited shows `*`, one marked to be removed `-`; nothing
 * is written before `^w`.
 *
 * Keys: up and down move; Enter edits the row (name, params, mM, ±, each typed in a
 * prompt under the table); `^n`, `^p`, `^f`, `^e` add a non-biological solute, a polymer,
 * a protein and DNA or RNA from a file (a dropdown or a prompt under the table), none
 * past 999 rows; `^r` marks the row to be removed; `^u` undoes its last change; `^w`
 * saves (a row that is not complete is told and nothing is saved); `^x` goes back, asking
 * first when something is unsaved. The pH row above the table (`pH`, `σ` and `T °C`, the
 * buffer's pH and the standard uncertainty of it, and the temperature) is edited with
 * `^g`: two prompts, pH then σ, and one for the temperature; it is an unsaved change
 * like a row until `^w`. While a flow is open Esc and `^x`
 * cancel it. `^k` turns the unit of the concentrations (mM, M, µM: display and entry
 * only, the file keeps mM). The mechanics are `useTableScreen`, the flows `useSoluteFlow`.
 *
 * @param props - see [[SolutesTableProps]].
 * @returns the screen.
 */
export function SolutesTable(props: SolutesTableProps): ReactNode {
    const { title = "buffer", subtitle, idleNote } = props
    const items = useMemo(() => props.items.map(draftFrom), [props.items])
    const added = useMemo(() => (props.draftRows ?? []).map(draftFrom), [props.draftRows])
    const nav = useNav()
    const [hint, setHint] = useState(props.hint)
    const [replace, setReplace] = useState(props.replace)
    const confirm = useConfirm()
    // the pH row: what the buffer has, and what it was edited to (unsaved)
    const [cond, setCond] = useState<{ saved?: Conditions; draft?: Conditions }>(() => ({
        saved: props.conditions,
        draft: draftOf(props.draftConditions, props.conditions),
    }))
    const shown = cond.draft ?? cond.saved
    // the notes: what the buffer has, and what they were edited to (unsaved)
    const [notes, setNotes] = useState<{ saved: Note[]; draft?: Note[] }>(() => {
        const saved = [...(props.notes ?? [])]
        const draft = props.draftNotes === undefined ? undefined : [...props.draftNotes]
        return { saved, draft: isDeepStrictEqual(draft, saved) ? undefined : draft }
    })
    const shownNotes = notes.draft ?? notes.saved
    // the unit of the concentrations: module state, the state here redraws the screen
    const [unit, setUnit] = useState(concUnit)
    // `^g`: the pH and σ prompt, then the temperature prompt (holding the pH and σ typed)
    const [asking, setAsking] = useState<"ph" | "temperature" | undefined>()
    const [typedPh, setTypedPh] = useState<Conditions | undefined>()
    const [phProblem, setPhProblem] = useState<string | undefined>(undefined)
    const [phKeys, setPhKeys] = useState<LegendItem[]>([])
    const clearPhProblem = useCallback(() => setPhProblem(undefined), [])

    const t = useTableScreen<Solute>({
        items,
        added,
        extraRows: CONDITIONS_ROWS,
        adds: ADDS,
        extraChanges: (cond.draft ? 1 : 0) + (notes.draft ? 1 : 0),
        save: (rows) => {
            props.save(rows.map(rowOf), shown, unit, shownNotes)
            setCond({ saved: shown })
            setNotes({ saved: shownNotes })
            // the buffer is replaced now, and what was said of it is done
            setReplace(undefined)
            setHint(undefined)
        },
        check: (drafts) => firstProblem(drafts, soluteProblem) ?? firstDuplicate(drafts),
        label: (solute) => solute.name,
    })
    const flow = useSoluteFlow(t)
    // a file or recipe that holds a solute twice opens, and says so
    // biome-ignore lint/correctness/useExhaustiveDependencies: told once, when it opens
    useEffect(() => {
        const twin = firstDuplicate(t.drafts)
        if (twin) t.setNote(`row ${twin[0] + 1}: ${twin[1]}`, true)
    }, [])
    const tmpl = useBufferTemplate(t, shown, (next) =>
        setCond((c) => ({
            ...c,
            draft: isDeepStrictEqual(next, c.saved) ? undefined : next,
        })),
    )

    /** The pH row typed as `pH σ`; σ may be left out (the row's own, else the default). */
    const submitPh = (text: string) => {
        const { pH: phLimits, sigmaPh } = conditionLimits()
        const fallback = formatNumber(shown?.sigmaPh ?? sigmaPh.default)
        const [phText = "", sigmaText = fallback] = text.trim().split(/\s+/)
        const pH = parseRanged(phText, "pH", phLimits)
        if ("error" in pH) return setPhProblem(pH.error)
        const sigma = parseRanged(sigmaText, "σ", sigmaPh)
        if ("error" in sigma) return setPhProblem(sigma.error)
        setPhProblem(undefined)
        setTypedPh({ pH: pH.value, "sigmaPh": sigma.value })
        setAsking("temperature")
    }

    /** The temperature typed, the last prompt of `^g`: the whole row becomes the draft. */
    const submitTemperature = (text: string) => {
        const temperature = parseTemperature(text)
        if ("error" in temperature) return setPhProblem(temperature.error)
        setPhProblem(undefined)
        setAsking(undefined)
        const next: Conditions = {
            ...(typedPh as Conditions),
            temperature: temperature.value,
        }
        // an edit back to what the target has is no change
        setCond((c) => ({
            ...c,
            draft: isDeepStrictEqual(next, c.saved) ? undefined : next,
        }))
    }

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        const ready = firstProblem(t.drafts, soluteProblem) === undefined
        if (press.is(keys.save) && replace && !t.locked && ready) {
            const { count, recipe, notes: withNotes, template } = replace
            const question = replaceBufferQuestion(
                count,
                recipe,
                t.width - 4,
                withNotes,
                template,
            )
            confirm.ask(question, () => void t.handleKey(press))
            return
        }
        if (t.handleKey(press)) return
        if (press.is(keys.enter) && t.canEdit) flow.edit()
        else if (press.is(keys.units)) {
            const next = nextConcUnit()
            setUnit(next)
            props.onUnit?.(next)
        }
        else if (press.is(keys.notesList)) {
            nav.push(
                <NotesList
                    owner={title === "buffer" ? `buffer ${subtitle ?? ""}`.trim() : title}
                    items={shownNotes}
                    onSave={(list) => {
                        props.onNotes(list)
                        setNotes({ saved: list })
                    }}
                />,
            )
        } else if (press.is(keys.editPh)) {
            setPhProblem(undefined)
            setAsking("ph")
        } else if (!t.canAdd) return
        else if (press.is(keys.addNonbio)) flow.add("nonbio")
        else if (press.is(keys.addPolymer)) flow.add("polymer")
        else if (press.is(keys.addProtein)) flow.add("protein")
        else if (press.is(keys.addNucleotide)) flow.add("nucleotide")
        else if (press.is(keys.bufferTemplate)) tmpl.start()
        else if (press.is(keys.newTemplate)) tmpl.startNew()
        else if (press.is(keys.convertTemplate)) tmpl.convert()
    }, !flow.open && asking === undefined && !tmpl.open)

    const cellText = (v: View, field: Field, width: number) => {
        if (flow.cell?.row === v.i && flow.cell.field === field) return flow.cell.text
        const s = rowValue(v.row) as Solute
        if (field === "name") return s.name
        if (field === "params") return paramsCell(s, width).text
        return formatConc(s[field], unit, width)
    }
    const widths = columnWidths(columnsOf(cellText, []), t.width)
    const view: View[] = flow.rows.map((row, i) => ({ row, i }))

    // only the keys that work now (`useTableScreen` knows where the cursor is and what the
    // rows allow); an open flow says what it says, else the table's own note, the basis of
    // the polymer under the cursor
    const legend = confirm.question ? questionLegend(confirm.question) : t.legend(ADDS)
    const quiet = t.frameNote === undefined
    const tableNote =
        t.frameNote ?? (t.current ? rowNote(t.current) : undefined) ?? hint ?? idleNote
    const openNote = tmpl.open ? tmpl.note : flow.open ? flow.note : tableNote
    const note = confirm.note ?? openNote
    const openLegend = tmpl.open ? tmpl.legend : flow.open ? flow.legend : legend
    const shownLegend = asking ? phKeys : openLegend
    const changes = t.drafts.count + (cond.draft ? 1 : 0) + (notes.draft ? 1 : 0)
    // the prompt takes rows under the table, so the window shrinks to keep the cursor
    const taken = asking ? PROMPT_ROWS : tmpl.reserved
    const pageSize = taken > 0 ? Math.max(3, flow.pageSize - taken) : flow.pageSize
    const offset = taken > 0
        ? scrollWindow(flow.cursor, flow.offset, pageSize, flow.rows.length)
        : flow.offset
    const small = conditionsTable(shown)
    return (
        <Frame
            design="blocky"
            title={title}
            subtitle={changes > 0 ? `${changes} unsaved` : subtitle}
            legendFull={t.legendFull}
            legend={shownLegend}
            note={note}
            noteIsError={
                tmpl.open
                    ? tmpl.noteIsError
                    : !flow.open && !quiet && !confirm.question && t.frameNoteIsError
            }
        >
            {tmpl.page ?? (
                <>
                    <DataTable
                        border="double"
                        columns={small.columns}
                        rows={small.rows}
                        cursor={-1}
                        offset={0}
                        pageSize={1}
                        mark={() => (cond.draft ? "*" : " ")}
                        width={t.width}
                    />
                    <Text> </Text>
                    <DataTable
                        border="double"
                        columns={columnsOf(cellText, widths)}
                        rows={view}
                        cursor={flow.cursor}
                        offset={offset}
                        pageSize={pageSize}
                        mark={(v) => t.mark(v.row)}
                        empty={EMPTY_HINT}
                        width={t.width}
                    />
                </>
            )}
            {tmpl.entry}
            {flow.entry}
            {t.finder}
            {asking === "ph" ? (
                <Prompt
                    key="ph"
                    label="pH σ:"
                    initial={
                        shown
                            ? `${formatNumber(shown.pH)} ${formatNumber(shown.sigmaPh)}`
                            : ""
                    }
                    maxLength={PH_MAX_LENGTH}
                    placeholder="pH, then σ (optional)"
                    error={phProblem}
                    onChange={clearPhProblem}
                    onLegend={setPhKeys}
                    onSubmit={submitPh}
                    onCancel={() => setAsking(undefined)}
                />
            ) : asking === "temperature" ? (
                <Prompt
                    key="temperature"
                    label={TEMPERATURE_LABEL}
                    initial={temperatureStart(shown?.temperature)}
                    maxLength={RUN_FLOW.temperature.maxLength}
                    error={phProblem}
                    onChange={clearPhProblem}
                    onLegend={setPhKeys}
                    onSubmit={submitTemperature}
                    onCancel={() => setAsking(undefined)}
                />
            ) : null}
        </Frame>
    )
}
