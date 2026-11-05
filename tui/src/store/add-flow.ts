// SPDX-License-Identifier: LGPL-3.0-or-later

// The add flow of the solutes table, as a state machine without a terminal. The four add
// keys (`^n` a non-biological solute, `^p` a polymer, `^f` a protein file, `^e` a DNA or
// RNA file) and the edit of an existing row each start a flow; a flow asks one thing at a
// time:
//
//   name   a dropdown of every solute BAYSOL knows (`search` of ./solute-index.ts, plus
//          the custom solutes), narrowed by what is typed, for `^n` and `^p`;
//   form   a polymer family with several forms (PEG by n or by Mn) asks which one;
//   nuc    `^e` asks DNA or RNA first;
//   path   the path of a sequence file, hinted as the models' paths are; the file is read
//          and every record of it becomes a row;
//   edit   one cell is typed into: the name (free text), the params of a family or of a
//          custom polymer (one argument at a time), mM, then +-;
//   done   nothing is asked any more: `table` holds the result.
//
// After the pick, by kind of the entry: a non-biological solute or a built-in polymer
// grade goes on to mM and +-; a polymer family asks its numbers in the params cell
// (`units n`, `Mn (g/mol)`, ...); a custom non-biological solute stores a snapshot of the
// entry (the project never reads the global file); a custom polymer asks the count of each
// unit kind (`nA`, `nB`, ...); DNA, RNA and protein ask a path and make one row for each
// record of the file, with the same mM and +-. The rows are those of
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

import { accessSync, constants, statSync } from "node:fs"
import { basename, isAbsolute } from "node:path"
import {
    displayWidth,
    formatNumber,
    numberText,
    type Parsed,
    takeWidth,
    tooLong,
} from "../core/text.js"
import { rowProblem } from "./buffer.js"
import {
    type CustomEntry,
    type NonbioEntry,
    type PolymerEntry,
    snapshot,
} from "./custom.js"
import type { Drafts } from "./draft.js"
import { MAX_ROWS } from "./limits.js"
import { complete, hintsFor } from "./models.js"
import { isFastaFile, parseFile, type SequenceKind, summary } from "./sequences.js"
import {
    allFamilies,
    DEFAULT_LIMIT,
    type EntryKind,
    family,
    familyArg,
    type PolymerFamily,
    polymerBasis,
    type SoluteEntry,
    search,
} from "./solute-index.js"
import { bufferRow, type Solute, setField } from "./solutes.js"

// Re-exported: the add flow API the screens use.
export { bufferRow, formatNumber, numberText, type Parsed, tooLong }

// ---- limits and wording ---------------------------------------------------------------

/** The most characters of a name typed in the dropdown. */
export const MAX_NAME_TYPED = 60

/** The most characters of a path typed. */
export const MAX_PATH_TYPED = 300

/** The most characters a cell takes. */
export const MAX_CELL_TYPED = 60

/** The most rows a dropdown has, its status row included. */
export const DROPDOWN_ROWS = 8

/** The room a dropdown line keeps at the right for the tag, a space included. */
const TAG_ROOM = 7

/**
 * What the status row says when a typed name finds nothing. `^e` is a key of the GLOBAL
 * settings (main menu > settings), not of a project's own settings, so the way there is
 * spelled out; 40 characters is what the row holds.
 */
export const NO_MATCH = "no match (custom: main menu>settings>^e)"

/**
 * The columns of the table, by the field typed into each: the order of the art, which is
 * what `Cell.column` indexes.
 */
export const COLUMNS = ["name", "mM", "sigmaMM", "params"] as const

/** A field of a row that the flow types into. */
export type EditField = (typeof COLUMNS)[number]

/** How a field is called to the user in a prompt. */
const FIELD_LABELS: Readonly<Record<EditField, string>> = {
    name: "name",
    mM: "mM",
    sigmaMM: "±",
    params: "params",
}

