// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { Fragment, type ReactNode } from "react"
import { displayWidth, padWidth, truncate } from "../core/text.js"
import { Bar, Rule } from "./table-segments.js"
import { useTheme } from "./theme.js"

/**
 * One column of a [[DataTable]].
 *
 * @typeParam R - the row type.
 * @property title - the header text.
 * @property width - a fixed width in cells; without it the column shares the rest of
 *     the width with the other flexible ones (`grow`).
 * @property grow - the share of the remaining width, 1 when left out.
 * @property align - `"right"` for numbers, `"left"` when left out.
 * @property text - the cell's text for a row.
 */
export type Column<R> = {
    title:  string
    width?: number
    grow?:  number
    align?: "left" | "right"
    text:   (row: R) => string
}

/**
 * What a table is told.
 *
 * @property columns - the columns, left to right.
 * @property rows - all the rows (the table shows the window from `offset`).
 * @property cursor - the index of the row the cursor is on.
 * @property offset - the first row shown.
 * @property pageSize - how many rows are shown.
 * @property mark - the one-character mark of a row (`*` new or edited, `-` marked for
 *     removal, a space for none); drawn in front of the first column.
 * @property empty - what to say when there are no rows.
 * @property width - the cells the table may use (the body width of the terminal).
 */
type DataTableProps<R> = {
    columns:  Column<R>[]
    rows:     R[]
    cursor:   number
    offset:   number
    pageSize: number
    mark?:    (row: R) => string
    empty?:   string
    width:    number
}

/** The cells taken by the cursor, the mark and the separators that frame the cells. */
const gutter = 3

/**
 * Works out the width of every column: the fixed ones as given, the flexible ones
 * share what is left in proportion to their `grow`, none narrower than its title.
 *
 * @param columns - the columns.
 * @param width - the total width of the table.
 * @returns one width per column, in order.
 */
export function columnWidths<R>(columns: Column<R>[], width: number): number[] {
    // each cell has one space of padding on both sides and the columns share one rule
    const room = width - gutter - columns.length * 3
    const fixed = columns.reduce((sum, c) => sum + (c.width ?? 0), 0)
    const grows = columns.reduce(
        (sum, c) => sum + (c.width === undefined ? (c.grow ?? 1) : 0),
        0,
    )
    const left = Math.max(0, room - fixed)
    return columns.map((c) =>
        c.width ??
            Math.max(displayWidth(c.title), Math.floor((left * (c.grow ?? 1)) / grows))
    )
}

/**
 * A table of rows that scrolls under a cursor: a header, a rule, then the rows of the
 * window, the cursor row marked with `>` and drawn in the full foreground colour.
 * Widths follow the terminal, nothing is fixed.
 *
 * @param props - see [[DataTableProps]].
 * @returns the table.
 */
export function DataTable<R>(props: DataTableProps<R>): ReactNode {
    const { columns, rows, cursor, offset, pageSize, mark, empty, width } = props
    const theme = useTheme()
    const widths = columnWidths(columns, width)

    // a row of text segments in the colour of the row, the separators in the border colour
    const line = (
        cells: string[],
        lead: string,
        ink: string,
        bold: boolean,
    ): ReactNode => (
        <Text>
            <Text color={ink} bold={bold}>{lead}</Text>
            {cells.map((c, i) => {
                const col = columns[i] as Column<R>
                const w = widths[i] as number
                const cut = truncate(c, w)
                const pad = " ".repeat(Math.max(0, w - displayWidth(cut)))
                const body = col.align === "right" ? pad + cut : padWidth(cut, w)
                return (
                    // biome-ignore lint/suspicious/noArrayIndexKey: a column is its place
                    <Fragment key={i}>
                        {i > 0 ? <Bar style="single" /> : null}
                        <Text color={ink} bold={bold}>{` ${body} `}</Text>
                    </Fragment>
                )
            })}
        </Text>
    )

    const shown = rows.slice(offset, offset + pageSize)
    return (
        <Box flexDirection="column">
            {line(columns.map((c) => c.title), "   ", theme.fg, true)}
            <Rule
                style="single"
                part="mid"
                widths={widths.map((w) => w + 2)}
                options={{ frame: false, lead: 3 }}
            />
            {rows.length === 0 ? (
                <Text color={theme.mt}>{empty ?? "nothing here yet"}</Text>
            ) : null}
            {shown.map((row, i) => {
                const on = offset + i === cursor
                const ink = on ? theme.fg : theme.mt
                const lead = `${on ? ">" : " "}${mark ? mark(row) : " "} `
                return (
                    // biome-ignore lint/suspicious/noArrayIndexKey: position is the id
                    <Fragment key={offset + i}>
                        {line(columns.map((c) => c.text(row)), lead, ink, on)}
                    </Fragment>
                )
            })}
            {rows.length > pageSize ? (
                <Text color={theme.mt}>{`${cursor + 1} / ${rows.length}`}</Text>
            ) : null}
        </Box>
    )
}
