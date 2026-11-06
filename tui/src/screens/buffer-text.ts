// SPDX-License-Identifier: LGPL-3.0-or-later

// The words of the buffer screens that need no terminal: the options of the landing, what
// a file holds, and the questions and messages. They are here, not in the screens, so
// that the rules they follow (a name cut to leave the keys in view, a plural) are
// tested.

import { truncate } from "../core/text.js"
import { MAX_ROWS } from "../store/limits.js"
import { keyLabels, keys } from "../ui/keys.js"
import { type Question, questionNote } from "../ui/use-confirm.js"
import { type FileCount, fileStatus } from "./custom-text.js"

/** What the landing can do: edit the buffer, load a recipe, start new, save globally. */
type LandingId = "edit" | "load" | "new" | "save"

/**
 * One option of the landing.
 *
 * @property id - which action it is.
 * @property label - the line shown.
 */
export type LandingOption = { id: LandingId; label: string }

/** What the empty solutes table says. */
export const EMPTY_HINT = `no solutes: ${keyLabels(
    keys.addNonbio, keys.addPolymer, keys.addProtein, keys.addNucleotide
)}`

/** The note of a recipe that was loaded over a buffer that has solutes. */
export const REPLACES_HINT = `replaces the current recipe at ${keys.save.label}`

/** The note of a new recipe over a buffer that has solutes. */
export const NOTHING_REPLACED_HINT = `nothing is replaced until ${keys.save.label}`

/** The message when there is no recipe to load. */
export const NO_RECIPES = "no saved recipes!"

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
export function bufferLandingOptions(count: FileCount): LandingOption[] {
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
 * What the landing says of the buffer file, under the plain label `buffer`.
 *
 * @param count - what it holds.
 * @returns `buffer: 12 solutes`, `buffer: none yet` or `buffer: unusable!`.
 */
export function bufferStatus(count: FileCount): string {
    return fileStatus("buffer", count, "solute")
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

/**
 * A question of the landing and the table that asks to replace something and shortens
 * the name in it so that the whole note, with the keys that answer it, fits.
 *
 * @param lead - the text before the name.
 * @param name - the name to fit.
 * @param room - the cells the note line has.
 * @returns `lead` + name + `"?`, answered by `replace` and `keep`.
 */
function replaceQuestion(lead: string, name: string, room: number): Question {
    const answers = { yes: "replace", no: "keep" }
    const end = '"?'
    const fixed = questionNote({ text: end, ...answers }).length + lead.length
    return { text: `${lead}${fitName(name, room, fixed)}${end}`, ...answers }
}

/**
 * The question asked at the first `^w` of a recipe loaded over a buffer.
 *
 * @param n - how many solutes the buffer has.
 * @param recipe - the recipe's name.
 * @param room - the cells the note line has.
 * @returns `replace 3 solutes with recipe "NAME"?`, answered by `replace` and `keep`.
 */
export function replaceBufferQuestion(n: number, recipe: string, room: number): Question {
    return replaceQuestion(`replace ${plural(n, "solute")} with recipe "`, recipe, room)
}

/**
 * The question asked when a recipe of the name typed exists.
 *
 * @param name - the name typed.
 * @param room - the cells the note line has.
 * @returns `replace "NAME"?`, answered by `replace` and `keep`.
 */
export function replaceRecipeQuestion(name: string, room: number): Question {
    return replaceQuestion('replace "', name, room)
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