/** The note of a sequence row being edited: the sequence is not edited, it is re-added. */
const RE_ADD_NOTE = "re-add to change the sequence"

/** The kinds of sequence a row can be, whose `arg` is a sequence. */
const SEQUENCE_KINDS: ReadonlySet<string> = new Set(["dna", "rna", "protein"])

/**
 * The choice `^e` asks first: the label shown and the sequence kind it stands for.
 */
export const NUCLEOTIDE_KINDS: readonly (readonly [string, SequenceKind])[] = [
    ["DNA", "dna"],
    ["RNA", "rna"],
]

// ---- numbers --------------------------------------------------------------------------

/**
 * What the text typed for a field comes to. A concentration must be above 0, an
 * uncertainty 0 or more.
 *
 * @param field - the field typed into.
 * @param text - the text typed.
 * @returns the trimmed name or the number, or an error: `name needed`,
 *   `a number, please`, `mM must be > 0`, `not below 0`.
 */
export function parseField(field: EditField, text: string): Parsed<string | number> {
    const t = text.trim()
    if (field === "name") return t === "" ? { error: "name needed" } : { value: t }
    const x = numberText(t)
    if (x === undefined) return { error: "a number, please" }
    if (field === "mM" && !(x > 0)) return { error: "mM must be > 0" }
    if (x < 0) return { error: "not below 0" }
    return { value: x }
}

/** The count of units typed: a number above 0. */
function parseCount(text: string): Parsed<number> {
    const x = numberText(text.trim())
    if (x === undefined) return { error: "a number, please" }
    if (!(x > 0)) return { error: "must be > 0" }
    return { value: x }
}

/** Keeps `index` on a list of `n` entries after one step forward or back, wrapping. */
function cycle(index: number, n: number, delta: 1 | -1): number {
    return (((index + delta) % n) + n) % n
}

// ---- the dropdown of names ------------------------------------------------------------

/** The add keys that open the dropdown of names. */
export type NameKind = "nonbio" | "polymer"

/** Every add key. */
export type AddKind = NameKind | "protein" | "nucleotide"

/**
 * The kinds of index entry each dropdown lists: `^n` the non-biological solutes and the
 * custom non-biological ones, `^p` the polymer grades, the families and the custom
 * polymers.
 */
const NAME_KINDS: Readonly<Record<NameKind, ReadonlySet<EntryKind>>> = {
    nonbio: new Set<EntryKind>(["nonbiological", "custom-nonbio"]),
    polymer: new Set<EntryKind>(["polymer", "polymer-family", "custom-polymer"]),
}

/**
 * The short tag at the right of an entry.
 *
 * @param e - an entry of the search.
 * @returns `solute`, `polymer`, `family` or `custom`.
 */
export function entryTag(e: SoluteEntry): string {
    return e.kind === "polymer-family" ? "family" : e.tag
}

/**
 * The entries of the dropdown of an add key for a typed query: what `search` finds of the
 * kind of the key and nothing else.
 *
 * @param kind - `nonbio` (`^n`) or `polymer` (`^p`).
 * @param query - what is typed; a blank one finds nothing.
 * @param customs - the custom solutes to search too.
 * @returns the entries, best first, at most `DEFAULT_LIMIT`.
 */
export function entries(
    kind: NameKind,
    query: string,
    customs: readonly CustomEntry[] = [],
): SoluteEntry[] {
    return search(query, customs, DEFAULT_LIMIT, NAME_KINDS[kind])
}

/**
 * The text of an entry as a dropdown line `room` characters wide: its name (with an
 * ellipsis when it does not fit) and its tag at the right.
 *
 * @param e - the entry.
 * @param room - the width of the line.
 * @returns a line of exactly `room` cells.
 */
