// SPDX-License-Identifier: LGPL-3.0-or-later

// `open runs`, the screen of the project menu that leads to the file viewer. A run's
// `run.LOG` (`^l`) is the logs menu's `RunLogScreen` (`logs-menu.tsx`, the one pager).
//
// Contents:
//   1. The rows of the list: keys, notes and the text of a row
//   2. `OpenRuns`: the runs of a project and the viewer on a done model

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useEffect, useMemo, useState } from "react"
import { LOGS_FLOW } from "../core/environment.js"
import { messageOf } from "../core/file-system.js"
import { clampIndex, displayWidth, padWidth, truncate } from "../core/terminal.js"
import {
    figurePairs,
    listRendered,
    mayRender,
    unrenderedTex,
} from "../store/plot-graphics.js"
import {
    compilePlots,
    dataRoot,
    type MoveKind,
    moveFiles,
    type PlotUnit,
    plotRoot,
    plotUnit,
    runFolder,
} from "../store/plots.js"
import { liveRun, type ProjectRef } from "../store/projects.js"
import { warmRunWorkbooks } from "../store/run-archive.js"
import {
    deleteRun,
    failedNote,
    listOpenRuns,
    type OpenModel,
    type OpenRow,
    type OpenRun,
    openRows,
    runModels,
} from "../store/run-logs.js"
import { runBrief, runDisplay } from "../store/run-stamp.js"
import { loadScope, projectScope } from "../store/settings-store.js"
import { cornerLabels, Frame, legendRoom } from "../ui/frame.js"
import {
    cursorMoves,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import {
    DROPDOWN_CHROME,
    Dropdown,
    destructiveQuestion,
    filterChoices,
    questionLegend,
    shownNote,
    suggestionLines,
    useConfirm,
    useNote,
} from "../ui/input.js"
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
import { ErrorText, useTheme } from "../ui/theme.js"
import { RunLogScreen } from "./logs-menu.js"
import { SheetViewerScreen } from "./viewer.js"

// ========================================================================================
// 1. The rows of the list
// ========================================================================================

// `open... > open runs` of the project menu: the runs and their models, the viewer above on
// a model's results, `^r` to delete a run and `^l` to read its `run.LOG`.

/** The keys `OpenRuns` can ever show: the frame reserves their height. */
const OPEN_FULL: LegendItem[] = [
    legendFor("move", [keys.up, keys.down]),
    legendFor("open", keys.enter),
    legendFor("run.LOG", keys.showLog),
    legendFor("move data", keys.moveData),
    legendFor("move tex plots", keys.moveTex),
    legendFor("compile plots", keys.compilePlots),
    legendFor("delete run", keys.remove),
    legendBack,
]

/** The first choice of the dropdown of a move: every model and the comparison. */
const MOVE_ALL = "move all"

/** The choices of a move: the whole run, then one model (or the comparison) each. */
export function moveChoices(
    models: readonly OpenModel[],
): { label: string; value: string | null }[] {
    return [
        { label: MOVE_ALL, value: null },
        ...models.map((m) => ({ label: `move by model: ${m.name}`, value: m.name })),
    ]
}

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
// 2. OpenRuns
// ========================================================================================

/**
 * The display of `open... > open runs`: the runs of the project, newest first, and their
 * models. A run with several models is a heading with its models under it; a run with one
 * model is that one row; a run with none is a row of its own. Enter on a model that is done
 * opens the read-only viewer on its results workbook (with the model's `plots.txt` behind
 * `shift+p`, the comparison too); on any other model the note says why there is
 * nothing to open. `^l` shows the run's `run.LOG` (the logs menu's [[RunLogScreen]]);
 * `^r` deletes the whole run folder after the usual question (refused
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
    const { note, say, clear } = useNote()
    // what a plots action is doing (`compiling plots...`); the keys wait while it does
    const [busy, setBusy] = useState<string | undefined>()
    // bumped when plots were rendered: the "render plots" gate is read again
    const [renderTick, setRenderTick] = useState(0)

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
    // the highlighted run's workbooks that only its archive holds are made in the
    // background, so that opening one finds the copy ready
    const warmDir = current?.run.dir
    useEffect(() => {
        if (active && warmDir !== undefined) void warmRunWorkbooks(warmDir)
    }, [active, warmDir])
    // `shift+d` / `shift+l` open a dropdown under the list: the whole run, or one model
    const [moving, setMoving] = useState<MoveKind | undefined>()
    const [moveKeys, setMoveKeys] = useState<LegendItem[]>([])
    const withFiles = (what: MoveKind, run: OpenRun): OpenModel[] =>
        runModels(run).filter((m) => (what === "tex" ? m.tex.length > 0 : m.workbook))
    const choices =
        moving === undefined || current === undefined
            ? []
            : moveChoices(withFiles(moving, current.run))
    const lines = Math.min(choices.length, suggestionLines)
    const reserved = moving === undefined ? 0 : lines + DROPDOWN_CHROME
    const pageSize = Math.max(3, useBodyRows() - reserved)
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
        const i = stops[clampIndex(to, stops.length)]
        if (i !== undefined) setSelected(rowKey(rows[i] as OpenRow))
        setOffset(top)
    }

    /** `^r`: refuse a live run, else ask and, on Enter, delete the whole run folder. */
    const askDelete = (run: OpenRun): void => {
        const live = liveRun(project.dir)
        if (live !== undefined) {
            say(`a run is in progress (pid ${live.pid})`, true)
            return
        }
        confirm.ask(destructiveQuestion(`run ${runBrief(run.id)}`), () => {
            try {
                deleteRun(project.dir, run.id)
                say("run deleted")
            } catch (error) {
                say(messageOf(error, "could not delete"), true)
            }
            refresh()
        })
    }

    /**
     * Moves the data (`shift+d`) or the tex plots (`shift+l`) of some models of the run,
     * or compiles the plots of the highlighted row (`shift+c`): into the folder of the
     * setting, in a folder of the run's name. A failure is the note (until the next key).
     *
     * @param what - `data`, `tex` or `compile`.
     * @param models - the models (and comparison) to take.
     */
    const filesAction = (
        what: MoveKind | "compile",
        models: readonly OpenModel[],
    ): void => {
        if (current === undefined) return
        const { run } = current
        const units: PlotUnit[] = models.map((m) => plotUnit(project.dir, run, m))
        setBusy(
            what === "data"
                ? "moving data..."
                : what === "tex"
                    ? "moving plots..."
                    : "compiling plots...",
        )
        void (async () => {
            try {
                const { settings } = loadScope(projectScope(project))
                const compiler = settings.get("FIGURES_COMPILER")
                const root = plotRoot(settings.get("FIGURES_DIR"))
                // plots are rendered exactly once: only the figures with no render yet
                const todo = units
                    .map((u) => ({
                        ...u,
                        tex: unrenderedTex(u, listRendered(runFolder(root, u))),
                    }))
                    .filter((u) => u.tex.length > 0)
                if (what === "compile" && todo.length === 0)
                    throw new Error("plots are already rendered")
                const text =
                    what === "compile"
                        ? await compilePlots(
                            todo,
                            root,
                            compiler,
                            noteRoom,
                        )
                        : await moveFiles(
                            what,
                            units,
                            what === "data"
                                ? dataRoot(settings.get("TABLE_DIR"))
                                : plotRoot(settings.get("FIGURES_DIR")),
                            noteRoom,
                        )
                say(text)
            } catch (error) {
                say(messageOf(error, "the plots failed"), true)
            } finally {
                setBusy(undefined)
                setRenderTick((t) => t + 1)
            }
        })()
    }

    /** The plot folder of the project's settings, or `undefined` if they cannot be read. */
    const figureRoot = (): string | undefined => {
        try {
            return plotRoot(loadScope(projectScope(project)).settings.get("FIGURES_DIR"))
        } catch {
            return undefined
        }
    }

    const moveChosen = (name: string | null): void => {
        const what = moving
        setMoving(undefined)
        if (what === undefined || current === undefined) return
        const models = withFiles(what, current.run)
        filesAction(what, name === null ? models : models.filter((m) => m.name === name))
    }

    /** Opens the dropdown of a move, or says there is nothing to move. */
    const openMove = (what: MoveKind, run: OpenRun): void => {
        if (withFiles(what, run).length > 0) {
            setMoving(what)
            return
        }
        say(what === "tex" ? "no plots (.tex) to move" : "no data to move", true)
    }

    useKeys((press) => {
        if (moving !== undefined) return
        if (confirm.handleKey(press)) return
        if (busy !== undefined) {
            // a plots action is running: only leaving works (it finishes on its own)
            if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
            return
        }
        clear()
        if (press.is(keys.back) || press.is(keys.escape)) nav.pop()
        else if (press.is(keys.up)) step(stop - 1)
        else if (press.is(keys.down)) step(stop + 1)
        else if (current === undefined) return
        else if (press.is(keys.remove)) askDelete(current.run)
        // a capital press matches the plain key too, so the capitals are tested first
        else if (press.is(keys.moveData)) openMove("data", current.run)
        else if (press.is(keys.moveTex)) openMove("tex", current.run)
        else if (press.is(keys.compilePlots)) {
            if (current.kind !== "run" && !renderable)
                return say("plots are already rendered")
            filesAction("compile", current.kind === "run" ? [] : [current.model])
        }
        else if (press.is(keys.showLog))
            nav.push(
                <RunLogScreen
                    projectId={project.id}
                    runId={current.run.id}
                    runDir={current.run.dir}
                />,
            )
        else if (press.is(keys.enter)) {
            if (current.kind === "run")
                return say(`${runBrief(current.run.id)} has no models`)
            const { run, model } = current
            if (model.workbook === undefined)
                return say(noWorkbookNote(model, noteRoom))
            // the comparison has plots too: its terminal plots and figures, like a model's
            const compare = current.kind === "compare"
            const root = figureRoot()
            const unit = plotUnit(project.dir, run, model)
            const figures =
                root === undefined || model.tex.length === 0
                    ? undefined
                    : {
                        dir: runFolder(root, unit),
                        pairs: figurePairs(unit),
                        writable: run.state !== "live",
                    }
            nav.push(
                <SheetViewerScreen
                    workbookPath={model.workbook}
                    plotsPath={model.plots}
                    plotFiles={model.plotSizes}
                    runDir={run.dir}
                    figures={figures}
                    title={compare ? "comparison" : "results"}
                    subtitle={compare ? undefined : model.name}
                    corner={cornerLabels(project.id, run.id)}
                />,
            )
        }
    })

    // the file actions are offered where there is something to take
    const here = current !== undefined && current.kind !== "run" ? current.model : undefined
    const hasTex = here !== undefined && here.tex.length > 0
    // "render plots" only while figures are missing (read again after each render)
    // biome-ignore lint/correctness/useExhaustiveDependencies: renderTick is the trigger
    const renderable = useMemo(() => {
        if (here === undefined || here.tex.length === 0) return false
        if (current === undefined) return false
        const root = figureRoot()
        if (root === undefined) return false
        return mayRender(plotUnit(project.dir, current.run, here), root)
    }, [here, current, project.dir, renderTick])
    const wholeRun = current === undefined ? [] : runModels(current.run)
    const hasData = wholeRun.some((m) => m.workbook !== undefined)
    const hasTexRun = wholeRun.some((m) => m.tex.length > 0)
    const legend = confirm.question
        ? questionLegend(confirm.question)
        : moving !== undefined
            ? moveKeys
            : legendOf([
                moveLegend(cursorMoves(stop, stops.length)),
                current !== undefined && legendFor("open", keys.enter),
                current !== undefined && legendFor("run.LOG", keys.showLog),
                current !== undefined && legendFor("delete run", keys.remove),
                hasData && legendFor("move data", keys.moveData),
                hasTexRun && legendFor("move tex plots", keys.moveTex),
                hasTex && renderable && legendFor("compile plots", keys.compilePlots),
                legendBack,
            ])
    // a model with settings of its own says which, when nothing else is to be said
    const own = current?.kind === "model" ? current.model.overrides : []
    const hint =
        own.length > 0
            ? { text: truncate(`overrides: ${own.join(", ")}`, noteRoom), error: false }
            : undefined
    const shown =
        shownNote(confirm, undefined) ??
        (busy !== undefined ? { text: busy, error: false } : (note ?? hint))
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
                                    <ErrorText>{status}</ErrorText>
                                ) : (
                                    <ListText on={on}>{status}</ListText>
                                )}
                            </Box>
                        )
                    }}
                />
            )}
            {moving !== undefined && (
                <Dropdown<string | null>
                    key={moving}
                    label={`move ${moving}:`}
                    search={filterChoices(choices)}
                    lines={lines}
                    onPick={moveChosen}
                    onCancel={() => setMoving(undefined)}
                    onLegend={setMoveKeys}
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
