// SPDX-License-Identifier: LGPL-3.0-or-later

// `open runs`, the screen of the project menu that leads to the file viewer, and the pager
// of a run's `run.LOG` (one pager for every text of a run, with the run watch it needs).
//
// Contents:
//   1. The rows of the list: keys, notes and the text of a row
//   2. The pager: `useRunWatch` and `TextPager`
//   3. `OpenRuns`: the runs of a project and the viewer on a done model

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useEffect, useMemo, useState } from "react"
import { LOGS_FLOW } from "../core/environment.js"
import { isFolder } from "../core/file-system.js"
import { displayWidth, padWidth, truncate, wrapLine } from "../core/terminal.js"
import {
    compilePlots,
    movePlots,
    type PlotUnit,
    plotRoot,
    plotUnit,
} from "../store/plots.js"
import { liveRun, type ProjectRef, runBrief, runDisplay } from "../store/projects.js"
import {
    deleteRun,
    failedNote,
    listOpenRuns,
    type OpenModel,
    type OpenRow,
    type OpenRun,
    openRows,
    RUN_GONE,
    readLogText,
} from "../store/run-logs.js"
import { loadScope, projectScope } from "../store/settings-store.js"
import {
    clampTop,
    lastTop,
    pagerLines,
    pagerStatus,
    pageTop,
    sliceCells,
} from "../store/view.js"
import { cornerLabels, Frame, legendRoom } from "../ui/frame.js"
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
    keys,
    ListText,
    scrollWindow,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { Panel, useTheme } from "../ui/theme.js"
import { legendExtraRows, SheetViewerScreen } from "./viewer.js"

// ========================================================================================
// 1. The rows of the list
// ========================================================================================

// `open... > open runs` of the project menu: the runs and their models, the viewer above on
// a model's results, `^r` to delete a run and `l` to read its `run.LOG`.

