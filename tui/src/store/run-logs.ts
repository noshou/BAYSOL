// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The store side of the runs of a project: the run list and the one deletion of a run, the
 * options of the logs menu and the restores that put a run's inputs back into the project,
 * and the runs and models of `open... > open runs`. A run's files are read from its
 * archive or from its plain folders alike (`run-archive.ts`), read here and never
 * written. Tolerant: a run or model folder
 * that vanishes is skipped or has no workbook, and nothing here throws for a run that is
 * odd.
 *
 * Contents: 1. the state of a run, the run list and the deletion; 2. the files of a run
 * (its own, flat); 3. the options of the logs menu
 * (`runItems`, `conditionsText`); 4. the restores
 * (`restoreSettings`, `restoreBuffer`, `restoreUnits`); 5. the runs and
 * models (`listOpenRuns`, `openRows`, `firstErrorLine`).
 */

import { lstatSync, readdirSync, rmSync } from "node:fs"
import { basename, isAbsolute, join } from "node:path"
import { PACK_LOCK } from "../core/archive.js"
import { RUN_FLOW } from "../core/environment.js"
import {
    FileInUseError,
    isDict,
    isFolder,
    withFileLock,
} from "../core/file-system.js"
import { displayWidth, takeWidth, truncateStart } from "../core/terminal.js"
import {
    assertNoLiveRun,
    livePid,
    newestRuns,
    type RunStatus,
    runDirOf,
    startLockName,
} from "./projects.js"
import {
    archivePath,
    RUN_FILES,
    RunFileMissing,
    RunFileTooLarge,
    readRunText,
    runExists,
    runFiles,
} from "./run-archive.js"

// ---- 1. the state of a run, the run list and the deletion ------------------------------

/** What the status says: a status of `run.json`, or `live`, or `unknown`. */
type RunState = RunStatus | "live" | "unknown"

/** The state of a run folder. */
function stateOf(dir: string, json: Record<string, unknown> | undefined): RunState {
    if (livePid(dir) !== undefined) return "live"
    const status = json?.status
    if (status === "running") return "interrupted"
    return status === "done" ||
        status === "failed" ||
        status === "aborted" ||
        status === "interrupted"
        ? status
        : "unknown"
}

/** The names of the models a `run.json` lists. */
function modelNames(json: Record<string, unknown> | undefined): string[] {
    const models = json?.models
    if (!Array.isArray(models)) return []
    const names: string[] = []
    for (const m of models) {
        if (isDict(m) && typeof m.name === "string") names.push(m.name)
        else if (isDict(m) && typeof m.path === "string") names.push(basename(m.path))
    }
    return names
}

/**
 * One run of the logs menu's list.
 *
 * @property id - the run's name, its stamp (`23-35-29-123_EST_-0500_2026-11-07`).
 * @property dir - the run's path: its folder, or where it was (the archive is `<dir>.7z`).
 * @property state - `live` for a run whose process is alive, `interrupted` for one that
 *     says `running` but nobody runs, else the status of `run.json`, or `unknown` when
 *     there is no readable file.
 * @property live - whether the run is live (`state === "live"`).
 * @property models - the names of its models, as `run.json` lists them.
 * @property size - the bytes of the whole run: its folder and its archive.
 */
export type RunRow = {
    id: string
    dir: string
    state: RunState
    live: boolean
    models: string[]
    size: number
}

/**
 * The bytes of a folder and everything in it. A file or folder that vanishes while it is
 * walked counts as nothing.
 */
export function folderSize(dir: string): number {
    let total = 0
    let names: string[]
    try {
        names = readdirSync(dir)
    } catch {
        return 0
    }
    for (const name of names) {
        try {
            const stat = lstatSync(join(dir, name))
            total += stat.isDirectory() ? folderSize(join(dir, name)) : stat.size
        } catch {
            // gone since the listing
        }
    }
    return total
}

/** The bytes of a run: its folder (when it has one) and its archive. */
function runSize(dir: string): number {
    let archived = 0
    try {
        archived = lstatSync(archivePath(dir)).size
    } catch {
        // no archive of the new layout
    }
    return folderSize(dir) + archived
}

