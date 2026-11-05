// SPDX-License-Identifier: LGPL-3.0-or-later

import { useCallback, useState } from "react"

/**
 * The cursor of a list that scrolls: which row it is on and which row is the first
 * one shown.
 *
 * @property index - the row the cursor is on.
 * @property offset - the first row shown, so `index` is always in view.
 * @property move - moves the cursor by some rows (negative is up), stopping at the ends.
 * @property set - puts the cursor on a row.
 */
export type ListCursor = {
    index:  number
    offset: number
    move:   (delta: number) => void
    set:    (index: number) => void
}

/**
 * Keeps a cursor on a list of `count` rows of which `pageSize` fit. When the list
 * shrinks (a row was removed) or the terminal does, the cursor and the window are
 * kept inside it, so nothing is ever drawn from beyond the end.
 *
 * @param count - how many rows the list has.
 * @param pageSize - how many rows fit on the screen, at least 1.
 * @returns the [[ListCursor]].
 */
export function useListCursor(count: number, pageSize: number): ListCursor {
    const [state, setState] = useState({ index: 0, offset: 0 })

    // clamp on read: the list may have shrunk since the state was set
    const index = Math.min(state.index, Math.max(0, count - 1))
    const size = Math.max(1, pageSize)
    let offset = Math.min(state.offset, Math.max(0, count - size))
    if (index < offset) offset = index
    if (index >= offset + size) offset = index - size + 1

    const set = useCallback((i: number) => {
        setState((s) => ({ ...s, index: Math.min(Math.max(i, 0), Math.max(0, count - 1)), offset }))
    }, [count, offset])

    const move = useCallback((delta: number) => set(index + delta), [set, index])

    return { index, offset, move, set }
}