export function itemText(
    e: { name: string; kind?: string; tag: string },
    room: number,
): string {
    const n = Math.max(1, room - TAG_ROOM - 1)
    const name = String(e.name)
    const shown = displayWidth(name) > n ? `${takeWidth(name, n - 1)}…` : name
    const pad = " ".repeat(Math.max(0, n - displayWidth(shown)))
    const tag = e.kind === "polymer-family" ? "family" : e.tag
    return `${shown}${pad} ${" ".repeat(Math.max(0, TAG_ROOM - tag.length))}${tag}`
}

/**
 * The note for a polymer whose molarity has a basis.
 *
 * @param basis - `per monomer unit`, `per 1000 Da`, or none.
 * @returns `mM per monomer unit`, or `undefined` for no basis.
 */
export function basisNote(basis: string | null | undefined): string | undefined {
    return basis ? `mM ${basis}` : undefined
}

/**
 * Whether a dropdown opens below the cell on a row: when at least `DROPDOWN_ROWS` rows of
 * the window remain below it.
 *
 * @param row - the row of the cell in the window (0-based).
 * @param window - how many body rows the table shows.
 * @returns true for below, false for above.
 */
export function opensBelow(row: number, window: number): boolean {
    return window - 1 - row >= DROPDOWN_ROWS
}

/**
 * The line of the page (0-based) where a dropdown starts: under the cell, else above it.
 *
 * @param row - the row of the cell in the window.
 * @param window - how many body rows the table shows.
 * @param height - the lines of the dropdown.
 * @param top - the line where the body starts.
 * @returns the first line of the dropdown.
 */
export function boxTop(row: number, window: number, height: number, top: number): number {
    return opensBelow(row, window) ? top + row + 1 : top + row - height
}

/**
 * The note for the row under the cursor when nothing is open: the basis of a polymer's
 * molarity.
 *
 * @param s - the solute of the row.
 * @returns `mM per monomer unit` / `mM per 1000 Da`, or `undefined`.
 */
export function rowNote(s: Solute): string | undefined {
    return s.kind === "polymer" ? basisNote(polymerBasis(s.arg)) : undefined
}

// ---- the params of a row --------------------------------------------------------------

/** A number as the form templates write it: the characters a number is made of. */
const NUMBER_GROUP = "([-+0-9.eE]+)"

