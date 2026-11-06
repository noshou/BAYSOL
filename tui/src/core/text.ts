// SPDX-License-Identifier: LGPL-3.0-or-later

import stringWidth from "string-width"
import wrapAnsi from "wrap-ansi"

/**
 * Text measured in terminal cells, not in characters: a wide character (CJK, most
 * emoji) takes two cells, a combining mark none. Cut text gets `…`, and a wide
 * character is never split.
 */

/** What marks text that was cut. */
const ellipsis = "…"

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

/**
 * The cells a text takes.
 *
 * @param text - the text, one line.
 * @returns its width in terminal cells.
 */
export function displayWidth(text: string): number {
    return stringWidth(text)
}

/**
 * The longest start of a text that fits in some cells.
 *
 * @param text - the text.
 * @param cells - the room.
 * @returns the start of `text` at most `cells` wide, cut at a character boundary.
 */
export function takeWidth(text: string, cells: number): string {
    let out = ""
    let used = 0
    for (const { segment } of graphemes.segment(text)) {
        const w = stringWidth(segment)
        if (used + w > cells) break
        out += segment
        used += w
    }
    return out
}

/**
 * Cuts a text to some cells, ending in `…` if it had to be cut.
 *
 * @param text - the text.
 * @param cells - the room; 0 or less gives an empty string.
 * @returns `text` if it fits, else its start with `…` as the last cell.
 */
export function truncate(text: string, cells: number): string {
    if (cells <= 0) return ""
    if (stringWidth(text) <= cells) return text
    return takeWidth(text, cells - 1) + ellipsis
}

/**
 * Cuts a text to some cells from the front, keeping its end (a path that is too long
 * shows where it ends).
 *
 * @param text - the text.
 * @param cells - the room.
 * @returns `text` if it fits, else `…` followed by its end.
 */
export function truncateStart(text: string, cells: number): string {
    if (cells <= 0) return ""
    if (stringWidth(text) <= cells) return text
    const parts = [...graphemes.segment(text)].map((s) => s.segment)
    let out = ""
    let used = 1
    for (let i = parts.length - 1; i >= 0; i--) {
        const w = stringWidth(parts[i])
        if (used + w > cells) break
        out = parts[i] + out
        used += w
    }
    return ellipsis + out
}

/**
 * Pads a text with spaces on the right to some cells.
 *
 * @param text - the text.
 * @param cells - the width wanted.
 * @returns the text, cut to `cells` if too long (with `…`), else padded.
 */
export function padWidth(text: string, cells: number): string {
    const cut = truncate(text, cells)
    return cut + " ".repeat(Math.max(0, cells - stringWidth(cut)))
}

/**
 * Breaks a text into lines of at most some cells, at spaces where it can.
 *
 * @param text - the text.
 * @param cells - the width of a line, at least 1.
 * @returns the lines; a word longer than a line is broken.
 */
export function wrapText(text: string, cells: number): string[] {
    return wrapAnsi(text, Math.max(1, cells), { hard: true, trim: true }).split("\n")
}

/**
 * The note that tells a cap was reached while typing a `what` (`name`, `text`). The one
 * place the wording lives.
 *
 * @param what - what is typed.
 * @param max - the most characters it may have.
 * @returns e.g. `name too long (40 at most)`.
 */
export function tooLong(what: string, max: number): string {
    return `${what} too long (${max} at most)`
}

/**
 * The text the way names are compared: trimmed and lower-cased.
 *
 * @param text - any text; `null` and `undefined` count as empty.
 * @returns the folded text.
 */
export function fold(text: string | null | undefined): string {
    return (text ?? "").trim().toLowerCase()
}

/**
 * Orders two texts without regard to case, by code unit (never by locale, which would
 * depend on the machine).
 *
 * @param a - a text.
 * @param b - a text.
 * @returns a negative number, 0 or a positive number, for `Array.sort`.
 */
export function compareNoCase(a: string, b: string): number {
    const [x, y] = [a.toLowerCase(), b.toLowerCase()]
    return x < y ? -1 : x > y ? 1 : 0
}

// --- numbers typed by the user

/** A decimal number as typed: sign, digits with a point, exponent (no hex, no NaN). */
const DECIMAL = /^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/

/**
 * The finite number a text is.
 *
 * @param text - the text; it is not trimmed (` 5` is no number).
 * @returns the number, or `undefined` when the text is none.
 */
export function numberText(text: string): number | undefined {
    if (!DECIMAL.test(text)) return undefined
    const x = Number(text)
    return Number.isFinite(x) ? x : undefined
}

