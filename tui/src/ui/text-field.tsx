// SPDX-License-Identifier: LGPL-3.0-or-later

import { Text } from "ink"
import type { ReactNode } from "react"
import { displayWidth, truncateStart } from "../core/text.js"
import { useTheme } from "./theme.js"
import type { TextBuffer } from "./text-buffer.js"

/**
 * The line of an input: the typed text with the cursor drawn as an inverted cell.
 * Text longer than the room scrolls so the cursor stays in view.
 *
 * @param buffer - the text and the cursor.
 * @param width - the cells the field may use.
 * @param placeholder - muted text shown while nothing is typed.
 * @returns the field.
 */
export function TextField(
    { buffer, width, placeholder }: { buffer: TextBuffer; width: number; placeholder?: string }
): ReactNode {
    const theme = useTheme()
    const [first] = [...new Intl.Segmenter().segment(buffer.text.slice(buffer.cursor))]
    const at     = first?.segment ?? " "
    const after  = buffer.text.slice(buffer.cursor + (first?.segment.length ?? 0))

    // keep the end of the text before the cursor, which is what the user is editing
    const room   = width - displayWidth(at) - displayWidth(after)
    const before = truncateStart(buffer.text.slice(0, buffer.cursor), Math.max(1, room))

    if (buffer.text === "" && placeholder)
        return (
            <Text>
                <Text inverse color={theme.fg}>{" "}</Text>
                <Text color={theme.mt}>{placeholder}</Text>
            </Text>
        )
    return (
        <Text color={theme.fg}>
            {before}
            <Text inverse>{at}</Text>
            {after}
        </Text>
    )
}