/** The runs of a project, newest first, tolerant of a folder that goes meanwhile. */
export function listRuns(projectDir: string): RunRow[] {
    const rows: RunRow[] = []
    for (const { id, dir, json } of newestRuns(projectDir)) {
        const size = runSize(dir)
        if (!runExists(dir)) continue // gone while it was measured
        const state = stateOf(dir, json)
        const models = modelNames(json)
        rows.push({ id, dir, state, live: state === "live", models, size })
    }
    return rows
}

/** A size for a column: bytes up to a kilobyte, then one decimal of KB, MB, GB. */
export function sizeText(bytes: number): string {
    const units = ["B", "KB", "MB", "GB"]
    let value = bytes
    let unit = 0
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024
        unit++
    }
    return unit === 0 ? `${value} B` : `${value.toFixed(1)} ${units[unit]}`
}

/**
 * Deletes a whole run, its folder and its archive: the one deletion of a run (there is no
 * delete-a-log action).
 * Under the project's `.start` lock (so no run starts between the check and the removal),
 * after checking that no run of the project is live. A folder that is already gone is no
 * error.
 *
 * @throws `RunInProgressError` (`a run is in progress (pid N)`) when a run of the project
 *     is live; Error for a name that is no run; FileInUseError if the start lock stays
 *     taken for 3 s.
 */
export function deleteRun(projectDir: string, id: string): void {
    const dir = runDirOf(projectDir, id)
    if (id === "" || id.startsWith(".") || basename(id) !== id)
        throw new Error(`not a run: "${id}"`)
    const runs = join(dir, "..")
    if (!isFolder(runs)) return
    withFileLock(
        join(runs, startLockName),
        () => {
            assertNoLiveRun(projectDir)
            if (!runExists(dir)) return
            // a run that is being packed is not deleted under the pack
            if (isFolder(dir)) {
                try {
                    withFileLock(join(dir, PACK_LOCK), () => {}, { createParents: false })
                } catch (error) {
                    if (error instanceof FileInUseError)
                        throw new Error("this run is being packed: try again in a moment")
                    throw error
                }
            }
            rmSync(archivePath(dir), { force: true })
            rmSync(dir, { recursive: true, force: true })
        },
        { createParents: false },
    )
}

// ---- 2. the files of a run's logs ------------------------------------------------------

/** What a screen says when the run it shows was deleted. */
export const RUN_GONE = "this run was deleted"

/**
 * The text of one of a run's own files (read whole, read only), from the run's archive or
 * from its plain folder.
 *
 * @param name - a file of the run (`run.LOG`, `settings.json`, ...), never a path.
 * @throws Error `this run was deleted`, `this run has no <name>`, `<name> is too large
 *     to show` (over `RUN_FLOW.log.maxBytes`) or `the run's archive cannot be read: ...`.
 */
export function readRunFile(runDir: string, name: string): string {
    try {
        return readRunText(runDir, name, RUN_FLOW.log.maxBytes)
    } catch (error) {
        if (error instanceof RunFileTooLarge)
            throw new Error(`${name} is too large to show`)
        if (error instanceof RunFileMissing)
            throw new Error(runExists(runDir) ? `this run has no ${name}` : RUN_GONE)
        if (!runExists(runDir)) throw new Error(RUN_GONE)
        throw new Error(`the run's archive cannot be read: ${(error as Error).message}`)
    }
}

/** The text of a run's `run.LOG`: [[readRunFile]]. */
export function readLogText(runDir: string): string {
    return readRunFile(runDir, "run.LOG")
}

/**
 * The files of a run and their sizes, in the archive and in the plain folder (empty for
 * a run without either).
 *
 * @returns file name to bytes.
 */
export function runFileSizes(runDir: string): Map<string, number> {
    return runFiles(runDir)
}

// ---- 3. the options of a run -----------------------------------------------------------

/**
 * The options of one run in the logs menu, as data: what each is called, which file of the
 * run's logs it reads and what it does with it. The screen draws and runs them; this file
 * holds the list and the text of the views that are made from a file (no React), so it
 * is tested.
 */

