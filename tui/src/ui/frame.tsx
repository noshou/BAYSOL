// SPDX-License-Identifier: LGPL-3.0-or-later

// Frame: the frame around every screen (title, body, legend, theme line) and the form
// pages drawn inside it.
//
// Contents:
//   1. `Frame`: title, body, legend and the theme line of a screen
//   2. Layout: column widths and cursor moves of a form (pure)
//   3. `FieldForm`: the component that draws the rows of cells
//   4. `useFormScreen`: the cursor, editing and key wiring of a form screen

import { Box, Text } from "ink"
import { Fragment, type ReactNode, useCallback, useState } from "react"
import { LOGS_FLOW } from "../core/environment.js"
import { displayWidth, padWidth, truncate } from "../core/terminal.js"
import { runDisplay } from "../store/projects.js"
import {
    type Design,
    Legend,
    type LegendItem,
    legendHeight,
    type Moves,
    smallLogo,
} from "./grid.js"
import { Prompt } from "./input.js"
import { keys, useBodyColumns, useKeys } from "./interaction.js"
import { Bar, type LineStyle, Panel, Rule, useTheme } from "./theme.js"

// ========================================================================================
// 1. `Frame`: title, body, legend and the theme line of a screen
// ========================================================================================

/**
 * The corner text of the logs and `open runs` pages: the muted line at the top right of the
 * title row, `project: <project name> · run: <run name>` (the run list, which has no run
 * chosen yet, shows only the project). Pure, so the rule is tested; `Frame` draws it.
 */

/** The cells kept between the title (with its subtitle) and the corner. */
const GAP = 2

/**
 * The corner text of a logs or `open runs` page.
 *
 * @param project - the project's name.
 * @param run - the run's name, `undefined` on the run list.
 * @returns `project: demo` or `project: demo · run: 19:33:08:000 UTC +00:00 · 2026-11-06`.
 */
export function cornerLabel(project: string, run?: string): string {
    const { separator } = LOGS_FLOW.corner
    return run === undefined
        ? `project: ${project}`
        : `project: ${project}${separator}run: ${runDisplay(run)}`
}

/**
 * The corner as far as it fits: cut with an ellipsis before it can push the title, and
 * left out altogether when what is left is less than `corner.minCells` (a few cells of
 * `pro…` say nothing).
 *
 * @param label - the corner text.
 * @param columns - the width of the title row.
 * @param title - the title of the page.
 * @param subtitle - its subtitle, if any (drawn as `· subtitle`, a space between).
 * @returns the text to draw, or `undefined` for none.
 */
export function fitCorner(
    label: string,
    columns: number,
    title: string,
    subtitle?: string,
): string | undefined {
    const used =
        displayWidth(title) + (subtitle ? 1 + displayWidth(`· ${subtitle}`) : 0) + GAP
    const room = columns - used
    if (room < LOGS_FLOW.corner.minCells) return undefined
    return truncate(label, room)
}

/** Both small logos, loaded once: they are read from disk. */
const logos = { blocky: smallLogo("blocky"), smooth: smallLogo("smooth") }

/** The cells the double-line box of a blocky footer takes beside its content. */
const BLOCKY_BOX_CELLS = 4

/** The rows that box takes above and below its content (the border). */
const BLOCKY_BOX_ROWS = 2

/** The cells between the logo and the keys. */
const FOOTER_GAP = 2

/** The cells a counter box takes besides its text (border and padding) and its gap. */
const COUNTER_CELLS = 4

/**
 * The cells the keys of the footer may take.
 *
 * @param design - which footer: the blocky one sits in a box of its own.
 * @param columns - the width of the body (`useBodyColumns`).
 * @param counter - the counter text, if any.
 * @returns the room, at least 1.
 */
function legendRoom(design: Design, columns: number, counter?: string): number {
    const box = design === "blocky" ? BLOCKY_BOX_CELLS : 0
    const count = counter ? displayWidth(counter) + COUNTER_CELLS + FOOTER_GAP : 0
    return Math.max(1, columns - box - logos[design].width - FOOTER_GAP - count)
}

