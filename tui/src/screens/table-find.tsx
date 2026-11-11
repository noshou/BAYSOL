// SPDX-License-Identifier: LGPL-3.0-or-later

// Table find: the search of a table of named rows (`/`), a dropdown under the table that
// lists the names that fit what is typed and moves the cursor to the one picked. Used by
// `useTableScreen` for the recipes, the custom solutes and the rows of a buffer.

import { type ReactNode, useCallback, useMemo, useState } from "react"
import { compareNoCase } from "../core/terminal.js"
import { type Row, rowValue } from "../store/lists.js"
import type { LegendItem } from "../ui/grid.js"
import { type Choice, Dropdown } from "../ui/input.js"

/** The rows the open finder takes under the table: its field, 4 names and the status. */
export const FIND_ROWS = 7

/** The names the finder lists at most. */
const FIND_LINES = 4

/**
 * What [[useTableFind]] gives the screen.
 *
 * @property open - the finder is open: the table's own keys are off.
 * @property element - the dropdown to draw under the table, `null` while closed.
 * @property legend - the keys of the open finder, empty while closed.
 * @property start - opens the finder.
 */
export type TableFind = {
    open: boolean
    element: ReactNode
    legend: LegendItem[]
    start: () => void
}

/**
 * The finder of a table of named rows. Typing narrows the names (any part of a name, case
 * ignored), they come in alphabetical order, Enter puts the cursor on the highlighted row,
 * Esc leaves with the cursor where it was.
 *
 * @param rows - the rows of the table.
 * @param label - the name of an item, `undefined` for a table without names (no finder).
 * @param goTo - puts the cursor on a row.
 * @returns the state of the finder, see [[TableFind]].
 */
export function useTableFind<V>(
    rows: readonly Row<V>[],
    label: ((item: V) => string) | undefined,
    goTo: (index: number) => void,
): TableFind {
    const [open, setOpen] = useState(false)
    const [legend, setLegend] = useState<LegendItem[]>([])
    const choices = useMemo<Choice<number>[]>(() => {
        if (label === undefined) return []
        return rows
            .map((row, index) => ({ label: label(rowValue(row) as V), value: index }))
            .sort((a, b) => compareNoCase(a.label, b.label))
    }, [rows, label])
    const search = useCallback(
        (text: string) => {
            const needle = text.trim().toLowerCase()
            return choices.filter((c) => c.label.toLowerCase().includes(needle))
        },
        [choices],
    )
    const close = useCallback(() => {
        setOpen(false)
        setLegend([])
    }, [])
    const pick = useCallback(
        (index: number) => {
            goTo(index)
            close()
        },
        [goTo, close],
    )
    const start = useCallback(() => setOpen(true), [])
    const element = open ? (
        <Dropdown<number>
            label="find:"
            search={search}
            noMatch="no match"
            onPick={pick}
            onCancel={close}
            take="go to"
            cancel="close"
            lines={FIND_LINES}
            onLegend={setLegend}
        />
    ) : null
    return { open, element, legend: open ? legend : [], start }
}
