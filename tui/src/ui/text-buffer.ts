// SPDX-License-Identifier: LGPL-3.0-or-later

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
        return this.with(this.text.slice(0, this.cursor) + after.slice(first.length), this.cursor)
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