/** What an option does: show text in the pager, show conditions, put back. */
type RunAction = "pager" | "conditions" | "restore"

/** What a restore puts back. */
type RestoreKind = "settings" | "buffer" | "units"

/**
 * One option of the run page.
 *
 * @property label - what the list says, e.g. `view settings`.
 * @property file - the file of the run it reads.
 * @property action - see [[RunAction]].
 * @property restore - what a `restore` option puts back.
 * @property json - the file is JSON and is shown pretty-printed.
 */
export type RunItem = {
    label: string
    file: string
    action: RunAction
    restore?: RestoreKind
    json?: boolean
}

/** The options of a run, in the order of the list. */
export const runItems: readonly RunItem[] = [
    { label: "view run.LOG", file: RUN_FILES.log, action: "pager" },
    { label: "view settings", file: RUN_FILES.settings, action: "pager", json: true },
    {
        label: "restore settings",
        file: RUN_FILES.settings,
        action: "restore",
        restore: "settings",
    },
    { label: "view buffer", file: RUN_FILES.buffer, action: "pager", json: true },
    {
        label: "restore buffer",
        file: RUN_FILES.buffer,
        action: "restore",
        restore: "buffer",
    },
    {
        label: "view units and energy",
        file: RUN_FILES.dataInfo,
        action: "pager",
        json: true,
    },
    {
        label: "restore units",
        file: RUN_FILES.dataInfo,
        action: "restore",
        restore: "units",
    },
    { label: "view conditions", file: RUN_FILES.log, action: "conditions" },
    { label: "view solutes", file: RUN_FILES.solutes, action: "pager", json: true },
    { label: "view models", file: RUN_FILES.models, action: "pager", json: true },
]

/**
 * A JSON text pretty-printed (two-space indent) so it reads in a pager; text that is not
 * JSON is shown as it is.
 */
export function prettyJson(text: string): string {
    try {
        return `${JSON.stringify(JSON.parse(text), null, 2)}\n`
    } catch {
        return text
    }
}

/**
 * The rows of a LOG: Julia writes it as flat `name<spaces><TAB>value` rows. The first row
 * of each name with a value counts; the log's own sections (`--- timing ---`) have no
 * tab-separated pair and are skipped by that rule.
 */
function logRows(text: string): Map<string, string> {
    const rows = new Map<string, string>()
    for (const line of text.split(/\r?\n/)) {
        const cells = line.split("\t")
        const name = cells[0]?.trim() ?? ""
        const value = cells[1]?.trim()
        if (cells.length >= 2 && value !== undefined && value !== "" && !rows.has(name))
            rows.set(name, value)
    }
    return rows
}

/** The rows of a LOG that make up the conditions, with the label each is shown under. */
const conditionRows: readonly [name: string, label: string, unit: string][] = [
    ["temperature_c", "temperature", "°C"],
    ["ph", "pH", ""],
    ["sigma_ph", "σ", ""],
    ["energy_ev", "energy", "eV"],
]

/**
 * The conditions of a run as its LOG records them: the temperature, the pH and its σ and
 * the X-ray energy.
 *
 * @returns the lines to show, one per condition the LOG has, or one line saying it has
 *     none.
 */
export function conditionsText(log: string): string {
    const found = logRows(log)
    const lines = conditionRows.flatMap(([name, label, unit]) => {
        const value = found.get(name)
        if (value === undefined) return []
        return [`${label.padEnd(12)}${value}${unit ? ` ${unit}` : ""}`]
    })
    return lines.length === 0 ? "the LOG records no conditions\n" : `${lines.join("\n")}\n`
}

// ---- 5. the runs and models of `open runs` ---------------------------------------------

/**
 * What `open... > open runs` lists: the runs of a project and, under each, its models with
 * how each went, read from `run.json` (never file names). Like the run list it is
 * tolerant: a run folder or a model folder that vanishes is skipped or has no workbook,
 * and nothing here throws for a run that is odd.
 */

