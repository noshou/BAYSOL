// SPDX-License-Identifier: LGPL-3.0-or-later

// The archive of a run: what is packed, how it is packed, and the readers that take the
// archive or the plain folder alike.
//
// Contents:
//   1. What is packed, and packing a finished run
//   2. Reading a run's files from the archive or from the folder
//   3. Files the viewers open: a copy on disk of a file that is only in the archive

import { createHash } from "node:crypto"
import {
    lstatSync,
    mkdirSync,
    mkdtempSync,
    readdirSync,
    readFileSync,
    rmdirSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { basename, join, relative, sep } from "node:path"
import {
    ArchiveError,
    isSafeEntryName,
    listEntries,
    packFiles,
    readEntry,
    removePacked,
} from "../core/archive.js"
import { RUN_FLOW } from "../core/environment.js"
import { isFile } from "../core/file-system.js"

// ========================================================================================
// 1. What is packed
// ========================================================================================

/**
 * A finished run is ONE archive, `runs/<stamp>.7z`, with EVERYTHING of the run in it: the
 * metadata `run.json`, the workbooks, the logs, the inputs and the plots, as FLAT names
 * (`run.LOG`, `<model>.xlsx`, `<model>.tex`, `<model>-plots.txt`, `compare.tsv`, ...).
 * While the run goes, and for a run whose pack failed, its files are in the plain folder
 * `runs/<stamp>/` instead (the run's name is the same either way).
 *
 * Packing is atomic: the archive is made beside the folder, tested with `7z t`, compared
 * with the list of what was asked for, and only then are the packed files (and the
 * folder, once empty) removed. A failure leaves the run folder as it was.
 *
 * Runs of the older layouts still read: a folder with a `run.7z` inside (`run.json` and
 * the workbooks outside it, the rest under `logs/`, `<model>/output/`, `compare/`), or
 * plain folders. [[legacyNames]] says where an old run keeps a file the new layout names
 * flat.
 */

/** The path of a run's archive, beside its folder (it may not exist). */
export const archivePath = (runDir: string): string =>
    `${runDir}${RUN_FLOW.archive.extension}`

/** The path of the archive of the older layout, inside the run folder. */
const legacyArchivePath = (runDir: string): string =>
    join(runDir, RUN_FLOW.archive.legacyName)

/** The archives a run has, the new one first. */
const archivesOf = (runDir: string): string[] =>
    [archivePath(runDir), legacyArchivePath(runDir)].filter(isFile)

/** Whether a run has been packed. */
export const isPacked = (runDir: string): boolean => archivesOf(runDir).length > 0

/** Whether a run is there: its folder or its archive. */
export const runExists = (runDir: string): boolean => {
    try {
        return statSync(runDir).isDirectory() || isFile(archivePath(runDir))
    } catch {
        return isFile(archivePath(runDir))
    }
}

/**
 * The files of a run folder that are packed: everything except the dot files and
 * folders (the `.claim` marker, the `.pack` lock, a staging folder), the archives and
 * their staging files. Links and anything that is not a plain file are left alone, and so
 * is a file whose name could not be an entry (a backslash, say).
 *
 * @param runDir - the run folder.
 * @returns `/`-separated paths relative to it, sorted.
 */
export function packableFiles(runDir: string): string[] {
    const found: string[] = []
    const walk = (folder: string, prefix: string): void => {
        let names: string[]
        try {
            names = readdirSync(folder)
        } catch {
            return
        }
        for (const name of names) {
            if (name.startsWith(".")) continue
            const rel = prefix === "" ? name : `${prefix}/${name}`
            if (prefix === "" && name.startsWith(RUN_FLOW.archive.legacyName)) continue
            let st: ReturnType<typeof lstatSync>
            try {
                st = lstatSync(join(folder, name))
            } catch {
                continue
            }
            if (st.isDirectory()) walk(join(folder, name), rel)
            else if (st.isFile() && !name.startsWith("~$") && isSafeEntryName(rel))
                found.push(rel)
        }
    }
    walk(runDir, "")
    return found.sort()
}

/**
 * Packs a finished run folder into `<run>.7z` (see the top of this section) and removes
 * the folder. Call it once the run's process is over.
 *
 * @param runDir - the run folder.
 * @returns how many files were packed (0: nothing to pack, or a run of the older layout
 *     that is packed already; no archive was made).
 * @throws [[ArchiveError]] when the archive exists already or a step failed (the message
 *     says why; the folder is as it was).
 */
export async function packRun(runDir: string): Promise<number> {
    if (isFile(legacyArchivePath(runDir))) return 0
    const files = packableFiles(runDir)
    if (files.length === 0) return 0
    await packFiles(runDir, archivePath(runDir), files)
    removePacked(runDir, files)
    // what is left of the folder: the markers and staging folders of the run (never
    // data), then the folder itself if nothing else is in it
    try {
        for (const name of readdirSync(runDir))
            if (name === ".claim" || name === ".pack.lock" || name.startsWith(".stage-")) {
                rmSync(join(runDir, name), { recursive: true, force: true })
            }
        rmdirSync(runDir)
    } catch {
        // something else is in the folder: it stays
    }
    return files.length
}

// ========================================================================================
// 2. Reading
// ========================================================================================

/** A file the run does not have, in its folder or in its archive. */
export class RunFileMissing extends Error {}

/** A file over the size a reader takes. */
export class RunFileTooLarge extends Error {}

/** The files of a run's own that an older run keeps under `logs/`. */
const LOG_FILES: ReadonlySet<string> = new Set([
    "run.LOG",
    "settings.json",
    "buffer.json",
    "data.tsv",
    "data.json",
    "solutes.json",
    "models.json",
    "model-settings.json",
    "model-references.json",
    "plots.txt",
])

/**
 * Where an older run keeps a file that the flat layout names `rel`: the inputs and the
 * logs were under `logs/`, the reference fits under `logs/reference-fit/` (or
 * `logs/references/`). A model's files are not mapped: `run.json` of an older run names
 * them with their old paths.
 *
 * @param rel - a flat name (`run.LOG`, `reference-fit-CRYSOL.tsv`).
 * @returns the older paths to try, none for a name that has none.
 */
export function legacyNames(rel: string): string[] {
    if (LOG_FILES.has(rel)) return [`logs/${rel}`]
    const reference = /^reference-fit-(.+)$/.exec(rel)
    if (reference?.[1] !== undefined)
        return [`logs/reference-fit/${reference[1]}`, `logs/references/${reference[1]}`]
    return []
}

/** Where a file of a run is: a plain path, or an entry of an archive. */
type Place = { plain: string } | { archive: string; name: string; size: number }

/** The archive entries of a run, listed (a listing that fails is an empty one). */
function archivedEntries(archive: string): Map<string, number> {
    try {
        return new Map(listEntries(archive).map((e) => [e.name, e.size]))
    } catch (error) {
        if (!(error instanceof ArchiveError)) throw error
        return new Map()
    }
}

/**
 * Finds a file of a run: tries the name as given, then the older paths it may have, each
 * in the plain folder first and then in the archives.
 */
function locate(runDir: string, rel: string): Place | undefined {
    for (const name of [rel, ...legacyNames(rel)]) {
        const plain = join(runDir, ...name.split("/"))
        if (isFile(plain)) return { plain }
        for (const archive of archivesOf(runDir)) {
            const size = archivedEntries(archive).get(name)
            if (size !== undefined) return { archive, name, size }
        }
    }
    return undefined
}

/** `run.json` texts kept by archive: an archive never changes, so its stamp is its key. */
const metadata = new Map<string, { stamp: string; text: string }>()

/**
 * The bytes of a file of a run, from its plain folder when it is there (a run being run,
 * or one whose pack was interrupted), else from the archive. A flat name falls back to the
 * paths of the older layouts. Nothing is written.
 *
 * @param runDir - the run (its folder's path, which need not exist once it is packed).
 * @param rel - the `/`-separated name (`run.LOG`, `crambin.xlsx`).
 * @param maxBytes - the most the file may hold.
 * @throws [[RunFileMissing]] if neither has it, [[RunFileTooLarge]] over `maxBytes`,
 *     [[ArchiveError]] for an archive 7-Zip cannot read, Error for a name that is not safe.
 */
export function readRunBytes(
    runDir: string,
    rel: string,
    maxBytes: number = RUN_FLOW.archive.maxEntryBytes,
): Buffer {
    if (!isSafeEntryName(rel)) throw new Error(`not a safe name: ${rel}`)
    const place = locate(runDir, rel)
    if (place === undefined) throw new RunFileMissing(`no ${rel}`)
    if ("plain" in place) {
        let size: number
        try {
            size = statSync(place.plain).size
        } catch {
            throw new RunFileMissing(`no ${rel}`)
        }
        if (size > maxBytes) throw new RunFileTooLarge(`${rel} is too large`)
        try {
            return readFileSync(place.plain)
        } catch {
            throw new RunFileMissing(`no ${rel}`)
        }
    }
    if (place.size > maxBytes) throw new RunFileTooLarge(`${rel} is too large`)
    if (rel === "run.json") return cachedMetadata(place.archive, place.name, maxBytes)
    return readEntry(place.archive, place.name, maxBytes)
}

/** `run.json` of an archive, read once while the archive stays as it is. */
function cachedMetadata(archive: string, name: string, maxBytes: number): Buffer {
    let stamp: string
    try {
        const st = statSync(archive)
        stamp = `${st.mtimeMs}:${st.size}`
    } catch {
        return readEntry(archive, name, maxBytes)
    }
    const kept = metadata.get(archive)
    if (kept?.stamp === stamp) return Buffer.from(kept.text, "utf-8")
    const bytes = readEntry(archive, name, maxBytes)
    metadata.set(archive, { stamp, text: bytes.toString("utf-8") })
    return bytes
}

/** [[readRunBytes]] as UTF-8 text. */
export function readRunText(
    runDir: string,
    rel: string,
    maxBytes: number = RUN_FLOW.archive.maxEntryBytes,
): string {
    return readRunBytes(runDir, rel, maxBytes).toString("utf-8")
}

/**
 * The archive that holds a file of a run, for a file the plain folder does not have.
 *
 * @param rel - the path relative to the run folder, as the archive names it.
 * @returns the archive, `undefined` when none holds it.
 */
export function archiveHolding(runDir: string, rel: string): string | undefined {
    return archivesOf(runDir).find((archive) => archivedEntries(archive).has(rel))
}

/**
 * The files directly in a folder of a run, plain and archived together (a plain file
 * wins).
 *
 * @param runDir - the run (its folder's path).
 * @param folder - the `/`-separated folder relative to it (`""` is the run's own top:
 *     the flat layout; `logs`, `crambin/output/plots` are folders of the older layouts).
 * @returns file name to bytes; empty for a folder that is nowhere.
 */
export function runFolderFiles(runDir: string, folder: string): Map<string, number> {
    const sizes = new Map<string, number>()
    const prefix = folder === "" ? "" : `${folder}/`
    for (const archive of archivesOf(runDir)) {
        for (const [name, size] of archivedEntries(archive)) {
            if (!name.startsWith(prefix)) continue
            const rest = name.slice(prefix.length)
            if (!rest.includes("/")) sizes.set(rest, size)
        }
    }
    const parts = folder === "" ? [] : folder.split("/")
    let names: string[] = []
    try {
        names = readdirSync(join(runDir, ...parts))
    } catch {
        // no plain folder
    }
    for (const name of names) {
        if (folder === "" && name.startsWith(".")) continue
        try {
            const st = statSync(join(runDir, ...parts, name))
            if (st.isFile()) sizes.set(name, st.size)
        } catch {
            // gone since the listing
        }
    }
    return sizes
}

// ========================================================================================
// 3. Files for the viewers
// ========================================================================================

/** The folder the copies are made in: made on first use, removed when the program ends. */
let copies: string | undefined

/** The folder of the copies of archived files. */
function copiesFolder(): string {
    if (copies !== undefined) return copies
    const made = mkdtempSync(join(tmpdir(), "baysol-view-"))
    copies = made
    process.once("exit", () => {
        try {
            rmSync(made, { recursive: true, force: true })
        } catch {
            // the system's temporary folder is cleaned anyway
        }
    })
    return made
}

/**
 * A file of a run as a path on disk: the file itself when it is a plain file, else a copy
 * of the archived entry in a temporary folder that is removed when the program ends (the
 * viewers open paths, and a workbook cannot be streamed out of an archive).
 *
 * @param runDir - the run (its folder's path).
 * @param path - the file's path inside the run's folder, as `run.json` and the lists give
 *     it (`<run>/crambin.xlsx`); it need not exist.
 * @returns the path to open.
 * @throws [[RunFileMissing]], [[RunFileTooLarge]], [[ArchiveError]] as [[readRunBytes]].
 */
export function materializeRunFile(runDir: string, path: string): string {
    if (isFile(path)) return path
    const rel = relative(runDir, path).split(sep).join("/")
    const bytes = readRunBytes(runDir, rel)
    const key = createHash("sha256").update(`${runDir}\0${rel}`).digest("hex").slice(0, 12)
    const folder = join(copiesFolder(), key)
    mkdirSync(folder, { recursive: true })
    const copy = join(folder, basename(rel))
    writeFileSync(copy, bytes)
    return copy
}
