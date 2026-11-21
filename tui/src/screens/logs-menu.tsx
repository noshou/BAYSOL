// SPDX-License-Identifier: LGPL-3.0-or-later

// The logs menu (`logs` of the project menu): the runs of a project, the options of one
// run (views of the run's own files, from its archive or folder, and the restores that put
// its inputs back into the project), and the ONE pager of a run's texts. `open... > open
// runs` (results, plots) is `open-runs.tsx`; its `^l` opens this file's `RunLogScreen`, the
// same screen as `view run.LOG` here.
//
// Contents:
//   1. Layout: the rows the pages give their tables
//   2. The pager: `useRunWatch`, `TextPager` and `RunLogScreen`
//   3. `LogsRun`: the options of one run, the restores
//   4. `LogsRuns`: the list of the runs, the entry of the menu

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useEffect, useMemo, useState } from "react"
import { appDir, LOGS_FLOW } from "../core/environment.js"
import { messageOf } from "../core/file-system.js"
import { clampIndex, displayWidth, superscripts, wrapLine } from "../core/terminal.js"
import { liveRun, type ProjectRef } from "../store/projects.js"
import { RUN_FILES, runExists, warmRunWorkbooks } from "../store/run-archive.js"
import {
    conditionsText,
    listRuns,
    prettyJson,
    RUN_GONE,
    type RunItem,
    type RunRow,
    readLogText,
    readRunFile,
    readStatisticsText,
    runFileSizes,
    runItems,
    sizeText,
} from "../store/run-logs.js"
import {
    bufferFacts,
    restoreBuffer,
    restoreErrorNote,
    restoreSettings,
    restoreUnits,
    watchBuffer,
} from "../store/run-restores.js"
import { runDisplay } from "../store/run-stamp.js"
import { pagerLines } from "../store/view.js"
import { cornerLabels, Frame, footerExtraLines } from "../ui/frame.js"
import {
    cursorMoves,
    type Design,
    type LegendItem,
    legendBack, legendFor, legendOf, moveLegend } from "../ui/grid.js"
