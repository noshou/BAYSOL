// SPDX-License-Identifier: LGPL-3.0-or-later

// The solutes being edited, with what has not been saved. A table of solutes is a
// `Drafts<Solute>` (`./draft.ts`); the functions here add what is particular to solutes:
// the blank row of an add, editing one field, and the check at save. A solute is an
// object of one of the kinds of the buffer (`kind`, `name`, `arg`, `mM`, `sigmaMM` and
// the keys its kind needs); the screen builds them (the add flow) and this module only
// keeps them.

import type { BufferRow } from "./buffer.js"
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
 * A row of a buffer (or recipe) file as the draft a table edits: `sigma-mM` becomes
 * `sigmaMM`, the one renaming, which [[rowOf]] undoes. Every other key travels along.
 *
 * @param row - the row as the file has it.
 * @returns the solute of the table.
 */
export function soluteOf(row: BufferRow): Solute {
    const { "sigma-mM": sigmaMM, ...rest } = row as BufferRow & Record<string, unknown>
    return { ...rest, sigmaMM } as unknown as Solute
}

/**
 * A draft of a table as the row the file gets (what `writeSolutes` takes).
 *
 * @param s - the solute of the table.
 * @returns the row; it is only as valid as the draft, so check it first
 *     (`soluteProblem` of the screens).
 */
export function rowOf(s: Solute): BufferRow {
    return bufferRow(s) as unknown as BufferRow
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
const BLANK_SOLUTE: Readonly<Solute> = {
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
 * @param s - the solute.
 * @param rowProblem - the buffer's check of the keys of its kind.
 * @returns `"name needed"`, `"mM must be > 0"`, `"±mM needed"`, `"row incomplete"`, or
 *   `undefined` for a complete solute.
 */
export function draftProblem(s: Solute, rowProblem: RowProblem): string | undefined {
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
        const message = draftProblem(state.value(i) as Solute, rowProblem)
        if (message) return [i, message]
    }
    return undefined
}
