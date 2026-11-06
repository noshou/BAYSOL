// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { Fragment, type ReactNode } from "react"
import { displayWidth, padWidth, truncate } from "../core/text.js"
import { type CellPos, fitWidths, MIN_CELL } from "./form-layout.js"
import { useBodyColumns } from "./layout.js"
import { Prompt } from "./prompt.js"
import { Bar, Rule } from "./table-segments.js"
import { useTheme } from "./theme.js"

/** The blank cells between two columns of cells. */
const CELL_GAP = 2

/** The cells before a row: the cursor mark and a space. */
const LEAD = 2

/**
 * One cell of a [[FormRow]].
 *
 * @property text - what the cell shows.
 * @property muted - draw it in the muted colour: what is offered or implied, not typed
 *     (a placeholder such as `(A)`, a fallback such as `(3.04)`).
 * @property wide - the cell takes the rest of the row and does not count for the width
 *     of its column (a name, which can be long, in the first column of a table).
 */
export type FormCell = {
    text:   string
    muted?: boolean
    wide?:  boolean
}

/**
 * One row of a [[FieldForm]]: a label and one or more cells, a column of a cell being
 * its place in the array (`undefined` leaves a column of the row empty).
 *
 * @property label - what the row is, drawn muted before the cells.
 * @property cells - the cells, one per column.
 * @property heading - titles for the columns of a small table: this row starts the
 *     table, and it and the rows after it are drawn as a grid (the titles, a rule, the
 *     rows, `│` between the columns, all lines in the border colour).
 */
export type FormRow = {
    label:     string
    cells:     readonly (FormCell | undefined)[]
    heading?:  readonly string[]
}

/**
 * The cell being typed into: the form shows a [[Prompt]] under its rows.
 *
 * @property label - what is asked.
 * @property initial - the text to start from.
 * @property error - what was wrong with the last attempt, under the field.
 * @property onSubmit - called with the text when Enter takes it.
 * @property onCancel - called for Esc and Ctrl-X.
 * @property onChange - called after every edit (keep it stable, see `Entry`).
 */
export type FieldFormEdit = {
    label:     string
    initial:   string
    error?:    string
    onSubmit:  (text: string) => void
    onCancel:  () => void
    onChange:  () => void
}

/**
 * What a form is told.
 *
 * @property rows - the rows, top to bottom.
 * @property pos - the cell the cursor is on.
 * @property problem - a row to flag with a message at its end, in the error colour.
 * @property edit - the cell being typed into, if one is.
 */
type FieldFormProps = {
    rows:     readonly FormRow[]
    pos:      CellPos
    problem?: { row: number; message: string }
    edit?:    FieldFormEdit
}

/** The cells a column is to be wide: the longest text of its cells and heading. */
function naturalWidths(rows: readonly FormRow[], count: number): number[] {
    const natural = Array.from({ length: count }, () => 1)
    for (const row of rows) {
        row.cells.forEach((cell, c) => {
            if (cell && !cell.wide)
                natural[c] = Math.max(natural[c], displayWidth(cell.text))
        })
        row.heading?.forEach((h, c) => {
            natural[c] = Math.max(natural[c], displayWidth(h))
        })
    }
    return natural
}

/** The sizes a row is drawn with, worked out once for the whole form. */
type Metrics = {
    columns:    number
    labelWidth: number
    widths:     number[]
    gridFrom:   number
}

/** The cells before the first cell of a row: the cursor mark, the label and a gap. */
function leadWidth(m: Metrics): number {
    // in a grid the label is a column of its own, padded, then the separator and a pad
    return m.gridFrom < Infinity
        ? LEAD + m.labelWidth + 2 + 2
        : LEAD + m.labelWidth + CELL_GAP
}

/** The cells of every column of a grid, padding included: the label column first. */
function gridWidths(m: Metrics): number[] {
    return [m.labelWidth + 2, ...m.widths.map((w) => w + 2)]
}

/** A text cut and padded to the width of a column. */
function inColumn(text: string, c: number, m: Metrics): string {
    return padWidth(truncate(text, m.widths[c] as number), m.widths[c] as number)
}

/**
 * One row of the form: the cursor mark and the label, the cells (the one under the
 * cursor inverted) and the message of the row, if it has one.
 */
