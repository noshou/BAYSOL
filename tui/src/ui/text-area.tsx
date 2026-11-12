// SPDX-License-Identifier: LGPL-3.0-or-later

// The multi-line text editor: the hook that keeps a [[TextArea]] as state (keys and
// paste), and the view that draws it with a visible cursor. The rules (cursor moves,
// inserting, deleting, the cap) are in `core/text-area.ts`; the scroll rules are the
// shared [[scrollWindow]].
//
// Contents:
//   1. `useTextArea`: the area as state, with key and paste handling
//   2. `TextAreaView`: draws the lines in view

import { Box, Text, usePaste } from "ink"
import { type ReactNode, useCallback, useRef, useState } from "react"
import { takeWidth } from "../core/terminal.js"
import { TAB_SPACES, TextArea, windowLine } from "../core/text-area.js"
import { type KeyInput, keys, scrollWindow, useScreenActive } from "./interaction.js"
import { useTheme } from "./theme.js"

// ========================================================================================
// 1. useTextArea
// ========================================================================================

/**
 * The state of a multi-line input and the function that feeds it key presses.
 *
 * @property area - the text and the cursor.
 * @property edit - applies a key press if it is an editing key (a typed character, Enter,
 *     Tab, backspace, delete, the arrows, home, end, page up, page down); returns `true`
 *     if it was one, so the caller can go on with its own keys otherwise.
 * @property set - replaces the whole area.
 */
export type TextAreaInput = {
    area: TextArea
    edit: (press: KeyInput, page: number) => boolean
    set: (area: TextArea) => void
}

/**
 * Keeps the text of a multi-line input. The caller still owns the keys that save and
 * leave (`^w`, Esc, `^x`): it calls `edit` first and handles the press itself when `edit`
 * says it is not an editing key. A pasted text (the terminal's bracketed paste) is
 * inserted whole, line breaks kept and tabs made spaces.
 *
 * @param initial - the starting text.
 * @param active - whether the input listens to pastes, `true` when left out.
 * @returns the [[TextAreaInput]]; the cursor starts at the top of the text.
 */
export function useTextArea(initial: string, active: boolean = true): TextAreaInput {
    const onTop = useScreenActive()
    const [area, set] = useState(() => new TextArea(initial, 0, 0))

    usePaste((pasted) => set((a) => a.insert(pasted)), { isActive: active && onTop })

    const edit = useCallback((press: KeyInput, page: number): boolean => {
        if (press.typed) set((a) => a.insert(press.text))
        else if (press.is(keys.enter)) set((a) => a.newline())
        else if (press.is(keys.tab)) set((a) => a.insert(" ".repeat(TAB_SPACES)))
        else if (press.is(keys.backspace)) set((a) => a.backspace())
        else if (press.is(keys.delete)) set((a) => a.delete())
        else if (press.is(keys.left)) set((a) => a.left())
        else if (press.is(keys.right)) set((a) => a.right())
        else if (press.is(keys.up)) set((a) => a.up())
        else if (press.is(keys.down)) set((a) => a.down())
        else if (press.is(keys.pageUp)) set((a) => a.move(-page))
        else if (press.is(keys.pageDown)) set((a) => a.move(page))
        else if (press.is(keys.home)) set((a) => a.home())
        else if (press.is(keys.end)) set((a) => a.end())
        else return false
        return true
    }, [])

    return { area, edit, set }
}

// ========================================================================================
// 2. TextAreaView
// ========================================================================================

/**
 * The lines of an area that are in view, the cursor drawn as an inverted cell. It keeps
 * the first line and the first cell shown between renders and moves them only as far as
 * the cursor needs, so the text does not jump while the cursor walks inside the window.
 * Lines are not wrapped: a long line scrolls sideways with the cursor.
 *
 * @param props.area - the text and the cursor.
 * @param props.rows - the lines the view has (always drawn, so its box keeps its height).
 * @param props.width - the cells of a line.
 * @returns the view.
 */
export function TextAreaView(
    { area, rows, width }: { area: TextArea; rows: number; width: number },
): ReactNode {
    const theme = useTheme()
    const view = useRef({ top: 0, left: 0 })
    const top = scrollWindow(area.row, view.current.top, rows, area.lines.length)
    const left = scrollWindow(area.cell, view.current.left, width, Number.POSITIVE_INFINITY)
    view.current = { top, left }

    const drawn = Array.from({ length: rows }, (_, i): ReactNode => {
        const at = top + i
        const line = area.lines[at]
        if (line === undefined) return <Text key={at}> </Text>
        if (at !== area.row)
            return (
                <Text key={at} color={theme.fg} wrap="truncate-end">
                    {windowLine(line, left, width) || " "}
                </Text>
            )
        // the line with one more cell, so a cursor after its end has a cell to be drawn in
        const visible = windowLine(`${line} `, left, width)
        const before = takeWidth(visible, area.cell - left)
        const rest = visible.slice(before.length)
        const under = [...new Intl.Segmenter().segment(rest)][0]?.segment ?? " "
        const after = visible.slice(before.length + under.length)
        return (
            <Text key={at} color={theme.fg} wrap="truncate-end">
                {before}
                <Text color={theme.bg} backgroundColor={theme.fg}>{under}</Text>
                {after}
            </Text>
        )
    })
    return (
        <Box flexDirection="column" height={rows} width={width}>
            {drawn}
        </Box>
    )
}
