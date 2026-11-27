// SPDX-License-Identifier: LGPL-3.0-or-later

// The rows that follow a template. The rows a buffer template made carry its link, the
// optional `template` key of a buffer row (`buffer.json`, `recipes.json`), recorded in
// every row of the group the template made:
//
//     {"id": "tris", "mM": 10, "sigmaMm": 0.2, "titrant": "chloride", "restMm": 100,
//      "setAt": "buffer"}
//
// A row with a link follows the pH and the temperature of the table: when the pH changes
// they are worked out again, and when one of them is edited by hand or removed the rest
// of its group stops following. The link is optional and never an error: one that is not
// valid (an id that is not a template, a number that is not positive) is dropped from the
// row, which stays an ordinary row. Pure functions over the drafts of a table; the screen
// (`screens/buffer-template.tsx`) calls them, and the readers of the files use the link.
//
// A group is the rows with the same link. The ionic strength of the rest of the recipe
// is in the link: if the other salt rows change after the template was made, the link is
// not worked out again (pick the template again to refresh).
//
// Limit: two groups with an identical link (same template, amounts, titrant, rest, setAt)
// would share one key. The flow never makes a second one: picking the template again
// replaces the rows of the first (`TemplateFlow.find`), so there is one group per link.
//
// Contents:
//   1. The link: `TemplateLink`, `linkOf`, `cleanRow`, `keyOf`
//   2. Rows made from a template: `soluteArg`, `soluteFromSpec`
//   3. The rows follow the conditions: `setAtTemperature`, `signatures`, `detach`,
//      `changedGroups`, `recompute`, `seedOfRows`

import { lazyAsset, RUN_FLOW } from "../core/environment.js"
import { computeTemplate, type RowSpec, SET_TEMPERATURE_C } from "./buffer-templates.js"
import type { Drafts } from "./lists.js"
import { type Solute, sameSoluteKey } from "./solutes.js"
import {
    checkDefinition,
    type Definition,
    isNum,
    normalizeDefinition,
    rowsFor,
} from "./template-defs.js"
import type { PointRow, TableSeed } from "./template-wizard.js"

// ========================================================================================
// 1. The link
// ========================================================================================

/**
 * The link of a row.
 *
 * @property id - the template (`tris`, `pbs`, ...).
 * @property mM - the concentration of a buffer, mM (a mixture has none).
 * @property sigmaMm - its uncertainty, mM.
 * @property titrant - the counter-ion the buffer was made with.
 * @property restMm - the ionic strength of the rest of the recipe, mM.
 * @property setAt - the temperature the pH was set at: `"buffer"` (the buffer's, so the
 *     rows follow its temperature) or a number of °C (fixed). Required of a shipped
 *     template's link (one without a valid one is not a link); a `custom` or `table`
 *     definition carries its own.
 * @property definition - a `custom` or `table` definition ([[Definition]]) the rows are
 *     worked out from; `id` is then the kind (`custom`, `table`) and no other key is used.
 */
export type TemplateLink = {
    id: string
    definition?: Definition
    mM?: number
    "sigmaMm"?: number
    titrant?: string
    "restMm"?: number
    "setAt"?: "buffer" | number
}

/** What the asset says of a template, as far as a link needs it. */
type Known = {
    id: string
    kind: string
    available?: boolean
    bufferComponents?: unknown[]
}

/** The templates a link may name, read on first use. */
const known = lazyAsset<Known[]>("data", "buffer_templates.json")

/** The link of a custom or table definition: valid only when the definition checks. */
function definitionLink(value: unknown): TemplateLink | undefined {
    const definition = normalizeDefinition(value)
    if (definition === undefined || definition.kind === "builtin") return undefined
    if (checkDefinition(definition).length > 0) return undefined
    return { id: definition.kind, definition }
}

/**
 * The link a value stands for, rebuilt with only the keys of a link.
 *
 * @param value - what the row has under `template`.
 * @returns the link, `undefined` when the value is no valid link (no object, an id that
 *     is not an available template, a buffer without a concentration above 0, a mixture
 *     with nothing that follows the pH, a number that is not positive or a titrant that is
 *     no text).
 */
