// SPDX-License-Identifier: LGPL-3.0-or-later

// The logs menu (`logs` of the project menu): the runs of a project, the options of one
// run (views of the run's own files, from its archive or folder, and the restores that put
// its inputs back into the project). `open... > open runs` (results, plots, `run.LOG`) is
// `open-runs.tsx`, whose pager these pages reuse.
//
// Contents:
//   1. Layout: the rows the pages give their tables
//   2. `LogsRun`: the options of one run, the restores
//   3. `LogsRuns`: the list of the runs, the entry of the menu

import { type ReactNode, useCallback, useEffect, useState } from "react"
import { appDir, LOGS_FLOW } from "../core/environment.js"
import { displayWidth } from "../core/terminal.js"
import { liveRun, type ProjectRef } from "../store/projects.js"
import {
    bufferFacts,
    conditionsText,
    listRuns,
    prettyJson,
    RUN_GONE,
    type RunItem,
    type RunRow,
    readRunFile,
    restoreBuffer,
    restoreErrorNote,
    restoreSettings,
    restoreUnits,
    runFileSizes,
    runItems,
    sizeText,
    watchBuffer,
} from "../store/run-logs.js"
import { runDisplay } from "../store/run-stamp.js"
import { cornerLabels, Frame, footerExtraLines } from "../ui/frame.js"
import { type LegendItem, legendBack, legendFor, legendOf, moveLegend } from "../ui/grid.js"
import {
    type Question,
    questionLegend,
    useConfirm,
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
import { type Column, columnWidths, DataTable } from "../ui/theme.js"
import { TextPager, useRunWatch } from "./open-runs.js"

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

/** What a page says on its note row: the text and whether it is an error. */
type Note = { text: string; error: boolean }

/**
 * The text of an error for a note row.
 *
 * @param error - what was thrown.
 * @param fallback - what to say for an error without a message.
 * @returns the message.
 */
function messageOf(error: unknown, fallback: string): string {
    return error instanceof Error && error.message !== "" ? error.message : fallback
}

/** The one key of a page whose content is gone or cannot be shown. */
const _CLOSE: LegendItem = legendFor("close", keys.escape, keys.back)

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
        : `pH ${conditions.pH}, σ ${conditions["sigma-pH"]}`
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
    const [note, setNote] = useState<Note | undefined>()
    const say = (text: string, error = false): void => setNote({ text, error })

    // a live run writes its files while the page is open: the sizes are read again
    useEffect(() => {
        if (!active) return
        const look = (): void => setSizes(runFileSizes(run.dir))
        look()
        const timer = setInterval(look, LOGS_FLOW.watch.pollSeconds * 1000)
        return () => clearInterval(timer)
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

    /** Opens a view. */
    const open = (it: RunItem): void => {
        const load = (): string => {
            const text = readRunFile(run.dir, it.file)
            if (it.action === "conditions") return conditionsText(text)
            return it.json ? prettyJson(text) : text
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
                    else if (it.restore === "buffer") restoreBuffer(project.dir, text)
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
        setNote(undefined)
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
        moveLegend({ up: index > 0, down: index < runItems.length - 1 }),
        legendFor("choose", keys.enter),
        legendBack,
    ])
    const legend = confirm.question ? questionLegend(confirm.question) : keysNow
    // what the note row says, most urgent first
    let shown = note
    if (confirm.note !== undefined) shown = { text: confirm.note, error: false }
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
    const [note, setNote] = useState<Note | undefined>()

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
        setSelectedId(runs[Math.min(Math.max(to, 0), runs.length - 1)]?.id)
        setOffset(top)
    }

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        setNote(undefined)
        if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
        else if (press.is(keys.up)) step(index - 1)
        else if (press.is(keys.down)) step(index + 1)
        else if (current === undefined) return
        else if (press.is(keys.enter)) nav.push(<LogsRun project={project} run={current} />)
    })

    const keysNow = legendOf([
        moveLegend({ up: index > 0, down: index < runs.length - 1 }),
        current !== undefined && legendFor("open", keys.enter),
        legendBack,
    ])
    const legend = confirm.question ? questionLegend(confirm.question) : keysNow
    const shown = confirm.note !== undefined ? { text: confirm.note, error: false } : note
    return (
        <Frame
            design="blocky"
            title="logs"
            subtitle="runs"
            corner={cornerLabels(project.id)}
            counter={
                runs.length > 0 && !confirm.question
                    ? `runs [${index + 1} / ${runs.length}]`
                    : undefined
            }
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
