// SPDX-License-Identifier: LGPL-3.0-or-later

// Run: starting a run and running it.
//
// Contents:
//   1. Readiness: what a project has of what a run needs
//   2. Temperature prompt: the text of the prompt that starts a run
//   3. Claim: the run folder's name, the claim, the snapshot of the inputs, stale sweeps
//   4. Output: the tail of Julia's output that the run page shows
//   5. Session: the Julia child process of one run, its phases and the quit/kill hooks
//
// The state of the run folders on disk (status, liveness, settling) is in `projects.ts`,
// the data of `open runs` in `run-logs.ts`.

import { type ChildProcess, spawn, spawnSync } from "node:child_process"
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { join } from "node:path"
import { stripVTControlCharacters } from "node:util"
import { cacheDir, RUN_FLOW, repoRoot } from "../core/environment.js"
import {
    copyOver,
    isFile,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import { formatNumber, type Parsed, parseNumber } from "../core/terminal.js"
import { bufferFile, readConditions, readSolutes } from "./buffer.js"
import { dataIsReady, dataJsonFile, dataTsvFile } from "./data.js"
import { modelReferencesFile } from "./model-references.js"
import type { ProjectRef } from "./projects.js"
import {
    CLAIM_FILE,
    inProject,
    isoStamp,
    listModels,
    listProjects,
    liveRun,
    lockedIn,
    markStaleRuns,
    RunInProgressError,
    runDirOf,
    runStatus,
    settleRun,
    startLockName,
} from "./projects.js"
import { migrateReferences, referenceFiles, referencesDir } from "./references.js"
import { packRun } from "./run-archive.js"
import { briefError, firstErrorLine, readLogText } from "./run-logs.js"
import { runStamp } from "./run-stamp.js"
import { modelSettingsFile, settingsFile } from "./settings-store.js"

// ========================================================================================
// 1. Readiness
// ========================================================================================

/**
 * What a project has of what a run needs, one flag each.
 *
 * @property models - at least one model.
 * @property buffer - a buffer with at least one solute and its pH set (a buffer file
 *     that cannot be read counts as missing).
 * @property data - the measured curve is loaded (`data.tsv` and `data.json` valid) and
 *     the X-ray energy is set (there is no default energy).
 * @property run - everything above is there, so a run can start.
 */
export type Readiness = {
    models: boolean
    buffer: boolean
    data: boolean
    run: boolean
}

/**
 * Whether a project can run a fit, and which parts it still lacks. The project menu
 * shows the `run` item of its taskbar only when `run` is true.
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
            readConditions(project.dir) !== undefined,
    )
    const data = attempt(() => dataIsReady(project.dir))
    return { models, buffer, data, run: models && buffer && data }
}

// ========================================================================================
// 2. Temperature prompt
// ========================================================================================

/**
 * The one question a run asks: the temperature of the buffer, in °C, with no uncertainty.
 * The range and the starting value are `RUN_FLOW.temperature`.
 */

/** The label of the temperature prompt. */
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
 * The text the temperature prompt starts with.
 *
 * @param last - the temperature of the newest finished run, if there is one.
 * @returns it, else the default of `RUN_FLOW.temperature`.
 */
export const temperatureStart = (last?: number): string =>
    formatNumber(last ?? RUN_FLOW.temperature.default)

// ========================================================================================
// 3. Claim
// ========================================================================================

/**
 * Starting a run, the part before any process exists: the NAME of the run folder, the
 * claim of it (one locked step that scans for a live run and makes the folder, so two
 * copies of the program starting at the same instant cannot both win) and the SNAPSHOT of
 * the inputs into its run folder (Julia reads only that copy, so editing the project
 * during a run changes nothing). The rules are those of notes/run-design.md, "Concurrency".
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
 * Claims a new run folder of a project. Under `withFileLock(<project>/runs/.start)` it
 * looks for a live run and, if there is none, makes `runs/<name>/` with a NON-recursive
 * `mkdir` (the name is taken: the next millisecond is tried, so a folder is never
 * overwritten)
 * and leaves the claim marker in it, which keeps the folder live until Julia writes its
 * own `run.json`. The project must exist: nothing here brings a deleted project back.
 *
 * @param now - the time in ms (the clock when left out; tests give a fixed one to make
 *     names clash).
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
        [settingsFile(projectDir), "settings.json"],
        [bufferFile(projectDir), "buffer.json"],
    ]
}

/**
 * Copies the inputs of a run into its folder (flat: the run folder has no subfolders, the
 * reference fits are `reference-fit-<file>`), each under the lock of its own file
 * (`settings.json`, `buffer.json`, then `data.tsv` outside `data.json`, the order the data
 * writer locks them in), so a save in progress in another copy is waited for and a copy is
 * never half a file. A project without `settings.json` gets `{}` (the defaults, as Julia
 * does). `model-settings.json`, `model-references.json` and the files of `reference-fit/`
 * are copied too when the project has them (Julia copies them itself otherwise, without
 * our locks). The models are not copied: Julia lists them (name, full path, size, sha256)
 * in `models.json` when the run starts.
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
            else if (name === "settings.json") writeAtomic(join(logs, name), "{}\n")
            else throw new Error(`the project has no ${name}`)
        })
    }
    const tsv = dataTsvFile(projectDir)
    const json = dataJsonFile(projectDir)
    lockedIn(projectDir, [tsv, json], () => {
        for (const [from, name] of [
            [tsv, "data.tsv"],
            [json, "data.json"],
        ] as const) {
            if (!isFile(from)) throw new Error(`the project has no ${name}`)
            copyOver(from, join(logs, name))
        }
    })
    // the optional inputs, under their own locks: the per-model settings and the
    // reference curves (the files only; Julia reads them from the run folder and uses
    // `reference-fit-*` files that are there as they are)
    const models = modelSettingsFile(projectDir)
    lockedIn(projectDir, models, () => {
        if (isFile(models)) copyOver(models, join(logs, "model-settings.json"))
    })
    const modelReferences = modelReferencesFile(projectDir)
    lockedIn(projectDir, modelReferences, () => {
        if (isFile(modelReferences))
            copyOver(modelReferences, join(logs, "model-references.json"))
    })
    migrateReferences(projectDir) // an old `references/` folder gets its new name first
    const references = referencesDir(projectDir)
    lockedIn(projectDir, references, () => {
        const files = referenceFiles(projectDir)
        if (files.length === 0) return
        for (const file of files)
            copyOver(join(references, file), join(logs, `reference-fit-${file}`))
    })
}

/**
 * The startup sweep of every project: a `running` run nobody runs any more becomes
 * `interrupted` ([[markStaleRuns]]). A project that cannot be swept (a lock held, a folder
 * that vanished) is skipped; the sweep never stops the program from starting.
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
 * Gives up a claimed run whose start failed before Julia was running: the folder stays (a
 * run is never deleted by the program) and is marked `failed`, with the reason written
 * into its `run.LOG` by the caller.
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
 * The live output of a run, as lines for the run screen. What Julia prints is not fit for
 * the screen as it comes: a progress bar rewrites its line with a carriage return and
 * colour and cursor codes are escape sequences. One small state per stream (standard
 * output and standard error) and the last lines of both.
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
     * by a newline sends the writing back to the start of the line (the next text replaces
     * it, as a progress bar does); escape sequences are dropped (one cut by the end of the
     * chunk waits for the next), a tab is spaces, other control characters are dropped.
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

    /**
     * The lines so far: the finished ones, then the unfinished line of each stream that
     * has one.
     */
    get lines(): string[] {
        const open = this.channels.map((c) => c.pending).filter((p) => p !== "")
        return [...this.done, ...open]
    }
}

