// SPDX-License-Identifier: LGPL-3.0-or-later

// The custom solutes being edited, with what has not been saved: pure functions of a
// state, so none of it needs a terminal. A table of custom solutes is a
// `Drafts<CustomEntry>` (`./draft.ts`, the state the tables of the solutes and of the
// recipes share); the functions here add what is particular to custom solutes: the blank
// entry of each kind, editing one field, the checks (each told with the field it is
// about), the text the forms show and the snapshot a buffer row stores.
//
// An entry is one of two kinds (the schema is frozen in
// `test/fixtures/buffer/custom-solutes.json`; the keys keep their file spelling, so
// `"z-ends"` is a quoted key, as in `./buffer.ts`):
//
//   - a non-biological solute `{kind, name, formula, z, pmv, sigma}`;
//   - a polymer, a generic additive chain of 1 to 4 kinds of repeat unit,
//     `{kind, name, units: [{label, formula, z, slope, sigma}, ...], z-ends, pmv-ends,
//     sigma-ends}`: PMV(n) = pmv-ends + sum(slope_i n_i), Z(n) = z-ends + sum(z_i n_i).
//     The end groups have no default: the user types them.
//
// A number the user has not given is `null` (a `sigma` of `null` is a blank: the
// defaults apply, where the Julia side resolves them).

import {
    fold,
    formatNumber,
    type NumberRules,
    type Parsed,
    parseNumber,
} from "../core/text.js"
import {
    type CustomNonbioRow,
    type CustomPolymerRow,
    isNumber,
    type RowBase,
} from "./buffer.js"
import type { Drafts } from "./draft.js"
import { isProblem, parseFormula, parseUnit, stripUnit } from "./formula.js"
/**
 * The relative uncertainty of the PMV of a polymer unit whose `sigma` is blank: 2 % of
 * the PMV. This is `POLYMER_UNKNOWN_REL_UNC` of `Polymers.jl` (BulkElectronDensity),
 * where the blank is resolved; the screen only says `(2%)`.
 */
export const POLYMER_UNKNOWN_REL_UNC = 0.02

/** The most kinds of repeat unit a polymer has (`CUSTOM_POLYMER_MAX_UNITS` of Julia). */
export const MAX_UNITS = 4

/** The labels offered for the units, in order. */
const DEFAULT_LABELS: readonly string[] = ["A", "B", "C", "D"]

/** The most characters a unit label has. */
const MAX_LABEL = 8

/** The most digits of a whole number typed for Z (it must fit a Julia `Int`). */
const MAX_Z_DIGITS = 9

/** The numbers of repeat units the polymer preview shows the chain's values for. */
const PREVIEW_COUNTS: readonly number[] = [10, 100]

/** What the preview says after a σ that is the fallback setting's. */
const FALLBACK_NOTE = "(fallback)"

/** The message a name that is a built-in solute, polymer grade or family gets. */
const BUILTIN_MESSAGE = "name is built-in"

/** The message a name that another entry has gets. */
const IN_USE_MESSAGE = "name in use"

// --- the types

/**
 * One kind of repeat unit of a polymer entry, every cell possibly not given yet.
 *
 * @property label - the name the user chose (one word, [[MAX_LABEL]] characters at most).
 * @property formula - its formula, without a surrounding `( )n`.
 * @property z - electrons per unit.
 * @property slope - its PMV per unit.
 * @property sigma - its absolute uncertainty, `null` for blank.
 */
export interface EntryUnit {
    label: string
    formula: string
    z: number | null
    slope: number | null
    sigma: number | null
}

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

/**
 * A custom polymer.
 *
 * @property units - 1 to [[MAX_UNITS]] kinds of repeat unit.
 * @property z-ends - the electrons of the end groups, 0 or more.
 * @property pmv-ends - their PMV.
 * @property sigma-ends - their uncertainty, `null` for none.
 */
export interface PolymerEntry {
    kind: "polymer"
    name: string
    units: EntryUnit[]
    "z-ends": number | null
    "pmv-ends": number | null
    "sigma-ends": number | null
}

/** An entry of `custom-solutes.json`, told apart by `kind`. */
export type CustomEntry = NonbioEntry | PolymerEntry

/** The kinds of custom entry. */
export type CustomKind = CustomEntry["kind"]

/** The cells of a unit. */
export type UnitKey = keyof EntryUnit

/** A cell of a unit of a polymer: the unit's index (0-based) and the cell. */
interface UnitField {
    unit: number
    key: UnitKey
}

