// SPDX-License-Identifier: LGPL-3.0-or-later

// The file viewer of the logs (a workbook or a delimited file, with its plots text behind
// `^p`), its legends, and `open runs`, the screen of the project menu that leads to it
// (with the pager of a run's `run.LOG`).
//
// Contents:
//   1. The viewer legend: the sheet legend and the rows its fullest legend needs
//   2. `SheetViewerScreen`: the read-only viewer of a workbook, a table file or plots
//   3. `OpenRuns`: the runs of a project and the viewer on a done model

import { readFileSync, statSync } from "node:fs"
import { basename } from "node:path"
import { Box, Text, useWindowSize } from "ink"
import { Fragment, type ReactNode, useCallback, useEffect, useMemo, useState } from "react"
import { LOGS_FLOW } from "../core/environment.js"
import { isFolder } from "../core/file-system.js"
import { displayWidth, padWidth, truncate } from "../core/terminal.js"
import { liveRun, type ProjectRef, runDisplay } from "../store/projects.js"
import {
    deleteRun,
    listOpenRuns,
    type OpenModel,
    type OpenRow,
    type OpenRun,
    openRows,
    type PlotFile,
    RUN_GONE,
    readLogText,
} from "../store/run-logs.js"
import {
    cellRef,
    clampTop,
    columnLabel,
    firstShown,
    fitCount,
    lastTop,
    looksNumeric,
    openWorkbook,
    type Plot,
    pagerLines,
    pagerStatus,
    pageTop,
    pickPlotFile,
    plotWidth,
    type Sheet,
    sliceCells,
    splitPlots,
    VIEWER_LIMITS,
    ViewerFileError,
    type Workbook,
} from "../store/view.js"
import { cornerLabel, Frame, footerExtraLines } from "../ui/frame.js"
import {
    type Design,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import { destructiveQuestion, questionLegend, useConfirm } from "../ui/input.js"
import {
    CursorList,
    clampWindow,
    type KeyInput,
    keys,
    ListText,
    scrollWindow,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { Bar, linesOf, Panel, Rule, useTheme } from "../ui/theme.js"

// ========================================================================================
// 1. The file viewer
// ========================================================================================

/** The lines the viewer's frame is laid out for: one band, a column of three. */
const BASE_LEGEND_LINES = 3

/**
 * The keys the viewer's footer must have room for, so the footer does not change height
 * while the user works: everything its sheets mode can show for this workbook at once.
 *
 * @param base - what the workbook has: how many tabs, a plots file.
 * @returns the items.
 */
function viewerFullLegend(base: { hasPlots: boolean }): LegendItem[] {
    const all = { up: true, down: true, left: true, right: true }
    return viewerLegend({
        ...base,
        plots: true,
        sheets: 3,
        active: 1,
        move: all,
        zoom: { in: true, out: true },
    })
}

/**
 * The rows a footer with these keys takes beyond the ones its frame is laid out for. The
 * keys go in as many bands as the width needs (never cut), so a narrow terminal has a
 * taller footer; the grid gives those rows up.
 *
 * @param items - the legend (the fullest, or the one shown).
 * @param columns - the width of the body (`useBodyColumns`).
 * @param design - the page's design: a blocky footer's box adds its two rows.
 * @returns the rows, 0 when the keys fit one band (smooth).
 */
function legendExtraRows(
    items: readonly LegendItem[],
    columns: number,
    design: Design,
): number {
    return footerExtraLines(items, columns, BASE_LEGEND_LINES, design)
}

/**
 * What the viewer's legend depends on.
 *
 * @property plots - the plots mode is on.
 * @property sheets - how many tabs there are.
 * @property active - the tab shown (0-based): previous exists from the second on, next
 *     until the last.
 * @property hasPlots - a plots file is there (the `^p` key works).
 * @property move - which arrows can move now (an edge has none past it).
 * @property zoom - whether a larger (`in`) or smaller (`out`) plot size exists.
 */
export type ViewerFacts = {
    plots: boolean
    sheets: number
    active: number
    hasPlots: boolean
    move: { up: boolean; down: boolean; left: boolean; right: boolean }
    zoom: { in: boolean; out: boolean }
}

/**
 * The keys of the viewer that work now, back last.
 *
 * @param facts - the state.
 * @returns the items (the frame lays them out in as many bands as the width needs).
 */
export function viewerLegend(facts: ViewerFacts): LegendItem[] {
    const what = facts.plots ? "plot" : "sheet"
    const next = facts.active < facts.sheets - 1 && legendFor(`next ${what}`, keys.tab)
    const prev = facts.active > 0 && legendFor(`prev ${what}`, keys.shiftTab)
    const move = moveLegend(facts.move)
    const zoom = facts.plots
        ? [
            facts.zoom.in && legendFor("zoom in", keys.zoomIn),
            facts.zoom.out && legendFor("zoom out", keys.zoomOut),
        ]
        : []
    return legendOf([
        next,
        prev,
        move,
        ...zoom,
        facts.hasPlots && legendFor(facts.plots ? "sheets" : "plots", keys.plots),
        legendBack,
    ])
}

// ========================================================================================
// 2. The file viewer
// ========================================================================================

/**
 * The rows the frame and the app keep: title and the gap under it, the footer (a note
 * row, the three rows of the logo and the keys), the theme line. The panel takes all that
 * is left, so the grid uses every row (`useBodyRows` keeps more, for screens whose footer
 * may grow).
 */
const FRAME_ROWS = 7

/** The rows inside the panel that are not data: tabs line and the borders, status line. */
const TABS_AND_STATUS_ROWS = 4

/** The rows of a sheet's letters line and its rule; a frozen header adds the same. */
const LETTER_ROWS = 2
const HEADER_ROWS = 2

/** The cells a column costs beyond its text (a space each side and the bar), a tab's. */
const COLUMN_EXTRA = 3
const TAB_EXTRA = 3

/** How many cells a sideways step moves a plot. */
const PLOT_STEP = 4

/** The cursor, and the first row and column shown, of one sheet. */
type Pos = { row: number; column: number; top: number; left: number }

/** Where a plot is scrolled to. */
type PlotPos = { top: number; left: number }

/** The plots file read: its plots, or none (missing, unreadable, empty, no plot in it). */
function readPlots(path: string | undefined): Plot[] {
    if (path === undefined || path === "") return []
    try {
        if (statSync(path).size > VIEWER_LIMITS.maxBytes) return []
        return splitPlots(readFileSync(path, "utf-8"))
    } catch {
        return []
    }
}

/**
 * The tab bar: one tab per name, the active one inverted, a `‹` or `›` where tabs are
 * out of reach. Only draws.
 *
 * @param props.names - the tabs.
 * @param props.active - the active tab.
 * @param props.first - the first tab shown.
 * @param props.count - how many are shown.
 * @returns the line.
 */
function TabBar(props: {
    names: string[]
    active: number
    first: number
    count: number
}): ReactNode {
    const { names, active, first, count } = props
    const theme = useTheme()
    const max = VIEWER_LIMITS.maxTabName
    const shown = names.slice(first, first + count)
    return (
        <Box columnGap={1}>
            <Text color={theme.mt}>{first > 0 ? "‹" : " "}</Text>
            {shown.map((name, i) => {
                const on = first + i === active
                return (
                    <Text
                        // biome-ignore lint/suspicious/noArrayIndexKey: a tab is its place
                        key={first + i}
                        bold={on}
                        color={on ? theme.bg : theme.mt}
                        backgroundColor={on ? theme.fg : undefined}
                    >
                        {` ${truncate(name, max)} `}
                    </Text>
                )
            })}
            <Text color={theme.mt}>{first + count < names.length ? "›" : " "}</Text>
        </Box>
    )
}

/**
 * The read-only file viewer: a tabbed frame with two modes over the same tabs. The
 * workbook mode has one tab per sheet of a workbook (a delimited file is one tab) and a
 * scrollable grid (cursor cell, widths fitted to the text, the first row kept in view
 * when it is a header). The plots mode (`^p`) has one tab per terminal plot of a plots
 * file, painted in the theme's colours and scrolled when bigger than the panel. Nothing
 * is ever written: no edit key exists and the file is only read.
 *
 * @param props.workbookPath - the workbook or delimited file.
 * @param props.plotsPath - the plots text file; without it (or with no plot in it) `^p`
 *     is not offered and says `no plots`.
 * @param props.plotFiles - the same plots written at several sizes (width, rows of the
 *     tallest plot): the largest that fits the panel is shown and picked again when the
 *     window changes, the plot tab kept; `plotsPath` is the fallback (and for a caller
 *     with no sizes the only file).
 * @param props.title - the title of the screen, `view` when left out.
 * @param props.design - `"blocky"` (the logs pages) or `"smooth"` (`open runs`, default).
 * @param props.corner - the text at the top right of the title row; none when left out.
 * @returns the screen.
 */
function SheetViewerScreen(props: {
    workbookPath: string
    plotsPath?: string
    plotFiles?: PlotFile[]
    title?: string
    subtitle?: string
    corner?: string
    design?: Design
}): ReactNode {
    const { workbookPath, plotsPath, plotFiles = [], title = "view", corner } = props
    const { subtitle: subtitleProp } = props
    const { design = "smooth" } = props
    const border = linesOf(design)
    const panel = design === "blocky" ? "double" : "round"
    const nav = useNav()
    const theme = useTheme()
    const columnsAvailable = useBodyColumns()
    const limits = VIEWER_LIMITS

    // ---- what is read (once)
    const opened = useMemo((): { book: Workbook } | { error: string } => {
        try {
            return { book: openWorkbook(workbookPath, basename(workbookPath)) }
        } catch (error) {
            return {
                error:
                    error instanceof ViewerFileError
                        ? error.message
                        : "cannot read that file",
            }
        }
    }, [workbookPath])
    // the plots come at several sizes: the largest file that fits the panel is read, and
    // another one when the window changes (the tabs are the same in every size)
    const { rows: terminalRows } = useWindowSize()
    const innerWidth = columnsAvailable - 4
    // a plot is drawn right up to the panel's border (no padding), so a plot as wide as
    // the 80-column window less its margins and borders fits
    const plotRoom = columnsAvailable - 2
    const pickRows = Math.max(
        1,
        terminalRows -
            FRAME_ROWS -
            legendExtraRows(
                viewerFullLegend({ hasPlots: true }),
                columnsAvailable,
                design,
            ) -
            TABS_AND_STATUS_ROWS,
    )
    // `+` and `-` pick another size of the plots than the automatic one; the files go
    // from the smallest to the largest by area
    const [zoom, setZoom] = useState<number | undefined>()
    const bySize = plotFiles
        .map((_, i) => i)
        .sort(
            (a, b) =>
                (plotFiles[a]?.width ?? 0) * (plotFiles[a]?.rows ?? 0) -
                (plotFiles[b]?.width ?? 0) * (plotFiles[b]?.rows ?? 0),
        )
    const autoAt = pickPlotFile(plotFiles, plotRoom, pickRows)
    const pickedAt = zoom !== undefined && zoom < plotFiles.length ? zoom : autoAt
    const sizeAt = pickedAt === undefined ? -1 : bySize.indexOf(pickedAt)
    /** Steps to the next larger (1) or smaller (-1) plot size; `false` at the end. */
    const zoomTo = (dir: 1 | -1): boolean => {
        const next = bySize[sizeAt + dir]
        if (sizeAt < 0 || next === undefined) return false
        setZoom(next)
        return true
    }
    const picked = pickedAt === undefined ? undefined : plotFiles[pickedAt]
    const pickedPath = picked?.path
    const plots = useMemo(() => {
        const sized = readPlots(pickedPath)
        return sized.length > 0 || pickedPath === undefined ? sized : readPlots(plotsPath)
    }, [pickedPath, plotsPath])

    // ---- state
    const [mode, setMode] = useState<"sheets" | "plots">("sheets")
    const [tab, setTab] = useState(0)
    const [plotTab, setPlotTab] = useState(0)
    const [tabFirst, setTabFirst] = useState(0)
    const [positions, setPositions] = useState<Record<number, Pos>>({})
    const [plotPositions, setPlotPositions] = useState<Record<number, PlotPos>>({})
    const [note, setNote] = useState<{ text: string; error: boolean } | undefined>()
    const say = (text: string, error = false) => setNote({ text, error })

    const book = "book" in opened ? opened.book : undefined
    const names = mode === "plots" ? plots.map((p) => p.title) : (book?.names ?? [])
    const active = mode === "plots" ? plotTab : tab

    // the sheet is parsed when its tab is first shown; a failure is a note, not a crash
    const loaded = useMemo((): { sheet: Sheet } | { error: string } | undefined => {
        if (book === undefined) return undefined
        try {
            return { sheet: book.sheet(tab) }
        } catch {
            return { error: "cannot read that sheet" }
        }
    }, [book, tab])
    const sheet = loaded !== undefined && "sheet" in loaded ? loaded.sheet : undefined

    const cursor: Pos = positions[tab] ?? { row: 0, column: 0, top: 0, left: 0 }

    // ---- the legend: the keys that work now, in as many bands as the width needs; the
    // footer reserves the height of the fullest one (`legendFull`), so it never moves
    const fullLegend = viewerFullLegend({ hasPlots: plots.length > 0 })
    const footerExtra = legendExtraRows(fullLegend, columnsAvailable, design)

    // ---- layout
    const framed = sheet?.header ? HEADER_ROWS : 0
    const pageRows = Math.max(
        1,
        terminalRows -
            FRAME_ROWS -
            footerExtra -
            TABS_AND_STATUS_ROWS -
            (mode === "plots" ? 0 : LETTER_ROWS + framed),
    )
    const rowWidth = String(sheet?.rows ?? 1).length
    const gutter = rowWidth + 2
    const widths = sheet?.widths ?? []
    const sizes = widths.map((w) => w + COLUMN_EXTRA)
    const room = innerWidth - gutter
    const firstBody = sheet?.header ? 1 : 0
    const bodyCount = Math.max(0, (sheet?.rows ?? 0) - firstBody)

    // the window that shows the cursor (also after a resize); stored offsets keep it still
    const rowTop = (r: number) => Math.max(r, firstBody) - firstBody
    const top = scrollWindow(rowTop(cursor.row), cursor.top, pageRows, bodyCount)
    const left = sheet ? firstShown(sizes, cursor.left, cursor.column, room) : 0
    const shownColumns = sheet ? fitCount(sizes, left, room) : 0

    const tabSizes = names.map(
        (n) => displayWidth(truncate(n, limits.maxTabName)) + TAB_EXTRA,
    )
    const tabRoom = innerWidth
    const first = firstShown(tabSizes, tabFirst, active, tabRoom)
    const tabCount = fitCount(tabSizes, first, tabRoom - 2)

    // ---- the plots mode
    const plot = plots[plotTab]
    const plotLines = useMemo(() => (plot ? plot.body.split("\n") : []), [plot])
    const maxPlotTop = Math.max(0, plotLines.length - pageRows)
    const maxPlotLeft = Math.max(0, (plot ? plotWidth(plot.body) : 0) - plotRoom)
    const pp = plotPositions[plotTab] ?? { top: 0, left: 0 }
    const plotTop = clampWindow(pp.top, pageRows, plotLines.length)
    const plotLeft = Math.min(pp.left, maxPlotLeft)
    const scrollPlot = (dTop: number, dLeft: number, absolute = false) =>
        setPlotPositions((s) => ({
            ...s,
            [plotTab]: {
                top: Math.min(maxPlotTop, Math.max(0, (absolute ? 0 : plotTop) + dTop)),
                left: Math.min(maxPlotLeft, Math.max(0, (absolute ? 0 : plotLeft) + dLeft)),
            },
        }))

    // ---- the legend: only the keys that work now (an arrow stops at an edge, the previous
    // tab is missing on the first, the next one on the last); the footer keeps the height
    // of the fullest legend (`legendFull`), so it never moves
    const legend = viewerLegend({
        plots: mode === "plots",
        sheets: names.length,
        active,
        hasPlots: plots.length > 0,
        move:
            mode === "plots"
                ? {
                    up: plotTop > 0,
                    down: plotTop < maxPlotTop,
                    left: plotLeft > 0,
                    right: plotLeft < maxPlotLeft,
                }
                : {
                    up: sheet !== undefined && cursor.row > 0,
                    down: sheet !== undefined && cursor.row < sheet.rows - 1,
                    left: sheet !== undefined && cursor.column > 0,
                    right: sheet !== undefined && cursor.column < sheet.columns - 1,
                },
        zoom: { in: sizeAt >= 0 && sizeAt < bySize.length - 1, out: sizeAt > 0 },
    })

    // ---- moves in the sheet
    /** Puts the cursor on a cell, keeping it in view, and forgets nothing else. */
    const place = (row: number, column: number) => {
        if (sheet === undefined) return
        const r = Math.min(Math.max(row, 0), sheet.rows - 1)
        const c = Math.min(Math.max(column, 0), sheet.columns - 1)
        setPositions((s) => ({
            ...s,
            [tab]: {
                row: r,
                column: c,
                top: scrollWindow(rowTop(r), top, pageRows, bodyCount),
                left: firstShown(sizes, left, c, room),
            },
        }))
    }

    const switchTab = (to: number) => {
        const next = Math.min(Math.max(to, 0), names.length - 1)
        if (mode === "plots") setPlotTab(next)
        else setTab(next)
        setTabFirst(0)
    }

    // ---- keys
    useKeys((press: KeyInput) => {
        setNote(undefined)
        if (press.is(keys.back)) return nav.depth > 1 ? nav.pop() : nav.quit()
        if (press.is(keys.plots)) {
            if (plots.length === 0) return say("no plots")
            setMode((m) => (m === "plots" ? "sheets" : "plots"))
            return setTabFirst(0)
        }
        // Shift+Tab is tested first: a plain `keys.tab` matches either press
        if (active > 0 && (press.is(keys.shiftTab) || press.is(keys.prevSheet)))
            return switchTab(active - 1)
        if (active < names.length - 1 && (press.is(keys.tab) || press.is(keys.nextSheet)))
            return switchTab(active + 1)
        if (mode === "plots" && press.is(keys.zoomIn) && zoomTo(+1)) return
        if (mode === "plots" && press.is(keys.zoomOut) && zoomTo(-1)) return
        if (mode === "plots") {
            if (press.is(keys.up)) scrollPlot(-1, 0)
            else if (press.is(keys.down)) scrollPlot(1, 0)
            else if (press.is(keys.left)) scrollPlot(0, -PLOT_STEP)
            else if (press.is(keys.right)) scrollPlot(0, PLOT_STEP)
            else if (press.is(keys.pageUp)) scrollPlot(-pageRows, 0)
            else if (press.is(keys.pageDown)) scrollPlot(pageRows, 0)
            else if (press.is(keys.home)) scrollPlot(0, 0, true)
            else if (press.is(keys.end)) scrollPlot(maxPlotTop, 0, true)
            return
        }
        if (sheet === undefined) return
        const { row, column } = cursor
        if (press.is(keys.up)) place(row - 1, column)
        else if (press.is(keys.down)) place(row + 1, column)
        else if (press.is(keys.left)) place(row, column - 1)
        else if (press.is(keys.right)) place(row, column + 1)
        else if (press.is(keys.pageUp)) place(row - pageRows, column)
        else if (press.is(keys.pageDown)) place(row + pageRows, column)
        else if (press.is(keys.home)) place(row, 0)
        else if (press.is(keys.end)) place(row, sheet.columns - 1)
    })

    // ---- drawing
    const subtitle = [subtitleProp, mode === "plots" ? "plots" : undefined]
        .filter(Boolean)
        .join(" · ")

    /** One cell: the text cut to its column, in the colour its state gives. */
    const cellView = (r: number, c: number, bold: boolean): ReactNode => {
        const w = widths[c] as number
        const raw = (sheet as Sheet).cells[r]?.[c] ?? ""
        const cut = truncate(raw, w)
        const pad = " ".repeat(Math.max(0, w - displayWidth(cut)))
        const text = looksNumeric(raw) ? pad + cut : padWidth(cut, w)
        const here = r === cursor.row && c === cursor.column
        return (
            <Text
                bold={bold || here}
                color={here ? theme.bg : theme.fg}
                backgroundColor={here ? theme.fg : undefined}
            >
                {` ${text} `}
            </Text>
        )
    }

    // the columns in view
    const shownIndices = Array.from({ length: shownColumns }, (_, k) => left + k)

    /** A line of the grid: the row number, then the columns that are in view. */
    const rowLine = (r: number, bold: boolean): ReactNode => (
        <Text>
            <Text color={r === cursor.row ? theme.fg : theme.mt} bold={r === cursor.row}>
                {` ${String(r + 1).padStart(rowWidth)} `}
            </Text>
            {shownIndices.map((c) => (
                <Fragment key={c}>
                    <Bar style={border} />
                    {cellView(r, c, bold)}
                </Fragment>
            ))}
        </Text>
    )

    const ruleWidths = [gutter, ...shownIndices.map((c) => (widths[c] ?? 0) + 2)]
    const lastLine = Math.min(plotLines.length, plotTop + pageRows)

    const status = ((): string => {
        if (mode === "plots")
            return plot
                ? `plot ${plotTab + 1} / ${plots.length} · ` +
                    (picked ? `${picked.width}x${picked.rows} · ` : "") +
                    `lines ${plotTop + 1}-${lastLine} of ${plotLines.length}`
                : "no plots"
        if (sheet === undefined) return ""
        const parts = [
            `${cellRef(cursor.row, cursor.column)} · ` +
                `row ${cursor.row + 1} / ${sheet.fullRows}`,
        ]
        if (sheet.fullRows > sheet.rows || sheet.fullColumns > sheet.columns)
            parts.push(
                `cut: ${sheet.rows} of ${sheet.fullRows} rows, ` +
                    `${sheet.columns} of ${sheet.fullColumns} columns`,
            )
        return parts.join(" · ")
    })()

    const failure =
        "error" in opened
            ? opened.error
            : loaded !== undefined && "error" in loaded
                ? loaded.error
                : undefined
    const shownNote = note ?? (failure ? { text: failure, error: true } : undefined)

    return (
        <Frame
            design={design}
            title={title}
            subtitle={subtitle}
            corner={corner}
            legend={legend}
            legendFull={fullLegend}
            note={shownNote?.text}
            noteIsError={shownNote?.error}
        >
            <TabBar names={names} active={active} first={first} count={tabCount} />
            <Panel
                style={panel}
                paddingX={mode === "plots" ? 0 : 1}
                flexDirection="column"
                flexGrow={1}
            >
                {mode === "plots" ? (
                    plotLines
                        .slice(plotTop, plotTop + pageRows)
                        .map((line, k) => (
                            // biome-ignore lint/suspicious/noArrayIndexKey: its place
                            <Text key={plotTop + k} color={theme.fg}>
                                {sliceCells(line, plotLeft, plotRoom)}
                            </Text>
                        ))
                ) : sheet === undefined || sheet.rows === 0 ? (
                    <Text color={theme.mt}>{failure ?? "this sheet is empty"}</Text>
                ) : (
                    <>
                        <Text color={theme.mt}>
                            {" ".repeat(gutter)}
                            {shownIndices.map((c) => (
                                <Fragment key={c}>
                                    <Bar style={border} />
                                    <Text
                                        bold={c === cursor.column}
                                        color={c === cursor.column ? theme.fg : theme.mt}
                                    >
                                        {` ${padWidth(columnLabel(c), widths[c] ?? 0)} `}
                                    </Text>
                                </Fragment>
                            ))}
                        </Text>
                        <Rule
                            style={border}
                            part="mid"
                            widths={ruleWidths}
                            options={{ frame: false }}
                        />
                        {sheet.header ? (
                            <>
                                {rowLine(0, true)}
                                <Rule
                                    style={border}
                                    part="mid"
                                    widths={ruleWidths}
                                    options={{ frame: false }}
                                />
                            </>
                        ) : null}
                        {Array.from(
                            { length: Math.min(pageRows, bodyCount - top) },
                            (_, k) => firstBody + top + k,
                        ).map((r) => (
                            <Fragment key={r}>{rowLine(r, false)}</Fragment>
                        ))}
                    </>
                )}
                <Box flexGrow={1} />
                <Text color={theme.mt} wrap="truncate-end">{status}</Text>
            </Panel>
        </Frame>
    )
}

// ========================================================================================
// 3. Open runs
// ========================================================================================

// `open... > open runs` of the project menu: the runs and their models, the viewer above on
// a model's results, `^r` to delete a run and `l` to read its `run.LOG`.

/** The keys `OpenRuns` can ever show: the frame reserves their height. */
const OPEN_FULL: LegendItem[] = [
    legendFor("move", [keys.up, keys.down]),
    legendFor("open", keys.enter),
    legendFor("run.LOG", keys.showLog),
    legendFor("delete run", keys.remove),
    legendBack,
]

/** The key of a selectable row: a model or the comparison of a run, or a run with none. */
const rowKey = (row: OpenRow): string =>
    row.kind === "run"
        ? row.run.id
        : `${row.run.id}/${row.kind === "compare" ? "\0" : ""}${row.model.name}`

/**
 * What Enter on a model that has no workbook says: why there is nothing to open.
 *
 * @param model - the model.
 * @returns the note, short.
 */
export function noWorkbookNote(model: OpenModel): string {
    if (model.state === "running" || model.state === "pending")
        return `${model.name} is still running`
    if (model.state === "failed")
        return model.error ? `${model.name} failed: ${model.error}` : `${model.name} failed`
    if (model.state === "done") return `${model.name} has no workbook`
    return `${model.name} was ${model.state}: no workbook`
}

/**
 * The text of a row of the open-runs list. A heading is the run (`stamp  status`); a
 * model row is `model  status`, indented under its run, or with its run in front when it
 * is the run's only model.
 *
 * @param row - the row.
 * @param stampWidth - the width of the run column (a long zone label widens it).
 * @returns the text before the status, and the status.
 */
export function openRowText(
    row: OpenRow,
    stampWidth: number = LOGS_FLOW.list.stampWidth,
): { text: string; status: string } {
    if (row.kind === "run") return { text: runDisplay(row.run.id), status: row.run.state }
    // a model that has settings of its own is marked
    const label = row.model.name + (row.model.overrides.length > 0 ? " *" : "")
    const name = row.nested
        ? `  ${label}`
        : `${(row.kind === "compare" ? "" : runDisplay(row.run.id)).padEnd(stampWidth)} ` +
            label
    return { text: name, status: row.model.state }
}

/** The keys of the pager, fullest first (the frame reserves their height). */
const pageNext = legendFor("next page", keys.enter, keys.space, keys.pageDown)
const pagePrev = legendFor("previous page", keys.pageBack, keys.pageUp)
const PAGER_FULL: LegendItem[] = [
    pageNext,
    pagePrev,
    legendFor("move", [keys.up, keys.down, keys.left, keys.right]),
    legendFor("close", keys.escape, keys.back),
]

/** The rows of the pager's panel that are not text: its borders and the status line. */
const PAGER_CHROME_ROWS = 3

/** The columns the pager's panel gives up: its two border columns and the padding. */
const PAGER_CHROME_COLUMNS = 4

/**
 * Watches the folder of a run for a page that shows it: another copy of the program may
 * delete the run while the page is open. Only the page on top looks (every
 * `watch.pollSeconds`, and at once when a page comes back to the top). When the folder is
 * gone the hook reports it; the page shows `this run was deleted` and the hook closes it
 * after `watch.closeSeconds` (or at any key), so nothing crashes and nothing stays on
 * screen.
 *
 * @param runDir - the run folder.
 * @returns `true` once the folder was found gone.
 */
export function useRunWatch(runDir: string): boolean {
    const nav = useNav()
    const active = useScreenActive()
    const [gone, setGone] = useState(false)

    useEffect(() => {
        if (!active) return
        const look = (): void => {
            if (!isFolder(runDir)) setGone(true)
        }
        look()
        const timer = setInterval(look, LOGS_FLOW.watch.pollSeconds * 1000)
        return () => clearInterval(timer)
    }, [active, runDir])

    useEffect(() => {
        if (!gone || !active) return
        const timer = setTimeout(nav.pop, LOGS_FLOW.watch.closeSeconds * 1000)
        return () => clearTimeout(timer)
    }, [gone, active, nav.pop])

    // any key closes it sooner; the keys of the page itself are off while it is gone
    useKeys(() => nav.pop(), gone)
    return gone
}

/**
 * The read-only pager of the program, ONE for every text of a run: its `run.LOG` (`l` in
 * `open runs`) and every view of the logs menu. Enter, Space and PgDn page down, `b` and
 * PgUp page up, the arrows move a line (or sideways, for the wide lines of a plot), Home
 * and End jump, Esc closes. The text is read once; a refusal (no file, too large, deleted)
 * is the note, and a run deleted while the page is open closes it with
 * `this run was deleted`.
 *
 * @param props.title - the title of the screen (`open`, `logs`).
 * @param props.subtitle - what is shown (`run.LOG`, `settings.json`).
 * @param props.corner - the corner text (`cornerLabel`).
 * @param props.runDir - the run folder, watched for its deletion.
 * @param props.design - `"blocky"` on the logs pages, `"smooth"` (default) in `open runs`.
 * @param props.load - reads the text (it may throw: the message is the note).
 * @returns the screen.
 */
export function TextPager(props: {
    title: string
    subtitle: string
    corner: string
    runDir: string
    load: () => string
    design?: Design
}): ReactNode {
    const { title, subtitle, corner, runDir, load, design = "smooth" } = props
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    const gone = useRunWatch(runDir)
    const panel = design === "blocky" ? "double" : "round"
    const [top, setTop] = useState(0)
    const [left, setLeft] = useState(0)
    // biome-ignore lint/correctness/useExhaustiveDependencies: `load` is read once per page
    const loaded = useMemo((): { lines: string[] } | { error: string } => {
        try {
            return { lines: pagerLines(load(), LOGS_FLOW.pager.tabWidth) }
        } catch (error) {
            const why = error instanceof Error ? error.message : "cannot read the file"
            return { error: why }
        }
    }, [runDir])
    const lines = "lines" in loaded ? loaded.lines : []
    const pageRows = Math.max(
        1,
        useBodyRows(legendExtraRows(PAGER_FULL, columns, design)) - PAGER_CHROME_ROWS,
    )
    const width = Math.max(1, columns - PAGER_CHROME_COLUMNS)
    const widest = useMemo(
        () => lines.reduce((m, l) => Math.max(m, displayWidth(l)), 0),
        [lines],
    )
    const maxLeft = Math.max(0, widest - width)
    const shownTop = clampTop(top, lines.length, pageRows)
    const shownLeft = Math.min(left, maxLeft)
    const canDown = shownTop < lastTop(lines.length, pageRows)
    const canUp = shownTop > 0

    useKeys((press) => {
        if (gone) return
        const page = (down: boolean): void =>
            setTop(pageTop(shownTop, lines.length, pageRows, LOGS_FLOW.pager.overlap, down))
        if (press.is(keys.escape) || press.is(keys.back)) nav.pop()
        else if (press.is(keys.enter) || press.is(keys.space) || press.is(keys.pageDown))
            page(true)
        else if (press.is(keys.pageBack) || press.is(keys.pageUp)) page(false)
        else if (press.is(keys.down)) setTop(clampTop(shownTop + 1, lines.length, pageRows))
        else if (press.is(keys.up)) setTop(clampTop(shownTop - 1, lines.length, pageRows))
        else if (press.is(keys.home)) setTop(0)
        else if (press.is(keys.end)) setTop(lastTop(lines.length, pageRows))
        else if (press.is(keys.right))
            setLeft(Math.min(shownLeft + LOGS_FLOW.pager.sideStep, maxLeft))
        else if (press.is(keys.left))
            setLeft(Math.max(shownLeft - LOGS_FLOW.pager.sideStep, 0))
    })

    const error = gone ? RUN_GONE : "error" in loaded ? loaded.error : undefined
    return (
        <Frame
            design={design}
            title={title}
            subtitle={subtitle}
            corner={corner}
            legend={legendOf([
                canDown && pageNext,
                canUp && pagePrev,
                moveLegend({
                    up: canUp,
                    down: canDown,
                    left: shownLeft > 0,
                    right: shownLeft < maxLeft,
                }),
                legendFor("close", keys.escape, keys.back),
            ])}
            legendFull={PAGER_FULL}
            note={error}
            noteIsError={error !== undefined}
        >
            <Panel style={panel} paddingX={1} flexDirection="column" flexGrow={1}>
                {lines.slice(shownTop, shownTop + pageRows).map((line, i) => (
                    // biome-ignore lint/suspicious/noArrayIndexKey: a line is its place
                    <Text key={shownTop + i} color={theme.fg} wrap="truncate">
                        {sliceCells(line, shownLeft, width) || " "}
                    </Text>
                ))}
                <Box flexGrow={1} />
                <Text color={theme.mt} wrap="truncate-end">
                    {pagerStatus(shownTop, lines.length, pageRows)}
                </Text>
            </Panel>
        </Frame>
    )
}

/**
 * The display of `open... > open runs`: the runs of the project, newest first, and their
 * models. A run with several models is a heading with its models under it; a run with one
 * model is that one row; a run with none is a row of its own. Enter on a model that is done
 * opens the read-only viewer on its results workbook (with the model's `plots.txt` behind
 * `^p`); on any other model the note says why there is nothing to open. `l` shows the
 * run's `run.LOG`; `^r` deletes the whole run folder after the usual question (refused
 * while a run of the project is live). The list is read again every few seconds and when
 * the screen comes back to the top.
 *
 * @param props.project - the project.
 * @returns the screen.
 */
export function OpenRuns({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const active = useScreenActive()
    const theme = useTheme()
    const confirm = useConfirm()
    const [runs, setRuns] = useState<OpenRun[]>(() => listOpenRuns(project.dir))
    // the highlighted row is kept by NAME, so a list that changes under it keeps the cursor
    const [selected, setSelected] = useState<string | undefined>()
    const [offset, setOffset] = useState(0)
    const [note, setNote] = useState<{ text: string; error: boolean } | undefined>()

    const refresh = useCallback(() => setRuns(listOpenRuns(project.dir)), [project.dir])
    useEffect(() => {
        if (!active) return
        refresh()
        const timer = setInterval(refresh, LOGS_FLOW.watch.pollSeconds * 1000)
        return () => clearInterval(timer)
    }, [active, refresh])

    const rows = useMemo(() => openRows(runs), [runs])
    // the cursor lives on the model rows and on runs without a model (not on a heading)
    const stops = rows.flatMap((r, i) =>
        r.kind !== "run" || r.run.models.length === 0 ? [i] : [],
    )
    const stop = Math.max(
        stops.findIndex((i) => rowKey(rows[i] as OpenRow) === selected),
        0,
    )
    const at = stops[stop] ?? 0
    const current = rows[at]
    const pageSize = useBodyRows()
    const columns = useBodyColumns()
    const top = scrollWindow(at, offset, pageSize, rows.length)
    // the status words line up: the names are padded to the longest
    const stampWidth = Math.max(
        LOGS_FLOW.list.stampWidth,
        ...rows.map((r) => displayWidth(runDisplay(r.run.id))),
    )
    const nameWidth = Math.max(
        ...rows.map((r) => displayWidth(openRowText(r, stampWidth).text)),
    )

    const step = (to: number): void => {
        const i = stops[Math.min(Math.max(to, 0), stops.length - 1)]
        if (i !== undefined) setSelected(rowKey(rows[i] as OpenRow))
        setOffset(top)
    }

    /** `^r`: refuse a live run, else ask and, on Enter, delete the whole run folder. */
    const askDelete = (run: OpenRun): void => {
        const live = liveRun(project.dir)
        if (live !== undefined) {
            setNote({ text: `a run is in progress (pid ${live.pid})`, error: true })
            return
        }
        confirm.ask(destructiveQuestion(`run ${runDisplay(run.id)}`), () => {
            try {
                deleteRun(project.dir, run.id)
                setNote({ text: "run deleted", error: false })
            } catch (error) {
                const text = error instanceof Error ? error.message : "could not delete"
                setNote({ text, error: true })
            }
            refresh()
        })
    }

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        setNote(undefined)
        if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
        else if (press.is(keys.up)) step(stop - 1)
        else if (press.is(keys.down)) step(stop + 1)
        else if (current === undefined) return
        else if (press.is(keys.remove)) askDelete(current.run)
        else if (press.is(keys.showLog))
            nav.push(
                <TextPager
                    title="open"
                    subtitle="run.LOG"
                    corner={cornerLabel(project.id, current.run.id)}
                    runDir={current.run.dir}
                    load={() => readLogText(current.run.dir)}
                />,
            )
        else if (press.is(keys.enter)) {
            if (current.kind === "run")
                return setNote({
                    text: `${runDisplay(current.run.id)} has no models`,
                    error: false,
                })
            const { run, model } = current
            if (model.workbook === undefined)
                return setNote({ text: noWorkbookNote(model), error: false })
            nav.push(
                <SheetViewerScreen
                    workbookPath={model.workbook}
                    plotsPath={model.plots}
                    plotFiles={model.plotSizes}
                    title={current.kind === "compare" ? "comparison" : "results"}
                    subtitle={current.kind === "compare" ? undefined : model.name}
                    corner={cornerLabel(project.id, run.id)}
                />,
            )
        }
    })

    const legend = confirm.question
        ? questionLegend(confirm.question)
        : legendOf([
            moveLegend({ up: stop > 0, down: stop < stops.length - 1 }),
            current !== undefined && legendFor("open", keys.enter),
            current !== undefined && legendFor("run.LOG", keys.showLog),
            current !== undefined && legendFor("delete run", keys.remove),
            legendBack,
        ])
    // a model with settings of its own says which, when nothing else is to be said
    const own = current?.kind === "model" ? current.model.overrides : []
    const hint =
        own.length > 0
            ? { text: truncate(`overrides: ${own.join(", ")}`, columns - 4), error: false }
            : undefined
    const shown =
        confirm.note !== undefined ? { text: confirm.note, error: false } : (note ?? hint)
    return (
        <Frame
            title="open"
            subtitle="runs"
            corner={cornerLabel(project.id)}
            legend={legend}
            legendFull={OPEN_FULL}
            note={shown?.text}
            noteIsError={shown?.error}
        >
            {rows.length === 0 ? (
                <Text color={theme.mt}>no runs yet</Text>
            ) : (
                <CursorList
                    items={rows}
                    index={at}
                    offset={top}
                    lines={pageSize}
                    heading={(r) =>
                        r.kind === "run" && r.run.models.length > 0
                            ? headingText(r.run)
                            : undefined
                    }
                    row={(r, on) => {
                        const { text, status } = openRowText(r, stampWidth)
                        const bad =
                            r.kind === "run"
                                ? r.run.state === "failed"
                                : r.model.state === "failed"
                        return (
                            <Box columnGap={2}>
                                <ListText on={on}>{padWidth(text, nameWidth)}</ListText>
                                {bad ? (
                                    <Text color={theme.er}>{status}</Text>
                                ) : (
                                    <ListText on={on}>{status}</ListText>
                                )}
                            </Box>
                        )
                    }}
                />
            )}
        </Frame>
    )
}

/**
 * The text of a run's heading row: its stamp and how it stands.
 *
 * @param run - the run.
 * @returns the text.
 */
function headingText(run: OpenRun): string {
    const { text, status } = openRowText({ kind: "run", run })
    return `${text}  ${status}`
}
