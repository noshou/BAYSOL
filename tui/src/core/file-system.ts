// SPDX-License-Identifier: LGPL-3.0-or-later

// File system: everything the program does with files and folders, and with the desktop
// around them.
//
// Contents:
//   1. Files: JSON files, atomic writes, locks, versions and folder helpers
//   2. File picker: the desktop's own dialog to choose structure files
//   3. Open folder: the file manager and a shell on a folder (BAYSOL root, project folder)

import { spawn, spawnSync } from "node:child_process"
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
import { findExecutable, isLinux, isMac, isWindows, type System } from "./environment.js"
import { compareNoCase } from "./terminal.js"

// ========================================================================================
// 1. Files
// ========================================================================================

/**
 * The file handling the files of the user share: reading one with a fallback or with
 * the "unusable" rule (a file that is not what it should be is told, never written
 * over), and writing one through a temporary file that replaces it in one step.
 */

/**
 * The error of a file that exists but cannot be used (it is not JSON, or not the kind
 * of map expected). It is told to the user and the file is never written over.
 *
 * @param kind - which kind of file it is, so a screen can tell them apart.
 */
export class UnusableFileError extends Error {
    constructor(
        message: string,
        readonly kind: string,
    ) {
        super(message)
    }
}

/**
 * Whether a value is a map, what `{...}` reads as in JSON: an object that is not an
 * array and not `null`.
 */
export function isDict(x: unknown): x is Record<string, unknown> {
    return typeof x === "object" && x !== null && !Array.isArray(x)
}

/**
 * Reads JSON text strictly (no comments, no trailing commas).
 *
 * @param text - the JSON text; an empty (or blank) text is `null`, a file with nothing
 *     in it.
 * @throws SyntaxError if the text is not JSON.
 */
export function parseJson(text: string): unknown {
    return text.trim() === "" ? null : JSON.parse(text)
}

/**
 * Reads the JSON value in a file.
 *
 * @param fallback - what to give back if the text cannot be read or is not JSON.
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
 * @throws TypeError for a value JSON cannot hold (a cycle, a bigint).
 */
export function writeJson(value: unknown): string {
    return `${JSON.stringify(value, null, 2)}\n`
}

/** Whether a path is a folder (a link to one counts). */
export function isFolder(path: string): boolean {
    try {
        return statSync(path).isDirectory()
    } catch {
        return false
    }
}

/** Whether a path is a file (a link to one counts). */
export function isFile(path: string): boolean {
    try {
        return statSync(path).isFile()
    } catch {
        return false
    }
}

/** Whether the user can read a file or folder. */
export function isReadable(path: string): boolean {
    try {
        accessSync(path, constants.R_OK)
        return true
    } catch {
        return false
    }
}

/** The names of everything in a folder. */
export function entryNames(dir: string): string[] {
    try {
        return readdirSync(dir)
    } catch {
        return []
    }
}

