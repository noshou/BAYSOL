// SPDX-License-Identifier: LGPL-3.0-or-later

// Buffer: `buffer.json` of a project, its rows, conditions and checks, and the saved
// recipes (`recipes.json`: named buffers).
//
// Contents:
//   1. The buffer file
//   2. Recipes

import { existsSync } from "node:fs"
import { join } from "node:path"
import { lazyAsset } from "../core/environment.js"
import { isDict, type ReadOptions } from "../core/file-system.js"
import { fold } from "../core/terminal.js"
import { ListFile, MAX_ROWS } from "./lists.js"
import { inProject } from "./projects.js"
import { CONC_UNITS, type ConcUnit } from "./solutes.js"

// ========================================================================================
// 1. The buffer file
// ========================================================================================

/**
 * The buffer of a project: `buffer.json` in the project's folder, a JSON object whose
 * `solutes` is an array of the solutes of the buffer, one object each:
 *
 *     {"kind": "nonbiological", "name": "NaCl", "arg": "NaCl", "mM": 200, "sigma-mM": 10}
 *
 * `name` is what the user calls it, `arg` what BAYSOL is given (the solute's name for a
 * non-biological one), `mM` the concentration and `sigma-mM` its standard uncertainty,
 * both in millimolar as they were typed (BAYSOL takes molar; that is for the run). The
 * keys keep their file spelling (`"sigma-mM"`), so a row is what the file holds. Other
 * keys of the file's map are kept as they are when the solutes are written. The file also
 * holds the conditions of the buffer, `"pH"` and `"sigma-pH"` (the standard uncertainty of
 * the pH, shown as σ to the user), next to `solutes`; both or neither ([[Conditions]],
 * [[conditionsProblem]]), and `"conc-unit"` (the unit the table shows, [[readConcUnit]]).
 * A missing or empty file is a buffer with no solutes and no pH;
 * a file that is not a JSON object (or whose `solutes` is
 * not an array of objects, or has a row that [[rowProblem]] refuses, or has more than
 * [[MAX_ROWS]]) is unusable, and is never written over.
 *
 * The kinds of row are the ones of `test/fixtures/buffer/buffer.json`, the file the Julia
 * loader (`BAYSOL.Pipeline.load_buffer`, `src/Pipeline/Buffer.jl`) is tested against
 * too. [[rowProblem]] checks the same keys and types as the loader, so a row the screen
 * writes is one the loader reads.
 */

/** The name of the file in a project's folder. */
export const bufferFileName = "buffer.json"

/** The top-level key that holds the unit of the table (one of [[CONC_UNITS]]). */
const concUnitKey = "conc-unit"

/** The most units a custom polymer row has (the loader's `CUSTOM_POLYMER_MAX_UNITS`). */
const maxUnits = 4

/** The kinds a row may have. */
export const kinds = [
    "nonbiological",
    "polymer",
    "dna",
    "rna",
    "protein",
    "custom-nonbio",
    "custom-polymer",
] as const

/**
 * What every row has.
 *
 * @property name - the label the user gave it (the loader does not check it).
 * @property mM - the concentration, above 0.
 * @property sigma-mM - its standard uncertainty, 0 or more; required.
 */
export type RowBase = {
    name: string
    mM: number
    "sigma-mM": number
}

/** A row whose `arg` is a name BAYSOL looks up: a table name or a grade or family. */
type NamedRow = RowBase & {
    kind: "nonbiological" | "polymer"
    arg: string
}

/**
 * A row of a sequence: `arg` is the clean sequence; `source` (a file name, no folder)
 * and `record` (the record's id) are provenance only.
 */
type SequenceRow = RowBase & {
    kind: "dna" | "rna" | "protein"
    arg: string
    source?: string
    record?: string
}

/**
 * A row of a custom non-biological solute: a snapshot of the custom entry.
 *
 * @property custom - the entry's name.
 * @property z - its electrons.
 * @property pmv - its partial molar volume.
 * @property sigma-pmv - its uncertainty, `null` for the fallback.
 */
export type CustomNonbioRow = RowBase & {
    kind: "custom-nonbio"
    custom: string
    z: number
    pmv: number
    "sigma-pmv": number | null
}

/**
 * One kind of repeat unit of a custom polymer.
 *
 * @property label - the name the user chose (not checked by the loader).
 * @property formula - its formula (not checked by the loader).
 * @property z - electrons per unit.
 * @property slope - its volume per unit.
 * @property sigma - its absolute uncertainty, `null` for none.
 */
type CustomUnit = {
    label?: string
    formula?: string
    z: number
    slope: number
    sigma: number | null
}

