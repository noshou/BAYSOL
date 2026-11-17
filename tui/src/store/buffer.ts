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
import { fold, NAME_BLANK, NAME_CONTROL, NAME_IN_USE } from "../core/terminal.js"
import { ListFile, MAX_ROWS } from "./lists.js"
import { type Note, notesProblem, storedNotes } from "./notes.js"
import { inProject } from "./projects.js"
import { CONC_UNITS, type ConcUnit } from "./solutes.js"
import type { Definition } from "./template-defs.js"
import { cleanRow, type TemplateLink } from "./template-rows.js"

// ========================================================================================
// 1. The buffer file
// ========================================================================================

/**
 * The buffer of a project: `buffer.json` in its folder, a JSON object whose `solutes` is
 * an array of rows, one object each:
 *
 *     {"kind": "nonbiological", "name": "NaCl", "arg": "NaCl", "mM": 200, "sigmaMm": 10}
 *
 * `name` is the user's label, `arg` what BAYSOL is given, `mM` and `sigmaMm` the
 * concentration and its uncertainty in millimolar. Other keys of the file are kept on
 * write. Next to `solutes` the file holds `"pH"` and `"sigmaPh"` (both or neither;
 * [[Conditions]]), the optional `"temperature"` (°C; a run needs it) and `"conc-unit"`
 * ([[readConcUnit]]). A missing or empty file is an empty buffer; a file that is not a
 * JSON object, has a row [[rowProblem]] refuses, or has more than [[MAX_ROWS]] rows is
 * unusable and never written over.
 *
 * The kinds of row are those of `test/fixtures/buffer/buffer.json`, which the Julia
 * loader (`loadBuffer`) is tested against; [[rowProblem]] applies its rules.
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
 * @property sigmaMm - its standard uncertainty, 0 or more; required.
 * @property template - the link to the buffer template that made the row
 *     ([[TemplateLink]]); optional, never checked by [[rowProblem]] (an invalid one is
 *     dropped on reading, `cleanRow`).
 */
