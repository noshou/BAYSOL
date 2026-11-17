// SPDX-License-Identifier: LGPL-3.0-or-later

// The temporary copies the viewers open (a workbook held as a tree in a run's archive is
// zipped again into a `.xlsx` on disk). All of them live in ONE folder per process,
// `<tmpdir>/baysol-<pid>/view/`, so that the folder can be capped in size, removed when
// the program ends, and swept by a later program when this one died without cleaning up.
// Every function takes the base folder as a parameter (the system's temporary folder in
// production), so tests never touch the real one.
//
// Contents:
//   1. Where the copies live
//   2. Dead processes' folders
//   3. The size cap

import {
    existsSync,
    mkdirSync,
    readdirSync,
    rmSync,
    statSync,
    utimesSync,
} from "node:fs"
import { join } from "node:path"

// ========================================================================================
// 1. Where the copies live
// ========================================================================================

/** The name of a process's folder: exactly `baysol-` and its pid, nothing else matches. */
const PROCESS_FOLDER = /^baysol-([1-9][0-9]*)$/

/**
 * The folder one process keeps its copies in.
 *
 * @param base - the folder the process folders live in (the system's temporary folder).
 * @param pid - the process.
 * @returns `<base>/baysol-<pid>/view`.
 */
export const viewFolder = (base: string, pid: number): string =>
    join(base, `baysol-${pid}`, "view")

/**
 * Makes the folder of a process's copies.
 *
 * @param base - see [[viewFolder]].
 * @param pid - the process.
 * @returns the folder (made, with its parents).
 */
export function makeViewFolder(base: string, pid: number): string {
    const folder = viewFolder(base, pid)
    mkdirSync(folder, { recursive: true })
    return folder
}

/**
 * Removes a process's whole folder (`<base>/baysol-<pid>`), the exit hook's job.
 *
 * @param base - see [[viewFolder]].
 * @param pid - the process.
 */
export function removeProcessFolder(base: string, pid: number): void {
    try {
        rmSync(join(base, `baysol-${pid}`), { recursive: true, force: true })
    } catch {
        // the system's temporary folder is cleaned anyway
    }
}

// ========================================================================================
// 2. Dead processes' folders
// ========================================================================================

/**
 * Whether a process exists (signal 0 only checks). A process of another user counts as
 * alive (`EPERM`), so its folder is never touched.
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

/**
 * Removes the folders `baysol-<pid>` that processes left behind: only entries whose name
 * is exactly that, only directories, only when the pid is not alive and is not this
 * process. Nothing else in `base` is touched, and an error on one folder is passed over.
 *
 * @param base - the folder the process folders live in.
 * @param self - this process's pid (never swept).
 * @param alive - whether a pid exists (replaceable for tests).
 * @returns the names of the folders removed.
 */
export function sweepDeadFolders(
    base: string,
    self: number,
    alive: (pid: number) => boolean = pidAlive,
): string[] {
    let names: string[]
    try {
        names = readdirSync(base)
    } catch {
        return []
    }
    const removed: string[] = []
    for (const name of names) {
        const match = PROCESS_FOLDER.exec(name)
        if (match === null) continue
        const pid = Number(match[1])
        if (pid === self || alive(pid)) continue
        try {
            const path = join(base, name)
            if (!statSync(path).isDirectory()) continue
            rmSync(path, { recursive: true, force: true })
            removed.push(name)
        } catch {
            // in use or not ours: left
        }
    }
    return removed
}

// ========================================================================================
// 3. The size cap
// ========================================================================================

/** The bytes of a file or folder, and the latest modification time inside. */
function measure(path: string): { bytes: number; time: number } {
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
 * Marks a copy as just used, so the cap evicts the least recently used first.
 *
 * @param folder - the copy's folder (one entry of the view folder).
 */
export function touchCopy(folder: string): void {
    try {
        const now = new Date()
        utimesSync(folder, now, now)
    } catch {
        // gone: the next open makes it again
    }
}

/**
 * Keeps the copies under a size cap: while their total is over `capBytes`, the oldest
 * copy (an entry of `folder`, by the latest modification time inside it) is removed,
 * never `keep`. A folder that does not exist has nothing to trim.
 *
 * @param folder - the view folder (each entry is one copy's folder).
 * @param capBytes - the most the copies may hold in all.
 * @param keep - the name of the entry never removed (the one being opened).
 * @returns the names removed, oldest first.
 */
export function trimCopies(folder: string, capBytes: number, keep?: string): string[] {
    if (!existsSync(folder)) return []
    const copies: { name: string; bytes: number; time: number }[] = []
    for (const name of readdirSync(folder)) {
        try {
            copies.push({ name, ...measure(join(folder, name)) })
        } catch {
            // gone since the listing
        }
    }
    copies.sort((a, b) => a.time - b.time)
    let total = copies.reduce((sum, c) => sum + c.bytes, 0)
    const removed: string[] = []
    for (const copy of copies) {
        if (total <= capBytes) break
        if (copy.name === keep) continue
        try {
            rmSync(join(folder, copy.name), { recursive: true, force: true })
            total -= copy.bytes
            removed.push(copy.name)
        } catch {
            // in use: left
        }
    }
    return removed
}
