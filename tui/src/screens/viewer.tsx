// SPDX-License-Identifier: LGPL-3.0-or-later

// The read-only file viewer (a workbook or a delimited file, with its plots text behind
// `shift+p`) and its legends. `open-runs.tsx` is the screen that leads to it.
//
// Contents:
//   1. The viewer legend: the sheet legend and the rows its fullest legend needs
//   2. `SheetViewerScreen`: the read-only viewer of a workbook, a table file or plots

import { readFileSync, statSync } from "node:fs"
import { basename, join, relative, sep } from "node:path"
import { Box, Text } from "ink"
import { Fragment, type ReactNode, useEffect, useMemo, useState } from "react"
import { isFile } from "../core/file-system.js"
import {
    clampIndex,
    displayWidth,
    padWidth,
    truncate,
    writeTerminal,
} from "../core/terminal.js"
import { cellDescription, fitDescription } from "../store/column-descriptions.js"
import {
    canGraphics,
    chosenView,
    type FigurePair,
    graphicsRefusal,
    listRendered,
    maxPanCells,
    PLOT_NOT_RENDERED,
    pixelBox,
    plotStem,
    renderedFile,
    zoomLevels,
} from "../store/plot-graphics.js"
import { materializeRunFileAsync, readRunText } from "../store/run-archive.js"
import type { PlotFile } from "../store/run-logs.js"
import { getSixelSupport } from "../store/sixel-support.js"
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
    type Sheet,
    shownCells,
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
import { Prompt, useNote } from "../ui/input.js"
import {
    type KeyInput,
    keys,
    scrollWindow,
    useBodyColumns,
    useKeys,
    useNav,
    useTerminalSize,
} from "../ui/interaction.js"
import { PagerLine, PagerPrompt, pageKey, pageLegend, usePager } from "../ui/pager.js"
import { hideSixelNow, SixelArea } from "../ui/sixel-view.js"
import { Bar, linesOf, Panel, Rule, useTheme } from "../ui/theme.js"
import { type GraphicTarget, useCacheEntry, useGraphicFrame } from "./viewer-graphics.js"

// ========================================================================================
// 1. The file viewer
// ========================================================================================

/** The lines the viewer's frame is laid out for: one band, a column of three. */
const BASE_LEGEND_LINES = 3

/**
 * The keys the viewer's footer must have room for, so it does not change height while the
 * user works: everything its sheets mode or its plots mode can show for this workbook at
 * once (the longer of the two by the lines they take at this width).
 *
 * @param base - what the workbook has: a plots file.
 * @param columns - the width of the body; the sheets legend when left out.
 * @param design - the page's design.
 * @returns the items.
 */
export function viewerFullLegend(
    base: { hasPlots: boolean },
    columns?: number,
    design: Design = "smooth",
): LegendItem[] {
    const all = { up: true, down: true, left: true, right: true }
    const facts = {
        ...base,
        sheets: 3,
        active: 1,
        move: all,
        pages: { up: true, down: true },
        zoom: { in: true, out: true },
        cells: true,
        marked: true,
        hasFormulas: true,
        matches: true,
    }
    const sheets = viewerLegend({ ...facts, plots: false, graphics: undefined })
    if (!base.hasPlots || columns === undefined) return sheets
    const plots = viewerLegend({ ...facts, plots: true, graphics: false })
    const rows = (items: LegendItem[]) => legendExtraRows(items, columns, design)
    return rows(plots) > rows(sheets) ? plots : sheets
}

/**
 * The rows a footer with these keys takes beyond those its frame is laid out for. The keys
 * go in as many bands as the width needs (never cut), so a narrow terminal has a taller
 * footer; the grid gives those rows up.
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
 * @property hasPlots - a plots file is there (the plots key works).
 * @property move - which arrows can move now (an edge has none past it).
 * @property pages - whether a page down or up moves anything.
 * @property zoom - whether a larger (`in`) or smaller (`out`) plot size exists.
 * @property cells - a sheet is shown, or a Unicode plot: find, go to, mark and copy work.
 * @property marked - a range is marked (`mark` becomes `unmark`).
 * @property hasFormulas - the sheet has formulas (the formulas key works).
 * @property matches - a search found something (the match keys work).
 * @property graphics - the graphics view is possible for this plot (a sixel terminal and a
 *     rendered figure): `false` offers it, `true` offers the way back to Unicode; left out
 *     or `undefined` it is not offered. While it is shown (`true`) the plot is a picture:
 *     no find, go to, mark or copy.
 */
