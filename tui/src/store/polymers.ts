// SPDX-License-Identifier: LGPL-3.0-or-later

// The custom polymers: a generic additive chain of 1 to 4 kinds of repeat unit,
// `{kind, name, units: [{label, formula, z, slope, sigma}, ...], z-ends, pmv-ends,
// sigma-ends}` (the schema is frozen in `test/fixtures/buffer/custom-solutes.json`; the
// keys keep their file spelling, so `"z-ends"` is a quoted key, as in `./buffer.ts`):
// PMV(n) = pmv-ends + sum(slope_i n_i), Z(n) = z-ends + sum(z_i n_i). The end groups have
// no default: the user types them.
//
// Pure functions of an entry, so none of it needs a terminal: the types and checks of a
// polymer and its units, the units of a form page, the chain's values (the TS copy of
// Julia's polymer math) and the preview of the polymer form. What the entries of both
// kinds share (the table, the file, the snapshot, the typed fields) is in `./custom.ts`,
// which builds on this file.
//
// A number the user has not given is `null` (a `sigma` of `null` is a blank: the
// defaults apply, where the Julia side resolves them).

import { fold, formatNumber } from "../core/terminal.js"
import { type CustomPolymerRow, isNumber, type RowBase } from "./buffer.js"
import { isProblem, parseFormula, takeFormula } from "./formula.js"

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
export const MAX_LABEL = 8

/** The numbers of repeat units the polymer preview shows the chain's values for. */
const PREVIEW_COUNTS: readonly number[] = [10, 100]

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

/** The cells of a unit. */
export type UnitKey = keyof EntryUnit

/** A cell of a unit of a polymer: the unit's index (0-based) and the cell. */
export interface UnitField {
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

// --- the blank entries

/** @returns a repeat unit with nothing filled in. */
export function blankUnit(): EntryUnit {
    return { label: "", formula: "", z: null, slope: null, sigma: null }
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

// --- the checks, each told with the field it is about

/** Whether a value is a number that is below 0. */
export function isNegative(x: unknown): boolean {
    return typeof x === "number" && x < 0
}

/**
 * What is wrong with the Z of an entry or a unit: a Z above 0, or else a formula that is
 * understood (and so would give one), is needed.
 *
 * @param e - the entry or unit.
 * @returns `formula` with `formula unknown`, `z` with `Z must be > 0`, or `undefined`.
 */
export function zProblem(e: { formula: string; z: number | null }): FieldProblem | undefined {
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
export function polymerProblem(e: PolymerEntry): FieldProblem | undefined {
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

// --- the snapshot a buffer row stores

/** What a buffer row stores of a polymer, without the row's own keys. */
export type PolymerSnapshot = Omit<CustomPolymerRow, keyof RowBase>

/**
 * What a buffer row stores of a polymer with its counts: `{kind: "custom-polymer", custom,
 * units, z-ends, pmv-ends, sigma-ends, counts}`, the units copied with just their keys.
 * The row's own `name`, `mM` and `sigma-mM` are for the caller to add. The entry must be
 * complete (see `fieldProblem` of ./custom.ts).
 *
 * @param entry - a stored polymer.
 * @param counts - one number per unit, in the order of the units.
 * @returns the snapshot.
 * @throws Error when `counts` is not one number per unit.
 */
export function polymerSnapshot(
    entry: PolymerEntry,
    counts: readonly number[],
): PolymerSnapshot {
    if (counts.length !== entry.units.length || !counts.every(isNumber))
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

// --- the typed fields

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
