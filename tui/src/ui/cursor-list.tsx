// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { useTheme } from "./theme.js"

/**
 * The text of one row of a [[CursorList]]: the foreground colour and bold on the row the
 * cursor is on, muted otherwise. A row that mixes cells (a logo, a swatch) uses it for
 * the part that is text.
 *
 * @param props.on - whether the cursor is on the row.
 * @param props.children - the text.
 * @returns the text.
 */
export function ListText(
    { on, children }: { on: boolean; children?: ReactNode },
): ReactNode {
    const theme = useTheme()
    return (
        <Text color={on ? theme.fg : theme.mt} bold={on}>
            {children}
        </Text>
    )
}

/**
 * The one list with a cursor of the program: a `>` before the row the cursor is on, the
 * rows from `offset` on, `lines` of them, each drawn by `row`. The suggestions under an
 * input, the theme picker, the settings pickers and the options of the landing pages are
 * all this list; they differ in what a row looks like and in who owns the cursor (a
 * [[useListCursor]], or a highlight that scrolls with a centred window).
 *
 * @typeParam T - what a row is made from.
 * @param props.items - every row of the list.
 * @param props.index - the row the cursor is on.
 * @param props.offset - the first row shown (see `scroll-window.ts`).
 * @param props.lines - the most rows shown.
 * @param props.row - draws one row after its marker; `on` is whether the cursor is on it
 *     and the list is active.
 * @param props.heading - the text of a row that is only a heading (`-- light themes --`:
 *     muted, no marker, never `on`; the owner of the cursor must skip it), `undefined`
 *     for a row `row` draws.
 * @param props.active - `false` while the list is shown but not driving (a dropdown is
 *     open under it): the marker stays on its row, but every row is muted. `true` when
 *     left out.
 * @returns the rows.
 */
export function CursorList<T>(props: {
    items:    readonly T[]
    index:    number
    offset:   number
    lines:    number
    row:      (item: T, on: boolean) => ReactNode
    heading?: (item: T) => string | undefined
    active?:  boolean
}): ReactNode {
    const { items, index, offset, lines, row, heading, active = true } = props
    const theme = useTheme()
    return (
        <Box flexDirection="column">
            {items.slice(offset, offset + lines).map((item, i) => {
                const at = offset + i
                const title = heading?.(item)
                if (title !== undefined)
                    return <Text key={at} color={theme.mt}>{title}</Text>
                const here = at === index
                const on = here && active
                return (
                    <Box key={at} columnGap={1}>
                        <Text color={on ? theme.fg : theme.mt} bold={on}>
                            {here ? ">" : " "}
                        </Text>
                        {row(item, on)}
                    </Box>
                )
            })}
        </Box>
    )
}