/** How a model stands: a model status of `run.json`, or `interrupted`, `unknown`. */
type ModelState =
    | "pending"
    | "running"
    | "done"
    | "failed"
    | "aborted"
    | "skipped"
    | "interrupted"
    | "unknown"

/**
 * One model of a run.
 *
 * @property name - the model's name (its file stem, the model folder's name).
 * @property state - how it stands. A `running` or `pending` model of a run that nobody
 *     runs any more is `interrupted`.
 * @property error - the first line of why a failed model failed (`run.json`), if known.
 * @property workbook - the results workbook of a finished model (a path in the run's
 *     folder, which may exist only in the archive: [[materializeRunFile]] gives a file),
 *     `undefined` for a model that is not done or has none.
 * @property plots - the model's plots text, `<model>-plots.txt` (it may not exist, the
 *     viewer says so).
 * @property plotSizes - the same plots at more sizes (`plot_sizes` of `run.json`), the
 *     viewer shows the largest that fits; empty for a run that has none.
 * @property overrides - the names of the settings the model has of its own.
 * @property tex - the `.tex` figures it has, in the archive or in its folder: names
 *     relative to the run folder (`<model>.tex`), sorted.
 */
export type OpenModel = {
    name: string
    state: ModelState
    error: string | undefined
    workbook: string | undefined
    plots: string
    plotSizes: PlotFile[]
    overrides: string[]
    tex: string[]
}

/**
 * A plots file written at one size.
 *
 * @property path - the file (inside the run folder).
 * @property width - the widest line, in terminal cells.
 * @property rows - the lines of the tallest plot.
 */
export type PlotFile = { path: string; width: number; rows: number }

/**
 * One run of `open runs`.
 *
 * @property id - the run's name, its stamp.
 * @property dir - the run folder.
 * @property state - as in the run list: `live`, `interrupted`, a status or `unknown`.
 * @property models - its models in the order of `run.json`.
 * @property compare - the comparison of the models (the `compare` entry of `run.json`,
 *     as a model named `comparison`: its workbook, plots and how it went); `undefined`
 *     when the run made none.
 */
export type OpenRun = {
    id: string
    dir: string
    state: RunState
    models: OpenModel[]
    compare: OpenModel | undefined
}

/** The name the comparison goes by in the list and in notes. */
const COMPARE_NAME = "comparison"

/**
 * A file named in `run.json`, inside the run folder: a relative path with no `..`, no
 * drive and no backslash.
 *
 * @returns the path in the run folder, or `undefined` for a name that is not safe.
 */
export function runFilePath(dir: string, name: unknown): string | undefined {
    if (typeof name !== "string" || name === "" || name.includes("\\")) return undefined
    if (isAbsolute(name) || /^[A-Za-z]:/.test(name) || name.includes("\0")) return undefined
    if (name.split("/").some((part) => part === ".." || part === "")) return undefined
    return join(dir, ...name.split("/"))
}

/** The plot files of a `plot_sizes` list, smallest first; odd entries are left out. */
function plotFilesOf(dir: string, list: unknown): PlotFile[] {
    if (!Array.isArray(list)) return []
    const files: PlotFile[] = []
    for (const e of list) {
        if (!isDict(e)) continue
        const path = runFilePath(dir, e.file)
        const { width, rows } = e
        const whole = Number.isSafeInteger(width) && Number.isSafeInteger(rows)
        if (path === undefined || !whole) continue
        files.push({ path, width: width as number, rows: rows as number })
    }
    return files.sort((a, b) => a.width - b.width || a.rows - b.rows)
}

/** The names of the settings of an `overrides` list. */
function overridesOf(list: unknown): string[] {
    return Array.isArray(list) ? list.filter((x): x is string => typeof x === "string") : []
}

/** The names a `files` list of `run.json` holds (flat names of the run folder). */
function listedFiles(list: unknown): string[] {
    if (!Array.isArray(list)) return []
    return list.filter(
        (f): f is string => typeof f === "string" && f !== "" && !f.includes("/"),
    )
}

/** The names of a list that end in `.tex`, sorted. */
const texOf = (files: readonly string[]): string[] =>
    files.filter((f) => f.endsWith(".tex")).sort()

