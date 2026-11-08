// SPDX-License-Identifier: LGPL-3.0-or-later

// The add flow of the solutes table, as a state machine without a terminal. The four add
// keys (`^n` a non-biological solute, `^p` a polymer, `^f` a protein file, `^e` a DNA or
// RNA file) and the edit of an existing row each start a flow; a flow asks one thing at a
// time:
//
//   name   a dropdown of every solute BAYSOL knows (`search` of ./solutes.ts, plus
//          the custom solutes), narrowed by what is typed, for `^n` and `^p`;
//   form   a polymer family with several forms (PEG by n or by Mn) asks which one;
//   nuc    `^e` asks DNA or RNA first;
//   path   the path of a sequence file (hinted as the models' paths are) or the sequence
//          text itself, typed or pasted; a file is read and its text linted the same way;
//          and every record of it becomes a row;
//   edit   one cell is typed into: the name (free text), the params of a family (one
//          argument at a time), mM, then +-;
//   done   nothing is asked any more: `table` holds the result.
//
// After the pick, by kind of the entry: a non-biological solute or a built-in polymer
// grade goes on to mM and +-; a polymer family asks its numbers in the params cell
// (`units n`, `Mn (g/mol)`, ...); a custom non-biological solute stores a snapshot of the
// entry (the project never reads the global file); DNA, RNA and protein ask a path and
// make one row for each record of the file, with the same mM and +-. The rows are those of
// `test/fixtures/buffer/buffer.json`. The flow never saves: the rows are drafts of a
// `Drafts<Solute>` until the screen's `^w`.
//
// How a screen uses it: make an `AddFlow` (`AddFlow.add` or `AddFlow.edit`), draw
// `flow.step` (a dropdown, a prompt or done), and forward what the user does as an
// `AddEvent` through `flow.send`. Every transition is also a pure function
// (`advance(state, event)`), which is what the class wraps.
//
// The row keys follow `Solute` of ./solutes.ts (`sigmaMM`); `bufferRow` renames it to the
// `sigma-mM` of the file (see ./solutes.ts), which `rowProblem` of ./buffer.ts checks.
//
// The vocabulary of the flow (fields, entries, params cell, states, events, steps) is in
// `solutes.ts`.
//
// Contents:
//   1. Building states: the state of a flow started, of a pick, of a field opened
//   2. The steps of the pick, 3. the path or text of a sequence, 4. editing a cell
//   5. The transitions: `advance`
//   6. What to draw: `view`
//   7. The class: `AddFlow`

import { basename } from "node:path"
import { parseNumber, tooLong } from "../core/terminal.js"
import { type AddEvent, type AddKind, type AddState, argProblem, basisNote, COUNT_RULES, type Common, type CountsContext, contextArgs, ctxInitialText, ctxPrompt, ctxShown, type DoneState, type EditState, editableParams, entries, entryTag, type FamilyContext, type FlowStep, type FormState, type NameKind, type NameState, type NucleotideState, type ParamsContext, type PathState } from "./add-state.js"
import { rowProblem } from "./buffer.js"
import { type CustomEntry, type NonbioEntry, snapshot } from "./custom.js"
import {
    checkPath,
    complete,
    type Drafts,
    hintsFor,
    isFastaFile,
    MAX_PATH_TYPED,
    MAX_ROWS,
    parseFile,
    parseText,
    residuesOf,
    type SequenceKind,
    type SequenceRecords,
} from "./lists.js"
import type { PolymerEntry } from "./polymers.js"
import { bufferRow, COLUMNS, cycle, type EditField, family, familyArg, fieldLabel, formatConc, MAX_CELL_TYPED, MAX_NAME_TYPED, NO_MATCH, NUCLEOTIDE_KINDS, type PolymerFamily, parseAddField, RE_ADD_NOTE, SEQUENCE_KINDS, type Solute, type SoluteEntry, setSoluteField } from "./solutes.js"


// ========================================================================================
// 1. Building states
// ========================================================================================