/**
 * A number as text with no exponent and no `.0` on a whole number (`1e6` is
 * `1000000`).
 *
 * @param v - a finite number.
 * @returns the plain decimal text.
 */
export function plainNumber(v: number): string {
    const text = String(v)
    const match = /^(-?)(\d+)(?:\.(\d+))?e([+-]\d+)$/.exec(text)
    if (!match) return text
    // JavaScript only switches to an exponent for very large or very small numbers.
    const [, sign, whole, fraction = "", exponent] = match
    const digits = whole + fraction
    const point = whole.length + Number(exponent)
    if (point <= 0) return `${sign}0.${"0".repeat(-point)}${digits}`
    if (point >= digits.length) return sign + digits + "0".repeat(point - digits.length)
    return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`
}

/**
 * A number as plain decimal text for a cell that shows it.
 *
 * @param x - a number, or null/undefined for none.
 * @returns `200` for 200.0, `0.00001` for 1e-5, `""` for none.
 */
export function formatNumber(x: number | null | undefined): string {
    return x === null || x === undefined ? "" : plainNumber(x)
}

/**
 * What typed text comes to: the value, or a short message for the cell.
 */
export type Parsed<T> = { value: T } | { error: string }

/** What [[parseNumber]] says of text that is no number. */
const NOT_A_NUMBER = "a number, please"

/** What [[parseNumber]] says of text that is no whole number. */
const NOT_A_WHOLE_NUMBER = "a whole number, please"

/** A whole number as typed: digits, a sign only when [[NumberRules.signed]]. */
const WHOLE_UNSIGNED = /^\d+$/
const WHOLE_SIGNED = /^[+-]?\d+$/

/**
 * What a number cell accepts. Every field is optional; with none, any finite number
 * (negative too) is taken. The checks run in the order of the fields below, after the
 * text is known to be a number.
 *
 * @property whole - only whole numbers (`a whole number, please` otherwise).
 * @property signed - with `whole`: a leading `+` or `-` is allowed (a decimal always
 *     allows one).
 * @property maxDigits - with `whole`: the most digits; more is refused with
 *     `digitsMessage`, or with the not-whole message when that is left out. Leading
 *     zeros are not counted unless `countZeros` is set.
 * @property countZeros - with `maxDigits`: count every digit typed, leading zeros too
 *     (the custom Z cells, as before).
 * @property digitsMessage - what is said of too many digits.
 * @property blank - blank text is the value `null` (the cell is optional), not an error.
 * @property above - the number must be above `limit`, else `message`.
 * @property atLeast - the number must be `limit` or more, else `message`.
 */
export type NumberRules = {
    whole?:         boolean
    signed?:        boolean
    maxDigits?:     number
    countZeros?:    boolean
    digitsMessage?: string
    blank?:         boolean
    above?:         { limit: number; message: string }
    atLeast?:       { limit: number; message: string }
}

/**
 * What the text typed in a number cell comes to. The one parser of every number the user
 * types (a concentration, a Z, a setting): the three families differ only in `rules`.
 * The text is trimmed first; a number with an exponent or past the range of a double
 * (`1e999`) is no number.
 *
 * @param text - what was typed.
 * @param rules - what the cell accepts.
 * @returns `{ value }` (`null` for blank text when `rules.blank`), or `{ error }`: `a
 *     number, please`, `a whole number, please`, the digits message, or the message of
 *     the limit that failed.
 */
export function parseNumber(
    text: string,
    rules: NumberRules & { blank: true },
): Parsed<number | null>
export function parseNumber(text: string, rules?: NumberRules): Parsed<number>
export function parseNumber(text: string, rules: NumberRules = {}): Parsed<number | null> {
    const t = text.trim()
    if (t === "" && rules.blank) return { value: null }
    let x: number
    if (rules.whole) {
        if (!(rules.signed ? WHOLE_SIGNED : WHOLE_UNSIGNED).test(t)) {
            return { error: NOT_A_WHOLE_NUMBER }
        }
        const leading = rules.countZeros ? /^[+-]/ : /^[+-]?0*/
        const stripped = t.replace(leading, "")
        const digits = stripped.length
        if (rules.maxDigits !== undefined && digits > rules.maxDigits) {
            return { error: rules.digitsMessage ?? NOT_A_WHOLE_NUMBER }
        }
        x = Number(t)
    } else {
        const n = numberText(t)
        if (n === undefined) return { error: NOT_A_NUMBER }
        x = n
    }
    if (rules.above && !(x > rules.above.limit)) return { error: rules.above.message }
    if (rules.atLeast && x < rules.atLeast.limit) return { error: rules.atLeast.message }
    return { value: x }
}