/** Escapes the characters of a text that mean something in a regular expression. */
function escapeRegex(text: string): string {
    return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

/** The pattern of the `arg` strings a form's template makes, a number for each `{key}`. */
function templateRegex(template: string): RegExp {
    const parts = template.split(/\{\w+\}/).map(escapeRegex)
    return new RegExp(`^${parts.join(NUMBER_GROUP)}$`, "i")
}

/** One form of one family with the pattern its `arg` strings have. */
interface FormPattern {
    fam: PolymerFamily
    formIndex: number
    keys: string[]
    regex: RegExp
}

/** The patterns of every form of every family; made when first needed. */
let cachedPatterns: FormPattern[] | undefined

/** The patterns of every form of every family. */
function formPatterns(): FormPattern[] {
    cachedPatterns ??= allFamilies().flatMap((fam) =>
        fam.forms.map((form, formIndex) => ({
            fam,
            formIndex,
            keys: form.args.map((a) => a.key),
            regex: templateRegex(form.template),
        })),
    )
    return cachedPatterns
}

/** The family and form a polymer row's `arg` was made from, with its values as written. */
export interface FamilyMatch {
    fam: PolymerFamily
    formIndex: number
    /** From an argument key to the text written in the `arg` (`PEG n=22`: n is "22"). */
    values: Record<string, string>
}

/**
 * The family and form a polymer row's `arg` was made from.
 *
 * @param arg - the `arg` of a row, or none.
 * @returns the match, or `undefined` for a grade or any other text.
 */
export function familyMatch(arg: string | null | undefined): FamilyMatch | undefined {
    const text = String(arg ?? "").trim()
    for (const { fam, formIndex, keys, regex } of formPatterns()) {
        const m = regex.exec(text)
        if (m)
            return {
                fam,
                formIndex,
                values: Object.fromEntries(keys.map((k, j) => [k, m[j + 1]])),
            }
    }
    return undefined
}

/**
 * The key=value text of the numbers of a family form: `n=22`, `nEO=100 nPO=65`.
 *
 * @param form - a form of a family.
 * @param values - from an argument key to its text; an argument it lacks shows as `key=`.
 * @returns the text.
 */
export function valuesText(
    form: { args: { key: string }[] },
    values: Readonly<Record<string, string | undefined>>,
): string {
    return form.args.map((a) => `${a.key}=${values[a.key] ?? ""}`).join(" ")
}

/**
 * The text of the counts of a custom polymer's units: `nA=100 nB=65` (a unit without a
 * count yet is left out).
 *
 * @param units - the units, with their labels.
 * @param counts - the counts, in the order of the units.
 * @returns the text.
 */
export function countsText(
    units: readonly { label?: string }[],
    counts: readonly number[],
): string {
    const n = Math.min(units.length, counts.length)
    const parts: string[] = []
    for (let k = 0; k < n; k++) parts.push(`n${units[k].label}=${formatNumber(counts[k])}`)
    return parts.join(" ")
}

/** What the params cell says of a solute and how it is aligned. */
export interface ParamsCell {
    text: string
    align: "left" | "center"
}

/**
 * What the params cell says of a solute: `n/a` centred for a non-biological solute, a
 * grade and a custom non-biological one; the key=value text, left, for a polymer family
 * and a custom polymer; the summary of the sequence for DNA, RNA and protein.
 *
 * @param s - the solute (not necessarily complete).
 * @param width - the room for text.
 * @returns the text and its alignment.
 */
export function paramsCell(
    s: Partial<Solute> & { kind: string },
    width: number,
): ParamsCell {
    const na: ParamsCell = { text: "n/a", align: "center" }
    if (s.kind === "polymer") {
        const m = familyMatch(s.arg)
        if (!m) return na
        return { text: valuesText(m.fam.forms[m.formIndex], m.values), align: "left" }
    }
    if (s.kind === "custom-polymer") {
        const units = (s.units ?? []) as { label?: string }[]
        const counts = (s.counts ?? []) as number[]
        return { text: countsText(units, counts), align: "left" }
    }
    if (SEQUENCE_KINDS.has(s.kind)) {
        return {
            text: summary(s.kind as SequenceKind, String(s.arg ?? ""), width),
            align: "left",
        }
    }
    return na
}

// ---- the arguments of the params cell -------------------------------------------------

/** The numbers of a polymer family's form, asked one at a time. */
interface FamilyContext {
    type: "family"
    fam: PolymerFamily
    formIndex: number
    /** The argument being typed. */
    k: number
    /** The arguments taken, by key. */
    values: Record<string, string>
    /** The old values of a row being edited, by key. */
    prefill: Record<string, string>
}

/** The count of each unit of a custom polymer, asked one at a time. */
interface CountsContext {
    type: "counts"
    /** The stored entry (an added row); none when an existing row's counts are re-typed. */
    entry?: PolymerEntry
    labels: string[]
    k: number
    counts: number[]
    prefill: string[]
}

/** What the params cell asks, and how far it is. */
type ParamsContext = FamilyContext | CountsContext

/** The context to type the params of a solute in; none when the row has none to type. */
function editableParams(s: Solute): ParamsContext | undefined {
    if (s.kind === "polymer") {
        const m = familyMatch(s.arg)
        if (!m) return undefined
        return {
            type: "family",
            fam: m.fam,
            formIndex: m.formIndex,
            k: 0,
            values: {},
            prefill: m.values,
        }
    }
    if (s.kind === "custom-polymer") {
        const units = (s.units ?? []) as { label?: string }[]
        const counts = (s.counts ?? []) as number[]
        return {
            type: "counts",
            labels: units.map((u) => String(u.label)),
            k: 0,
            counts: [],
            prefill: counts.map(formatNumber),
        }
    }
    return undefined
}

/** The arguments of the form a family context asks. */
function contextArgs(ctx: FamilyContext) {
    return ctx.fam.forms[ctx.formIndex].args
}

/** The prompt of the argument being typed: `units n`, `Mn (g/mol)`, `nA`. */
function ctxPrompt(ctx: ParamsContext): string {
    return ctx.type === "family" ? contextArgs(ctx)[ctx.k].prompt : `n${ctx.labels[ctx.k]}`
}

/** The text the argument being typed starts as: the old value when a row is edited. */
function ctxInitialText(ctx: ParamsContext): string {
    if (ctx.type === "family") return ctx.prefill[contextArgs(ctx)[ctx.k].key] ?? ""
    return ctx.prefill[ctx.k] ?? ""
}

/** What the params cell shows while `typed` is typed: the arguments taken, then it. */
function ctxShown(ctx: ParamsContext, typed: string): string {
    if (ctx.type === "family") {
        const args = contextArgs(ctx)
        const done = args.slice(0, ctx.k).map((a) => `${a.key}=${ctx.values[a.key]}`)
        return [...done, `${args[ctx.k].key}=${typed}`].join(" ")
    }
    const done = ctx.labels
        .slice(0, ctx.k)
        .map((l, j) => `n${l}=${formatNumber(ctx.counts[j])}`)
    return [...done, `n${ctx.labels[ctx.k]}=${typed}`].join(" ")
}

/**
 * What is wrong with a text as one argument of a family form. The other arguments stand
 * at a value that is always fine.
 */
function argProblem(ctx: FamilyContext, key: string, text: string): string | undefined {
    const dummy = Object.fromEntries(contextArgs(ctx).map((a) => [a.key, "1000"]))
    const r = familyArg(ctx.fam, ctx.formIndex, { ...dummy, [key]: text })
    return "error" in r ? r.error : undefined
}

// ---- the state ------------------------------------------------------------------------

/** What every state of the flow carries. */
interface Common {
    /** The table with the rows as the flow has made them. */
    table: Drafts<Solute>
    /** The row the flow is at (the table's cursor). */
    cursor: number
    /** The rows this add made: Escape drops them. Empty when an existing row is edited. */
    added: readonly number[]
    /** The cursor before the add, which Escape goes back to. */
    fromCursor: number
    /** What went wrong with the last event, as a short message. */
    problem?: string
}

/** The dropdown of names of `^n` and `^p` is open. */
export interface NameState extends Common {
    kind: "name"
    nameKind: NameKind
    customs: readonly CustomEntry[]
    /** What is typed. */
    query: string
    matches: SoluteEntry[]
    /** The highlighted entry. */
    index: number
}

/** A polymer family with several forms asks which one. */
export interface FormState extends Common {
    kind: "form"
    fam: PolymerFamily
    labels: string[]
    index: number
}

/** `^e` asks DNA or RNA. */
export interface NucleotideState extends Common {
    kind: "nuc"
    index: number
}

/** The path of a sequence file is typed. */
export interface PathState extends Common {
    kind: "path"
    seqKind: SequenceKind
    buffer: string
    /** The highlighted hint. */
    index: number
}

/** One cell is typed into. */
export interface EditState extends Common {
    kind: "edit"
    /** The row typed into. */
    i: number
    field: EditField
    /** What is typed (for a params cell, the argument being typed). */
    text: string
    /** The fields still to do after this one. */
    queue: readonly EditField[]
    /** The arguments of the params cell being typed. */
    ctx?: ParamsContext
    /** The context of the params field that comes next in the queue. */
    nextCtx?: ParamsContext
    /** The rows of a file, which get the same mM and +-. */
    batch?: readonly number[]
    /** A note to keep while mM is typed (`below 1000 counts as kDa`). */
    hint?: string
}

/** The flow is over: `table` and `cursor` are its result. */
export interface DoneState extends Common {
    kind: "done"
    /** Whether it was cancelled (the rows of the add are dropped) or stopped or ended. */
    cancelled: boolean
}

/** A state of the flow. */
export type AddState =
    | NameState
    | FormState
    | NucleotideState
    | PathState
    | EditState
    | DoneState

/** What the user does, as the screen forwards it. */
export type AddEvent =
    /** Enter: take the highlighted entry, the path, or the cell. */
    | { type: "submit" }
    /** Choose entry `index` of the dropdown (a click); the highlighted one when absent. */
    | { type: "pick"; index?: number }
    /** The typed text is now `text` (the whole text, as the screen's field holds it). */
    | { type: "text"; text: string }
    /** Up or down in a dropdown. */
    | { type: "move"; delta: 1 | -1 }
    /** Tab: complete the typed text to the highlighted entry or hint. */
    | { type: "complete" }
    /** Escape: drop the rows of the add; an edit stops and keeps what was taken. */
    | { type: "cancel" }
    /** What the desktop's file picker gave (`o` on an empty path). */
    | { type: "files"; result: { files: readonly string[] } | { problem: string } }

/** Where a prompt or a dropdown is drawn. */
export interface Cell {
    /** The row of the table. */
    row: number
    /** The column, an index of `COLUMNS`. */
    column: number
}

/** One line of a dropdown. */
export interface DropdownItem {
    text: string
    /** `solute`, `polymer`, `family` or `custom`; none for a form or a hint. */
    tag?: string
}

/** A dropdown is open under a cell. */
export interface DropdownStep {
    type: "dropdown"
    /** What is asked: `name`, `form`, `DNA or RNA`, `path`. */
    label: string
    cell: Cell
    /** What is typed; `undefined` when the dropdown is a choice with no typing. */
    typed?: string
    maxLength?: number
    items: DropdownItem[]
    /** The highlighted item. */
    index: number
    /** The text of the status row, when it is not the count of the items. */
    status?: string
    /** The border note: the basis of the highlighted entry's molarity. */
    note?: string
    /** Whether `o` on an empty text asks for the desktop's file picker. */
    filePicker?: boolean
    /** The message of the last event. */
    problem?: string
}

/** A cell is typed into. */
export interface PromptStep {
    type: "prompt"
    /** What is asked: `name`, `mM`, `±`, or the prompt of an argument (`units n`). */
    label: string
    cell: Cell
    /** The text being edited: the whole cell, or the argument of a params cell. */
    typed: string
    /** What the cell shows: `typed`, or every argument of a params cell. */
    shown: string
    maxLength: number
    /** The border note: an argument's prompt, the hint kept for mM, a reminder. */
    note?: string
    problem?: string
}

/** The flow is over. */
export interface DoneStep {
    type: "done"
    cancelled: boolean
    table: Drafts<Solute>
    cursor: number
    /** The rows this add made (empty after a cancel and for an edit). */
    added: readonly number[]
    problem?: string
}

/** What a screen draws. */
export type Step = DropdownStep | PromptStep | DoneStep

// ---- building states ------------------------------------------------------------------

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
            return formatNumber(s.mM)
        case "sigmaMM":
            return formatNumber(s.sigmaMM)
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
export function startAdd(
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
 * a polymer family or a custom polymer, mM, then +-.
 *
 * @param table - the table.
 * @param cursor - the row.
 * @returns the first state; done at once for no row or a row marked for removal.
 */
export function startEdit(table: Drafts<Solute>, cursor: number): AddState {
    const row = table.rows[cursor]
    const base: Common = { table, cursor, added: [], fromCursor: cursor }
    if (!row || row.removed) return finish(base, true)
    const ctx = editableParams(rowSolute(table, cursor))
    return openField(base, table, cursor, "name", {
        queue: [...(ctx ? (["params"] as const) : []), "mM", "sigmaMM"],
        nextCtx: ctx,
    })
}

// ---- the steps of the pick ------------------------------------------------------------

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
            if (rowProblem(bufferRow(probe as unknown as Solute))) {
                return { ...state, problem: "custom entry invalid" }
            }
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

// ---- the path of a sequence file ------------------------------------------------------

/**
 * What is wrong with a path as the sequence file to read.
 *
 * @param path - the path typed.
 * @returns a message of 22 characters at most: `type a path first!`, `use a full path`,
 *   `no such file`, `that is a folder`, `cannot read the file`; `undefined` when fine.
 */
export function pathProblem(path: string): string | undefined {
    if (path.trim() === "") return "type a path first!"
    if (!isAbsolute(path)) return "use a full path"
    let isFolder: boolean
    try {
        isFolder = statSync(path).isDirectory()
    } catch {
        return "no such file"
    }
    if (isFolder) return "that is a folder"
    try {
        accessSync(path, constants.R_OK)
    } catch {
        return "cannot read the file"
    }
    return undefined
}

/**
 * The names a typed path can go on with: folders, then the FASTA and FASTQ files.
 *
 * @param buffer - the path typed.
 * @returns the hints (see `hintsFor` of ./models.ts).
 */
export function pathHints(buffer: string): string[] {
    return hintsFor(buffer, isFastaFile)
}

/** The state after Enter on the path typed: the file is read and its rows added. */
function pathEnter(state: PathState): AddState {
    // a typed or pasted path may end in blanks or a newline
    const path = state.buffer.trim()
    const problem = pathProblem(path)
    if (problem) return { ...state, problem }
    const parsed = parseFile(path, state.seqKind)
    if ("error" in parsed) return { ...state, problem: parsed.error }
    const existing = state.table.length - state.added.length
    if (existing + parsed.records.length > MAX_ROWS) {
        return { ...state, problem: `over ${MAX_ROWS} rows` }
    }
    const file = basename(path)
    const [first, ...rest] = parsed.records.map(
        (r): Solute => ({
            kind: state.seqKind,
            name: r.id,
            arg: r.letters,
            source: file,
            record: r.id,
            mM: null,
            sigmaMM: null,
        }),
    )
    const i = state.added[0]
    const table = state.table.set(i, first).add(...rest)
    const idx = [...Array(parsed.records.length).keys()].map((k) => i + k)
    return openField({ ...state, added: idx }, table, i, "mM", {
        queue: ["sigmaMM"],
        batch: idx,
    })
}

// ---- editing a cell -------------------------------------------------------------------

/** The table with a field of every row of a batch (or of row `i`) set. */
function setBatchField(
    table: Drafts<Solute>,
    state: EditState,
    field: string,
    value: unknown,
): Drafts<Solute> {
    return (state.batch ?? [state.i]).reduce((t, j) => setField(t, j, field, value), table)
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
        const table = setField(state.table, state.i, "arg", result.arg)
        return nextField(state, table, { hint: result.note })
    }
    const parsed = parseCount(state.text)
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
    const parsed = parseField(state.field, state.text)
    if ("error" in parsed) return { ...state, problem: parsed.error }
    const table = setBatchField(state.table, state, state.field, parsed.value)
    return nextField(state, table, {
        hint: state.field === "mM" ? undefined : state.hint,
        nextCtx: state.nextCtx,
    })
}

// ---- the transitions ------------------------------------------------------------------

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
    const hints = pathHints(state.buffer)
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
            }))
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
export function advance(state: AddState, event: AddEvent): AddState {
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

// ---- what to draw ---------------------------------------------------------------------

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
    if (state.buffer === "") return "type a path, o: file picker"
    return hints.length === 0 ? "no hint" : undefined
}

/**
 * What a screen draws for a state.
 *
 * @param state - the state.
 * @returns a dropdown, a prompt, or done.
 */
export function view(state: AddState): Step {
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
            const hints = pathHints(state.buffer)
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
                label: params ? ctxPrompt(ctx) : FIELD_LABELS[state.field],
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
    get step(): Step {
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
    send(event: AddEvent): Step {
        this.current = advance(this.current, event)
        return this.step
    }
}
