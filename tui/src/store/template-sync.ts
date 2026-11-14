// SPDX-License-Identifier: LGPL-3.0-or-later

// Rows that follow the pH: the rows a buffer template made carry its link
// (`template-link.ts`); when the pH of the table changes they are worked out again, and
// when one of them is edited by hand or removed the rest of its group stops following.
// Pure functions over the drafts of a table; the screen (`screens/buffer-template.tsx`)
// calls them.
//
// A group is the rows with the same link. The ionic strength of the rest of the recipe
// is in the link: if the other salt rows change after the template was made, the link is
// not worked out again (pick the template again to refresh).
//
// Limit: two groups with an identical link (same template, amounts, titrant, rest, setAt)
// would share one key. The flow never makes a second one: picking the template again
// replaces the rows of the first (`TemplateFlow.find`), so there is one group per link.

import { computeTemplate, SET_TEMPERATURE_C } from "./buffer-templates.js"
import type { Drafts } from "./lists.js"
import { type Solute, sameSoluteKey } from "./solutes.js"
import { rowsFor } from "./template-defs.js"
import {
    keyOf,
    linkOf,
    soluteArg,
    soluteFromSpec,
    type TemplateLink,
} from "./template-link.js"
import type { PointRow, TableSeed } from "./template-wizard.js"

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

/** The indices of the rows that stay, by group, with their link. */
/** The rows of a group and their link. */
type Group = { link: TemplateLink; rows: number[] }

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
        if (s.kind === "nonbiological") rows.push({ name: s.name, arg: s.arg, ...amounts })
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
