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
    readdirSync,
    readFileSync,
    rmdirSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { basename, dirname, join, relative, sep } from "node:path"
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
    makeViewFolder,
    removeProcessFolder,
    sweepDeadFolders,
    touchCopy,
    trimCopies,
} from "./view-cache.js"
import {
    discardTree,
    expandWorkbook,
    isWorkbookName,
    rebuildWorkbook,
    rebuildWorkbookAsync,
    treeEntries,
    WORKBOOK_MARK,
} from "./workbook-tree.js"

// ========================================================================================
// 1. What is packed
// ========================================================================================

/**
 * A finished run is `runs/<stamp>.7z` with the run's files in it as FLAT names
 * (`run.LOG`, `<model>.xlsx`, `<model>.tex`, `<model>-plots.txt`, `compare.tsv`, ...), and
 * up to two small companions that keep the cheap files away from the heavy ones (item 16
 * of the UI bugfix list in `notes/release-0.5.0-todo.md`):
 *
 * - `<stamp>.meta.7z`: the small metadata (`run.json`, every `.LOG`, `.json`, `.tsv`,
 *   `plots.txt`, `<model>-plots.txt`), so a listing, the comparison and the open-runs
 *   screen never decode the solid block of the workbooks;
 * - `<stamp>.draws.7z`: a worksheet of a workbook tree that is over `DRAWS_MIN_BYTES`
 *   (the `draws` sheet, 13 MB of XML). Measured: the method is the same (level 9 was
 *   already the configured one, and xz, PPMd and LZMA2 tuning gain under 1 percent), so
 *   the group saves no bytes; it keeps the 13 MB block out of the archive that holds the
 *   rest (a sixel cache added to the run rewrites 113 KB, not 1.8 MB).
 *
 * `<stamp>.7z` always exists and holds the rest. A run packed before the split is that
 * one archive holding everything; readers look a file up in every archive of the run
 * ([[archivesOf]]), so both kinds open alike. While the run goes, and for a run whose
 * pack failed, its files are in the plain folder
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

/** The groups a run's files are packed in; `main` is the archive every run has. */
export type RunGroup = "main" | "meta" | "draws"

/** The part of an archive's name before the extension, per group. */
const GROUP_SUFFIX: Record<RunGroup, string> = { main: "", meta: ".meta", draws: ".draws" }

/** A workbook sheet at least this big (bytes uncompressed) goes in the `draws` group. */
const DRAWS_MIN_BYTES = 4 * 1024 * 1024

/**
 * The path of one of a run's archives, beside its folder (it may not exist).
 *
 * @param group - which archive of the run (`main` when omitted).
 */
export const archivePath = (runDir: string, group: RunGroup = "main"): string =>
    `${runDir}${GROUP_SUFFIX[group]}${RUN_FLOW.archive.extension}`

/**
 * Whether a file name under `runs/` is a companion archive of a run (`<stamp>.meta.7z`)
 * and so not a run of its own.
 */
export const isCompanionArchive = (name: string): boolean =>
    [GROUP_SUFFIX.meta, GROUP_SUFFIX.draws].some((suffix) =>
        name.endsWith(`${suffix}${RUN_FLOW.archive.extension}`),
    )

/** The archives a run has now, `meta` first (the cheap one), then `main`, then `draws`. */
export const archivesOf = (runDir: string): string[] =>
    (["meta", "main", "draws"] as const)
        .map((group) => archivePath(runDir, group))
        .filter(isFile)

/**
 * The group a file is packed in.
 *
 * @param rel - the `/`-separated name (a workbook already opened into its tree).
 * @param size - the file's size in bytes.
 */
function groupOf(rel: string, size: number): RunGroup {
    if (!rel.includes("/") && /(\.(json|LOG|tsv)|(^|-)plots\.txt)$/.test(rel))
        return "meta"
    if (rel.includes("/xl/worksheets/") && size >= DRAWS_MIN_BYTES) return "draws"
    return "main"
}

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
            files.push(...(await expandWorkbook(runDir, rel)))
            opened.push(rel)
        }
        files.sort()
        await packGroups(runDir, files)
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