/** Sorts names without regard to case, by code unit (the order the screens list in). */
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
 * @param options - `createParents: false` makes no folder: the file's folder must
 *     exist (a project's files, which must not bring back a deleted project).
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
 */
export class ParentMissingError extends Error {
    constructor(readonly dir: string) {
        super(`${basename(dir)} no longer exists`)
    }
}

/**
 * Makes the folder of a file, or checks that it is there.
 *
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

/** Sleeps without spinning, in synchronous code. */
export function sleepSync(ms: number): void {
    Atomics.wait(sleepCell, 0, 0, ms)
}

/** The error of a file that another copy of the program holds locked for too long. */
export class FileInUseError extends Error {
    constructor(readonly file: string) {
        super(`${basename(file)} is in use by another copy`)
    }
}

/**
 * Runs `fn` while this process alone may change `file`: the read-modify-write of one
 * file, which two copies of the program must not interleave. The lock is a folder
 * `<file>.lock` next to the file (the file need not exist), refreshed by the library
 * and taken over when its owner died (no refresh for 10 s). It is not re-entrant: `fn`
 * must not lock the same file again. Waiting is by polling every 25 ms, for 3 s.
 *
 * @param options - as for [[writeAtomic]]: `createParents: false` for a project's files.
 * @throws [[ParentMissingError]] as for [[writeAtomic]]; [[FileInUseError]] if the lock
 *     stays taken for 3 s; whatever `fn` throws (the
 *     lock is always released).
 */
export function withFileLock<T>(
    file: string,
    fn: () => T,
    options: FolderOptions = {},
): T {
    const release = acquireLock(file, options)
    try {
        return fn()
    } finally {
        releaseLock(release)
    }
}

/**
 * Takes the lock of [[withFileLock]], waiting up to 3 s for another copy: the one place
 * that polls, shared by the sync and the async helper.
 *
 * @throws [[ParentMissingError]], [[FileInUseError]] as for [[withFileLock]].
 */
function acquireLock(file: string, options: FolderOptions): () => void {
    prepareFolder(file, options)
    const deadline = Date.now() + LOCK_WAIT_MS
    for (;;) {
        try {
            return lockSync(file, { realpath: false, stale: LOCK_STALE_MS })
        } catch (error) {
            if ((error as { code?: string }).code !== "ELOCKED") throw error
            if (Date.now() >= deadline) throw new FileInUseError(file)
            sleepSync(LOCK_RETRY_MS)
        }
    }
}

/**
 * Releases a lock taken by [[acquireLock]]; a lock that was taken over as stale has
 * nothing left to release, which is no error.
 */
function releaseLock(release: () => void): void {
    try {
        release()
    } catch {
        // the lock was taken over as stale; nothing is left to release
    }
}

/**
 * What a file looked like when this process last read or wrote it; `null` is "there
 * was no file".
 */
type Version = { mtimeMs: number; size: number; hash: string } | null

/** The version of each file this process has read or written, by absolute path. */
const seen = new Map<string, Version>()

/** The version of a file now. */
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
 */
export class ChangedOnDiskError extends Error {
    constructor(readonly file: string) {
        super(
            `${basename(file)} changed on disk: ` +
                "another copy of BAYSOL saved it; reopen it",
        )
    }
}

/**
 * Records the version of a file as this process now takes it to be (it read it, or
 * found none): the base for [[assertUnchanged]]. Only a read that opens an editing
 * session on the file calls this, and it calls it BEFORE reading, so a save by another
 * copy between the two can only make a later save refuse, never lose an update. A
 * plain read (a count, a list for display) must not call it, or it would accept another
 * copy's save as "current".
 */
export function noteRead(file: string): void {
    seen.set(resolve(file), versionOf(file))
}

/** Records that this process has just written a file. */
export function noteWritten(file: string): void {
    noteRead(file)
}

/**
 * Checks that nobody changed a file since this process read or wrote it. Call it under
 * [[withFileLock]], before writing. A file this process never read passes.
 *
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

// ========================================================================================
// 2. File picker
// ========================================================================================

/**
 * The desktop's own file picker, to choose structure files (`.cif`, `.pdb`), several at
 * once: `zenity` or `kdialog` on Linux, AppleScript on macOS, PowerShell's open dialog on
 * Windows. The program is asked for the paths and prints them, one to a line. Only the
 * Linux commands have been run; the macOS and Windows ones come from the programs'
 * documentation and are untested.
 *
 * A picker is a window of its own, so it needs a desktop: without one (no `DISPLAY` or
 * `WAYLAND_DISPLAY` on Linux) or without any of the programs there is a short reason to
 * show instead. Programs are started with argument arrays, never through a shell.
 */

/**
 * What a picker asks for.
 *
 * @property title - the title of the window.
 * @property label - the name of the file filter.
 * @property exts - the extensions that are shown (lower case, no dot).
 * @property multiple - `true` if several files may be chosen.
 */
type PickerSpec = {
    title: string
    label: string
    exts: string[]
    multiple: boolean
}

/** The pickers by kind: the models (several `.cif` and `.pdb` files), the buffer's
 * DNA, RNA and protein sequence file (ONE file, FASTA or FASTQ) and the measured curve
 * of a project (ONE delimited text file or `.xlsx` workbook). */
const pickerSpecs = {
    structure: {
        title: "Choose models",
        label: "Structure files",
        exts: ["cif", "pdb"],
        multiple: true,
    },
    sequence: {
        title: "Choose a sequence file",
        label: "Sequence files",
        exts: ["fasta", "fa", "fna", "faa", "fastq", "fq"],
        multiple: false,
    },
    data: {
        title: "Choose a data file",
        label: "Data files",
        exts: ["dat", "txt", "csv", "tsv", "tab", "xlsx"],
        multiple: false,
    },
} satisfies Record<string, PickerSpec>

/** The kinds of picker. */
export type PickerKind = keyof typeof pickerSpecs

/** The result of [[pick]]: the files chosen (none if the window was closed), or why no
 * picker could be shown. */
export type PickResult = { files: string[] } | { problem: string }

/** The patterns of the extensions of a spec, in lower and upper case: `*.cif *.CIF`. */
function globs(spec: PickerSpec, separator: string): string {
    return spec.exts.flatMap((e) => [`*.${e}`, `*.${e.toUpperCase()}`]).join(separator)
}

/** @returns the `zenity` command that picks files, starting in a folder. */
function zenityCommand(startDir: string, spec: PickerSpec): string[] {
    return [
        "zenity",
        "--file-selection",
        ...(spec.multiple ? ["--multiple"] : []),
        `--title=${spec.title}`,
        `--filename=${startDir}/`,
        "--separator=\n",
        `--file-filter=${spec.label} | ${globs(spec, " ")}`,
    ]
}

/** @returns the `kdialog` command that picks files, starting in a folder. */
function kdialogCommand(startDir: string, spec: PickerSpec): string[] {
    return [
        "kdialog",
        ...(spec.multiple ? ["--multiple", "--separate-output"] : []),
        "--title",
        spec.title,
        "--getopenfilename",
        startDir,
        `${globs(spec, " ")}|${spec.label}`,
    ]
}

/** @returns the `osascript` command that picks files (untested). */
function macCommand(spec: PickerSpec): string[] {
    const types = spec.exts.map((e) => `"${e}"`).join(", ")
    const choose =
        `set fs to choose file with prompt "${spec.title}" of type {${types}}` +
        (spec.multiple ? " with multiple selections allowed" : "\nset fs to {fs}")
    return [
        "osascript",
        "-e",
        choose,
        "-e",
        'set out to ""',
        "-e",
        "repeat with f in fs",
        "-e",
        "set out to out & POSIX path of f & linefeed",
        "-e",
        "end repeat",
        "-e",
        "return out",
    ]
}

/** @returns the PowerShell command that picks files, starting in a folder (untested). */
function windowsCommand(startDir: string, spec: PickerSpec): string[] {
    const filter = spec.exts.map((e) => `*.${e}`).join(";")
    return [
        "powershell",
        "-NoProfile",
        "-Command",
        "Add-Type -AssemblyName System.Windows.Forms; " +
            "$d = New-Object System.Windows.Forms.OpenFileDialog; " +
            `$d.Multiselect = ${spec.multiple ? "$true" : "$false"}; ` +
            `$d.Title = '${spec.title}'; ` +
            `$d.Filter = '${spec.label}|${filter}'; ` +
            `$d.InitialDirectory = '${startDir.replaceAll("'", "''")}'; ` +
            "if ($d.ShowDialog() -eq 'OK') { $d.FileNames -join \"`n\" }",
    ]
}

/**
 * The commands to try, in order, to pick files.
 *
 * @param system - the machine; on Linux `kdialog` comes first on a KDE desktop and
 *     `zenity` first anywhere else.
 */
function pickerCommands(
    system: System,
    startDir: string,
    spec: PickerSpec = pickerSpecs.structure,
): string[][] {
    if (isLinux(system)) {
        const kde = (system.env.XDG_CURRENT_DESKTOP ?? "").toLowerCase().includes("kde")
        const both = [zenityCommand(startDir, spec), kdialogCommand(startDir, spec)]
        return kde ? both.reverse() : both
    }
    if (isMac(system)) return [macCommand(spec)]
    if (isWindows(system)) return [windowsCommand(startDir, spec)]
    return []
}

/**
 * The paths in the output of a picker.
 *
 * @returns its non-blank lines, trimmed of the line ends only (a name may have spaces).
 */
export function parsePickerOutput(text: string | undefined): string[] {
    return (text ?? "")
        .split(/\r?\n/)
        .map((line) => line.replace(/[\r\n]+$/, ""))
        .filter((line) => line.trim() !== "")
}

/**
 * @param system - the machine.
 * @returns `true` if its desktop can show a window (on Linux; elsewhere always).
 */
function hasDisplay(system: System): boolean {
    return (
        !isLinux(system) ||
        Boolean(system.env.DISPLAY) ||
        Boolean(system.env.WAYLAND_DISPLAY)
    )
}

/**
 * Runs a command and collects what it prints on standard output. Its input is closed
 * and its errors thrown away, so nothing of it reaches the terminal the TUI draws on.
 *
 * @throws if the program cannot be started.
 */
function runCommand(command: string[]): Promise<string> {
    const [program, ...args] = command as [string, ...string[]]
    return new Promise((resolve, reject) => {
        const child = spawn(program, args, { stdio: ["ignore", "pipe", "ignore"] })
        const chunks: Buffer[] = []
        child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk))
        child.once("error", reject)
        child.once("close", () => resolve(Buffer.concat(chunks).toString("utf8")))
    })
}