export function linkOf(value: unknown): TemplateLink | undefined {
    if (typeof value !== "object" || value === null) return undefined
    if (Array.isArray(value)) return undefined
    const v = value as Record<string, unknown>
    if ("definition" in v) return definitionLink(v.definition)
    const t = known().find((x) => x.id === v.id)
    if (!t || t.available === false) return undefined
    const link: TemplateLink = { id: t.id }
    if (t.kind === "buffer") {
        if (!(isNum(v.mM) && v.mM > 0)) return undefined
        link.mM = v.mM
        if ("sigmaMm" in v) {
            if (!(isNum(v.sigmaMm) && v.sigmaMm >= 0)) return undefined
            link.sigmaMm = v.sigmaMm
        }
    } else if (!t.bufferComponents?.length) return undefined
    if ("titrant" in v) {
        if (typeof v.titrant !== "string" || v.titrant.trim() === "") return undefined
        link.titrant = v.titrant
    }
    if ("restMm" in v) {
        if (!(isNum(v.restMm) && v.restMm >= 0)) return undefined
        link.restMm = v.restMm
    }
    const { min, max } = RUN_FLOW.temperature
    const at = v.setAt
    // only "buffer" or a temperature in range is valid, and the key must be there
    if (!(at === "buffer" || (isNum(at) && at >= min && at <= max))) return undefined
    link.setAt = at
    return link
}

/**
 * A row with its link checked: the valid link is kept (rebuilt), an invalid one is taken
 * off, a row without one is returned as it is.
 *
 * @param row - the row (a file's or a draft).
 * @returns the row.
 */
export function cleanRow<T extends object>(row: T): T {
    if (!("template" in row)) return row
    const { template, ...rest } = row as T & { template: unknown }
    const link = linkOf(template)
    return (link ? { ...rest, template: link } : rest) as T
}

/**
 * The key of a link, in a fixed key order: what makes two rows one group.
 *
 * @param link - the link.
 * @returns the key text.
 */
export function keyOf(link: TemplateLink): string {
    const { id, mM, titrant } = link
    const key = [id, mM, link.sigmaMm, titrant, link.restMm, link.definition]
    // a link without `setAt` keeps the key it always had
    return JSON.stringify("setAt" in link ? [...key, link.setAt] : key)
}

// ========================================================================================
// 2. Rows made from a template
// ========================================================================================

/**
 * The name a solute row is known by to a template: the `arg` of a bundled solute, the
 * `custom` name of a custom one (its row has no `arg`).
 *
 * @param s - a draft row.
 * @returns the name, `""` when the row has none.
 */
export function soluteArg(s: { kind: string; arg?: unknown; custom?: unknown }): string {
    return String((s.kind === "custom-nonbio" ? s.custom : s.arg) ?? "")
}

/**
 * The draft row a template makes of one of its rows: a bundled solute is a
 * `nonbiological` row (a `polymer` row for the Polymer species of glycylglycine); one with
 * a custom snapshot is a `custom-nonbio` row (the keys the loader reads, no `arg`).
 *
 * @param r - the row the template made.
 * @param template - the link that makes the row follow the conditions, left out for none.
 * @returns the draft.
 */
export function soluteFromSpec(r: RowSpec, template?: TemplateLink): Solute {
    const own = template === undefined ? {} : { template }
    const amounts = { mM: r.mM, sigmaMM: r.sigmaMM }
    if (r.custom === undefined) {
        const kind = r.kind ?? "nonbiological"
        return { kind, name: r.name, arg: r.arg, ...amounts, ...own }
    }
    return {
        kind: "custom-nonbio",
        name: r.name,
        custom: r.arg,
        z: r.custom.z,
        pmv: r.custom.pmv,
        "sigmaPmv": r.custom.sigmaPmv,
        ...amounts,
        ...own,
    } as Solute
}

