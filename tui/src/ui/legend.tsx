// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { type KeyInput, keyLabels, keys } from "./keys.js"
import { Panel } from "./panel.js"
import { useTheme } from "./theme.js"

/**
 * One line of a key legend.
 *
 * @property label - what the key does, e.g. `"save"`.
 * @property keys - the key, e.g. `"^w"` (`^` is the Ctrl key) or `"⏎"`.
 */
export type LegendItem = { label: string; keys: string }

/**
 * A legend item whose keys are written from the key constants, so a legend cannot
 * drift from the key it describes.
 *
 * @param label - what the key does, e.g. `"save"`.
 * @param parts - the keys, as for `keyLabels`: a key, or an array for a run written
 *     together (`[keys.up, keys.down]` is `↑↓`).
 * @returns the item.
 * @throws never.
 */
export function legendFor(label: string, ...parts: (KeyInput | KeyInput[])[]): LegendItem {
    return { label, keys: keyLabels(...parts) }
}

/** The legend items that nearly every screen has. */
/** Back one screen. */
export const legendBack: LegendItem = legendFor("back", keys.back)
/** Choose or edit what the cursor is on. */
export const legendEnter: LegendItem = legendFor("select", keys.enter)

/**
 * Which arrow keys do something right now.
 *
 * @property up - the cursor can go up.
 * @property down - the cursor can go down.
 * @property left - there is something to the left (a previous group).
 * @property right - there is something to the right (a next group).
 */
export type Moves = { up?: boolean; down?: boolean; left?: boolean; right?: boolean }

/**
 * The `move` item of a legend, with only the arrows that work from where the cursor
 * is (like the move hint of the menus): `↑↓` in the middle of a list, `↓` on its first
 * row, `←→` between groups.
 *
 * @param moves - which arrows work.
 * @returns the item, or `undefined` when no arrow works (nothing to move to).
 */
export function moveLegend(moves: Moves): LegendItem | undefined {
    const arrows = [
        moves.up && keys.up, moves.down && keys.down,
        moves.left && keys.left, moves.right && keys.right,
    ].filter((k): k is KeyInput => k !== false && k !== undefined)
    return arrows.length === 0 ? undefined : legendFor("move", arrows)
}

/**
 * Builds a legend from items that may not apply: a key that does nothing right now (undo
 * with nothing to undo, remove on an empty table) is left out, so the legend only ever
 * lists keys that work, as the move hint of the menus does.
 *
 * @param items - the items; `false` and `undefined` are skipped, so a screen writes
 *     `canUndo && legendFor("undo", keys.undo)`.
 * @returns the items that remain, in order.
 */
export function legendOf(items: (LegendItem | false | undefined)[]): LegendItem[] {
    return items.filter((item): item is LegendItem => Boolean(item))
}

/**
 * What the legend of an open prompt or dropdown depends on.
 *
 * @property count - how many suggestions it lists now (0 for a plain prompt).
 * @property pick - it is a dropdown: Enter takes the highlighted suggestion, so there
 *     must be one. A prompt takes what is typed.
 * @property canTake - a prompt's Enter has something to take (`true` when left out).
 * @property take - what Enter does, `"take"` when left out; `null` when Enter does
 *     nothing (a list that is only browsed), so it is not shown.
 * @property extras - keys of this particular overlay (`file picker o`), shown before
 *     `cancel`.
 * @property listedExtras - keys that work only while something is listed (`delete ^r`),
 *     shown after `extras`.
 * @property cancel - what Esc does, `"cancel"` when left out; `null` when Esc does
 *     nothing (a prompt that is the screen itself), so it is not shown.
 * @property back - Ctrl-X goes back one screen (it differs from Esc), shown last.
 */
export type EntryFacts = {
    count: number
    pick?: boolean
    canTake?: boolean
    take?: string | null
    extras?: LegendItem[]
    listedExtras?: LegendItem[]
    cancel?: string | null
    back?: boolean
}

/**
 * The legend of an open prompt or dropdown: `take` when Enter does something, `move`
 * only when the list has more than one entry, `complete` only when a suggestion is
 * highlighted, then the overlay's own keys, `cancel` and, when it has one, `back`.
 *
 * @param facts - what the overlay is showing.
 * @returns the items, in order.
 */
export function entryLegend(facts: EntryFacts): LegendItem[] {
    const { count, pick = false, canTake = true, take = "take", extras = [] } = facts
    const { listedExtras = [], cancel = "cancel", back = false } = facts
    return legendOf([
        take !== null && (pick ? count > 0 : canTake) && legendFor(take, keys.enter),
        moveLegend({ up: count > 1, down: count > 1 }),
        count > 0 && legendFor("complete", keys.tab),
        ...extras,
        ...(count > 0 ? listedExtras : []),
        cancel !== null && legendFor(cancel, keys.escape),
        back && legendBack,
    ])
}

/**
 * How a legend is laid out: `columns` puts the items in columns of up to three lines
 * with a `┃` between them (the tables, forms and sheets); `boxes` puts each item in a
 * small rounded box of its own (the landing pages).
 */
export type LegendStyle = "columns" | "boxes"

/** The lines of a column of the `columns` style, the height of a small logo. */
const columnLines = 3

/**
 * Cuts a list into the fewest pieces of at most `size`, as even as it can be, so the
 * columns of a legend look alike (four items are 2 + 2, not 3 + 1; seven are 3 + 2 + 2).
 *
 * @param items - the list.
 * @param size - the most items in a piece.
 * @returns the pieces, in order; the longer ones come first.
 */
export function chunks<T>(items: T[], size: number): T[][] {
    const count = Math.ceil(items.length / size)
    const out: T[][] = []
    let from = 0
    for (let i = 0; i < count; i++) {
        const length = Math.floor(items.length / count) + (i < items.length % count ? 1 : 0)
        out.push(items.slice(from, from + length))
        from += length
    }
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
                    <Panel key={item.label} paddingX={1}>
                        <Text color={theme.mt}>{text(item)}</Text>
                    </Panel>
                ))}
            </Box>
        )
    return (
        <Box columnGap={1}>
            {chunks(items, columnLines).map((column, i) => (
                <Box key={column[0].label} columnGap={1}>
                    {i > 0 ? (
                        <Text color={theme.mt}>
                            {Array(column.length).fill("┃").join("\n")}
                        </Text>
                    ) : null}
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
