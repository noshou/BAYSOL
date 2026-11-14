// SPDX-License-Identifier: LGPL-3.0-or-later

// The custom solutes being edited, with what has not been saved: pure functions of a
// state, so none of it needs a terminal. A table of custom solutes is a
// `Drafts<CustomEntry>` (`./lists.ts`); the functions here add what is particular to
// custom solutes: the blank entry of each kind, editing one field, the checks (each told
// with the field it is about), the text the forms show and the snapshot a buffer row
// stores.
//
// An entry is one of two kinds (the schema is frozen in
// `test/fixtures/buffer/custom-solutes.json`; the keys keep their file spelling):
//
//   - a non-biological solute `{kind, name, formula, z, pmv, sigma}`;
//   - a polymer, a generic additive chain of 1 to 4 kinds of repeat unit: everything
//     particular to it (units, end groups, chain values, preview) is in `./polymers.ts`.
//
// A number the user has not given is `null` (a `sigma` of `null` is a blank: the
// defaults apply, where the Julia side resolves them).
//
// Contents:
//   1. The entries and the table state
//   2. The checks and the snapshot
//   3. The typed fields and what a cell shows
//   4. The custom solutes file

import { join } from "node:path"
import { isDict, type ReadOptions } from "../core/file-system.js"
import {
    fold,
    formatNumber,
    NAME_IN_USE,
    type NumberRules,
    type Parsed,
    parseNumber,
} from "../core/terminal.js"
import { type CustomNonbioRow, isNumber, type RowBase } from "./buffer.js"
import { type Drafts, ListFile } from "./lists.js"
import {
    blankPolymer,
    blankUnit,
    type EntryField,
    type FieldProblem,
    formatRounded,
    isNegative,
    MAX_LABEL,
    MAX_UNITS,
    type PolymerEntry,
    type PolymerSnapshot,
    polymerProblem,
    polymerSnapshot,
    type UnitField,
    zProblem,
} from "./polymers.js"

/** The most digits of a whole number typed for Z (it must fit a Julia `Int`). */
const MAX_Z_DIGITS = 9

/** What the preview says after a σ that is the fallback setting's. */
const FALLBACK_NOTE = "(fallback)"

/** The message a name that is a built-in solute, polymer grade or family gets. */
const BUILTIN_MESSAGE = "name is built-in"

// ========================================================================================
// 1. The entries and the table state
// ========================================================================================

/**
 * A custom non-biological solute.
 *
 * @property z - electrons, above 0 (or computed from `formula`).
 * @property pmv - the partial molar volume in cm³/mol, negative is fine for an ion.
 * @property sigma - its uncertainty, `null` for the fallback setting.
 */
export interface NonbioEntry {
    kind: "nonbiological"
    name: string
    formula: string
    z: number | null
    pmv: number | null
    sigma: number | null
}

/** An entry of `custom-solutes.json`, told apart by `kind`. */
export type CustomEntry = NonbioEntry | PolymerEntry

/** The kinds of custom entry. */
export type CustomKind = CustomEntry["kind"]

/** The state of a table of custom solutes: the entries with their drafts and marks. */
export type CustomState = Drafts<CustomEntry>

/** Says whether a name is a built-in solute, polymer grade or family. */
export type BuiltinName = (name: string) => boolean

// --- the blank entries

/** @returns a non-biological entry with nothing filled in. */
export function blankNonbio(): NonbioEntry {
    return { kind: "nonbiological", name: "", formula: "", z: null, pmv: null, sigma: null }
}

// --- the state

/**
 * The state with a new blank row of a kind at the end.
 *
 * @param state - the table.
 * @param kind - `nonbiological` or `polymer`.
 * @returns the new table.
 */
export function addEntry(state: CustomState, kind: CustomKind): CustomState {
    return state.add(kind === "polymer" ? blankPolymer() : blankNonbio())
}

/** Whether a field is a cell of a unit. */
function isUnitField(field: EntryField): field is UnitField {
    return typeof field === "object"
}

/**
 * The value of a field of an entry.
 *
 * @param e - the entry.
 * @param field - a top field, or the cell of a unit.
 * @returns the value (`undefined` for a field the kind of entry has not).
 */