/**
 * The lines the keys of a footer take for a legend: the same count the frame reserves, so
 * a screen can take them off the rows of its body.
 *
 * @param items - the legend.
 * @param design - which footer.
 * @param columns - the width of the body (`useBodyColumns`).
 * @param counter - the counter text, if any.
 * @returns the height of the keys, 0 for none.
 */
function footerLegendLines(
    items: readonly LegendItem[],
    design: Design,
    columns: number,
    counter?: string,
): number {
    return legendHeight(items, legendRoom(design, columns, counter))
}

/**
 * The rows a footer's keys take beyond the lines its screen's own row count allows for: the
 * one rule behind every screen that gives its body's page size up for a taller footer.
 *
 * @param items - the legend (the fullest, or the one shown).
 * @param columns - the width of the body (`useBodyColumns`).
 * @param base - the lines the screen's row count already counts for the keys.
 * @param design - which footer; the blocky one adds the rows of its box.
 * @returns the extra rows, 0 when the keys fit `base` lines of a smooth footer.
 */
export function footerExtraLines(
    items: readonly LegendItem[],
    columns: number,
    base: number,
    design: Design = "smooth",
): number {
    const box = design === "blocky" ? BLOCKY_BOX_ROWS : 0
    return Math.max(0, footerLegendLines(items, design, columns) - base) + box
}

/**
 * What a screen tells the frame.
 *
 * @property title - the name of the screen, e.g. `"sampler settings"`.
 * @property subtitle - what it is about, e.g. the project's name.
 * @property legend - the keys that work now.
 * @property legendFull - the fullest legend this screen can show (every key that can
 *     ever work on it). The footer reserves the height of that legend, so a key appearing
 *     or disappearing while the user works never moves the logo or the body: the
 *     footer's height depends on the screen and the terminal width only. Without it the
 *     footer takes the height of the legend shown now.
 * @property design - `"blocky"` for the table-style screens (tables, forms, settings
 *     sheets, logs): the blocky logo, the keys and the counter in one double-line box;
 *     `"smooth"` (default): the rounded logo, the keys loose. Its footer is taller by the
 *     box's two rows, which [[footerExtraLines]] reserves.
 * @property counter - a short text in a box at the bottom right, such as
 *     `"sampler [1 / 6]"` or `"solutes [3 / 12]"`.
 * @property note - one line above the keys: a question (`discard 3 changes?`), an
 *     error, or a hint. It is cut to the width of the terminal.
 * @property noteIsError - draw the note in the error colour.
 * @property corner - a muted text at the top right of the title row (the logs and
 *     `open runs` pages show `project: <name> · run: <name>` there). It is cut with an
 *     ellipsis before it can push the title, and left out when too little room is left
 *     (`fitCorner`).
 */
type FrameProps = {
    title:        string
    subtitle?:    string
    legend:       LegendItem[]
    legendFull?:  LegendItem[]
    design?:      Design
    counter?:     string
    note?:        string
    noteIsError?: boolean
    corner?:      string
    children?:    ReactNode
}

/**
 * The common shape of every screen below the menus: a title, a body that takes the
 * rest of the terminal, and at the bottom the small BAYSOL logo, the keys that work, an
 * optional note and an optional counter. It reads the size of the terminal and keeps
 * no fixed size of its own.
 *
 * @param props - see [[FrameProps]].
 * @returns the screen.
 */
