// SPDX-License-Identifier: LGPL-3.0-or-later

import { type ReactNode, useEffect, useMemo, useRef, useState } from "react"
import { formatNumber } from "../core/text.js"
import { paramsCell, rowNote } from "../store/add-flow.js"
import type { BufferRow } from "../store/buffer.js"
import { type Row, rowValue } from "../store/draft.js"
import { firstProblem, rowOf, type Solute, soluteOf } from "../store/solutes.js"
import { type Column, columnWidths, DataTable } from "../ui/data-table.js"
import { Frame } from "../ui/frame.js"
import { keys } from "../ui/keys.js"
import { legendFor } from "../ui/legend.js"
import { questionLegend, useConfirm } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"
import { EMPTY_HINT, replaceBufferQuestion } from "./buffer-text.js"
import { soluteProblem } from "./solute-rows.js"
import { useSoluteFlow } from "./use-solute-flow.js"
import { useTableScreen } from "./use-table-screen.js"

/**
 * The recipe that a table of solutes replaces at its first `^w`.
 *
 * @property count - how many solutes the target has now (above 0).
 * @property recipe - the name of the recipe the rows come from.
 */
type ReplaceInfo = { count: number; recipe: string }

/**
 * What a table of solutes edits and where it saves.
 *
 * @property title - the screen's title (`buffer`, or a recipe's name).
 * @property subtitle - what it is about (the project), shown while nothing is unsaved.
 * @property items - the rows the target holds now, as the file has them.
 * @property save - writes the rows the target is to have (`^w`, after the check); it
 *     throws if it cannot (the note is then `could not save!`). It is called with
 *     complete rows only.
 * @property locked - set when the target cannot be used: the table is empty, shows this
 *     as its note and changes nothing.
 * @property drafts - rows the table starts with as unsaved ones (a recipe loaded into the
 *     buffer): nothing of them is written before `^w`, which then replaces the target's
 *     rows; `items` is what the target has, usually none here.
 * @property hint - a note for the bottom line until the first `^w`.
 * @property idleNote - what the bottom line says when it has nothing else to say.
 * @property replace - when set, the first `^w` asks `replace N solutes with recipe
 *     "NAME"?` and saves only on Enter.
 */
type SolutesTableProps = {
    title: string
    subtitle?: string
    items: readonly BufferRow[]
    save: (rows: BufferRow[]) => void
    locked?: string
    drafts?: readonly BufferRow[]
    hint?: string
    idleNote?: string
    replace?: ReplaceInfo
}

/** The index of the params column, whose text depends on its width. */
const PARAMS_COLUMN = 1

/** A field the table shows. */
type Field = "name" | "params" | "mM" | "sigmaMM"

/**
 * One row of the table as the table draws it: the row and its place, which the cell being
 * typed into is found by.
 */
type View = { row: Row<Solute>; i: number }

/**
 * The columns of the table: name, params, mM and ±.
 *
 * @param cellText - the text of a cell: the row, then the field.
 * @param paramsWidth - the room the params text has.
 * @returns the columns.
 */
function columnsOf(
    cellText: (v: View, field: Field, paramsWidth: number) => string,
    paramsWidth: number,
): Column<View>[] {
    return [
        { title: "name", grow: 3, text: (v) => cellText(v, "name", paramsWidth) },
        { title: "params", grow: 4, text: (v) => cellText(v, "params", paramsWidth) },
        {
            title: "mM",
            grow: 1,
            align: "right",
            text: (v) => cellText(v, "mM", paramsWidth),
        },
        {
            title: "±",
            grow: 1,
            align: "right",
            text: (v) => cellText(v, "sigmaMM", paramsWidth),
        },
    ]
}

/**
 * A table of solutes: the buffer of a project, or one recipe. One row for each solute
 * with the columns name, params (the numbers of a polymer, the summary of a sequence),
 * mM and ±. A row that is new or edited shows `*`, one marked to be removed `-`; nothing
 * is written before `^w`.
 *
 * Keys: up and down move; Enter edits the row (name, params, mM, ±, each typed in a
 * prompt under the table); `^n`, `^p`, `^f`, `^e` add a non-biological solute, a polymer,
 * a protein and DNA or RNA from a file (a dropdown or a prompt under the table), none
 * past 999 rows; `^r` marks the row to be removed; `^u` undoes its last change; `^w`
 * saves (a row that is not complete is told and nothing is saved); `^x` goes back, asking
 * first when something is unsaved. While a flow is open Esc and `^x`
 * cancel it. The mechanics are `useTableScreen`, the flows `useSoluteFlow`.
 *
 * @param props - see [[SolutesTableProps]].
 * @returns the screen.
 */