/**
 * A row of a custom polymer: a snapshot of the custom entry and the counts of the row.
 *
 * @property counts - the number of each unit, in order of `units`.
 * @property z-ends - the electrons of the end groups.
 * @property pmv-ends - their volume.
 * @property sigma-ends - its uncertainty, `null` for none.
 */
export type CustomPolymerRow = RowBase & {
    kind: "custom-polymer"
    custom: string
    units: CustomUnit[]
    counts: number[]
    "z-ends": number
    "pmv-ends": number
    "sigma-ends": number | null
}

/**
 * The conditions of a buffer: its pH and the standard uncertainty of the pH. The keys
 * keep their file spelling, like a row's.
 *
 * @property pH - the pH, within [[phLimits]].
 * @property sigma-pH - its standard uncertainty, 0 or more (the screens call it σ).
 */
export type Conditions = {
    pH: number
    "sigma-pH": number
}

/** `assets/data/buffer_conditions.json`; the Julia loader is tested against it. */
type ConditionLimits = {
    pH: { min: number; max: number }
    sigmaPh: { min: number; max: number; default: number }
}

/** @returns the limits of the pH and of its uncertainty, and the default uncertainty. */
export const conditionLimits: () => ConditionLimits = lazyAsset(
    "data",
    "buffer_conditions.json",
)

/** A row of the buffer: one of the seven kinds, told apart by `kind`. */
export type BufferRow = NamedRow | SequenceRow | CustomNonbioRow | CustomPolymerRow

/** The buffer file of a project. */
export function bufferFile(projectDir: string): string {
    return join(projectDir, bufferFileName)
}

// --- what a row must have (the loader's rules)

type Dict = Record<string, unknown>

/**
 * Whether a value is a number (not `NaN`; a boolean is none). The one test of "is a
 * number" that the loader's rules ([[rowProblem]]) and the custom entries share.
 */
export function isNumber(x: unknown): x is number {
    return typeof x === "number" && !Number.isNaN(x)
}

/** Whether a value is a whole number (a boolean is none). */
function isInt(x: unknown): boolean {
    return Number.isInteger(x)
}

/** Whether a value is a string with something in it besides white space. */
function isName(x: unknown): x is string {
    return typeof x === "string" && x.trim() !== ""
}

/** Whether a map has a key that holds a number or `null`: the key must be there. */
function isOptNum(m: Dict, key: string): boolean {
    return key in m && (m[key] === null || isNumber(m[key]))
}

/** What is wrong with one unit of a custom polymer. */
function unitProblem(u: unknown): string | undefined {
    if (!isDict(u)) return "a unit is not a map"
    if (!isInt(u.z)) return "unit z must be an integer"
    if (!isNumber(u.slope)) return "unit slope must be a number"
    if (!isOptNum(u, "sigma")) return "unit sigma must be a number or null"
    return undefined
}

/** What is wrong with the keys of a `custom-nonbio` or `custom-polymer` row. */
function customProblem(row: Dict): string | undefined {
    if (!isName(row.custom)) return "custom must be a name"
    if (row.kind === "custom-nonbio") {
        if (!isInt(row.z)) return "z must be an integer"
        if (!isNumber(row.pmv)) return "pmv must be a number"
        if (!isOptNum(row, "sigma-pmv")) return "sigma-pmv must be a number or null"
        return undefined
    }
    const { units, counts } = row
    if (!Array.isArray(units) || units.length < 1 || units.length > maxUnits)
        return "units needs 1 to 4"
    for (const u of units) {
        const problem = unitProblem(u)
        if (problem !== undefined) return problem
    }
    if (!Array.isArray(counts) || !counts.every(isNumber)) return "counts must be numbers"
    if (counts.length !== units.length) return "counts needs one per unit"
    if (!isInt(row["z-ends"])) return "z-ends must be an integer"
    if (!isNumber(row["pmv-ends"])) return "pmv-ends must be a number"
    if (!isOptNum(row, "sigma-ends")) return "sigma-ends must be a number or null"
    return undefined
}

/**
 * What is wrong with a buffer row for the Julia loader: a map of a known `kind` with an
 * `mM` above 0 and a `sigma-mM` of 0 or more (numbers), and the keys its kind needs
 * (see the top of this file). The name of a row is only a label and is not checked.
 */
export function rowProblem(row: unknown): string | undefined {
    if (!isDict(row)) return "a row is not a map"
    if (!(kinds as readonly unknown[]).includes(row.kind)) return "unknown kind"
    if (!(isNumber(row.mM) && Number(row.mM) > 0)) return "mM must be above 0"
    if (!(isNumber(row["sigma-mM"]) && Number(row["sigma-mM"]) >= 0))
        return "sigma-mM must be 0 or more"
    if (row.kind === "custom-nonbio" || row.kind === "custom-polymer")
        return customProblem(row)
    if (!isName(row.arg)) return "arg must be a name"
    return undefined
}