/** The solute of row `i`. */
function rowSolute(table: Drafts<Solute>, i: number): Solute {
    const s = table.value(i)
    if (!s) throw new RangeError(`no row ${i}`)
    return s
}

/** `cursor` held within a table: 0 at the least, the last row at the most. */
function clampCursor(cursor: number, table: Drafts<Solute>): number {
    return Math.max(0, Math.min(cursor, table.length - 1))
}

/** The state that ends the flow with the table it stands at. */
function finish(state: Common, cancelled = false, table = state.table): DoneState {
    const { added, fromCursor } = state
    return { kind: "done", table, cursor: state.cursor, added, fromCursor, cancelled }
}

/** The state after Escape: the rows of an add go and the cursor is where it was. */
function cancelAdd(state: Common): DoneState {
    const table = state.table.dropNew(state.added)
    return {
        kind: "done",
        table,
        cursor: clampCursor(state.fromCursor, table),
        added: [],
        fromCursor: state.fromCursor,
        cancelled: true,
    }
}

/** The part of a state that goes on from step to step of one flow. */
function carry(state: Common): Pick<Common, "table" | "cursor" | "added" | "fromCursor"> {
    return {
        table: state.table,
        cursor: state.cursor,
        added: state.added,
        fromCursor: state.fromCursor,
    }
}

/** The text to start typing a field of a row from. */
function fieldText(table: Drafts<Solute>, i: number, field: EditField): string {
    const s = rowSolute(table, i)
    switch (field) {
        case "name":
            return s.name
        case "mM":
            return formatConc(s.mM)
        case "sigmaMM":
            return formatConc(s.sigmaMM)
        default:
            return ""
    }
}

/** What opening a field carries besides the flow's own state. */
interface OpenOptions {
    queue: readonly EditField[]
    ctx?: ParamsContext
    nextCtx?: ParamsContext
    batch?: readonly number[]
    hint?: string
}

/** The state with a field of row `i` open for typing. */
function openField(
    from: Common,
    table: Drafts<Solute>,
    i: number,
    field: EditField,
    o: OpenOptions,
): EditState {
    return {
        ...carry(from),
        table,
        cursor: i,
        kind: "edit",
        i,
        field,
        text: o.ctx ? ctxInitialText(o.ctx) : fieldText(table, i, field),
        queue: o.queue,
        ctx: o.ctx,
        nextCtx: o.nextCtx,
        batch: o.batch,
        hint: o.hint,
    }
}

/**
 * The state after the field of an edit is done: the next field of its queue opens (a
 * params field with `nextCtx`), or the edit ends.
 */
function nextField(
    state: EditState,
    table: Drafts<Solute>,
    over: { hint?: string; nextCtx?: ParamsContext },
): AddState {
    const [field, ...more] = state.queue
    if (!field) return finish(state, false, table)
    return openField(state, table, state.i, field, {
        queue: more,
        ctx: field === "params" ? over.nextCtx : undefined,
        batch: state.batch,
        hint: over.hint,
    })
}

/** The state with mM then +- opened for row `i`. */
function toMoney(from: Common, table: Drafts<Solute>, i: number): EditState {
    return openField(from, table, i, "mM", { queue: ["sigmaMM"] })
}

/** The state with the numbers of a family form being asked for row `i`. */
function familyStart(
    from: Common,
    table: Drafts<Solute>,
    i: number,
    fam: PolymerFamily,
    formIndex: number,
): EditState {
    const ctx: FamilyContext = {
        type: "family",
        fam,
        formIndex,
        k: 0,
        values: {},
        prefill: {},
    }
    return openField(from, table, i, "params", { queue: ["mM", "sigmaMM"], ctx })
}

/** How a form asks for its numbers: the prompts of its arguments. */
function formLabel(form: { args: { prompt: string }[] }): string {
    return form.args.map((a) => a.prompt).join(", ")
}

/** The name state for a typed query. */
function refilter(state: NameState, query: string): NameState {
    return {
        ...state,
        query,
        matches: entries(state.nameKind, query, state.customs),
        index: 0,
        problem: undefined,
    }
}