export function SolutesTable(props: SolutesTableProps): ReactNode {
    const { title, subtitle, locked, idleNote } = props
    const items = useMemo(() => props.items.map(soluteOf), [props.items])
    const [hint, setHint] = useState(props.hint)
    const [replace, setReplace] = useState(props.replace)
    const confirm = useConfirm()

    const t = useTableScreen<Solute>({
        items,
        locked,
        save: (rows) => {
            props.save(rows.map(rowOf))
            // the recipe is replaced now, and what was said of it is done
            setReplace(undefined)
            setHint(undefined)
        },
        check: (drafts) => firstProblem(drafts, soluteProblem),
    })
    const flow = useSoluteFlow(t)

    // the rows given as drafts go in once, and the cursor stays at the top
    const seeded = useRef(false)
    const [atTop, setAtTop] = useState(false)
    // biome-ignore lint/correctness/useExhaustiveDependencies: once, when it opens
    useEffect(() => {
        if (seeded.current) return
        seeded.current = true
        const rows = props.drafts ?? []
        for (const row of rows) t.append(soluteOf(row))
        if (rows.length > 0) setAtTop(true)
    }, [])
    // biome-ignore lint/correctness/useExhaustiveDependencies: the cursor is `t.cursor`
    useEffect(() => {
        if (!atTop) return
        t.cursor.set(0)
        setAtTop(false)
    }, [atTop])

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        const ready = firstProblem(t.drafts, soluteProblem) === undefined
        if (press.is(keys.save) && replace && !t.locked && ready) {
            const room = t.width - 4
            const question = replaceBufferQuestion(replace.count, replace.recipe, room)
            confirm.ask(question, () => void t.handleKey(press))
            return
        }
        if (t.handleKey(press)) return
        if (press.is(keys.enter) && t.canEdit) flow.edit()
        else if (!t.canAdd) return
        else if (press.is(keys.addNonbio)) flow.add("nonbio")
        else if (press.is(keys.addPolymer)) flow.add("polymer")
        else if (press.is(keys.addProtein)) flow.add("protein")
        else if (press.is(keys.addNucleotide)) flow.add("nucleotide")
    }, !flow.open)

    const cellText = (v: View, field: Field, width: number) => {
        if (flow.cell?.row === v.i && flow.cell.field === field) return flow.cell.text
        const s = rowValue(v.row) as Solute
        if (field === "name") return s.name
        if (field === "params") return paramsCell(s, width).text
        return formatNumber(s[field])
    }
    const widths = columnWidths(columnsOf(cellText, 0), t.width)
    const paramsWidth = widths[PARAMS_COLUMN] as number
    const view: View[] = flow.rows.map((row, i) => ({ row, i }))

    // only the keys that work now (`useTableScreen` knows where the cursor is and what the
    // rows allow); a question of the screen's own (the recipe replace) shows its answers
    const legend = confirm.question
        ? questionLegend(confirm.question)
        : t.legend([
            legendFor("add solute", keys.addNonbio),
            legendFor("add polymer", keys.addPolymer),
            legendFor("add protein", keys.addProtein),
            legendFor("add DNA/RNA", keys.addNucleotide),
        ])

    // the questions first, then what an open flow says, the table's own note, the basis
    // of the polymer under the cursor, and what the caller asked to say
    const quiet = t.frameNote === undefined
    const note = confirm.note ?? (flow.open
        ?   flow.note
        :   (t.frameNote ??
            (t.current ? rowNote(t.current) : undefined) ??
            hint ??
            idleNote))
    const changes = t.drafts.count
    return (
        <Frame
            title={title}
            subtitle={changes > 0 ? `${changes} unsaved` : subtitle}
            legend={flow.open ? flow.legend : legend}
            note={note}
            noteIsError={!flow.open && !quiet && !confirm.question && t.frameNoteIsError}
        >
            <DataTable
                columns={columnsOf(cellText, paramsWidth)}
                rows={view}
                cursor={flow.cursor}
                offset={flow.offset}
                pageSize={flow.pageSize}
                mark={(v) => t.mark(v.row)}
                empty={t.locked ? "" : EMPTY_HINT}
                width={t.width}
            />
            {flow.entry}
        </Frame>
    )
}
