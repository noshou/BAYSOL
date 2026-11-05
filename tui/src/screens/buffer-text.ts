// SPDX-License-Identifier: LGPL-3.0-or-later

// The words of the buffer screens that need no terminal: the options of the landing, what
// a file holds, and the questions and messages. They are here, not in the screens, so
// that the rules they follow (a name cut to leave the keys in view, a plural) are
// tested.

import { truncate } from "../core/text.js"
import { MAX_ROWS } from "../store/limits.js"
import { type FileCount, fileStatus } from "./custom-text.js"

/** What the landing can do: edit the buffer, load a recipe, start new, save globally. */
export type LandingId = "edit" | "load" | "new" | "save"

/**
 * One option of the landing.
 *
 * @property id - which action it is.
 * @property label - the line shown.
 */
export type LandingOption = { id: LandingId; label: string }

/** What the empty solutes table says. */
export const EMPTY_HINT = "no solutes: ^n ^p ^f ^e"

/** The note of a recipe that was loaded over a buffer that has solutes. */
export const REPLACES_HINT = "replaces the current recipe at ^w"

/** The note of a new recipe over a buffer that has solutes. */
export const NOTHING_REPLACED_HINT = "nothing is replaced until ^w"

/** The message when there is no recipe to load. */
export const NO_RECIPES = "no saved recipes!"

/** The message of a save that failed for a reason that is not an unusable file. */
export const COULD_NOT_SAVE = "could not save!"

/** The message when a name prompt of the landing is left with a question unanswered. */
export const NOT_SAVED = "not saved"

/** The message when there is no room for one more recipe. */
export const TOO_MANY_RECIPES = `${MAX_ROWS} recipes at most!`

/** The most room kept free for the keys of a question, see [[fitName]]. */
const MIN_NAME = 8

/**
 * A count with its noun: `1 solute`, `12 solutes`.
 *
 * @param n - the count.
 * @param word - the noun in the singular.
 * @returns the text.
 */
export function plural(n: number, word: string): string {
    return `${n} ${word}${n === 1 ? "" : "s"}`
}

/**
 * The options of the landing for a buffer, in order; `edit` and `save` only for a buffer
 * that has solutes (what does nothing is not offered).
 *
 * @param count - the solutes of the buffer, `"unusable"` for a file that cannot be used.
 * @returns the options.
 */
export function landingOptions(count: FileCount): LandingOption[] {
    const has = typeof count === "number" && count > 0
    const options: (LandingOption | undefined)[] = [
        has
            ? { id: "edit", label: `edit current recipe (${plural(count, "solute")})` }
            : undefined,
        { id: "load", label: "load a recipe" },
        { id: "new", label: "new recipe" },
        has ? { id: "save", label: "save current recipe globally" } : undefined,
    ]
    return options.filter((o): o is LandingOption => o !== undefined)
}

/**
 * What the landing says of the buffer file.
 *
 * @param file - the file's name.
 * @param count - what it holds.
 * @returns `buffer.json: 12 solutes`, `none yet` or `unusable!` after the name.
 */
export function bufferStatus(file: string, count: FileCount): string {
    return fileStatus(file, count, "solute")
}

/**
 * The line of a recipe in the dropdown of the recipes to load.
 *
 * @param name - the recipe's name.
 * @param solutes - how many solutes it has.
 * @returns `SEC buffer (3)`.
 */
export function recipeChoice(name: string, solutes: number): string {
    return `${name} (${solutes})`
}

/**
 * A name cut to fit a question so that the keys at its end stay in view.
 *
 * @param name - the name.
 * @param room - the cells the whole question may take.
 * @param fixed - the cells the rest of the question takes.
 * @returns the name, with an ellipsis if it was cut; at least 8 cells are kept.
 */
export function fitName(name: string, room: number, fixed: number): string {
    return truncate(name, Math.max(MIN_NAME, room - fixed))
}

/** The keys that answer a question of the landing and the table. */
const REPLACE_KEYS = "enter: replace  esc: keep"

/**
 * The question asked at the first `^w` of a recipe loaded over a buffer.
 *
 * @param n - how many solutes the buffer has.
 * @param recipe - the recipe's name.
 * @param room - the cells the note line has.
 * @returns `replace 3 solutes with recipe "NAME"?  enter: replace  esc: keep`.
 */
export function replaceBufferQuestion(n: number, recipe: string, room: number): string {
    const lead = `replace ${plural(n, "solute")} with recipe "`
    const tail = `"?  ${REPLACE_KEYS}`
    return `${lead}${fitName(recipe, room, lead.length + tail.length)}${tail}`
}

/**
 * The question asked when a recipe of the name typed exists.
 *
 * @param name - the name typed.
 * @param room - the cells the note line has.
 * @returns `replace "NAME"?  enter: replace  esc: keep`.
 */
export function replaceRecipeQuestion(name: string, room: number): string {
    const lead = 'replace "'
    const tail = `"?  ${REPLACE_KEYS}`
    return `${lead}${fitName(name, room, lead.length + tail.length)}${tail}`
}

/**
 * The message of a saved recipe.
 *
 * @param name - its name.
 * @param room - the cells the note line has.
 * @returns `saved as "NAME"`.
 */
export function savedAs(name: string, room: number): string {
    return `saved as "${fitName(name, room, 'saved as ""'.length)}"`
}

/**
 * The message for a file that cannot be used.
 *
 * @param file - the file's name.
 * @returns `buffer.json unusable!`.
 */
export function unusable(file: string): string {
    return `${file} unusable!`
}
