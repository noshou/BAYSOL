// SPDX-License-Identifier: LGPL-3.0-or-later

// What the screens of the buffer share and that needs no terminal: the two spellings of a
// solute (the row of the buffer file and the draft of a table), the check of a draft
// against the loader's rules, the window of a table that follows a cursor of its own, and
// what an add flow changed in a table.

import { isDeepStrictEqual } from "node:util"
import { type BufferRow, rowProblem } from "../store/buffer.js"
import type { Drafts } from "../store/draft.js"
import { bufferRow, type RowProblem, type Solute } from "../store/solutes.js"

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
 *     ([[soluteProblem]]).
 */
export function rowOf(s: Solute): BufferRow {
    return bufferRow(s) as unknown as BufferRow
}

/**
 * The loader's check of a draft, in the shape the table's `check` takes.
 *
 * @param s - the solute of the table.
 * @returns what the Julia loader would refuse in it, `undefined` when nothing.
 */
export const soluteProblem: RowProblem = (s) => rowProblem(bufferRow(s))

/**
 * The first row of a window of a table that shows `size` rows, so that `cursor` is in it,
 * moving as little as possible from where the window was.
 *
 * @param cursor - the row that must be in view.
 * @param offset - the first row shown now.
 * @param size - how many rows fit, at least 1.
 * @param count - how many rows there are.
 * @returns the new first row, between 0 and `count - size`.
 */
export function windowOffset(
    cursor: number,
    offset: number,
    size: number,
    count: number,
): number {
    const room = Math.max(1, size)
    let first = Math.min(offset, Math.max(0, count - room))
    if (cursor < first) first = cursor
    if (cursor >= first + room) first = cursor - room + 1
    return Math.max(0, first)
}

/**
 * What an add or edit flow changed in the table it was started on: the flow works on a
 * whole `Drafts` of its own, while a screen only has `replaceAt` and `append`, so the
 * difference is what the screen applies. A flow only ever changes rows it was started
 * on (an edit) or adds rows at the end (an add; a cancelled add has dropped them again).
 *
 * @param before - the table when the flow was started.
 * @param after - the table the flow ended with.
 * @returns the rows below the old length whose value changed (`[index, solute]`) and
 *     the solutes added past it, in order.
 */
export function flowChanges(
    before: Drafts<Solute>,
    after: Drafts<Solute>,
): { replaced: [number, Solute][]; appended: Solute[] } {
    const replaced: [number, Solute][] = []
    const appended: Solute[] = []
    for (let i = 0; i < after.length; i++) {
        const now = after.value(i)
        if (now === undefined) continue
        if (i >= before.length) appended.push(now)
        else if (!isDeepStrictEqual(before.value(i), now)) replaced.push([i, now])
    }
    return { replaced, appended }
}