export function getField(e: CustomEntry, field: EntryField): unknown {
    if (!isUnitField(field)) return (e as unknown as Record<string, unknown>)[field]
    return e.kind === "polymer" ? e.units[field.unit]?.[field.key] : undefined
}

/**
 * The entry with one field set.
 *
 * @param e - the entry.
 * @param field - a top field, or the cell of a unit.
 * @param v - the new value.
 * @returns a new entry.
 */
export function withField(e: CustomEntry, field: EntryField, v: unknown): CustomEntry {
    if (!isUnitField(field)) return { ...e, [field]: v } as CustomEntry
    if (e.kind !== "polymer") return e
    const units = e.units.map((u, i) => (i === field.unit ? { ...u, [field.key]: v } : u))
    return { ...e, units }
}

/**
 * The state with one field of row `i` set. A row set back to what was saved has no
 * draft.
 *
 * @param state - the table.
 * @param i - the row.
 * @param field - a top field, or the cell of a unit of a polymer.
 * @param v - the new value.
 * @returns the new table.
 * @throws RangeError for a row that is not there.
 */
export function setField(
    state: CustomState,
    i: number,
    field: EntryField,
    v: unknown,
): CustomState {
    const e = state.value(i)
    if (!e) throw new RangeError(`no row ${i}`)
    return state.set(i, withField(e, field, v))
}

/**
 * The state with a blank unit added at the end of the polymer in row `i`.
 *
 * @param state - the table.
 * @param i - the row (a polymer).
 * @returns the new table, unchanged when the polymer has [[MAX_UNITS]] already or the
 *     row is no polymer.
 * @throws RangeError for a row that is not there.
 */
export function addUnit(state: CustomState, i: number): CustomState {
    const e = state.value(i)
    if (!e) throw new RangeError(`no row ${i}`)
    if (e.kind !== "polymer" || e.units.length >= MAX_UNITS) return state
    return state.set(i, { ...e, units: [...e.units, blankUnit()] })
}

/**
 * The state with unit `j` of the polymer in row `i` removed.
 *
 * @param state - the table.
 * @param i - the row (a polymer).
 * @param j - the unit.
 * @returns the new table, unchanged when it is the only unit or the row is no polymer.
 * @throws RangeError for a row that is not there.
 */
export function removeUnit(state: CustomState, i: number, j: number): CustomState {
    const e = state.value(i)
    if (!e) throw new RangeError(`no row ${i}`)
    if (e.kind !== "polymer" || e.units.length <= 1) return state
    return state.set(i, { ...e, units: e.units.filter((_, k) => k !== j) })
}

// ========================================================================================
// 2. The checks and the snapshot
// ========================================================================================

// --- the checks, each told with the field it is about

/**
 * The first thing missing in an entry. Both kinds need a name. A non-biological solute
 * needs a formula that is understood or a Z above 0, a PMV (a number, negative is fine
 * for an ion) and a ± of 0 or more when given. A polymer needs, of each unit, a label, a
 * Z or formula as above, a slope and a ± of 0 or more when given; labels that differ
 * (`unit label used`, case-insensitively); the end groups (`end groups needed`: `zEnds`
 * and `pmvEnds`, no default) and `sigmaEnds` of 0 or more when given. Whether the name
 * is taken is for [[entryProblem]] and [[problems]], which see the other entries.
 *
 * @param e - the entry.
 * @returns the field and a message of 22 characters at most, or `undefined`.
 */
export function fieldProblem(e: CustomEntry): FieldProblem | undefined {
    if (e.name.trim() === "") return { field: "name", message: "name needed" }
    if (e.kind === "polymer") return polymerProblem(e)
    const z = zProblem(e)
    if (z) return z
    if (!isNumber(e.pmv)) return { field: "pmv", message: "PMV needed" }
    if (isNegative(e.sigma)) return { field: "sigma", message: "± not below 0" }
    return undefined
}

/**
 * What is missing in an entry, as a short message.
 *
 * @param e - the entry.
 * @returns the message of [[fieldProblem]], or `undefined`.
 */
