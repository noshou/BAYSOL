// SPDX-License-Identifier: LGPL-3.0-or-later

// Template recipes: a recipe of `recipes.json` with a `template` key, the definition of
// what depends on the pH and the temperature (`template-defs.ts`), stored inside the
// recipe. Its `solutes` are the FIXED rows (salt, protein, ...); loading it adds the rows
// the definition comes to at the buffer's pH, σ and temperature, each with a link
// (`template-link.ts`) so that they follow the conditions of the table. Julia never sees
// the definition: it reads rows only, and a row's `template` key is ignored there.
//
// Pure, nothing here throws. A definition that is not good makes the recipe an ordinary
// one that cannot be loaded as a template (`kind` is `invalid`, the problem is told).

import { type BufferRow, type Conditions, type Recipe, recipeConditions } from "./buffer.js"
import { rowOf } from "./solutes.js"
import {
    checkDefinition,
    type Definition,
    normalizeDefinition,
    rowsFor,
} from "./template-defs.js"
import {
    keyOf,
    linkOf,
    soluteArg,
    soluteFromSpec,
    type TemplateLink,
} from "./template-link.js"

/** What the definition of a recipe is: the definition, or what is wrong with it. */
export type RecipeTemplate = { definition: Definition } | { problem: string }

/** What a recipe is, as the table of recipes tells it. */
export type RecipeKind = "recipe" | "builtin" | "custom" | "table" | "invalid"

/**
 * The definition of a recipe.
 *
 * @param recipe - the recipe (its `template` key is looked at).
 * @returns `undefined` for a recipe without one, the definition when it is good, else
 *     the first problem.
 */
export function templateOf(recipe: { template?: unknown }): RecipeTemplate | undefined {
    if (recipe.template === undefined) return undefined
    const definition = normalizeDefinition(recipe.template)
    if (definition === undefined) return { problem: "the template is not a definition" }
    const problems = checkDefinition(definition)
    return problems.length > 0 ? { problem: problems[0] as string } : { definition }
}

/** @returns what a recipe is: an ordinary one, a template of a kind, or an invalid one. */
export function kindOf(recipe: { template?: unknown }): RecipeKind {
    const t = templateOf(recipe)
    if (t === undefined) return "recipe"
    return "problem" in t ? "invalid" : t.definition.kind
}

/**
 * The link the rows of a definition carry, so that they follow the table's conditions.
 *
 * @param definition - a good definition.
 * @returns the link; a `builtin` one is the link `shift+b` makes, a `custom` or `table`
 *     one holds the definition.
 */
export function linkFor(definition: Definition): TemplateLink {
    if (definition.kind !== "builtin") return { id: definition.kind, definition }
    const link: TemplateLink = { id: definition.id }
    if (definition.mM !== undefined) link.mM = definition.mM
    if (definition.sigmaMM !== undefined) link.sigmaMm = definition.sigmaMM
    if (definition.ion !== undefined) link.titrant = definition.ion
    if (definition.restMM !== undefined) link.restMm = definition.restMM
    link.setAt = definition.pHSetAt ?? "buffer"
    return link
}

/**
 * The definition a link stands for.
 *
 * @param link - a valid link of a row.
 * @returns the definition.
 */
export function definitionOf(link: TemplateLink): Definition {
    if (link.definition) return link.definition
    const at = link.setAt
    return {
        kind: "builtin",
        id: link.id,
        ...(link.mM !== undefined && { mM: link.mM }),
        ...(link.sigmaMm !== undefined && { sigmaMM: link.sigmaMm }),
        // `chloride` is an acid's anion, no cation: the definition leaves `ion` out then
        ...(link.titrant !== undefined && link.titrant !== "chloride"
            ? { ion: link.titrant }
            : {}),
        ...(typeof at === "number" && { pHSetAt: at }),
        ...(link.restMm !== undefined && { restMM: link.restMm }),
    }
}

/**
 * The buffer's rows as a template recipe: the definition of its one linked group, the
 * other rows fixed.
 *
 * @param rows - the rows of the buffer (a draft's or the file's).
 * @returns `undefined` when no row has a valid link; `{ problem }` when the links are
 *     of more than one group (a recipe has one template); else the definition and the
 *     rows without a link, which stay in the recipe as they are.
 */
export function templateOfRows(
    rows: readonly BufferRow[],
): { definition: Definition; fixed: BufferRow[] } | { problem: string } | undefined {
    const links = new Map<string, TemplateLink>()
    for (const row of rows) {
        const link = linkOf(row.template)
        if (link) links.set(keyOf(link), link)
    }
    if (links.size === 0) return undefined
    if (links.size > 1) {
        return { problem: "the buffer has rows of more than one template: save as recipe" }
    }
    const [link] = [...links.values()] as [TemplateLink]
    const fixed = rows.filter((r) => !linkOf(r.template))
    return { definition: definitionOf(link), fixed: fixed.map(withoutLink) }
}

/** A row without its link. */
function withoutLink(row: BufferRow): BufferRow {
    const { template: _gone, ...rest } = row
    return rest as BufferRow
}

