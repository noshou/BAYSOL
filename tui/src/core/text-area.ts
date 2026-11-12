// SPDX-License-Identifier: LGPL-3.0-or-later

// The rules of the multi-line text editor as pure values: the text with its cursor, every
// edit a new value, and the cells of a line that a window shows. The editor itself
// (`ui/text-area.tsx`) only feeds it key presses and draws what these functions say.
//
// Long lines are NOT wrapped: a line is as long as its text and the window scrolls
// sideways with the cursor, as the one-line input does. That keeps the cursor, the column
// counter and the up and down arrows honest (a screen row is a line, always).
//
// Contents:
//   1. Text: cleaning pasted text, counting characters, cutting a line to cells
//   2. `TextArea`: the text and the cursor as an immutable value

import stringWidth from "string-width"
import { takeWidth } from "./terminal.js"

// ========================================================================================
// 1. Text
// ========================================================================================

/** The spaces a Tab (typed or pasted) becomes. */
export const TAB_SPACES = 4

const segmenter = new Intl.Segmenter()

/** The characters (graphemes) of a text, the way the user counts them. */
function graphemesOf(text: string): string[] {
    return [...segmenter.segment(text)].map((s) => s.segment)
}

/**
 * The number of characters of a text as the user counts them (a line break is one).
 *
 * @param text - the text.
 * @returns the count of graphemes.
 */
export function textLength(text: string): number {
    let n = 0
    for (const _ of segmenter.segment(text)) n++
    return n
}

/**
 * Typed or pasted text as the editor takes it: line breaks of every system become `\n`,
 * a tab becomes [[TAB_SPACES]] spaces, any other control character is dropped.
 *
 * @param typed - what arrived.
 * @returns the text to insert.
 */
export function cleanText(typed: string): string {
    return typed
        .replace(/\r\n?/g, "\n")
        .replace(/\t/g, " ".repeat(TAB_SPACES))
        .replace(/[\p{Cc}]/gu, (c) => (c === "\n" ? c : ""))
}

/**
 * The longest start of a line that is at most some cells wide, as a length in code units
 * (where the cursor stands when an arrow key keeps the column).
 *
 * @param line - the line.
 * @param cells - the cells wanted.
 * @returns the offset into `line`, at a character boundary.
 */
export function offsetAtCell(line: string, cells: number): number {
    return takeWidth(line, cells).length
}

/**
 * The cells `[left, left + width)` of a line, as text: a wide character that straddles
 * the left edge shows as spaces, one that straddles the right edge is left out. A line
 * that ends before the window gives less than `width` cells.
 *
 * @param line - the line.
 * @param left - the first cell shown.
 * @param width - how many cells at most.
 * @returns the visible text.
 */
export function windowLine(line: string, left: number, width: number): string {
    let out = ""
    let cell = 0
    for (const g of graphemesOf(line)) {
        const w = stringWidth(g)
        if (cell + w <= left) {
            cell += w
            continue
        }
        if (cell + w > left + width) break
        out += cell < left ? " ".repeat(cell + w - left) : g
        cell += w
    }
    return out
}

// ========================================================================================
// 2. TextArea
// ========================================================================================

/**
 * The text of a multi-line input and the place of its cursor, as a value: every edit
 * gives a new area, so the editing rules can be tested without a terminal.
 *
 * The text is kept as lines (the text split at `\n`, so a text ending in a line break
 * ends in an empty line). The cursor is a line and an offset into it in UTF-16 code
 * units that only stands between characters the user sees as one. `up` and `down` keep
 * the cell the cursor was in (`want`) across short lines, as editors do.
 *
 * @param text - the whole text, lines joined by `\n`.
 * @param row - the line of the cursor, the last when left out.
 * @param col - the offset in the line, the end of it when left out.
 * @param want - the cell `up` and `down` keep, `undefined` when the last move was not one.
 */
export class TextArea {
    readonly lines: readonly string[]
    readonly row: number
    readonly col: number
    private readonly want: number | undefined

    constructor(
        text: string = "",
        row?: number,
        col?: number,
        want?: number,
    ) {
        this.lines = text.split("\n")
        const lastRow = this.lines.length - 1
        this.row = Math.min(Math.max(row ?? lastRow, 0), lastRow)
        const line = this.lines[this.row] as string
        this.col = Math.min(Math.max(col ?? line.length, 0), line.length)
        this.want = want
    }

    /** The whole text. */
    get text(): string {
        return this.lines.join("\n")
    }

    /** The line the cursor is on. */
    get line(): string {
        return this.lines[this.row] as string
    }

