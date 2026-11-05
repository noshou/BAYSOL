// SPDX-License-Identifier: LGPL-3.0-or-later

// The text of the custom solutes screens that needs no terminal: what the cells of a row
// of the custom solutes table show, and what the landing says of its two files.

import {
    type CustomEntry,
    formatNumber,
    formatRounded,
    POLYMER_UNKNOWN_REL_UNC,
    type PolymerEntry,
} from "../store/custom.js"

/** How many rows a file holds, or that it cannot be used. */
export type FileCount = number | "unusable"

/**
 * A number as a term of a sum: `+36.9` or `-5.2`, the number as typed.
 *
 * @param x - the number.
 * @returns the text with its sign.
 */
function signed(x: number): string {
    return (x < 0 ? "-" : "+") + formatNumber(Math.abs(x))
}

/**
 * The terms of a sum as text, `36.9A+53.1B+9`: a term with no number is left out, the
 * first keeps its minus (`-5.2A+3`) and the others carry their sign.
 *
 * @param terms - `[number, suffix]` pairs, the suffix a unit's label or `""`.
 * @returns the text.
 */
function sumText(terms: readonly (readonly [number | null, string])[]): string {
    const shown = terms.filter((t): t is readonly [number, string] => t[0] !== null)
    return shown
        .map(([x, suffix], i) => (i === 0 ? formatNumber(x) : signed(x)) + suffix)
        .join("")
}

/**
 * What the formula cell of the custom solutes table shows: the formula of a
 * non-biological solute, the units of a polymer as `A:C2H4O B:C3H6O` (a unit with no
 * formula is left out).
 *
 * @param e - the entry.
 * @returns the text.
 */
export function formulaCell(e: CustomEntry): string {
    if (e.kind !== "polymer") return e.formula
    return e.units
        .filter((u) => u.formula.trim() !== "")
        .map((u) => `${u.label}:${u.formula}`)
        .join(" ")
}

/**
 * What the Z cell shows: the number, or for a polymer the sum `24A+32B+10` of the Z of
 * each unit by its label, then the end groups.
 *
 * @param e - the entry.
 * @returns the text.
 */
export function zCell(e: CustomEntry): string {
    if (e.kind !== "polymer") return e.z === null ? "" : String(e.z)
    const units = e.units.map((u) => [u.z, u.label] as const)
    return sumText([...units, [e["z-ends"], ""]])
}

/**
 * What the PMV cell shows: the number, or for a polymer the sum `36.9A+53.1B+9` of the
 * slope of each unit by its label, then the end groups.
 *
 * @param e - the entry.
 * @returns the text.
 */
export function pmvCell(e: CustomEntry): string {
    if (e.kind !== "polymer") return formatNumber(e.pmv)
    const units = e.units.map((u) => [u.slope, u.label] as const)
    return sumText([...units, [e["pmv-ends"], ""]])
}

/**
 * The ± of a polymer as one cell: the ± of its units if they all agree, `…` if they
 * differ (the form page shows them all), `(2%)` when it is blank. The ± of the end
 * groups is not shown.
 */
function polymerSigmaCell(e: PolymerEntry): string {
    const sigmas = [...new Set(e.units.map((u) => u.sigma))]
    if (sigmas.length > 1) return "…"
    const [first] = sigmas
    if (first !== null && first !== undefined) return formatNumber(first)
    return `(${formatNumber(100 * POLYMER_UNKNOWN_REL_UNC)}%)`
}

/**
 * What the ± cell shows: the number; a blank of a non-biological solute as the setting
 * `PMV_FALLBACK_UNCERT` in parentheses; for a polymer see the table's documentation.
 * Nothing is computed here, the defaults apply at the run.
 *
 * @param e - the entry.
 * @param fallback - the setting `PMV_FALLBACK_UNCERT`.
 * @returns the text.
 */
export function sigmaCell(e: CustomEntry, fallback: number): string {
    if (e.kind === "polymer") return polymerSigmaCell(e)
    return e.sigma === null ? `(${formatRounded(fallback)})` : formatNumber(e.sigma)
}

/**
 * The labels of the two options of the landing.
 *
 * @param recipes - what the recipes file holds.
 * @param solutes - what the custom solutes file holds.
 * @returns `["recipes (3)", "solutes (12)"]`, `?` for a file that cannot be used.
 */
export function landingOptions(recipes: FileCount, solutes: FileCount): [string, string] {
    const shown = (n: FileCount) => (n === "unusable" ? "?" : String(n))
    return [`recipes (${shown(recipes)})`, `solutes (${shown(solutes)})`]
}

/**
 * What the landing says of what a file holds: `recipes.json: 3 recipes`, `none yet`, or
 * `unusable!`.
 *
 * @param file - the name of the file.
 * @param count - what it holds.
 * @param word - what one row is called (`recipe`); an `s` is added unless there is one.
 * @returns the text.
 */
export function fileStatus(file: string, count: FileCount, word: string): string {
    if (count === "unusable") return `${file} unusable!`
    if (count === 0) return `${file}: none yet`
    return `${file}: ${count} ${word}${count === 1 ? "" : "s"}`
}
