// SPDX-License-Identifier: LGPL-3.0-or-later

import { createHash, randomBytes } from "node:crypto"
import {
    accessSync,
    constants,
    copyFileSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    renameSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { basename, dirname, join, resolve } from "node:path"
import { lockSync } from "proper-lockfile"
import { compareNoCase } from "./text.js"

/**
 * The file handling the files of the user share: reading one with a fallback or with
 * the "unusable" rule (a file that is not what it should be is told, never written
 * over), and writing one through a temporary file that replaces it in one step.
 */

/**
 * The error of a file that exists but cannot be used (it is not JSON, or not the kind
 * of map expected). It is told to the user and the file is never written over.
 *
 * @param message - what is wrong, e.g. `settings.json is not JSON`.
 * @param kind - which kind of file it is, so a screen can tell them apart.
 */
export class UnusableFileError extends Error {
    constructor(
        message: string,
        readonly kind: string,
    ) {
        super(message)
        this.name = "UnusableFileError"
    }
}

/**
 * Whether a value is a map, what `{...}` reads as in JSON: an object that is not an
 * array and not `null`.
 *
 * @param x - any value.
 * @returns true for a plain object.
 */
export function isDict(x: unknown): x is Record<string, unknown> {
    return typeof x === "object" && x !== null && !Array.isArray(x)
}

/**
 * Reads JSON text strictly (no comments, no trailing commas).
 *
 * @param text - the JSON text; an empty (or blank) text is `null`, a file with nothing
 *     in it.
 * @returns the value.
 * @throws SyntaxError if the text is not JSON.
 */
export function parseJson(text: string): unknown {
    return text.trim() === "" ? null : JSON.parse(text)
}

/**
 * Reads the JSON value in a file.
 *
 * @param file - the file; it must exist.
 * @param fallback - what to give back if the text cannot be read or is not JSON.
 * @returns the value read (`null` for an empty file), or `fallback`.
 */
export function readJson<T>(file: string, fallback: T): unknown | T {
    try {
        return parseJson(readFileSync(file, "utf-8"))
    } catch {
        return fallback
    }
}

/**
 * The JSON text of a value as the files of the user hold it: two-space indent and a
 * final newline, so a person can read and edit it.
 *
 * @param value - the value.
 * @returns the text.
 * @throws TypeError for a value JSON cannot hold (a cycle, a bigint).
 */
export function writeJson(value: unknown): string {
    return `${JSON.stringify(value, null, 2)}\n`
}

/**
 * Whether a path is a folder (a link to one counts).
 *
 * @param path - the path.
 * @returns the answer; `false` for a path that is not there.
 */
export function isFolder(path: string): boolean {
    try {
        return statSync(path).isDirectory()
    } catch {
        return false
    }
}

/**
 * Whether a path is a file (a link to one counts).
 *
 * @param path - the path.
 * @returns the answer; `false` for a path that is not there.
 */
export function isFile(path: string): boolean {
    try {
        return statSync(path).isFile()
    } catch {
        return false
    }
}

/**
 * Whether the user can read a file or folder.
 *
 * @param path - the path.
 * @returns the answer; `false` for a path that is not there.
 */
export function isReadable(path: string): boolean {
    try {
        accessSync(path, constants.R_OK)
        return true
    } catch {
        return false
    }
}

/**
 * The names of everything in a folder.
 *
 * @param dir - the folder.
 * @returns the names; empty if there is no such folder.
 */
export function entryNames(dir: string): string[] {
    try {
        return readdirSync(dir)
    } catch {
        return []
    }
}

/**
 * Sorts names without regard to case, by code unit (the order the screens list in).
 *
 * @param names - the names.
 * @returns a new array.
 */
export function sortNoCase(names: readonly string[]): string[] {
    return [...names].sort(compareNoCase)
}

/**
 * What [[readMap]] needs to know about a file.
 *
 * @property kind - the kind of file, carried by the error.
 * @property name - the name used in the messages.
 * @property expected - a phrase for the map expected, e.g. `a map of the screens`.
 * @property valid - says whether a map is the kind of map expected.
 */
export type MapSpec = {
    kind:     string
    name:     string
    expected: string
    valid:    (map: Record<string, unknown>) => boolean
}

/**
 * Reads the map in a file. It does not note the version ([[noteRead]]): the store
 * decides whether the read starts an editing session.
 *
 * @param file - the file; none (or no content) is `{}`.
 * @param spec - what the map must be.
 * @returns the map.
 * @throws [[UnusableFileError]] for a file that is not JSON or not such a map.
 */
export function readMap(file: string, spec: MapSpec): Record<string, unknown> {
    if (!isFile(file)) return {}
    const bad = Symbol("bad")
    const value = readJson<symbol>(file, bad)
    if (value === bad) throw new UnusableFileError(`${spec.name} is not JSON`, spec.kind)
    if (value === null || value === undefined) return {}
    if (isDict(value) && spec.valid(value)) return value
    throw new UnusableFileError(`${spec.name} is not ${spec.expected}`, spec.kind)
}

/**
 * Writes text to a file through a temporary file next to it that replaces it in one
 * step, so a reader (this program, Julia) never sees half a file; the folders are made
 * if there are none. The temporary file has a name of its own
 * (`<name>.<pid>.<random>.tmp`),
 * so two copies of the program saving at once never write into the same one: each rename
 * puts a whole file in place and the last one wins. A temporary file is never left
 * behind, even when the write fails.
 *
 * @param file - the file.
 * @param text - the text, UTF-8.
 * @param options - `createParents: false` makes no folder: the file's folder must
 *     exist (a project's files, which must not bring back a deleted project).
 * @returns `file`.
 * @throws [[ParentMissingError]] with `createParents: false` and no folder; otherwise
 *     if it cannot be written.
 */
export function writeAtomic(
    file: string,
    text: string,
    options: FolderOptions = {},
): string {
    const unique = `${process.pid}.${randomBytes(4).toString("hex")}`
    const tmp = join(dirname(file), `${basename(file)}.${unique}.tmp`)
    prepareFolder(file, options)
    try {
        writeFileSync(tmp, text, "utf-8")
        renameSync(tmp, file)
    } catch (error) {
        rmSync(tmp, { force: true })
        throw error
    }
    return file
}

/**
 * Whether the folders of a file are made when they are missing.
 *
 * @property createParents - `true` (the default) makes them; `false` requires the
 *     folder to exist already.
 */
export type FolderOptions = { createParents?: boolean }

/**
 * The error of a write into a folder that is not there although it must be (a project
 * folder another copy of the program has deleted).
 *
 * @param dir - the folder.
 */
export class ParentMissingError extends Error {
    constructor(readonly dir: string) {
        super(`${basename(dir)} no longer exists`)
        this.name = "ParentMissingError"
    }
}

/**
 * Makes the folder of a file, or checks that it is there.
 *
 * @param file - the file about to be written or locked.
 * @param options - see [[FolderOptions]].
 * @throws [[ParentMissingError]] with `createParents: false` and no folder.
 */
function prepareFolder(file: string, options: FolderOptions): void {
    const dir = dirname(file)
    if (options.createParents ?? true) mkdirSync(dir, { recursive: true })
    else if (!isFolder(dir)) throw new ParentMissingError(dir)
}

/**
 * Copies a file over another one that may be there. The copy is made next to `to` under
 * a unique name and renamed into place, so a reader (the other copy of the program, or
 * Julia) never sees half a file.
 *
 * @param from - the file to copy.
 * @param to - where the copy goes.
 * @returns `to`.
 * @throws if it cannot be copied.
 */
export function copyOver(from: string, to: string): string {
    const unique = `${process.pid}.${randomBytes(4).toString("hex")}`
    const tmp = join(dirname(to), `${basename(to)}.${unique}.tmp`)
    try {
        copyFileSync(from, tmp)
        renameSync(tmp, to)
    } catch (error) {
        rmSync(tmp, { force: true })
        throw error
    }
    return to
}

// --- two copies of the program at once

/** How long a lock waits for another copy before it gives up (ms). */
const LOCK_WAIT_MS = 3000

/** How long [[withFileLock]] sleeps between two tries (ms). */
const LOCK_RETRY_MS = 25

/** A lock nobody has refreshed for this long belongs to a dead process (ms). */
const LOCK_STALE_MS = 10000

/** What [[withFileLock]] sleeps on: a cell nobody ever changes. */
const sleepCell = new Int32Array(new SharedArrayBuffer(4))

/**
 * Sleeps without spinning, in synchronous code.
 *
 * @param ms - how long.
 */
export function sleepSync(ms: number): void {
    Atomics.wait(sleepCell, 0, 0, ms)
}

/**
 * The error of a file that another copy of the program holds locked for too long.
 *
 * @param file - the file.
 */
export class FileInUseError extends Error {
    constructor(readonly file: string) {
        super(`${basename(file)} is in use by another copy`)
        this.name = "FileInUseError"
    }
}

/**
 * Runs `fn` while this process alone may change `file`: the read-modify-write of one
 * file, which two copies of the program must not interleave. The lock is a folder
 * `<file>.lock` next to the file (the file need not exist), refreshed by the library
 * and taken over when its owner died (no refresh for 10 s). It is not re-entrant: `fn`
 * must not lock the same file again. Waiting is by polling every 25 ms, for 3 s.
 *
 * @param file - the file to protect.
 * @param fn - the work; keep it short.
 * @param options - as for [[writeAtomic]]: `createParents: false` for a project's files.
 * @returns what `fn` returns.
 * @throws [[ParentMissingError]] as for [[writeAtomic]]; [[FileInUseError]] if the lock
 *     stays taken for 3 s; whatever `fn` throws (the
 *     lock is always released).
 */
export function withFileLock<T>(
    file: string,
    fn: () => T,
    options: FolderOptions = {},
): T {
    prepareFolder(file, options)
    const deadline = Date.now() + LOCK_WAIT_MS
    let release: () => void
    for (;;) {
        try {
            release = lockSync(file, { realpath: false, stale: LOCK_STALE_MS })
            break
        } catch (error) {
            if ((error as { code?: string }).code !== "ELOCKED") throw error
            if (Date.now() >= deadline) throw new FileInUseError(file)
            sleepSync(LOCK_RETRY_MS)
        }
    }
    try {
        return fn()
    } finally {
        try {
            release()
        } catch {
            // the lock was taken over as stale; nothing is left to release
        }
    }
}

/**
 * What a file looked like when this process last read or wrote it; `null` is "there
 * was no file".
 */
type Version = { mtimeMs: number; size: number; hash: string } | null

/** The version of each file this process has read or written, by absolute path. */
const seen = new Map<string, Version>()

/**
 * The version of a file now.
 *
 * @param file - the file.
 * @returns its version, or `null` if it is not there.
 */
function versionOf(file: string): Version {
    try {
        const st = statSync(file)
        const hash = createHash("sha1").update(readFileSync(file)).digest("hex")
        return { mtimeMs: st.mtimeMs, size: st.size, hash }
    } catch {
        return null
    }
}

/**
 * What the read function of a list file takes besides what to read.
 *
 * @property track - `true` when the read opens an editing session on the file (a table
 *     loads its rows to change them): the version read becomes the base that the next
 *     write checks ([[assertUnchanged]]). Left out, the read is plain and the base
 *     stays as it was.
 */
export type ReadOptions = { track?: boolean }

/**
 * The error of a list file that another copy of the program saved after this one read
 * it: saving now would lose that copy's changes.
 *
 * @param file - the file.
 */
export class ChangedOnDiskError extends Error {
    constructor(readonly file: string) {
        super(
            `${basename(file)} changed on disk: ` +
                "another copy of BAYSOL saved it; reopen it",
        )
        this.name = "ChangedOnDiskError"
    }
}

/**
 * Records the version of a file as this process now takes it to be (it read it, or
 * found none): the base for [[assertUnchanged]]. Only a read that opens an editing
 * session on the file calls this, and it calls it BEFORE reading, so a save by another
 * copy between the two can only make a later save refuse, never lose an update. A
 * plain read (a count, a list for display) must not call it, or it would accept another
 * copy's save as "current".
 *
 * @param file - the file.
 */
export function noteRead(file: string): void {
    seen.set(resolve(file), versionOf(file))
}

/**
 * Records that this process has just written a file.
 *
 * @param file - the file.
 */
export function noteWritten(file: string): void {
    noteRead(file)
}

/**
 * Checks that nobody changed a file since this process read or wrote it. Call it under
 * [[withFileLock]], before writing. A file this process never read passes.
 *
 * @param file - the file.
 * @throws [[ChangedOnDiskError]] if the file now differs (same content, saved again, is
 *     no difference).
 */
export function assertUnchanged(file: string): void {
    const key = resolve(file)
    if (!seen.has(key)) return
    const before = seen.get(key) ?? null
    const now = versionOf(file)
    if (before === null || now === null) {
        if (before === now) return
    } else if (before.hash === now.hash) return
    throw new ChangedOnDiskError(file)
}

/**
 * Renames a file to `<name>.corrupt` in its folder (replacing an older one), so a file
 * that cannot be used is kept and a new one can take its place.
 *
 * @param file - the file; none does nothing.
 * @returns the path of the kept file, or `undefined` if there was no file.
 * @throws if it cannot be renamed.
 */
export function quarantine(file: string): string | undefined {
    if (!isFile(file)) return undefined
    const kept = join(dirname(file), `${basename(file)}.corrupt`)
    renameSync(file, kept)
    return kept
}

/**
 * The words for a failed save, for a screen's note: what another copy of the program
 * did (`ChangedOnDiskError`, `FileInUseError`, `ParentMissingError` and its
 * `ProjectGoneError` say it themselves), else `could not save!`.
 *
 * @param error - what the save threw.
 * @returns the note to show.
 */
export function saveErrorNote(error: unknown): string {
    if (
        error instanceof ChangedOnDiskError ||
        error instanceof FileInUseError ||
        error instanceof ParentMissingError
    )
        return error.message
    return "could not save!"
}
