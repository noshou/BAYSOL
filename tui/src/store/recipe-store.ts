// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import { isDict, type ReadOptions } from "../core/files.js"
import { fold } from "../core/text.js"
import { type BufferRow, rowProblem } from "./buffer.js"
import { MAX_ROWS } from "./limits.js"
import { ListFile } from "./list-file.js"

/**
 * The saved recipes of the user: `recipes.json` in the BAYSOL data folder, next to
 * `settings.json` and `custom-solutes.json` (it belongs to the user, not to a project). A
 * recipe is a named buffer: the same rows a project's `buffer.json` has (the schema of
 * `test/fixtures/buffer/buffer.json`, checked by `rowProblem` of `./buffer.ts`; custom
 * rows are snapshots, so a recipe is self-contained). A JSON object whose `recipes` is an
 * array of objects, one for each recipe:
 *
 *     {"recipes": [{"name": "SEC buffer",
 *                   "solutes": [{"kind": "nonbiological", "name": "NaCl",
 *                                "arg": "sodium chloride", "mM": 150, "sigma-mM": 5},
 *                               ...]},
 *                  ...]}
 *
 * A recipe is keyed by its name: unique without regard to case, not blank. At most
 * [[MAX_ROWS]] recipes (the counter of the recipes table has room for three digits), each
 * of at most [[MAX_ROWS]] solutes. Other keys of the map, and of a recipe, are kept as they
 * are on write. A missing or empty file is no recipes; a file that is not a
 * JSON object, whose `recipes` is not an array of objects with a name and an array of
 * valid rows,
 * that has a name twice or more recipes or solutes than the limits, is unusable, and is
 * never written over. The project side never reads this file: loading a recipe copies its
 * rows into the project's own `buffer.json` (and the Julia side only ever reads that file).
 */

/** The most characters a recipe name typed in the TUI may have. */
export const MAX_NAME = 40

/** The name of the file in the BAYSOL folder. */
export const recipesFileName = "recipes.json"

/** What the name problem says of a name that another recipe has. */
const IN_USE_MESSAGE = "name in use"

/**
 * A saved recipe. Keys other than these are kept as they are.
 *
 * @property name - the recipe's name, unique without regard to case.
 * @property solutes - the rows of the buffer it stands for.
 */
export interface Recipe {
    name: string
    solutes: BufferRow[]
    [other: string]: unknown
}

/**
 * The line of the recipes table for one recipe.
 *
 * @property name - the recipe's name.
 * @property solutes - how many solutes it has.
 * @property kinds - the counts by kind, `1 solute 2 polymer 3 custom 4 seq`.
 */
export interface RecipeSummary {
    name: string
    solutes: number
    kinds: string
}

/**
 * The recipes file of the BAYSOL folder.
 *
 * @param root - the BAYSOL data folder.
 * @returns the path.
 */
export function recipesFile(root: string): string {
    return join(root, recipesFileName)
}

/**
 * What is wrong with a text as the name of a recipe: blank, longer than [[MAX_NAME]], or
 * with a control character in it. Whether it is taken is for [[indexOfRecipe]] and
 * [[renameProblem]].
 *
 * @param n - the text typed.
 * @returns a short message, or `undefined`.
 */
export function recipeNameProblem(n: string): string | undefined {
    if (n.trim() === "") return "type a name first!"
    if (n.trim().length > MAX_NAME) return `${MAX_NAME} characters at most`
    if (/\p{Cc}/u.test(n)) return "no control characters"
    return undefined
}

/**
 * The position of the recipe with a name.
 *
 * @param recipes - the recipes.
 * @param n - the name, compared without regard to case and to the spaces at the ends.
 * @returns the index, or `undefined`.
 */
export function indexOfRecipe(
    recipes: readonly { name: string }[],
    n: string,
): number | undefined {
    const t = fold(n)
    const i = recipes.findIndex((r) => fold(r.name) === t)
    return i < 0 ? undefined : i
}

/**
 * What is wrong with a name for the recipe at a place in a list: the rules of
 * [[recipeNameProblem]], and a name that another recipe has already. The recipe itself may
 * keep its name, or change only its case (that is a rename, not a clash).
 *
 * @param recipes - the recipes (or table rows holding a `name`).
 * @param n - the name typed.
 * @param except - the index of the recipe being renamed, `undefined` for a new one.
 * @returns the message, or `undefined`.
 */