// ========================================================================================
// 5. Session
// ========================================================================================

/**
 * One run of a project, from the claimed folder to its end: the snapshot, the Julia
 * child (its own process group, its stdin kept open because Julia ends the run when it
 * reaches end of file), the live output, the end (done, failed or aborted, read from the
 * `run.json` Julia wrote or, when Julia could not, written here), and the abort. Julia
 * knows nothing of this program; it reads the snapshot and writes plain files.
 * The screen only watches a [[RunSession]].
 */

/**
 * What the run is doing: runs, is being stopped, is being packed into its archive (the
 * process is over; see `run-archive.ts`), or is over.
 */
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
 */
export type LaunchSpec = { projectDir: string; runDir: string; temperature: number }

/**
 * Starts the process that fits the project. It must return a child with three pipes, in
 * a process group of its own (`detached`), so the abort can signal the whole group. The
 * real one starts Julia ([[juliaLauncher]]); the tests give a script in its place.
 */
export type Launcher = (spec: LaunchSpec) => ChildProcess

/** What Julia runs: the arguments come in `ARGS`, never spliced into the code. */
const juliaProgram =
    "using BAYSOL; BAYSOL.run_project(ARGS[1]; temperature = parse(Float64, ARGS[2]), " +
    "ui = :tui, run_dir = ARGS[3])"

