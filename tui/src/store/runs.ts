// SPDX-License-Identifier: LGPL-3.0-or-later

import { constants, copyFileSync, mkdirSync } from "node:fs"
import { basename, join } from "node:path"
import {
    entryNames,
    isFile,
    isFolder,
    sleepSync,
    writeAtomic,
    writeJson,
} from "../core/files.js"
import { settingsFileName } from "./settings-store.js"

/**
 * The record of the runs of a project. Nothing here is ever deleted or overwritten: a
 * run adds a folder named by its exact time (UTC) to `logs/` and, if it succeeded, one
 * to `data/`, and the two have the same name, so a log and its data belong together.
 *
 *     <project>/logs/<time>/models.json   the names of the models of the run
 *                           settings.json the project's settings as they were (to
 *                                         restore by hand)
 *                           <name>.LOG    the run's log
 *     <project>/data/<time>/...           everything the run wrote: the workbook of each
 *                                         model, its plots (rendered or not) and its
 *                                         unicode plots
 *
 * `logs/` and `data/` are not made by the user or by a new project: a run makes them, a
 * failed one only `logs/`. Until then the project has no runs, which is [[hasRuns]].
 */

/** The two folders a run is recorded in. */
export type RunKind = "logs" | "data"

/** The name of the file that lists the models of a run. */
export const modelsFileName = "models.json"

/** The time a run waits when the name it wanted is taken (two runs in one millisecond). */
const retryMs = 1

/**
 * The name of a run started at a time, one that sorts as text and that every file
 * system accepts (no colon).
 *
 * @param instant - the time.
 * @returns e.g. `20261102T153045123Z` (UTC, milliseconds).
 */
export function stamp(instant: Date): string {
    return instant.toISOString().replace(/[-:.]/g, "")
}

/**
 * The names of the runs in one of the folders of a project.
 *
 * @param projectDir - the project's folder.
 * @param kind - `logs` or `data`.
 * @returns the names, oldest first; empty if the folder is not there.
 */
export function runIds(projectDir: string, kind: RunKind): string[] {
    const dir = join(projectDir, kind)
    return entryNames(dir)
        .filter((name) => isFolder(join(dir, name)))
        .sort()
}

/**
 * Whether a project has a run to show in one of its folders.
 *
 * @param projectDir - the project's folder.
 * @param kind - `logs` or `data`.
 * @returns the answer.
 */
export function hasRuns(projectDir: string, kind: RunKind): boolean {
    return runIds(projectDir, kind).length > 0
}

/**
 * A run just recorded.
 *
 * @property id - the run's name, a [[stamp]].
 * @property logs - its folder in `logs/`.
 * @property data - its folder in `data/`; `undefined` for a failed run.
 */
export type RunRecord = {
    id: string
    logs: string
    data: string | undefined
}

/**
 * What a run gives to [[recordRun]].
 *
 * @property models - the names of its models.
 * @property logFile - its log, if it has one.
 * @property outputDir - the folder the run wrote its results to; `undefined` if the
 *     run failed: a failed run leaves its record in `logs/` only.
 */
export type RunInput = {
    models: readonly string[]
    logFile?: string
    outputDir?: string
}

/**
 * Makes a folder that must be new.
 *
 * @param dir - the folder; its parent is made if need be.
 * @returns `true` if it was made, `false` if the name was taken.
 * @throws for any other failure.
 */
function makeNew(dir: string): boolean {
    mkdirSync(join(dir, ".."), { recursive: true })
    try {
        mkdirSync(dir)
        return true
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "EEXIST") return false
        throw error
    }
}

/**
 * Makes the folder of a new run under `logs` and, with `withData`, under `data`, both
 * named by the current time. A name already taken is never reused: it waits for the
 * next one.
 *
 * @param projectDir - the project's folder.
 * @param withData - whether the run has a folder in `data/` too.
 * @returns the new run's folders.
 */
function newRunDirs(projectDir: string, withData: boolean): RunRecord {
    for (;;) {
        const id = stamp(new Date())
        const logs = join(projectDir, "logs", id)
        const data = join(projectDir, "data", id)
        if (makeNew(logs) && (!withData || makeNew(data)))
            return { id, logs, data: withData ? data : undefined }
        sleepSync(retryMs)
    }
}

/**
 * Copies a file, never over a file that is there.
 *
 * @param from - the file.
 * @param to - where the copy goes.
 * @throws if it cannot be copied or `to` exists.
 */
function copyNew(from: string, to: string): void {
    copyFileSync(from, to, constants.COPYFILE_EXCL)
}

/**
 * Copies a file that may vanish meanwhile (the run's own output folder is being
 * cleaned by something else): a file that is gone is skipped, never an error.
 *
 * @param from - the file.
 * @param to - where the copy goes.
 * @throws if it cannot be copied for any other reason, or `to` exists.
 */
function copyIfThere(from: string, to: string): void {
    try {
        copyNew(from, to)
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error
    }
}

/**
 * Copies every file under a folder into another folder, keeping the layout.
 *
 * @param from - the folder to copy.
 * @param to - the folder the copy goes in; it is made if need be.
 */
function copyTree(from: string, to: string): void {
    mkdirSync(to, { recursive: true })
    for (const entry of entryNames(from)) {
        const source = join(from, entry)
        if (isFolder(source)) copyTree(source, join(to, entry))
        else if (isFile(source)) copyIfThere(source, join(to, entry))
    }
}

/**
 * Records a run of a project: its models, the project's settings as they are now, its
 * log and, for a run that succeeded, its output.
 *
 * @param projectDir - the project's folder.
 * @param run - what the run has to record.
 * @returns the run's name and folders.
 * @throws if something cannot be written; nothing is deleted then, what was written
 *     stays.
 */
export function recordRun(projectDir: string, run: RunInput): RunRecord {
    const record = newRunDirs(projectDir, run.outputDir !== undefined)
    writeAtomic(join(record.logs, modelsFileName), writeJson([...run.models]))
    copyNew(join(projectDir, settingsFileName), join(record.logs, settingsFileName))
    if (run.logFile !== undefined)
        copyNew(run.logFile, join(record.logs, basename(run.logFile)))
    if (run.outputDir !== undefined && record.data !== undefined)
        copyTree(run.outputDir, record.data)
    return record
}