/**
 * The state of the dropdown of names of an add key with nothing typed.
 *
 * @param from - the flow's table, cursor and rows.
 * @param nameKind - `nonbio` or `polymer`.
 * @param customs - the custom solutes to offer.
 * @returns the state.
 */
function nameState(
    from: Common,
    nameKind: NameKind,
    customs: readonly CustomEntry[],
): NameState {
    return {
        ...carry(from),
        kind: "name",
        nameKind,
        customs,
        query: "",
        matches: [],
        index: 0,
    }
}

/** The `source` of rows made from typed or pasted text (a file's rows carry its name). */
const PASTED_SOURCE = "text"

/** The state of the path prompt of a sequence file. */
function pathState(from: Common, seqKind: SequenceKind): PathState {
    return { ...carry(from), kind: "path", seqKind, buffer: "", index: 0 }
}

/** How a flow is started. */
export interface StartOptions {
    /** The custom solutes to offer in the name dropdown. */
    customs?: readonly CustomEntry[]
    /** The table's cursor, which Escape goes back to. */
    cursor?: number
    /** A message to show at once (`custom file unusable!`). */
    problem?: string
}

/**
 * The flow of an add key: a new blank row at the end of the table and its first question.
 *
 * @param table - the table.
 * @param kind - `nonbio` (`^n`) and `polymer` (`^p`) ask the name in a dropdown; `protein`
 *   (`^f`) asks the path of a sequence file at once; `nucleotide` (`^e`) asks DNA or RNA,
 *   then the path.
 * @param options - the custom solutes, the cursor, a first message.
 * @returns the first state; done at once, with the table as it is, when it holds
 *   `MAX_ROWS` rows.
 */
function startAdd(
    table: Drafts<Solute>,
    kind: AddKind,
    options: StartOptions = {},
): AddState {
    const fromCursor = options.cursor ?? 0
    if (!table.hasRoom) {
        return {
            kind: "done",
            table,
            cursor: fromCursor,
            added: [],
            fromCursor,
            cancelled: true,
        }
    }
    const n = table.length
    const grown = table.add({
        kind: "nonbiological",
        name: "",
        arg: "",
        mM: null,
        sigmaMM: null,
    })
    const from: Common = {
        table: grown,
        cursor: n,
        added: [n],
        fromCursor,
        problem: options.problem,
    }
    let state: AddState
    if (kind === "protein") state = pathState(from, "protein")
    else if (kind === "nucleotide") state = { ...carry(from), kind: "nuc", index: 0 }
    else state = nameState(from, kind, options.customs ?? [])
    return { ...state, problem: options.problem }
}

/**
 * The flow of an edit of the row under the cursor: its name (a free label), the params of
 * a polymer family, mM, then +-.
 *
 * @param table - the table.
 * @param cursor - the row.
 * @returns the first state; done at once for no row or a row marked for removal.
 */
function startEdit(table: Drafts<Solute>, cursor: number): AddState {
    const row = table.rows[cursor]
    const base: Common = { table, cursor, added: [], fromCursor: cursor }
    if (!row || row.removed) return finish(base, true)
    const ctx = editableParams(rowSolute(table, cursor))
    return openField(base, table, cursor, "name", {
        queue: [...(ctx ? (["params"] as const) : []), "mM", "sigmaMM"],
        nextCtx: ctx,
    })
}

// ========================================================================================
// 2. The steps of the pick
// ========================================================================================