/**
 * What is wrong with the pH and σ among the keys of a buffer's map: neither is there (a
 * buffer without conditions, which cannot be run), or both are numbers, the pH within
 * its limits and σ within its own (0 or more). The rules of the Julia loader.
 */
export function conditionsProblem(map: Record<string, unknown>): string | undefined {
    const has = "pH" in map || "sigma-pH" in map
    if (!has) return undefined
    const { pH, sigmaPh } = conditionLimits()
    const ph = map.pH
    const sigma = map["sigma-pH"]
    if (!(isNumber(ph) && ph >= pH.min && ph <= pH.max))
        return `pH must be a number from ${pH.min} to ${pH.max}`
    if (!(isNumber(sigma) && sigma >= sigmaPh.min && sigma <= sigmaPh.max))
        return `sigma-pH must be a number from ${sigmaPh.min} to ${sigmaPh.max}`
    return undefined
}

/**
 * The conditions held among the keys of a map.
 *
 * @returns the conditions, `undefined` for none (or ones [[conditionsProblem]] refuses).
 */
export function conditionsOf(map: Record<string, unknown>): Conditions | undefined {
    if (!("pH" in map) || conditionsProblem(map) !== undefined) return undefined
    return { pH: map.pH as number, "sigma-pH": map["sigma-pH"] as number }
}

// --- the file

/**
 * The list file of the buffer: the mechanics (tracked read, locked write, unusable files,
 * the cap, the other keys kept) are [[ListFile]]'s. A project's folder that is gone is
 * not made again.
 */
const bufferList = new ListFile<BufferRow>({
    fileName: bufferFileName,
    key: "solutes",
    kind: "buffer",
    plural: "solutes",
    noun: "buffer row",
    problem: rowProblem,
    mapProblem: conditionsProblem,
    createParents: false,
})

/**
 * The solutes of the buffer of a project.
 *
 * @param options - `track: true` when the rows are read to be edited and saved: the
 *     version read is then the one [[writeSolutes]] checks against, so a save after
 *     another copy saved the file is refused. A plain read changes nothing about that.
 * @throws UnusableFileError if the file cannot be used.
 */
export function readSolutes(projectDir: string, options: ReadOptions = {}): BufferRow[] {
    return bufferList.read(projectDir, options)
}

/**
 * Writes the solutes of the buffer of a project, the other keys of the file kept,
 * through a temporary file that replaces it in one step. The file is made if there is
 * none; one that cannot be used is not touched.
 *
 * @param conditions - the pH and σ to write with them, `undefined` to leave the file's own
 *     (a buffer that has none stays without).
 * @param unit - the unit the table shows, `undefined` to leave the file's own.
 * @throws ChangedOnDiskError if another copy of the program saved the file after this
 *     one read it (nothing is written); UnusableFileError (`not a valid buffer row: ...`,
 *     `too many solutes ...`, nothing written) for a row that [[rowProblem]] refuses or
 *     more than [[MAX_ROWS]] rows, or a file that cannot be used; ProjectGoneError when
 *     the project's folder is gone.
 */
export function writeSolutes(
    projectDir: string,
    solutes: readonly BufferRow[],
    conditions?: Conditions,
    unit?: ConcUnit,
): string {
    const extras = {
        ...(conditions && { pH: conditions.pH, "sigma-pH": conditions["sigma-pH"] }),
        ...(unit && { [concUnitKey]: unit }),
    }
    return inProject(projectDir, () => bufferList.write(projectDir, solutes, extras))
}

/**
 * The conditions of the buffer of a project.
 *
 * @param options - `track: true` when read to be edited, as for [[readSolutes]].
 * @throws UnusableFileError if the file cannot be used.
 */
export function readConditions(
    projectDir: string,
    options: ReadOptions = {},
): Conditions | undefined {
    return conditionsOf(bufferList.readOther(projectDir, options))
}

/**
 * The concentration unit the table of this buffer shows, kept in the file as the top-level
 * key [[concUnitKey]] (Julia ignores it).
 *
 * @returns the unit; `mM` for a file without the key, with another value or unusable.
 */
export function readConcUnit(projectDir: string): ConcUnit {
    try {
        const unit = bufferList.readOther(projectDir)[concUnitKey]
        return CONC_UNITS.find((u) => u === unit) ?? "mM"
    } catch {
        return "mM"
    }
}

