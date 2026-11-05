// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { useTheme } from "./theme.js"

/**
 * One line of a key legend.
 *
 * @property label - what the key does, e.g. `"save"`.
 * @property keys - the key, e.g. `"^w"` (`^` is the Ctrl key) or `"⏎"`.
 */
export type LegendItem = { label: string; keys: string }

/** The legend items that nearly every screen has. */
export const legendQuit: LegendItem = { label: "quit", keys: "esc" }
/** Back one screen. */
export const legendBack: LegendItem = { label: "back", keys: "^x" }
/** Choose or edit what the cursor is on. */
export const legendEnter: LegendItem = { label: "select", keys: "⏎" }
/** Move the cursor. */
export const legendMove: LegendItem = { label: "move", keys: "↑↓" }

/**
 * How a legend is laid out: `columns` puts the items in columns of up to three lines
 * with a `┃` between them (the tables, forms and sheets); `boxes` puts each item in a
 * small rounded box of its own (the landing pages).
 */
export type LegendStyle = "columns" | "boxes"

/** The lines of a column of the `columns` style, the height of a small logo. */
const columnLines = 3

/**
 * Cuts a list into pieces of at most `size`.
 *
 * @param items - the list.
 * @param size - the most items in a piece.
 * @returns the pieces, in order.
 */
function chunks<T>(items: T[], size: number): T[][] {
    const out: T[][] = []
    for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
    return out
}

/**
 * Keys with what they do, as `label: keys` pairs, in the muted colour.
 *
 * @param items - the keys to show, in order.
 * @param style - `"columns"` or `"boxes"`, `"columns"` when left out.
 * @returns the legend; it wraps to the width of the terminal.
 */
export function Legend(
    { items, style = "columns" }: { items: LegendItem[]; style?: LegendStyle }
): ReactNode {
    const theme = useTheme()
    const text = (item: LegendItem) => `${item.label}: ${item.keys}`
    if (style === "boxes")
        return (
            <Box flexWrap="wrap" columnGap={1}>
                {items.map((item) => (
                    <Box key={item.label} borderStyle="round" borderColor={theme.mt} paddingX={1}>
                        <Text color={theme.mt}>{text(item)}</Text>
                    </Box>
                ))}
            </Box>
        )
    return (
        <Box columnGap={1}>
            {chunks(items, columnLines).map((column, i) => (
                <Box key={column[0].label} columnGap={1}>
                    {i > 0 ? <Text color={theme.mt}>{Array(column.length).fill("┃").join("\n")}</Text> : null}
                    <Box flexDirection="column">
                        {column.map((item) => (
                            <Text key={item.label} color={theme.mt}>{text(item)}</Text>
                        ))}
                    </Box>
                </Box>
            ))}
        </Box>
    )
}