function RowLine(props: {
    row:      FormRow
    on:       boolean
    col:      number
    message?: string
    grid:     boolean
    m:        Metrics
}): ReactNode {
    const { row, on, col, message, grid, m } = props
    const theme = useTheme()
    // a wide cell takes the rest of the row but leaves room for the message
    const flag = message ? displayWidth(message) + CELL_GAP : 0
    const wideRoom = Math.max(MIN_CELL, m.columns - leadWidth(m) - flag)
    const gap = " ".repeat(CELL_GAP)
    const mark = `${on ? ">" : " "} `
    const lead = grid
        ? `${mark} ${padWidth(row.label, m.labelWidth)} `
        : `${mark}${padWidth(row.label, m.labelWidth)}${gap}`
    return (
        <Text color={theme.mt} wrap="truncate-end">
            {lead}
            {row.cells.map((cell, c) => {
                const here = on && c === col
                const text = !cell
                    ? " ".repeat(m.widths[c] as number)
                    : cell.wide
                        ? truncate(cell.text, wideRoom)
                        : inColumn(cell.text, c, m)
                const color = !cell || cell.muted ? theme.mt : theme.fg
                return (
                    // biome-ignore lint/suspicious/noArrayIndexKey: a column is its place
                    <Text key={c}>
                        {grid ? <Bar style="single" /> : null}
                        {grid ? " " : null}
                        <Text inverse={here} bold={here} color={color}>
                            {text || " "}
                        </Text>
                        {grid ? " " : c < row.cells.length - 1 ? gap : ""}
                    </Text>
                )
            })}
            {message ? <Text color={theme.er}>{`${gap}${message}`}</Text> : null}
        </Text>
    )
}

/**
 * A form page body: rows of a label and cells (one cell is a field, several are a small
 * table), the cursor on one cell drawn inverted, a message at the end of a row that has
 * a problem, and, while a cell is being edited, a prompt under the rows. It only draws;
 * the keys are those of `useFormScreen`. Columns are as wide as their longest text and
 * are squeezed, then truncated with `…`, when the terminal is narrow.
 *
 * @param props - see [[FieldFormProps]].
 * @returns the form.
 */
export function FieldForm(props: FieldFormProps): ReactNode {
    const { rows, pos, problem, edit } = props
    const theme = useTheme()
    const columns = useBodyColumns()

    const count = Math.max(...rows.map((r) => r.cells.length))
    const labelWidth = Math.max(...rows.map((r) => displayWidth(r.label)))
    const gridFrom = rows.findIndex((r) => r.heading !== undefined)
    const grid = gridFrom >= 0
    // a grid pays 2 cells of padding and a separator per column, the label column too
    const room = grid
        ? columns - LEAD - (labelWidth + 2) - count * 3
        : columns - LEAD - labelWidth - CELL_GAP - (count - 1) * CELL_GAP
    const m: Metrics = {
        columns,
        labelWidth,
        widths: fitWidths(naturalWidths(rows, count), room),
        gridFrom: grid ? gridFrom : Infinity,
    }

    return (
        <Box flexDirection="column">
            {rows.map((row, r) => (
                <Box key={row.label} flexDirection="column">
                    {row.heading ? (
                        <>
                            <Text color={theme.mt} wrap="truncate-end">
                                {" ".repeat(LEAD + 1 + m.labelWidth + 1)}
                                {row.heading.map((h, c) => (
                                    // biome-ignore lint/suspicious/noArrayIndexKey: column
                                    <Fragment key={c}>
                                        <Bar style="single" />
                                        {` ${inColumn(h, c, m)} `}
                                    </Fragment>
                                ))}
                            </Text>
                            <Rule
                                style="single"
                                part="mid"
                                widths={gridWidths(m)}
                                options={{ frame: false, lead: LEAD }}
                            />
                        </>
                    ) : null}
                    <RowLine
                        row={row}
                        on={r === pos.row}
                        col={pos.col}
                        message={problem?.row === r ? problem.message : undefined}
                        grid={r >= gridFrom && grid}
                        m={m}
                    />
                </Box>
            ))}
            {edit ? (
                <Box marginTop={1}>
                    <Prompt
                        label={edit.label}
                        initial={edit.initial}
                        error={edit.error}
                        onSubmit={edit.onSubmit}
                        onCancel={edit.onCancel}
                        onChange={edit.onChange}
                    />
                </Box>
            ) : null}
        </Box>
    )
}
