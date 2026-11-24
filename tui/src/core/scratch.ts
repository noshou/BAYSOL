// SPDX-License-Identifier: LGPL-3.0-or-later

// Scratch space: every temporary folder this program makes (the `.xlsx` copies the viewers
// open, the models of a running fit, the staging folders of an archive rewrite, ...) lives
// in ONE folder per process, `<tmp>/baysol/<pid>/<purpose>/`, where `<tmp>` is the system's
// temporary folder ([[tmpFolder]] in `environment.ts`, `Platform.tmp_dir` in Julia). This
// is the only module that asks for it: nothing else in `src` calls `tmpdir()` (a test
// checks), so nothing is scattered. The persistent cache holds no temporary file.
// [[startScratch]] runs at program start: it sweeps the folders of processes that are dead
// (a crash, a killed terminal, a power loss) and registers, once, the exit hook that
// removes this process's folder on every way out that runs JavaScript (^c and `q` end the
// program normally; SIGHUP and SIGTERM call `process.exit`; an uncaught exception still
// emits `exit`). The system also wipes its temporary folder now and then.
//
// Contents:
//   1. Where the scratch space is
//   2. Dead processes' folders
//   3. Leftovers of older versions
//   4. Maintenance while the program runs
//   5. Start and exit

import {
    existsSync,
    mkdirSync,
    mkdtempSync,
    readdirSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { dirname, join } from "node:path"
import { tmpFolder, tmpProcessFolder } from "./environment.js"

// ========================================================================================
// 1. Where the scratch space is
// ========================================================================================

/** The name of a process's folder: a pid, nothing else matches. */
const PROCESS_FOLDER = /^[1-9][0-9]*$/

/** The scratch root of this program: `<tmp>/baysol`. */
const scratchRoot = (): string => tmpFolder()

/** @returns `<root>/<pid>`: the one folder a process keeps its scratch files in. */
export const processFolder = (root: string, pid: number): string => join(root, String(pid))

/**
 * A folder for one purpose in this process's scratch folder, made if missing.
 *
 * @param purpose - one folder name (`view`, `run-models`, ...).
 */
export function scratchFolder(purpose: string): string {
    const folder = join(tmpProcessFolder(process.pid), purpose)
    mkdirSync(folder, { recursive: true })
    return folder
}

/**
 * Makes a new, empty, uniquely named folder in this process's scratch folder. The caller
 * removes it when done; the exit hook and the next start's sweep are the safety net.
 *
 * @param purpose - the folder it goes in (`pack`, `book`, ...), also the start of its name.
 */
export function scratchTemp(purpose: string): string {
    return mkdtempSync(join(scratchFolder(purpose), "x-"))
}

/**
 * Runs `fn` with a new empty scratch folder and removes the folder afterwards, whatever
 * `fn` does.
 *
 * @param purpose - see [[scratchTemp]].
 */
export async function withScratch<T>(
    purpose: string,
    fn: (folder: string) => Promise<T>,
): Promise<T> {
    const folder = scratchTemp(purpose)
    try {
        return await fn(folder)
    } finally {
        rmSync(folder, { recursive: true, force: true })
    }
}

// ========================================================================================
// 2. Dead processes' folders
// ========================================================================================

/**
 * Whether a process exists (signal 0 only checks; it kills nothing and works the same on
 * every system): `ESRCH` is dead, anything else (`EPERM`, a process of another user) is
 * alive, so its folder is never touched. A pid that was reused by another program counts
 * as alive until that program ends: its stale folder then waits for a later start.
 *
 * @param pid - the process id.
 */
export function pidAlive(pid: number): boolean {
    try {
        process.kill(pid, 0)
        return true
    } catch (error) {
        return (error as NodeJS.ErrnoException).code !== "ESRCH"
    }
}

/** Removes one folder, retrying a little (Windows keeps a file busy for a moment). */
function removeFolder(path: string): void {
    rmSync(path, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 })
}

/**
 * Removes a process's whole folder, the exit hook's job. Never throws.
 *
 * @param root - the scratch root.
 * @param pid - the process.
 */
export function removeProcessFolder(root: string, pid: number): void {
    try {
        removeFolder(processFolder(root, pid))
    } catch {
        // busy or gone: the next start's sweep finds it
    }
}

