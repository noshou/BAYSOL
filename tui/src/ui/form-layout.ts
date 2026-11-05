// SPDX-License-Identifier: LGPL-3.0-or-later

// The pure parts of a form page (`./field-form.tsx`, `./use-form-screen.ts`): how wide
// the columns of its cells are on a terminal of some width, and where the cursor goes
// for an arrow key. A form is a few rows of cells; a row has one cell (a plain field) or
// several (a small table, like the units of a polymer). The cursor is a cell.

/** The narrowest a column of cells is squeezed to when the terminal is narrow. */
export const MIN_CELL = 3

/**
 * Where the cursor is on a form: a row and a column of its cells.
 *
 * @property row - the row.
 * @property col - the column of the cell, one of the valid columns of the row.
 * @property want - the column the user last asked for with left and right, kept while
 *     the cursor moves up and down so that a row with fewer cells does not make it
 *     forget the column (it goes to the nearest valid one of each row).
 */
export interface CellPos {
    row: number
    col: number
    want: number
}

/**
 * The cursor on a cell.
 *
 * @param row - the row.
 * @param col - the column.
 * @returns the position, with `want` the column too.
 */
export function placeAt(row: number, col: number): CellPos {
    return { row, col, want: col }
}

/**
 * The widths of the columns of a form, squeezed to fit.
 *
 * @param natural - the width each column would like (its longest text).
 * @param room - the cells the columns may use together.
 * @param floor - the width below which no column is squeezed, [[MIN_CELL]] by default.
 * @returns one width per column: the natural ones if they fit, else the widest column
 *     loses a cell at a time (the first of equal ones) until they fit or all are at the
 *     floor.
 */
export function fitWidths(
    natural: readonly number[],
    room: number,
    floor: number = MIN_CELL,
): number[] {
    const widths = natural.map((w) => Math.max(w, 1))
    const total = () => widths.reduce((sum, w) => sum + w, 0)
    while (total() > room) {
        const widest = Math.max(...widths)
        if (widest <= floor) break
        widths[widths.indexOf(widest)] = widest - 1
    }
    return widths
}

/**
 * The cursor after an arrow key. Up and down go to the row above or below, to its valid
 * column nearest to the one asked for; left and right go to the previous and next valid
 * column of the row, and become the column asked for. Nothing wraps.
 *
 * @param valid - for each row, the columns that have a cell, ascending, none empty.
 * @param pos - where the cursor is.
 * @param dRow - rows to move (-1, 0 or 1).
 * @param dCol - cells to move along the row (-1, 0 or 1).
 * @returns the new position.
 */
export function moveCell(
    valid: readonly (readonly number[])[],
    pos: CellPos,
    dRow: number,
    dCol: number,
): CellPos {
    if (dRow !== 0) {
        const row = Math.min(Math.max(pos.row + dRow, 0), valid.length - 1)
        const cols = valid[row] as readonly number[]
        const near = (a: number, b: number) =>
            Math.abs(a - pos.want) <= Math.abs(b - pos.want) ? a : b
        return { row, col: cols.reduce(near), want: pos.want }
    }
    const cols = valid[pos.row] as readonly number[]
    const at = Math.max(0, cols.indexOf(pos.col))
    const col = cols[Math.min(Math.max(at + dCol, 0), cols.length - 1)] as number
    return { row: pos.row, col, want: col }
}