export function Frame(props: FrameProps): ReactNode {
    const {
        title,
        subtitle,
        legend,
        legendFull,
        design = "smooth",
        counter,
        note,
        noteIsError,
        corner,
        children,
    } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const art = logos[design]
    const cornerShown =
        corner === undefined ? undefined : fitCorner(corner, columns, title, subtitle)

    // the note has a row of its own whether there is one or not, so a note appearing
    // never makes the footer taller (which would push the body, and the logo, up a row)
    const noteLine = (
        <Box height={1} flexShrink={0}>
            {note ? (
                <Text color={noteIsError ? theme.er : theme.fg}>
                    {truncate(note, legendRoom(design, columns, counter))}
                </Text>
            ) : null}
        </Box>
    )
    const logoBox = (
        <Box
            width={art.width}
            height={art.height}
            backgroundColor={theme.bg}
            flexShrink={0}
        >
            <Text color={theme.fg}>{art.text}</Text>
        </Box>
    )
    const counterBox = counter ? (
        <Panel style={design === "blocky" ? "double" : "round"} paddingX={1}>
            <Text color={theme.fg}>{counter}</Text>
        </Panel>
    ) : null

    // the keys' column is as tall as the fullest legend of the screen (or the one shown,
    // if that is taller) plus the note, with the note and the keys at the bottom beside
    // the logo: a legend that shrinks leaves blank rows above the note, never a moved logo
    const room = legendRoom(design, columns, counter)
    const keyLines = Math.max(
        legendHeight(legend, room),
        legendFull ? legendHeight(legendFull, room) : 0,
    )
    const keysColumn = {
        flexDirection: "column",
        flexGrow: 1,
        justifyContent: "flex-end",
        height: keyLines + 1,
    } as const

    return (
        <Box flexDirection="column" flexGrow={1} paddingX={1}>
            <Box>
                <Box columnGap={1} flexShrink={0}>
                    <Text bold color={theme.fg}>{title}</Text>
                    {subtitle ? <Text color={theme.mt}>· {subtitle}</Text> : null}
                </Box>
                <Box flexGrow={1} />
                {cornerShown ? (
                    <Text color={theme.mt} wrap="truncate-end">{cornerShown}</Text>
                ) : null}
            </Box>

            <Box flexDirection="column" flexGrow={1} marginTop={1}>
                {children}
            </Box>

            <Footer boxed={design === "blocky"}>
                {logoBox}
                <Box {...keysColumn}>
                    {noteLine}
                    <Legend items={legend} room={room} />
                </Box>
                {counterBox}
            </Footer>
        </Box>
    )
}

/** The footer's wrapper: a double-line [[Panel]] (blocky) or a bare row (smooth). */
function Footer(props: { boxed: boolean; children: ReactNode }): ReactNode {
    return props.boxed ? (
        <Panel style="double" paddingX={1} columnGap={2} alignItems="flex-end">
            {props.children}
        </Panel>
    ) : (
        <Box columnGap={2} alignItems="flex-end">
            {props.children}
        </Box>
    )
}

// ========================================================================================
// 2. Layout
// ========================================================================================

// The pure parts of a form page (`FieldForm`, `useFormScreen`, below): how wide
// the columns of its cells are on a terminal of some width, and where the cursor goes
// for an arrow key. A form is a few rows of cells; a row has one cell (a plain field) or
// several (a small table, like the units of a polymer). The cursor is a cell.

/** The narrowest a column of cells is squeezed to when the terminal is narrow. */
const MIN_CELL = 3

/**
 * Where the cursor is on a form: a row and a column of its cells.
 *
 * @property row - the row.
 * @property col - the column of the cell, one of the valid columns of the row.
 * @property want - the column the user last asked for with left and right, kept while
 *     the cursor moves up and down so that a row with fewer cells does not make it
 *     forget the column (it goes to the nearest valid one of each row).
 */
export interface CellPos {
    row: number
    col: number
    want: number
}

/**
 * The cursor on a cell.
 *
 * @param row - the row.
 * @param col - the column.
 * @returns the position, with `want` the column too.
 */
export function placeAt(row: number, col: number): CellPos {
    return { row, col, want: col }
}

/**
 * The widths of the columns of a form, squeezed to fit.
 *
 * @param natural - the width each column would like (its longest text).
 * @param room - the cells the columns may use together.
 * @param floor - the width below which no column is squeezed, [[MIN_CELL]] by default.
 * @returns one width per column: the natural ones if they fit, else the widest column
 *     loses a cell at a time (the first of equal ones) until they fit or all are at the
 *     floor.
 */