export function renameProblem(
    recipes: readonly { name: string }[],
    n: string,
    except?: number,
): string | undefined {
    const problem = recipeNameProblem(n)
    if (problem) return problem
    const others = recipes.filter((_, i) => i !== except)
    return indexOfRecipe(others, n) === undefined ? undefined : IN_USE_MESSAGE
}

/**
 * What is wrong with a recipe: no name, or not an array of at most [[MAX_ROWS]] valid
 * buffer rows.
 *
 * @param r - a value of the file or of a save.
 * @returns the message, or `undefined`.
 */
function recipeProblem(r: unknown): string | undefined {
    if (!isDict(r) || typeof r.name !== "string" || r.name.trim() === "")
        return "a recipe needs a name"
    if (!Array.isArray(r.solutes)) return "a recipe needs solutes"
    if (r.solutes.length > MAX_ROWS) return `too many solutes (${MAX_ROWS} at most)`
    for (const row of r.solutes) {
        const why = isDict(row) ? rowProblem(row) : "a row is not a map"
        if (why !== undefined) return why
    }
    return undefined
}

/** The list file of the recipes; names differ without regard to case. */
const list = new ListFile<Recipe>({
    fileName: recipesFileName,
    key: "recipes",
    kind: "recipes",
    plural: "recipes",
    noun: "recipe",
    problem: recipeProblem,
    nameOf: (r) => r.name,
})

/**
 * The recipes in the order the file keeps their keys: the name first and the solutes
 * second, then whatever else the recipe has.
 */
function ordered(recipes: readonly Recipe[]): Recipe[] {
    return recipes.map(({ name, solutes, ...rest }) => ({ name, solutes, ...rest }))
}

/**
 * The recipes of the folder.
 *
 * @param root - the BAYSOL data folder.
 * @param options - `track: true` when the recipes are read to be edited and saved with
 *     [[writeRecipes]] (see `readSolutes` of ./buffer.ts); a plain read leaves the base
 *     of the check alone.
 * @returns the recipes, in file order (empty for none).
 * @throws UnusableFileError (kind `recipes`) if the file cannot be used.
 */
export function readRecipes(root: string, options: ReadOptions = {}): Recipe[] {
    return list.read(root, options)
}

/**
 * The solutes of the recipe with a name.
 *
 * @param root - the BAYSOL data folder.
 * @param n - the name, without regard to case.
 * @returns the rows, or `undefined` when there is no such recipe.
 * @throws UnusableFileError like [[readRecipes]].
 */
export function recipeSolutes(root: string, n: string): BufferRow[] | undefined {
    const recipes = readRecipes(root)
    const i = indexOfRecipe(recipes, n)
    return i === undefined ? undefined : (recipes[i] as Recipe).solutes
}

/**
 * Writes the recipes as those of the folder, the other keys of the file kept, through a
 * temporary file that replaces it in one step. The file is made if there is none; one
 * that cannot be used is not touched. It takes the lock on the file and refuses to
 * write when another copy of the program saved the file after this one read it (the
 * operations that read and write in one step, [[saveRecipe]] and [[renameRecipe]],
 * read again under the lock and so never conflict; [[removeRecipe]] does too unless
 * it is `guarded`, for a table that shows an older file).
 *
 * @param root - the BAYSOL data folder.
 * @param recipes - the recipes; they must keep the rules above.
 * @returns the file.
 * @throws ChangedOnDiskError if the file changed since this process read it (nothing
 *     is written); UnusableFileError (kind `recipes`) for recipes that break the rules
 *     (nothing is written) or a file that cannot be used.
 */
export function writeRecipes(root: string, recipes: readonly Recipe[]): string {
    return list.write(root, ordered(recipes))
}

/**
 * The recipes with one saved under a name: a recipe of that name (without regard to
 * case) is replaced where it stands (its other keys kept), else the recipe goes at the
 * end.
 *
 * @param recipes - the recipes.
 * @param n - the name (trimmed).
 * @param solutes - the rows.
 * @returns the new list.
 */
function withRecipe(
    recipes: readonly Recipe[],
    n: string,
    solutes: readonly BufferRow[],
): Recipe[] {
    const recipe = { name: n.trim(), solutes: [...solutes] }
    const i = indexOfRecipe(recipes, n)
    if (i === undefined) return [...recipes, recipe]
    return recipes.map((r, j) => (j === i ? { ...r, ...recipe } : r))
}

