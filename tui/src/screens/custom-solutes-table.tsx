// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import type { ReactNode } from "react"
import { useMemo } from "react"
import { appDir } from "../core/paths.js"
import {
    blankNonbio,
    blankPolymer,
    type CustomEntry,
    problems,
} from "../store/custom.js"
import {
    customFile,
    readCustomSolutes,
    removeCustomSolute,
    writeCustomSolutes,
} from "../store/custom-store.js"
import { type Row, rowValue } from "../store/draft.js"
import { globalScope, loadScope } from "../store/scope.js"
import { soundCatalog } from "../store/settings-store.js"
import { isBuiltinName } from "../store/solute-index.js"
import { type Column, DataTable } from "../ui/data-table.js"
import { Frame } from "../ui/frame.js"
import { keyLabels, keys } from "../ui/keys.js"
import { legendFor } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { useKeys } from "../ui/use-keys.js"
import { CustomNonbioForm } from "./custom-nonbio-form.js"
import { CustomPolymerForm } from "./custom-polymer-form.js"
import { formulaCell, pmvCell, sigmaCell, zCell } from "./custom-text.js"
import { useTableScreen } from "./use-table-screen.js"

/** The setting whose value stands for the blank ± of a non-biological solute. */
const FALLBACK_SETTING = "PMV_FALLBACK_UNCERT"

/** The widths of the two narrow columns: their titles, which the cells fit under. */
const PMV_WIDTH = 14
const SIGMA_WIDTH = 10

/** What the empty table says. */
const EMPTY_HINT = `none: ${keyLabels(keys.addNonbio, keys.addPolymer)} add`

/**
 * The global setting `PMV_FALLBACK_UNCERT`, which a blank ± stands for; the forms and
 * the table show it in parentheses.
 *
 * @returns its value, the default of the catalog if the settings cannot be read.
 */
function fallbackUncertainty(): number {
    try {
        const value = loadScope(globalScope).settings.get(FALLBACK_SETTING)
        if (typeof value === "number") return value
    } catch {
        // the unreadable settings are the settings screens' business: use the default
    }
    return soundCatalog().require(FALLBACK_SETTING).default as number
}

/**
 * Loads the custom solutes of the BAYSOL folder once.
 *
 * @param root - the BAYSOL data folder.
 * @returns the entries, or none and a `locked` message for a file that cannot be used.
 */
function load(root: string): { items: CustomEntry[]; locked?: string } {
    try {
        return { items: readCustomSolutes(root, { track: true }) }
    } catch {
        return { items: [], locked: `${basename(customFile(root))} unusable!` }
    }
}

/**
 * The names of the entries of the table other than one row, for the check of a name.
 *
 * @param rows - the rows.
 * @param except - the index of the row being edited, `undefined` for a new entry.
 * @returns the names of the rows that stay.
 */
function otherNames(
    rows: readonly Row<CustomEntry>[],
    except: number | undefined,
): string[] {
    return rows
        .filter((row, i) => i !== except && !row.removed)
        .map((row) => (rowValue(row) as CustomEntry).name)
}

/**
 * The custom solutes of the user: one row for each entry of the custom solutes file, with
 * the columns name, formula, Z, PMV at 25 °C and ± (cm³/mol). A polymer shows its units
 * by their labels (`A:C2H4O B:C3H6O`, Z `24A+32B+10`, PMV `36.9A+53.1B+9`). A new or
 * edited row shows `*`; nothing of that is written before `^w`.
 *
 * Keys: up and down move; Enter edits the row in its form page; `^n` and `^p` add a
 * non-biological solute and a polymer (their form pages), neither past 999 rows; `^r`
 * on a saved row asks `delete solute NAME? ...` and Enter deletes that entry from the
 * file at once (a row never saved just goes); `^u` undoes the last edit of the row; `^w`
 * saves (a row that is not complete is told and nothing is saved); `^x` goes back,
 * asking first when something is unsaved. A file that cannot be used
 * is told and left alone: the table is empty and nothing can be changed. The mechanics
 * are `useTableScreen`.
 *
 * @returns the screen.
 */
export function CustomSolutesTable(): ReactNode {
    const nav = useNav()
    const root = appDir()
    const loaded = useMemo(() => load(root), [root])
    const fallback = useMemo(fallbackUncertainty, [])
    const t = useTableScreen<CustomEntry>({
        items: loaded.items,
        locked: loaded.locked,
        erase: {
            what: "solute",
            name: (entry) => entry.name,
            remove: (entry) => void removeCustomSolute(root, entry.name),
        },
        save: (items) => void writeCustomSolutes(root, items),
        check: (drafts) => problems(drafts, isBuiltinName),
    })

    const form = (entry: CustomEntry, row: number | undefined) => {
        const others = otherNames(t.drafts.rows, row)
        const done = (e: CustomEntry) =>
            row === undefined ? t.append(e) : t.replaceAt(row, e)
        nav.push(
            entry.kind === "polymer" ? (
                <CustomPolymerForm entry={entry} others={others} onAccept={done} />
            ) : (
                <CustomNonbioForm
                    entry={entry}
                    others={others}
                    fallback={fallback}
                    onAccept={done}
                />
            ),
        )
    }

    useKeys((press) => {
        if (t.handleKey(press)) return
        if (press.is(keys.enter) && t.canEdit && t.current) form(t.current, t.cursor.index)
        else if (press.is(keys.addNonbio) && t.canAdd) form(blankNonbio(), undefined)
        else if (press.is(keys.addPolymer) && t.canAdd) form(blankPolymer(), undefined)
    })

    const columns: Column<Row<CustomEntry>>[] = [
        { title: "name", grow: 2, text: (r) => (rowValue(r) as CustomEntry).name },
        { title: "formula", grow: 2, text: (r) => formulaCell(rowValue(r) as CustomEntry) },
        {
            title: "Z",
            grow: 2,
            align: "right",
            text: (r) => zCell(rowValue(r) as CustomEntry),
        },
        {
            title: "PMV @ 25 °C",
            width: PMV_WIDTH,
            align: "right",
            text: (r) => pmvCell(rowValue(r) as CustomEntry),
        },
        {
            title: "± cm³/mol",
            width: SIGMA_WIDTH,
            align: "right",
            text: (r) => sigmaCell(rowValue(r) as CustomEntry, fallback),
        },
    ]

    // only the keys that work now: where the cursor is, what the rows and the file allow
    const legend = t.legend([
        legendFor("add nonbio", keys.addNonbio),
        legendFor("add polymer", keys.addPolymer),
    ])

    const changes = t.drafts.count
    return (
        <Frame
            title="custom solutes"
            subtitle={changes > 0 ? `${changes} unsaved` : basename(customFile(root))}
            legend={legend}
            note={t.frameNote}
            noteIsError={t.frameNoteIsError}
        >
            <DataTable
                columns={columns}
                rows={t.rows}
                cursor={t.cursor.index}
                offset={t.cursor.offset}
                pageSize={t.pageSize}
                mark={t.mark}
                empty={t.locked ? "" : EMPTY_HINT}
                width={t.width}
            />
        </Frame>
    )
}
