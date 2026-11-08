// SPDX-License-Identifier: LGPL-3.0-or-later

// The vocabulary of the add flow: the dropdown of names, the params of a row (a polymer
// family's numbers, a custom polymer's counts), and the states, events and steps of
// `./add-flow.ts`, which holds the transitions. Split from `./solutes.ts` (the rows, the
// index, the wording) to keep every file under 1,000 lines.
//
// Contents:
//   5. The dropdown of names
//   6. The params of a row
//   7. The arguments of the params cell
//   8. The state

import { formatNumber, type NumberRules } from "../core/terminal.js"
import type { CustomEntry } from "./custom.js"
import {
    type Drafts,
    type SequenceKind,
    type SequenceRecords,
    summary,
} from "./lists.js"
import type { PolymerEntry } from "./polymers.js"
import {
    allFamilies,
    concUnit,
    DEFAULT_LIMIT,
    type EditField,
    type EntryKind,
    familyArg,
    type PolymerFamily,
    polymerBasis,
    SEQUENCE_KINDS,
    type Solute,
    type SoluteEntry,
    search,
} from "./solutes.js"

// ========================================================================================
// 5. The dropdown of names
// ========================================================================================

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
 * The note for a polymer whose molarity has a basis.
 *
 * @param basis - `per monomer unit`, `per 1000 Da`, or none.
 * @returns `mM per monomer unit`, or `undefined` for no basis.
 */
export function basisNote(basis: string | null | undefined): string | undefined {
    return basis ? `${concUnit()} ${basis}` : undefined
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

// ========================================================================================
// 6. The params of a row
// ========================================================================================

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
function valuesText(
    form: { args: { key: string }[] },
    values: Readonly<Record<string, string | undefined>>,
): string {
    return form.args.map((a) => `${a.key}=${values[a.key] ?? ""}`).join(" ")
}

/**
 * The text of the counts of a custom polymer's units: `nA=100 nB=65` (a unit without a
 * count yet is left out).
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

// ========================================================================================
// 7. The arguments of the params cell
// ========================================================================================

/** The numbers of a polymer family's form, asked one at a time. */
export interface FamilyContext {
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
export interface CountsContext {
    type: "counts"
    /** The stored entry (an added row); none when an existing row's counts are re-typed. */
    entry?: PolymerEntry
    labels: string[]
    k: number
    counts: number[]
    prefill: string[]
}

/** What the params cell asks, and how far it is. */
export type ParamsContext = FamilyContext | CountsContext

/** The count of a unit: a number above 0. */
export const COUNT_RULES: NumberRules = { above: { limit: 0, message: "must be > 0" } }

/** The context to type the params of a solute in; none when the row has none to type. */
export function editableParams(s: Solute): ParamsContext | undefined {
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
export function contextArgs(ctx: FamilyContext) {
    return ctx.fam.forms[ctx.formIndex].args
}

/** The prompt of the argument being typed: `units n`, `Mn (g/mol)`, `nA`. */
export function ctxPrompt(ctx: ParamsContext): string {
    return ctx.type === "family" ? contextArgs(ctx)[ctx.k].prompt : `n${ctx.labels[ctx.k]}`
}

/** The text the argument being typed starts as: the old value when a row is edited. */
export function ctxInitialText(ctx: ParamsContext): string {
    if (ctx.type === "family") return ctx.prefill[contextArgs(ctx)[ctx.k].key] ?? ""
    return ctx.prefill[ctx.k] ?? ""
}

/** What the params cell shows while `typed` is typed: the arguments taken, then it. */
export function ctxShown(ctx: ParamsContext, typed: string): string {
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
export function argProblem(
    ctx: FamilyContext,
    key: string,
    text: string,
): string | undefined {
    const dummy = Object.fromEntries(contextArgs(ctx).map((a) => [a.key, "1000"]))
    const r = familyArg(ctx.fam, ctx.formIndex, { ...dummy, [key]: text })
    return "error" in r ? r.error : undefined
}


// ========================================================================================
// 8. The state
// ========================================================================================

/** What every state of the flow carries. */
export interface Common {
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
    /** The records of a pasted text, linted and waiting for Enter (the field is empty). */
    pasted?: SequenceRecords
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
    /** A text pasted that is not a field's (several lines, or longer than the field). */
    | { type: "paste"; text: string }
    | { type: "files"; result: { files: readonly string[] } | { problem: string } }

/** Where a prompt or a dropdown is drawn. */
interface Cell {
    /** The row of the table. */
    row: number
    /** The column, an index of `COLUMNS`. */
    column: number
}

/** One line of a dropdown. */
interface DropdownItem {
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
export type FlowStep = DropdownStep | PromptStep | DoneStep
