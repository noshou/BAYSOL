// SPDX-License-Identifier: LGPL-3.0-or-later

// Solutes: the solute rows, the index and the wording. The vocabulary of the add flow
// (names dropdown, params of a row, states, events, steps) is in `./add-state.ts`.
//
// Contents:
//   1. Solute rows: a `Drafts<Solute>` table, the blank row, one field, the check at save
//   2. Index: the names of the built-in, polymer-family and custom solutes, and the search
//   3. Limits and wording
//   4. Numbers

import { lazy, lazyAsset, readAssetJson } from "../core/environment.js"
import {
    fold,
    type NumberRules,
    numberText,
    type Parsed,
    parseNumber,
    plainNumber,
} from "../core/terminal.js"
import type { BufferRow } from "./buffer.js"
import type { CustomEntry } from "./custom.js"
import type { Drafts, SequenceKind, } from "./lists.js"

// ========================================================================================
// 1. Solute rows
// ========================================================================================

// The solutes being edited, with what has not been saved. A table of solutes is a
// `Drafts<Solute>` (`./lists.ts`); the functions here add what is particular to solutes:
// the blank row of an add, editing one field, and the check at save. A solute is an
// object of one of the kinds of the buffer (`kind`, `name`, `arg`, `mM`, `sigmaMM` and
// the keys its kind needs); the screen builds them (the add flow) and this module only
// keeps them.


/**
 * A solute of the buffer. Only the fields every kind has are typed; the others (`z`,
 * `pmv`, `units`, ...) depend on the kind and travel along unchanged.
 */
export interface Solute {
    kind: string
    name: string
    arg: string
    /** The concentration in mM; `null` until typed. */
    mM: number | null
    /** The uncertainty of the concentration in mM; `null` until typed. */
    sigmaMM: number | null
    [field: string]: unknown
}

/**
 * A solute as the row of the buffer file: `sigmaMM` is written `sigmaMm` there.
 *
 * Two types describe a solute on purpose. [[Solute]] is the draft in a table: camelCase
 * (`sigmaMM`), `null` for what is not typed yet, and no obligation to be complete.
 * `BufferRow` of ./buffer.ts is the row of the file, with the spelling the Julia loader
 * reads (`"sigmaMm"`) and every number given. This adapter is the one place that
 * turns the first into the second (the check of the file, `rowProblem`, runs on its
 * result), so no other module spells a key twice.
 *
 * @returns the row, as `rowProblem` and `writeSolutes` of ./buffer.ts take it.
 */
export function bufferRow(s: Solute): Record<string, unknown> {
    const { sigmaMM, ...rest } = s
    return { ...rest, "sigmaMm": sigmaMM }
}

/**
 * A row of a buffer file as the draft a table edits: `sigmaMm` becomes
 * `sigmaMM`, the one renaming, which [[rowOf]] undoes. Every other key travels along.
 */
export function soluteOf(row: BufferRow): Solute {
    const { "sigmaMm": sigmaMM, ...rest } = row as BufferRow & Record<string, unknown>
    return { ...rest, sigmaMM } as unknown as Solute
}

/**
 * A draft of a table as the row the file gets (what `writeSolutes` takes).
 *
 * @returns the row; it is only as valid as the draft, so check it first
 *     (`soluteProblem` of the screens).
 */
export function rowOf(s: Solute): BufferRow {
    return bufferRow(s) as unknown as BufferRow
}

/** Tells what a buffer row lacks for the Julia loader (the check of the buffer file). */
export type RowProblem = (row: Solute) => string | undefined

/**
 * The state with one field of row `i` set. The name is a label: the row's `arg` is not
 * touched. A row set back to what was saved has no draft.
 *
 * @throws RangeError for a row that is not there.
 */
export function setSoluteField(
    state: Drafts<Solute>,
    i: number,
    field: string,
    value: unknown,
): Drafts<Solute> {
    const current = state.value(i)
    if (!current) throw new RangeError(`no row ${i}`)
    return state.set(i, { ...current, [field]: value })
}

/**
 * What is missing in a solute, as a short message.
 *
 * @returns `"name needed"`, `"mM must be > 0"`, `"±mM needed"`, `"row incomplete"`, or
 *   `undefined` for a complete solute.
 */
export function draftProblem(s: Solute, rowProblem: RowProblem): string | undefined {
    if (s.name.trim() === "") return "name needed"
    if (!(typeof s.mM === "number" && s.mM > 0)) return `${concUnit()} must be > 0`
    if (!(typeof s.sigmaMM === "number" && s.sigmaMM >= 0)) return `±${concUnit()} needed`
    if (rowProblem(s)) return "row incomplete"
    return undefined
}