/** The state after an entry was picked in the name dropdown. */
function picked(state: NameState, e: SoluteEntry): AddState {
    const i = state.added[0]
    const solute = { name: e.name, mM: null, sigmaMM: null }
    const set = (s: Solute) => state.table.set(i, s)
    switch (e.kind) {
        case "nonbiological":
        case "polymer":
            return toMoney(state, set({ ...solute, kind: e.kind, arg: e.target }), i)
        case "polymer-family": {
            const fam = e.family === undefined ? undefined : family(e.family)
            if (!fam) return { ...state, problem: "no such family" }
            const table = set({ ...solute, kind: "polymer", arg: "" })
            if (fam.forms.length > 1) {
                const labels = fam.forms.map(formLabel)
                return { ...carry(state), table, kind: "form", fam, labels, index: 0 }
            }
            return familyStart(state, table, i, fam, 0)
        }
        case "custom-nonbio": {
            const snap = {
                ...snapshot(e.entry as NonbioEntry),
                ...solute,
            } as unknown as Solute // a custom row has no `arg`
            const probe = { ...snap, mM: 1, sigmaMM: 0 }
            if (rowProblem(bufferRow(probe)))
                return { ...state, problem: "custom entry invalid" }
            return toMoney(state, set(snap), i)
        }
        case "custom-polymer": {
            const entry = e.entry as PolymerEntry
            const labels = entry.units.map((u) => u.label)
            const ones = labels.map(() => 1)
            const probe = { ...snapshot(entry, ones), mM: 1, sigmaMM: 0 }
            if (rowProblem(bufferRow(probe as unknown as Solute)))
                return { ...state, problem: "custom entry invalid" }
            const table = set({ ...solute, kind: "custom-polymer" } as Solute)
            const ctx: CountsContext = {
                type: "counts",
                entry,
                labels,
                k: 0,
                counts: [],
                prefill: [],
            }
            return openField(state, table, i, "params", { queue: ["mM", "sigmaMM"], ctx })
        }
    }
}

// ========================================================================================
// 3. The path or text of a sequence
// ========================================================================================

/**
 * What is wrong with a path as the sequence file to read.
 *
 * @param path - the path typed.
 * @returns a message of 22 characters at most: `type a path first!`, `use a full path`,
 *   `no such file`, `that is a folder`, `cannot read the file`; `undefined` when fine.
 */
export function sequencePathProblem(path: string): string | undefined {
    return checkPath(path, 22)
}

/** Whether typed text names a path (it has a separator, a dot, `~` or a drive colon). */
function looksLikePath(text: string): boolean {
    return /[/\\.~:]/.test(text)
}

/** The rows of the records taken, each asked its mM and ± next. */
function takeRecords(
    state: PathState,
    records: SequenceRecords,
    source: string,
): AddState {
    const existing = state.table.length - state.added.length
    if (existing + records.length > MAX_ROWS) {
        return { ...state, problem: `over ${MAX_ROWS} rows` }
    }
    const [first, ...rest] = records.map(
        (r): Solute => ({
            kind: state.seqKind,
            name: r.id,
            arg: r.letters,
            source,
            record: r.id,
            mM: null,
            sigmaMM: null,
        }),
    )
    const i = state.added[0]
    const table = state.table.set(i, first).add(...rest)
    const idx = [...Array(records.length).keys()].map((k) => i + k)
    return openField({ ...state, added: idx }, table, i, "mM", {
        queue: ["sigmaMM"],
        batch: idx,
    })
}

/**
 * The state after Enter: the pasted text waiting, else what is typed. Text that names a
 * path is a file (every path message of [[checkPath]] applies); anything else is linted
 * as sequence text ([[parseText]]).
 */
function pathEnter(state: PathState): AddState {
    // a typed or pasted path may end in blanks or a newline
    const text = state.buffer.trim()
    if (text === "") {
        return state.pasted
            ? takeRecords(state, state.pasted, PASTED_SOURCE)
            : { ...state, problem: "type a path or a sequence first!" }
    }
    if (!looksLikePath(text)) {
        const parsed = parseText(text, state.seqKind)
        if ("error" in parsed) return { ...state, problem: parsed.error }
        return takeRecords(state, parsed.records, PASTED_SOURCE)
    }
    const problem = sequencePathProblem(text)
    if (problem) return { ...state, problem }
    const parsed = parseFile(text, state.seqKind)
    if ("error" in parsed) return { ...state, problem: parsed.error }
    return takeRecords(state, parsed.records, basename(text))
}

// ========================================================================================
// 4. Editing a cell
// ========================================================================================

/** The table with a field of every row of a batch (or of row `i`) set. */
function setBatchField(
    table: Drafts<Solute>,
    state: EditState,
    field: string,
    value: unknown,
): Drafts<Solute> {
    return (state.batch ?? [state.i]).reduce(
        (t, j) => setSoluteField(t, j, field, value),
        table,
    )
}

