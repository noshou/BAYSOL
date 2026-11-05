// SPDX-License-Identifier: LGPL-3.0-or-later

// The names of every solute BAYSOL knows, for the autocomplete of the buffer page: the
// index file `assets/data/solute_index.json` (written by the harvest tool from the Julia
// tables), the polymer families of `polymer_families.json` and the custom solutes of the
// user. The index is read once, when first needed, and turned into one sorted array and
// one lookup table, so that a search (run on every keystroke) only scans strings.
//
// Names are matched case-insensitively, as the Julia code lowercases them.

import { readAssetJson } from "../core/assets.js"
import { fold, numberText, plainNumber } from "../core/text.js"
import type { CustomEntry } from "./custom.js"

// Re-exported: the path the screens and the other stores have always imported them by.
export { fold, plainNumber }

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
export type EntryTag = "solute" | "polymer" | "custom"

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
export interface FamilyArgument {
    key: string
    min?: number
    prompt: string
}

/** One way to write a family: a template with `{key}` placeholders and its arguments. */
export interface FamilyForm {
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

let cachedIndex: Index | undefined
let cachedFamilies: PolymerFamily[] | undefined

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

/** Reads the index file and builds the sorted entries and the lookup tables. */
function buildIndex(): Index {
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
}

/** The index, built on the first call (a keystroke never pays for the file twice). */
function index(): Index {
    cachedIndex ??= buildIndex()
    return cachedIndex
}

/**
 * The built-in entry of a typed name.
 *
 * @param typed - a name or an alias, in any case, with outer spaces.
 * @returns the entry as `search` gives it, or `undefined` for an unknown name.
 */
export function resolveBuiltin(typed: string): SoluteEntry | undefined {
    return index().byName.get(fold(typed))
}

/**
 * Whether a typed text is a name or alias of a built-in solute, polymer grade or family.
 *
 * @param typed - the text.
 * @returns true for a built-in name.
 */
export function isBuiltinName(typed: string): boolean {
    return resolveBuiltin(typed) !== undefined
}

/**
 * What the molarity of a built-in polymer grade is per.
 *
 * @param target - a buffer row's `arg`, in any case.
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
 * @param customs - the custom solutes to search too.
 * @param limit - how many results at most.
 * @param kinds - when given, only entries of these kinds are returned.
 * @returns the results; a blank query gives none.
 */
export function search(
    query: string,
    customs: readonly CustomEntry[] = [],
    limit: number = DEFAULT_LIMIT,
    kinds?: ReadonlySet<EntryKind>,
): SoluteEntry[] {
    const q = fold(query)
    if (q === "") return []
    // One pass over the sorted entries: each group stays in index order, which is the
    // order the result wants (length, then alphabet).
    const groups: SoluteEntry[][] = [[], [], []]
    for (const entry of index().entries) {
        const g = rank(entry.name, q)
        if (g !== undefined) groups[g].push(entry)
    }
    if (customs.length > 0) {
        const extra: SoluteEntry[][] = [[], [], []]
        for (const solute of customs) {
            const entry = customEntry(solute)
            const g = rank(fold(entry.name), q)
            if (g !== undefined) extra[g].push(entry)
        }
        for (const g of [0, 1, 2]) {
            if (extra[g].length === 0) continue
            // Stable: on a tie the built-in entry stays first.
            groups[g] = [...groups[g], ...extra[g]].sort((a, b) => {
                const lengths = a.name.length - b.name.length
                if (lengths !== 0) return lengths
                return byLengthThenName(fold(a.name), fold(b.name))
            })
        }
    }
    const result: SoluteEntry[] = []
    for (const entry of groups.flat()) {
        if (kinds && !kinds.has(entry.kind)) continue
        result.push(entry)
        if (result.length >= limit) break
    }
    return result
}

/**
 * The polymer families of `polymer_families.json`.
 *
 * @returns the families, in file order.
 */
export function allFamilies(): readonly PolymerFamily[] {
    cachedFamilies ??= readAssetJson<PolymerFamily[]>("data", "polymer_families.json")
    return cachedFamilies
}

/**
 * One polymer family.
 *
 * @param id - the family id, `"peg"`.
 * @returns the family, or `undefined` for another id.
 */
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
 * @param fam - the family, as `family` gives it.
 * @param formIndex - which of the family's forms.
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