/**
 * What makes two rows the same solute: the kind and the solute BAYSOL resolves the row to
 * (the bundled table's name of an `arg`, a custom entry's name, the letters of a sequence),
 * case and outer blanks ignored. `chloride` and `cl-` are one solute; `sodium chloride`,
 * `chloride` and `sodium(1+)` are three; two polymer grades are two.
 *
 * @param s - the row.
 * @returns the key, `undefined` for a row that has no name yet.
 */
export function sameSoluteKey(s: Solute): string | undefined {
    const text = String(s.kind.startsWith("custom") ? (s.custom ?? s.name) : s.arg).trim()
    if (text === "") return undefined
    const resolved = s.kind === "nonbiological" || s.kind === "polymer"
        ? (resolveBuiltin(text)?.target ?? text)
        : text
    return `${s.kind}|${fold(resolved)}`
}

/**
 * The message when a row is a solute that another row of the table is already: `NAME
 * already in the buffer (as FIRST)`. Rows marked to be removed do not count.
 *
 * @param table - the table.
 * @param candidate - the row about to be set.
 * @param skip - the indices of rows to leave out (the row being made or edited).
 * @returns the message, `undefined` when it is a new solute.
 */
export function duplicateMessage(
    table: Drafts<Solute>,
    candidate: Solute,
    skip: readonly number[] = [],
): string | undefined {
    const key = sameSoluteKey(candidate)
    if (key === undefined) return undefined
    for (let i = 0; i < table.length; i++) {
        if (skip.includes(i) || table.rows[i].removed) continue
        const other = table.value(i) as Solute
        if (sameSoluteKey(other) === key) {
            return `${candidate.name} already in the buffer (as ${other.name})`
        }
    }
    return undefined
}

/**
 * The first row that is a solute an earlier row is already.
 *
 * @param state - the table.
 * @returns `[row index, message]`, `undefined` when every solute is there once.
 */
export function firstDuplicate(state: Drafts<Solute>): [number, string] | undefined {
    const seen = new Map<string, string>()
    for (let i = 0; i < state.length; i++) {
        if (state.rows[i].removed) continue
        const s = state.value(i) as Solute
        const key = sameSoluteKey(s)
        if (key === undefined) continue
        const first = seen.get(key)
        if (first !== undefined) return [i, `${s.name} already in the buffer (as ${first})`]
        seen.set(key, s.name)
    }
    return undefined
}

/**
 * The first problem of the rows that stay at the next save.
 *
 * @returns `[row index, message]`, or `undefined` when every row that stays is complete.
 */
export function firstProblem(
    state: Drafts<Solute>,
    rowProblem: RowProblem,
): [number, string] | undefined {
    for (let i = 0; i < state.length; i++) {
        if (state.rows[i].removed) continue
        const message = draftProblem(state.value(i) as Solute, rowProblem)
        if (message) return [i, message]
    }
    return undefined
}

// ========================================================================================
// 2. Index
// ========================================================================================

// The names of every solute BAYSOL knows, for the autocomplete of the buffer page: the
// index file `assets/data/solute_index.json` (written by the harvest tool from the Julia
// tables), the polymer families of `polymer_families.json` and the custom solutes of the
// user. The index is read once, when first needed, and turned into one sorted array and
// one lookup table, so that a search (run on every keystroke) only scans strings.
//
// Names are matched case-insensitively, as the Julia code lowercases them.


/** How many results `search` gives at most. */
export const DEFAULT_LIMIT = 200

/** The kinds of a search result: what the buffer row built from it will be. */
export type EntryKind =
    | "nonbiological"
    | "polymer"
    | "polymer-family"
    | "custom-nonbio"
    | "custom-polymer"

/** The badge a result carries in the dropdown. */
type EntryTag = "solute" | "polymer" | "custom"

/**
 * One result of `search`.
 *
 * - `name`: the text to show, the name as typed in the index (lower case) or a custom
 *   solute's own name;
 * - `target`: what the buffer row takes: the lower-case IUPAC name (`nonbiological`),
 *   the grade (`polymer`), the family id (`polymer-family`, which also has `family`),
 *   the custom name;
 * - `basis`: what a polymer's molarity is per; `null` for per mole of chains and for
 *   everything that is no polymer.
 */
export interface SoluteEntry {
    name: string
    kind: EntryKind
    target: string
    tag: EntryTag
    basis: string | null
    family?: string
    entry?: CustomEntry
}