export function fieldMessage(e: CustomEntry): string | undefined {
    return fieldProblem(e)?.message
}

/**
 * The first problem of an entry among others, for a form page, which sees one entry:
 * [[fieldProblem]], then a name that is built-in or that one of the other entries has,
 * case-insensitively.
 *
 * @param e - the entry.
 * @param builtin - says whether a name is built-in, or `undefined` for no such check.
 * @param otherNames - the names of the other entries.
 * @returns the field and message, or `undefined`.
 */
export function entryProblem(
    e: CustomEntry,
    builtin: BuiltinName | undefined,
    otherNames: readonly string[],
): FieldProblem | undefined {
    const own = fieldProblem(e)
    if (own) return own
    if (builtin?.(e.name)) return { field: "name", message: BUILTIN_MESSAGE }
    if (otherNames.some((n) => fold(n) === fold(e.name)))
        return { field: "name", message: NAME_IN_USE }
    return undefined
}

/**
 * The first problem of the rows that stay at the next save.
 *
 * @param state - the table.
 * @param builtin - says whether a name is built-in (`isBuiltinName` of the solute
 *     index); without it no name is checked against the built-in ones.
 * @returns `[row index, message]`, or `undefined`. A name that an earlier row has
 *     (case-insensitively) is `name in use`.
 */
export function problems(
    state: CustomState,
    builtin?: BuiltinName,
): [number, string] | undefined {
    const seen = new Set<string>()
    for (const [i, row] of state.rows.entries()) {
        if (row.removed) continue
        const e = state.value(i) as CustomEntry
        const key = fold(e.name)
        const message =
            fieldMessage(e) ??
            (builtin?.(e.name) ? BUILTIN_MESSAGE : undefined) ??
            (seen.has(key) ? NAME_IN_USE : undefined)
        if (message) return [i, message]
        seen.add(key)
    }
    return undefined
}

// --- the snapshot a buffer row stores

/** What a buffer row stores of a non-biological entry, without the row's own keys. */
export type NonbioSnapshot = Omit<CustomNonbioRow, keyof RowBase>

/**
 * What a buffer row stores of a stored entry, so the project never reads the global
 * file. A non-biological entry gives `{kind: "custom-nonbio", custom, z, pmv,
 * sigmaPmv}`; a polymer, with its counts, `{kind: "custom-polymer", custom, units,
 * zEnds, pmvEnds, sigmaEnds, counts}`, the units copied with just their keys. The
 * row's own `name`, `mM` and `sigmaMm` are for the caller to add. The entry must be
 * complete (see [[fieldProblem]]).
 *
 * @param entry - a stored entry.
 * @param counts - for a polymer, one number per unit, in the order of the units.
 * @returns the snapshot.
 * @throws Error for a polymer when `counts` is not one number per unit.
 */
export function snapshot(entry: NonbioEntry): NonbioSnapshot
export function snapshot(entry: PolymerEntry, counts: readonly number[]): PolymerSnapshot
export function snapshot(
    entry: CustomEntry,
    counts?: readonly number[],
): NonbioSnapshot | PolymerSnapshot {
    if (entry.kind === "nonbiological")
        return {
            kind: "custom-nonbio",
            custom: entry.name,
            z: entry.z as number,
            pmv: entry.pmv as number,
            "sigmaPmv": entry.sigma ?? null,
        }
    return polymerSnapshot(entry, counts ?? [])
}

// ========================================================================================
// 3. The typed fields and what a cell shows
// ========================================================================================

// --- the typed fields (shared by the table and the form pages)

/** A whole number as typed for Z: digits only, at most [[MAX_Z_DIGITS]] (zeros count). */
const WHOLE_RULES: NumberRules = { whole: true, maxDigits: MAX_Z_DIGITS, countZeros: true }

/** The Z of a unit or a non-biological solute: whole and above 0. */
const Z_RULES: NumberRules = {
    ...WHOLE_RULES,
    above: { limit: 0, message: "Z must be > 0" },
}

/** A ± is blank (the defaults apply) or a number, 0 or more. */
const SIGMA_RULES: NumberRules & { blank: true } = {
    blank:   true,
    atLeast: { limit: 0, message: "not below 0" },
}