/**
 * Saves a recipe (save as, or replace when the name exists) in the folder.
 *
 * @param root - the BAYSOL data folder.
 * @param n - the name; a recipe of that name (without regard to case) is replaced where
 *     it stands, under the new spelling, else the recipe goes at the end.
 * @param solutes - the rows.
 * @returns the file.
 * @throws UnusableFileError like [[writeRecipes]] (too many recipes or solutes, an
 *     invalid row, a blank name, an unusable file).
 */
export function saveRecipe(root: string, n: string, solutes: readonly BufferRow[]): string {
    list.update(root, (recipes) => ordered(withRecipe(recipes, n, solutes)))
    return recipesFile(root)
}

/**
 * Renames a recipe of the folder; the name may change only its case.
 *
 * @param root - the BAYSOL data folder.
 * @param from - the recipe's name now, without regard to case.
 * @param to - the new name.
 * @returns `undefined` when done, else the message ([[renameProblem]], or `no such
 *     recipe`).
 * @throws UnusableFileError like [[readRecipes]].
 */
export function renameRecipe(root: string, from: string, to: string): string | undefined {
    let message: string | undefined
    list.update(root, (recipes) => {
        const i = indexOfRecipe(recipes, from)
        if (i === undefined) {
            message = "no such recipe"
            return undefined
        }
        message = renameProblem(recipes, to, i)
        if (message) return undefined
        return ordered(recipes.map((r, j) => (j === i ? { ...r, name: to.trim() } : r)))
    })
    return message
}

/**
 * Removes ONE saved recipe, at once: it re-reads the file under the lock and drops that
 * recipe only, so it never loses another copy's changes to the other recipes.
 *
 * @param root - the BAYSOL data folder.
 * @param n - the recipe's name, without regard to case.
 * @param options - `guarded: true` for a table that shows the file as it read it for
 *     editing: the removal then refuses when another copy saved the file since. A list
 *     that picks a recipe by name (the buffer landing) leaves it out.
 * @returns whether there was such a recipe (nothing is written when there was not).
 * @throws ChangedOnDiskError when `guarded` and the file changed since this process read
 *     it; UnusableFileError like [[writeRecipes]].
 */
export function removeRecipe(
    root: string,
    n: string,
    options: { guarded?: boolean } = {},
): boolean {
    return list.remove(root, n, options)
}

/** The groups [[kindsSummary]] counts, in the order it tells them. */
const GROUPS = ["solute", "polymer", "custom", "seq"] as const

/** The group of a row's kind. */
function groupOf(kind: string): (typeof GROUPS)[number] {
    switch (kind) {
        case "nonbiological":
            return "solute"
        case "polymer":
            return "polymer"
        case "custom-nonbio":
        case "custom-polymer":
            return "custom"
        default:
            return "seq"
    }
}

/**
 * A compact summary of rows: the counts of each group that has any, as `3 solute 1
 * polymer 2 custom 4 seq` (non-biological solutes, polymers, custom ones of either kind,
 * and DNA, RNA and protein together as `seq`).
 *
 * @param solutes - the rows (only their `kind` is looked at).
 * @returns the summary; `none` for no rows.
 */
export function kindsSummary(solutes: readonly { kind: string }[]): string {
    const counts = new Map<string, number>()
    for (const row of solutes) {
        const g = groupOf(row.kind)
        counts.set(g, (counts.get(g) ?? 0) + 1)
    }
    const parts = GROUPS.filter((g) => counts.has(g)).map((g) => `${counts.get(g)} ${g}`)
    return parts.length > 0 ? parts.join(" ") : "none"
}

/**
 * The lines of the recipes table.
 *
 * @param recipes - the recipes.
 * @returns the name, the solute count and the kinds of each.
 */
function summaries(recipes: readonly Recipe[]): RecipeSummary[] {
    return recipes.map((r) => ({
        name: r.name,
        solutes: r.solutes.length,
        kinds: kindsSummary(r.solutes),
    }))
}

/**
 * The recipes of the folder as lines of the table.
 *
 * @param root - the BAYSOL data folder.
 * @returns the summaries, in file order.
 * @throws UnusableFileError like [[readRecipes]].
 */
export function listRecipes(root: string): RecipeSummary[] {
    return summaries(readRecipes(root))
}