/** The fields an entry has that are not in a unit. */
type TopField =
    | "name"
    | "formula"
    | "z"
    | "pmv"
    | "sigma"
    | "units"
    | "z-ends"
    | "pmv-ends"
    | "sigma-ends"

/** A field of an entry: a top field or a cell of a unit. */
export type EntryField = TopField | UnitField

/**
 * What is wrong with an entry.
 *
 * @property field - the field the message is about.
 * @property message - a short text, 22 characters at most.
 */
export interface FieldProblem {
    field: EntryField
    message: string
}

/** The state of a table of custom solutes: the entries with their drafts and marks. */
export type CustomState = Drafts<CustomEntry>

/** Says whether a name is a built-in solute, polymer grade or family. */
export type BuiltinName = (name: string) => boolean

// --- the blank entries

/** @returns a repeat unit with nothing filled in. */
export function blankUnit(): EntryUnit {
    return { label: "", formula: "", z: null, slope: null, sigma: null }
}

/** @returns a non-biological entry with nothing filled in. */
export function blankNonbio(): NonbioEntry {
    return { kind: "nonbiological", name: "", formula: "", z: null, pmv: null, sigma: null }
}

/**
 * @returns a polymer entry with nothing filled in: one blank unit, and no end groups
 *     (they have no default).
 */
export function blankPolymer(): PolymerEntry {
    return {
        kind: "polymer",
        name: "",
        units: [blankUnit()],
        "z-ends": null,
        "pmv-ends": null,
        "sigma-ends": null,
    }
}

/**
 * The label offered for a unit.
 *
 * @param i - the unit's place, 0-based.
 * @returns `A` to `D`, `""` beyond.
 */