/** The fields a form cell is typed for. */
export type ParseField =
    | "name"
    | "label"
    | "formula"
    | "z"
    | "zEnds"
    | "pmv"
    | "slope"
    | "pmvEnds"
    | "sigma"
    | "sigmaEnds"

/**
 * What the text typed for a field comes to. The name must not be blank; a label is one
 * word of at most [[MAX_LABEL]] characters; the formula is taken as typed (a polymer's
 * unit without a surrounding `( )n`); Z is a whole number above 0 (of the ends, 0 or
 * more); a PMV or slope a number (negative is fine); a ± blank (`null`) or 0 or more.
 *
 * @param field - the field.
 * @param text - the text typed.
 * @returns `{value}` or `{error}` with a message of 22 characters at most.
 */
export function parseField(
    field: ParseField,
    text: string,
): Parsed<string | number | null> {
    const t = text.trim()
    switch (field) {
        case "name":
            return t === "" ? { error: "name needed" } : { value: t }
        case "label":
            if (t === "") return { error: "label needed" }
            if (/\s/.test(t)) return { error: "one word, please" }
            if ([...t].length > MAX_LABEL)
                return { error: `at most ${MAX_LABEL} characters` }
            return { value: t }
        case "formula":
            return { value: t }
        case "zEnds":
            return parseNumber(t, WHOLE_RULES)
        case "z":
            return parseNumber(t, Z_RULES)
        case "sigma":
        case "sigmaEnds":
            return parseNumber(t, SIGMA_RULES)
        default:
            return parseNumber(t)
    }
}

/**
 * [[parseField]] for a cell of a form page, where a blank text is allowed and clears the
 * cell (the name, label and formula to `""`, the numbers to `null`): what is missing is
 * told when the form is accepted ([[fieldProblem]]), not as the cell is left.
 *
 * @param field - the field.
 * @param text - the text typed.
 * @returns `{value}` or `{error}`.
 */
export function parseCell(
    field: ParseField,
    text: string,
): Parsed<string | number | null> {
    if (text.trim() !== "") return parseField(field, text)
    const isText = field === "name" || field === "label" || field === "formula"
    return { value: isText ? "" : null }
}

// --- what a cell shows

/**
 * What the ± cell of a non-biological entry shows: its value, a blank as the fallback
 * setting in parentheses with 2 decimals, e.g. `(3.04)`. The entry keeps `null`.
 *
 * @param sigma - the entry's σ.
 * @param fallback - the setting `PMV_FALLBACK_UNCERT`.
 * @returns the text.
 */
export function sigmaShown(sigma: number | null, fallback: number): string {
    return sigma === null ? `(${formatRounded(fallback)})` : formatNumber(sigma)
}

// --- the preview of a non-biological entry

/**
 * The paragraphs of the preview of a non-biological entry: how the electrons add up (the
 * `breakdown` of the formula, which the caller gives), then `Z = ..   PMV = .. cm³/mol
 * σ = .. cm³/mol` of what is known (the σ with `(fallback)` when it is the setting's);
 * nothing for what is not known yet.
 *
 * @param e - the entry.
 * @param fallback - the setting `PMV_FALLBACK_UNCERT`.
 * @param breakdown - the sum of electrons of the formula, or `undefined`.
 * @returns the paragraphs, none empty.
 */
export function nonbioPreview(
    e: NonbioEntry,
    fallback: number,
    breakdown?: string,
): string[] {
    const parts: string[] = []
    if (e.z !== null) parts.push(`Z = ${e.z}`)
    if (e.pmv !== null) parts.push(`PMV = ${formatNumber(e.pmv)} cm³/mol`)
    if (e.sigma !== null) parts.push(`σ = ${formatNumber(e.sigma)} cm³/mol`)
    if (e.pmv !== null && e.sigma === null)
        parts.push(`σ = ${formatRounded(fallback)} cm³/mol ${FALLBACK_NOTE}`)
    return [e.formula.trim() === "" ? undefined : breakdown, parts.join("   ")].filter(
        (p): p is string => !!p,
    )
}

// ========================================================================================
// 4. The custom solutes file
// ========================================================================================