function fitWidths(
    natural: readonly number[],
    room: number,
    floor: number = MIN_CELL,
): number[] {
    const widths = natural.map((w) => Math.max(w, 1))
    const total = () => widths.reduce((sum, w) => sum + w, 0)
    while (total() > room) {
        const widest = Math.max(...widths)
        if (widest <= floor) break
        widths[widths.indexOf(widest)] = widest - 1
    }
    return widths
}

/**
 * The cursor after an arrow key. Up and down go to the row above or below, to its valid
 * column nearest to the one asked for; left and right go to the previous and next valid
 * column of the row, and become the column asked for. Nothing wraps.
 *
 * @param valid - for each row, the columns that have a cell, ascending, none empty.
 * @param pos - where the cursor is.
 * @param dRow - rows to move (-1, 0 or 1).
 * @param dCol - cells to move along the row (-1, 0 or 1).
 * @returns the new position.
 */
export function moveCell(
    valid: readonly (readonly number[])[],
    pos: CellPos,
    dRow: number,
    dCol: number,
): CellPos {
    if (dRow !== 0) {
        const row = Math.min(Math.max(pos.row + dRow, 0), valid.length - 1)
        const cols = valid[row] as readonly number[]
        const near = (a: number, b: number) =>
            Math.abs(a - pos.want) <= Math.abs(b - pos.want) ? a : b
        return { row, col: cols.reduce(near), want: pos.want }
    }
    const cols = valid[pos.row] as readonly number[]
    const at = Math.max(0, cols.indexOf(pos.col))
    const col = cols[Math.min(Math.max(at + dCol, 0), cols.length - 1)] as number
    return { row: pos.row, col, want: col }
}

// ========================================================================================
// 3. FieldForm
// ========================================================================================

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
type FieldFormEdit = {
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
 * @property border - the lines of a grid: `"single"` (default) or `"double"` (blocky).
 */
type FieldFormProps = {
    rows:     readonly FormRow[]
    pos:      CellPos
    problem?: { row: number; message: string }
    edit?:    FieldFormEdit
    border?:  LineStyle
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
    border:     LineStyle
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
                        {grid ? <Bar style={m.border} /> : null}
                        {grid ? " " : null}
                        <Text
                            bold={here}
                            color={here ? theme.bg : color}
                            backgroundColor={here ? color : undefined}
                        >
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
    const { rows, pos, problem, edit, border = "single" } = props
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
        border,
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
                                        <Bar style={m.border} />
                                        {` ${inColumn(h, c, m)} `}
                                    </Fragment>
                                ))}
                            </Text>
                            <Rule
                                style={m.border}
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

// ========================================================================================
// 4. useFormScreen
// ========================================================================================

/**
 * What a form screen knows about its own cells; the hook asks for it when a key needs
 * it. Every function sees the current state of the screen (a new spec is made on every
 * render), so none of them keeps anything.
 *
 * @property valid - for each row of the form, the columns that have a cell.
 * @property editLabel - the label of the prompt for a cell, e.g. `"name:"`.
 * @property editText - the text the prompt starts from.
 * @property take - takes the text typed for a cell into the screen's state; returns an
 *     `error` (the cell then stays open, the error under the field) or, when the text
 *     was taken, a `note` for the frame.
 * @property restore - puts a cell back to what it was when the form opened.
 * @property check - the first thing wrong with the form: where and what; `undefined`
 *     when it can be accepted.
 * @property canRestore - whether `^u` has anything to put back on a cell (the cell differs
 *     from what it was when the form opened); `true` for every cell when left out.
 * @property accept - the form is complete: hand it back and leave.
 * @property cancel - leave and change nothing.
 */
export type FormScreenSpec = {
    valid:     readonly (readonly number[])[]
    editLabel: (pos: CellPos) => string
    editText:  (pos: CellPos) => string
    take:      (pos: CellPos, text: string) => { error?: string; note?: string }
    restore:   (pos: CellPos) => void
    canRestore?: (pos: CellPos) => boolean
    check:     () => { pos: CellPos; message: string } | undefined
    accept:    () => void
    cancel:    () => void
}