/**
 * Opens the desktop's file picker and waits for it.
 *
 * @returns the files picked (empty if the window was closed without a choice), or a
 *     short reason when no picker could be shown.
 */
export async function pick(
    system: System,
    startDir: string,
    kind: PickerKind = "structure",
): Promise<PickResult> {
    const command = pickerCommands(system, startDir, pickerSpecs[kind]).find(
        ([program]) => findExecutable(system, program ?? "") !== undefined,
    )
    if (!hasDisplay(system)) return { problem: "no desktop: cannot show a picker" }
    if (!command) return { problem: "no file picker (zenity or kdialog)" }
    try {
        return { files: parsePickerOutput(await runCommand(command)) }
    } catch (error) {
        return { problem: `picker failed: ${(error as Error).message}` }
    }
}

// ========================================================================================
// 3. Open folder
// ========================================================================================

/**
 * "Open" for a folder (the BAYSOL root or a project folder): the desktop's file manager
 * is tried, and a shell is started in the folder with the terminal of this program. The
 * macOS and Windows commands come from documentation and are untested.
 */

/** How long to wait for the file manager's command to fail before assuming it worked, in
 * milliseconds: a file manager keeps running, so only a quick failure is a failure. */
const fileManagerWaitMs = 2000

/** The commands to try, in order, to open a folder in the desktop's file manager. */
function fileManagerCommands(system: System, dir: string): string[][] {
    if (isLinux(system))
        return [
            ["xdg-open", dir],
            ["gio", "open", dir],
        ]
    if (isMac(system)) return [["open", dir]]
    if (isWindows(system)) return [["explorer", dir]]
    return []
}