import {
    type Question,
    questionLegend,
    shownNote,
    useConfirm,
    useNote,
} from "../ui/input.js"
import {
    keys,
    scrollWindow,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { PagerLine, PagerPrompt, pagerFullLegend, usePager } from "../ui/pager.js"
import { type Column, columnWidths, DataTable, Panel, useTheme } from "../ui/theme.js"

// ========================================================================================
// 1. Layout
// ========================================================================================

/**
 * The `models` cell of the run list: how many models the run had (the names would be cut
 * by the column; `open runs` and `view models` list them).
 *
 * @param models - the names of a run's models.
 * @returns `-` for none, else the count.
 */
export function modelsCell(models: readonly string[]): string {
    return models.length === 0 ? "-" : String(models.length)
}

/** The rows a `DataTable` takes besides its rows: header, rule and the `n / total` line. */
const TABLE_CHROME_ROWS = 3

/** The lines of keys the frame's footer holds without growing (its logo is lower). */
const BASE_LEGEND_LINES = 3

/**
 * The rows of a table of these pages: what is left of the terminal after the frame, the
 * table's own chrome and the lines the fullest legend of the page takes beyond the ones
 * the frame holds (and the blocky box's two rows), so a taller footer never pushes the
 * table.
 *
 * @param full - every key the page can ever show (`Frame`'s `legendFull`).
 * @returns the rows, at least 3.
 */
function useTableRows(full: readonly LegendItem[]): number {
    const columns = useBodyColumns()
    const taller = footerExtraLines(full, columns, BASE_LEGEND_LINES, "blocky")
    return useBodyRows(TABLE_CHROME_ROWS + taller)
}

/** The one key of a page whose content is gone or cannot be shown. */
const _CLOSE: LegendItem = legendFor("close", keys.escape, keys.back)

// ========================================================================================
// 2. The pager: `useRunWatch`, `TextPager` and `RunLogScreen`
// ========================================================================================

/** The keys of the pager, fullest first (the frame reserves their height). */
const PAGER_FULL: LegendItem[] = [
    ...pagerFullLegend(),
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
 * @param close - what closes the page (default: pop it off the screen stack).
 * @returns `true` once the folder was found gone.
 */
function useRunWatch(runDir: string, close?: () => void): boolean {
    const nav = useNav()
    const leave = close ?? nav.pop
    const active = useScreenActive()
    const [gone, setGone] = useState(false)

    useEffect(() => {
        if (!active) return
        const look = (): void => {
            if (!runExists(runDir)) setGone(true)
        }
        look()
        const timer = setInterval(look, LOGS_FLOW.watch.pollSeconds * 1000)
        return () => clearInterval(timer)
    }, [active, runDir])

    useEffect(() => {
        if (!gone || !active) return
        const timer = setTimeout(leave, LOGS_FLOW.watch.closeSeconds * 1000)
        return () => clearTimeout(timer)
    }, [gone, active, leave])

    // any key closes it sooner; the keys of the page itself are off while it is gone
    useKeys(() => leave(), gone)
    return gone
}

/**
 * The read-only pager of the program, ONE for every text of a run: its `run.LOG` (see
 * [[RunLogScreen]]) and every view of the logs menu. The keys are those of [[usePager]]
 * (shift+↓ and PgDn a page down, shift+↑ and PgUp a page up, the arrows a line or
 * sideways, Home and End, find, go to a line, mark and copy); Esc closes (or drops the
 * mark first). The text is read once; a refusal (no file, too large, deleted) is the note,
 * and a run deleted while the page is open closes it with `this run was deleted`.
 *
 * @param props.title - the title of the screen (`logs`).
 * @param props.subtitle - what is shown (`run.LOG`, `settings.json`).
 * @param props.corner - the corner text (`cornerLabel`).
 * @param props.runDir - the run folder, watched for its deletion.
 * @param props.design - `"blocky"` on the logs pages, `"smooth"` when left out.
 * @param props.load - reads the text (it may throw: the message is the note).
 * @param props.counter - the frame's counter (`statistics [2 / 2]`), none when left out.
 * @param props.onClose - what Esc does instead of popping the page (the page of a
 *     screen that has several).
 * @param props.onLeft - what the left arrow does instead of a sideways step (lines are
 *     wrapped, so there is nothing to scroll sideways); with it the legend names `back`.
 * @returns the screen.
 */
export function TextPager(props: {
    title: string
    subtitle: string
    corner: string | readonly string[]
    runDir: string
    load: () => string
    design?: Design
    counter?: string
    onClose?: () => void
    onLeft?: { label: string; run: () => void }
}): ReactNode {
    const { title, subtitle, corner, runDir, load, design = "smooth" } = props
    const { counter, onClose, onLeft } = props
    const nav = useNav()
    const close = onClose ?? nav.pop
    const theme = useTheme()
    const columns = useBodyColumns()
    const gone = useRunWatch(runDir, close)
    const { note, say, clear } = useNote()
    const [askKeys, setAskKeys] = useState<LegendItem[]>([])
    const panel = design === "blocky" ? "double" : "round"
    const width = Math.max(1, columns - PAGER_CHROME_COLUMNS)
    // a line wider than the page continues on the next row, so no text runs off the edge
    // biome-ignore lint/correctness/useExhaustiveDependencies: `load` is read once per page
    const loaded = useMemo((): { lines: string[] } | { error: string } => {
        try {
            const raw = pagerLines(load(), LOGS_FLOW.pager.tabWidth)
            return { lines: raw.flatMap((line) => wrapLine(line, width)) }
        } catch (error) {
            const why = messageOf(error, "cannot read the file")
            return { error: why }
        }
    }, [runDir, width])
    const lines = "lines" in loaded ? loaded.lines : []
    const pageRows = Math.max(
        1,
        useBodyRows(footerExtraLines(PAGER_FULL, columns, BASE_LEGEND_LINES, design)) -
            PAGER_CHROME_ROWS,
    )
    const pager = usePager({
        lines,
        rows: pageRows,
        width,
        overlap: LOGS_FLOW.pager.overlap,
        sideStep: LOGS_FLOW.pager.sideStep,
        say,
    })

    useKeys((press) => {
        if (gone) return
        clear()
        if (onLeft && press.is(keys.left)) {
            onLeft.run()
            return
        }
        if (pager.handle(press)) return
        if (press.is(keys.escape) || press.is(keys.back)) close()
    }, pager.asking === undefined)

    const error = gone ? RUN_GONE : "error" in loaded ? loaded.error : undefined
    const shown = error !== undefined ? { text: error, error: true } : note
    return (
        <Frame
            design={design}
            title={title}
            subtitle={subtitle}
            corner={corner}
            counter={counter}
            legend={
                pager.asking
                    ? askKeys
                    : [
                        ...pager.legend,
                        ...(onLeft ? [legendFor(onLeft.label, keys.left)] : []),
                        legendFor("close", keys.escape, keys.back),
                    ]
            }
            legendFull={onLeft ? [...PAGER_FULL, legendFor("runs", keys.left)] : PAGER_FULL}
            note={shown?.text}
            noteIsError={shown?.error}
        >
            <Panel style={panel} paddingX={1} flexDirection="column" flexGrow={1}>
                {pager.shown.map((line) => (
                    <PagerLine key={line.index} text={line.text} look={line.look} />
                ))}
                <Box flexGrow={1} />
                {pager.asking ? (
                    <PagerPrompt pager={pager} onLegend={setAskKeys} />
                ) : (
                    <Text color={theme.mt} wrap="truncate-end">
                        {pager.status}
                    </Text>
                )}
            </Panel>
        </Frame>
    )
}

/**
 * The `run.LOG` of a run: the ONE screen both `open runs` (`^l`) and `logs > view run.LOG`
 * open, the logs menu's pager page.
 *
 * @param props.projectId - the project, for the corner.
 * @param props.runId - the run, for the corner.
 * @param props.runDir - the run folder.
 * @returns the screen.
 */
export function RunLogScreen(props: {
    projectId: string
    runId: string
    runDir: string
}): ReactNode {
    const { projectId, runId, runDir } = props
    return (
        <TextPager
            design="blocky"
            title="logs"
            subtitle="run.LOG"
            corner={cornerLabels(projectId, runId)}
            runDir={runDir}
            load={() => readLogText(runDir)}
        />
    )
}

// ========================================================================================
// 3. The options of a run
// ========================================================================================

/** The fullest legend of the options page: the frame reserves its height. */
const RUN_FULL: LegendItem[] = [
    legendFor("move", [keys.up, keys.down]),
    legendFor("choose", keys.enter),
    legendBack,
]

/**
 * The question before a restore replaces what the project has. Short, and the same shape
 * as every other question; the buffer's names the pH and σ it brings.
 *
 * @param item - the restore option.
 * @param detail - what the file brings, e.g. `pH 7.4, σ 0.1` (buffer), else none.
 * @returns the question.
 */
function replaceQuestion(item: RunItem, detail?: string): Question {
    const what: Record<string, string> = {
        settings: "settings",
        buffer: "buffer",
        data: "data",
        units: "units and energy",
    }
    const name = what[item.restore ?? ""] ?? "it"
    const text = detail ? `replace ${name} (${detail})?` : `replace ${name}?`
    return { text, yes: "replace", no: "keep" }
}

/**
 * The words for the pH and σ of a buffer file, for its question.
 *
 * @param facts - what [[bufferFacts]] found.
 * @returns `pH 7.4, σ 0.1`, or `no pH` for a buffer without conditions.
 */
function conditionsDetail(facts: ReturnType<typeof bufferFacts>): string {
    const { conditions } = facts
    return conditions === undefined
        ? "no pH"
        : `pH ${conditions.pH}, σ ${conditions.sigmaPh}`
}

/**
 * The page of one run: a list of what can be done with it, each a view (`run.LOG`,
 * settings, buffer, data, units and energy, conditions, solutes, models, plots) or a
 * restore (settings, buffer, data, units: put the run's own copy back into the project).
 * Views open the shared pager or, for the data table, the sheet viewer. A restore reads
 * the run's copy, asks the short replace question and writes through the store of the
 * file; it is refused while a run of the project is live. `^r` deletes the whole run after
 * the usual question. Nothing is ever written into the run. A run deleted by another copy
 * closes the page.
 *
 * @param props.project - the project.
 * @param props.run - the run (its row of the list).
 * @returns the screen.
 */
function LogsRun({ project, run }: { project: ProjectRef; run: RunRow }): ReactNode {
    const nav = useNav()
    const active = useScreenActive()
    const columns = useBodyColumns()
    const gone = useRunWatch(run.dir)
    const confirm = useConfirm()
    const [sizes, setSizes] = useState(() => runFileSizes(run.dir))
    const [selected, setSelected] = useState(0)
    const [offset, setOffset] = useState(0)
    const { note, say, clear } = useNote()

    // a live run writes its files while the page is open: the sizes are read again
    useEffect(() => {
        if (!active) return
        const look = (): void => setSizes(runFileSizes(run.dir))
        look()
        const timer = setInterval(look, LOGS_FLOW.watch.pollSeconds * 1000)
        return () => clearInterval(timer)
    }, [active, run.dir])

    // the workbooks that only the archive holds are made in the background, so that a
    // view of one finds its copy ready
    useEffect(() => {
        if (active) void warmRunWorkbooks(run.dir)
    }, [active, run.dir])

    const pageSize = useTableRows(RUN_FULL)
    const index = Math.min(selected, runItems.length - 1)
    const top = scrollWindow(index, offset, pageSize, runItems.length)
    const item = runItems[index] as RunItem

    const table: Column<RunItem>[] = [
        { title: "option", text: (r) => r.label },
        { title: "file", width: LOGS_FLOW.options.fileWidth, text: (r) => r.file },
        {
            title: "size",
            width: LOGS_FLOW.options.sizeWidth,
            align: "right",
            text: (r) => {
                const size = sizes.get(r.file)
                return size === undefined ? "-" : sizeText(size)
            },
        },
    ]

    /** Opens a view; the `run.LOG` is the one screen `open runs` opens too. */
    const open = (it: RunItem): void => {
        if (it.file === RUN_FILES.log) {
            nav.push(
                <RunLogScreen projectId={project.id} runId={run.id} runDir={run.dir} />,
            )
            return
        }
        const load = (): string => {
            const text = readRunFile(run.dir, it.file)
            // superscripts are display only: the restore path reads the raw text
            if (it.action === "conditions") return superscripts(conditionsText(text))
            return superscripts(it.json ? prettyJson(text) : text)
        }
        nav.push(
            <TextPager
                design="blocky"
                title="logs"
                subtitle={it.action === "conditions" ? "conditions" : it.file}
                corner={cornerLabels(project.id, run.id)}
                runDir={run.dir}
                load={load}
            />,
        )
    }

    /** Reads what a restore needs, asks the replace question and, on Enter, writes. */
    const restore = (it: RunItem): void => {
        try {
            const text = readRunFile(run.dir, it.file)
            let detail: string | undefined
            if (it.restore === "buffer") {
                detail = conditionsDetail(bufferFacts(text))
                watchBuffer(project.dir)
            }
            confirm.ask(replaceQuestion(it, detail), () => {
                try {
                    if (it.restore === "settings")
                        restoreSettings(project.dir, appDir(), text)
                    else if (it.restore === "buffer")
                        restoreBuffer(project.dir, text)
                    else restoreUnits(project.dir, text)
                    say(`${it.restore} restored`)
                } catch (error) {
                    say(restoreErrorNote(error), true)
                }
            })
        } catch (error) {
            say(messageOf(error, "could not read the run"), true)
        }
    }

    useKeys((press) => {
        if (gone || confirm.handleKey(press)) return
        clear()
        if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
        else if (press.is(keys.up)) {
            setSelected(Math.max(0, index - 1))
            setOffset(top)
        } else if (press.is(keys.down)) {
            setSelected(Math.min(runItems.length - 1, index + 1))
            setOffset(top)
        } else if (press.is(keys.enter)) {
            const live = liveRun(project.dir)
            if (item.action === "restore" && live !== undefined)
                say(`a run is in progress (pid ${live.pid})`, true)
            else if (!runFileSizes(run.dir).has(item.file))
                say(`${item.file} is not in this run`, true)
            else if (item.action === "restore") restore(item)
            else open(item)
        }
    })

    const keysNow = legendOf([
        moveLegend(cursorMoves(index, runItems.length)),
        legendFor("choose", keys.enter),
        legendBack,
    ])
    const legend = confirm.question ? questionLegend(confirm.question) : keysNow
    // what the note row says, most urgent first
    let shown = shownNote(confirm, note)
    if (gone) shown = { text: RUN_GONE, error: true }
    return (
        <Frame
            design="blocky"
            title="logs"
            subtitle="options"
            corner={cornerLabels(project.id, run.id)}
            counter={
                confirm.question ? undefined : `options [${index + 1} / ${runItems.length}]`
            }
            legend={legend}
            legendFull={RUN_FULL}
            note={shown?.text}
            noteIsError={shown?.error}
        >
            <DataTable
                border="double"
                columns={table}
                rows={[...runItems]}
                cursor={index}
                offset={top}
                pageSize={pageSize}
                width={columns}
            />
        </Frame>
    )
}

// ========================================================================================
// 4. The list of the runs
// ========================================================================================

/** The fullest legend of the list: the frame reserves its height. */
const RUNS_FULL: LegendItem[] = [
    legendFor("move", [keys.up, keys.down]),
    legendFor("open", keys.enter),
    legendFor("statistics", keys.right),
    legendBack,
]

/**
 * The mark in front of a run: `*` for a live run, `!` for an interrupted one.
 *
 * @param run - the run.
 * @returns the one character, a space for the others.
 */
function runMark(run: RunRow): string {
    return run.live ? "*" : run.state === "interrupted" ? "!" : " "
}

/**
 * The runs of a project (`logs` in the project menu), newest first: the stamp, how the run
 * ended (`live` for one that is running now, `interrupted` for one nobody runs any more,
 * `unknown` for a `run.json` that cannot be read), its models and its size. The list is
 * read again every few seconds and whenever the page comes back to the top, so a run that
 * ends, starts or is deleted by another copy shows. Enter opens a run's options, `^r`
 * deletes the whole run after the usual question (refused while a run of the project is
 * live). `project: <name>` is in the corner.
 *
 * @param props.project - the project.
 * @returns the screen.
 */
export function LogsRuns({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const active = useScreenActive()
    const columns = useBodyColumns()
    const confirm = useConfirm()
    const [runs, setRuns] = useState<RunRow[]>(() => listRuns(project.dir))
    // the highlighted run is kept by NAME, so a list that changes under it keeps the cursor
    const [selectedId, setSelectedId] = useState<string | undefined>(runs[0]?.id)
    const [offset, setOffset] = useState(0)
    // page 1 is the list, page 2 the statistics of the highlighted run (left and right
    // switch, as the groups of a settings sheet do)
    const [page, setPage] = useState(0)
    const { note, clear } = useNote()

    const refresh = useCallback(() => setRuns(listRuns(project.dir)), [project.dir])
    useEffect(() => {
        if (!active) return
        refresh()
        const timer = setInterval(refresh, LOGS_FLOW.watch.pollSeconds * 1000)
        return () => clearInterval(timer)
    }, [active, refresh])

    const pageSize = useTableRows(RUNS_FULL)
    const index = Math.max(
        runs.findIndex((r) => r.id === selectedId),
        0,
    )
    const top = scrollWindow(index, offset, pageSize, runs.length)
    const current = runs[index]

    const flow = LOGS_FLOW.list
    const tableFor = (stampWidth: number): Column<RunRow>[] => [
        { title: "run", width: stampWidth, text: (r) => runDisplay(r.id) },
        { title: "status", width: flow.statusWidth, text: (r) => r.state },
        { title: "models", text: (r) => modelsCell(r.models) },
        {
            title: "size",
            width: flow.sizeWidth,
            align: "right",
            text: (r) => sizeText(r.size),
        },
    ]
    // a long zone label (`Istanbul`, `SãoPaulo`) widens the run column, as far as the
    // terminal allows (the models column keeps its title's width)
    const spare = (columnWidths(tableFor(0), columns)[2] ?? 0) - displayWidth("models")
    const wanted = Math.max(...runs.map((r) => displayWidth(runDisplay(r.id))))
    const table = tableFor(Math.max(flow.stampWidth, Math.min(wanted, spare)))

    const step = (to: number): void => {
        setSelectedId(runs[clampIndex(to, runs.length)]?.id)
        setOffset(top)
    }

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        clear()
        if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
        else if (press.is(keys.up)) step(index - 1)
        else if (press.is(keys.down)) step(index + 1)
        else if (current === undefined) return
        else if (press.is(keys.right)) setPage(1)
        else if (press.is(keys.enter)) nav.push(<LogsRun project={project} run={current} />)
    }, page === 0)

    if (page === 1 && current !== undefined) {
        return (
            <TextPager
                key={current.id}
                design="blocky"
                title="logs"
                subtitle="statistics"
                corner={cornerLabels(project.id, current.id)}
                counter="statistics [2 / 2]"
                runDir={current.dir}
                load={() => readStatisticsText(current.dir)}
                onClose={() => setPage(0)}
                onLeft={{ label: "runs", run: () => setPage(0) }}
            />
        )
    }

    const keysNow = legendOf([
        moveLegend(cursorMoves(index, runs.length)),
        current !== undefined && legendFor("open", keys.enter),
        current !== undefined && legendFor("statistics", keys.right),
        legendBack,
    ])
    const legend = confirm.question ? questionLegend(confirm.question) : keysNow
    const shown = shownNote(confirm, note)
    return (
        <Frame
            design="blocky"
            title="logs"
            subtitle="runs"
            corner={cornerLabels(project.id)}
            counter={runs.length > 0 && !confirm.question ? "runs [1 / 2]" : undefined}
            legend={legend}
            legendFull={RUNS_FULL}
            note={shown?.text}
            noteIsError={shown?.error}
        >
            <DataTable
                border="double"
                columns={table}
                rows={runs}
                cursor={index}
                offset={top}
                pageSize={pageSize}
                width={columns}
                mark={runMark}
                empty="no runs yet"
            />
        </Frame>
    )
}