/**
 * The custom solutes of the user: `custom-solutes.json` in the BAYSOL data folder, next
 * to `settings.json` (so it belongs to the user, not to a project, and a reset of the
 * settings never touches it). A JSON object whose `solutes` is an array of the entries,
 * one object each:
 *
 *     {"kind": "nonbiological", "name": "N-acetylcysteine ethyl ester",
 *      "formula": "C7H13NO3S", "z": 100, "pmv": 118.4, "sigma": 4.0}
 *     {"kind": "polymer", "name": "chain-2",
 *      "units": [{"label": "A", "formula": "C2H4O", "z": 24, "slope": 36.73,
 *                 "sigma": null},
 *                {"label": "B", "formula": "C3H6O", "z": 32, "slope": 53.1,
 *                 "sigma": 0.1}],
 *      "zEnds": 10, "pmvEnds": 19.24, "sigmaEnds": null}
 *
 * The fields are explained above and in `./polymers.ts`; the schema is frozen in
 * `test/fixtures/buffer/custom-solutes.json`. Other keys of the map are kept as they are
 * on write. A missing or empty file is no entries; a file that is not a JSON object,
 * whose `solutes` is not an array of objects, that has more than [[MAX_ROWS]] entries, or
 * has a polymer without 1 to [[MAX_UNITS]] units (an entry of the single-unit shape older
 * than this one has none) is unusable, and is never written over.
 */

/** The name of the file in the BAYSOL folder. */
export const customSolutesFileName = "custom-solutes.json"

/** The custom solutes file of the BAYSOL folder. */
export function customFile(root: string): string {
    return join(root, customSolutesFileName)
}

/** What is wrong with an entry: not a map or, if a polymer, without 1 to 4 unit maps. */
function listEntryProblem(e: unknown): string | undefined {
    if (!isDict(e)) return "an entry is not a map"
    if (e.kind !== "polymer") return undefined
    const u = e.units
    const ok = Array.isArray(u) && u.length >= 1 && u.length <= MAX_UNITS && u.every(isDict)
    return ok ? undefined : `a polymer needs 1-${MAX_UNITS} units`
}

/** The list file of the custom solutes; names differ without regard to case. */
const list = new ListFile<CustomEntry>({
    fileName: customSolutesFileName,
    key: "solutes",
    kind: "custom-solutes",
    plural: "solutes",
    noun: "custom solute",
    problem: listEntryProblem,
    nameOf: (e) => e.name,
})

/**
 * The custom solutes of the folder.
 *
 * @param options - `track: true` when the entries are read to be edited and saved (see
 *     `readSolutes` of ./buffer.ts); a plain read leaves the base of the check alone.
 * @throws UnusableFileError (kind `custom-solutes`) if the file cannot be used.
 */
export function readCustomSolutes(root: string, options: ReadOptions = {}): CustomEntry[] {
    return list.read(root, options)
}

/**
 * Removes ONE saved entry from the file at once, leaving every other entry (and key) as
 * the file has it: the delete of the custom solutes table, which writes nothing else.
 * It takes the lock and refuses when another copy saved the file after this one read it.
 *
 * @returns whether there was such an entry (nothing is written when there was not).
 * @throws ChangedOnDiskError if the file changed since this process read it;
 *     UnusableFileError (kind `custom-solutes`) for a file that cannot be used.
 */
export function removeCustomSolute(root: string, name: string): boolean {
    return list.remove(root, name, { guarded: true })
}

/**
 * Writes the entries as the custom solutes of the folder, the other keys of the file
 * kept, through a temporary file that replaces it in one step. The file is made if there
 * is none; one that cannot be used is not touched. Nothing is written when the entries
 * break the rules above or two of them have the same name (case-insensitively).
 *
 * @throws ChangedOnDiskError if another copy of the program saved the file after this
 *     one read it (nothing is written); UnusableFileError (kind `custom-solutes`) for too
 *     many entries, a polymer without 1 to [[MAX_UNITS]] units, a name used twice, or a
 *     file that cannot be used.
 */
export function writeCustomSolutes(root: string, solutes: readonly CustomEntry[]): string {
    return list.write(root, solutes)
}