export function defaultLabel(i: number): string {
    return DEFAULT_LABELS[i] ?? ""
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

// --- the checks, each told with the field it is about

/** Whether a value is a number that is below 0. */
function isNegative(x: unknown): boolean {
    return typeof x === "number" && x < 0
}

/**
 * What is wrong with the Z of an entry or a unit: a Z above 0, or else a formula that is
 * understood (and so would give one), is needed.
 *
 * @param e - the entry or unit.
 * @returns `formula` with `formula unknown`, `z` with `Z must be > 0`, or `undefined`.
 */
function zProblem(e: { formula: string; z: number | null }): FieldProblem | undefined {
    const hasZ = e.z !== null && e.z > 0
    const formulaOk = e.formula.trim() === "" || !isProblem(parseFormula(e.formula))
    if (!hasZ && !formulaOk) return { field: "formula", message: "formula unknown" }
    if (!hasZ) return { field: "z", message: "Z must be > 0" }
    return undefined
}

/**
 * The first problem of a unit of a polymer.
 *
 * @param j - the unit's index.
 * @param u - the unit.
 * @returns the problem, its field a [[UnitField]], or `undefined`.
 */
function unitProblem(j: number, u: EntryUnit): FieldProblem | undefined {
    if (u.label.trim() === "")
        return { field: { unit: j, key: "label" }, message: "label needed" }
    const z = zProblem(u)
    if (z) return { field: { unit: j, key: z.field as UnitKey }, message: z.message }
    if (!isNumber(u.slope))
        return { field: { unit: j, key: "slope" }, message: "slope needed" }
    if (isNegative(u.sigma))
        return { field: { unit: j, key: "sigma" }, message: "± not below 0" }
    return undefined
}

/**
 * The index of the first unit whose label an earlier unit has, case-insensitively.
 *
 * @param units - the units.
 * @returns the index, or `undefined`.
 */
function duplicateLabel(units: readonly EntryUnit[]): number | undefined {
    const seen = new Set<string>()
    for (const [i, u] of units.entries()) {
        const key = fold(u.label)
        if (seen.has(key)) return i
        seen.add(key)
    }
    return undefined
}

/** The first problem of a polymer's units and end groups. */
function polymerProblem(e: PolymerEntry): FieldProblem | undefined {
    if (e.units.length === 0) return { field: "units", message: "unit needed" }
    for (const [j, u] of e.units.entries()) {
        const p = unitProblem(j, u)
        if (p) return p
    }
    const dup = duplicateLabel(e.units)
    if (dup !== undefined)
        return { field: { unit: dup, key: "label" }, message: "unit label used" }
    if (!isNumber(e["z-ends"])) return { field: "z-ends", message: "end groups needed" }
    if (!isNumber(e["pmv-ends"])) return { field: "pmv-ends", message: "end groups needed" }
    if (isNegative(e["sigma-ends"]))
        return { field: "sigma-ends", message: "ends ± not below 0" }
    return undefined
}

/**
 * The first thing missing in an entry. Both kinds need a name. A non-biological solute
 * needs a formula that is understood or a Z above 0, a PMV (a number, negative is fine
 * for an ion) and a ± of 0 or more when given. A polymer needs, of each unit, a label, a
 * Z or formula as above, a slope and a ± of 0 or more when given; labels that differ
 * (`unit label used`, case-insensitively); the end groups (`end groups needed`: `z-ends`
 * and `pmv-ends`, no default) and `sigma-ends` of 0 or more when given. Whether the name
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
        return { field: "name", message: IN_USE_MESSAGE }
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
            (seen.has(key) ? IN_USE_MESSAGE : undefined)
        if (message) return [i, message]
        seen.add(key)
    }
    return undefined
}

// --- the snapshot a buffer row stores

/** What a buffer row stores of a non-biological entry, without the row's own keys. */
export type NonbioSnapshot = Omit<CustomNonbioRow, keyof RowBase>

/** What a buffer row stores of a polymer, without the row's own keys. */
export type PolymerSnapshot = Omit<CustomPolymerRow, keyof RowBase>

/**
 * What a buffer row stores of a stored entry, so the project never reads the global
 * file. A non-biological entry gives `{kind: "custom-nonbio", custom, z, pmv,
 * sigma-pmv}`; a polymer, with its counts, `{kind: "custom-polymer", custom, units,
 * z-ends, pmv-ends, sigma-ends, counts}`, the units copied with just their keys. The
 * row's own `name`, `mM` and `sigma-mM` are for the caller to add. The entry must be
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
            "sigma-pmv": entry.sigma ?? null,
        }
    if (!counts || counts.length !== entry.units.length || !counts.every(isNumber))
        throw new Error("one count per unit needed")
    return {
        kind: "custom-polymer",
        custom: entry.name,
        units: entry.units.map(({ label, formula, z, slope, sigma }) => ({
            label,
            formula,
            z: z as number,
            slope: slope as number,
            sigma: sigma ?? null,
        })),
        "z-ends": entry["z-ends"] as number,
        "pmv-ends": entry["pmv-ends"] as number,
        "sigma-ends": entry["sigma-ends"] ?? null,
        counts: [...counts],
    }
}

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

/**
 * A number rounded to 2 decimals, as [[formatNumber]] shows it.
 *
 * @param x - the number.
 * @returns the text; `undefined` for `null` and `undefined`.
 */
export function formatRounded(x: number | null | undefined): string | undefined {
    if (x === null || x === undefined) return undefined
    return formatNumber(Math.round(100 * x) / 100)
}

/** The fields a form cell is typed for. */
export type ParseField =
    | "name"
    | "label"
    | "formula"
    | "z"
    | "z-ends"
    | "pmv"
    | "slope"
    | "pmv-ends"
    | "sigma"
    | "sigma-ends"

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
        case "z-ends":
            return parseNumber(t, WHOLE_RULES)
        case "z":
            return parseNumber(t, Z_RULES)
        case "sigma":
        case "sigma-ends":
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

/** The things a formula can be taken into: an entry or a unit. */
export interface WithFormula {
    formula: string
    z: number | null
    label?: string
}

/**
 * The formula text taken into an entry or a unit of a polymer. The formula is set and,
 * when it is not the one the target had, Z is what it comes to, or `null` when the
 * formula is not understood (the reason is the note, unless the formula is blank); a
 * formula that did not change keeps its Z, so a Z typed by hand stays. A polymer unit
 * with no label gets `offered`, when that is given.
 *
 * @param m - the entry (non-biological) or unit.
 * @param text - the formula as typed.
 * @param unit - true for a polymer unit: a surrounding `( )n` is dropped and no charge
 *     is allowed.
 * @param offered - the label to give a unit that has none.
 * @returns the new target, and the reason the formula was not understood, if any.
 */
export function takeFormula<T extends WithFormula>(
    m: T,
    text: string,
    unit: boolean,
    offered?: string,
): { value: T; note: string | undefined } {
    const parsed = unit ? parseUnit(text) : parseFormula(text)
    const shown = unit ? stripUnit(text) : text.trim()
    const same = shown === m.formula
    const failed = isProblem(parsed)
    const z = same ? m.z : failed ? null : parsed.z
    let value: T = { ...m, formula: shown, z }
    if (unit && offered && shown !== "" && (m.label ?? "").trim() === "")
        value = { ...value, label: offered }
    return { value, note: !same && failed && shown !== "" ? parsed.error : undefined }
}

/**
 * The formula of the end groups taken into the polymer: its `z-ends` is what the
 * formula comes to unless the formula is the one it had. The formula is not part of the
 * entry (the stored shape is frozen): it only gives the Z, and is not kept when the form
 * is opened again, so the caller keeps it.
 *
 * @param entry - the polymer.
 * @param endsFormula - the end-groups formula it had.
 * @param text - the formula as typed.
 * @returns the new entry, the formula as taken, and the note (`Z must be >= 0` for a
 *     negative Z, which is not kept; else the reason the formula was not understood).
 */
export function takeEndsFormula(
    entry: PolymerEntry,
    endsFormula: string,
    text: string,
): { entry: PolymerEntry; endsFormula: string; note: string | undefined } {
    const r = takeFormula({ formula: endsFormula, z: entry["z-ends"] }, text, false)
    const negative = r.value.z !== null && r.value.z < 0
    return {
        entry: { ...entry, "z-ends": negative ? null : r.value.z },
        endsFormula: r.value.formula,
        note: negative ? "Z must be >= 0" : r.note,
    }
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

/**
 * What the ± cell of a polymer unit shows: its value; a blank of a used row as `(2%)`
 * (see [[POLYMER_UNKNOWN_REL_UNC]]), of an unused row nothing.
 *
 * @param sigma - the unit's σ.
 * @param used - whether the row is used ([[usedRows]]).
 * @returns the text.
 */
export function unitSigmaShown(sigma: number | null, used: boolean): string {
    if (sigma !== null) return formatNumber(sigma)
    return used ? `(${formatNumber(100 * POLYMER_UNKNOWN_REL_UNC)}%)` : ""
}

/**
 * What the label cell of a unit shows: its label; a blank of a used row as the one
 * offered for its place, `(A)`, of an unused row nothing.
 *
 * @param label - the unit's label.
 * @param i - the row's place, 0-based.
 * @param used - whether the row is used ([[usedRows]]).
 * @returns the text.
 */
export function labelShown(label: string, i: number, used: boolean): string {
    if (label.trim() !== "") return label
    return used ? `(${defaultLabel(i)})` : ""
}

// --- the units of a form page

/**
 * Whether every cell of a unit is blank (a form row nobody filled).
 *
 * @param u - the unit.
 * @returns true if so.
 */
function unitBlank(u: EntryUnit): boolean {
    return (
        u.label.trim() === "" &&
        u.formula.trim() === "" &&
        u.z === null &&
        u.slope === null &&
        u.sigma === null
    )
}

/**
 * The indices of the rows of a unit table that are used: row 0 always, then every row
 * that has anything in it (an all-blank row is ignored; a half-filled one is used, and
 * then a problem).
 *
 * @param units - the rows of the table.
 * @returns the indices, ascending.
 */
export function usedRows(units: readonly EntryUnit[]): number[] {
    const filled = (i: number) => i > 0 && !unitBlank(units[i] as EntryUnit)
    const rest = units.map((_, i) => i).filter(filled)
    return [0, ...rest]
}

/**
 * The units a form page's table makes: the used rows in order, a blank label being the
 * one offered for its row (the row's place in the table).
 *
 * @param units - the rows of the table.
 * @returns the units.
 */
export function compactUnits(units: readonly EntryUnit[]): EntryUnit[] {
    return usedRows(units).map((i) => {
        const u = units[i] as EntryUnit
        return u.label.trim() === "" ? { ...u, label: defaultLabel(i) } : u
    })
}

// --- a chain of units (the preview of the polymer form)

/** A polymer with every number a chain needs, as [[chainValues]] takes it. */
export interface CompletePolymer extends PolymerEntry {
    units: (EntryUnit & { z: number; slope: number })[]
    "z-ends": number
    "pmv-ends": number
}

/**
 * Whether a polymer has every number the chain values need.
 *
 * @param e - the polymer (its units compacted).
 * @returns true if so.
 */
function isComplete(e: PolymerEntry): e is CompletePolymer {
    return (
        isNumber(e["z-ends"]) &&
        isNumber(e["pmv-ends"]) &&
        e.units.every((u) => isNumber(u.z) && isNumber(u.slope))
    )
}

/** What a chain comes to: electrons, PMV and uncertainty (cm³/mol). */
export interface ChainValues {
    z: number
    pmv: number
    sigma: number
}

/**
 * Rounds to the nearest whole number, halves to even (Java's `Math.rint`, Julia's
 * `round`).
 *
 * @param x - the number.
 * @returns the whole number.
 */
function roundHalfEven(x: number): number {
    const floor = Math.floor(x)
    const diff = x - floor
    if (diff < 0.5) return floor
    if (diff > 0.5) return floor + 1
    return floor % 2 === 0 ? floor : floor + 1
}

/**
 * What a chain of the units of a polymer, with `counts` repeat units of each kind,
 * comes to. This is the rule of `_ρₑ_i(::CustomPolymer)` in
 * `src/BulkElectronDensity/CalcDensity.jl`: ϕ° = pmv-ends + Σ slope·n, Z = round(z-ends
 * + Σ Z_unit·n) (halves to even), σ = sqrt(Σ term² + σ_ends²) with term = σ_unit·n, or
 * 2 % of |slope·n| for a unit with no σ; when no σ is stated at all (neither of the ends
 * nor of a unit) σ is 2 % of |ϕ°|. Nothing is checked here (see [[fieldProblem]]).
 *
 * @param entry - a complete polymer.
 * @param counts - one number of repeat units per unit.
 * @returns the electrons, PMV and σ.
 */
export function chainValues(
    entry: CompletePolymer,
    counts: readonly number[],
): ChainValues {
    const units = entry.units
    const sum = (f: (u: CompletePolymer["units"][number], n: number) => number) =>
        units.reduce((s, u, i) => s + f(u, counts[i] as number), 0)
    const pmv = entry["pmv-ends"] + sum((u, n) => u.slope * n)
    const z = roundHalfEven(entry["z-ends"] + sum((u, n) => u.z * n))
    const sEnds = entry["sigma-ends"]
    const unstated = sEnds === null && units.every((u) => u.sigma === null)
    const terms = (u: CompletePolymer["units"][number], n: number) =>
        u.sigma === null ? POLYMER_UNKNOWN_REL_UNC * Math.abs(u.slope * n) : u.sigma * n
    const sigma = unstated
        ? POLYMER_UNKNOWN_REL_UNC * Math.abs(pmv)
        : Math.sqrt(sum((u, n) => terms(u, n) ** 2) + (sEnds ?? 0) ** 2)
    return { z, pmv, sigma }
}

// --- the previews

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

/**
 * A term of a sum with the sign of its place: ` + 36.7·nA` or ` - 5.2·nA` (`?` for a
 * number not given yet).
 */
function termText(x: number | null, label: string): string {
    const negative = typeof x === "number" && x < 0
    const n = typeof x === "number" ? formatNumber(Math.abs(x)) : "?"
    return `${negative ? " - " : " + "}${n}·n${label}`
}

/** `lhs = head + a·nA + b·nB` for the head of the ends and the `[x, label]` terms. */
function equation(
    lhs: string,
    head: number | null,
    terms: readonly (readonly [number | null, string])[],
): string {
    const h = typeof head === "number" ? formatNumber(head) : "?"
    return `${lhs} = ${h}${terms.map(([x, label]) => termText(x, label)).join("")}`
}

/** The line for `k` of each unit: `n = 10 of each: Z = 274, PMV = 411.5 cm³/mol, ...`. */
function chainLine(e: CompletePolymer, k: number): string {
    const { z, pmv, sigma } = chainValues(e, e.units.map(() => k))
    return (
        `n = ${k} of each: Z = ${z}, PMV = ${formatRounded(pmv)} cm³/mol, ` +
        `σ = ${formatRounded(sigma)} cm³/mol`
    )
}

/**
 * The paragraphs of the preview of a polymer form: the chain's PMV and Z in words with
 * the labels of the used units (`PMV = 9 + 36.92·nA + 53.13·nB`) and, when every number
 * they need is given, the chain's values for each of [[PREVIEW_COUNTS]] of each unit.
 *
 * @param entry - the polymer as the form holds it (its units are the rows of the table,
 *     blank rows included).
 * @returns the paragraphs; none before anything is given.
 */
export function polymerPreview(entry: PolymerEntry): string[] {
    const e: PolymerEntry = { ...entry, units: compactUnits(entry.units) }
    if (entry.units.every(unitBlank) && e["z-ends"] === null && e["pmv-ends"] === null)
        return []
    const lines = [
        equation("PMV", e["pmv-ends"], e.units.map((u) => [u.slope, u.label] as const)),
        equation("Z", e["z-ends"], e.units.map((u) => [u.z, u.label] as const)),
    ]
    if (isComplete(e)) for (const k of PREVIEW_COUNTS) lines.push(chainLine(e, k))
    return lines
}
