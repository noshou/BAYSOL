// SPDX-License-Identifier: LGPL-3.0-or-later

// Run: starting a run and running it.
//
// Contents:
//   1. Readiness: what a project has of what a run needs
//   2. Temperature: parsing the buffer's temperature, the start of its prompt
//   3. Claim: the run folder's name, the claim, the snapshot of the inputs, stale sweeps
//   4. Output: the tail of Julia's output that the run page shows
//   5. Session: the Julia child process of one run, its phases and the quit/kill hooks
//
// The state of the run folders on disk (status, liveness, settling) is in `projects.ts`,
// the data of `open runs` in `run-logs.ts`.

import { type ChildProcess, spawn, spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
    appendFileSync,
    existsSync,
    mkdirSync,
    readFileSync,
    rmSync,
    symlinkSync,
    writeFileSync,
} from "node:fs"
import { hostname } from "node:os"
import { join } from "node:path"
import { stripVTControlCharacters } from "node:util"
import {
    cacheDir,
    exeName,
    isWindows,
    RUN_FLOW,
    readSystem,
    repoRoot,
} from "../core/environment.js"
import {
    copyOver,
    isFile,
    isFolder,
    messageOf,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import { formatNumber, type Parsed, parseNumber } from "../core/terminal.js"
import { bufferFile, readConditions, readSolutes } from "./buffer.js"
import { dataIsReady, dataJsonFile, dataTsvFile, readDataInfo } from "./data.js"
import { modelReferencesFile } from "./model-references.js"
import { packState, settleWrites } from "./packs.js"
import type { ProjectRef } from "./projects.js"
import {
    CLAIM_FILE,
    extractGenerated,
    extractModels,
    GENERATED_DIR,
    inProject,
    isoStamp,
    listModels,
    listProjects,
    liveRun,
    lockedIn,
    MODELS_PACK,
    markStaleRuns,
    modelsArchive,
    packGenerated,
    projectFile,
    RunInProgressError,
    runDirOf,
    runStatus,
    settleRun,
    startLockName,
} from "./projects.js"
import { copyReferences, referencesArchive } from "./references.js"
import { packRun, RUN_FILES, runCacheFolder, runModelsFolder } from "./run-archive.js"
import { briefError, firstErrorLine, readLogText } from "./run-logs.js"
import { runStamp } from "./run-stamp.js"
import { modelSettingsFile, modelStem, settingsFile } from "./settings-store.js"

// ========================================================================================
// 1. Readiness
// ========================================================================================

/**
 * What a project has of what a run needs, one flag each.
 *
 * @property models - at least one model.
 * @property buffer - a buffer with at least one solute, its pH and its temperature set
 *     (an unreadable file counts as missing; `^g` sets the temperature).
 * @property data - the measured curve is loaded (`data.tsv` and `data.json` valid) and
 *     the X-ray energy is set (there is no default).
 * @property run - everything above is there, so a run can start.
 */
export type Readiness = {
    models: boolean
    buffer: boolean
    data: boolean
    run: boolean
}

/**
 * Whether a project can run a fit, and which parts it still lacks (the project menu shows
 * `run` only when `run` is true).
 *
 * @throws never: a folder that cannot be read counts as missing parts.
 */
export function projectReadiness(project: ProjectRef): Readiness {
    const attempt = (check: () => boolean): boolean => {
        try {
            return check()
        } catch {
            return false
        }
    }
    const models = attempt(() => listModels(project.dir).length > 0)
    const buffer = attempt(
        () =>
            readSolutes(project.dir).length > 0 &&
            readConditions(project.dir)?.temperature !== undefined,
    )
    const data = attempt(() => dataIsReady(project.dir))
    return { models, buffer, data, run: models && buffer && data }
}

/**
 * The parts a project still lacks before it can run, in the order of the project menu:
 * `models`, `solutes`, `pH`, `temperature`, `data`, `energy`. Empty exactly when
 * [[projectReadiness]] says `run`; an unreadable folder lacks all.
 *
 * @param project - the project.
 * @returns the names of what is missing.
 * @throws never.
 */
export function missingComponents(project: ProjectRef): string[] {
    const attempt = <T>(read: () => T, otherwise: T): T => {
        try {
            return read()
        } catch {
            return otherwise
        }
    }
    const missing: string[] = []
    if (!attempt(() => listModels(project.dir).length > 0, false)) missing.push("models")
    if (!attempt(() => readSolutes(project.dir).length > 0, false)) missing.push("solutes")
    const conditions = attempt(() => readConditions(project.dir), undefined)
    if (conditions === undefined) missing.push("pH")
    if (conditions?.temperature === undefined) missing.push("temperature")
    const data = attempt(() => readDataInfo(project.dir), undefined)
    if (data?.kind !== "ok") missing.push("data")
    if (data?.kind !== "ok" || data.info.energy === null) missing.push("energy")
    return missing
}

// ========================================================================================
// 2. Temperature
// ========================================================================================

/** The label of the temperature prompt of the buffer (`^g`, after pH and σ). */
export const TEMPERATURE_LABEL = "temperature °C:"

/**
 * What typing a temperature comes to.
 *
 * @returns `{ value }` in °C, or `{ error }` with the message for the prompt: `a number,
 *     please`, or `from 0 to 100 °C` (the range of the asset file).
 */
export function parseTemperature(text: string): Parsed<number> {
    const { min, max } = RUN_FLOW.temperature
    const range = `from ${formatNumber(min)} to ${formatNumber(max)} °C`
    const parsed = parseNumber(text, {
        atLeast: { limit: min, message: range },
    })
    if ("error" in parsed) return parsed
    return parsed.value > max ? { error: range } : parsed
}

/**
 * The text the temperature prompt starts with: the buffer's, else the default.
 *
 * @param held - the temperature the buffer has, if any.
 * @returns the text.
 */
export const temperatureStart = (held?: number): string =>
    formatNumber(held ?? RUN_FLOW.temperature.default)

// ========================================================================================
// 3. Claim
// ========================================================================================

/**
 * Starting a run, before any process exists: the NAME of the run folder, the CLAIM of it
 * (one locked step that scans for a live run and makes the folder, so two copies cannot
 * both win) and the SNAPSHOT of the inputs (Julia reads only that copy, so editing the
 * project during a run changes nothing). Rules: notes/run-design.md, "Concurrency".
 */

/**
 * A claimed run folder.
 *
 * @property id - its name (`runStamp`).
 * @property dir - the folder.
 */
export type ClaimedRun = { id: string; dir: string }

/**
 * Writes (renews) the claim marker of a run folder: this process, this host, now.
 *
 * @throws if the folder is gone.
 */
function writeClaim(runDir: string): void {
    const claim = { pid: process.pid, host: hostname(), time: isoStamp(Date.now()) }
    writeAtomic(join(runDir, CLAIM_FILE), writeJson(claim), { createParents: false })
}

/**
 * Claims a new run folder of a project. Under the lock `<project>/runs/.start` it looks
 * for a live run and, if none, makes `runs/<name>/` with a NON-recursive `mkdir` (a taken
 * name tries the next millisecond) and leaves the claim marker, which keeps the folder
 * live until Julia writes its own `run.json`. The project must exist.
 *
 * @param now - the time in ms (the clock when left out; tests give a fixed one).
 * @throws [[RunInProgressError]] (`a run is in progress (pid N)`); `ProjectGoneError` for
 *     a project that is not there; [[FileInUseError]] if the lock stays taken for 3 s;
 *     Error if no free name is found in `claim.maxStampTries` milliseconds.
 */
export function claimRun(projectDir: string, now: number = Date.now()): ClaimedRun {
    return inProject(projectDir, () => {
        const runs = join(projectDir, "runs")
        try {
            mkdirSync(runs) // not recursive: a missing project is an error, not made again
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error
        }
        return withFileLock(
            join(runs, startLockName),
            () => {
                const live = liveRun(projectDir)
                if (live !== undefined) throw new RunInProgressError(live.pid)
                const tries = RUN_FLOW.claim.maxStampTries
                for (let ms = Math.floor(now), n = 0; n < tries; ms++, n++) {
                    const id = runStamp(ms)
                    const dir = runDirOf(projectDir, id)
                    try {
                        mkdirSync(dir)
                    } catch (error) {
                        if ((error as NodeJS.ErrnoException).code === "EEXIST") continue
                        throw error
                    }
                    writeClaim(dir)
                    return { id, dir }
                }
                throw new Error("no free name for the run folder")
            },
            { createParents: false },
        )
    })
}

/** The files of a project the snapshot copies, in the order they are locked and copied. */
function snapshotFiles(projectDir: string): [string, string][] {
    return [
        [settingsFile(projectDir), RUN_FILES.settings],
        [bufferFile(projectDir), RUN_FILES.buffer],
    ]
}

/**
 * Copies the inputs of a run into its flat folder (reference fits as
 * `reference-fit-<file>`), each under the lock of its own file (`settings.json`,
 * `buffer.json`, then `data.tsv` outside `data.json`, the data writer's order), so a
 * save in another copy is waited for. A project without `settings.json` gets `{}` (the
 * defaults). `model-settings.json`, `model-references.json`, the reference curves
 * (`reference-fit.7z` or the old folder) and `project.json` are copied when present. The
 * models are not copied: Julia lists them in `models.json` when the run starts, except for
 * a project that keeps them in `models.7z` ([[stageModels]] writes that file).
 *
 * @throws if a file the run needs (`buffer.json`, `data.tsv`, `data.json`) is missing,
 *     [[FileInUseError]], `ProjectGoneError`.
 */
export function snapshotInputs(projectDir: string, runDir: string): void {
    const logs = runDir
    mkdirSync(logs, { recursive: true })
    for (const [from, name] of snapshotFiles(projectDir)) {
        lockedIn(projectDir, from, () => {
            if (isFile(from)) copyOver(from, join(logs, name))
            else if (name === RUN_FILES.settings) writeAtomic(join(logs, name), "{}\n")
            else throw new Error(`the project has no ${name}`)
        })
    }
    const tsv = dataTsvFile(projectDir)
    const json = dataJsonFile(projectDir)
    lockedIn(projectDir, [tsv, json], () => {
        for (const [from, name] of [
            [tsv, RUN_FILES.dataTable],
            [json, RUN_FILES.dataInfo],
        ] as const) {
            if (!isFile(from)) throw new Error(`the project has no ${name}`)
            copyOver(from, join(logs, name))
        }
    })
    // `project.json` (with the notes) travels with the run into its archive
    const project = projectFile(projectDir)
    lockedIn(projectDir, project, () => {
        if (isFile(project)) copyOver(project, join(logs, "project.json"))
    })
    // the optional inputs, under their own locks: per-model settings and reference curves
    const models = modelSettingsFile(projectDir)
    lockedIn(projectDir, models, () => {
        if (isFile(models)) copyOver(models, join(logs, RUN_FILES.modelSettings))
    })
    const modelReferences = modelReferencesFile(projectDir)
    lockedIn(projectDir, modelReferences, () => {
        if (isFile(modelReferences))
            copyOver(modelReferences, join(logs, RUN_FILES.modelReferences))
    })
    // the reference curves (`reference-fit.7z`, or the old folder) and the models
    // (extracted when the project keeps them in `models.7z`) under the archive's lock
    lockedIn(projectDir, referencesArchive(projectDir), () => {
        copyReferences(projectDir, logs)
    })
    stageModels(projectDir, runDir)
}

/** The names the run's own files use: a model may not take them (Julia's rule). */
const RESERVED_MODEL_NAMES: readonly string[] = ["run", "compare"]

/**
 * When the project keeps its models in `models.7z`, extracts them into the run's own
 * temporary folder ([[runModelsFolder]]) and writes the run's `models.json` with those
 * paths, which Julia keeps when it finds the file: so Julia reads the models as it always
 * did, a path to a file, and needs no 7-Zip. The entries follow Julia's own rule
 * (`_projectModels`): file names in byte order, the stem as the name, `-2`, `-3`, ... for
 * a taken stem or a name of the run's own files. A project without an archive is left to
 * Julia (the old `models/` folder).
 *
 * The same archive holds the files Julia generated in earlier runs (hydrogenated
 * structures, PROPKA output): they are extracted into the run's own cache folder
 * ([[runCache]]), which the launcher gives Julia as `BAYSOL_CACHE`, so a repeated run finds
 * them and the files of a new one are stored after the run ([[packGenerated]]). The
 * components Julia downloads stay in the shared cache: the folder holds a link to it.
 *
 * @param sharedCache - the shared cache folder, only asked for when the project is packed.
 *
 * @returns the folder the models were extracted into, `undefined` when there is none.
 * @throws ArchiveError (7-Zip missing or failing), ProjectGoneError, FileInUseError.
 */
export function stageModels(
    projectDir: string,
    runDir: string,
    sharedCache: () => string = cacheDir,
): string | undefined {
    const archive = modelsArchive(projectDir)
    return lockedIn(projectDir, archive, () => {
        const state = packState(projectDir, MODELS_PACK)
        if (state.kind !== "packed") return undefined
        const folder = runModelsFolder(runDir)
        rmSync(folder, { recursive: true, force: true })
        const names = [...state.names].sort()
        extractModels(projectDir, names, folder)
        const used = new Set<string>(RESERVED_MODEL_NAMES)
        const entries = names.map((file) => {
            const path = join(folder, file)
            const stem = modelStem(file)
            let name = stem
            for (let k = 2; used.has(name); k++) name = `${stem}-${k}`
            used.add(name)
            const bytes = readFileSync(path)
            return {
                name,
                path,
                size: bytes.length,
                sha256: createHash("sha256").update(bytes).digest("hex"),
            }
        })
        writeAtomic(join(runDir, RUN_FILES.models), `${JSON.stringify(entries, null, 2)}\n`)
        const cache = runCacheFolder(runDir)
        rmSync(cache, { recursive: true, force: true })
        linkComponents(extractGenerated(projectDir, cache), sharedCache())
        return folder
    })
}

/**
 * Links the component files Julia downloads (`components/` of its cache) to the shared
 * cache, so a run with its own cache folder does not fetch them again. Where a link
 * cannot be made (Windows without the right) Julia downloads them again.
 */
function linkComponents(cache: string, shared: string): void {
    try {
        const components = join(shared, "components")
        mkdirSync(components, { recursive: true })
        symlinkSync(components, join(cache, "components"), "dir")
    } catch {
        // no link: the components are fetched into this run's cache
    }
}

/**
 * @returns the cache folder of a run whose project keeps its models in `models.7z`
 *     ([[stageModels]] made it), `undefined` for the other projects (Julia then uses the
 *     shared cache).
 */
export function runCache(runDir: string): string | undefined {
    const folder = join(runCacheFolder(runDir), GENERATED_DIR)
    return isFolder(folder) ? folder : undefined
}

/** Removes the folders [[stageModels]] made for a run (the models are in the project). */
export function unstageModels(runDir: string): void {
    rmSync(runModelsFolder(runDir), { recursive: true, force: true })
    rmSync(runCacheFolder(runDir), { recursive: true, force: true })
}

/**
 * The startup sweep of every project ([[markStaleRuns]]). A project that cannot be swept
 * (a lock held, a folder gone) is skipped; the sweep never stops the program starting.
 */
export function markAllStaleRuns(projectsRoot: string): string[] {
    const changed: string[] = []
    for (const id of listProjects(projectsRoot)) {
        try {
            for (const run of markStaleRuns(join(projectsRoot, id)))
                changed.push(`${id}/${run}`)
        } catch {
            // a lock held for too long, a project that went away: the next one
        }
    }
    return changed
}

/**
 * Gives up a claimed run whose start failed before Julia ran: the folder stays (a run is
 * never deleted) marked `failed`; the caller writes the reason into `run.LOG`.
 */
function abandonClaim(runDir: string): boolean {
    try {
        return settleRun(runDir, "failed")
    } catch {
        return false
    }
}

// ========================================================================================
// 4. Output tail
// ========================================================================================

/**
 * The live output of a run, as lines for the run screen. Julia's output is not fit as it
 * comes: a progress bar rewrites its line with a carriage return, and colour and cursor
 * codes are escapes. One small state per stream (stdout, stderr), the last lines of both.
 */

/** The state of one stream: the unfinished line, a `\r` just seen, an unfinished escape. */
type Channel = { pending: string; cr: boolean; carry: string }

/** An escape sequence cut short at the end of a chunk. */
// biome-ignore lint/suspicious/noControlCharactersInRegex: that is what is matched
const CUT_ESCAPE = /\x1b(?:\[[\x20-\x3f]*|\][^\x07\x1b]*)?$/

/** The columns a tab is shown as. */
const TAB = "    "

/** The last lines of the output of a process, cleaned for display. */
export class OutputTail {
    private readonly done: string[] = []
    private readonly channels: Channel[] = []

    constructor(private readonly max: number) {}

    /**
     * Takes a piece of a stream. A line ends at a newline; a carriage return not followed
     * by one sends the writing back to the line start (the next text replaces it); escape
     * sequences are dropped (one cut by the chunk's end waits for the next), a tab is
     * spaces, other control characters are dropped.
     *
     * @param channel - which stream (0 and 1: each has its own unfinished line).
     */
    feed(channel: number, chunk: string): void {
        this.channels[channel] ??= { pending: "", cr: false, carry: "" }
        const ch = this.channels[channel] as Channel
        let text = ch.carry + chunk
        ch.carry = CUT_ESCAPE.exec(text)?.[0] ?? ""
        text = stripVTControlCharacters(text.slice(0, text.length - ch.carry.length))
        for (const c of text) {
            if (c === "\n") {
                this.done.push(ch.pending)
                ch.pending = ""
                ch.cr = false
            } else if (c === "\r") ch.cr = true
            else if (c === "\t" || (c >= " " && c !== "\x7f")) {
                if (ch.cr) ch.pending = ""
                ch.cr = false
                ch.pending += c === "\t" ? TAB : c
            }
        }
        if (this.done.length > this.max) this.done.splice(0, this.done.length - this.max)
    }

    /** The lines so far: the finished ones, then each stream's unfinished line. */
    get lines(): string[] {
        const open = this.channels.map((c) => c.pending).filter((p) => p !== "")
        return [...this.done, ...open]
    }
}

// ========================================================================================
// 5. Session
// ========================================================================================

/**
 * One run of a project, from the claimed folder to its end: the snapshot, the Julia child
 * (own process group, stdin kept open because Julia ends the run at end of file), the
 * live output, the end (read from Julia's `run.json` or, failing that, written here) and
 * the abort. Julia knows nothing of this program; the screen only watches a
 * [[RunSession]].
 */

/** What the run is doing: runs, is stopped, is packed (`run-archive.ts`), or is over. */
export type RunPhase = "running" | "aborting" | "packing" | "done" | "failed" | "aborted"

/** Whether a phase is an end: the run is over. */
export const isEnd = (phase: RunPhase): boolean =>
    phase === "done" || phase === "failed" || phase === "aborted"

/**
 * What a screen shows of a run. A new object for every change, so it can be compared.
 *
 * @property id - the run's name (its stamp).
 * @property project - the project's name.
 * @property phase - see [[RunPhase]].
 * @property lines - the tail of the output, oldest first.
 * @property startedMs - when it was started (ms since 1970).
 * @property endedMs - when the child ended (`undefined` while it runs).
 * @property note - something to tell the user (a failed start).
 */
export type RunView = {
    readonly id: string
    readonly project: string
    readonly phase: RunPhase
    readonly lines: readonly string[]
    readonly startedMs: number
    readonly endedMs: number | undefined
    readonly note: string | undefined
}

/**
 * What a launcher needs to start the child.
 *
 * @property projectDir - the project's folder.
 * @property runDir - the claimed run folder.
 * @property temperature - the buffer's temperature, °C.
 * @property cache - the run's own cache folder (`BAYSOL_CACHE`), absent: the shared one.
 */
export type LaunchSpec = {
    projectDir: string
    runDir: string
    temperature: number
    cache?: string
}

/**
 * Starts the process that fits the project: a child with three pipes in a process group
 * of its own (`detached`), so the abort can signal the group. The real one starts Julia
 * ([[juliaLauncher]]); the tests give a script.
 */
export type Launcher = (spec: LaunchSpec) => ChildProcess

/**
 * What Julia runs: the package `BAYSOLRun` (`tui/julia`; in a packaged run it is part of
 * the sysimage, so nothing is compiled at start). The values are `ARGS[1..3]` (project,
 * temperature, run folder), never spliced into the code.
 */
const juliaProgram =
    "using BAYSOLRun; BAYSOLRun.runProject(ARGS[1]; temperature = parse(Float64, " +
    "ARGS[2]), ui = :tui, runDir = ARGS[3])"

/** The Julia program to start: the `JULIA` environment variable, else `julia`. */
export function juliaCommand(env: Record<string, string | undefined>): string {
    const named = (env.JULIA ?? "").trim()
    return named === "" ? "julia" : named
}

/**
 * The arguments of the Julia child: no start-up file, no colour codes, the threads of
 * `assets/data/run_flow.json`, the environment of the package `BAYSOLRun` (`tui/julia`
 * of a checkout), then `-e` the program and its three values (project, temperature,
 * run folder).
 *
 * @param root - the package folder, or `undefined` (packaged: the sysimage holds BAYSOL and
 *     `BAYSOLRun`, and the launcher chose the environment).
 */
export function juliaArgs(
    spec: LaunchSpec,
    root: string | undefined,
    threads: string,
): string[] {
    return [
        "--startup-file=no",
        "--color=no",
        `--threads=${threads}`,
        ...(root === undefined ? [] : [`--project=${join(root, "tui", "julia")}`]),
        "-e",
        juliaProgram,
        spec.projectDir,
        String(spec.temperature),
        spec.runDir,
    ]
}

let traceCount = 0

/**
 * The `--trace-compile` flag of a Julia child when `BAYSOL_TRACE_COMPILE` names a folder
 * (the packaging build records what the TUI tests make Julia compile): one file per child.
 */
export function traceFlag(
    env: Record<string, string | undefined>,
    pid: number,
): string[] {
    const dir = env.BAYSOL_TRACE_COMPILE
    if (!dir) return []
    traceCount += 1
    return [`--trace-compile=${join(dir, `tui-${pid}-${traceCount}.jl`)}`]
}

/** The threads of a run: `BAYSOL_THREADS` (the setup wizard's choice), else the default. */
function juliaThreads(): string {
    return process.env.BAYSOL_THREADS || RUN_FLOW.julia.threads
}

/**
 * The real launcher: `julia ... -e 'using BAYSOLRun; BAYSOLRun.runProject(...)'` in its own
 * process group, with this program's cache folder and three pipes.
 *
 * @returns the child. A Julia that cannot be started arrives as its `error` event.
 */
const juliaLauncher: Launcher = (spec) => {
    const packaged = bundledCommand(process.env, spec)
    const [command, args] = packaged ?? [
        juliaCommand(process.env),
        [
            ...traceFlag(process.env, process.pid),
            ...juliaArgs(spec, repoRoot(), juliaThreads()),
        ],
    ]
    return spawn(command, args, {
        detached: true,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
        env: {
            ...process.env,
            BAYSOL_CACHE: spec.cache ?? cacheDir(),
            ...(packaged ? { JULIA_NUM_THREADS: juliaThreads() } : {}),
        },
    })
}

/**
 * The packaged app's way to a fit: the `baysol` executable beside this program
 * (`BAYSOL_BUNDLE`) with `run-tui PROJECT TEMPERATURE RUNDIR`.
 *
 * @returns the command and its arguments, or `undefined` when there is no bundle (a
 *     checkout starts Julia instead).
 */
export function bundledCommand(
    env: Record<string, string | undefined>,
    spec: LaunchSpec,
): [string, string[]] | undefined {
    const bundle = env.BAYSOL_BUNDLE
    if (!bundle) return undefined
    const exe = join(bundle, exeName(readSystem(), "baysol"))
    if (!existsSync(exe)) return undefined
    return [exe, ["run-tui", spec.projectDir, String(spec.temperature), spec.runDir]]
}

/**
 * Sends a signal to a child's whole process group. On Windows, which has no signal
 * groups, `taskkill /T` ends the tree.
 *
 * @param pid - the child's pid, also its group's id (it leads the group).
 */
function signalGroup(pid: number, signal: NodeJS.Signals): void {
    if (isWindows(readSystem())) {
        spawnSync("taskkill", ["/pid", String(pid), "/T", "/F"], { windowsHide: true })
        return
    }
    try {
        process.kill(-pid, signal)
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ESRCH") return
        try {
            process.kill(pid, signal)
        } catch {
            // it is gone
        }
    }
}

/** Whether anything of a process group is still alive. */
function groupAlive(pid: number): boolean {
    if (isWindows(readSystem())) return false
    try {
        process.kill(-pid, 0)
        return true
    } catch (error) {
        return (error as NodeJS.ErrnoException).code === "EPERM"
    }
}

/**
 * Appends text to the run's `run.LOG` (made if Julia never got to). The file has one
 * writer: this is only called once Julia is gone.
 *
 * @param text - what to add; an `=== ERRORS ===` heading goes first when the log has none.
 */
function appendToLog(runDir: string, text: string): void {
    mkdirSync(runDir, { recursive: true })
    const file = join(runDir, "run.LOG")
    let before = ""
    try {
        before = readFileSync(file, "utf-8")
    } catch {
        writeFileSync(file, "")
    }
    const head = before.includes("=== ERRORS ===") ? "\n" : "\n=== ERRORS ===\n"
    appendFileSync(file, `${head}${text}\n`)
}

/**
 * The first error of a run's `run.LOG` ERRORS section in a few words, for the note row
 * of a failed run (`tui: ...` lines stay as they are); the full text stays in the log.
 *
 * @returns the line, or `undefined` when the log cannot be read or has no error.
 */
function failureNote(runDir: string): string | undefined {
    try {
        const line = firstErrorLine(readLogText(runDir))
        return line === undefined || line.startsWith("tui: ") ? line : briefError(line)
    } catch {
        return undefined
    }
}

/** The elapsed time as a clock. */
export function elapsedText(ms: number): string {
    const total = Math.max(0, Math.floor(ms / 1000))
    const s = String(total % 60).padStart(2, "0")
    const m = Math.floor(total / 60) % 60
    const h = Math.floor(total / 3600)
    return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`
}

/** The sessions that have not ended; the quit paths abort them. */
const active = new Set<RunSession>()

/** Sleeps. */
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

/** How long the end waits for the child's pipes to drain after it exited (ms). */
const DRAIN_MS = 500

/**
 * A run in progress or just over. Create one with [[RunSession.begin]]; watch it with
 * [[RunSession.subscribe]]; stop it with [[RunSession.abort]].
 */
export class RunSession {
    /** Settles with the final phase once the run is over. */
    readonly done: Promise<RunPhase>
    private resolveDone!: (phase: RunPhase) => void
    private readonly listeners = new Set<() => void>()
    private readonly tail: OutputTail
    private current: RunView
    private stopping: string | undefined
    private killed = false
    private childExited: Promise<void>
    private childClosed: Promise<void>
    private readonly timers: NodeJS.Timeout[] = []
    private aborting: Promise<void> | undefined
    private ending = false

    private constructor(
        private readonly projectDir: string,
        private readonly runDir: string,
        private readonly child: ChildProcess,
        id: string,
        project: string,
        private readonly pack: (runDir: string) => Promise<number>,
    ) {
        this.done = new Promise((resolve) => {
            this.resolveDone = resolve
        })
        this.tail = new OutputTail(RUN_FLOW.screen.tailLines)
        this.current = {
            id,
            project,
            phase: "running",
            lines: [],
            startedMs: Date.now(),
            endedMs: undefined,
            note: undefined,
        }
        this.childExited = new Promise((resolve) => child.once("exit", () => resolve()))
        this.childClosed = new Promise((resolve) => child.once("close", () => resolve()))
        this.watch()
    }

    /**
     * Starts a run: claims the run folder (a live run refuses it), copies the inputs and
     * starts the child. If a step fails the folder is marked `failed` and the error is
     * thrown.
     *
     * @param launcher - what starts the child, [[juliaLauncher]] when left out.
     * @param pack - what packs the run once it is over, [[packRun]] when left out.
     * @throws [[RunInProgressError]] (`a run is in progress (pid N)`), `ProjectGoneError`,
     *     [[FileInUseError]], or the error of a missing input file.
     */
    static begin(
        projectDir: string,
        temperature: number,
        launcher: Launcher = juliaLauncher,
        pack: (runDir: string) => Promise<number> = packRun,
    ): RunSession {
        const claimed = claimRun(projectDir)
        let child: ChildProcess
        try {
            snapshotInputs(projectDir, claimed.dir)
            child = launcher({
                projectDir,
                runDir: claimed.dir,
                temperature,
                cache: runCache(claimed.dir),
            })
        } catch (error) {
            try {
                appendToLog(
                    claimed.dir,
                    `tui: could not start: ${(error as Error).message}`,
                )
            } finally {
                unstageModels(claimed.dir)
                abandonClaim(claimed.dir)
            }
            throw error
        }
        const name = projectDir.split(/[\\/]/).filter(Boolean).pop() ?? projectDir
        const session = new RunSession(
            projectDir,
            claimed.dir,
            child,
            claimed.id,
            name,
            pack,
        )
        active.add(session)
        return session
    }

    /** What the screen shows now; the same object until something changes. */
    get view(): RunView {
        return this.current
    }

    /** Calls `listener` after every change of the view. */
    subscribe = (listener: () => void): (() => void) => {
        this.listeners.add(listener)
        return () => {
            this.listeners.delete(listener)
        }
    }

    /** The view as a snapshot for `useSyncExternalStore`. */
    snapshot = (): RunView => this.current

    /** Changes the view and tells the listeners. */
    private update(change: Partial<RunView>): void {
        this.current = { ...this.current, ...change }
        for (const listener of this.listeners) listener()
    }

    /** Wires the child: its output, its end, and the claim marker's renewal. */
    private watch(): void {
        const { child } = this
        const feed = (channel: number) => (chunk: Buffer) => {
            this.tail.feed(channel, chunk.toString("utf-8"))
            this.update({ lines: this.tail.lines })
        }
        child.stdout?.on("data", feed(0))
        child.stderr?.on("data", feed(1))
        // Julia ends the run when this pipe reaches end of file, so it stays open
        child.stdin?.on("error", () => {})
        // a Julia that cannot be started: there is no exit, only this event
        child.once("error", (error) => {
            this.update({ note: `could not start julia: ${error.message}` })
            void this.finish(null, null, `could not start julia: ${error.message}`)
        })
        child.once("exit", (code, signal) => void this.finish(code, signal))
        // while Julia loads there is no run.json: the marker keeps the folder live
        const renew = setInterval(() => {
            try {
                if (runStatus(this.projectDir, this.current.id) === undefined)
                    writeClaim(this.runDir)
            } catch {
                // the folder is gone; nothing to keep alive
            }
        }, RUN_FLOW.liveness.claimRefreshSeconds * 1000)
        renew.unref()
        this.timers.push(renew)
    }

    /** Ends the run once the child has: final status if Julia gave none, [[done]]. */
    private async finish(
        code: number | null,
        signal: NodeJS.Signals | null,
        problem?: string,
    ): Promise<void> {
        if (this.ending) return
        this.ending = true
        for (const timer of this.timers) clearInterval(timer)
        await Promise.race([this.childClosed, sleep(DRAIN_MS)])
        this.update({ endedMs: Date.now() })
        try {
            let status = runStatus(this.projectDir, this.current.id)
            if (status === undefined || status === "running") {
                // Julia did not finish its files: the run is over all the same
                const stopped = this.stopping !== undefined
                const how =
                    problem ??
                    (stopped
                        ? `aborted from the terminal interface (${this.stopping})`
                        : `julia ended unexpectedly (${signal ?? `exit code ${code}`})`)
                appendToLog(
                    this.runDir,
                    `tui: ${how}${this.killed ? "; killed after the grace time" : ""}`,
                )
                settleRun(this.runDir, stopped ? "aborted" : "failed")
                status = stopped ? "aborted" : "failed"
            } else if (this.killed) {
                appendToLog(this.runDir, "tui: julia was killed after the grace time")
            }
            let note = this.current.note
            const phase: RunPhase =
                status === "done" ? "done" : status === "aborted" ? "aborted" : "failed"
            // a failed run tells why: the first line of its ERRORS section
            if (phase === "failed" && note === undefined)
                note = failureNote(this.runDir)
            // a pack that fails leaves the folder as it was; the outcome is unchanged
            this.update({ phase: "packing", note })
            try {
                await this.pack(this.runDir)
            } catch (error) {
                const why = messageOf(error, "unknown error")
                note = `not packed: ${why}`
            }
            // what Julia generated goes into the project's `models.7z`, in the background
            const cache = runCache(this.runDir)
            if (phase === "done" && cache !== undefined) {
                try {
                    await packGenerated(this.projectDir, cache)
                } catch (error) {
                    const why = messageOf(error, "unknown error")
                    const lead = note === undefined ? "" : `${note}; `
                    note = `${lead}generated files not stored: ${why}`
                }
            }
            this.update({ phase, note })
        } catch (error) {
            this.update({ phase: "failed", note: (error as Error).message })
        } finally {
            unstageModels(this.runDir)
            active.delete(this)
            this.resolveDone(this.current.phase)
        }
    }

    /**
     * Stops the run: SIGTERM to the child's process group, a few seconds for Julia to
     * finish its log, then SIGKILL; the end follows as for any end. Calling it again
     * returns the same promise.
     *
     * @param reason - what asked for it, e.g. `^c`; it goes into the run's errors.
     */
    abort(reason: string): Promise<void> {
        this.aborting ??= this.stop(reason)
        return this.aborting
    }

    /** The steps of [[abort]]. */
    private async stop(reason: string): Promise<void> {
        if (this.current.endedMs !== undefined) {
            await this.done
            return
        }
        const pid = this.child.pid
        this.stopping = reason
        this.update({ phase: "aborting" })
        if (pid !== undefined) {
            const { graceSeconds, killWaitSeconds } = RUN_FLOW.abort
            signalGroup(pid, "SIGTERM")
            let gone = await Promise.race([
                this.childExited.then(() => true),
                sleep(graceSeconds * 1000).then(() => false),
            ])
            if (!gone || groupAlive(pid)) {
                this.killed = true
                signalGroup(pid, "SIGKILL")
                gone = await Promise.race([
                    this.childExited.then(() => true),
                    sleep(killWaitSeconds * 1000).then(() => false),
                ])
            }
            // a child that will not even die: end the run without it
            if (!gone) void this.finish(null, "SIGKILL")
        }
        await this.done
    }

    /** Kills the group at once, for the last gasp of the process (no waiting, no files). */
    killNow(): void {
        const pid = this.child.pid
        if (pid !== undefined) signalGroup(pid, "SIGKILL")
    }
}

/** @returns whether a run is going (it has not ended yet). */
export function hasActiveRuns(): boolean {
    return active.size > 0
}

/**
 * Stops every run going and waits until each is over, and for the writes of the archives
 * still going (^c, ^d, SIGHUP, SIGTERM).
 */
export async function quitAll(reason: string): Promise<void> {
    await Promise.all([...active].map((session) => session.abort(reason)))
    // a write of `models.7z` or `reference-fit.7z` in the background finishes first
    await settleWrites()
}

/**
 * Kills the process group of every run going, synchronously: only for the process's
 * `exit` event, when nothing can be awaited (a crash). Julia's end-of-input watch is the
 * backstop.
 */
export function killAllNow(): void {
    for (const session of active) session.killNow()
}