/** One kind's section of `solute_index.json`: names point into the list of targets. */
interface IndexSection {
    targets: string[]
    names: [string, number][]
    basis?: Record<string, string>
}

/** The shape of `solute_index.json`: the families are `[typed name, family id]` pairs. */
interface IndexFile {
    nonbiological: IndexSection
    polymers: IndexSection
    families: [string, string][]
}

/** One argument of a family form: `{key}` in the template, with a lower bound. */
interface FamilyArgument {
    key: string
    min?: number
    prompt: string
}

/** One way to write a family: a template with `{key}` placeholders and its arguments. */
interface FamilyForm {
    template: string
    args: FamilyArgument[]
}

/** A polymer family of `polymer_families.json`. */
export interface PolymerFamily {
    id: string
    label: string
    names: string[]
    forms: FamilyForm[]
}

/** The result of `familyArg`: the buffer row's `arg`, maybe a note, or an error. */
export type FamilyArgResult = { arg: string; note?: string } | { error: string }

/** The built-in entries, sorted, with a lookup by name; built on first use. */
interface Index {
    entries: SoluteEntry[]
    byName: Map<string, SoluteEntry>
    basisByTarget: Map<string, string>
}

/**
 * Orders names by length, then alphabetically (by UTF-16 code unit, like the Clojure
 * original; never by locale, which would depend on the machine).
 */
function byLengthThenName(a: string, b: string): number {
    if (a.length !== b.length) return a.length - b.length
    return a < b ? -1 : a > b ? 1 : 0
}

/** The entries of one section of the index file, as search results. */
function sectionEntries(
    kind: EntryKind,
    tag: EntryTag,
    section: IndexSection,
): SoluteEntry[] {
    return section.names.map(([name, position]) => {
        const target = section.targets[position]
        return { name, kind, target, tag, basis: section.basis?.[target] ?? null }
    })
}

/** The sorted entries and lookup tables, read from the index file on first use. */
const index: () => Index = lazy(() => {
    const data = readAssetJson<IndexFile>("data", "solute_index.json")
    const families: SoluteEntry[] = data.families.map(([name, id]) => ({
        name,
        kind: "polymer-family",
        target: id,
        family: id,
        tag: "polymer",
        basis: null,
    }))
    // The families come last before the (stable) sort, so that a family wins over a
    // grade of the same name in `byName`, as it did in the Clojure.
    const entries = [
        ...sectionEntries("nonbiological", "solute", data.nonbiological),
        ...sectionEntries("polymer", "polymer", data.polymers),
        ...families,
    ].sort((a, b) => byLengthThenName(a.name, b.name))
    const byName = new Map<string, SoluteEntry>()
    const basisByTarget = new Map<string, string>()
    for (const entry of entries) {
        byName.set(entry.name, entry)
        if (entry.kind === "polymer" && entry.basis) {
            basisByTarget.set(entry.target, entry.basis)
        }
    }
    return { entries, byName, basisByTarget }
})

/**
 * The built-in entry of a typed name.
 *
 * @returns the entry as `search` gives it, or `undefined` for an unknown name.
 */
export function resolveBuiltin(typed: string): SoluteEntry | undefined {
    return index().byName.get(fold(typed))
}

/** Whether a typed text names a built-in solute, polymer grade or family. */
export function isBuiltinName(typed: string): boolean {
    return resolveBuiltin(typed) !== undefined
}

/**
 * What the molarity of a built-in polymer grade is per.
 *
 * @returns `"per monomer unit"` or `"per 1000 Da"`; `undefined` for a grade that is per
 *   mole of chains, for a family string (`PEG n=22`) and for anything else.
 */
export function polymerBasis(target: string | null | undefined): string | undefined {
    return index().basisByTarget.get(fold(target))
}

/** The search result of a custom solute. */
function customEntry(solute: CustomEntry): SoluteEntry {
    const name = String(solute.name)
    return {
        name,
        kind: solute.kind === "nonbiological" ? "custom-nonbio" : "custom-polymer",
        target: name,
        tag: "custom",
        basis: null,
        entry: solute,
    }
}

/** The group of a folded name for a folded query: 0 exact, 1 starts with, 2 contains. */
function rank(low: string, query: string): 0 | 1 | 2 | undefined {
    if (low === query) return 0
    if (low.startsWith(query)) return 1
    if (low.includes(query)) return 2
    return undefined
}

/**
 * The entries whose name matches a query, best first: the exact match, the names that
 * start with the query, the names that contain it; each group by length, then
 * alphabetically. Custom solutes match by name like the built-in ones and rank with them.
 *
 * @param query - what the user typed; case and outer spaces do not matter.
 */
