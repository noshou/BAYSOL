// SPDX-License-Identifier: LGPL-3.0-or-later

// Notes: the titled free-text notes that a project, a buffer or a recipe may carry, as the
// optional `"notes"` array of their file, and the pure rules of a list of them.
//
// Contents:
//   1. The note and the rules of its file
//   2. The rules of a list: titles, adding, renaming

import { fold, NAME_CONTROL } from "../core/terminal.js"
import { textLength } from "../core/text-area.js"

// ========================================================================================
// 1. The note and the rules of its file
// ========================================================================================

/**
 * A note: a title and free text. The owner of the notes (the file of a project, of a
 * buffer or of a recipe) keeps them as the optional array `"notes"` of `{"title", "text"}`
 * objects, in the order the user keeps them; the key is absent when there are none.
 *
 * @property title - what the note is called, unique among its owner's notes without
 *     regard to case.
 * @property text - the text as typed, line breaks as `\n`.
 */
export type Note = { title: string; text: string }

/** The most characters of a note's title. */
export const NOTE_TITLE_MAX = 40

/** What a title problem says of a title another note has. */
const TITLE_IN_USE = "title in use"

/**
 * What is wrong with a text as the title of a note: blank, longer than
 * [[NOTE_TITLE_MAX]] or with a control character in it.
 *
 * @param title - the text.
 * @returns a short message, or `undefined`.
 */
function noteTitleProblem(title: string): string | undefined {
    if (title.trim() === "") return "type a title first!"
    if (textLength(title.trim()) > NOTE_TITLE_MAX)
        return `${NOTE_TITLE_MAX} characters at most`
    if (/\p{Cc}/u.test(title)) return NAME_CONTROL
    return undefined
}

/**
 * What is wrong with the `"notes"` value of a file: not an array,
 * a note that is not a map of a title and a text that are strings, a title
 * [[noteTitleProblem]] refuses or a title that another note has (without regard to case).
 * There is no limit on the number of notes or on the length of a text.
 *
 * @param value - the value of the key, `undefined` for a file without notes.
 * @returns the message, or `undefined`.
 */
export function notesProblem(value: unknown): string | undefined {
    if (value === undefined) return undefined
    if (!Array.isArray(value)) return "notes must be an array"
    const titles = new Set<string>()
    for (const note of value as unknown[]) {
        if (typeof note !== "object" || note === null || Array.isArray(note))
            return "a note is not a map"
        const { title, text } = note as Record<string, unknown>
        if (typeof title !== "string" || typeof text !== "string")
            return "a note needs a title and a text, both text"
        const bad = noteTitleProblem(title)
        if (bad !== undefined) return `note title: ${bad}`
        const key = fold(title)
        if (titles.has(key)) return TITLE_IN_USE
        titles.add(key)
    }
    return undefined
}

// ========================================================================================
// 2. The rules of a list
// ========================================================================================

/**
 * What is wrong with a title for the note at a place in a list: the rules of
 * [[noteTitleProblem]], and a title that another note has. A note may keep its title, or
 * change only its case.
 *
 * @param notes - the notes (or table rows holding a `title`).
 * @param title - the title typed.
 * @param except - the index of the note being renamed, `undefined` for a new one.
 * @returns the message, or `undefined`.
 */
export function titleProblem(
    notes: readonly { title: string }[],
    title: string,
    except?: number,
): string | undefined {
    const bad = noteTitleProblem(title)
    if (bad !== undefined) return bad
    const t = fold(title)
    const taken = notes.some((n, i) => i !== except && fold(n.title) === t)
    return taken ? TITLE_IN_USE : undefined
}

/**
 * The title a new note starts with: `note 1`, `note 2`, ... the first that is free.
 *
 * @param notes - the notes (or table rows holding a `title`).
 * @returns the title.
 */
export function defaultTitle(notes: readonly { title: string }[]): string {
    for (let n = 1; ; n++) {
        const title = `note ${n}`
        if (titleProblem(notes, title) === undefined) return title
    }
}

/**
 * The notes as one cell of a table: their titles, `setup, source`, or nothing.
 *
 * @param notes - the notes, `undefined` for none.
 * @returns the text, `""` for none.
 */
export function notesCell(notes: readonly Note[] | undefined): string {
    return (notes ?? []).map((n) => n.title).join(", ")
}

/**
 * The first line of a text that has any, for a one-line cell.
 *
 * @param text - the text.
 * @returns the line without the spaces at its ends, `""` for none.
 */
export function firstLine(text: string): string {
    for (const line of text.split("\n")) if (line.trim() !== "") return line.trim()
    return ""
}

/**
 * The notes as an owner stores them: `undefined` for none, so the key is left out.
 *
 * @param notes - the notes.
 * @returns the same array, or `undefined` for an empty one.
 */
export function storedNotes(notes: readonly Note[] | undefined): Note[] | undefined {
    return notes === undefined || notes.length === 0 ? undefined : [...notes]
}
