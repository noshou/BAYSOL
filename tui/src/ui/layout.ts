// SPDX-License-Identifier: LGPL-3.0-or-later

import { useWindowSize } from "ink"

/**
 * The layout adapts to the terminal: nothing has a fixed width or height, text wraps
 * and lists scroll. Only a minimum is asked for, below which a screen says so instead
 * of drawing itself badly.
 */

/** The narrowest terminal the screens are laid out for, in columns. */
export const minColumns = 80

/** The shortest terminal the screens are laid out for, in rows. */
export const minRows = 24

/**
 * The rows that every screen keeps for itself: its title, the box of keys at the
 * bottom (the logo's three lines, a note line, the border)  and the theme line.
 */
const frameRows = 10

/**
 * The rows a list or table body may use on the current terminal.
 *
 * @param extra - rows the screen uses besides the frame (a table header, a status line).
 * @returns the rows left, at least 3 so a list never vanishes.
 */
export function useBodyRows(extra: number = 0): number {
    const { rows } = useWindowSize()
    return Math.max(3, rows - frameRows - extra)
}

/**
 * The columns a screen's body may use.
 *
 * @returns the width of the terminal less the frame's side padding, at least
 *     `minColumns - 2`.
 */
export function useBodyColumns(): number {
    const { columns } = useWindowSize()
    return Math.max(minColumns, columns) - 2
}

/** The rows the app keeps under every screen for the theme line (`theme (^t): ...`). */
export const themeLineRows = 1
