// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { padWidth, truncate } from "../core/text.js"
import { CursorList, ListText } from "./cursor-list.js"
import { centredWindow } from "./scroll-window.js"
import { Swatch, swatchCells } from "./swatch.js"
import { useTheme } from "./theme.js"

/**
 * One line of a list of suggestions.
 *
 * @property label - the text shown.
 * @property completion - what Tab puts into the input, `label` when left out (a path
 *     hint shows the file name but completes the whole path).
 * @property tag - a short kind shown muted after it (`solute`, `polymer`, `custom`).
 * @property swatch - a colour (`#rrggbb`) drawn as a swatch before the label. A list
 *     where any item has one keeps the column for all, so the labels stay aligned.
 */
export type Suggestion = {
    label: string
    completion?: string
    tag?: string
    swatch?: string
}

/**
 * The position of the highlight in a list, for the status line under it.
 *
 * @param index - the highlighted item.
 * @param count - how many items there are (at least 1).
 * @returns `3 of 12`.
 */
export function positionStatus(index: number, count: number): string {
    return `${index + 1} of ${count}`
}

/**
 * A list of suggestions under an input, the highlighted one marked with `>`: a
 * [[CursorList]] over a window centred on the highlight.
 *
 * @param items - the suggestions, best first.
 * @param highlight - the index of the highlighted one.
 * @param lines - the most items shown; the list scrolls to keep the highlight in view.
 * @param width - the cells each line may use.
 * @param status - a line below the items (`no match`, `3 more`), omitted when empty.
 * @returns the list.
 */
export function SuggestionList(props: {
    items:     Suggestion[]
    highlight: number
    lines:     number
    width:     number
    status?:   string
}): ReactNode {
    const { items, highlight, lines, width, status } = props
    const theme = useTheme()
    const swatches = items.some((item) => item.swatch !== undefined)
    // the marker and its gap, then the swatch and its gap
    const taken = 2 + (swatches ? swatchCells + 1 : 0)
    return (
        <Box flexDirection="column">
            <CursorList
                items={items}
                index={highlight}
                offset={centredWindow(items.length, highlight, lines)}
                lines={lines}
                row={(item, on) => {
                    const tag = item.tag ? ` ${item.tag}` : ""
                    const room = Math.max(1, width - taken - tag.length)
                    return (
                        <ListText on={on}>
                            {swatches ? <Swatch colour={item.swatch} /> : null}
                            {swatches ? " " : null}
                            {padWidth(truncate(item.label, room), room)}
                            <Text dimColor>{tag}</Text>
                        </ListText>
                    )
                }}
            />
            {status ? <Text color={theme.mt}>{truncate(status, width)}</Text> : null}
        </Box>
    )
}