/** The state after Enter in the params cell: the argument is taken and the next asked. */
function paramsEnter(state: EditState): AddState {
    const ctx = state.ctx
    if (!ctx) return finish(state)
    const k = ctx.k
    const asNext = (c: ParamsContext): EditState => ({
        ...state,
        ctx: c,
        text: ctxInitialText(c),
    })
    if (ctx.type === "family") {
        const args = contextArgs(ctx)
        const key = args[k].key
        const problem = argProblem(ctx, key, state.text)
        if (problem) return { ...state, problem }
        const values = { ...ctx.values, [key]: state.text.trim() }
        if (k + 1 < args.length) return asNext({ ...ctx, values, k: k + 1 })
        const result = familyArg(ctx.fam, ctx.formIndex, values)
        if ("error" in result) return { ...state, problem: result.error }
        const table = setSoluteField(state.table, state.i, "arg", result.arg)
        return nextField(state, table, { hint: result.note })
    }
    const parsed = parseNumber(state.text, COUNT_RULES)
    if ("error" in parsed) return { ...state, problem: parsed.error }
    const counts = [...ctx.counts, parsed.value]
    if (k + 1 < ctx.labels.length) return asNext({ ...ctx, counts, k: k + 1 })
    const row = rowSolute(state.table, state.i)
    const made = ctx.entry
        ? ({ ...row, ...snapshot(ctx.entry, counts) } as Solute)
        : { ...row, counts }
    return nextField(state, state.table.set(state.i, made), {})
}

/** The state after Enter in the cell being typed into. */
function editEnter(state: EditState): AddState {
    if (state.field === "params") return paramsEnter(state)
    const parsed = parseAddField(state.field, state.text)
    if ("error" in parsed) return { ...state, problem: parsed.error }
    const table = setBatchField(state.table, state, state.field, parsed.value)
    return nextField(state, table, {
        hint: state.field === "mM" ? undefined : state.hint,
        nextCtx: state.nextCtx,
    })
}

// ========================================================================================
// 5. The transitions
// ========================================================================================

/** The state with the typed text replaced, or the message that it is too long. */
function withText<S extends { problem?: string }>(
    state: S,
    text: string,
    max: number,
    what: string,
    set: (s: S, text: string) => S,
): S {
    if (text.length > max) return { ...state, problem: tooLong(what, max) }
    return set(state, text)
}

/** The index `state` has after an event that picks entry `index` (when given). */
function atIndex<S extends { index: number }>(state: S, index: number | undefined): S {
    return index === undefined ? state : { ...state, index }
}

/** The name dropdown after an event. */
function advanceName(state: NameState, event: AddEvent): AddState {
    const { matches, index } = state
    switch (event.type) {
        case "cancel":
            return cancelAdd(state)
        case "submit":
            return matches.length > 0
                ? picked(state, matches[index])
                : { ...state, problem: "no match" }
        case "pick": {
            const at = atIndex(state, event.index)
            return at.matches[at.index] ? picked(at, at.matches[at.index]) : state
        }
        case "move":
            return matches.length > 0
                ? { ...state, index: cycle(index, matches.length, event.delta) }
                : state
        case "complete":
            return matches.length > 0 ? refilter(state, matches[index].name) : state
        case "text":
            return withText(state, event.text, MAX_NAME_TYPED, "name", refilter)
        default:
            return state
    }
}

/** A dropdown of choices (the forms, DNA or RNA) after an event: the index it picks. */
function advanceChoice(
    state: FormState | NucleotideState,
    n: number,
    event: AddEvent,
    choose: (index: number) => AddState,
): AddState {
    switch (event.type) {
        case "cancel":
            return cancelAdd(state)
        case "submit":
            return choose(state.index)
        case "pick":
            return event.index !== undefined && event.index < n
                ? choose(event.index)
                : state
        case "move":
            return { ...state, index: cycle(state.index, n, event.delta) }
        default:
            return state
    }
}

