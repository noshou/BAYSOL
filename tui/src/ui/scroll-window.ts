// SPDX-License-Identifier: LGPL-3.0-or-later

// The one place that decides which rows of a long list are drawn: the cursor of a table,
// the suggestions under an input, the blocks of a settings sheet and the picker all ask
// here, so they scroll the same way.

/**
 * Keeps a window of `size` rows inside a list of `count` rows.
 *
 * @param first - the wanted first row.
 * @param size - how many rows fit, at least 1.
 * @param count - how many rows the list has.
 * @returns `first` moved to between 0 and `count - size` (0 for a short list).
 */
export function clampWindow(first: number, size: number, count: number): number {
    return Math.min(Math.max(first, 0), Math.max(0, count - size))
}

/**
 * The first row of a window that has to show `selected`, moving as little as possible
 * from where the window was; rows may differ in height, so how many rows fit from a
 * first row is a function.
 *
 * @param top - the first row shown now.
 * @param selected - the row that must be in view.
 * @param fitting - how many rows fit when the window starts at the given row.
 * @returns the old `top` if it already shows `selected`, else the smallest top that does.
 */
export function scrollTo(
    top: number,
    selected: number,
    fitting: (first: number) => number,
): number {
    let first = Math.min(top, selected)
    while (first < selected && first + fitting(first) <= selected) first++
    return first
}

/**
 * The first row of a window of equal rows that shows `cursor`, moving as little as
 * possible from where the window was (a list the cursor walks along).
 *
 * @param cursor - the row that must be in view.
 * @param offset - the first row shown now.
 * @param size - how many rows fit, at least 1 (a smaller size is taken as 1).
 * @param count - how many rows there are.
 * @returns the new first row, between 0 and `count - size`.
 */
export function scrollWindow(
    cursor: number,
    offset: number,
    size: number,
    count: number,
): number {
    const room = Math.max(1, size)
    return Math.max(0, scrollTo(clampWindow(offset, room, count), cursor, () => room))
}

/**
 * The first row of a window that has `highlight` in its middle (a list that is
 * redrawn around the highlight, with no memory of where it was).
 *
 * @param count - how many items there are.
 * @param highlight - the index of the highlighted item.
 * @param lines - how many items fit.
 * @returns the index of the first item to show.
 */
export function centredWindow(count: number, highlight: number, lines: number): number {
    return clampWindow(highlight - Math.floor(lines / 2), lines, count)
}

/**
 * The highlight of a list one step up or down.
 *
 * @param index - the highlighted item now.
 * @param count - how many items there are; 0 keeps the highlight on 0.
 * @param down - `true` for down, `false` for up.
 * @param wrap - whether a step past an end goes round to the other end; else it stops.
 * @returns the new index, between 0 and `count - 1`.
 */
export function stepIndex(
    index: number,
    count: number,
    down: boolean,
    wrap: boolean = false,
): number {
    if (count <= 0) return 0
    if (wrap) return (index + (down ? 1 : count - 1)) % count
    return Math.min(Math.max(index + (down ? 1 : -1), 0), count - 1)
}