/**
 * What the hook gives the screen to draw.
 *
 * @property pos - the cell the cursor is on.
 * @property edit - the prompt, while a cell is being typed into (for `FieldForm`).
 * @property problem - the row to flag after `^w` found a problem (for `FieldForm`).
 * @property note - the line for the `Frame`: what `^w` found, or what taking a cell said.
 * @property noteIsError - draw the note in the error colour (always true now).
 * @property moves - which arrows move the cursor from `pos` (a neighbouring cell exists
 *     in that direction), for the legend.
 * @property canRestore - `^u` has something to put back on the cell under the cursor.
 * @property complete - `spec.check` finds nothing: `^w` would accept the form.
 */
export type FormScreen = {
    pos:         CellPos
    edit:        FieldFormEdit | undefined
    problem:     { row: number; message: string } | undefined
    note:        string | undefined
    noteIsError: boolean
    moves:       Moves
    canRestore:  boolean
    complete:    boolean
}

/**
 * The keys and state every form page has: up, down, left and right move the cursor over
 * the cells, Enter opens a prompt on the cell and takes what is typed (a mistake keeps it
 * open with a message), `^u` restores the cell, `^w` accepts the form only if
 * `spec.check` finds nothing (else the problem is the note, flagged on its row, and the
 * cursor goes there) and Esc or Ctrl-X cancel. While the prompt is open it takes the
 * keys, Esc closing just the prompt. The form page decides what the cells mean (the
 * spec) and draws them (`FieldForm`, `Frame`).
 *
 * @param spec - what the screen knows about its cells.
 * @returns what to draw.
 */
export function useFormScreen(spec: FormScreenSpec): FormScreen {
    const [pos, setPos] = useState<CellPos>(() => placeAt(0, spec.valid[0]?.[0] ?? 0))
    const [editing, setEditing] = useState(false)
    const [editError, setEditError] = useState<string | undefined>(undefined)
    const [note, setNote] = useState<string | undefined>(undefined)
    const [problem, setProblem] = useState<FormScreen["problem"]>(undefined)

    // stable, so that the prompt's own effect does not clear a fresh error at once
    const onChange = useCallback(() => setEditError(undefined), [])
    const closePrompt = useCallback(() => {
        setEditing(false)
        setEditError(undefined)
    }, [])

    useKeys((press) => {
        setNote(undefined)
        setProblem(undefined)
        const arrows = [
            [keys.up, -1, 0],
            [keys.down, 1, 0],
            [keys.left, 0, -1],
            [keys.right, 0, 1],
        ] as const
        const move = arrows.find(([key]) => press.is(key))
        if (move) setPos(moveCell(spec.valid, pos, move[1], move[2]))
        else if (press.is(keys.enter)) setEditing(true)
        else if (press.is(keys.undo)) spec.restore(pos)
        else if (press.is(keys.save)) {
            const found = spec.check()
            if (!found) return spec.accept()
            setPos(placeAt(found.pos.row, found.pos.col))
            setProblem({ row: found.pos.row, message: found.message })
            setNote(found.message)
        } else if (press.is(keys.escape) || press.is(keys.back)) spec.cancel()
    }, !editing)

    const editOf = (): FieldFormEdit => ({
        label: spec.editLabel(pos),
        initial: spec.editText(pos),
        error: editError,
        onChange,
        onCancel: closePrompt,
        onSubmit: (text) => {
            const result = spec.take(pos, text)
            if (result.error) return setEditError(result.error)
            closePrompt()
            setNote(result.note)
        },
    })
    const edit: FieldFormEdit | undefined = editing ? editOf() : undefined
    const moves: Moves = {
        up: moveCell(spec.valid, pos, -1, 0).row !== pos.row,
        down: moveCell(spec.valid, pos, 1, 0).row !== pos.row,
        left: moveCell(spec.valid, pos, 0, -1).col !== pos.col,
        right: moveCell(spec.valid, pos, 0, 1).col !== pos.col,
    }
    return {
        pos,
        edit,
        problem,
        note,
        noteIsError: true,
        moves,
        canRestore: spec.canRestore?.(pos) ?? true,
        complete: spec.check() === undefined,
    }
}
