// SPDX-License-Identifier: LGPL-3.0-or-later

import { usePaste } from "ink"
import { useCallback, useState } from "react"
import { type KeyInput, keys } from "./keys.js"
import { TextBuffer } from "./text-buffer.js"
import { useScreenActive } from "./nav.js"

/**
 * The state of a one-line text input and the one function that feeds it key presses.
 *
 * @property buffer - the text and the cursor.
 * @property edit - applies a key press to the buffer if it is an editing key (a typed
 *     character, backspace, delete, left, right, home, end); returns `true` if the
 *     key was one, so the caller can go on with its own keys otherwise.
 * @property set - replaces the whole buffer (a completion, a reset).
 */
export type TextInput = {
    buffer: TextBuffer
    edit:   (press: KeyInput) => boolean
    set:    (buffer: TextBuffer) => void
}

/**
 * Keeps the text of an input. The caller still owns the keys that end the input
 * (Enter, Esc, Tab, arrows of a list): it calls `edit` first and handles the press
 * itself when `edit` says it is not an editing key.
 *
 * Pasted text (the terminal's bracketed paste) is inserted whole, newlines dropped.
 *
 * @param initial - the starting text, empty when left out.
 * @param maxLength - the most characters taken, unlimited when left out.
 * @param active - whether this input listens to pastes, `true` when left out.
 * @returns the [[TextInput]].
 */
export function useTextBuffer(
    initial: string = "",
    maxLength: number = Number.POSITIVE_INFINITY,
    active: boolean = true
): TextInput {
    const onTop = useScreenActive()
    const [buffer, set] = useState(() => new TextBuffer(initial, undefined, maxLength))

    usePaste((pasted) => set((b) => b.insert(pasted.trim())), { isActive: active && onTop })

    const edit = useCallback((press: KeyInput): boolean => {
        if (press.typed) set((b) => b.insert(press.text))
        else if (press.is(keys.backspace)) set((b) => b.backspace())
        else if (press.is(keys.delete)) set((b) => b.delete())
        else if (press.is(keys.left)) set((b) => b.left())
        else if (press.is(keys.right)) set((b) => b.right())
        else if (press.key_ === "home") set((b) => b.home())
        else if (press.key_ === "end") set((b) => b.end())
        else return false
        return true
    }, [])

    return { buffer, edit, set }
}