export function search(
    query: string,
    customs: readonly CustomEntry[] = [],
    limit: number = DEFAULT_LIMIT,
    kinds?: ReadonlySet<EntryKind>,
): SoluteEntry[] {
    const q = fold(query)
    if (q === "") return []
    // The built-in names are folded already, so every name is ranked the same way
    const ranked = [...index().entries, ...customs.map(customEntry)].flatMap((entry) => {
        const name = fold(entry.name)
        const group = rank(name, q)
        return group === undefined ? [] : [{ entry, group, name }]
    })
    // Stable: on a tie the built-in entry stays first.
    ranked.sort((a, b) => a.group - b.group || byLengthThenName(a.name, b.name))
    return ranked
        .map((r) => r.entry)
        .filter((entry) => !kinds || kinds.has(entry.kind))
        .slice(0, limit)
}

/** The polymer families of `polymer_families.json`. */
export const allFamilies: () => readonly PolymerFamily[] = lazyAsset(
    "data",
    "polymer_families.json",
)

/** One polymer family. */
export function family(id: string): PolymerFamily | undefined {
    return allFamilies().find((f) => f.id === id)
}

/** The families whose molar mass form takes kDa below 1000 (the Julia code's rule). */
const KDA_FAMILIES: ReadonlySet<string> = new Set(["dextran", "glucan"])

/** The key of the molar-mass argument, which the kDa rule applies to. */
const MOLAR_MASS_KEY = "Mn"

/** A molar mass below this (g/mol) is read as kDa by the families in `KDA_FAMILIES`. */
const KDA_BELOW = 1000

/** The note that goes with a molar mass read as kDa. */
const KDA_NOTE = "below 1000 counts as kDa"

/** The finite number typed as `x` (a number or text), else `undefined`. */
function toNumber(x: unknown): number | undefined {
    if (typeof x === "number") return Number.isFinite(x) ? x : undefined
    return numberText(String(x ?? "").trim())
}

/**
 * The `arg` of a buffer row for a family form: the form's template with every `{key}`
 * replaced by the typed value.
 *
 * @param values - from an argument key (`"n"`, `"nEO"`) to the typed text or number.
 * @returns `{ arg: "PEG n=22" }`; for a molar mass of dextran or pullulan below 1000 also
 *   a `note` (it counts as kDa). `{ error }` when a value is no number, not above 0 or
 *   below the form's `min`, or the form does not exist.
 */
export function familyArg(
    fam: PolymerFamily,
    formIndex: number,
    values: Readonly<Record<string, string | number | undefined>>,
): FamilyArgResult {
    const form = fam.forms[formIndex]
    if (!form) return { error: "no such form" }
    let arg = form.template
    let note: string | undefined
    for (const a of form.args) {
        const v = toNumber(values[a.key])
        if (v === undefined) return { error: `${a.key}: not a number` }
        if (!(v > 0)) return { error: `${a.key}: must be above 0` }
        if (a.min !== undefined && v < a.min) {
            return { error: `${a.key}: at least ${a.min}` }
        }
        arg = arg.replaceAll(`{${a.key}}`, () => plainNumber(v))
        const kda = KDA_FAMILIES.has(fam.id) && a.key === MOLAR_MASS_KEY && v < KDA_BELOW
        if (!note && kda) {
            note = KDA_NOTE
        }
    }
    return note ? { arg, note } : { arg }
}

// ========================================================================================
// 3. Limits and wording
// ========================================================================================

/** The most characters of a name typed in the dropdown. */
export const MAX_NAME_TYPED = 60

/** The most characters a cell takes. */
export const MAX_CELL_TYPED = 60

/**
 * What the status row says when a typed name finds nothing: custom solutes are made in
 * the buffer landing's `custom solutes` table. 40 characters is what the row holds.
 */
export const NO_MATCH = "no match (custom: buffer>custom solutes)"

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

/** The prompt label of a field: a concentration and its ± carry the unit shown. */
export function fieldLabel(field: EditField): string {
    if (field === "mM") return concUnit()
    return field === "sigmaMM" ? `±${concUnit()}` : FIELD_LABELS[field]
}

/** The note of a sequence row being edited: the sequence is not edited, it is re-added. */
export const RE_ADD_NOTE = "re-add to change the sequence"

/** The kinds of sequence a row can be, whose `arg` is a sequence. */
export const SEQUENCE_KINDS: ReadonlySet<string> = new Set(["dna", "rna", "protein"])

/**
 * The choice `^e` asks first: the label shown and the sequence kind it stands for.
 */
