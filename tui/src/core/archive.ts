// SPDX-License-Identifier: LGPL-3.0-or-later

// Archive: the 7z archive of a finished run, packed and read through 7-Zip (the `7zip-bin`
// binary, driven by `node-7z`; a 7-Zip on the PATH when the bundled one cannot run).
//
// Contents:
//   1. The tool and the names: which 7-Zip, what an entry name may be
//   2. Reading: listing and reading one entry, read only, with a size cap
//   3. Writing: packing atomically, extracting into a temporary folder
//   4. Zip files: a workbook opened into its tree and zipped back

import { type ChildProcess, spawn, spawnSync } from "node:child_process"
import {
    accessSync,
    chmodSync,
    constants,
    lstatSync,
    mkdtempSync,
    readdirSync,
    renameSync,
    rmdirSync,
    rmSync,
    statSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { dirname, isAbsolute, join } from "node:path"
import { path7za } from "7zip-bin"
import sevenZip, { type SevenZipOptions, type ZipStream } from "node-7z"
import { lock } from "proper-lockfile"
import { findExecutable, RUN_FLOW, readSystem } from "./environment.js"

// ========================================================================================
// 1. The tool and the names
// ========================================================================================

/**
 * Why an archive could not be made or read: said to the user as it is, in a sentence
 * (`7-Zip failed: ...`, `run.7z holds no run.LOG`).
 */
export class ArchiveError extends Error {}

/** The lock a pack holds on a run folder (`<folder>/.pack`, and `.pack.lock` beside it). */
export const PACK_LOCK = ".pack"

/** The bundled 7-Zip's path once it is known to run (or the one found on the PATH). */
let tool: string | undefined

/**
 * The 7-Zip that runs: the `7zip-bin` binary (made executable when the package left it
 * without the bit, which an npm install may do), else a `7z`, `7zz` or `7za` found on the
 * `PATH`.
 *
 * @throws [[ArchiveError]] if there is none.
 */
export function archiveTool(): string {
    if (tool !== undefined) return tool
    const found = [path7za, ...["7zz", "7z", "7za"].map(onPath)].filter(
        (p): p is string => p !== undefined && runnable(p),
    )
    const first = found[0]
    if (first === undefined) throw new ArchiveError("no 7-Zip found: install 7z")
    tool = first
    return first
}

/** A program on the `PATH`, or `undefined`. */
const onPath = (name: string): string | undefined => findExecutable(readSystem(), name)

/** Whether a file can run, giving a bundled binary that lost its execute bit one. */
function runnable(file: string): boolean {
    try {
        accessSync(file, constants.X_OK)
        return true
    } catch {
        try {
            chmodSync(file, 0o755)
            accessSync(file, constants.X_OK)
            return true
        } catch {
            return false
        }
    }
}

/** Forgets the tool found (the tests point it at another program). */
export function setArchiveTool(program: string | undefined): void {
    tool = program
}

/**
 * Whether a name is safe as an entry of an archive: a relative path of `/`-separated
 * parts, none empty, `.` or `..`, with no backslash, drive letter or control character.
 */
export function isSafeEntryName(name: unknown): name is string {
    if (typeof name !== "string" || name === "" || name.length > 1024) return false
    if (name.startsWith("/") || /^[A-Za-z]:/.test(name) || name.includes("\\")) return false
    // biome-ignore lint/suspicious/noControlCharactersInRegex: the point is to refuse them
    if (/[\x00-\x1f\x7f]/.test(name)) return false
    return name.split("/").every((part) => part !== "" && part !== "." && part !== "..")
}

// ========================================================================================
// 2. Reading
// ========================================================================================

/**
 * What an archive holds, as listed.
 *
 * @property name - the entry's path in the archive (`/`-separated, checked by
 *     [[isSafeEntryName]]).
 * @property size - its bytes, uncompressed.
 */
export type Entry = { name: string; size: number }

/** The listings made, by archive path: valid while the file's time and size stay. */
const listings = new Map<string, { stamp: string; entries: Entry[] }>()

/** The time and size of a file as one text, `undefined` for a file that is not there. */
function stampOf(file: string): string | undefined {
    try {
        const st = statSync(file)
        return `${st.mtimeMs}:${st.size}`
    } catch {
        return undefined
    }
}

/**
 * Runs 7-Zip and waits (the readers of the screens are synchronous, and a listing or one
 * small entry takes a few milliseconds).
 *
 * @returns the standard output.
 * @throws [[ArchiveError]] when 7-Zip cannot run, fails, or prints more than `maxBytes`.
 */
function sevenZipSync(args: string[], maxBytes: number, cwd?: string): Buffer {
    const r = spawnSync(archiveTool(), args, {
        maxBuffer: maxBytes,
        windowsHide: true,
        ...(cwd === undefined ? {} : { cwd }),
    })
    if (r.error !== undefined) {
        const tooBig = (r.error as NodeJS.ErrnoException).code === "ENOBUFS"
        throw new ArchiveError(
            tooBig
                ? "the entry is too large to show"
                : `7-Zip could not run: ${r.error.message}`,
        )
    }
    if (r.status !== 0)
        throw new ArchiveError(
            `7-Zip failed: ${r.stderr.toString("utf-8").trim().split("\n")[0] || r.status}`,
        )
    return r.stdout
}

/**
 * The entries of an archive (files only; an entry whose name is not safe is left out).
 * The result is kept while the archive file does not change.
 *
 * @throws [[ArchiveError]] if the archive is missing or 7-Zip cannot read it.
 */
export function listEntries(archive: string): Entry[] {
    const stamp = stampOf(archive)
    if (stamp === undefined) throw new ArchiveError(`${archive} is not there`)
    const kept = listings.get(archive)
    if (kept?.stamp === stamp) return kept.entries
    const text = sevenZipSync(
        ["l", "-slt", "-ba", "-bd", "-sccUTF-8", "--", archive],
        RUN_FLOW.archive.maxEntryBytes,
    ).toString("utf-8")
    const entries: Entry[] = []
    for (const block of text.split(/\r?\n\r?\n/)) {
        const field = (key: string): string | undefined =>
            new RegExp(`^${key} = (.*)$`, "m").exec(block)?.[1]
        const name = field("Path")?.replace(/\\/g, "/")
        const folder = (field("Attributes") ?? "").startsWith("D")
        const size = Number(field("Size") ?? "0")
        if (isSafeEntryName(name) && !folder && Number.isFinite(size))
            entries.push({ name, size })
    }
    listings.set(archive, { stamp, entries })
    return entries
}

/**
 * The bytes of one entry, read from the archive without writing anything to disk.
 *
 * @param name - the entry's name, as [[listEntries]] gives it.
 * @param maxBytes - the most the entry may hold (`RUN_FLOW.archive.maxEntryBytes`).
 * @throws [[ArchiveError]] for a name that is not safe, an entry the archive does not
 *     hold, one over `maxBytes`, or an archive 7-Zip cannot read.
 */
export function readEntry(
    archive: string,
    name: string,
    maxBytes: number = RUN_FLOW.archive.maxEntryBytes,
): Buffer {
    if (!isSafeEntryName(name)) throw new ArchiveError(`not a safe entry name: ${name}`)
    const entry = listEntries(archive).find((e) => e.name === name)
    if (entry === undefined)
        throw new ArchiveError(`${basenameOf(archive)} holds no ${name}`)
    if (entry.size > maxBytes) throw new ArchiveError(`${name} is too large to show`)
    return sevenZipSync(
        ["x", "-so", "-y", "-spd", "-bd", "--", archive, name],
        maxBytes + 1,
    )
}

/** The last part of a path, for messages. */
const basenameOf = (path: string): string => path.split(/[\\/]/).pop() ?? path

// ========================================================================================
// 3. Writing
// ========================================================================================

/**
 * Waits for a 7-Zip command driven by `node-7z`.
 *
 * @throws [[ArchiveError]] with the first line 7-Zip said when it failed.
 */
function finished(stream: ZipStream): Promise<void> {
    return new Promise((resolve, reject) => {
        stream.on("end", () => resolve())
        stream.on("error", (error: Error) =>
            reject(
                new ArchiveError(
                    `7-Zip failed: ${error.message.trim().split("\n")[0] ?? "no message"}`,
                ),
            ),
        )
    })
}

/**
 * What a stream made with `$defer` holds before its 7-Zip runs. `node-7z` 3.0 takes a
 * `$spawnOptions` option but never passes it on, so a command that must run in a folder
 * (packing relative paths) is deferred, started here with that folder, and handed back.
 */
type Deferred = { _bin: string; _args: string[]; _childProcess?: ChildProcess }

/** Starts a deferred stream's 7-Zip in `cwd` and wires the stream to it. */
function startIn(stream: ZipStream, cwd: string): ZipStream {
    const d = stream as unknown as Deferred
    d._childProcess = spawn(d._bin, d._args, { cwd, windowsHide: true })
    return sevenZip.listen(stream)
}

/**
 * The compression of a run's archive, all from `run_flow.json`: the level (`x`), the
 * word size (`fb`, the most 7-Zip's LZMA2 takes) and solid mode (`s`), so the files of a
 * run are compressed as one block, which is what makes many alike XML files small.
 */
const methodOptions = (): string[] => {
    const { level, wordSize, solid } = RUN_FLOW.archive
    return [`x=${level}`, `fb=${wordSize}`, `s=${solid ? "on" : "off"}`]
}

/** The options every command shares: this 7-Zip, 7z format, no wildcards, no prompts. */
const common = (): SevenZipOptions => ({
    $bin: archiveTool(),
    archiveType: "7z",
    noWildcards: true,
    yes: true,
})

/**
 * Packs files of a folder into a 7z archive, atomically: the archive is made as
 * `<archive>.tmp.<pid>`, tested with `7z t` and compared with the list of what was asked
 * for, and only then renamed to `archive`. A lock on the folder (`.pack`) keeps two
 * packs from running at once. The staged file is removed whatever happens, and nothing
 * else is touched: the files packed stay where they are (the caller removes them once
 * this returns).
 *
 * @param folder - the folder the paths are relative to (and the archive is written in,
 *     unless `archiveName` is a path).
 * @param archiveName - the archive's file name, in `folder`, or an absolute path (a run's
 *     archive is written beside its folder).
 * @param files - the files to pack, `/`-separated paths relative to `folder`, at least
 *     one.
 * @throws [[ArchiveError]] when the archive exists already, there is nothing to pack, a
 *     name is not safe, 7-Zip fails or its test fails, or the archive does not hold what
 *     was asked for. The folder is then as it was.
 */
export async function packFiles(
    folder: string,
    archiveName: string,
    files: readonly string[],
): Promise<void> {
    const archive = isAbsolute(archiveName) ? archiveName : join(folder, archiveName)
    const staging = `${archive}.tmp.${process.pid}`
    if (files.length === 0) throw new ArchiveError("nothing to pack")
    const bad = files.find((f) => !isSafeEntryName(f))
    if (bad !== undefined) throw new ArchiveError(`not a safe name to pack: ${bad}`)
    const release = await lock(join(folder, PACK_LOCK), {
        realpath: false,
        stale: 30000,
    }).catch(() => {
        throw new ArchiveError("the run is being packed by another copy")
    })
    try {
        if (stampOf(archive) !== undefined)
            throw new ArchiveError(`${basenameOf(archive)} exists already`)
        const options: SevenZipOptions = {
            ...common(),
            method: methodOptions(),
            $defer: true,
        }
        await finished(startIn(sevenZip.add(staging, [...files], options), folder))
        await finished(sevenZip.test(staging, common()))
        listings.delete(staging)
        const held = new Set(listEntries(staging).map((e) => e.name))
        const lacking = files.find((f) => !held.has(f))
        if (lacking !== undefined)
            throw new ArchiveError(`the archive lacks ${lacking}: nothing was removed`)
        renameSync(staging, archive)
    } finally {
        listings.delete(staging)
        rmSync(staging, { force: true })
        try {
            await release()
        } catch {
            // the lock went stale and was taken over; nothing is left to release
        }
    }
}

/**
 * Removes packed files and the folders that this empties (a folder with something else in
 * it stays). The caller does this only once [[packFiles]] has returned.
 *
 * @param folder - the folder the paths are relative to.
 * @param files - the `/`-separated paths that were packed.
 */
export function removePacked(folder: string, files: readonly string[]): void {
    const dirs = new Set<string>()
    for (const f of files) {
        const path = join(folder, ...f.split("/"))
        try {
            if (lstatSync(path).isFile()) rmSync(path)
        } catch {
            // gone already
        }
        for (let d = dirname(path); d.length > folder.length; d = dirname(d)) dirs.add(d)
    }
    for (const d of [...dirs].sort((a, b) => b.length - a.length)) {
        try {
            if (readdirSync(d).length === 0) rmdirSync(d)
        } catch {
            // not empty, or gone
        }
    }
}

/**
 * Extracts entries of an archive into a folder (made if missing), nothing else of the
 * archive. The names must be listed in the archive and safe, and together at most
 * `RUN_FLOW.archive.maxExtractBytes`.
 *
 * @param names - the entries (the paths in the archive; they keep their paths in
 *     `into`).
 * @throws [[ArchiveError]] for a name that is not in the archive, a total over the cap,
 *     or a 7-Zip that fails.
 */
export async function extractEntries(
    archive: string,
    names: readonly string[],
    into: string,
): Promise<void> {
    const held = new Map(listEntries(archive).map((e) => [e.name, e.size]))
    let total = 0
    for (const n of names) {
        const size = held.get(n)
        if (size === undefined)
            throw new ArchiveError(`${basenameOf(archive)} holds no ${n}`)
        total += size
    }
    if (total > RUN_FLOW.archive.maxExtractBytes)
        throw new ArchiveError("the plots are too large to extract")
    if (names.length === 0) return
    await finished(
        sevenZip.extractFull(archive, into, {
            ...common(),
            overwrite: "a",
            $cherryPick: [...names],
        }),
    )
}

/**
 * Runs `fn` with a new empty temporary folder and removes the folder afterwards, whatever
 * `fn` does.
 *
 * @param prefix - the start of the folder's name.
 */
export async function withTempFolder<T>(
    prefix: string,
    fn: (folder: string) => Promise<T>,
): Promise<T> {
    const folder = mkdtempSync(join(tmpdir(), `${prefix}-`))
    try {
        return await fn(folder)
    } finally {
        rmSync(folder, { recursive: true, force: true })
    }
}

// ========================================================================================
// 4. Zip files (a `.xlsx` is one)
// ========================================================================================

/**
 * Extracts every entry of an archive of any format into a folder (made if missing), with
 * their paths. Used to open a workbook (`.xlsx`, a zip) into its XML tree.
 *
 * @throws [[ArchiveError]] when 7-Zip cannot run or fails.
 */
export function extractAllSync(archive: string, into: string): void {
    sevenZipSync(
        ["x", "-y", "-bd", "-spd", `-o${into}`, "--", archive],
        RUN_FLOW.archive.maxEntryBytes,
    )
}

/**
 * Extracts the named entries of a 7z archive into a folder (made if missing), with their
 * paths: the synchronous twin of [[extractEntries]] for readers that cannot wait.
 *
 * @throws [[ArchiveError]] when 7-Zip cannot run or fails.
 */
export function extractNamesSync(
    archive: string,
    names: readonly string[],
    into: string,
): void {
    if (names.length === 0) return
    sevenZipSync(
        ["x", "-y", "-bd", "-spd", `-o${into}`, "--", archive, ...names],
        RUN_FLOW.archive.maxEntryBytes,
    )
}

/**
 * Makes a zip of files of a folder, the same bytes for the same files: the entries are in
 * the order given, deflated at the archive level, with the modification time of each
 * file as the only timestamp (the caller gives the files a fixed time first). The zip is
 * written to `out`, which must not exist.
 *
 * @param folder - the folder the names are relative to.
 * @param files - the `/`-separated entry names, in order.
 * @param out - the zip's path.
 * @throws [[ArchiveError]] when 7-Zip cannot run or fails.
 */
export function zipFolderSync(folder: string, files: readonly string[], out: string): void {
    // `-mtc=off`: no creation time (7-Zip would write the time of the packing); the access
    // time is off by default, so the modification time, fixed by the caller, is all
    const method = ["-tzip", `-mx=${RUN_FLOW.archive.level}`, "-mm=Deflate", "-mtc=off"]
    sevenZipSync(
        ["a", ...method, "-bd", "-y", "-spd", "--", out, ...files],
        RUN_FLOW.archive.maxEntryBytes,
        folder,
    )
}