/** The path prompt after an event. */
function advancePath(state: PathState, event: AddEvent): AddState {
    const hints = hintsFor(state.buffer, isFastaFile)
    const at = Math.min(state.index, Math.max(0, hints.length - 1))
    switch (event.type) {
        case "cancel":
            return cancelAdd(state)
        case "submit":
            return pathEnter(state)
        case "move":
            return hints.length > 0
                ? { ...state, index: cycle(at, hints.length, event.delta) }
                : state
        case "complete":
            return hints.length > 0
                ? { ...state, buffer: complete(state.buffer, hints[at]), index: 0 }
                : state
        case "text":
            return withText(state, event.text, MAX_PATH_TYPED, "path", (s, buffer) => ({
                ...s,
                buffer,
                index: 0,
                pasted: undefined,
            }))
        case "paste": {
            const parsed = parseText(event.text, state.seqKind)
            return "error" in parsed
                ? { ...state, pasted: undefined, problem: parsed.error }
                : { ...state, pasted: parsed.records }
        }
        case "files": {
            if ("problem" in event.result)
                return { ...state, problem: event.result.problem }
            const first = event.result.files[0]
            return first === undefined ? state : { ...state, buffer: first }
        }
        default:
            return state
    }
}

/** The cell being typed into after an event. */
function advanceEdit(state: EditState, event: AddEvent): AddState {
    switch (event.type) {
        case "cancel":
            return state.added.length > 0 ? cancelAdd(state) : finish(state, true)
        case "submit":
            return editEnter(state)
        case "text":
            return withText(state, event.text, MAX_CELL_TYPED, "text", (s, text) => ({
                ...s,
                text,
            }))
        default:
            return state
    }
}

/**
 * The state after an event. The message of the last event (`problem`) is dropped at the
 * next one; a state that is done does not change.
 *
 * @param state - the state.
 * @param event - what the user did.
 * @returns the next state (the same object when the event means nothing here).
 */
function advance(state: AddState, event: AddEvent): AddState {
    const clean = state.problem === undefined ? state : { ...state, problem: undefined }
    switch (clean.kind) {
        case "name":
            return advanceName(clean, event)
        case "form": {
            const open = (index: number) =>
                familyStart(clean, clean.table, clean.added[0], clean.fam, index)
            return advanceChoice(clean, clean.labels.length, event, open)
        }
        case "nuc": {
            const open = (index: number) => pathState(clean, NUCLEOTIDE_KINDS[index][1])
            return advanceChoice(clean, NUCLEOTIDE_KINDS.length, event, open)
        }
        case "path":
            return advancePath(clean, event)
        case "edit":
            return advanceEdit(clean, event)
        default:
            return state
    }
}

// ========================================================================================
// 6. What to draw
// ========================================================================================

/** The status row of the name dropdown when nothing went wrong: what to type, no match. */
function nameStatus(state: NameState): string | undefined {
    if (state.problem) return state.problem
    if (state.query.trim() === "") {
        return state.nameKind === "polymer" ? "type a polymer name" : "type a solute name"
    }
    return state.matches.length === 0 ? NO_MATCH : undefined
}

/** The border note while a cell is open: a prompt, the hint kept for mM, a reminder. */
function editNote(state: EditState): string | undefined {
    if (state.field === "params" && state.ctx) return ctxPrompt(state.ctx)
    if (state.field === "mM" && state.hint) return state.hint
    const kind = rowSolute(state.table, state.i).kind
    if (state.field === "name" && SEQUENCE_KINDS.has(kind)) return RE_ADD_NOTE
    return undefined
}

/** The status row of the path prompt. */
function pathStatus(state: PathState, hints: readonly string[]): string | undefined {
    if (state.problem) return state.problem
    if (state.pasted) {
        const n = residuesOf(state.pasted)
        const k = state.pasted.length
        return `pasted ${n} residues${k > 1 ? ` in ${k} records` : ""}`
    }
    if (state.buffer === "") return "type a path or a sequence, o: file picker"
    return hints.length === 0 ? "no hint" : undefined
}

