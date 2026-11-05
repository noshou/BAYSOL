// SPDX-License-Identifier: LGPL-3.0-or-later

// The solutes being edited, with what has not been saved, and the names a text setting
// may take (the lookup helpers the buffer and the add flow use). A table of solutes is a
// `Drafts<Solute>` (`./draft.ts`); the functions here add what is particular to solutes:
// the blank row of an add, editing one field, and the check at save. A solute is an
// object of one of the kinds of the buffer (`kind`, `name`, `arg`, `mM`, `sigmaMM` and
// the keys its kind needs); the screen builds them (the add flow) and this module only
// keeps them.
//
// The names a colour or font setting may take, which the editor offers as a list to pick
// from, are here too: the colours (`assets/data/colours.json`, harvested from the names
// `Colors.parse` knows) and the fonts installed on this machine, which the caller finds
// (the font scan is a module of its own) and passes in.

import { readAssetJson } from "../core/assets.js"
import type { Drafts } from "./draft.js"

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
 * A solute as the row of the buffer file: `sigmaMM` is written `sigma-mM` there.
 *
 * Two types describe a solute on purpose. [[Solute]] is the draft in a table: camelCase
 * (`sigmaMM`), `null` for what is not typed yet, and no obligation to be complete.
 * `BufferRow` of ./buffer.ts is the row of the file, with the spelling the Julia loader
 * reads (`"sigma-mM"`) and every number given. This adapter is the one place that
 * turns the first into the second (the check of the file, `rowProblem`, runs on its
 * result), so no other module spells a key twice.
 *
 * @param s - the solute of the table.
 * @returns the row, as `rowProblem` and `writeSolutes` of ./buffer.ts take it.
 */
export function bufferRow(s: Solute): Record<string, unknown> {
    const { sigmaMM, ...rest } = s
    return { ...rest, "sigma-mM": sigmaMM }
}

/**
 * Tells what a buffer row lacks for the Julia loader (the check of the buffer file).
 *
 * @param row - a solute.
 * @returns a message, or `undefined` for a complete row.
 */
export type RowProblem = (row: Solute) => string | undefined

/**
 * A solute with nothing filled in, the draft of a row just added: a non-biological one
 * until the name is picked.
 */
export const BLANK_SOLUTE: Readonly<Solute> = {
    kind: "nonbiological",
    name: "",
    arg: "",
    mM: null,
    sigmaMM: null,
}

/**
 * The state with a new blank row at the end.
 *
 * @param state - the table.
 * @returns the new table.
 */
export function addBlankRow(state: Drafts<Solute>): Drafts<Solute> {
    return state.add({ ...BLANK_SOLUTE })
}

/**
 * The state with one field of row `i` set. The name is a label: the row's `arg` is not
 * touched. A row set back to what was saved has no draft.
 *
 * @param state - the table.
 * @param i - the row.
 * @param field - `name`, `mM`, `sigmaMM` or any other key of the solute.
 * @param value - the new value.
 * @returns the new table.
 * @throws RangeError for a row that is not there.
 */
export function setField(
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
 * @param s - the solute.
 * @param rowProblem - the buffer's check of the keys of its kind.
 * @returns `"name needed"`, `"mM must be > 0"`, `"±mM needed"`, `"row incomplete"`, or
 *   `undefined` for a complete solute.
 */
export function problem(s: Solute, rowProblem: RowProblem): string | undefined {
    if (s.name.trim() === "") return "name needed"
    if (!(typeof s.mM === "number" && s.mM > 0)) return "mM must be > 0"
    if (!(typeof s.sigmaMM === "number" && s.sigmaMM >= 0)) return "±mM needed"
    if (rowProblem(s)) return "row incomplete"
    return undefined
}

/**
 * The first problem of the rows that stay at the next save.
 *
 * @param state - the table.
 * @param rowProblem - the buffer's check of the keys of a kind.
 * @returns `[row index, message]`, or `undefined` when every row that stays is complete.
 */
export function firstProblem(
    state: Drafts<Solute>,
    rowProblem: RowProblem,
): [number, string] | undefined {
    for (let i = 0; i < state.length; i++) {
        if (state.rows[i].removed) continue
        const message = problem(state.value(i) as Solute, rowProblem)
        if (message) return [i, message]
    }
    return undefined
}

// ---- the names a setting may take -------------------------------------------------------

/** The colours, `[name, [r, g, b]]` in the order of the file; read when first asked. */
let cachedColours: [string, [number, number, number]][] | undefined
let cachedSwatches: Map<string, [number, number, number]> | undefined

/** The red, green and blue (0 to 255 each) of a `rrggbb` hex text. */
function rgb(hex: string): [number, number, number] {
    return [0, 2, 4].map((at) => Number.parseInt(hex.slice(at, at + 2), 16)) as [
        number,
        number,
        number,
    ]
}

/** The colours of `colours.json` (`name -> "#rrggbb"`), read once. */
function colours(): [string, [number, number, number]][] {
    const file = readAssetJson<Record<string, string>>("data", "colours.json")
    cachedColours ??= Object.entries(file).map(
        ([name, hex]) => [name, rgb(hex.slice(1))],
    )
    return cachedColours
}

/**
 * The colour of a name as red, green and blue.
 *
 * @param colour - a name of the list, or a `#rrggbb` text (its own colour).
 * @returns `[r, g, b]` (0 to 255 each), or `undefined` for a name that is no colour.
 */
export function swatch(colour: string): [number, number, number] | undefined {
    if (/^#[0-9a-f]{6}$/.test(colour)) return rgb(colour.slice(1))
    cachedSwatches ??= new Map(colours())
    return cachedSwatches.get(colour)
}

/** The fonts of a machine: math fonts (with an OpenType MATH table) and text fonts. */
export interface FontLists {
    math: readonly string[]
    text: readonly string[]
}

/** The kinds of text setting that take a list of names. */
export type NameKind = "colour" | "font"

/**
 * The names a text setting may take. The font of a setting whose name has `MATH` in it is
 * chosen from the math fonts, any other font setting from the text fonts, which leave the
 * math fonts out.
 *
 * @param setting - the setting's name, `PLOT_MATH_FONT`.
 * @param kind - `colour` or `font`; any other kind has no list.
 * @param fonts - the fonts installed here; a machine with none has no list.
 * @returns the names, sorted (colours in the order of the harvest, which is sorted).
 */
export function names(
    setting: string,
    kind: NameKind | string,
    fonts: FontLists = { math: [], text: [] },
): readonly string[] {
    if (kind === "colour") return colours().map(([name]) => name)
    if (kind === "font") return setting.includes("MATH") ? fonts.math : fonts.text
    return []
}
