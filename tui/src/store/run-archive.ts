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
import {
    discardTree,
    expandWorkbook,
    isWorkbookName,
    rebuildWorkbook,
    treeEntries,
    WORKBOOK_MARK,
} from "./workbook-tree.js"

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
 * A workbook goes in as the tree of its unzipped XML files (`m.xlsx` as `m/...`), which
 * compresses far better; readers rebuild a proper `.xlsx` from it ([[materializeRunFile]],
 * `store/workbook-tree.ts`).
 *
 * Packing is atomic: the archive is made beside the folder, tested with `7z t`, compared
 * with the list of what was asked for, and only then are the packed files (and the
 * folder, once empty) removed. A failure leaves the run folder as it was.
 *
 * A run is one flat folder or its one archive.
 */

/** The path of a run's archive, beside its folder (it may not exist). */
export const archivePath = (runDir: string): string =>
    `${runDir}${RUN_FLOW.archive.extension}`

/** Whether a run has been packed. */
export const isPacked = (runDir: string): boolean => isFile(archivePath(runDir))

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
 * folders (the `.claim` marker, the `.pack` lock, a staging folder). Links and anything
 * that is not a plain file are left alone, and so is a file whose name could not be an
 * entry (a backslash, say).
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
 * @returns how many files were packed (0: nothing to pack; no archive was made).
 * @throws [[ArchiveError]] when the archive exists already or a step failed (the message
 *     says why; the folder is as it was).
 */
export async function packRun(runDir: string): Promise<number> {
    const plain = packableFiles(runDir)
    if (plain.length === 0) return 0
    // a workbook goes in as its tree: the tree's files take the place of the `.xlsx`
    const books = plain.filter(isWorkbookName)
    const files = plain.filter((f) => !isWorkbookName(f))
    // only the trees made here are taken away again if the pack fails
    const opened: string[] = []
    try {
        for (const rel of books) {
            files.push(...expandWorkbook(runDir, rel))
            opened.push(rel)
        }
        files.sort()
        await packFiles(runDir, archivePath(runDir), files)
    } catch (error) {
        for (const rel of opened) discardTree(runDir, rel)
        throw error
    }
    removePacked(runDir, [...files, ...books])
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
    return plain.length
}

// ========================================================================================
// 2. Reading
// ========================================================================================

/** A file the run does not have, in its folder or in its archive. */
export class RunFileMissing extends Error {}

/** A file over the size a reader takes. */
export class RunFileTooLarge extends Error {}

/** The names of the files a run folder holds of its own (the flat layout). */
export const RUN_FILES = {
    log: "run.LOG",
    settings: "settings.json",
    buffer: "buffer.json",
    dataTable: "data.tsv",
    dataInfo: "data.json",
    solutes: "solutes.json",
    models: "models.json",
    modelSettings: "model-settings.json",
    modelReferences: "model-references.json",
    plots: "plots.txt",
} as const

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

/** Finds a file of a run: in the plain folder first, then in the archive. */
function locate(runDir: string, rel: string): Place | undefined {
    const plain = join(runDir, ...rel.split("/"))
    if (isFile(plain)) return { plain }
    const archive = archivePath(runDir)
    if (!isFile(archive)) return undefined
    const size = archivedEntries(archive).get(rel)
    return size === undefined ? undefined : { archive, name: rel, size }
}

/** `run.json` texts kept by archive: an archive never changes, so its stamp is its key. */
const metadata = new Map<string, { stamp: string; text: string }>()

/**
 * The bytes of a file of a run, from its plain folder when it is there (a run being run,
 * or one whose pack was interrupted), else from the archive. Nothing is written.
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
 * @param rel - the path relative to the run folder, as the archive names it; a workbook
 *     (`m.xlsx`) is held as its tree (`m/...`).
 * @returns the archive, `undefined` when none holds it.
 */
export function archiveHolding(runDir: string, rel: string): string | undefined {
    const holds = (archive: string): boolean =>
        isWorkbookName(rel)
            ? treeEntries(archive, rel).length > 0
            : archivedEntries(archive).has(rel)
    const archive = archivePath(runDir)
    return isFile(archive) && holds(archive) ? archive : undefined
}

/**
 * The files of a run's own top folder, plain and archived together (a plain file wins).
 *
 * @param runDir - the run (its folder's path).
 * @returns file name to bytes; empty for a run that is nowhere.
 */
export function runFiles(runDir: string): Map<string, number> {
    const sizes = new Map<string, number>()
    const archive = archivePath(runDir)
    if (isFile(archive)) {
        // a workbook is held as a tree (`m/[Content_Types].xml`, ...): listed as `m.xlsx`
        const trees = new Map<string, { size: number; book: boolean }>()
        for (const [name, size] of archivedEntries(archive)) {
            const slash = name.indexOf("/")
            if (slash < 0) {
                sizes.set(name, size)
                continue
            }
            const tree = trees.get(name.slice(0, slash)) ?? { size: 0, book: false }
            tree.size += size
            tree.book ||= name.slice(slash + 1) === WORKBOOK_MARK
            trees.set(name.slice(0, slash), tree)
        }
        for (const [folderName, tree] of trees)
            if (tree.book) sizes.set(`${folderName}.xlsx`, tree.size)
    }
    let names: string[] = []
    try {
        names = readdirSync(runDir)
    } catch {
        // no plain folder
    }
    for (const name of names) {
        if (name.startsWith(".")) continue
        try {
            const st = statSync(join(runDir, name))
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
 *     it (`<run>/crambin.xlsx`); it need not exist. A workbook only in the archive is
 *     rebuilt from its tree.
 * @returns the path to open.
 * @throws [[RunFileMissing]], [[RunFileTooLarge]], [[ArchiveError]] as [[readRunBytes]].
 */
export function materializeRunFile(runDir: string, path: string): string {
    if (isFile(path)) return path
    const rel = relative(runDir, path).split(sep).join("/")
    const key = createHash("sha256").update(`${runDir}\0${rel}`).digest("hex").slice(0, 12)
    const folder = join(copiesFolder(), key)
    mkdirSync(folder, { recursive: true })
    const copy = join(folder, basename(rel))
    if (isWorkbookName(rel)) {
        // held as a tree: zipped again into a proper workbook (an archive never changes,
        // so a copy made earlier is the same file)
        const archive = archiveHolding(runDir, rel)
        if (archive === undefined) throw new RunFileMissing(`no ${rel}`)
        if (!isFile(copy)) rebuildWorkbook(archive, rel, copy)
        return copy
    }
    writeFileSync(copy, readRunBytes(runDir, rel))
    return copy
}
