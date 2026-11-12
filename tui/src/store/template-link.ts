// SPDX-License-Identifier: LGPL-3.0-or-later

// The link of a row to the buffer template that made it: the optional `template` key of a
// buffer row (`buffer.json`, `recipes.json`), recorded in every row of the group the
// template made:
//
//     {"id": "tris", "mM": 10, "sigma-mM": 0.2, "titrant": "chloride", "rest-mM": 100,
//      "set-at": "buffer"}
//
// A row with a link follows the pH and the temperature of the table (`template-sync.ts`).
// The link is optional
// and never an error: one that is not valid (an id that is not a template, a number that
// is not positive) is dropped from the row, which stays an ordinary row. A leaf module,
// so that the readers of the files can use it.

import { lazyAsset, RUN_FLOW } from "../core/environment.js"
import type { RowSpec } from "./buffer-templates.js"
import type { Solute } from "./solutes.js"
import {
    checkDefinition,
    type Definition,
    isNum,
    normalizeDefinition,
} from "./template-defs.js"

/**
 * The link of a row.
 *
 * @property id - the template (`tris`, `pbs`, ...).
 * @property mM - the concentration of a buffer, mM (a mixture has none).
 * @property sigma-mM - its uncertainty, mM.
 * @property titrant - the counter-ion the buffer was made with.
 * @property rest-mM - the ionic strength of the rest of the recipe, mM.
 * @property set-at - the temperature the pH was set at: `"buffer"` (the buffer's, so the
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
    "sigma-mM"?: number
    titrant?: string
    "rest-mM"?: number
    "set-at"?: "buffer" | number
}

/** What the asset says of a template, as far as a link needs it. */
type Known = {
    id: string
    kind: string
    available?: boolean
    buffer_components?: unknown[]
}

/** The templates a link may name, read on first use. */
const known = lazyAsset<Known[]>("data", "buffer_templates.json")

/** Whether a value is a finite number. */

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
        if ("sigma-mM" in v) {
            if (!(isNum(v["sigma-mM"]) && v["sigma-mM"] >= 0)) return undefined
            link["sigma-mM"] = v["sigma-mM"]
        }
    } else if (!t.buffer_components?.length) return undefined
    if ("titrant" in v) {
        if (typeof v.titrant !== "string" || v.titrant.trim() === "") return undefined
        link.titrant = v.titrant
    }
    if ("rest-mM" in v) {
        if (!(isNum(v["rest-mM"]) && v["rest-mM"] >= 0)) return undefined
        link["rest-mM"] = v["rest-mM"]
    }
    const { min, max } = RUN_FLOW.temperature
    const at = v["set-at"]
    // only "buffer" or a temperature in range is valid, and the key must be there
    if (!(at === "buffer" || (isNum(at) && at >= min && at <= max))) return undefined
    link["set-at"] = at
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
    const key = [id, mM, link["sigma-mM"], titrant, link["rest-mM"], link.definition]
    // a link without `set-at` keeps the key it always had
    return JSON.stringify("set-at" in link ? [...key, link["set-at"]] : key)
}

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
 * `nonbiological` row; one with a custom snapshot is a `custom-nonbio` row (the keys the
 * loader reads, no `arg`).
 *
 * @param r - the row the template made.
 * @param template - the link that makes the row follow the conditions, left out for none.
 * @returns the draft.
 */
export function soluteFromSpec(r: RowSpec, template?: TemplateLink): Solute {
    const own = template === undefined ? {} : { template }
    const amounts = { mM: r.mM, sigmaMM: r.sigmaMM }
    if (r.custom === undefined) {
        return { kind: "nonbiological", name: r.name, arg: r.arg, ...amounts, ...own }
    }
    return {
        kind: "custom-nonbio",
        name: r.name,
        custom: r.arg,
        z: r.custom.z,
        pmv: r.custom.pmv,
        "sigma-pmv": r.custom["sigma-pmv"],
        ...amounts,
        ...own,
    } as unknown as Solute
}