// ========================================================================================
// 3. The rows follow the conditions
// ========================================================================================

/** The link of a draft, `undefined` for an ordinary row. */
function linkOfSolute(s: Solute): TemplateLink | undefined {
    return s.template === undefined ? undefined : linkOf(s.template)
}

/**
 * The temperature a link's pH was set at.
 *
 * @param link - the link.
 * @param buffer - the temperature of the buffer, °C, `undefined` while it has none.
 * @returns the number of `setAt`; the buffer's temperature for `"buffer"` (22 while the
 *     buffer has none).
 */
export function setAtTemperature(link: TemplateLink, buffer: number | undefined): number {
    const at = link.setAt
    return typeof at === "number" ? at : (buffer ?? SET_TEMPERATURE_C)
}

/** The rows of a group and their link. */
type Group = { link: TemplateLink; rows: number[] }

/** The groups of the table, by key: the indices of the rows that stay, with the link. */
function groups(drafts: Drafts<Solute>): Map<string, Group> {
    const out = new Map<string, Group>()
    drafts.rows.forEach((row, i) => {
        if (row.removed) return
        const link = linkOfSolute(drafts.value(i) as Solute)
        if (!link) return
        const group = out.get(keyOf(link)) ?? { link, rows: [] }
        group.rows.push(i)
        out.set(keyOf(link), group)
    })
    return out
}

/**
 * What each group holds now, to see later whether a row of it was edited or removed.
 *
 * @param drafts - the table.
 * @returns the key of each group and the text of its rows (name, amount, uncertainty),
 *     in an order that does not depend on the order of the table.
 */
export function signatures(drafts: Drafts<Solute>): Map<string, string> {
    const out = new Map<string, string>()
    for (const [key, { rows }] of groups(drafts)) {
        const text = rows
            .map((i) => {
                const s = drafts.value(i) as Solute
                return JSON.stringify([soluteArg(s), s.mM, s.sigmaMM])
            })
            .sort()
        out.set(key, text.join("|"))
    }
    return out
}

/**
 * The table with the groups of `keys` no longer linked: the link is taken off every row
 * of them.
 *
 * @param drafts - the table.
 * @param keys - the keys of the groups (from [[signatures]]).
 * @returns the table.
 */
export function detach(drafts: Drafts<Solute>, keys: readonly string[]): Drafts<Solute> {
    let next = drafts
    for (const [key, { rows }] of groups(drafts)) {
        if (!keys.includes(key)) continue
        for (const i of rows) {
            const { template: _gone, ...rest } = next.value(i) as Solute
            next = next.set(i, rest as Solute)
        }
    }
    return next
}

/**
 * The groups that changed between two states of the table: those that were there and
 * whose rows are not the same now.
 *
 * @param before - the signatures before.
 * @param after - the signatures after.
 * @returns the keys.
 */
export function changedGroups(
    before: ReadonlyMap<string, string>,
    after: ReadonlyMap<string, string>,
): string[] {
    const moved = ([k, v]: [string, string]) => after.has(k) && after.get(k) !== v
    return [...before].filter(moved).map(([k]) => k)
}

/**
 * Every group worked out again at a pH and a temperature: the amounts of its rows are set
 * (a row the new pH does not need any more is removed, one it needs is added with the
 * link). The temperature the pH was set at is the link's ([[setAtTemperature]]).
 *
 * @param drafts - the table.
 * @param pH - the new pH.
 * @param sigmaPH - σ of the pH.
 * @param temperature - the temperature of the buffer, °C, `undefined` while it has none.
 * @returns the new table, whether anything changed, and the args of rows the pH needs
 *     that were NOT added because another row of the same solute is in the table (the
 *     group stays; there is one row of a solute only), and the `errors` of definitions
 *     that cannot be worked out at this pH (a table outside its points): their rows stay.
 */
