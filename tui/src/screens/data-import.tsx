// SPDX-License-Identifier: LGPL-3.0-or-later

// The import screen that reads a table file into a curve: the project's measured curve,
// or (the reference mode) a reference curve for the comparison. The options of a table
// file on the left, a live preview on the right.

import { basename } from "node:path"
import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { numberText, parseNumber, shortNumber, truncate } from "../core/terminal.js"
import {
    type DataMapping,
    DEFAULT_UNITS,
    dataErrorNote,
    makeMapping,
    readDataInfo,
    unitLabel,
    writeData,
} from "../store/data.js"
import { measuredPoints, referenceWarning, sigmaWarning } from "../store/data-checks.js"
import {
    DataFileError,
    type DataPoints,
    DEFAULT_PARSE_OPTIONS,
    extractCurve,
    guessColumns,
    headerModes,
    IMPORT_TUNABLES,
    isNoSigma,
    NO_SIGMA,
    type ParseOptions,
    parseTable,
    type Role,
    resolveColumn,
    resolveColumns,
    resolveReferenceColumns,
    roleLabel,
    roles,
    rowsOf,
    type Source,
    separatorPresets,
    separatorProblem,
    sheetNames,
    suggestColumns,
    type Table,
    type TableRow,
} from "../store/data-table.js"
import type { ProjectRef } from "../store/projects.js"
import { addReference, referenceUnits } from "../store/references.js"
import { Frame } from "../ui/frame.js"
import {
    cursorMoves,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import { Entry, Prompt, type Suggestion, useNote } from "../ui/input.js"
import {
    CursorList,
    type KeyInput,
    keys,
    ListText,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useListCursor,
    useNav,
} from "../ui/interaction.js"
import { type Column, DataTable, Panel, useTheme } from "../ui/theme.js"

/** A row of the options panel: a parse option or one of the three columns. */
type Field = "separator" | "sheet" | "comments" | "skip" | "header" | Role

/** What each field is called, the width of its label column is [[LABEL_WIDTH]]. */
const fieldLabel: Record<Field, string> = {
    separator: "separator",
    sheet: "sheet",
    comments: "comments",
    skip: "skip rows",
    header: "header",
    q: roleLabel.q,
    i: roleLabel.i,
    sigma: roleLabel.sigma,
}

/** The column of the model's intensity in a depositor's fit file (q, I, model, error). */
const REFERENCE_MODEL_COLUMN = 3

/** @returns a preview cell with a number rounded to five digits, a text cell as it is. */
function roundedCell(text: string): string {
    const x = numberText(text.trim())
    return x === undefined ? text : shortNumber(x)
}

/** The width of the label column of the options panel. */
const LABEL_WIDTH = 10

/** The rows the prompt under the panels may need (field, three suggestions, status). */
const PROMPT_ROWS = 5

/** The rows of the preview panel that are not data: header, its rule, the border. */
const PREVIEW_FRAME_ROWS = 4

/** The narrowest a data column of the preview is drawn. */
const MIN_PREVIEW_CELL = 8

/** The width of the options panel as a share of the body, with its least and most. */
const OPTIONS_SHARE = 0.35
const OPTIONS_MIN = 34
const OPTIONS_MAX = 48

/** The cells a preview table spends per column on its separators, and in front. */
const TABLE_GUTTER = 3
const TABLE_COLUMN_GAP = 3

/** @returns the text of a column that does not resolve, in the error colour. */
const problemText = (spec: string, problem: string): string =>
    spec === "" ? problem : `${spec}: ${problem}`

/** @returns whether a field is one of the three columns. */
const isRole = (f: Field | undefined): f is Role => f === "q" || f === "i" || f === "sigma"

/**
 * The next (or previous) value of a list, going round.
 *
 * @param list - the values.
 * @param current - the value now.
 * @param step - 1 or -1.
 * @returns the neighbour.
 */
function cycle<T>(list: readonly T[], current: T, step: number): T {
    const at = list.indexOf(current)
    return list[(at + step + list.length) % list.length] as T
}

/**
 * The warning for the curve the chosen columns of a table give, `undefined` for none (or
 * for columns that give no curve: the import says why when it is tried).
 *
 * @param table - the whole table.
 * @param specs - the columns as typed or guessed.
 * @param reference - whether it is a reference fit (checked against `measured`) or the
 *     measured curve (its sigma is checked).
 * @param measured - the project's measured curve, for a reference.
 */
function curveWarning(
    table: Table,
    specs: Record<Role, string>,
    reference: boolean,
    measured: DataPoints | undefined,
): string | undefined {
    try {
        if (reference)
            return referenceWarning(
                extractCurve(table, resolveReferenceColumns(specs, table.names)),
                measured,
            )
        const columns = resolveColumns(specs, table.names)
        return sigmaWarning(
            extractCurve(table, {
                q: columns.q.column,
                i: columns.i.column,
                sigma: columns.sigma.column,
            }),
        )
    } catch {
        return undefined
    }
}

/**
 * The columns of the preview to draw: those the three roles are on first, then the
 * first others, in the order of the file.
 *
 * @param count - how many columns the table has.
 * @param chosen - the columns (counting from 1) the roles resolve to.
 * @param room - how many fit.
 * @returns the indices (from 0), ascending.
 */
function visibleColumns(count: number, chosen: number[], room: number): number[] {
    const picked = new Set(
        [...new Set(chosen)]
            .map((c) => c - 1)
            .filter((c) => c >= 0 && c < count)
            .sort((a, b) => a - b)
            .slice(0, room),
    )
    for (let k = 0; k < count && picked.size < room; k++) picked.add(k)
    return [...picked].sort((a, b) => a - b)
}

/**
 * The import of a data file, the second half of the `data` screen: the options of how
 * the file is read (separator, comment lines, rows to skip, header) and the three columns
 * (q, I(q), sigma) on the left, a live preview of the first rows of the parsed table on
 * the right. The columns start as a guess from the names and the order; Enter on a row
 * changes it (an option cycles, the rows to skip and the columns open a prompt; left and
 * right change an option too), `^w` imports. A row that gives no number in a chosen
 * column stops the import with a message that names the line and the column, and
 * nothing is written; the message stays until the next key.
 * The legend keeps to four keys in every mode, so at 80 columns the footer stays one row of
 * boxes high.
 *
 * @param props.project - the project.
 * @param props.path - the source file.
 * @param props.source - its content, already read.
 * @param props.initial - the stored mapping, to start from the choices of an earlier
 *     import.
 * @param props.reference - the reference mode: the curve is added to the project's
 *     `reference-fit/` instead of replacing its data; sigma may be `none`, the units are
 *     the project's (shown in the subtitle), and the stored mapping is not used.
 * @param props.onDone - called with the number of points, of rows dropped for a q (or
 *     sigma) not above 0, for a reference the name it got, and a warning about the curve
 *     (a wrong file or columns, see `store/data-checks.ts`) or `undefined`, after a
 *     successful import (a warning never stops it).
 * @returns the screen.
 */
export function DataImportScreen(props: {
    project: ProjectRef
    path: string
    source: Source
    initial?: DataMapping
    reference?: boolean
    onDone: (points: number, dropped: number, name?: string, warning?: string) => void
}): ReactNode {
    const { project, path, source, initial, reference = false, onDone } = props
    const nav = useNav()
    const theme = useTheme()
    const assets = IMPORT_TUNABLES
    const [options, setOptions] = useState<ParseOptions>(
        initial
            ? {
                separator: initial.separator,
                sheet: initial.sheet,
                skipRows: initial.skipRows,
                comments: initial.comments,
                header: initial.header,
            }
            : DEFAULT_PARSE_OPTIONS,
    )
    // what the user typed for a role; a role never touched follows the guess
    const [typed, setTyped] = useState<Partial<Record<Role, string>>>(
        initial
            ? {
                q: initial.columns.q.spec,
                i: initial.columns.i.spec,
                sigma: initial.columns.sigma.spec,
            }
            : {},
    )
    const [edit, setEdit] = useState<Field | undefined>()
    const { note, say, clear } = useNote()
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])

    const sheets = sheetNames(source)
    const fields: Field[] = [
        ...(source.kind === "text" ? (["separator"] as const) : []),
        ...(sheets.length > 1 ? (["sheet"] as const) : []),
        "comments",
        "skip",
        "header",
        ...roles,
    ]
    const cursor = useListCursor(fields.length, fields.length)
    const field = fields[cursor.index] as Field

    const table = useMemo(
        () => parseTable(source, options, assets.previewRows),
        [source, options],
    )
    const rowCount = rowsOf(source, options.sheet).length
    const guess = useMemo(() => guessColumns(table.names, table.header), [table])
    // a reference fit starts as the files of the fits come: q first, the model's
    // intensity in column 3 (a table of two columns has it in column 2) and no sigma
    const referenceGuess: Record<Role, string> = {
        q: "col:1",
        i:
            table.names.length >= REFERENCE_MODEL_COLUMN
                ? `col:${REFERENCE_MODEL_COLUMN}`
                : "col:2",
        sigma: NO_SIGMA,
    }
    const start = reference ? referenceGuess : guess
    const specs: Record<Role, string> = {
        q: typed.q ?? start.q,
        i: typed.i ?? start.i,
        sigma: typed.sigma ?? start.sigma,
    }
    // a reference has the units of the project's data (read once, when the screen opens)
    const units = useMemo(() => {
        try {
            return reference ? unitLabel(referenceUnits(project.dir)) : undefined
        } catch {
            return undefined
        }
    }, [reference, project.dir])

    // the measured curve a reference is held against, read once
    const measured = useMemo(
        () => (reference ? measuredPoints(project.dir) : undefined),
        [reference, project.dir],
    )
    // what is wrong with the curve the columns give now (the whole file is read again
    // only when the options or the columns change)
    const { q: specQ, i: specI, sigma: specSigma } = specs
    const warning = useMemo(
        () =>
            curveWarning(
                parseTable(source, options),
                { q: specQ, i: specI, sigma: specSigma },
                reference,
                measured,
            ),
        [source, options, specQ, specI, specSigma, reference, measured],
    )

    /** Changes the option or column row by a step, when it can be stepped. */
    const step = (f: Field, by: number) => {
        if (f === "separator")
            setOptions((o) => ({
                ...o,
                separator: cycle(separatorPresets, o.separator, by),
            }))
        else if (f === "sheet")
            setOptions((o) => ({ ...o, sheet: cycle(sheets, table.sheet, by) }))
        else if (f === "comments") setOptions((o) => ({ ...o, comments: !o.comments }))
        else if (f === "header")
            setOptions((o) => ({ ...o, header: cycle(headerModes, o.header, by) }))
        else if (f === "skip")
            setOptions((o) => ({
                ...o,
                skipRows: Math.min(rowCount, Math.max(0, o.skipRows + by)),
            }))
    }

    /** Reads the whole file with the choices and writes the project's data. */
    const importNow = () => {
        try {
            if (reference) {
                const full = parseTable(source, options)
                const data = extractCurve(full, resolveReferenceColumns(specs, full.names))
                const name = addReference(project.dir, data, path)
                onDone(data.q.length, data.dropped, name, warning)
                nav.pop()
                return
            }
            const current = readDataInfo(project.dir)
            if (current?.kind === "unusable")
                throw new DataFileError("data files are unusable: reset them first")
            const keep = current?.kind === "ok" ? current.info : undefined
            const full = parseTable(source, options)
            const columns = resolveColumns(specs, full.names)
            const data = extractCurve(full, {
                q: columns.q.column,
                i: columns.i.column,
                sigma: columns.sigma.column,
            })
            writeData(
                project.dir,
                data,
                path,
                keep?.units ?? DEFAULT_UNITS,
                keep?.energy ?? undefined,
                makeMapping(path, options, columns),
                keep?.energy_unit,
            )
            onDone(data.q.length, data.dropped, undefined, warning)
            nav.pop()
        } catch (error) {
            say(dataErrorNote(error), true)
        }
    }

    // the form: move, change, edit, import, back (an error stays until the next key)
    useKeys((press: KeyInput) => {
        clear()
        // Shift+Tab is tested first: a plain `keys.tab` matches either press
        if (press.is(keys.up) || press.is(keys.shiftTab)) cursor.move(-1)
        else if (press.is(keys.down) || press.is(keys.tab)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.save)) importNow()
        else if (press.is(keys.left)) step(field, -1)
        else if (press.is(keys.right)) step(field, 1)
        else if (press.is(keys.enter)) {
            if (field === "skip" || field === "separator" || isRole(field)) setEdit(field)
            else step(field, 1)
        }
    }, edit === undefined)

    const submitSeparator = (text: string) => {
        const problem = separatorProblem(text)
        if (problem !== undefined) return say(problem, true)
        setOptions((o) => ({ ...o, separator: text }))
        closeEdit()
    }

    const closeEdit = () => setEdit(undefined)
    const suggest = useCallback((text: string) => suggestColumns(table, text), [table])

    const submitSkip = (text: string) => {
        const parsed = parseNumber(text, { whole: true })
        if ("error" in parsed) return say("a whole number, please", true)
        if (parsed.value > rowCount) return say(`the file has ${rowCount} rows`, true)
        setOptions((o) => ({ ...o, skipRows: parsed.value }))
        closeEdit()
    }

    const submitColumn = (role: Role, text: string, suggestion?: Suggestion) => {
        if (reference && role === "sigma" && isNoSigma(text)) {
            setTyped((t) => ({ ...t, sigma: NO_SIGMA }))
            return closeEdit()
        }
        // what is typed when it names a column; else the highlighted suggestion
        const found = resolveColumn(text, table.names)
        if ("error" in found && suggestion === undefined)
            return say(`${roleLabel[role]}: ${found.error}`, true)
        const spec = "error" in found ? (suggestion?.label ?? "") : text.trim()
        setTyped((t) => ({ ...t, [role]: spec }))
        closeEdit()
    }

    // ---- the options panel
    const bodyColumns = useBodyColumns()
    const optionsWidth = Math.min(
        OPTIONS_MAX,
        Math.max(OPTIONS_MIN, Math.floor(bodyColumns * OPTIONS_SHARE)),
    )
    const valueText = (f: Field): ReactNode => {
        if (f === "separator")
            return options.separator === "auto"
                ? `auto (${table.separator})`
                : options.separator
        if (f === "sheet")
            return `${table.sheet} (${sheets.indexOf(table.sheet) + 1}/${sheets.length})`
        if (f === "comments") return options.comments ? "on" : "off"
        if (f === "skip") return String(options.skipRows)
        if (f === "header")
            return options.header === "auto"
                ? `auto (${table.header ? "yes" : "no"})`
                : options.header
        if (reference && f === "sigma" && isNoSigma(specs[f]))
            return <Text color={theme.mt}>{NO_SIGMA}</Text>
        const found = resolveColumn(specs[f], table.names)
        if ("error" in found)
            return <Text color={theme.er}>{problemText(specs[f], found.error)}</Text>
        const name = table.names[found.column - 1] as string
        return (
            <>
                {name}
                {name.startsWith("col:") ? null : (
                    <Text color={theme.mt}>{` col:${found.column}`}</Text>
                )}
            </>
        )
    }

    // ---- the preview: the columns that fit, the chosen ones first
    const previewWidth = bodyColumns - optionsWidth - 1 - 4
    const shownRows: TableRow[] = table.rows.slice(0, assets.previewRows)
    const lineWidth = Math.max(4, ...shownRows.map((r) => String(r.line).length))
    // at least the three columns of the curve are shown, however narrow the terminal
    const fit = Math.floor(
        (previewWidth - TABLE_GUTTER - TABLE_COLUMN_GAP - lineWidth) /
            (MIN_PREVIEW_CELL + TABLE_COLUMN_GAP),
    )
    const chosen = roles.flatMap((r) => {
        const found = resolveColumn(specs[r], table.names)
        return "column" in found ? [found.column] : []
    })
    const visible = visibleColumns(table.names.length, chosen, Math.max(roles.length, fit))
    const hidden = table.names.length - visible.length
    const columns: Column<TableRow>[] = [
        { title: "line", width: lineWidth, align: "right", text: (r) => String(r.line) },
        ...visible.map((k) => ({
            title: table.names[k] as string,
            text: (r: TableRow) =>
                reference ? roundedCell(r.cells[k] ?? "") : (r.cells[k] ?? ""),
        })),
    ]
    const bodyRows = useBodyRows(PROMPT_ROWS + PREVIEW_FRAME_ROWS)
    const pageSize = Math.min(assets.previewRows, bodyRows) - (hidden > 0 ? 1 : 0)

    // ---- the keys that work now
    const stepping = !isRole(field)
    const legend: LegendItem[] =
        edit === undefined
            ? legendOf([
                legendFor(reference ? "add" : "import", keys.save),
                stepping
                    ? legendFor("change", keys.enter, [keys.left, keys.right])
                    : legendFor("edit", keys.enter),
                moveLegend({ ...cursorMoves(cursor.index, fields.length), tab: true }),
                legendBack,
            ])
            : promptKeys

    return (
        <Frame
            title={reference ? "reference fit" : "data"}
            subtitle={`${project.id} · ${truncate(basename(path), 30)}${
                units === undefined ? "" : ` · ${units}`
            }`}
            legend={legend}
            note={note?.text ?? warning}
            noteIsError={note?.error}
        >
            <Box columnGap={1}>
                <Panel width={optionsWidth} paddingX={1} flexDirection="column">
                    <CursorList
                        items={fields}
                        index={cursor.index}
                        offset={cursor.offset}
                        lines={fields.length}
                        active={edit === undefined}
                        row={(f, on) => (
                            <Box>
                                <ListText on={on}>
                                    {fieldLabel[f].padEnd(LABEL_WIDTH)}
                                </ListText>
                                <Text color={on ? theme.fg : theme.mt} wrap="truncate-end">
                                    {valueText(f)}
                                </Text>
                            </Box>
                        )}
                    />
                </Panel>
                <Panel flexGrow={1} paddingX={1} flexDirection="column">
                    <DataTable
                        columns={columns}
                        rows={shownRows.slice(0, Math.max(1, pageSize))}
                        cursor={-1}
                        offset={0}
                        pageSize={Math.max(1, pageSize)}
                        empty="no rows: check the options"
                        width={previewWidth}
                    />
                    {hidden > 0 ? (
                        <Text color={theme.mt}>{`+ ${hidden} more columns`}</Text>
                    ) : null}
                </Panel>
            </Box>
            {edit === "separator" ? (
                <Prompt
                    label="separator:"
                    initial={options.separator}
                    maxLength={12}
                    placeholder="auto, tab, comma, ;, |, ~, space, or any characters"
                    onSubmit={submitSeparator}
                    onCancel={closeEdit}
                    onChange={clear}
                    take="set"
                    cancel="close"
                    onLegend={setPromptKeys}
                />
            ) : null}
            {edit === "skip" ? (
                <Prompt
                    label="skip rows:"
                    initial={String(options.skipRows)}
                    maxLength={6}
                    onSubmit={submitSkip}
                    onCancel={closeEdit}
                    onChange={clear}
                    take="set"
                    cancel="close"
                    onLegend={setPromptKeys}
                />
            ) : null}
            {isRole(edit) ? (
                <Entry
                    label={`${roleLabel[edit]} column:`}
                    initial={reference && edit === "sigma" ? specs.sigma : specs[edit]}
                    maxLength={40}
                    placeholder={
                        reference && edit === "sigma"
                            ? `a number, col:N, a header name or ${NO_SIGMA}`
                            : "a number, col:N or a header name"
                    }
                    suggest={suggest}
                    lines={3}
                    noMatch="no such column"
                    onSubmit={(text, suggestion) => submitColumn(edit, text, suggestion)}
                    onCancel={closeEdit}
                    onChange={clear}
                    take="set"
                    cancel="close"
                    onLegend={setPromptKeys}
                />
            ) : null}
        </Frame>
    )
}