/** The keys `OpenRuns` can ever show: the frame reserves their height. */
const OPEN_FULL: LegendItem[] = [
    legendFor("move", [keys.up, keys.down]),
    legendFor("open", keys.enter),
    legendFor("run.LOG", keys.showLog),
    legendFor("move plots", keys.movePlots),
    legendFor("compile plots", keys.compilePlots),
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
 * @param room - the cells of the note row; only the model's name is cut to fit it.
 * @returns the note, short: a failed model's error is `briefError`.
 */
export function noWorkbookNote(model: OpenModel, room = Number.POSITIVE_INFINITY): string {
    if (model.state === "running" || model.state === "pending")
        return `${model.name} is still running`
    if (model.state === "failed") return failedNote(model.name, model.error, room)
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

// ========================================================================================
// 2. The pager
// ========================================================================================

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
    corner: string | readonly string[]
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
    const width = Math.max(1, columns - PAGER_CHROME_COLUMNS)
    // a line wider than the page continues on the next row, so no text runs off the edge
    // biome-ignore lint/correctness/useExhaustiveDependencies: `load` is read once per page
    const loaded = useMemo((): { lines: string[] } | { error: string } => {
        try {
            const raw = pagerLines(load(), LOGS_FLOW.pager.tabWidth)
            return { lines: raw.flatMap((line) => wrapLine(line, width)) }
        } catch (error) {
            const why = error instanceof Error ? error.message : "cannot read the file"
            return { error: why }
        }
    }, [runDir, width])
    const lines = "lines" in loaded ? loaded.lines : []
    const pageRows = Math.max(
        1,
        useBodyRows(legendExtraRows(PAGER_FULL, columns, design)) - PAGER_CHROME_ROWS,
    )
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

// ========================================================================================
// 3. OpenRuns
// ========================================================================================

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
    // what a plots action is doing (`compiling plots...`); the keys wait while it does
    const [busy, setBusy] = useState<string | undefined>()

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
    // the cells of the note row of this (smooth) footer
    const noteRoom = legendRoom("smooth", columns)
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
        confirm.ask(destructiveQuestion(`run ${runBrief(run.id)}`), () => {
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

    /**
     * `shift+m` / `shift+c`: move or compile the plots of the highlighted
     * model or comparison, into the plot folder. A failure is the note, which stays until
     * the next key.
     */
    const plotsAction = (what: "move" | "compile"): void => {
        if (current === undefined) return
        const { run } = current
        const here = current.kind === "run" ? [] : [current.model]
        const units: PlotUnit[] = here.map((m) => plotUnit(project.dir, run, m))
        setBusy(what === "move" ? "moving plots..." : "compiling plots...")
        void (async () => {
            try {
                const { settings } = loadScope(projectScope(project))
                const root = plotRoot(settings.get("FIGURES_DIR"))
                const compiler = settings.get("FIGURES_COMPILER")
                const text =
                    what === "move"
                        ? await movePlots(units, root, noteRoom)
                        : await compilePlots(units, root, compiler, noteRoom)
                setNote({ text, error: false })
            } catch (error) {
                const text = error instanceof Error ? error.message : "the plots failed"
                setNote({ text, error: true })
            } finally {
                setBusy(undefined)
            }
        })()
    }

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        if (busy !== undefined) {
            // a plots action is running: only leaving works (it finishes on its own)
            if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
            return
        }
        setNote(undefined)
        if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
        else if (press.is(keys.up)) step(stop - 1)
        else if (press.is(keys.down)) step(stop + 1)
        else if (current === undefined) return
        else if (press.is(keys.remove)) askDelete(current.run)
        else if (press.is(keys.movePlots)) plotsAction("move")
        else if (press.is(keys.compilePlots)) plotsAction("compile")
        else if (press.is(keys.showLog))
            nav.push(
                <TextPager
                    title="open"
                    subtitle="run.LOG"
                    corner={cornerLabels(project.id, current.run.id)}
                    runDir={current.run.dir}
                    load={() => readLogText(current.run.dir)}
                />,
            )
        else if (press.is(keys.enter)) {
            if (current.kind === "run")
                return setNote({
                    text: `${runBrief(current.run.id)} has no models`,
                    error: false,
                })
            const { run, model } = current
            if (model.workbook === undefined)
                return setNote({ text: noWorkbookNote(model, noteRoom), error: false })
            nav.push(
                <SheetViewerScreen
                    workbookPath={model.workbook}
                    plotsPath={model.plots}
                    plotFiles={model.plotSizes}
                    runDir={run.dir}
                    title={current.kind === "compare" ? "comparison" : "results"}
                    subtitle={current.kind === "compare" ? undefined : model.name}
                    corner={cornerLabels(project.id, run.id)}
                />,
            )
        }
    })

    // the plots actions are offered where there are figures to take
    const hasTex =
        current !== undefined && current.kind !== "run" && current.model.tex.length > 0
    const legend = confirm.question
        ? questionLegend(confirm.question)
        : legendOf([
            moveLegend({ up: stop > 0, down: stop < stops.length - 1 }),
            current !== undefined && legendFor("open", keys.enter),
            current !== undefined && legendFor("run.LOG", keys.showLog),
            current !== undefined && legendFor("delete run", keys.remove),
            hasTex && legendFor("move plots", keys.movePlots),
            hasTex && legendFor("compile plots", keys.compilePlots),
            legendBack,
        ])
    // a model with settings of its own says which, when nothing else is to be said
    const own = current?.kind === "model" ? current.model.overrides : []
    const hint =
        own.length > 0
            ? { text: truncate(`overrides: ${own.join(", ")}`, noteRoom), error: false }
            : undefined
    const shown =
        confirm.note !== undefined
            ? { text: confirm.note, error: false }
            : busy !== undefined
                ? { text: busy, error: false }
                : (note ?? hint)
    return (
        <Frame
            title="open"
            subtitle="runs"
            corner={cornerLabels(project.id)}
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
