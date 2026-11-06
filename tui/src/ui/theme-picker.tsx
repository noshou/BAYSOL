// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text, useWindowSize } from "ink"
import type { ReactNode } from "react"
import { padWidth } from "../core/text.js"
import { CursorList, ListText } from "./cursor-list.js"
import { keys } from "./keys.js"
import { Logo } from "./logo.js"
import { Panel } from "./panel.js"
import { Swatch } from "./swatch.js"
import {
    darkThemes,
    lightThemes,
    type Theme,
    useTheme,
} from "./theme.js"
import { useKeys } from "./use-keys.js"
import { useListCursor } from "./use-list-cursor.js"

/** The rows of the popup that are not list entries: its border, title and key line. */
const popupChrome = 6

/** One line of the list: a heading (`-- light themes --`) or a theme to stand on. */
type Entry = { heading: string } | { theme: Theme }

/** The list: each group of themes under its heading. */
const entries: readonly Entry[] = [
    { heading: "-- light themes --" },
    ...lightThemes.map((theme) => ({ theme })),
    { heading: "-- dark themes --" },
    ...darkThemes.map((theme) => ({ theme })),
]

/**
 * The next line the cursor can stand on (a theme, never a heading) in one direction.
 *
 * @param from - the line the cursor is on.
 * @param direction - `1` for down, `-1` for up.
 * @returns the index of the next theme line, or `from` at the end of the list.
 */
function nextTheme(from: number, direction: 1 | -1): number {
    for (let i = from + direction; i >= 0 && i < entries.length; i += direction)
        if ("theme" in entries[i]) return i
    return from
}

/**
 * The four colours a theme row shows: background, foreground, muted and error.
 *
 * @param theme - the theme.
 * @returns the colours, in that order.
 */
function swatchesOf(theme: Theme): string[] {
    return [theme.bg, theme.fg, theme.mt, theme.er]
}

/**
 * The popup that picks a theme: one row for each theme (its logo, its name and the
 * swatches of its four colours), scrolled with the arrow keys, Enter picks and Esc (or
 * `^t` again) leaves. It is drawn in the colours of the theme in use now; nothing
 * changes until a theme is picked. While it is open it is the only thing that takes keys.
 *
 * @param current - the theme in use; the cursor starts on it.
 * @param onPick - called with the theme that Enter picked.
 * @param onClose - called when the popup is left without picking.
 * @returns the popup box, to be placed over the screen.
 */
export function ThemePicker(
    { current, onPick, onClose }:
        { current: Theme; onPick: (theme: Theme) => void; onClose: () => void }
): ReactNode {
    const theme = useTheme()
    const { rows } = useWindowSize()
    const pageSize = Math.max(3, Math.min(entries.length, rows - popupChrome))
    const start = entries.findIndex((e) => "theme" in e && e.theme === current)
    const cursor = useListCursor(entries.length, pageSize, Math.max(0, start))
    const nameCells = Math.max(
        ...entries.map((e) => ("theme" in e ? e.theme.nm.length : 0)),
    )

    useKeys((press) => {
        const here = entries[cursor.index]
        if (press.is(keys.escape) || press.is(keys.theme)) onClose()
        else if (press.is(keys.enter) && "theme" in here) onPick(here.theme)
        else if (press.is(keys.up)) cursor.set(nextTheme(cursor.index, -1))
        else if (press.is(keys.down)) cursor.set(nextTheme(cursor.index, 1))
    })

    return (
        <Panel flexDirection="column" paddingX={1}>
            <Text bold color={theme.fg}>theme</Text>
            <CursorList
                items={entries}
                index={cursor.index}
                offset={cursor.offset}
                lines={pageSize}
                heading={(e) => ("heading" in e ? e.heading : undefined)}
                row={(e, on) => {
                    if ("heading" in e) return null
                    return (
                        <Box columnGap={1}>
                            <Logo theme={e.theme} />
                            <ListText on={on}>{padWidth(e.theme.nm, nameCells)}</ListText>
                            <Box>
                                {swatchesOf(e.theme).map((c) => (
                                    <Swatch key={c} colour={c} />
                                ))}
                            </Box>
                        </Box>
                    )
                }}
            />
            <Text color={theme.mt}>
                pick: {keys.enter.label}   close: {keys.escape.label}
            </Text>
        </Panel>
    )
}