/**
 * The rows a template recipe loads: its fixed rows, then the rows of its definition at
 * the conditions, each with the link that makes them follow those conditions.
 *
 * @param recipe - the recipe.
 * @param c - the pH, σ of the pH and temperature (°C).
 * @returns the rows and the warnings of the engine, or `{ error }`: the recipe has no
 *     good definition, or the conditions cannot be worked out (a table outside its points).
 */
export function templateRows(
    recipe: Recipe,
    c: { pH: number; sigmaPH: number; temperatureC: number },
): { rows: BufferRow[]; warnings: string[] } | { error: string } {
    const t = templateOf(recipe)
    if (t === undefined) return { error: "not a template" }
    if ("problem" in t) return { error: t.problem }
    const made = rowsFor(t.definition, c)
    if ("error" in made) return made
    const link = linkFor(t.definition)
    const argOf = (r: BufferRow) => soluteArg(r as { kind: string }).toLowerCase()
    const fixed = new Set(recipe.solutes.map(argOf))
    const twin = made.rows.find((r) => fixed.has(r.arg.toLowerCase()))
    if (twin) return { error: `${twin.arg} is in the recipe's rows and in the template` }
    const generated = made.rows.map((r) => rowOf(soluteFromSpec(r, link)))
    return { rows: [...recipe.solutes, ...generated], warnings: made.warnings }
}

/**
 * A recipe with its definition set.
 *
 * @param recipe - the recipe.
 * @param definition - the definition, `undefined` to make it an ordinary recipe again.
 * @returns the recipe, its other keys kept.
 */
export function withTemplate(recipe: Recipe, definition?: Definition): Recipe {
    const { template: _old, ...rest } = recipe
    return definition === undefined ? rest : { ...rest, template: definition }
}

/**
 * What loading a recipe into the buffer table brings.
 *
 * @property rows - the rows, as unsaved ones.
 * @property conditions - the pH row to show, left out for the recipe's own.
 * @property template - the rows came from a template (the question says `template`).
 * @property hint - what to say under the table, left out for nothing.
 */
export type RecipeLoad =
    | { rows: BufferRow[]; conditions?: Conditions; template: boolean; hint?: string }
    | { message: string }

/**
 * What loading a recipe comes to: an ordinary recipe is its rows; a template is its fixed
 * rows and the rows of its definition at the recipe's pH, σ and temperature (else the
 * buffer's), each linked so that it follows them; a template that cannot be used is its
 * fixed rows with the problem as the hint.
 *
 * @param recipe - the recipe.
 * @param buffer - the buffer's conditions, `undefined` while it has none.
 * @returns the rows, or the `message` that says why nothing is loaded (no pH or no
 *     temperature anywhere, or the conditions cannot be worked out).
 */
export function recipeLoad(
    recipe: Recipe,
    buffer: Conditions | undefined,
): RecipeLoad {
    const kind = kindOf(recipe)
    if (kind === "recipe") return { rows: recipe.solutes, template: false }
    if (kind === "invalid") {
        const bad = templateOf(recipe)
        const why = bad && "problem" in bad ? bad.problem : ""
        return {
            rows: recipe.solutes,
            template: false,
            hint: `template not used: ${why}`,
        }
    }
    const held = recipeConditions(recipe) ?? buffer
    if (held === undefined)
        return { message: "set the pH first (buffer table, ^g): the template needs it" }
    const temperature = held.temperature ?? buffer?.temperature
    if (temperature === undefined)
        return {
            message: "set the temperature first (buffer table, ^g): the template needs it",
        }
    const made = templateRows(recipe, {
        pH: held.pH,
        sigmaPH: held.sigmaPh,
        temperatureC: temperature,
    })
    if ("error" in made) return { message: `${recipe.name}: ${made.error}` }
    return {
        rows: made.rows,
        conditions: { ...held, temperature },
        template: true,
        ...(made.warnings.length > 0 ? { hint: made.warnings.join("; ") } : {}),
    }
}

/**
 * How the buffer is written as a recipe.
 *
 * @param rows - the buffer's rows.
 * @param asTemplate - make the one linked group the recipe's definition.
 * @returns the rows to store and, for a template, its definition (the rows of the group
 *     are not stored: the definition makes them). Without a group, or not asked, the rows
 *     as they are.
 */
export function recipeSave(
    rows: readonly BufferRow[],
    asTemplate: boolean,
): { solutes: BufferRow[]; definition?: Definition } {
    const made = asTemplate ? templateOfRows(rows) : undefined
    if (made && "definition" in made) {
        return { solutes: made.fixed, definition: made.definition }
    }
    return { solutes: [...rows] }
}

/**
 * Whether saving these rows as a recipe may be a template: they hold exactly one group of
 * linked rows.
 *
 * @param rows - the buffer's rows.
 * @returns `true` when the question `save as a template?` is asked.
 */
export function offersTemplate(rows: readonly BufferRow[]): boolean {
    const made = templateOfRows(rows)
    return made !== undefined && "definition" in made
}