    /** The cell of the cursor in its line (a wide character takes two). */
    get cell(): number {
        return stringWidth(this.line.slice(0, this.col))
    }

    /** A copy with other lines and cursor. */
    private with(
        lines: readonly string[],
        row: number,
        col: number,
        want?: number,
    ): TextArea {
        return new TextArea(lines.join("\n"), row, col, want)
    }

    /**
     * Types text at the cursor: line breaks start new lines, tabs are spaces
     * ([[cleanText]]).
     *
     * @param typed - the text, one character or a paste.
     * @returns the new area.
     */
    insert(typed: string): TextArea {
        const parts = cleanText(typed).split("\n")
        const last = parts.length - 1
        const typedEnd = (parts[last] as string).length
        const col = last === 0 ? this.col + typedEnd : typedEnd
        parts[0] = this.line.slice(0, this.col) + parts[0]
        parts[last] = parts[last] + this.line.slice(this.col)
        const lines = [
            ...this.lines.slice(0, this.row),
            ...parts,
            ...this.lines.slice(this.row + 1),
        ]
        return this.with(lines, this.row + last, col)
    }

    /** Starts a new line at the cursor (Enter). */
    newline(): TextArea {
        return this.insert("\n")
    }

    /** Deletes the character before the cursor; at a line start joins the line above. */
    backspace(): TextArea {
        if (this.col > 0) {
            const before = graphemesOf(this.line.slice(0, this.col))
            const start = this.col - (before.pop() as string).length
            const line = this.line.slice(0, start) + this.line.slice(this.col)
            return this.with(this.replaced(line), this.row, start)
        }
        if (this.row === 0) return this
        const above = this.lines[this.row - 1] as string
        const lines = [
            ...this.lines.slice(0, this.row - 1),
            above + this.line,
            ...this.lines.slice(this.row + 1),
        ]
        return this.with(lines, this.row - 1, above.length)
    }

    /** Deletes the character at the cursor; at a line end joins the next line to it. */
    delete(): TextArea {
        if (this.col < this.line.length) {
            const first = graphemesOf(this.line.slice(this.col))[0] as string
            const rest = this.line.slice(this.col + first.length)
            const line = this.line.slice(0, this.col) + rest
            return this.with(this.replaced(line), this.row, this.col)
        }
        if (this.row === this.lines.length - 1) return this
        const lines = [
            ...this.lines.slice(0, this.row),
            this.line + (this.lines[this.row + 1] as string),
            ...this.lines.slice(this.row + 2),
        ]
        return this.with(lines, this.row, this.col)
    }

    /** The lines with the cursor's line replaced. */
    private replaced(line: string): string[] {
        return this.lines.map((l, i) => (i === this.row ? line : l))
    }

    /** One character left; at a line start the end of the line above. */
    left(): TextArea {
        if (this.col > 0) {
            const last = graphemesOf(this.line.slice(0, this.col)).pop() as string
            return this.with(this.lines, this.row, this.col - last.length)
        }
        if (this.row === 0) return this
        const above = this.lines[this.row - 1] as string
        return this.with(this.lines, this.row - 1, above.length)
    }

    /** One character right; at a line end the start of the line below. */
    right(): TextArea {
        if (this.col < this.line.length) {
            const first = graphemesOf(this.line.slice(this.col))[0] as string
            return this.with(this.lines, this.row, this.col + first.length)
        }
        if (this.row === this.lines.length - 1) return this
        return this.with(this.lines, this.row + 1, 0)
    }

    /**
     * Moves the cursor some lines up (negative) or down, keeping its cell where the line
     * is long enough, else at the end of the line. At the first line an up goes to the
     * start of the text, at the last line a down goes to the end of it.
     *
     * @param by - the lines, negative for up.
     * @returns the new area.
     */
    move(by: number): TextArea {
        const target = this.row + by
        if (target < 0) return this.with(this.lines, 0, 0)
        if (target > this.lines.length - 1) {
            const last = this.lines.at(-1) as string
            return this.with(this.lines, this.lines.length - 1, last.length)
        }
        const want = this.want ?? this.cell
        const col = offsetAtCell(this.lines[target] as string, want)
        return this.with(this.lines, target, col, want)
    }

    /** One line up. */
    up(): TextArea {
        return this.move(-1)
    }

    /** One line down. */
    down(): TextArea {
        return this.move(1)
    }

    /** To the start of the line. */
    home(): TextArea {
        return this.with(this.lines, this.row, 0)
    }

    /** To the end of the line. */
    end(): TextArea {
        return this.with(this.lines, this.row, this.line.length)
    }
}