/**
 * Packs the files into the run's archives by [[groupOf]], the main one last (it is the
 * one whose presence says the run is packed). When the main group would be empty the
 * `meta` files go in it. A failure removes the archives this call made.
 *
 * @throws [[ArchiveError]] as [[packFiles]], or when an archive of the run exists.
 */
async function packGroups(runDir: string, files: readonly string[]): Promise<void> {
    const groups: Record<RunGroup, string[]> = { main: [], meta: [], draws: [] }
    for (const rel of files) {
        let size = 0
        try {
            size = statSync(join(runDir, ...rel.split("/"))).size
        } catch {
            // vanished: packFiles reports it
        }
        groups[groupOf(rel, size)].push(rel)
    }
    if (groups.main.length === 0) groups.main = groups.meta.splice(0)
    const made: string[] = []
    try {
        for (const group of ["meta", "draws", "main"] as const) {
            if (groups[group].length === 0) continue
            const archive = archivePath(runDir, group)
            await packFiles(runDir, archive, groups[group])
            made.push(archive)
        }
    } catch (error) {
        for (const archive of made) rmSync(archive, { force: true })
        throw error
    }
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

/** Finds a file of a run: in the plain folder first, then in its archives. */
function locate(runDir: string, rel: string): Place | undefined {
    const plain = join(runDir, ...rel.split("/"))
    if (isFile(plain)) return { plain }
    for (const archive of archivesOf(runDir)) {
        const size = archivedEntries(archive).get(rel)
        if (size !== undefined) return { archive, name: rel, size }
    }
    return undefined
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
 * The archives that hold a file of a run, for a file the plain folder does not have. A
 * plain file has one archive; a workbook's tree may be in two (the `draws` sheet).
 *
 * @param rel - the path relative to the run folder, as the archive names it; a workbook
 *     (`m.xlsx`) is held as its tree (`m/...`).
 * @returns the archives, none when nothing holds it.
 */
export function archivesHolding(runDir: string, rel: string): string[] {
    const holds = (archive: string): boolean =>
        isWorkbookName(rel)
            ? treeEntries(archive, rel).length > 0
            : archivedEntries(archive).has(rel)
    return archivesOf(runDir).filter(holds)
}

/** The first of [[archivesHolding]], `undefined` when none holds the file. */
const _archiveHolding = (runDir: string, rel: string): string | undefined =>
    archivesHolding(runDir, rel)[0]

/**
 * The files of a run's own top folder, plain and archived together (a plain file wins).
 *
 * @param runDir - the run (its folder's path).
 * @returns file name to bytes; empty for a run that is nowhere.
 */
export function runFiles(runDir: string): Map<string, number> {
    const sizes = new Map<string, number>()
    // a workbook is held as a tree (`m/[Content_Types].xml`, ...): listed as `m.xlsx`
    const trees = new Map<string, { size: number; book: boolean }>()
    for (const archive of archivesOf(runDir)) {
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
    }
    for (const [folderName, tree] of trees)
        if (tree.book) sizes.set(`${folderName}.xlsx`, tree.size)
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

/**
 * The folder of the copies of archived files, `<tmpdir>/baysol-<pid>/view`. The first use
 * sweeps the folders that dead processes left (`baysol-<pid>` of a pid that no longer
 * exists) and registers the exit hook that removes this process's folder.
 */
function copiesFolder(): string {
    if (copies !== undefined) return copies
    const base = tmpdir()
    sweepDeadFolders(base, process.pid)
    copies = makeViewFolder(base, process.pid)
    process.once("exit", () => removeProcessFolder(base, process.pid))
    return copies
}

/**
 * The folder a run's models are extracted into while it runs, `<tmpdir>/baysol-<pid>/
 * run-models/<key>`: in the same process folder as the view copies (swept when its process
 * is dead, removed at exit) but NOT inside `view/`, which is trimmed by size and must never
 * evict the models of a running fit. It is not made here.
 *
 * @param runDir - the run (its folder's path).
 */
export function runModelsFolder(runDir: string): string {
    const key = createHash("sha256").update(runDir).digest("hex").slice(0, 12)
    return join(dirname(copiesFolder()), "run-models", key)
}

/**
 * The folder the cache of a run is made in while it runs, `<tmpdir>/baysol-<pid>/
 * run-cache/<key>`, next to [[runModelsFolder]] and swept the same way. It holds the
 * generated files of a project that keeps its models in `models.7z`
 * (`extractGenerated`). It is not made here.
 *
 * @param runDir - the run (its folder's path).
 */
export function runCacheFolder(runDir: string): string {
    const key = createHash("sha256").update(runDir).digest("hex").slice(0, 12)
    return join(dirname(copiesFolder()), "run-cache", key)
}

/** Where the copy of a file of a run goes, and the folder name that identifies it. */
function copyPlace(
    runDir: string,
    path: string,
): { rel: string; key: string; folder: string; copy: string } {
    const rel = relative(runDir, path).split(sep).join("/")
    const key = createHash("sha256").update(`${runDir}\0${rel}`).digest("hex").slice(0, 12)
    const folder = join(copiesFolder(), key)
    return { rel, key, folder, copy: join(folder, basename(rel)) }
}

/** The rebuilds in progress, by the copy's path: one per file at a time. */
const rebuilding = new Map<string, Promise<string>>()

/**
 * A file of a run as a path on disk: the file itself when it is a plain file, else a copy
 * of the archived entry in a temporary folder that is removed when the program ends (the
 * viewers open paths, and a workbook cannot be streamed out of an archive).
 *
 * This one waits for the copy; [[materializeRunFileAsync]] does not.
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
    const { rel, key, folder, copy } = copyPlace(runDir, path)
    mkdirSync(folder, { recursive: true })
    if (isWorkbookName(rel)) {
        // held as a tree: zipped again into a proper workbook (an archive never changes,
        // so a copy made earlier is the same file)
        const archives = archivesHolding(runDir, rel)
        if (archives.length === 0) throw new RunFileMissing(`no ${rel}`)
        if (isFile(copy)) touchCopy(folder)
        else {
            rebuildWorkbook(archives, rel, copy)
            trimCopies(copiesFolder(), RUN_FLOW.archive.maxViewCacheBytes, key)
        }
        return copy
    }
    writeFileSync(copy, readRunBytes(runDir, rel))
    return copy
}

/**
 * [[materializeRunFile]] without blocking: a workbook is rebuilt by 7-Zip as a child
 * process. Two asks for the same file share one rebuild, and a copy that exists is not
 * made again. After a rebuild the copies are trimmed to `maxViewCacheBytes`, the new one
 * kept.
 *
 * @param runDir - the run (its folder's path).
 * @param path - as for [[materializeRunFile]].
 * @returns the path to open.
 * @throws [[RunFileMissing]], [[RunFileTooLarge]], [[ArchiveError]] (as rejections).
 */
export async function materializeRunFileAsync(
    runDir: string,
    path: string,
): Promise<string> {
    if (isFile(path)) return path
    const { rel, key, folder, copy } = copyPlace(runDir, path)
    if (!isWorkbookName(rel)) return materializeRunFile(runDir, path)
    const archives = archivesHolding(runDir, rel)
    if (archives.length === 0) throw new RunFileMissing(`no ${rel}`)
    if (isFile(copy)) {
        touchCopy(folder)
        return copy
    }
    const running = rebuilding.get(copy)
    if (running !== undefined) return running
    const job = (async () => {
        try {
            mkdirSync(folder, { recursive: true })
            await rebuildWorkbookAsync(archives, rel, copy)
            trimCopies(copiesFolder(), RUN_FLOW.archive.maxViewCacheBytes, key)
            return copy
        } finally {
            rebuilding.delete(copy)
        }
    })()
    rebuilding.set(copy, job)
    return job
}

/**
 * Starts making, in the background, the copies of a run's workbooks that only the archive
 * holds, one after the other, so that opening one later finds the copy ready. Errors are
 * ignored here (the viewer shows them when the file is really opened), and a file that is
 * being made or is made is not made again.
 *
 * @param runDir - the run (its folder's path).
 * @returns a promise that resolves when the warm-up is over (it never rejects).
 */
export async function warmRunWorkbooks(runDir: string): Promise<void> {
    try {
        for (const name of runFiles(runDir).keys()) {
            if (!isWorkbookName(name)) continue
            const path = join(runDir, name)
            if (isFile(path)) continue
            try {
                await materializeRunFileAsync(runDir, path)
            } catch {
                // shown when the file is opened
            }
        }
    } catch {
        // the run is gone or its archive unreadable
    }
}