/**
 * Writes the unit at once (^k), the rows and every other key as the file has them, under
 * the lock. Best effort: nothing happens for a buffer without a file (the first save
 * writes the unit), a file another copy changed since this one read it, or one that
 * cannot be used; the next `^w` then reports it. The version this process holds is
 * renewed only when the check passed, so a draft or another copy's save is never lost.
 */
export function writeConcUnit(projectDir: string, unit: ConcUnit): void {
    if (!existsSync(bufferFile(projectDir))) return
    try {
        inProject(projectDir, () =>
            bufferList.update(projectDir, (rows) => rows, {
                guarded: true,
                extras: { [concUnitKey]: unit },
            }),
        )
    } catch {
        // the unit then stays unsaved until ^w
    }
}

/**
 * Starts the buffer over after the file was found unusable: the file is renamed to
 * `buffer.json.corrupt` (replacing an older one), so nothing is lost and a new buffer
 * can be written.
 *
 * @returns the path of the kept file, or `undefined` if there was no file.
 * @throws if it cannot be renamed.
 */
export function resetBuffer(projectDir: string): string | undefined {
    return bufferList.reset(projectDir)
}

// ========================================================================================
// 2. Recipes
// ========================================================================================

/**
 * The saved recipes of the user: `recipes.json` in the BAYSOL data folder, next to
 * `settings.json` and `custom-solutes.json` (it belongs to the user, not to a project). A
 * recipe is a named buffer: the same rows a project's `buffer.json` has (the schema of
 * `test/fixtures/buffer/buffer.json`, checked by [[rowProblem]]; custom rows are
 * snapshots, so a recipe is self-contained) and, when it has them, the buffer's pH and σ
 * as `"pH"` and `"sigma-pH"` (both or neither, the rules of [[conditionsProblem]]). A JSON
 * object whose `recipes` is an array of objects, one for each recipe (the shape of
 * `test/fixtures/buffer/recipes.json`):
 *
 *     {"recipes": [{"name": "SEC buffer",
 *                   "solutes": [{"kind": "nonbiological", "name": "NaCl",
 *                                "arg": "sodium chloride", "mM": 150, "sigma-mM": 5},
 *                               ...],
 *                   "pH": 6.8, "sigma-pH": 0.05},
 *                  ...]}
 *
 * A recipe is keyed by its name: unique without regard to case, not blank. At most
 * [[MAX_ROWS]] recipes, each of at most [[MAX_ROWS]] solutes. Other keys of the map, and of
 * a recipe, are kept as they are on write. A missing or empty file is no recipes; a file
 * that is not a JSON object, whose `recipes` is not an array of objects with a name, an
 * array of valid rows and valid conditions, that has a name twice or more recipes or
 * solutes than the limits, is unusable, and is never written over. The project side never
 * reads this file: loading a recipe copies its rows into the project's own `buffer.json`
 * (and the Julia side only ever reads that file). The unit of the concentrations is not
 * part of a recipe.
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
 * @property pH - the buffer's pH, with `sigma-pH` (both or neither).
 */
export interface Recipe {
    name: string
    solutes: BufferRow[]
    pH?: number
    "sigma-pH"?: number
    [other: string]: unknown
}

/**
 * The line of the recipes table for one recipe.
 *
 * @property name - the recipe's name.
 * @property solutes - how many solutes it has.
 * @property kinds - the counts by kind, `1 solute 2 polymer 3 custom 4 seq`.
 * @property conditions - its pH and σ, `undefined` for none.
 */
export interface RecipeSummary {
    name: string
    solutes: number
    kinds: string
    conditions?: Conditions
}

/** The recipes file of the BAYSOL folder. */
export function recipesFile(root: string): string {
    return join(root, recipesFileName)
}

/**
 * What is wrong with a text as the name of a recipe: blank, longer than [[MAX_NAME]], or
 * with a control character in it. Whether it is taken is for [[indexOfRecipe]] and
 * [[renameProblem]].
 *
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
 * What is wrong with a recipe: no name, not an array of at most [[MAX_ROWS]] valid buffer
 * rows, or a pH and σ that [[conditionsProblem]] refuses.
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
    return conditionsProblem(r)
}

/** The list file of the recipes; names differ without regard to case. */
const recipeList = new ListFile<Recipe>({
    fileName: recipesFileName,
    key: "recipes",
    kind: "recipes",
    plural: "recipes",
    noun: "recipe",
    problem: recipeProblem,
    nameOf: (r) => r.name,
})