/**
 * The state of one model entry of `run.json`.
 *
 * @returns the model state: a model still `running` or `pending` in a run that is not
 *     live is `interrupted`.
 */
function modelState(status: unknown, run: RunState): ModelState {
    if (
        status === "done" ||
        status === "failed" ||
        status === "aborted" ||
        status === "skipped"
    )
        return status
    if (status === "running" || status === "pending")
        return run === "live" ? status : "interrupted"
    return "unknown"
}

/**
 * The models of a `run.json`, each with its state and workbook.
 *
 * @returns the models; an entry without a usable name (one that is no plain folder name)
 *     is left out.
 */
function openModels(
    dir: string,
    json: Record<string, unknown> | undefined,
    run: RunState,
): OpenModel[] {
    const list = Array.isArray(json?.models) ? (json?.models as unknown[]) : []
    const out: OpenModel[] = []
    for (const m of list) {
        if (!isDict(m) || typeof m.name !== "string") continue
        const name = m.name
        if (name === "" || name.startsWith(".") || basename(name) !== name) continue
        const state = modelState(m.status, run)
        const files = listedFiles(m.files)
        const book = files.includes(`${name}.xlsx`)
            ? `${name}.xlsx`
            : files.filter((f) => f.endsWith(".xlsx")).sort()[0]
        out.push({
            name,
            state,
            error: typeof m.error === "string" && m.error !== "" ? m.error : undefined,
            workbook: state === "done" && book !== undefined ? join(dir, book) : undefined,
            plots: join(dir, `${name}-plots.txt`),
            plotSizes: plotFilesOf(dir, m.plot_sizes),
            overrides: overridesOf(m.overrides),
            tex: texOf(files),
        })
    }
    return out
}

/**
 * The comparison of a `run.json` (its `compare` entry), as a model named `comparison`:
 * its table `compare.tsv`, its figures and its plots `compare-plots.txt`.
 *
 * @returns it, or `undefined` for a run with no `compare` entry.
 */
function openCompare(
    dir: string,
    json: Record<string, unknown> | undefined,
    run: RunState,
): OpenModel | undefined {
    const c = json?.compare
    if (!isDict(c)) return undefined
    const state = modelState(c.status, run)
    const files = listedFiles(c.files)
    const table = files.find((f) => f.endsWith(".tsv"))
    return {
        name: COMPARE_NAME,
        state,
        error: typeof c.error === "string" && c.error !== "" ? c.error : undefined,
        workbook: state === "done" && table !== undefined ? join(dir, table) : undefined,
        plots: join(dir, "compare-plots.txt"),
        plotSizes: plotFilesOf(dir, c.plot_sizes),
        overrides: [],
        tex: texOf(files),
    }
}

/** The runs of a project with their models, newest first (what `open runs` lists). */
export function listOpenRuns(projectDir: string): OpenRun[] {
    const runs: OpenRun[] = []
    for (const { id, dir, json } of newestRuns(projectDir)) {
        const state = stateOf(dir, json)
        runs.push({
            id,
            dir,
            state,
            models: openModels(dir, json, state),
            compare: openCompare(dir, json, state),
        })
    }
    return runs
}

/** The models of a run and its comparison, as the units a whole-run action takes. */
export function runModels(run: OpenRun): OpenModel[] {
    return run.compare === undefined ? run.models : [...run.models, run.compare]
}

/**
 * One row of the `open runs` list: a run that is only a heading (it has several models,
 * or none), or a model (a run with exactly one model is just that one row, with its run).
 *
 * @property kind - `run` (a heading the cursor skips), `model` (selectable) or `compare`
 *     (the run's comparison, selectable, after its models).
 * @property run - the run the row belongs to.
 * @property model - the model of a `model` row, the comparison of a `compare` row.
 * @property nested - a model listed under its run's heading (indented).
 */
export type OpenRow =
    | { kind: "run"; run: OpenRun }
    | { kind: "model" | "compare"; run: OpenRun; model: OpenModel; nested: boolean }