export function recompute(
    drafts: Drafts<Solute>,
    pH: number,
    sigmaPH: number,
    temperature?: number,
): { drafts: Drafts<Solute>; changed: boolean; skipped: string[]; errors: string[] } {
    let next = drafts
    let changed = false
    const skipped: string[] = []
    const errors: string[] = []
    const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase()
    for (const { link, rows } of groups(drafts).values()) {
        let outcome: Pick<ReturnType<typeof computeTemplate>, "rows">
        if (link.definition) {
            const made = rowsFor(link.definition, {
                pH,
                sigmaPH,
                temperatureC: temperature ?? SET_TEMPERATURE_C,
            })
            if ("error" in made) {
                errors.push(made.error)
                continue
            }
            outcome = made
        } else {
            try {
                outcome = computeTemplate({
                    id: link.id,
                    mM: link.mM,
                    sigmaMM: link.sigmaMm,
                    pH,
                    sigmaPH,
                    restIonicMM: link.restMm,
                    cation: link.titrant === "chloride" ? undefined : link.titrant,
                    tempC: setAtTemperature(link, temperature),
                })
            } catch {
                continue
            }
        }
        const taken = new Set<string>()
        const gone: number[] = []
        for (const i of rows) {
            const s = next.value(i) as Solute
            const want = outcome.rows.find((r) => same(r.arg, soluteArg(s)))
            if (!want) {
                gone.push(i)
                continue
            }
            taken.add(want.arg)
            if (want.mM !== s.mM || want.sigmaMM !== s.sigmaMM) {
                next = next.set(i, { ...s, mM: want.mM, sigmaMM: want.sigmaMM })
                changed = true
            }
        }
        const fresh = outcome.rows.filter((r) => !taken.has(r.arg))
        for (const r of fresh) {
            if (!next.hasRoom) break
            // a typed row of the same solute stays the only one
            const key = sameSoluteKey(soluteFromSpec(r))
            const twin = next.rows.some(
                (row, i) =>
                    !row.removed && sameSoluteKey(next.value(i) as Solute) === key,
            )
            if (twin) {
                skipped.push(r.arg)
                continue
            }
            next = next.add(soluteFromSpec(r, link))
            changed = true
        }
        // dropped from the end, so the indices of the others stay
        for (const i of gone.sort((a, b) => b - a)) {
            next = next.remove(i)
            changed = true
        }
    }
    return { drafts: next, changed, skipped, errors }
}

/**
 * The first point of a table template made from the rows of the table: every complete
 * row of a bundled or custom non-biological solute that does not follow a template yet,
 * at the table's pH. Polymers, proteins, DNA/RNA and rows that follow a template are not
 * part of it and stay as they are.
 *
 * @param drafts - the table.
 * @param pH - the table's pH.
 * @returns the seed and the indices of the rows it replaces, or `{ problem }`.
 */
export function seedOfRows(
    drafts: Drafts<Solute>,
    pH: number,
): { seed: TableSeed; indices: number[] } | { problem: string } {
    const rows: PointRow[] = []
    const indices: number[] = []
    for (let i = 0; i < drafts.length; i++) {
        if (drafts.rows[i]?.removed) continue
        const s = drafts.value(i) as Solute
        if (linkOfSolute(s) !== undefined) continue
        if (s.kind !== "nonbiological" && s.kind !== "custom-nonbio") continue
        const { mM, sigmaMM } = s
        if (!(typeof mM === "number" && mM > 0 && typeof sigmaMM === "number")) {
            return { problem: `row ${i + 1}: the amount is not complete` }
        }
        const amounts = { mM, sigmaMM }
        if (s.kind === "nonbiological") {
            rows.push({ name: s.name, arg: soluteArg(s), ...amounts })
        }
        else {
            const custom = {
                z: Number(s.z),
                pmv: Number(s.pmv),
                "sigmaPmv": typeof s.sigmaPmv === "number" ? s.sigmaPmv : null,
            }
            rows.push({ name: s.name, arg: String(s.custom), custom, ...amounts })
        }
        indices.push(i)
    }
    if (rows.length === 0) return { problem: "no solutes to turn into a template" }
    return { seed: { pH, rows }, indices }
}