/**
 * Removes the folders `<pid>` that dead processes left in the scratch root: only
 * entries whose name is exactly that, only directories, only when the pid is not alive and
 * is not this process. Nothing else in `root` is touched, and an error on one folder is
 * passed over.
 *
 * @param root - the scratch root.
 * @param self - this process's pid (never swept).
 * @param alive - whether a pid exists (replaceable for tests).
 * @returns the names of the folders removed.
 */
export function sweepDeadFolders(
    root: string,
    self: number,
    alive: (pid: number) => boolean = pidAlive,
): string[] {
    let names: string[]
    try {
        names = readdirSync(root)
    } catch {
        return []
    }
    const removed: string[] = []
    for (const name of names) {
        if (!PROCESS_FOLDER.test(name)) continue
        const pid = Number(name)
        if (pid === self || alive(pid)) continue
        try {
            const path = join(root, name)
            if (!statSync(path).isDirectory()) continue
            removeFolder(path)
            removed.push(name)
        } catch {
            // in use or not ours: left
        }
    }
    return removed
}

// ========================================================================================
// 3. Leftovers of older versions
// ========================================================================================

/**
 * What older versions left in the system's temporary folder: the process folders
 * `baysol-<pid>` and the per-operation folders (`baysol-book-`, `-pack-`, `-run-`, `-add-`,
 * `-sixel-`, `-extract-`, `-move-`, `-compile-` and six random characters).
 */
/** The old process folder, `baysol-<pid>`. */
const LEGACY_PROCESS = /^baysol-([1-9][0-9]*)$/

const LEGACY_OPERATION =
    /^baysol-(book|pack|run|add|sixel|extract|move|compile)-[A-Za-z0-9]{6}$/

/** An operation folder this much older than now is a leftover (nothing runs that long). */
const LEGACY_AGE_MS = 24 * 60 * 60 * 1000

/**
 * One-time cleanup of the leftovers older versions made in the system's temporary folder:
 * a `baysol-<pid>` of a dead pid, and an operation folder (names above) not changed for a
 * day. Nothing else is touched, and no folder of a live process.
 *
 * @param base - the system's temporary folder.
 * @param alive - whether a pid exists (replaceable for tests).
 * @param now - the time, in milliseconds.
 * @returns the names removed.
 */
export function sweepLegacy(
    base: string,
    alive: (pid: number) => boolean = pidAlive,
    now: number = Date.now(),
): string[] {
    let names: string[]
    try {
        names = readdirSync(base)
    } catch {
        return []
    }
    const removed: string[] = []
    for (const name of names) {
        const old = LEGACY_PROCESS.exec(name)
        const operation = LEGACY_OPERATION.test(name)
        if (old === null && !operation) continue
        try {
            const path = join(base, name)
            const st = statSync(path)
            if (!st.isDirectory()) continue
            if (old !== null ? alive(Number(old[1])) : now - st.mtimeMs < LEGACY_AGE_MS)
                continue
            removeFolder(path)
            removed.push(name)
        } catch {
            // in use or not ours: left
        }
    }
    return removed
}

// ========================================================================================
// 4. Maintenance while the program runs
// ========================================================================================

/**
 * How the program keeps its own scratch folder from growing: every `maintainEveryMs` it
 * removes what nobody touched for `idleMs`, then evicts the least recently used entries
 * while the folder is over `capBytes`. The purposes in `protectedPurposes` hold what a
 * running fit or program needs (its models, its generated cache, the natives it loaded):
 * they count towards the size but are never removed here (their owner removes them when the
 * run ends).
 */
export const SCRATCH_POLICY = {
    maintainEveryMs: 30 * 60 * 1000,
    idleMs: 60 * 60 * 1000,
    capBytes: 2 * 1024 * 1024 * 1024,
    protectedPurposes: ["run-models", "run-cache", "native"] as readonly string[],
}

/** The bytes of a file or folder, and the latest modification time inside. */
export function measure(path: string): { bytes: number; time: number } {
    const st = statSync(path)
    if (!st.isDirectory()) return { bytes: st.size, time: st.mtimeMs }
    let bytes = 0
    let time = st.mtimeMs
    for (const name of readdirSync(path)) {
        try {
            const inner = measure(join(path, name))
            bytes += inner.bytes
            time = Math.max(time, inner.time)
        } catch {
            // gone since the listing
        }
    }
    return { bytes, time }
}