export type ViewerFacts = {
    plots: boolean
    sheets: number
    active: number
    hasPlots: boolean
    move: { up: boolean; down: boolean; left: boolean; right: boolean }
    pages: { up: boolean; down: boolean }
    zoom: { in: boolean; out: boolean }
    cells: boolean
    marked: boolean
    hasFormulas: boolean
    matches: boolean
    graphics?: boolean | undefined
}

/**
 * The keys of the viewer that work now, back last.
 *
 * @param facts - the state.
 * @returns the items (the frame lays them out in as many bands as the width needs).
 */
export function viewerLegend(facts: ViewerFacts): LegendItem[] {
    const next = facts.active < facts.sheets - 1 && legendFor("next", keys.tab)
    const prev = facts.active > 0 && legendFor("prev", keys.shiftTab)
    const zoom = facts.plots
        ? [
            facts.zoom.in && legendFor("zoom in", keys.zoomIn),
            facts.zoom.out && legendFor("zoom out", keys.zoomOut),
        ]
        : []
    // a sheet, or a Unicode plot (a picture has no lines to find, mark or copy)
    const on = facts.cells && !(facts.plots && facts.graphics === true)
    // the order puts the keys in columns of three that fit one band at 80 columns
    return legendOf([
        next,
        prev,
        moveLegend(facts.move),
        facts.pages.down && pageLegend.next,
        facts.pages.up && pageLegend.prev,
        ...zoom,
        on && legendFor("find", keys.find),
        on && legendFor("go to", keys.jump),
        on && legendFor(facts.marked ? "unmark" : "mark", keys.mark),
        on && facts.matches && legendFor("next match", keys.nextMatch),
        on && facts.matches && legendFor("prev match", keys.prevMatch),
        on && !facts.plots && facts.hasFormulas && legendFor("formulas", keys.formulas),
        on && legendFor("copy", keys.copy),
        facts.plots && legendFor(facts.graphics ? "unicode" : "graphics", keys.plotType),
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

/**
 * Where the figures of a run's plots are rendered.
 *
 * @property dir - the plot folder of the run (`<plot folder>/<run>`).
 * @property pairs - each figure's run-side name and its name in `dir` (`figurePairs`).
 * @property writable - the sixel cache may be written to the run (it is not live).
 */
export type Figures = { dir: string; pairs: FigurePair[]; writable: boolean }

/** The cursor, and the first row and column shown, of one sheet. */
type Pos = { row: number; column: number; top: number; left: number }

/** Where a plot is scrolled to. */
type PlotPos = { top: number; left: number }

/** What opening the file gave: the workbook, or the sentence that says why not. */
type Opened = { book: Workbook } | { error: string }

/** The sentence for a failure to open a file (a viewer error says its own). */
const viewerMessage = (error: unknown): string =>
    error instanceof ViewerFileError ? error.message : "cannot read that file"

/**
 * Opens a workbook without throwing.
 *
 * @param file - gives the path to parse (it may throw, as making a copy does).
 * @param name - the file's name as shown.
 * @returns the workbook, or the error's sentence.
 */
function openedFrom(file: () => string, name: string): Opened {
    try {
        return { book: openWorkbook(file(), basename(name)) }
    } catch (error) {
        return { error: viewerMessage(error) }
    }
}

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
 * workbook mode has one tab per sheet (a delimited file is one tab) and a scrollable grid
 * (cursor cell, widths fitted to the text, a header row kept in view). The plots mode
 * (`shift+p`) has one tab per terminal plot of a plots file, painted in the theme's
 * colours and read with the pager's keys ([[usePager]]) when bigger than the panel.
 * Nothing is ever written.
 *
 * @param props.workbookPath - the workbook or delimited file.
 * @param props.plotsPath - the plots text file; without it (or with no plot in it) the
 *     plots key is not offered and does nothing.
 * @param props.plotFiles - the same plots written at several sizes (width, rows of the
 *     tallest plot): the largest that fits the panel is shown and picked again when the
 *     window changes, the plot tab kept; `plotsPath` is the fallback (and for a caller
 *     with no sizes the only file).
 * @param props.runDir - the run folder the plots files are in: a plots file that is not on
 *     disk is read from its archive (`<run>.7z`).
 * @param props.figures - where the rendered figures of these plots are (the run's plot
 *     folder) and the figures' names: with it, and on a terminal that draws sixel, the
 *     plots mode can show the figures as graphics (`shift+t`); without it Unicode only.
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
    figures?: Figures
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
    // a plain file is parsed at once; a workbook that is only in the run's archive is made
    // into a copy on disk and parsed afterwards, while the screen shows `loading…`
    const archived = useMemo(
        () => runDir !== undefined && !isFile(workbookPath),
        [workbookPath, runDir],
    )
    const plainOpened = useMemo(
        (): Opened | undefined =>
            archived ? undefined : openedFrom(() => workbookPath, workbookPath),
        [archived, workbookPath],
    )
    const [archivedOpened, setArchivedOpened] = useState<
        { key: string; opened: Opened } | undefined
    >()
    const loadKey = `${runDir}\0${workbookPath}`
    useEffect(() => {
        if (!archived || runDir === undefined) return
        // a load that is over after the screen is gone (or the file changed) is dropped
        let live = true
        materializeRunFileAsync(runDir, workbookPath).then(
            (file) =>
                // parsed after the screen has drawn once more, not in the same turn
                setImmediate(() => {
                    if (live)
                        setArchivedOpened({
                            key: loadKey,
                            opened: openedFrom(() => file, workbookPath),
                        })
                }),
            (error: unknown) => {
                if (live)
                    setArchivedOpened({
                        key: loadKey,
                        opened: { error: viewerMessage(error) },
                    })
            },
        )
        return () => {
            live = false
        }
    }, [archived, runDir, workbookPath, loadKey])
    // `undefined` while the copy is made and the workbook parsed
    const opened: Opened | undefined = archived
        ? archivedOpened?.key === loadKey
            ? archivedOpened.opened
            : undefined
        : plainOpened
    // the plots come at several sizes: the largest file that fits the panel is read, and
    // another one when the window changes (the tabs are the same in every size)
    const { rows: terminalRows } = useTerminalSize()
    const innerWidth = columnsAvailable - 4
    // a plot is drawn right up to the panel's border (no padding), so a plot as wide as
    // the 80-column window less its margins and borders fits
    const plotRoom = columnsAvailable - 2
    const pickRows = Math.max(
        1,
        terminalRows -
            FRAME_ROWS -
            legendExtraRows(
                viewerFullLegend({ hasPlots: true }, columnsAvailable, design),
                columnsAvailable,
                design,
            ) -
            TABS_AND_STATUS_ROWS,
    )
    // the zoom keys pick another size of the plots than the automatic one; the files go
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
        // no sizes (or an unreadable one): the plain plots file
        const sized = readPlots(pickedPath, runDir)
        return sized.length > 0 ? sized : readPlots(plotsPath, runDir)
    }, [pickedPath, plotsPath, runDir])

    // ---- state
    const [mode, setMode] = useState<"sheets" | "plots">("sheets")
    const [tab, setTab] = useState(0)
    const [plotTab, setPlotTab] = useState(0)
    const [tabFirst, setTabFirst] = useState(0)
    const [positions, setPositions] = useState<Record<number, Pos>>({})
    const { note, say, clear } = useNote()
    // find, jump, mark, copy and formulas (sheets mode)
    const [asking, setAsking] = useState<"find" | "jump" | undefined>()
    const [askKeys, setAskKeys] = useState<LegendItem[]>([])
    const [search, setSearch] = useState("")
    const [mark, setMark] = useState<{ tab: number; at: CellAt } | undefined>()
    const [copying, setCopying] = useState(false)
    const [showFormulas, setShowFormulas] = useState(false)

    const book = opened !== undefined && "book" in opened ? opened.book : undefined
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

    // what the cells show (a formula's text with `shift+u`) and what the search finds in it
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
    const fullLegend = viewerFullLegend(
        { hasPlots: plots.length > 0 },
        columnsAvailable,
        design,
    )
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
    // a Unicode plot is a text of several pages: the one pager of the program, its place
    // kept per plot tab
    const pager = usePager({
        id: plotTab,
        lines: plotLines,
        rows: pageRows,
        width: plotRoom,
        overlap: 0,
        sideStep: PLOT_STEP,
        screenEnds: true,
        say,
    })

    // ---- the graphics view: the rendered figure of this plot as a sixel picture. It is
    // possible with a sixel terminal and a rendered figure (or a cache of it); it opens by
    // default when the run already has the cache, else `plotType` asks for it. Zoom and pan
    // act on the picture the way they act on the Unicode plot while it is shown.
    const support = getSixelSupport()
    const { figures } = props
    const rendered = useMemo(
        () => (figures === undefined ? [] : listRendered(figures.dir)),
        [figures],
    )
    const stemHere =
        figures === undefined || plot === undefined
            ? undefined
            : plotStem(
                plot.title,
                figures.pairs.map((p) => p.stem),
                plots.length,
            )
    const destHere = figures?.pairs.find((p) => p.stem === stemHere)?.dest
    const fileHere = destHere === undefined ? undefined : renderedFile(rendered, destHere)
    /** The graphics target of a plot tab (`undefined`: no figure for it). */
    const targetOfTab = (index: number): GraphicTarget | undefined => {
        const tabPlot = plots[index]
        if (figures === undefined || tabPlot === undefined || runDir === undefined)
            return undefined
        const stem = plotStem(
            tabPlot.title,
            figures.pairs.map((p) => p.stem),
            plots.length,
        )
        const dest = figures.pairs.find((p) => p.stem === stem)?.dest
        const file = dest === undefined ? undefined : renderedFile(rendered, dest)
        if (stem === undefined) return undefined
        return {
            runDir,
            stem,
            source: file === undefined ? undefined : join(figures.dir, file),
            writable: figures.writable,
        }
    }
    const target = useMemo(
        (): GraphicTarget | undefined => {
            if (figures === undefined || stemHere === undefined || runDir === undefined)
                return undefined
            return {
                runDir,
                stem: stemHere,
                source: fileHere === undefined ? undefined : join(figures.dir, fileHere),
                writable: figures.writable,
            }
        },
        [figures, stemHere, fileHere, runDir],
    )
    // the plots a page turn is likely to show next: made in the background
    const ahead = [plotTab + 1, plotTab - 1, plotTab + 2]
        .map(targetOfTab)
        .filter((t): t is GraphicTarget => t?.source !== undefined)
    const cell = support.cell
    const sixelOn = support.supported && cell !== undefined && mode === "plots"
    const [entry, setEntry] = useCacheEntry(target, sixelOn)
    const graphicFacts = {
        supported: sixelOn,
        hasSource: fileHere !== undefined,
        cached: entry !== undefined,
    }
    const [pick, setPick] = useState<"graphics" | "unicode" | undefined>()
    const graphicsPossible = target !== undefined && canGraphics(graphicFacts)
    const view = target === undefined ? "unicode" : chosenView(graphicFacts, pick)
    const wantGraphics = sixelOn && view === "graphics"
    const cellPx = cell ?? { width: 1, height: 1 }
    const levels = zoomLevels(pixelBox(plotRoom, pageRows, cellPx))
    const [graphicZooms, setGraphicZooms] = useState<Record<number, number>>({})
    const [graphicPans, setGraphicPans] = useState<Record<number, PlotPos>>({})
    const zoomAt = Math.min(graphicZooms[plotTab] ?? 0, levels.length - 1)
    const graphicPan = graphicPans[plotTab] ?? { top: 0, left: 0 }
    const gfx = useGraphicFrame({
        target,
        ahead,
        levels,
        enabled: wantGraphics,
        cell: cellPx,
        columns: plotRoom,
        rows: pageRows,
        zoom: levels[zoomAt] ?? 1,
        pan: graphicPan,
        entry,
        stored: setEntry,
    })
    const showing = wantGraphics && gfx.frame !== undefined
    const graphicMaxLeft =
        gfx.full === undefined ? 0 : maxPanCells(gfx.full.width, plotRoom, cellPx.width)
    const graphicMaxTop =
        gfx.full === undefined ? 0 : maxPanCells(gfx.full.height, pageRows, cellPx.height)
    const graphicLeft = Math.min(graphicPan.left, graphicMaxLeft)
    const graphicTop = Math.min(graphicPan.top, graphicMaxTop)
    const panGraphic = (dTop: number, dLeft: number, absolute = false) =>
        setGraphicPans((s) => ({
            ...s,
            [plotTab]: {
                top: Math.min(
                    graphicMaxTop,
                    Math.max(0, (absolute ? 0 : graphicTop) + dTop),
                ),
                left: Math.min(
                    graphicMaxLeft,
                    Math.max(0, (absolute ? 0 : graphicLeft) + dLeft),
                ),
            },
        }))
    /** A step to a larger (1) or smaller (-1) zoom of the picture; `false` at the end. */
    const zoomGraphic = (dir: 1 | -1): boolean => {
        const next = zoomAt + dir
        if (next < 0 || next >= levels.length) return false
        setGraphicZooms((s) => ({ ...s, [plotTab]: next }))
        setGraphicPans((s) => ({ ...s, [plotTab]: { top: 0, left: 0 } }))
        return true
    }

    // ---- the legend: only the keys that work now (an arrow stops at an edge, the previous
    // tab is missing on the first, the next one on the last); the footer keeps the height
    // of the fullest legend (`legendFull`), so it never moves
    // the moves and pages of the plots mode: the picture's pan, or the pager's
    const plotMove =
        mode !== "plots"
            ? undefined
            : showing
                ? {
                    up: graphicTop > 0,
                    down: graphicTop < graphicMaxTop,
                    left: graphicLeft > 0,
                    right: graphicLeft < graphicMaxLeft,
                }
                : pager.can
    const plotPages =
        mode !== "plots"
            ? undefined
            : showing
                ? { up: graphicTop > 0, down: graphicTop < graphicMaxTop }
                : { up: false, down: false }
    const legend = viewerLegend({
        plots: mode === "plots",
        sheets: names.length,
        active,
        hasPlots: plots.length > 0,
        move: plotMove ?? {
            up: sheet !== undefined && cursor.row > 0,
            down: sheet !== undefined && cursor.row < sheet.rows - 1,
            left: sheet !== undefined && cursor.column > 0,
            right: sheet !== undefined && cursor.column < sheet.columns - 1,
        },
        pages: plotPages ?? {
            up: sheet !== undefined && cursor.row > 0,
            down: sheet !== undefined && cursor.row < sheet.rows - 1,
        },
        zoom: showing
            ? { in: zoomAt < levels.length - 1, out: zoomAt > 0 }
            : { in: sizeAt >= 0 && sizeAt < bySize.length - 1, out: sizeAt > 0 },
        cells:
            mode === "plots"
                ? plotLines.length > 0
                : sheet !== undefined && sheet.rows > 0,
        marked: mode === "plots" ? pager.can.marked : range !== undefined,
        hasFormulas,
        matches: mode === "plots" ? pager.can.matches : found.length > 0,
        graphics: graphicsPossible ? view === "graphics" : undefined,
    })
    const copyLegend = legendOf([
        legendFor("cell", keys.copyCell),
        legendFor("row", keys.copyRow),
        legendFor("column", keys.copyColumn),
        legendFor("cancel", keys.escape),
    ])

    // ---- moves in the sheet
    /** Puts the cursor on a cell, keeping it in view, and forgets nothing else. */
    const place = (row: number, column: number) => {
        if (sheet === undefined) return
        const r = clampIndex(row, sheet.rows)
        const c = clampIndex(column, sheet.columns)
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
        const next = clampIndex(to, names.length)
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

    /** Go to (`shift+j`) took a cell, a row or a column. */
    const submitJump = (text: string) => {
        setAsking(undefined)
        if (sheet === undefined) return
        const to = parseJump(text, cursor, sheet.rows, sheet.columns)
        if ("error" in to) return say(to.error, true)
        place(to.row, to.column)
    }

    // ---- keys
    useKeys((press: KeyInput) => {
        clear()
        if (copying) {
            setCopying(false)
            if (sheet === undefined) return
            const here = { row: cursor.row, column: cursor.column }
            if (press.is(keys.copyCell)) copy({ kind: "range", from: here, to: here })
            else if (press.is(keys.copyRow)) copy({ kind: "row", row: cursor.row })
            else if (press.is(keys.copyColumn))
                copy({ kind: "column", column: cursor.column })
            return
        }
        if (press.is(keys.back)) {
            // blanked BEFORE the screen below is drawn: the unmount cleanup would erase
            // after Ink wrote it and leave the area blank
            hideSixelNow()
            return nav.depth > 1 ? nav.pop() : nav.quit()
        }
        // no plots written: the key does nothing
        if (press.is(keys.plots)) {
            if (plots.length === 0) return
            // the picture is blanked BEFORE the sheet is drawn: the unmount cleanup erases
            // after Ink wrote it and would leave the sheet blank
            hideSixelNow()
            setMode((m) => (m === "plots" ? "sheets" : "plots"))
            return setTabFirst(0)
        }
        // Shift+Tab is tested first: a plain `keys.tab` matches either press
        if (press.is(keys.shiftTab)) return active > 0 && switchTab(active - 1)
        if (press.is(keys.tab)) return active < names.length - 1 && switchTab(active + 1)
        if (press.is(keys.plotType)) {
            // a key the legend does not show does nothing (it is shown with the plots
            // open); once shown, a switch says which view it chose and a refusal why
            if (plots.length === 0 || mode !== "plots") return
            const refusal = graphicsRefusal({
                supported: sixelOn,
                hasFigures: figures !== undefined && runDir !== undefined,
                hasStem: stemHere !== undefined,
                hasSource: fileHere !== undefined,
                cached: entry !== undefined,
            })
            if (refusal !== undefined || !graphicsPossible)
                return say(refusal?.text ?? PLOT_NOT_RENDERED, true)
            if (view === "graphics") hideSixelNow()
            say(view === "graphics" ? "unicode plot" : "graphics view")
            return setPick(view === "graphics" ? "unicode" : "graphics")
        }
        // the page keys are read before the arrows: a plain arrow also matches shift+arrow
        const turn = pageKey(press)
        if (mode === "plots" && showing) {
            // the same keys as the Unicode plot, acting on the picture
            if (turn !== undefined) panGraphic(turn === "down" ? graphicMaxTop : 0, 0, true)
            else if (press.is(keys.zoomIn)) zoomGraphic(1)
            else if (press.is(keys.zoomOut)) zoomGraphic(-1)
            else if (press.is(keys.up)) panGraphic(-1, 0)
            else if (press.is(keys.down)) panGraphic(1, 0)
            else if (press.is(keys.left)) panGraphic(0, -PLOT_STEP)
            else if (press.is(keys.right)) panGraphic(0, PLOT_STEP)
            else if (press.is(keys.home)) panGraphic(0, 0, true)
            else if (press.is(keys.end)) panGraphic(graphicMaxTop, 0, true)
            return
        }
        if (mode === "plots") {
            if (press.is(keys.zoomIn)) zoomTo(+1)
            else if (press.is(keys.zoomOut)) zoomTo(-1)
            else pager.handle(press)
            return
        }
        if (sheet === undefined) return
        const { row, column } = cursor
        if (turn !== undefined)
            return place(row + (turn === "down" ? pageRows : -pageRows), column)
        if (press.is(keys.escape) && range !== undefined) return setMark(undefined)
        if (sheet.rows > 0) {
            if (press.is(keys.find)) return setAsking("find")
            if (press.is(keys.jump)) return setAsking("jump")
            if (press.is(keys.mark))
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
                if (!hasFormulas) return // not in the legend: ignored
                return setShowFormulas((v) => !v)
            }
            if (press.is(keys.prevMatch) || press.is(keys.nextMatch)) {
                if (search === "") return // not in the legend before a search: ignored
                const dir = press.is(keys.prevMatch) ? -1 : 1
                return goToMatch(matchStep(found, row, column, dir))
            }
        }
        if (press.is(keys.up)) place(row - 1, column)
        else if (press.is(keys.down)) place(row + 1, column)
        else if (press.is(keys.left)) place(row, column - 1)
        else if (press.is(keys.right)) place(row, column + 1)
        else if (press.is(keys.home)) place(row, 0)
        else if (press.is(keys.end)) place(row, sheet.columns - 1)
    }, asking === undefined && pager.asking === undefined)

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

    const status = ((): string => {
        if (mode === "plots" && showing)
            return (
                `plot ${plotTab + 1} / ${plots.length} · graphics · ` +
                `zoom ${levels[zoomAt] ?? 1}x`
            )
        if (mode === "plots")
            return plot
                ? `plot ${plotTab + 1} / ${plots.length} · ` +
                    (wantGraphics ? `graphics: ${gfx.error ?? "rendering..."} · ` : "") +
                    (picked ? `${picked.width}x${picked.rows} · ` : "") +
                    pager.status
                : "no plots"
        if (sheet === undefined) return ""
        // a marked range names its rows, so it takes the place of the row counter (the
        // sentence after them must keep its room, `DESCRIPTION_CELLS`)
        const parts = [
            range === undefined
                ? `${cellRef(cursor.row, cursor.column)} · ` +
                    `row ${cursor.row + 1} / ${sheet.fullRows}`
                : `${cellRef(cursor.row, cursor.column)} · ` +
                    `range ${cellRef(range.r0, range.c0)}:${cellRef(range.r1, range.c1)}`,
        ]
        if (search !== "" && sheet.rows > 0)
            parts.push(
                foundAt === undefined
                    ? `${found.length} matches`
                    : `match ${foundAt + 1} / ${found.length}`,
            )
        if (formulasOn) parts.push("formulas")
        if (sheet.fullRows > sheet.rows || sheet.fullColumns > sheet.columns)
            parts.push(
                `cut: ${sheet.rows} of ${sheet.fullRows} rows, ` +
                    `${sheet.columns} of ${sheet.fullColumns} columns`,
            )
        // the column's sentence goes last, cut to the room left, so the rest stays whole
        const line = parts.join(" · ")
        const said = cellDescription(
            sheet.name,
            sheet.cells,
            sheet.header,
            cursor.row,
            cursor.column,
        )
        const room = innerWidth - displayWidth(line) - 3
        return said === undefined || room < 8
            ? line
            : `${line} · ${fitDescription(said, room)}`
    })()

    const failure =
        opened !== undefined && "error" in opened
            ? opened.error
            : loaded !== undefined && "error" in loaded
                ? loaded.error
                : undefined
    const shownNote = copying
        ? {
            text:
                `copy: cell (${keys.copyCell.label}), row (${keys.copyRow.label}), ` +
                `column (${keys.copyColumn.label})?`,
            error: false,
        }
        : (note ?? (failure ? { text: failure, error: true } : undefined))

    return (
        <Frame
            design={design}
            title={title}
            subtitle={subtitle}
            corner={corner}
            legend={asking || pager.asking ? askKeys : copying ? copyLegend : legend}
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
                {mode === "plots" && showing ? (
                    <SixelArea
                        columns={plotRoom}
                        rows={pageRows}
                        cell={cellPx}
                        frame={gfx.frame}
                    />
                ) : mode === "plots" ? (
                    pager.shown.map((line) => (
                        <PagerLine key={line.index} text={line.text} look={line.look} />
                    ))
                ) : sheet === undefined || sheet.rows === 0 ? (
                    <Text color={theme.mt}>
                        {opened === undefined
                            ? "loading…"
                            : (failure ?? "this sheet is empty")}
                    </Text>
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
                {mode === "plots" && pager.asking ? (
                    <PagerPrompt pager={pager} onLegend={setAskKeys} />
                ) : asking ? (
                    <Prompt
                        label={asking === "find" ? "find:" : "go to (B7, row 7, column B):"}
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