export type RowBase = {
    name: string
    mM: number
    "sigmaMm": number
    template?: TemplateLink
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
 * @property sigmaPmv - its uncertainty, `null` for the fallback.
 */
export type CustomNonbioRow = RowBase & {
    kind: "custom-nonbio"
    custom: string
    z: number
    pmv: number
    "sigmaPmv": number | null
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
 * @property zEnds - the electrons of the end groups.
 * @property pmvEnds - their volume.
 * @property sigmaEnds - its uncertainty, `null` for none.
 */
export type CustomPolymerRow = RowBase & {
    kind: "custom-polymer"
    custom: string
    units: CustomUnit[]
    counts: number[]
    "zEnds": number
    "pmvEnds": number
    "sigmaEnds": number | null
}

/**
 * The conditions of a buffer: its pH and the standard uncertainty of the pH. The keys
 * keep their file spelling, like a row's.
 *
 * @property pH - the pH, within [[phLimits]].
 * @property sigmaPh - its standard uncertainty, 0 or more (the screens call it σ).
 * @property temperature - the temperature of the buffer, °C, within [[conditionLimits]];
 *     absent in a new buffer (the buffer cannot run until it is set).
 */
export type Conditions = {
    pH: number
    "sigmaPh": number
    temperature?: number
}

/** `assets/data/buffer_conditions.json`; the Julia loader is tested against it. */
type ConditionLimits = {
    pH: { min: number; max: number }
    sigmaPh: { min: number; max: number; default: number }
    temperature: { min: number; max: number }
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

/** Whether a value is a number (not `NaN`, not a boolean). */
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
        if (!isOptNum(row, "sigmaPmv")) return "sigmaPmv must be a number or null"
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
    if (!isInt(row.zEnds)) return "zEnds must be an integer"
    if (!isNumber(row.pmvEnds)) return "pmvEnds must be a number"
    if (!isOptNum(row, "sigmaEnds")) return "sigmaEnds must be a number or null"
    return undefined
}

/**
 * What is wrong with a buffer row for the Julia loader: a known `kind`, `mM` above 0,
 * `sigmaMm` of 0 or more, and the keys its kind needs. The name is only a label.
 */
export function rowProblem(row: unknown): string | undefined {
    if (!isDict(row)) return "a row is not a map"
    if (!(kinds as readonly unknown[]).includes(row.kind)) return "unknown kind"
    if (!(isNumber(row.mM) && Number(row.mM) > 0)) return "mM must be above 0"
    if (!(isNumber(row.sigmaMm) && Number(row.sigmaMm) >= 0))
        return "sigmaMm must be 0 or more"
    if (row.kind === "custom-nonbio" || row.kind === "custom-polymer")
        return customProblem(row)
    if (!isName(row.arg)) return "arg must be a name"
    return undefined
}

/**
 * What is wrong with the pH, σ and temperature of a buffer's map: neither pH nor σ is
 * there, or both are numbers within their limits; a `temperature`, if present, is a
 * number within its limits. The rules of the Julia loader.
 */
export function conditionsProblem(map: Record<string, unknown>): string | undefined {
    const { pH, sigmaPh, temperature } = conditionLimits()
    const t = map.temperature
    if (
        t !== undefined &&
        !(isNumber(t) && t >= temperature.min && t <= temperature.max)
    )
        return `temperature must be a number from ${temperature.min} to ${temperature.max}`
    const has = "pH" in map || "sigmaPh" in map
    if (!has) return undefined
    const ph = map.pH
    const sigma = map.sigmaPh
    if (!(isNumber(ph) && ph >= pH.min && ph <= pH.max))
        return `pH must be a number from ${pH.min} to ${pH.max}`
    if (!(isNumber(sigma) && sigma >= sigmaPh.min && sigma <= sigmaPh.max))
        return `sigmaPh must be a number from ${sigmaPh.min} to ${sigmaPh.max}`
    return undefined
}

/**
 * The conditions held among the keys of a map.
 *
 * @returns the conditions, `undefined` for none (or ones [[conditionsProblem]] refuses).
 */
export function conditionsOf(map: Record<string, unknown>): Conditions | undefined {
    if (!("pH" in map) || conditionsProblem(map) !== undefined) return undefined
    return {
        pH: map.pH as number,
        "sigmaPh": map.sigmaPh as number,
        ...(map.temperature !== undefined && { temperature: map.temperature as number }),
    }
}

// --- the file

/** The list file of the buffer (mechanics: [[ListFile]]); a gone folder is not remade. */
const bufferList = new ListFile<BufferRow>({
    fileName: bufferFileName,
    key: "solutes",
    kind: "buffer",
    plural: "solutes",
    noun: "buffer row",
    problem: rowProblem,
    mapProblem: (map) => conditionsProblem(map) ?? notesProblem(map.notes),
    createParents: false,
})

/**
 * The solutes of the buffer of a project.
 *
 * @param options - `track: true` when the rows are read to be edited: the version read
 *     is then the one [[writeSolutes]] checks against (a save after another copy saved
 *     the file is refused).
 * @throws UnusableFileError if the file cannot be used.
 */
export function readSolutes(projectDir: string, options: ReadOptions = {}): BufferRow[] {
    return bufferList.read(projectDir, options).map(cleanRow)
}

/**
 * Writes the solutes of the buffer of a project, the other keys kept, through a temporary
 * file renamed over it. The file is made if there is none; an unusable one is not touched.
 *
 * @param conditions - the pH, σ and temperature to write (no temperature takes the key
 *     off), `undefined` to leave the file's own.
 * @param unit - the unit the table shows, `undefined` to leave the file's own.
 * @param notes - the notes of the buffer (an empty array takes the key off), `undefined`
 *     to leave the file's own.
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
    notes?: readonly Note[],
): string {
    const extras = {
        // an absent temperature is `undefined`: it takes the key off
        ...(conditions && {
            pH: conditions.pH,
            "sigmaPh": conditions.sigmaPh,
            temperature: conditions.temperature,
        }),
        ...(unit && { [concUnitKey]: unit }),
        // `undefined` is left out of the JSON: it takes the key off
        ...(notes && { notes: storedNotes(notes) }),
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
 * The notes of the buffer of a project (`"notes"` next to `solutes`; Julia ignores them).
 *
 * @param options - `track: true` when read to be edited, as for [[readSolutes]].
 * @returns the notes, empty for none.
 * @throws UnusableFileError if the file cannot be used (invalid notes included).
 */
export function readBufferNotes(projectDir: string, options: ReadOptions = {}): Note[] {
    const notes = bufferList.readOther(projectDir, options).notes
    return Array.isArray(notes) ? (notes as Note[]) : []
}

/**
 * Writes ONLY the notes of the buffer: the file is re-read under the project's lock and
 * just `notes` is replaced. The held version is renewed, so a later [[writeSolutes]] is
 * not refused.
 *
 * @param notes - the notes; they must keep the rules of [[notesProblem]].
 * @throws UnusableFileError for notes that break the rules or a file that cannot be
 *     used (nothing is written); ProjectGoneError when the folder is gone.
 */
export function writeBufferNotes(projectDir: string, notes: readonly Note[]): void {
    inProject(projectDir, () =>
        bufferList.update(projectDir, (rows) => rows, {
            // `undefined` is left out of the JSON: it takes the key off
            extras: { notes: storedNotes(notes) },
        }),
    )
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
 * Writes the unit at once (^k) under the lock. Best effort: nothing happens for a buffer
 * without a file, a file another copy changed, or an unusable one; the next `^w` reports
 * it. The held version is renewed only when the check passed.
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
 * The saved recipes of the user: `recipes.json` in the BAYSOL data folder (not in a
 * project). A recipe is a named buffer: the rows of a `buffer.json` and, when it has
 * them, `"pH"`, `"sigmaPh"` and `"temperature"`. A JSON object whose `recipes` is an
 * array (see `test/fixtures/buffer/recipes.json`):
 *
 *     {"recipes": [{"name": "SEC buffer",
 *                   "solutes": [{"kind": "nonbiological", "name": "NaCl",
 *                                "arg": "sodium chloride", "mM": 150, "sigmaMm": 5},
 *                               ...],
 *                   "pH": 6.8, "sigmaPh": 0.05},
 *                  ...]}
 *
 * A recipe is keyed by its name: unique without regard to case, not blank. At most
 * [[MAX_ROWS]] recipes of at most [[MAX_ROWS]] solutes. Other keys are kept on write. A
 * file that breaks these rules is unusable and never written over. The project side never
 * reads this file: loading a recipe copies its rows into `buffer.json`. The concentration
 * unit is not part of a recipe.
 */

/** The most characters a recipe name typed in the TUI may have. */
export const MAX_NAME = 40

/** The name of the file in the BAYSOL folder. */
export const recipesFileName = "recipes.json"

/**
 * A saved recipe. Keys other than these are kept as they are.
 *
 * @property name - the recipe's name, unique without regard to case.
 * @property solutes - the rows of the buffer it stands for.
 * @property pH - the buffer's pH, with `sigmaPh` (both or neither).
 * @property temperature - the buffer's temperature, °C (optional).
 * @property notes - the titled notes of the recipe ([[Note]]), absent when there are none.
 * @property template - the definition of a template recipe (`template-recipes.ts`); kept
 *     as it is, never checked here (a bad one makes the recipe an ordinary one).
 */
export interface Recipe {
    name: string
    solutes: BufferRow[]
    pH?: number
    "sigmaPh"?: number
    temperature?: number
    notes?: Note[]
    template?: unknown
    [other: string]: unknown
}

/**
 * The line of the recipes table for one recipe.
 *
 * @property name - the recipe's name.
 * @property solutes - how many solutes it has.
 * @property kinds - the counts by kind, `1 solute 2 polymer 3 custom 4 seq`.
 * @property conditions - its pH and σ, `undefined` for none.
 * @property notes - its notes, absent for none.
 */
export interface RecipeSummary {
    name: string
    solutes: number
    kinds: string
    conditions?: Conditions
    notes?: Note[]
}

/** The recipes file of the BAYSOL folder. */
export function recipesFile(root: string): string {
    return join(root, recipesFileName)
}

/**
 * What is wrong with a text as the name of a recipe: blank, longer than [[MAX_NAME]], or
 * with a control character. Whether it is taken is [[renameProblem]]'s.
 *
 * @returns a short message, or `undefined`.
 */
export function recipeNameProblem(n: string): string | undefined {
    if (n.trim() === "") return NAME_BLANK
    if (n.trim().length > MAX_NAME) return `${MAX_NAME} characters at most`
    if (/\p{Cc}/u.test(n)) return NAME_CONTROL
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
 * What is wrong with a name for the recipe at a place in a list: [[recipeNameProblem]]'s
 * rules, and a name another recipe has. The recipe itself may keep its name or change
 * only its case.
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
    return indexOfRecipe(others, n) === undefined ? undefined : NAME_IN_USE
}

/**
 * What is wrong with a recipe: no name, not at most [[MAX_ROWS]] valid rows, conditions
 * [[conditionsProblem]] refuses, or notes [[notesProblem]] refuses.
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
    const why = notesProblem(r.notes)
    if (why !== undefined) return why
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

/**
 * The recipes with their keys in file order: name, solutes, pH, sigmaPh, temperature,
 * notes, rest.
 */
function ordered(recipes: readonly Recipe[]): Recipe[] {
    return recipes.map(
        ({ name, solutes, pH, "sigmaPh": sigma, temperature, notes, ...rest }) => ({
            name,
            solutes,
            ...(pH !== undefined && { pH }),
            ...(sigma !== undefined && { "sigmaPh": sigma }),
            ...(temperature !== undefined && { temperature }),
            ...(notes !== undefined && { notes }),
            ...rest,
        }),
    )
}

/**
 * The recipes of the folder.
 *
 * @param root - the BAYSOL data folder.
 * @param options - `track: true` when read to be edited and saved with
 *     [[writeRecipes]] (see [[readSolutes]]).
 * @returns the recipes, in file order (empty for none).
 * @throws UnusableFileError (kind `recipes`) if the file cannot be used.
 */
export function readRecipes(root: string, options: ReadOptions = {}): Recipe[] {
    return recipeList
        .read(root, options)
        .map((r) => ({ ...r, solutes: r.solutes.map(cleanRow) }))
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
 * The pH, σ and temperature of a recipe.
 *
 * @returns them, `undefined` for a recipe without (or with ones [[conditionsProblem]]
 *     refuses).
 */
export function recipeConditions(recipe: Recipe): Conditions | undefined {
    return conditionsOf(recipe)
}

/** The recipe with the pH, σ and, when there is one, the temperature put in. */
function addConditions(rest: Recipe, c: Conditions): Recipe {
    const out: Recipe = { ...rest, pH: c.pH, "sigmaPh": c.sigmaPh }
    if (c.temperature !== undefined) out.temperature = c.temperature
    return out
}

/**
 * A recipe with the conditions set, or taken off when there are none.
 *
 * @param recipe - the recipe.
 * @param conditions - the pH and σ it is to have, `undefined` for none.
 * @returns the recipe, its other keys kept.
 */
export function withConditions(recipe: Recipe, conditions?: Conditions): Recipe {
    const { pH: _ph, "sigmaPh": _sigma, temperature: _t, ...rest } = recipe
    return conditions === undefined
        ? rest
        : addConditions(rest, conditions)
}

/**
 * A recipe with its notes set, or the key taken off when there are none.
 *
 * @param recipe - the recipe.
 * @param notes - the notes it is to have.
 * @returns the recipe, its other keys kept.
 */
export function withNotes(recipe: Recipe, notes: readonly Note[]): Recipe {
    const { notes: _old, ...rest } = recipe
    const stored = storedNotes(notes)
    return stored === undefined ? rest : { ...rest, notes: stored }
}

/**
 * Writes the recipes of the folder, the other keys kept, through a temporary file renamed
 * over it. It refuses when another copy saved the file since this one read it
 * ([[saveRecipe]], [[renameRecipe]] and [[removeRecipe]] unless `guarded` re-read under
 * the lock and never conflict).
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
 * The recipes with one saved under a name: a recipe of that name (any case) is replaced
 * where it stands (other keys and notes kept; pH and σ those given), else it goes last.
 */
function withRecipe(
    recipes: readonly Recipe[],
    n: string,
    solutes: readonly BufferRow[],
    conditions: Conditions | undefined,
    notes: readonly Note[] | undefined,
    definition?: Definition,
): Recipe[] {
    // the buffer's notes when it has any, else a recipe it replaces keeps its own
    const base = withNotes(
        withConditions({ name: n.trim(), solutes: [...solutes] }, conditions),
        notes ?? [],
    )
    // the definition is the save's own: a template replaced by a recipe loses it
    const recipe = definition === undefined ? base : { ...base, template: definition }
    const i = indexOfRecipe(recipes, n)
    if (i === undefined) return [...recipes, recipe]
    return recipes.map((r, j) => {
        if (j !== i) return r
        const { template: _old, ...kept } = withConditions(r, undefined)
        return { ...kept, ...recipe }
    })
}

/**
 * Saves a recipe (save as, or replace when the name exists) in the folder.
 *
 * @param n - the name; a recipe of that name (any case) is replaced where it stands,
 *     under the new spelling, else the recipe goes at the end.
 * @param solutes - the rows.
 * @param conditions - the buffer's pH and σ, stored with the rows; `undefined` for a
 *     buffer without (the replaced recipe then has none either).
 * @param notes - the buffer's notes; with none, a replaced recipe keeps its own.
 * @param definition - the definition of a template recipe (the `solutes` are then its
 *     fixed rows); none makes an ordinary recipe, also of a template that is replaced.
 * @returns the file.
 * @throws UnusableFileError like [[writeRecipes]] (too many recipes or solutes, an
 *     invalid row or pH, a blank name, an unusable file).
 */
export function saveRecipe(
    root: string,
    n: string,
    solutes: readonly BufferRow[],
    conditions?: Conditions,
    notes?: readonly Note[],
    definition?: Definition,
): string {
    recipeList.update(root, (recipes) =>
        ordered(withRecipe(recipes, n, solutes, conditions, notes, definition)),
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
 * Changes one saved recipe in place, at once: the file is re-read under the lock, so
 * nothing of the other recipes is lost.
 *
 * @param n - the recipe's name, without regard to case.
 * @param change - given the recipe as it is on disk now; returns the recipe to keep.
 * @returns whether there was such a recipe (nothing is written when there was not).
 * @throws UnusableFileError like [[writeRecipes]].
 */
export function updateRecipe(
    root: string,
    n: string,
    change: (recipe: Recipe) => Recipe,
): boolean {
    return recipeList.update(root, (recipes) => {
        const i = indexOfRecipe(recipes, n)
        if (i === undefined) return undefined
        return ordered(recipes.map((r, j) => (j === i ? change(r) : r)))
    })
}

/**
 * Removes ONE saved recipe at once: it re-reads the file under the lock and drops that
 * recipe only, so another copy's changes to the others are never lost.
 *
 * @param n - the recipe's name, without regard to case.
 * @param options - `guarded: true` for a table showing the file as read for editing: the
 *     removal then refuses when another copy saved the file since.
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
        ...(r.notes !== undefined && { notes: r.notes }),
    }))
}
