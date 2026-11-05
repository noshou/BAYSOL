// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { padWidth, truncate } from "../core/text.js"
import { useTheme } from "./theme.js"

/**
 * One line of a list of suggestions.
 *
 * @property label - the text shown.
 * @property completion - what Tab puts into the input, `label` when left out (a path
 *     hint shows the file name but completes the whole path).
 * @property tag - a short kind shown muted after it (`solute`, `polymer`, `custom`).
 */
export type Suggestion = { label: string; completion?: string; tag?: string }

/**
 * The lines of a list shown around the highlighted one, so a long list scrolls.
 *
 * @param count - how many items there are.
 * @param highlight - the index of the highlighted item.
 * @param lines - how many items fit.
 * @returns the index of the first item to show.
 */
export function listWindowStart(count: number, highlight: number, lines: number): number {
    if (count <= lines) return 0
    return Math.min(Math.max(highlight - Math.floor(lines / 2), 0), count - lines)
}

/**
 * A list of suggestions under an input, the highlighted one marked with `>`.
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
    const start = listWindowStart(items.length, highlight, lines)
    return (
        <Box flexDirection="column">
            {items.slice(start, start + lines).map((item, i) => {
                const on  = start + i === highlight
                const tag = item.tag ? ` ${item.tag}` : ""
                const room = Math.max(1, width - 2 - tag.length)
                return (
                    <Text key={start + i} color={on ? theme.fg : theme.mt} bold={on}>
                        {on ? "> " : "  "}
                        {padWidth(truncate(item.label, room), room)}
                        <Text dimColor>{tag}</Text>
                    </Text>
                )
            })}
            {status ? <Text color={theme.mt}>{truncate(status, width)}</Text> : null}
        </Box>
    )
}