/**
 * The flat rows of the list: for each run (as given, newest first) its heading and its
 * models under it when it has several (or none: a heading alone), and one single row
 * when it has one model, which goes straight on. The comparison is a row of its own only
 * for a run of several models: one model has nothing to compare it with.
 */
export function openRows(runs: readonly OpenRun[]): OpenRow[] {
    const rows: OpenRow[] = []
    for (const run of runs) {
        const [only] = run.models
        const single = run.models.length === 1 && only !== undefined
        if (single) rows.push({ kind: "model", run, model: only, nested: false })
        else {
            rows.push({ kind: "run", run })
            for (const model of run.models)
                rows.push({ kind: "model", run, model, nested: true })
        }
        if (run.compare !== undefined && run.models.length > 1)
            rows.push({ kind: "compare", run, model: run.compare, nested: !single })
    }
    return rows
}

/** The widest a brief reason may be (`briefError`): it has to share a note row. */
export const BRIEF_ERROR_WIDTH = 30

/**
 * The short phrases of the errors a run knows, tried in this order on the first line of an
 * error (`NotConvergedError: the run did not converge: ...`).
 */
const KNOWN_ERRORS: readonly (readonly [RegExp, string])[] = [
    [/^NotConvergedError\b/, "not converged"],
    [/^InterruptException\b/, "interrupted"],
    [/^OutOfMemoryError\b/, "out of memory"],
]

/**
 * A failed model's `error` (the first line Julia put in `run.json`) in a few words, for a
 * row or a note: the model prefix and the error's type are left off, a known error gets
 * its phrase (`NotConvergedError` is `not converged`), anything else its first sentence,
 * cut at a word when it is longer than [[BRIEF_ERROR_WIDTH]]. The whole text stays in
 * `run.LOG` (`^l` in the run list).
 *
 * @param error - the error text; only its first line is read.
 * @returns the reason, never ending in `…` and never longer than the width.
 */
export function briefError(error: string): string {
    const first = (error.split(/\r?\n/)[0] ?? "").trim().replace(/^model .+?: /, "")
    for (const [pattern, phrase] of KNOWN_ERRORS) if (pattern.test(first)) return phrase
    const plain = first.replace(/^[A-Z]\w*(?:Error|Exception): /, "")
    const sentence = (plain.split(/(?<=[.!?])\s/)[0] ?? plain).replace(/[.:;,]$/, "")
    if (displayWidth(sentence) <= BRIEF_ERROR_WIDTH) return sentence
    // cut at the last word that fits
    const cut = takeWidth(sentence, BRIEF_ERROR_WIDTH + 1)
    const at = cut.lastIndexOf(" ")
    return (at > 0 ? cut.slice(0, at) : takeWidth(cut, BRIEF_ERROR_WIDTH)).trim()
}

/**
 * `<name> failed: <reason>` for a note row: only the name (data of the user) is cut, from
 * its start (the end tells models apart), when the line would not fit; the sentence never
 * is.
 *
 * @param name - the model's name.
 * @param error - its error (`briefError` shortens it); none gives `<name> failed`.
 * @param room - the cells of the note row.
 * @returns the line.
 */
export function failedNote(name: string, error: string | undefined, room: number): string {
    const tail = error ? ` failed: ${briefError(error)}` : " failed"
    return `${truncateStart(name, Math.max(8, room - displayWidth(tail)))}${tail}`
}

/**
 * The first line of what went wrong in a run, from the `=== ERRORS ===` section of its
 * `run.LOG` (each entry is `model <name>: <Error>: <message>` and its stack). The `model
 * <name>: ` is left off, so `WLSError: need n ≥ 3 points ...` is what is told.
 *
 * @returns the line, or `undefined` when the log has no ERRORS section or it is empty.
 */
export function firstErrorLine(log: string): string | undefined {
    const heading = "=== ERRORS ==="
    const at = log.indexOf(heading)
    if (at < 0) return undefined
    for (const raw of log.slice(at + heading.length).split(/\r?\n/)) {
        const line = raw.trim()
        if (line !== "") return line.replace(/^model .+?: /, "")
    }
    return undefined
}
