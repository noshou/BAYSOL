// SPDX-License-Identifier: LGPL-3.0-or-later

// The read-only file viewer (a workbook or a delimited file, with its plots text behind
// `^p`) and its legends. `open-runs.tsx` is the screen that leads to it.
//
// Contents:
//   1. The viewer legend: the sheet legend and the rows its fullest legend needs
//   2. `SheetViewerScreen`: the read-only viewer of a workbook, a table file or plots

import { readFileSync, statSync } from "node:fs"
import { basename, relative, sep } from "node:path"
import { Box, Text, useWindowSize } from "ink"
import { Fragment, type ReactNode, useMemo, useState } from "react"
import { isFile } from "../core/file-system.js"
import { displayWidth, padWidth, truncate, writeTerminal } from "../core/terminal.js"
import { readRunText } from "../store/run-archive.js"
import type { PlotFile } from "../store/run-logs.js"
import {
    type CellAt,
    type CopyWhat,
    cellRef,
    clipboardSequence,
    columnLabel,
    copyText,
    findCells,
    firstShown,
    fitCount,
    fitWidths,
    looksNumeric,
    matchFrom,
    matchIndex,
    matchStep,
    openWorkbook,
    type Plot,
    parseJump,
    pickPlotFile,
    plotWidth,
    type Sheet,
    shownCells,
    sliceCells,
    splitPlots,
    VIEWER_LIMITS,
    ViewerFileError,
    type Workbook,
} from "../store/view.js"
import { Frame, footerExtraLines } from "../ui/frame.js"
import {
    type Design,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import { Prompt } from "../ui/input.js"
import {
    clampWindow,
    type KeyInput,
    keys,
    scrollWindow,
    useBodyColumns,
    useKeys,
    useNav,
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
export function viewerFullLegend(base: { hasPlots: boolean }): LegendItem[] {
    const all = { up: true, down: true, left: true, right: true }
    return viewerLegend({
        ...base,
        plots: false,
        sheets: 3,
        active: 1,
        move: all,
        zoom: { in: true, out: true },
        cells: true,
        marked: true,
        hasFormulas: true,
        matches: true,
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
export function legendExtraRows(
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
 * @property cells - a sheet is shown (sheets mode): find, go to, mark and copy work.
 * @property marked - a range is marked (`mark` becomes `unmark`).
 * @property hasFormulas - the sheet has formulas (`f` works).
 * @property matches - a search found cells (`n` and shift+`n` work).
 */
export type ViewerFacts = {
    plots: boolean
    sheets: number
    active: number
    hasPlots: boolean
    move: { up: boolean; down: boolean; left: boolean; right: boolean }
    zoom: { in: boolean; out: boolean }
    cells: boolean
    marked: boolean
    hasFormulas: boolean
    matches: boolean
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
    const on = facts.cells && !facts.plots
    // the order puts the keys in columns of three that fit one band at 80 columns
    return legendOf([
        next,
        prev,
        move,
        ...zoom,
        on && legendFor("find", keys.find),
        on && legendFor("go to", keys.jump),
        on && legendFor(facts.marked ? "unmark" : "mark", keys.space),
        on && facts.matches && legendFor("next match", keys.nextMatch),
        on && facts.matches && legendFor("prev match", keys.prevMatch),
        on && facts.hasFormulas && legendFor("formulas", keys.formulas),
        on && legendFor("copy", keys.copy),
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

/**
 * The plots file read: its plots, or none (missing, unreadable, empty, no plot in it). The
 * file is read from its plain place or, for a packed run, from the run's archive (`runDir`
 * is the run folder the path is in); nothing is extracted to disk.
 */
export function readPlots(path: string | undefined, runDir: string | undefined): Plot[] {
    if (path === undefined || path === "") return []
    try {
        if (runDir !== undefined && !isFile(path)) {
            const rel = relative(runDir, path).split(sep).join("/")
            return splitPlots(readRunText(runDir, rel, VIEWER_LIMITS.maxBytes))
        }
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
 * @param props.runDir - the run folder the plots files are in: a plots file that is not on
 *     disk is read from its archive (`run.7z`).
 * @param props.title - the title of the screen, `view` when left out.
 * @param props.design - `"blocky"` (the logs pages) or `"smooth"` (`open runs`, default).
 * @param props.corner - the text at the top right of the title row; none when left out.
 * @returns the screen.
 */
export function SheetViewerScreen(props: {
    workbookPath: string
    plotsPath?: string
    plotFiles?: PlotFile[]
    runDir?: string
    title?: string
    subtitle?: string
    corner?: string | readonly string[]
    design?: Design
}): ReactNode {
    const { workbookPath, plotsPath, plotFiles = [], title = "view", corner } = props
    const { runDir } = props
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
        const sized = readPlots(pickedPath, runDir)
        return sized.length > 0 || pickedPath === undefined
            ? sized
            : readPlots(plotsPath, runDir)
    }, [pickedPath, plotsPath, runDir])

    // ---- state
    const [mode, setMode] = useState<"sheets" | "plots">("sheets")
    const [tab, setTab] = useState(0)
    const [plotTab, setPlotTab] = useState(0)
    const [tabFirst, setTabFirst] = useState(0)
    const [positions, setPositions] = useState<Record<number, Pos>>({})
    const [plotPositions, setPlotPositions] = useState<Record<number, PlotPos>>({})
    const [note, setNote] = useState<{ text: string; error: boolean } | undefined>()
    const say = (text: string, error = false) => setNote({ text, error })
    // find, jump, mark, copy and formulas (sheets mode)
    const [asking, setAsking] = useState<"find" | "jump" | undefined>()
    const [askKeys, setAskKeys] = useState<LegendItem[]>([])
    const [search, setSearch] = useState("")
    const [mark, setMark] = useState<{ tab: number; at: CellAt } | undefined>()
    const [copying, setCopying] = useState(false)
    const [showFormulas, setShowFormulas] = useState(false)

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

    // what the cells show (a formula's text with `f`) and what the search finds in it
    const hasFormulas = sheet?.formulas !== undefined
    const formulasOn = showFormulas && hasFormulas
    const texts = useMemo(
        () => (sheet ? shownCells(sheet, formulasOn) : []),
        [sheet, formulasOn],
    )
    const found = useMemo(() => findCells(texts, search), [texts, search])
    const foundKeys = useMemo(
        () => new Set(found.map((m) => `${m.row}:${m.column}`)),
        [found],
    )
    const foundAt = matchIndex(found, cursor.row, cursor.column)
    const range =
        mark !== undefined && mark.tab === tab
            ? {
                r0: Math.min(mark.at.row, cursor.row),
                r1: Math.max(mark.at.row, cursor.row),
                c0: Math.min(mark.at.column, cursor.column),
                c1: Math.max(mark.at.column, cursor.column),
            }
            : undefined

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
    const formulaWidths = useMemo(
        () =>
            sheet && formulasOn
                ? fitWidths(texts, sheet.columns, VIEWER_LIMITS)
                : undefined,
        [sheet, formulasOn, texts],
    )
    const widths = formulaWidths ?? sheet?.widths ?? []
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
        cells: sheet !== undefined && sheet.rows > 0,
        marked: range !== undefined,
        hasFormulas,
        matches: found.length > 0,
    })
    const copyLegend = legendOf([
        legendFor("cell", keys.copy),
        legendFor("row", keys.copyRow),
        legendFor("column", keys.copyColumn),
        legendFor("cancel", keys.escape),
    ])

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
        setMark(undefined)
        setTabFirst(0)
    }

    /** Copies what was asked through the terminal and says what went. */
    const copy = (what: CopyWhat) => {
        const out = copyText(texts, what)
        if ("error" in out) return say(out.error, true)
        if (!writeTerminal(clipboardSequence(out.text))) return say("no terminal", true)
        setMark(undefined)
        say(out.note)
    }

    /** Puts the cursor on a match (the search found some) and says where it is. */
    const goToMatch = (at: number | undefined, list: readonly CellAt[] = found) => {
        const m = at === undefined ? undefined : list[at]
        if (m === undefined) return say("no match")
        place(m.row, m.column)
    }

    /** `/` took a text: an empty one ends the search. */
    const submitFind = (text: string) => {
        setAsking(undefined)
        setSearch(text)
        if (text === "") return
        const list = findCells(texts, text)
        goToMatch(matchFrom(list, cursor.row, cursor.column), list)
    }

    /** `g` took a cell, a row or a column. */
    const submitJump = (text: string) => {
        setAsking(undefined)
        if (sheet === undefined) return
        const to = parseJump(text, cursor, sheet.rows, sheet.columns)
        if ("error" in to) return say(to.error, true)
        place(to.row, to.column)
    }

    // ---- keys
    useKeys((press: KeyInput) => {
        setNote(undefined)
        if (copying) {
            setCopying(false)
            if (sheet === undefined) return
            const here = { row: cursor.row, column: cursor.column }
            if (press.is(keys.copy)) copy({ kind: "range", from: here, to: here })
            else if (press.is(keys.copyRow)) copy({ kind: "row", row: cursor.row })
            else if (press.is(keys.copyColumn))
                copy({ kind: "column", column: cursor.column })
            return
        }
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
        const zoomIn = press.is(keys.zoomIn) || press.is(keys.zoomInAlt)
        if (mode === "plots" && zoomIn && zoomTo(+1)) return
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
        if (press.is(keys.escape) && range !== undefined) return setMark(undefined)
        if (sheet.rows > 0) {
            if (press.is(keys.find)) return setAsking("find")
            if (press.is(keys.jump)) return setAsking("jump")
            if (press.is(keys.space))
                return setMark(range ? undefined : { tab, at: { row, column } })
            if (press.is(keys.copy)) {
                if (range === undefined) return setCopying(true)
                return copy({
                    kind: "range",
                    from: { row: range.r0, column: range.c0 },
                    to: { row: range.r1, column: range.c1 },
                })
            }
            if (press.is(keys.formulas)) {
                if (!hasFormulas) return say("no formulas here")
                return setShowFormulas((v) => !v)
            }
            // shift+n is tested first: a plain `n` matches either press
            if (press.is(keys.prevMatch) || press.is(keys.nextMatch)) {
                if (search === "") return say("nothing searched: press /")
                const dir = press.is(keys.prevMatch) ? -1 : 1
                return goToMatch(matchStep(found, row, column, dir))
            }
        }
        if (press.is(keys.up)) place(row - 1, column)
        else if (press.is(keys.down)) place(row + 1, column)
        else if (press.is(keys.left)) place(row, column - 1)
        else if (press.is(keys.right)) place(row, column + 1)
        else if (press.is(keys.pageUp)) place(row - pageRows, column)
        else if (press.is(keys.pageDown)) place(row + pageRows, column)
        else if (press.is(keys.home)) place(row, 0)
        else if (press.is(keys.end)) place(row, sheet.columns - 1)
    }, asking === undefined)

    // ---- drawing
    const subtitle = [subtitleProp, mode === "plots" ? "plots" : undefined]
        .filter(Boolean)
        .join(" · ")

    /** One cell: the text cut to its column, in the colour its state gives. */
    const cellView = (r: number, c: number, bold: boolean): ReactNode => {
        const w = widths[c] as number
        const raw = texts[r]?.[c] ?? ""
        const cut = truncate(raw, w)
        const pad = " ".repeat(Math.max(0, w - displayWidth(cut)))
        const text = looksNumeric(raw) ? pad + cut : padWidth(cut, w)
        const here = r === cursor.row && c === cursor.column
        const marked =
            range !== undefined &&
            r >= range.r0 &&
            r <= range.r1 &&
            c >= range.c0 &&
            c <= range.c1
        return (
            <Text
                bold={bold || here}
                underline={foundKeys.has(`${r}:${c}`)}
                color={here || marked ? theme.bg : theme.fg}
                backgroundColor={here ? theme.fg : marked ? theme.mt : undefined}
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
        if (search !== "" && sheet.rows > 0)
            parts.push(
                foundAt === undefined
                    ? `${found.length} matches`
                    : `match ${foundAt + 1} / ${found.length}`,
            )
        if (range !== undefined)
            parts.push(
                `range ${cellRef(range.r0, range.c0)}:${cellRef(range.r1, range.c1)}`,
            )
        if (formulasOn) parts.push("formulas")
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
    const shownNote = copying
        ? { text: "copy: cell (c), row (r), column (l)?", error: false }
        : (note ?? (failure ? { text: failure, error: true } : undefined))

    return (
        <Frame
            design={design}
            title={title}
            subtitle={subtitle}
            corner={corner}
            legend={asking ? askKeys : copying ? copyLegend : legend}
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
                {asking ? (
                    <Prompt
                        label={asking === "find" ? "find:" : "go to:"}
                        initial={asking === "find" ? search : ""}
                        maxLength={VIEWER_LIMITS.maxColumnWidth * 2}
                        take={asking === "find" ? "find" : "go"}
                        onLegend={setAskKeys}
                        onSubmit={asking === "find" ? submitFind : submitJump}
                        onCancel={() => setAsking(undefined)}
                    />
                ) : (
                    <Text color={theme.mt} wrap="truncate-end">
                        {status}
                    </Text>
                )}
            </Panel>
        </Frame>
    )
}