/** The recipes with their keys in file order: name, solutes, pH, sigma-pH, the rest. */
function ordered(recipes: readonly Recipe[]): Recipe[] {
    return recipes.map(({ name, solutes, pH, "sigma-pH": sigma, ...rest }) => ({
        name,
        solutes,
        ...(pH !== undefined && { pH }),
        ...(sigma !== undefined && { "sigma-pH": sigma }),
        ...rest,
    }))
}

/**
 * The recipes of the folder.
 *
 * @param root - the BAYSOL data folder.
 * @param options - `track: true` when the recipes are read to be edited and saved with
 *     [[writeRecipes]] (see [[readSolutes]]); a plain read leaves the base of the check
 *     alone.
 * @returns the recipes, in file order (empty for none).
 * @throws UnusableFileError (kind `recipes`) if the file cannot be used.
 */
export function readRecipes(root: string, options: ReadOptions = {}): Recipe[] {
    return recipeList.read(root, options)
}

/**
 * The solutes of the recipe with a name.
 *
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
 * The pH and σ of a recipe.
 *
 * @returns them, `undefined` for a recipe without (or with ones [[conditionsProblem]]
 *     refuses).
 */
export function recipeConditions(recipe: Recipe): Conditions | undefined {
    return conditionsOf(recipe)
}

/**
 * A recipe with the conditions set, or taken off when there are none.
 *
 * @param recipe - the recipe.
 * @param conditions - the pH and σ it is to have, `undefined` for none.
 * @returns the recipe, its other keys kept.
 */
export function withConditions(recipe: Recipe, conditions?: Conditions): Recipe {
    const { pH: _ph, "sigma-pH": _sigma, ...rest } = recipe
    return conditions === undefined
        ? rest
        : { ...rest, pH: conditions.pH, "sigma-pH": conditions["sigma-pH"] }
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
 * @param recipes - the recipes; they must keep the rules above.
 * @returns the file.
 * @throws ChangedOnDiskError if the file changed since this process read it (nothing
 *     is written); UnusableFileError (kind `recipes`) for recipes that break the rules
 *     (nothing is written) or a file that cannot be used.
 */
export function writeRecipes(root: string, recipes: readonly Recipe[]): string {
    return recipeList.write(root, ordered(recipes))
}

/**
 * The recipes with one saved under a name: a recipe of that name (without regard to
 * case) is replaced where it stands (its other keys kept, its pH and σ those given:
 * none given, none kept), else the recipe goes at the end.
 */
function withRecipe(
    recipes: readonly Recipe[],
    n: string,
    solutes: readonly BufferRow[],
    conditions: Conditions | undefined,
): Recipe[] {
    const recipe = withConditions({ name: n.trim(), solutes: [...solutes] }, conditions)
    const i = indexOfRecipe(recipes, n)
    if (i === undefined) return [...recipes, recipe]
    return recipes.map((r, j) =>
        j === i ? { ...withConditions(r, undefined), ...recipe } : r,
    )
}

/**
 * Saves a recipe (save as, or replace when the name exists) in the folder.
 *
 * @param n - the name; a recipe of that name (without regard to case) is replaced where
 *     it stands, under the new spelling, else the recipe goes at the end.
 * @param solutes - the rows.
 * @param conditions - the buffer's pH and σ, stored with the rows; `undefined` for a
 *     buffer without (the replaced recipe then has none either).
 * @returns the file.
 * @throws UnusableFileError like [[writeRecipes]] (too many recipes or solutes, an
 *     invalid row or pH, a blank name, an unusable file).
 */
export function saveRecipe(
    root: string,
    n: string,
    solutes: readonly BufferRow[],
    conditions?: Conditions,
): string {
    recipeList.update(root, (recipes) =>
        ordered(withRecipe(recipes, n, solutes, conditions)),
    )
    return recipesFile(root)
}

/**
 * Renames a recipe of the folder; the name may change only its case.
 *
 * @param from - the recipe's name now, without regard to case.
 * @param to - the new name.
 * @returns `undefined` when done, else the message ([[renameProblem]], or `no such
 *     recipe`).
 * @throws UnusableFileError like [[readRecipes]].
 */
export function renameRecipe(root: string, from: string, to: string): string | undefined {
    let message: string | undefined
    recipeList.update(root, (recipes) => {
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
    return recipeList.remove(root, n, options)
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
 * The recipes of the folder as lines of the table.
 *
 * @returns the summaries, in file order.
 * @throws UnusableFileError like [[readRecipes]].
 */
export function listRecipes(root: string): RecipeSummary[] {
    return readRecipes(root).map((r) => ({
        name: r.name,
        solutes: r.solutes.length,
        kinds: kindsSummary(r.solutes),
        conditions: recipeConditions(r),
    }))
}