/**
 * The command that starts the user's shell: `$SHELL` (else `/bin/sh`) on Linux and
 * macOS, `%COMSPEC%` (else `cmd.exe`) on Windows.
 */
function subshellCommand(system: System): string[] {
    if (isWindows(system)) return [system.env.COMSPEC || "cmd.exe"]
    return [system.env.SHELL || "/bin/sh"]
}

/**
 * Tries to open a folder in the file manager. Its output is discarded and it is never
 * killed; on Windows its exit code is ignored, because `explorer` returns 1 even when it
 * works.
 */
export function openFileManager(system: System, dir: string): Promise<string | undefined> {
    const command = fileManagerCommands(system, dir).find(([program]) =>
        findExecutable(system, program ?? ""),
    )
    if (!command) return Promise.resolve("no file manager command found")
    const [program, ...args] = command as [string, ...string[]]
    return new Promise((resolve) => {
        const child = spawn(program, args, { stdio: "ignore", detached: true })
        const timer = setTimeout(() => {
            child.unref()
            resolve(undefined)
        }, fileManagerWaitMs)
        child.once("error", (error) => {
            clearTimeout(timer)
            resolve(`could not start ${program}: ${error.message}`)
        })
        child.once("exit", (code) => {
            clearTimeout(timer)
            resolve(
                code === 0 || code === null || isWindows(system)
                    ? undefined
                    : `${program} exited with ${code}`,
            )
        })
    })
}

/**
 * Starts the user's shell in a folder, with this program's terminal, and waits for it.
 * The terminal must already be back to normal (the screen closed).
 *
 * @returns a problem text if the shell could not be started, else `undefined`.
 */
function runShellIn(system: System, dir: string): string | undefined {
    const [program, ...args] = subshellCommand(system) as [string, ...string[]]
    console.log(`BAYSOL: shell in ${dir} (type exit to return)`)
    const result = spawnSync(program, args, { cwd: dir, stdio: "inherit" })
    return result.error ? `could not start a shell: ${result.error.message}` : undefined
}

/**
 * The whole of "Open": the file manager is tried (a failure is reported through
 * `warn`), then a shell runs in the folder until the user leaves it.
 *
 * @returns a problem text if the shell could not be started, else `undefined`.
 */
export async function openFolder(
    system: System,
    dir: string,
    warn: (text: string) => void,
): Promise<string | undefined> {
    const reason = await openFileManager(system, dir)
    if (reason !== undefined) warn(`could not open the file manager: ${reason}`)
    return runShellIn(system, dir)
}
