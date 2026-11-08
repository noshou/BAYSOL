// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The store side of the runs of a project: the run list and the one deletion of a run, the
 * options of the logs menu and the restores that put a run's inputs back into the project,
 * and the runs and models of `open... > open runs`. The run's `logs/` folder is plain
 * files (nothing is packed), read here and never written. Tolerant: a run or model folder
 * that vanishes is skipped or has no workbook, and nothing here throws for a run that is
 * odd.
 *
 * Contents: 1. the state of a run, the run list and the deletion; 2. the files of a run's
 * `logs/`; 3. the options of the logs menu (`runItems`, `conditionsText`); 4. the restores
 * (`restoreSettings`, `restoreBuffer`, `restoreUnits`); 5. the runs and
 * models (`listOpenRuns`, `openRows`, `findWorkbook`, `firstErrorLine`).
 */

import { lstatSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs"
import { basename, isAbsolute, join } from "node:path"
import { RUN_FLOW } from "../core/environment.js"
import {
    ChangedOnDiskError,
    FileInUseError,
    isDict,
    isFolder,
    ParentMissingError,
    parseJson,
    UnusableFileError,
    withFileLock,
} from "../core/file-system.js"
import {
    type BufferRow,
    type Conditions,
    conditionsOf,
    readSolutes,
    rowProblem,
    writeSolutes,
} from "./buffer.js"
import {
    DataFileError,
    type DataMapping,
    readMapping,
    setEnergy,
    setUnits,
    type Units,
} from "./data.js"
import {
    assertNoLiveRun,
    livePid,
    newestRuns,
    RunInProgressError,
    type RunStatus,
    runDirOf,
    startLockName,
} from "./projects.js"
import { defaultCatalog } from "./settings.js"
import { loadProject, wipeInvalid } from "./settings-store.js"

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
 * @property dir - the run folder.
 * @property state - `live` for a run whose process is alive, `interrupted` for one that
 *     says `running` but nobody runs, else the status of `run.json`, or `unknown` when
 *     there is no readable file.
 * @property live - whether the run is live (`state === "live"`).
 * @property models - the names of its models, as `run.json` lists them.
 * @property size - the bytes of the whole run folder.
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

/** The runs of a project, newest first, tolerant of a folder that goes meanwhile. */
export function listRuns(projectDir: string): RunRow[] {
    const rows: RunRow[] = []
    for (const { id, dir, json } of newestRuns(projectDir)) {
        const size = folderSize(dir)
        if (!isFolder(dir)) continue // gone while it was measured
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
 * Deletes a whole run folder: the one deletion of a run (there is no delete-a-log action).
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
            if (isFolder(dir)) rmSync(dir, { recursive: true, force: true })
        },
        { createParents: false },
    )
}

// ---- 2. the files of a run's logs ------------------------------------------------------

/** What a screen says when the run it shows was deleted. */
export const RUN_GONE = "this run was deleted"

/**
 * The text of a file of a run's `logs/` (read whole, read only).
 *
 * @param name - a file of the folder (`run.LOG`, `settings.json`, ...), never a path.
 * @throws Error `this run was deleted`, `this run has no <name>` or `<name> is too large
 *     to show` (over `RUN_FLOW.log.maxBytes`).
 */
export function readRunFile(runDir: string, name: string): string {
    const file = join(runDir, "logs", name)
    const missing = (): Error =>
        new Error(isFolder(runDir) ? `this run has no ${name}` : RUN_GONE)
    let size: number
    try {
        size = statSync(file).size
    } catch {
        throw missing()
    }
    if (size > RUN_FLOW.log.maxBytes) throw new Error(`${name} is too large to show`)
    try {
        return readFileSync(file, "utf-8")
    } catch {
        throw missing()
    }
}

/** The text of a run's `logs/run.LOG`: [[readRunFile]]. */
export function readLogText(runDir: string): string {
    return readRunFile(runDir, "run.LOG")
}

/**
 * The files of a run's `logs/` and their sizes (empty for a run without the folder).
 *
 * @returns file name to bytes.
 */