/**
 * One round of maintenance on a process's scratch folder: the entries (one level below a
 * purpose folder) idle for `idleMs` go, then the oldest go while the whole folder is over
 * `capBytes`. Protected purposes are measured, never removed. An entry that cannot be
 * removed (in use, on Windows) is left. Never throws.
 *
 * @param folder - the process's scratch folder (`<tmp>/baysol/<pid>`).
 * @param policy - the limits ([[SCRATCH_POLICY]]).
 * @param now - the time, in milliseconds (replaceable for tests).
 * @returns the entries removed, as `<purpose>/<name>`.
 */
export function maintainScratch(
    folder: string,
    policy: typeof SCRATCH_POLICY = SCRATCH_POLICY,
    now: number = Date.now(),
): string[] {
    const removed: string[] = []
    const entries: {
        id: string
        path: string
        bytes: number
        time: number
        keep: boolean
    }[] = []
    try {
        for (const purpose of readdirSync(folder)) {
            const keep = policy.protectedPurposes.includes(purpose)
            let names: string[]
            try {
                names = readdirSync(join(folder, purpose))
            } catch {
                continue
            }
            for (const name of names) {
                const path = join(folder, purpose, name)
                try {
                    entries.push({ id: `${purpose}/${name}`, path, ...measure(path), keep })
                } catch {
                    // gone since the listing
                }
            }
        }
    } catch {
        return removed
    }
    const drop = (entry: (typeof entries)[number]): boolean => {
        try {
            removeFolder(entry.path)
            removed.push(entry.id)
            return true
        } catch {
            return false
        }
    }
    let total = entries.reduce((sum, e) => sum + e.bytes, 0)
    const left: typeof entries = []
    for (const entry of entries) {
        if (!entry.keep && now - entry.time > policy.idleMs && drop(entry)) {
            total -= entry.bytes
        } else left.push(entry)
    }
    left.sort((a, b) => a.time - b.time)
    for (const entry of left) {
        if (total <= policy.capBytes) break
        if (!entry.keep && drop(entry)) total -= entry.bytes
    }
    return removed
}

/**
 * Runs [[maintainScratch]] now and then every `maintainEveryMs`. The timer never keeps the
 * program alive (`unref`).
 *
 * @returns the timer (a test stops it).
 */
export function startMaintenance(
    folder: string,
    policy: typeof SCRATCH_POLICY = SCRATCH_POLICY,
): NodeJS.Timeout {
    maintainScratch(folder, policy)
    const timer = setInterval(() => maintainScratch(folder, policy), policy.maintainEveryMs)
    timer.unref()
    return timer
}

// ========================================================================================
// 5. Start and exit
// ========================================================================================

/** Whether the exit hook is registered (once per program). */
let hooked = false

/**
 * The first thing the program does: sweeps the folders dead processes left in the scratch
 * root, once ever cleans the old leftovers in the system's temporary folder (a marker file
 * in the root says it was done), and registers, once, the exit hook that removes this
 * process's folder and starts the periodic maintenance ([[SCRATCH_POLICY]]). It never
 * throws: starting the program does not depend on it.
 *
 * @param root - the scratch root (a test names another).
 * @param legacyBase - the system's temporary folder (a test names another).
 * @param alive - whether a pid exists (replaceable for tests).
 * @returns the scratch root.
 */
export function startScratch(
    root: string = scratchRoot(),
    legacyBase: string = dirname(tmpFolder()),
    alive: (pid: number) => boolean = pidAlive,
): string {
    try {
        sweepDeadFolders(root, process.pid, alive)
        const marker = join(root, ".legacy-swept")
        if (!existsSync(marker)) {
            sweepLegacy(legacyBase, alive)
            mkdirSync(root, { recursive: true })
            writeFileSync(marker, "")
        }
    } catch {
        // housekeeping only
    }
    if (!hooked) {
        hooked = true
        const pid = process.pid
        process.once("exit", () => removeProcessFolder(root, pid))
        startMaintenance(processFolder(root, pid))
    }
    return root
}
