// SPDX-License-Identifier: LGPL-3.0-or-later

// What the screens of the buffer share and that needs no terminal: the check of a draft
// against the loader's rules, and what an add flow changed in a table.

import { isDeepStrictEqual } from "node:util"
import { rowProblem } from "../store/buffer.js"
import type { Drafts } from "../store/draft.js"
import { bufferRow, type RowProblem, type Solute } from "../store/solutes.js"

/**
 * The loader's check of a draft, in the shape the table's `check` takes.
 *
 * @param s - the solute of the table.
 * @returns what the Julia loader would refuse in it, `undefined` when nothing.
 */
export const soluteProblem: RowProblem = (s) => rowProblem(bufferRow(s))

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