/**
 * The Julia program to start: the `JULIA` environment variable (the one the dev tools
 * use), else `julia` on the PATH.
 */
export function juliaCommand(env: Record<string, string | undefined>): string {
    const named = (env.JULIA ?? "").trim()
    return named === "" ? "julia" : named
}

/**
 * The arguments of the Julia child: no start-up file, no colour codes in the output, the
 * threads of `assets/data/run_flow.json`, the BAYSOL package folder (when the program
 * runs from a checkout), then `-e` the program and the three values it takes.
 *
 * @param root - the package folder, or `undefined` (a packaged program: Julia's own
 *     environment holds BAYSOL).
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
        ...(root === undefined ? [] : [`--project=${root}`]),
        "-e",
        juliaProgram,
        spec.projectDir,
        String(spec.temperature),
        spec.runDir,
    ]
}

/**
 * The real launcher: `julia ... -e 'using BAYSOL; BAYSOL.run_project(...)'` in its own
 * process group, with the same cache folder as this program and three pipes.
 *
 * @returns the child. A Julia that cannot be started arrives as its `error` event.
 */
const juliaLauncher: Launcher = (spec) =>
    spawn(juliaCommand(process.env), juliaArgs(spec, repoRoot(), RUN_FLOW.julia.threads), {
        detached: true,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env, BAYSOL_CACHE: cacheDir() },
    })

/**
 * Sends a signal to a child's whole process group (the child and everything it started).
 * On Windows, which has no groups of signals, `taskkill /T` ends the tree.
 *
 * @param pid - the child's pid, which is also its group's id (it leads the group).
 */
function signalGroup(pid: number, signal: NodeJS.Signals): void {
    if (process.platform === "win32") {
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
    if (process.platform === "win32") return false
    try {
        process.kill(-pid, 0)
        return true
    } catch (error) {
        return (error as NodeJS.ErrnoException).code === "EPERM"
    }
}

/**
 * Appends text to the run's `run.LOG` (made if Julia never got to), under the rule
 * that the file has one writer: this is only called once Julia is gone.
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
 * The first error of the ERRORS section of a run's `run.LOG` in a few words, for the note
 * row of a failed run (`not converged`; this program's own `tui: ...` lines are short
 * and stay as they are). The whole text stays in `run.LOG`.
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
     * Starts a run: claims the run folder (a live run refuses it), copies the inputs into
     * it and starts the child. The claim and the copies are made before any process
     * exists; if one fails the folder is marked `failed` and the error is thrown.
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
            child = launcher({ projectDir, runDir: claimed.dir, temperature })
        } catch (error) {
            try {
                appendToLog(
                    claimed.dir,
                    `tui: could not start: ${(error as Error).message}`,
                )
            } finally {
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

    /**
     * Ends the run once the child has ended: gives the run its final status when Julia
     * could not, records what happened and settles [[done]].
     */
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
            // a failed run tells why: the first line of its ERRORS section (the full text
            // stays in run.LOG)
            if (phase === "failed" && note === undefined)
                note = failureNote(this.runDir)
            // the packing phase is shown; a pack that fails leaves the folder as it was and
            // the note says why (the run's own outcome is unchanged)
            this.update({ phase: "packing", note })
            try {
                await this.pack(this.runDir)
            } catch (error) {
                const why = error instanceof Error ? error.message : "unknown error"
                note = `not packed: ${why}`
            }
            this.update({ phase, note })
        } catch (error) {
            this.update({ phase: "failed", note: (error as Error).message })
        } finally {
            active.delete(this)
            this.resolveDone(this.current.phase)
        }
    }

    /**
     * Stops the run: SIGTERM to the child's whole process group, then a few seconds for
     * Julia to finish its log, then SIGKILL to the group; the end (status, the note in the
     * run's errors) follows as for any end. Calling it again returns the same
     * promise.
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
 * Stops every run that is going and waits until each is over, its status written: what
 * Ctrl-C, Ctrl-D, SIGHUP and SIGTERM do before the program leaves.
 */
export async function quitAll(reason: string): Promise<void> {
    await Promise.all([...active].map((session) => session.abort(reason)))
}

/**
 * Kills the process group of every run that is going, now and synchronously. Only for
 * the `exit` event of the process, when nothing can be awaited any more (a crash): no run
 * is left behind, and Julia's own end-of-input watch is the backstop.
 */
export function killAllNow(): void {
    for (const session of active) session.killNow()
}