export function runFileSizes(runDir: string): Map<string, number> {
    const sizes = new Map<string, number>()
    const dir = join(runDir, "logs")
    let names: string[]
    try {
        names = readdirSync(dir)
    } catch {
        return sizes
    }
    for (const name of names) {
        try {
            const stat = statSync(join(dir, name))
            if (stat.isFile()) sizes.set(name, stat.size)
        } catch {
            // gone since the listing
        }
    }
    return sizes
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
 * @property file - the file of the run's `logs/` it reads.
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
    { label: "view run.LOG", file: "run.LOG", action: "pager" },
    { label: "view settings", file: "settings.json", action: "pager", json: true },
    {
        label: "restore settings",
        file: "settings.json",
        action: "restore",
        restore: "settings",
    },
    { label: "view buffer", file: "buffer.json", action: "pager", json: true },
    { label: "restore buffer", file: "buffer.json", action: "restore", restore: "buffer" },
    { label: "view units and energy", file: "data.json", action: "pager", json: true },
    { label: "restore units", file: "data.json", action: "restore", restore: "units" },
    { label: "view conditions", file: "run.LOG", action: "conditions" },
    { label: "view solutes", file: "solutes.json", action: "pager", json: true },
    { label: "view models", file: "models.json", action: "pager", json: true },
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

// ---- 4. the restores -------------------------------------------------------------------

/**
 * Putting a run's inputs back into the project (the `restore ...` options of the logs
 * menu). The caller reads the text of the run's own copy (`settings.json`, `buffer.json`,
 * `data.tsv`, `data.json`) and hands it here; nothing is ever written into the run, and
 * every write goes through the store that owns the file (its validation, its lock, its
 * atomic replace, `ChangedOnDiskError`). Every restore refuses while a run of the project
 * is live, and says in a short sentence what is wrong with a file it cannot use; nothing
 * is written then.
 */

/** The error of a run file that cannot be restored; the message is short, for a note. */
export class RestoreError extends Error {}

/**
 * The JSON object in a text.
 *
 * @throws [[RestoreError]] `<name> is not usable` for anything else.
 */
function objectOf(text: string, name: string): Record<string, unknown> {
    let value: unknown
    try {
        value = parseJson(text)
    } catch {
        throw new RestoreError(`${name} is not usable`)
    }
    if (!isDict(value)) throw new RestoreError(`${name} is not usable`)
    return value
}

/**
 * Restores the settings of the project to those of a run: every setting the run's
 * `settings.json` holds (a value that is not valid is left out) is set, and a setting the
 * project has saved that the run's file lacks goes to its default (that is what the run
 * used). The values are checked together with the rules between settings and saved
 * through the settings store (its lock and merge).
 *
 * @param globalDir - the BAYSOL folder (the baseline of a project's settings).
 * @throws [[RestoreError]] for a file that is no settings map or whose values break a
 *     rule; `RunInProgressError` for a live run; whatever the store throws (project gone,
 *     file in use).
 */
export function restoreSettings(project: string, globalDir: string, text: string): void {
    const stored = objectOf(text, "settings.json")
    assertNoLiveRun(project)
    const catalog = defaultCatalog()
    const { settings } = loadProject(project, globalDir, catalog)
    const kept = wipeInvalid(catalog, stored).saved
    const changes: Record<string, unknown> = Object.fromEntries(kept)
    for (const def of catalog.defs())
        if (!kept.has(def.name) && settings.isSaved(def.name))
            changes[def.name] = def.default
    const result = settings.set(changes)
    if (!result.ok) {
        const first = [...result.errors][0]
        throw new RestoreError(first ? `${first[0]} ${first[1]}` : "settings are not valid")
    }
    settings.save()
}

/**
 * What a run's `buffer.json` holds, for the question before it replaces the buffer.
 *
 * @returns the solutes and the conditions (`undefined` when it has none).
 * @throws [[RestoreError]] for a file that is not a buffer.
 */
export function bufferFacts(text: string): {
    rows: BufferRow[]
    conditions: Conditions | undefined
} {
    const map = objectOf(text, "buffer.json")
    const rows = map.solutes
    if (!Array.isArray(rows)) throw new RestoreError("buffer.json has no solutes")
    for (const row of rows) {
        if (rowProblem(row) !== undefined)
            throw new RestoreError("buffer.json is not usable")
    }
    return { rows: rows as BufferRow[], conditions: conditionsOf(map) }
}

/**
 * Starts watching the project's buffer file for the replace question: the version read
 * now is the one [[restoreBuffer]] checks, so a save by another copy while the question
 * is open makes the restore refuse (`ChangedOnDiskError`) instead of losing that save.
 * A buffer that cannot be read is not watched (the restore says why).
 */
export function watchBuffer(project: string): void {
    try {
        readSolutes(project, { track: true })
    } catch {
        // an unusable file: the restore reports it
    }
}

/**
 * Restores the buffer of the project to a run's: its solutes and its pH and σ in ONE
 * write (a run file without conditions leaves the project's own).
 *
 * @throws [[RestoreError]] for a file that is not a buffer; `RunInProgressError` for a
 *     live run; `ChangedOnDiskError`, `UnusableFileError`, `ProjectGoneError` from the
 *     buffer store.
 */
export function restoreBuffer(project: string, text: string): void {
    const { rows, conditions } = bufferFacts(text)
    assertNoLiveRun(project)
    writeSolutes(project, rows, conditions)
}

/**
 * The units, energy, source and import mapping of a run's `data.json`, checked.
 *
 * @returns the units of q, the X-ray energy (`undefined` when the run had none), the name
 *     of the file the curve came from and the mapping of the import, if it says.
 * @throws [[RestoreError]] `data.json is not usable` for units that are none of the two
 *     or an energy that is no number above 0.
 */
function infoOf(json: string): {
    units: Units
    energy?: number
    source?: string
    mapping?: DataMapping
} {
    const { units, energy, source, mapping } = objectOf(json, "data.json")
    const badUnits = units !== "nm-1" && units !== "A-1"
    const badEnergy = energy != null && !(typeof energy === "number" && energy > 0)
    if (badUnits || badEnergy) throw new RestoreError("data.json is not usable")
    return {
        units: units as Units,
        energy: typeof energy === "number" ? energy : undefined,
        source: typeof source === "string" ? source : undefined,
        mapping: readMapping(mapping),
    }
}

/**
 * Restores the units of q and the X-ray energy of the project's data to a run's: only
 * `data.json` is written (the table and the mapping never), through the data store's
 * edits.
 *
 * @throws [[RestoreError]] when it is not usable; `DataFileError` `no data yet` when the
 *     project has no data; `RunInProgressError` for a live run; `UnusableFileError`.
 */
export function restoreUnits(project: string, json: string): void {
    const { units, energy } = infoOf(json)
    assertNoLiveRun(project)
    setUnits(project, units)
    if (energy !== undefined) setEnergy(project, energy)
}

/**
 * The words for a failure of a restore, for the line of a screen.
 *
 * @returns the message of the errors that say it themselves (a restore, the data store,
 *     an unusable file, a live run, another copy's save or lock, a deleted project), else
 *     `could not restore`.
 */
export function restoreErrorNote(error: unknown): string {
    const speaks =
        error instanceof RestoreError ||
        error instanceof DataFileError ||
        error instanceof UnusableFileError ||
        error instanceof RunInProgressError ||
        error instanceof ChangedOnDiskError ||
        error instanceof FileInUseError ||
        error instanceof ParentMissingError
    return speaks ? (error as Error).message : "could not restore"
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
 * @property workbook - the results workbook of a finished model, `undefined` for a model
 *     that is not done or whose workbook is not there ([[findWorkbook]]).
 * @property plots - the model's `output/plots.txt` (it may not exist; the viewer says so).
 * @property plotSizes - the same plots at more sizes (`plot_sizes` of `run.json`), the
 *     viewer shows the largest that fits; empty for a run that has none.
 * @property overrides - the names of the settings the model has of its own.
 */
export type OpenModel = {
    name: string
    state: ModelState
    error: string | undefined
    workbook: string | undefined
    plots: string
    plotSizes: PlotFile[]
    overrides: string[]
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

/** The folder of the comparison, in the run folder. */
const COMPARE_FOLDER = "compare"

/** The folder of a model that holds what `results` wrote. */
const OUTPUT_FOLDER = "output"

/** The name of a model's plain-text unicode plots in its output folder. */
const PLOTS_FILE = "plots.txt"

/**
 * The results workbook of a model: the `.xlsx` that `results` wrote into its output
 * folder. It is named for the model (`<model>.xlsx`), and that one is preferred, but the
 * real name is whatever is there: otherwise the first `.xlsx` in name order. Lock and
 * hidden files (`~$x.xlsx`, `.x.xlsx`) are not workbooks.
 *
 * @returns the path, or `undefined` when there is no workbook (or no folder).
 */
export function findWorkbook(outputDir: string, model: string): string | undefined {
    let names: string[]
    try {
        names = readdirSync(outputDir)
    } catch {
        return undefined
    }
    const books = names
        .filter((n) => /\.xlsx$/i.test(n) && !n.startsWith("~$") && !n.startsWith("."))
        .sort()
    const named = books.find((n) => n === `${model}.xlsx`)
    const pick = named ?? books[0]
    return pick === undefined ? undefined : join(outputDir, pick)
}

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
        const output = join(dir, name, OUTPUT_FOLDER)
        const state = modelState(m.status, run)
        out.push({
            name,
            state,
            error: typeof m.error === "string" && m.error !== "" ? m.error : undefined,
            workbook: state === "done" ? findWorkbook(output, name) : undefined,
            plots: join(output, PLOTS_FILE),
            plotSizes: plotFilesOf(dir, m.plot_sizes),
            overrides: overridesOf(m.overrides),
        })
    }
    return out
}

/**
 * The comparison of a `run.json` (its `compare` entry), as a model named `comparison`:
 * its workbook is the `.xlsx` of `files` (else the one in `compare/`), its plots the
 * `compare/plots.txt`.
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
    const folder = join(dir, COMPARE_FOLDER)
    const listed = (Array.isArray(c.files) ? c.files : [])
        .filter((f) => typeof f === "string" && /\.xlsx$/i.test(f))
        .map((f) => runFilePath(dir, f))
        .find((f) => f !== undefined)
    return {
        name: COMPARE_NAME,
        state,
        error: typeof c.error === "string" && c.error !== "" ? c.error : undefined,
        workbook:
            state === "done"
                ? (listed ?? findWorkbook(folder, `${basename(dir)}_compare`))
                : undefined,
        plots: join(folder, PLOTS_FILE),
        plotSizes: plotFilesOf(dir, c.plot_sizes),
        overrides: [],
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
 * when it has one model, which goes straight on.
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
        if (run.compare !== undefined)
            rows.push({ kind: "compare", run, model: run.compare, nested: !single })
    }
    return rows
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