/**
 * What a screen draws for a state.
 *
 * @param state - the state.
 * @returns a dropdown, a prompt, or done.
 */
function view(state: AddState): FlowStep {
    const { problem } = state
    const paramsColumn = COLUMNS.indexOf("params")
    switch (state.kind) {
        case "name": {
            const cell = { row: state.added[0], column: 0 }
            return {
                type: "dropdown",
                label: "name",
                cell,
                typed: state.query,
                maxLength: MAX_NAME_TYPED,
                items: state.matches.map((e) => ({ text: e.name, tag: entryTag(e) })),
                index: state.index,
                status: nameStatus(state),
                note: basisNote(state.matches[state.index]?.basis),
                problem,
            }
        }
        case "form":
            return {
                type: "dropdown",
                label: "form",
                cell: { row: state.added[0], column: paramsColumn },
                items: state.labels.map((text) => ({ text })),
                index: state.index,
                problem,
            }
        case "nuc":
            return {
                type: "dropdown",
                label: "DNA or RNA",
                cell: { row: state.added[0], column: 0 },
                items: NUCLEOTIDE_KINDS.map(([text]) => ({ text })),
                index: state.index,
                problem,
            }
        case "path": {
            const hints = hintsFor(state.buffer, isFastaFile)
            return {
                type: "dropdown",
                label: "path",
                cell: { row: state.added[0], column: 0 },
                typed: state.buffer,
                maxLength: MAX_PATH_TYPED,
                items: hints.map((text) => ({ text })),
                index: Math.min(state.index, Math.max(0, hints.length - 1)),
                status: pathStatus(state, hints),
                filePicker: true,
                problem,
            }
        }
        case "edit": {
            const { ctx } = state
            const params = state.field === "params" && ctx
            return {
                type: "prompt",
                label: params ? ctxPrompt(ctx) : fieldLabel(state.field),
                cell: { row: state.i, column: COLUMNS.indexOf(state.field) },
                typed: state.text,
                shown: params ? ctxShown(ctx, state.text) : state.text,
                maxLength: MAX_CELL_TYPED,
                note: editNote(state),
                problem,
            }
        }
        case "done":
            return {
                type: "done",
                cancelled: state.cancelled,
                table: state.table,
                cursor: state.cursor,
                added: state.added,
                problem,
            }
    }
}

// ========================================================================================
// 7. The class
// ========================================================================================

/**
 * One add or edit flow for a screen: draw `step`, forward what the user does to `send`
 * until `done`, then take `table` and `cursor`.
 */
export class AddFlow {
    private current: AddState

    private constructor(state: AddState) {
        this.current = state
    }

    /**
     * Starts the flow of an add key.
     *
     * @param table - the table.
     * @param kind - the add key.
     * @param options - the custom solutes, the cursor, a first message.
     * @returns the flow (done at once when the table is full).
     */
    static add(table: Drafts<Solute>, kind: AddKind, options: StartOptions = {}): AddFlow {
        return new AddFlow(startAdd(table, kind, options))
    }

    /**
     * Starts the edit of one row.
     *
     * @param table - the table.
     * @param cursor - the row.
     * @returns the flow (done at once for no row or a row marked for removal).
     */
    static edit(table: Drafts<Solute>, cursor: number): AddFlow {
        return new AddFlow(startEdit(table, cursor))
    }

    /** The state, for the pure functions. */
    get state(): AddState {
        return this.current
    }

    /** What to draw now. */
    get step(): FlowStep {
        return view(this.current)
    }

    /** Whether the flow is over. */
    get done(): boolean {
        return this.current.kind === "done"
    }

    /** The table as the flow has it (the result once `done`). */
    get table(): Drafts<Solute> {
        return this.current.table
    }

    /** The row the flow is at (the cursor of the table once `done`). */
    get cursor(): number {
        return this.current.cursor
    }

    /**
     * Forwards what the user did.
     *
     * @param event - the event.
     * @returns the step to draw next.
     */
    send(event: AddEvent): FlowStep {
        this.current = advance(this.current, event)
        return this.step
    }
}
