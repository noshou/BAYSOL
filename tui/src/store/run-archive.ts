// SPDX-License-Identifier: LGPL-3.0-or-later

// The archive of a run folder: what is packed, how it is packed, and the readers that take
// the archive or the plain folders alike.
//
// Contents:
//   1. What is packed, and packing a finished run
//   2. Reading a run's files from the archive or from the folders

import { lstatSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join } from "node:path"
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
 * A finished run folder is packed into ONE archive, `<run>/run.7z`, specific to that run.
 * Inside it the paths are relative to the run folder (`logs/run.LOG`,
 * `<model>/<model>.LOG`, `<model>/output/plots.txt`, `<model>/output/plots/<name>.tex`,
 * `compare/plots.txt`, ...). Left OUTSIDE it, in place:
 *
 * - `run.json`, the small metadata file the run lists, the state of a run and the
 *   viewers' `plot_sizes` come from (what the program needs fast and without a 7-Zip);
 * - the `.xlsx` workbooks (`<model>/output/*.xlsx`, `compare/*.xlsx`), which the viewer
 *   opens directly and which do not compress;
 * - the dot files of the run folder: the `.claim` marker and the `.pack` lock.
 *
 * Packing is atomic and removes the packed originals only after the archive has passed
 * `7z t` and holds every file; a failure leaves the run folder as it was. A run that was
 * never packed (an older one, or one whose pack failed) reads from its plain folders.
 */

/** The archive's name in a run folder. */
export const RUN_ARCHIVE = RUN_FLOW.archive.name

/** The file of a run folder that is never packed. */
const METADATA = "run.json"

/** The path of a run's archive (it may not exist). */
export const archivePath = (runDir: string): string => join(runDir, RUN_ARCHIVE)

/** Whether a run has been packed. */
export const isPacked = (runDir: string): boolean => isFile(archivePath(runDir))

/** Whether a file name is a workbook (`~$x.xlsx` lock files are not packed either). */
const isWorkbook = (name: string): boolean => /\.xlsx$/i.test(name) || name.startsWith("~$")

/**
 * The files of a run folder that are packed: everything except `run.json`, the workbooks,
 * the dot files of the top folder, the archive itself and its staging files. Links and
 * anything that is not a plain file are left alone, and so is a file whose name could
 * not be an entry (a backslash, say).
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
            const rel = prefix === "" ? name : `${prefix}/${name}`
            const top = prefix === ""
            if (top && (name === METADATA || name.startsWith("."))) continue
            if (top && name.startsWith(`${RUN_ARCHIVE}`)) continue
            let st: ReturnType<typeof lstatSync>
            try {
                st = lstatSync(join(folder, name))
            } catch {
                continue
            }
            if (st.isDirectory()) walk(join(folder, name), rel)
            else if (st.isFile() && !isWorkbook(name) && isSafeEntryName(rel))
                found.push(rel)
        }
    }
    walk(runDir, "")
    return found.sort()
}

/**
 * Packs a finished run folder (see the top of this section). Call it once the run's
 * process is over.
 *
 * @param runDir - the run folder.
 * @returns how many files were packed (0: nothing to pack, no archive was made).
 * @throws [[ArchiveError]] when the run is packed already or a step failed (the message
 *     says why; the folder is as it was).
 */
export async function packRun(runDir: string): Promise<number> {
    const files = packableFiles(runDir)
    if (files.length === 0) return 0
    await packFiles(runDir, RUN_ARCHIVE, files)
    removePacked(runDir, files)
    return files.length
}

// ========================================================================================
// 2. Reading
// ========================================================================================

/** A file the run does not have, in its folders or in its archive. */
export class RunFileMissing extends Error {}

/** A file over the size a reader takes. */
export class RunFileTooLarge extends Error {}

/**
 * The bytes of a file of a run, from its plain folder when it is there (a run not packed,
 * or one whose pack was interrupted), else from the archive. Nothing is written.
 *
 * @param runDir - the run folder.
 * @param rel - the `/`-separated path relative to the run folder (`logs/run.LOG`).
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
    const plain = join(runDir, ...rel.split("/"))
    let size: number | undefined
    try {
        const st = statSync(plain)
        if (st.isFile()) size = st.size
    } catch {
        // not a plain file: the archive may have it
    }
    if (size !== undefined) {
        if (size > maxBytes) throw new RunFileTooLarge(`${rel} is too large`)
        try {
            return readFileSync(plain)
        } catch {
            throw new RunFileMissing(`no ${rel}`)
        }
    }
    const archive = archivePath(runDir)
    if (!isFile(archive)) throw new RunFileMissing(`no ${rel}`)
    const entry = listEntries(archive).find((e) => e.name === rel)
    if (entry === undefined) throw new RunFileMissing(`no ${rel}`)
    if (entry.size > maxBytes) throw new RunFileTooLarge(`${rel} is too large`)
    return readEntry(archive, rel, maxBytes)
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
 * The files directly in a folder of a run, plain and archived together (a plain file
 * wins).
 *
 * @param runDir - the run folder.
 * @param folder - the `/`-separated folder relative to it (`logs`, `crambin/output/plots`).
 * @returns file name to bytes; empty for a folder that is nowhere.
 */
export function runFolderFiles(runDir: string, folder: string): Map<string, number> {
    const sizes = new Map<string, number>()
    const archive = archivePath(runDir)
    if (isFile(archive)) {
        try {
            for (const { name, size } of listEntries(archive)) {
                if (!name.startsWith(`${folder}/`)) continue
                const rest = name.slice(folder.length + 1)
                if (!rest.includes("/")) sizes.set(rest, size)
            }
        } catch (error) {
            if (!(error instanceof ArchiveError)) throw error
            // an archive that cannot be read lists nothing of its own
        }
    }
    let names: string[] = []
    try {
        names = readdirSync(join(runDir, ...folder.split("/")))
    } catch {
        // no plain folder
    }
    for (const name of names) {
        try {
            const st = statSync(join(runDir, ...folder.split("/"), name))
            if (st.isFile()) sizes.set(name, st.size)
        } catch {
            // gone since the listing
        }
    }
    return sizes
}
