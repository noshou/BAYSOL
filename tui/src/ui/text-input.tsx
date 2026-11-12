// SPDX-License-Identifier: LGPL-3.0-or-later

// The one-line text input: the text and cursor of an input as a value, the hook that keeps
// it as state (paste and keys), and the field that draws it.
//
// Contents:
//   1. `TextBuffer`: the text and cursor of an input as an immutable value
//   2. `useTextBuffer`: the buffer as state, with paste and key handling
//   3. `TextField`: draws a buffer with its cursor

import { Text, usePaste } from "ink"
import { type ReactNode, useCallback, useState } from "react"
import { displayWidth, truncateStart } from "../core/terminal.js"
import { type KeyInput, keys, useScreenActive } from "./interaction.js"
import { useTheme } from "./theme.js"

// ========================================================================================
// 1. TextBuffer
// ========================================================================================

/**
 * The text of a one-line input and the place of its cursor, as a value: every edit
 * gives a new buffer, so the state of a component is just "a `TextBuffer`" and the
 * editing rules can be tested without a terminal.
 *
 * The cursor counts UTF-16 code units; it only ever stands between characters that
 * the user sees as one, because every edit moves it by whole graphemes.
 *
 * @param text - what is typed so far.
 * @param cursor - where the next character goes, `text.length` when left out.
 * @param maxLength - the most characters (graphemes) the input takes; `Infinity`
 *     when left out. Typing more is cut, and [[TextBuffer.full]] says it happened so
 *     the screen can tell the user (a limit that caps typing is never silent).
 */
export class TextBuffer {
    readonly cursor: number

    constructor(
        readonly text: string = "",
        cursor?: number,
        readonly maxLength: number = Number.POSITIVE_INFINITY
    ) {
        this.cursor = Math.min(Math.max(cursor ?? text.length, 0), text.length)
    }

    /** The characters (graphemes) the user sees. */
    private get units(): string[] {
        return [...new Intl.Segmenter().segment(this.text)].map((s) => s.segment)
    }

    /** The number of characters the user sees. */
    get length(): number {
        return this.units.length
    }

    /** `true` when the buffer holds `maxLength` characters, so typing is refused. */
    get full(): boolean {
        return this.length >= this.maxLength
    }

    /** A copy with another text and cursor, same limit. */
    private with(text: string, cursor?: number): TextBuffer {
        return new TextBuffer(text, cursor, this.maxLength)
    }

    /**
     * Types text at the cursor (a pasted text may be many characters, newlines
     * become nothing).
     *
     * @param typed - the text to insert.
     * @returns the new buffer; characters beyond `maxLength` are dropped.
     */
    insert(typed: string): TextBuffer {
        const clean = typed.replace(/[\r\n]+/g, "")
        const room = this.maxLength - this.length
        const take = [...new Intl.Segmenter().segment(clean)].slice(0, Math.max(0, room))
        const add = take.map((s) => s.segment).join("")
        const text = this.text.slice(0, this.cursor) + add + this.text.slice(this.cursor)
        return this.with(text, this.cursor + add.length)
    }

    /** Deletes the character before the cursor. */
    backspace(): TextBuffer {
        if (this.cursor === 0) return this
        const before = this.text.slice(0, this.cursor)
        const last = [...new Intl.Segmenter().segment(before)].pop()?.segment ?? ""
        const start = this.cursor - last.length
        return this.with(this.text.slice(0, start) + this.text.slice(this.cursor), start)
    }

    /** Deletes the character at the cursor. */
    delete(): TextBuffer {
        const after = this.text.slice(this.cursor)
        const first = [...new Intl.Segmenter().segment(after)][0]?.segment ?? ""
        const text = this.text.slice(0, this.cursor) + after.slice(first.length)
        return this.with(text, this.cursor)
    }

    /** Moves the cursor one character left. */
    left(): TextBuffer {
        if (this.cursor === 0) return this
        const before = this.text.slice(0, this.cursor)
        const last = [...new Intl.Segmenter().segment(before)].pop()?.segment ?? ""
        return this.with(this.text, this.cursor - last.length)
    }

    /** Moves the cursor one character right. */
    right(): TextBuffer {
        const after = this.text.slice(this.cursor)
        const first = [...new Intl.Segmenter().segment(after)][0]?.segment ?? ""
        return this.with(this.text, this.cursor + first.length)
    }

    /** Moves the cursor to the start. */
    home(): TextBuffer {
        return this.with(this.text, 0)
    }

    /** Moves the cursor to the end. */
    end(): TextBuffer {
        return this.with(this.text, this.text.length)
    }

    /** Replaces the whole text (a completion), the cursor goes to its end. */
    replace(text: string): TextBuffer {
        return this.with(text).end()
    }
}

// ========================================================================================
// 2. useTextBuffer
// ========================================================================================

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
 * Pasted text (the terminal's bracketed paste) is inserted whole, newlines dropped,
 * unless `onPaste` takes it.
 *
 * @param initial - the starting text, empty when left out.
 * @param maxLength - the most characters taken, unlimited when left out.
 * @param active - whether this input listens to pastes, `true` when left out.
 * @param onPaste - sees the pasted text first (line breaks kept); `true` means it took
 *     it and nothing is inserted (a sequence prompt takes a multi-line paste whole).
 * @returns the [[TextInput]].
 */
export function useTextBuffer(
    initial: string = "",
    maxLength: number = Number.POSITIVE_INFINITY,
    active: boolean = true,
    onPaste?: (text: string, room: number) => boolean,
): TextInput {
    const onTop = useScreenActive()
    const [buffer, set] = useState(() => new TextBuffer(initial, undefined, maxLength))

    usePaste(
        (pasted) => {
            if (onPaste?.(pasted, maxLength - buffer.length)) return
            set((b) => b.insert(pasted.trim()))
        },
        { isActive: active && onTop },
    )

    const edit = useCallback((press: KeyInput): boolean => {
        if (press.typed) set((b) => b.insert(press.text))
        else if (press.is(keys.backspace)) set((b) => b.backspace())
        else if (press.is(keys.delete)) set((b) => b.delete())
        else if (press.is(keys.left)) set((b) => b.left())
        else if (press.is(keys.right)) set((b) => b.right())
        else if (press.is(keys.home)) set((b) => b.home())
        else if (press.is(keys.end)) set((b) => b.end())
        else return false
        return true
    }, [])

    return { buffer, edit, set }
}

// ========================================================================================
// 3. TextField
// ========================================================================================

/**
 * The cells [[TextField]] draws for a buffer (the text, plus one for the cursor cell
 * after its end), never more than its room: a caller that puts a field into a table cell
 * pads the rest with spaces.
 *
 * @param buffer - the text and the cursor.
 * @param width - the cells the field may use.
 * @returns the cells drawn.
 */
export function fieldCells(buffer: TextBuffer, width: number): number {
    const atEnd = buffer.cursor >= buffer.text.length
    return Math.min(width, displayWidth(buffer.text) + (atEnd ? 1 : 0))
}

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
    { buffer, width, placeholder }:
        { buffer: TextBuffer; width: number; placeholder?: string }
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
                <Text color={theme.bg} backgroundColor={theme.fg}>{" "}</Text>
                <Text color={theme.mt}>{placeholder}</Text>
            </Text>
        )
    return (
        <Text color={theme.fg}>
            {before}
            <Text color={theme.bg} backgroundColor={theme.fg}>{at}</Text>
            {after}
        </Text>
    )
}
