// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import {
    assertUnchanged,
    isDict,
    noteWritten,
    readMap,
    UnusableFileError,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/files.js"
import { fold } from "../core/text.js"
import { type BufferRow, rowProblem } from "./buffer.js"
import { MAX_ROWS } from "./limits.js"

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

/** The kind carried by the errors of this file. */
const KIND = "recipes"

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

type Dict = Record<string, unknown>

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
 * with a control character in it. Whether it is taken is for [[indexOfName]] and
 * [[renameProblem]].
 *
 * @param n - the text typed.
 * @returns a short message, or `undefined`.
 */
export function nameProblem(n: string): string | undefined {
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
export function indexOfName(
    recipes: readonly { name: string }[],
    n: string,
): number | undefined {
    const t = fold(n)
    const i = recipes.findIndex((r) => fold(r.name) === t)
    return i < 0 ? undefined : i
}

/**
 * What is wrong with a name for the recipe at a place in a list: the rules of
 * [[nameProblem]], and a name that another recipe has already. The recipe itself may
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
    const problem = nameProblem(n)
    if (problem) return problem
    const others = recipes.filter((_, i) => i !== except)
    return indexOfName(others, n) === undefined ? undefined : IN_USE_MESSAGE
}

/**
 * Whether a value is a map with a name and at most [[MAX_ROWS]] valid buffer rows.
 *
 * @param r - a value of the file or of a save.
 * @returns true if so.
 */
function usableRecipe(r: unknown): r is Recipe {
    return (
        isDict(r) &&
        typeof r.name === "string" &&
        r.name.trim() !== "" &&
        Array.isArray(r.solutes) &&
        r.solutes.length <= MAX_ROWS &&
        r.solutes.every((row) => isDict(row) && rowProblem(row) === undefined)
    )
}

/** Whether a value is at most [[MAX_ROWS]] usable recipes with names that differ. */
function usableRecipes(recipes: unknown): recipes is Recipe[] {
    if (!Array.isArray(recipes) || recipes.length > MAX_ROWS) return false
    if (!recipes.every(usableRecipe)) return false
    return new Set(recipes.map((r) => fold(r.name))).size === recipes.length
}

/**
 * Reads the map in the file.
 *
 * @param root - the BAYSOL data folder.
 * @returns the map; `{}` for no file or no content.
 * @throws UnusableFileError (kind `recipes`) if the file is not one JSON object of the kind
 *     described above.
 */
function readFileMap(root: string): Dict {
    return readMap(recipesFile(root), {
        kind: KIND,
        name: recipesFileName,
        expected: "a map of valid recipes",
        valid: (map) => usableRecipes("recipes" in map ? map.recipes : []),
    })
}

/**
 * The recipes of the folder.
 *
 * @param root - the BAYSOL data folder.
 * @returns the recipes, in file order (empty for none).
 * @throws UnusableFileError (kind `recipes`) if the file cannot be used.
 */
export function readRecipes(root: string): Recipe[] {
    const recipes = readFileMap(root).recipes
    return Array.isArray(recipes) ? (recipes as Recipe[]) : []
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
    const i = indexOfName(recipes, n)
    return i === undefined ? undefined : (recipes[i] as Recipe).solutes
}

/**
 * The write of [[writeRecipes]], for a caller that holds the lock on the file and has
 * made sure of what is on disk.
 *
 * @param root - the BAYSOL data folder.
 * @param recipes - the recipes.
 * @returns the file.
 * @throws UnusableFileError like [[writeRecipes]].
 */
function writeRecipesLocked(root: string, recipes: readonly Recipe[]): string {
    if (!usableRecipes(recipes)) throw new UnusableFileError("not valid recipes", KIND)
    const file = recipesFile(root)
    const { recipes: _old, ...others } = readFileMap(root)
    // The name comes first and the solutes second, then whatever else the recipe has.
    const out = recipes.map(({ name, solutes, ...rest }) => ({ name, solutes, ...rest }))
    writeAtomic(file, writeJson({ recipes: out, ...others }))
    noteWritten(file)
    return file
}

/**
 * Writes the recipes as those of the folder, the other keys of the file kept, through a
 * temporary file that replaces it in one step. The file is made if there is none; one
 * that cannot be used is not touched. It takes the lock on the file and refuses to
 * write when another copy of the program saved the file after this one read it (the
 * operations that read and write in one step, [[saveRecipe]], [[renameRecipe]] and
 * [[deleteRecipe]], read again under the lock and so never conflict).
 *
 * @param root - the BAYSOL data folder.
 * @param recipes - the recipes; they must keep the rules above.
 * @returns the file.
 * @throws ChangedOnDiskError if the file changed since this process read it (nothing
 *     is written); UnusableFileError (kind `recipes`) for recipes that break the rules
 *     (nothing is written) or a file that cannot be used.
 */
export function writeRecipes(root: string, recipes: readonly Recipe[]): string {
    if (!usableRecipes(recipes)) throw new UnusableFileError("not valid recipes", KIND)
    const file = recipesFile(root)
    return withFileLock(file, () => {
        assertUnchanged(file)
        return writeRecipesLocked(root, recipes)
    })
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
export function withRecipe(
    recipes: readonly Recipe[],
    n: string,
    solutes: readonly BufferRow[],
): Recipe[] {
    const recipe = { name: n.trim(), solutes: [...solutes] }
    const i = indexOfName(recipes, n)
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
    return withFileLock(recipesFile(root), () =>
        writeRecipesLocked(root, withRecipe(readRecipes(root), n, solutes)),
    )
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
    return withFileLock(recipesFile(root), () => {
        const recipes = readRecipes(root)
        const i = indexOfName(recipes, from)
        if (i === undefined) return "no such recipe"
        const problem = renameProblem(recipes, to, i)
        if (problem) return problem
        writeRecipesLocked(
            root,
            recipes.map((r, j) => (j === i ? { ...r, name: to.trim() } : r)),
        )
        return undefined
    })
}

/**
 * Deletes a recipe of the folder.
 *
 * @param root - the BAYSOL data folder.
 * @param n - the recipe's name, without regard to case.
 * @returns whether there was such a recipe (nothing is written when there was not).
 * @throws UnusableFileError like [[writeRecipes]].
 */
export function deleteRecipe(root: string, n: string): boolean {
    return withFileLock(recipesFile(root), () => {
        const recipes = readRecipes(root)
        const i = indexOfName(recipes, n)
        if (i === undefined) return false
        writeRecipesLocked(
            root,
            recipes.filter((_, j) => j !== i),
        )
        return true
    })
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
export function summaries(recipes: readonly Recipe[]): RecipeSummary[] {
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
