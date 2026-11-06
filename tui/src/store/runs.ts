// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync } from "node:fs"
import { join } from "node:path"
import { entryNames, isFile, isFolder } from "../core/files.js"

/**
 * The runs of a project, as the program that makes them leaves them. A run is a folder
 * named by its start time (UTC); Julia creates it, the TUI only reads:
 *
 *     <project>/runs/<stamp>/run.json   {"status": "running" | "done" | "failed" |
 *                                        "aborted", ...}
 *                            logs/ or logs.7z, one folder per model, ...
 *
 * `runs/` is not made by the user or by a new project: a run makes it. Until then the
 * project has no runs, which is [[hasRuns]]. Nothing here deletes or overwrites a run.
 */

/** The folder of a project that holds its runs. */
const runsFolder = "runs"

/** The file of a run folder that says how the run ended. */
const runFileName = "run.json"

/** How a run stands, as `run.json` says. */
export type RunStatus = "running" | "done" | "failed" | "aborted"

/** The statuses a `run.json` may hold; anything else reads as unknown. */
const statuses: readonly string[] = ["running", "done", "failed", "aborted"]

/**
 * The names of the runs of a project.
 *
 * @param projectDir - the project's folder.
 * @returns the folder names under `runs/`, oldest first (a stamp sorts as text); empty
 *     if the folder is not there.
 */
export function runIds(projectDir: string): string[] {
    const dir = join(projectDir, runsFolder)
    return entryNames(dir)
        .filter((name) => isFolder(join(dir, name)))
        .sort()
}

/**
 * Whether a project has at least one run folder.
 *
 * @param projectDir - the project's folder.
 * @returns the answer.
 */
export function hasRuns(projectDir: string): boolean {
    return runIds(projectDir).length > 0
}

/**
 * How one run ended, from its `run.json`.
 *
 * @param projectDir - the project's folder.
 * @param id - the run's name.
 * @returns the status, or `undefined` when the file is missing, unreadable or says
 *     something else.
 */
export function runStatus(projectDir: string, id: string): RunStatus | undefined {
    const file = join(projectDir, runsFolder, id, runFileName)
    if (!isFile(file)) return undefined
    try {
        const status = (JSON.parse(readFileSync(file, "utf-8")) as { status?: unknown })
            .status
        return typeof status === "string" && statuses.includes(status)
            ? (status as RunStatus)
            : undefined
    } catch {
        return undefined
    }
}

/**
 * Whether a run finished properly, which is what the `results` item of the project
 * menu needs.
 *
 * @param projectDir - the project's folder.
 * @returns `true` when some run has the status `done`.
 */
export function hasFinishedRun(projectDir: string): boolean {
    return runIds(projectDir).some((id) => runStatus(projectDir, id) === "done")
}