export const NUCLEOTIDE_KINDS: readonly (readonly [string, SequenceKind])[] = [
    ["DNA", "dna"],
    ["RNA", "rna"],
]

// ========================================================================================
// 4. Numbers
// ========================================================================================

/**
 * What the text typed for a field comes to. A concentration must be above 0, an
 * uncertainty 0 or more.
 *
 * @param field - the field typed into.
 * @param text - the text typed.
 * @returns the trimmed name or the number, or an error: `name needed`,
 *   `a number, please`, `mM must be > 0`, `not below 0`.
 */
export function parseAddField(field: EditField, text: string): Parsed<string | number> {
    if (field === "name") {
        const t = text.trim()
        return t === "" ? { error: "name needed" } : { value: t }
    }
    const rules = field === "mM" ? concentrationRules() : UNCERTAINTY_RULES
    const parsed = parseNumber(text, rules)
    return "error" in parsed ? parsed : { value: fromShown(parsed.value) }
}

/** A concentration is a number above 0 (in the unit shown). */
const concentrationRules = (): NumberRules => ({
    above: { limit: 0, message: `${concUnit()} must be > 0` },
})

/** The units a concentration is shown and typed in, in the order `^k` turns them. */
export const CONC_UNITS = ["mM", "M", "µM"] as const

/** A unit of [[CONC_UNITS]]. */
export type ConcUnit = (typeof CONC_UNITS)[number]

/** The powers of ten from the stored mM to a unit. */
const UNIT_SHIFT: Readonly<Record<ConcUnit, number>> = { mM: 0, M: -3, µM: 3 }

/** The unit now shown (kept while the program runs; nothing is written to a file). */
let shownUnit: ConcUnit = "mM"

/** @returns the unit the concentrations are shown and typed in. */
export function concUnit(): ConcUnit {
    return shownUnit
}

/** Sets the unit shown (`mM` is what the file holds). */
export function setConcUnit(unit: ConcUnit): void {
    shownUnit = unit
}

/** Turns to the next unit: mM, M, µM, mM. @returns the unit now shown. */
export function nextConcUnit(): ConcUnit {
    shownUnit = CONC_UNITS[(CONC_UNITS.indexOf(shownUnit) + 1) % CONC_UNITS.length]
    return shownUnit
}

/**
 * `x` times 10 to the `k`, by shifting the decimal exponent of its shortest text, so a
 * round trip loses nothing (137 mM is 137000 µM and back, exactly).
 */
function shiftDecimal(x: number, k: number): number {
    const m = /^(-?[\d.]+)(?:e([+-]\d+))?$/.exec(String(x))
    return m ? Number(`${m[1]}e${Number(m[2] ?? 0) + k}`) : x
}

/** A concentration from the stored mM to the unit shown. */
export function toShown(mM: number, unit: ConcUnit = shownUnit): number {
    return shiftDecimal(mM, UNIT_SHIFT[unit])
}

/** A concentration typed in the unit shown to the stored mM. */
export function fromShown(v: number, unit: ConcUnit = shownUnit): number {
    return shiftDecimal(v, -UNIT_SHIFT[unit])
}

/**
 * A stored concentration (or its uncertainty) as text in the unit shown: plain decimals
 * (`plainNumber`) when they fit `width`, else scientific with the most digits that fit
 * (`1.37e-1`, `6.85e3`, `3e-7`; no `+`, the exponent of one digit or more), at least one
 * digit. Without `width` it is plain and exact (what an edit starts from). The text is
 * a number `parseNumber` takes.
 */
export function formatConc(
    mM: number | null | undefined,
    unit: ConcUnit = shownUnit,
    width?: number,
): string {
    if (mM === null || mM === undefined) return ""
    const v = toShown(mM, unit)
    const plain = plainNumber(v)
    if (width === undefined || plain.length <= width) return plain
    const sci = (d?: number) => v.toExponential(d).replace("e+", "e")
    let text = sci()
    const mantissa = text.slice(0, text.indexOf("e"))
    const point = mantissa.indexOf(".")
    const decimals = point < 0 ? 0 : mantissa.length - point - 1
    for (let d = decimals - 1; d >= 0 && text.length > width; d--) text = sci(d)
    return text
}

/** An uncertainty is a number, 0 or more. */
const UNCERTAINTY_RULES: NumberRules = { atLeast: { limit: 0, message: "not below 0" } }

/** Keeps `index` on a list of `n` entries after one step forward or back, wrapping. */
export function cycle(index: number, n: number, delta: 1 | -1): number {
    return (((index + delta) % n) + n) % n
}
