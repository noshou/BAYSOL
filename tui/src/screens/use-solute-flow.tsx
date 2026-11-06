// SPDX-License-Identifier: LGPL-3.0-or-later

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

import { basename } from "node:path"
import { type ReactNode, useCallback, useReducer, useRef, useState } from "react"
import { pick } from "../core/file-picker.js"
import { appDir } from "../core/paths.js"
import { readSystem } from "../core/system.js"
import {
    type AddEvent,
    AddFlow,
    type AddKind,
    basisNote,
    COLUMNS,
    type DoneStep,
    type EditField,
    type FlowStep,
    NO_MATCH,
} from "../store/add-flow.js"
import type { CustomEntry } from "../store/custom.js"
import { customFile, readCustomSolutes } from "../store/custom-store.js"
import type { Row } from "../store/draft.js"
import { pathSuggestions } from "../store/path-input.js"
import { isFastaFile } from "../store/sequences.js"
import type { Solute } from "../store/solutes.js"
import { Dropdown, filterChoices } from "../ui/dropdown.js"
import { Entry, suggestionLines } from "../ui/entry.js"
import { keys } from "../ui/keys.js"
import { type LegendItem, legendFor } from "../ui/legend.js"
import { Prompt } from "../ui/prompt.js"
import { scrollWindow } from "../ui/scroll-window.js"
import type { Suggestion } from "../ui/suggestion-list.js"
import { useKeys } from "../ui/use-keys.js"
import { flowChanges } from "./solute-rows.js"
import type { TableScreen } from "./use-table-screen.js"

/**
 * The rows an open flow takes under the table: its label, the messages, the suggestions
 * (`suggestionLines`) and the status line.
 */
const FLOW_ROWS = suggestionLines + 4

/** The fewest table rows left in view while a flow is open. */
const MIN_TABLE_ROWS = 3

/** The message when the custom solutes cannot be read: only built-in ones are offered. */
const customUnusable = (file: string) => `${file} unusable!`

/** What the path field says while nothing is typed. */
const PATH_PLACEHOLDER = "full path of a FASTA or FASTQ file"

/** The suggestions of the path prompt of a sequence file: folders and FASTA/FASTQ files. */
const suggestSequencePaths = (text: string) => pathSuggestions(text, isFastaFile)

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
export function flowLegend(step: FlowStep, items: LegendItem[]): LegendItem[] {
    const completes = step.type === "dropdown" && step.label !== "path"
    if (!completes || step.typed !== undefined) return items
    return items.filter((i) => i.keys !== keys.tab.label)
}

/** A flow that is open and the table it was started on. */
type Run = { flow: AddFlow; before: TableScreen<Solute>["drafts"] }

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
export type SoluteFlow = {
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
export function useSoluteFlow(t: TableScreen<Solute>, root: string = appDir()): SoluteFlow {
    // the flow is a mutable object: it lives in a ref and a counter redraws after it moves
    const tRef = useRef(t)
    tRef.current = t
    const run = useRef<Run | undefined>(undefined)
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
        const { replaced, appended } = flowChanges(current.before, done.table)
        for (const [i, s] of replaced) tRef.current.replaceAt(i, s)
        for (const s of appended) tRef.current.append(s)
        redraw()
    }, [])

    const send = useCallback(
        (event: AddEvent) => {
            const current = run.current
            if (!current) return
            const step = current.flow.send(event)
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
            run.current = { flow, before: tRef.current.drafts }
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
        const state = run.current?.flow.state
        const entry = state?.kind === "name" && s ? state.matches[s.value] : undefined
        setBasis(basisNote(entry?.basis))
    }, [])

    const current = run.current
    const step = current?.flow.step
    const typed = step?.type === "dropdown" ? step.typed : undefined
    const canPick = step?.type === "dropdown" && step.filePicker === true && typed === ""

    // `o` on an empty path field asks the desktop for a file; the field has the `o` by
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

    const rows = [...current.flow.table.rows]
    const cursor = current.flow.cursor
    const pageSize = Math.max(MIN_TABLE_ROWS, t.pageSize - FLOW_ROWS)
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
            <Prompt
                key={key("path")}
                label="path:"
                initial={step.typed}
                maxLength={step.maxLength}
                placeholder={PATH_PLACEHOLDER}
                suggest={suggestSequencePaths}
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
