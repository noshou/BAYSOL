// SPDX-License-Identifier: LGPL-3.0-or-later

// Column descriptions: the one sentence the viewer's status line shows for the column
// under the cursor (`assets/data/column_descriptions.json`). Pure: no screen, no file but
// the asset. The headers are those the pipeline writes (`src/pipeline/tables.jl`,
// `summary.jl`, `results.jl`, `compare.jl`).

import { lazyAsset } from "../core/environment.js"
import { superscripts, truncate } from "../core/terminal.js"

/**
 * The shape of `assets/data/column_descriptions.json`: sentences by sheet group, then by
 * column header as the pipeline writes it. The group `*` holds the headers shared by
 * several sheets and is the fallback of every other group.
 */
export type ColumnDescriptions = Record<string, Record<string, string>>

/**
 * The longest counter the status line prints before the sentence: the cell, the row
 * counter (a marked range replaces it by `range AB1:AB20000`, which is no wider).
 */
export const WORST_COUNTER = "AB20000 · row 20000 / 20000"

/**
 * The most cells a description may take. The status line sits in the viewer's panel: 80
 * columns less the frame (2), the panel's border and padding (4), the counter and the
 * ` · ` that joins the sentence to it: 80 - 6 - 27 - 3 = 44.
 */
export const DESCRIPTION_CELLS = 44

/** The sheets whose rows are named parameters (the groups of `descriptionGroup`). */
const PARAMETER_SHEETS: ReadonlySet<string> = new Set([
    "map",
    "quantiles",
    "stdevFromPrior",
])

const descriptions = lazyAsset<ColumnDescriptions>("data", "column_descriptions.json")

/**
 * The group of descriptions a sheet uses: `hist_<parameter>` is `hist`, `ref_<name>` is
 * `ref`, `quantiles<interval>` is `quantiles`, a table named for the comparison is
 * `compare`, any other sheet is its own name.
 *
 * @param sheetName - the sheet's (or delimited file's) name.
 * @returns the group's name (it may have no entry: then only `*` applies).
 */
export function descriptionGroup(sheetName: string): string {
    if (sheetName.startsWith("hist_")) return "hist"
    if (sheetName.startsWith("ref_")) return "ref"
    if (sheetName.startsWith("quantiles")) return "quantiles"
    if (/compare/i.test(sheetName)) return "compare"
    return sheetName
}

/**
 * The sentence for a column header.
 *
 * @param sheetName - the sheet's name.
 * @param header - the header as written or as the viewer shows it (`A^-1` or `Å⁻¹`).
 * @returns the sentence, or `undefined` for a header that has none.
 */
export function describeColumn(sheetName: string, header: string): string | undefined {
    const all = descriptions()
    const wanted = header.trim()
    for (const group of [descriptionGroup(sheetName), "*"]) {
        const entries = all[group]
        if (entries === undefined) continue
        for (const [key, text] of Object.entries(entries)) {
            if (key === wanted || superscripts(key) === wanted) return text
            // `fit_<model> (a.u.)`, `ref_<name> (a.u.)`: a key ending in `*` is a prefix
            if (key.endsWith("*") && wanted.startsWith(key.slice(0, -1))) return text
        }
    }
    return undefined
}

/**
 * What the status line adds after the row counter for the cell under the cursor.
 *
 * @param sheetName - the sheet's name.
 * @param cells - the sheet's cells (`cells[0]` is the header row when `header` is on).
 * @param header - the first row is a header.
 * @param row - the cursor's row.
 * @param column - the cursor's column.
 * @returns the sentence: on the sheets `map`, `quantiles` and `stdevFromPrior` the
 *     description of the row's parameter (group `parameterRows`) in the `parameter`
 *     column, the other cells the column's; on the `run` sheet the description of the row's
 *     `name` (group `runRows`; a workbook of an older release may carry a fifth column,
 *     which is
 *     ignored); otherwise the description of the column's header; `undefined` for neither.
 */
export function cellDescription(
    sheetName: string,
    cells: string[][],
    header: boolean,
    row: number,
    column: number,
): string | undefined {
    if (!header) return undefined
    const heads = cells[0] ?? []
    if (sheetName === "run" && row > 0) {
        const name = cells[row]?.[heads.indexOf("name")]?.trim() ?? ""
        const own = descriptions().runRows?.[name]
        if (own) return own
    }
    if (PARAMETER_SHEETS.has(descriptionGroup(sheetName)) && row > 0) {
        // the rows are named parameters (`rhoE`, `deltaRho1`, ...): the row says what it is
        const name = cells[row]?.[heads.indexOf("parameter")]?.trim() ?? ""
        const own = descriptions().parameterRows?.[name]
        if (own && column === heads.indexOf("parameter")) return own
    }
    const head = heads[column]
    return head === undefined || head === "" ? undefined : describeColumn(sheetName, head)
}

/**
 * The description cut to the room left on the status line (never a second row).
 *
 * @param text - the sentence.
 * @param room - the cells left; nothing is shown below 8, which is too little to read.
 * @returns the text cut with an ellipsis, or `""`.
 */
export function fitDescription(text: string, room: number): string {
    return room < 8 ? "" : truncate(text, room)
}
