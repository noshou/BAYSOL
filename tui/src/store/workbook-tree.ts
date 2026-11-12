// SPDX-License-Identifier: LGPL-3.0-or-later

// Workbooks in a run's archive. A `.xlsx` is a zip of XML files, so it is already
// compressed and 7-Zip can do little with it; the archive holds each workbook as the
// tree of its unzipped files (`m.xlsx` is `m/[Content_Types].xml`, `m/_rels/.rels`,
// `m/xl/...`), which 7-Zip compresses as one solid block, far smaller. When a reader needs
// the workbook, it is zipped again from the tree into a proper `.xlsx`: the same entries
// in a fixed order (`[Content_Types].xml` first), the same time on every file, so the
// same bytes every time. This module is the one place that knows both directions.
//
// Contents:
//   1. Names: which file is a workbook, where its tree is
//   2. Packing: a workbook opened into its tree
//   3. Reading: a workbook zipped again from the tree

import {
    copyFileSync,
    existsSync,
    mkdirSync,
    mkdtempSync,
    readdirSync,
    renameSync,
    rmSync,
    statSync,
    utimesSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import {
    ArchiveError,
    extractAllSync,
    extractNamesSync,
    listEntries,
    zipFolderSync,
} from "../core/archive.js"
import { RUN_FLOW } from "../core/environment.js"

// ========================================================================================
// 1. Names
// ========================================================================================

/** The extension of a workbook. */
const EXTENSION = ".xlsx"

/** The time every file of a rebuilt workbook has (a zip keeps one), so rebuilds agree. */
const FIXED_TIME = new Date("2000-01-01T00:00:00Z")

/** The entry every workbook has: a folder of the archive that holds it is a workbook. */
export const WORKBOOK_MARK = "[Content_Types].xml"

/** The entries a workbook zip starts with, in this order, then the others by name. */
const FIRST_ENTRIES = [WORKBOOK_MARK, "_rels/.rels"]

/**
 * Whether a name is a workbook.
 *
 * @param rel - a `/`-separated name in a run.
 * @returns `true` for a name ending in `.xlsx`.
 */
export const isWorkbookName = (rel: string): boolean =>
    rel.toLowerCase().endsWith(EXTENSION)

/**
 * The folder a workbook's tree has in the archive.
 *
 * @param rel - the workbook's name (`m.xlsx`).
 * @returns the name without the extension (`m`).
 */
const treeFolder = (rel: string): string => rel.slice(0, -EXTENSION.length)

/**
 * The entries of an archive that make up a workbook's tree.
 *
 * @param archive - the archive's path.
 * @param rel - the workbook's name.
 * @returns the entries' names and sizes, none when the archive holds no such tree.
 */
export function treeEntries(
    archive: string,
    rel: string,
): { name: string; size: number }[] {
    const prefix = `${treeFolder(rel)}/`
    return listEntries(archive).filter((e) => e.name.startsWith(prefix))
}

// ========================================================================================
// 2. Packing
// ========================================================================================

/** The files under a folder as `/`-separated paths relative to it, sorted. */
function filesUnder(folder: string, prefix = ""): string[] {
    const out: string[] = []
    for (const name of readdirSync(folder)) {
        const path = join(folder, name)
        const rel = prefix === "" ? name : `${prefix}/${name}`
        if (statSync(path).isDirectory()) out.push(...filesUnder(path, rel))
        else out.push(rel)
    }
    return out.sort()
}

/**
 * Opens a workbook of a run folder into its tree, beside it (`m.xlsx` into `m/`). The
 * workbook itself is left; the caller packs the tree and removes both.
 *
 * @param runDir - the run folder.
 * @param rel - the workbook's name in it.
 * @returns the tree's files as `/`-separated names relative to the run folder.
 * @throws [[ArchiveError]] when something is in the way of the tree's folder or the
 *     workbook is not a zip; nothing is left behind then.
 */
export function expandWorkbook(runDir: string, rel: string): string[] {
    const folder = treeFolder(rel)
    const tree = join(runDir, ...folder.split("/"))
    if (existsSync(tree)) throw new ArchiveError(`${folder} is in the way of ${rel}`)
    try {
        extractAllSync(join(runDir, ...rel.split("/")), tree)
        return filesUnder(tree).map((file) => `${folder}/${file}`)
    } catch (error) {
        discardTree(runDir, rel)
        throw error
    }
}

/**
 * Removes the tree [[expandWorkbook]] made (a pack that failed).
 *
 * @param runDir - the run folder.
 * @param rel - the workbook's name.
 */
export function discardTree(runDir: string, rel: string): void {
    rmSync(join(runDir, ...treeFolder(rel).split("/")), { recursive: true, force: true })
}

// ========================================================================================
// 3. Reading
// ========================================================================================

/** The entries of a zip in the order a workbook wants them. */
const zipOrder = (files: readonly string[]): string[] => {
    const first = FIRST_ENTRIES.filter((f) => files.includes(f))
    return [...first, ...files.filter((f) => !first.includes(f)).sort()]
}

/**
 * Makes the `.xlsx` of a workbook that the archive holds as a tree.
 *
 * @param archive - the archive's path.
 * @param rel - the workbook's name in it.
 * @param out - where the workbook is written (its folder must exist); a file there is
 *     replaced.
 * @throws [[ArchiveError]] when the archive holds no tree for it, the tree is over the
 *     size an extraction may take, or 7-Zip fails.
 */
export function rebuildWorkbook(archive: string, rel: string, out: string): void {
    const entries = treeEntries(archive, rel)
    if (entries.length === 0) throw new ArchiveError(`the archive holds no ${rel}`)
    const total = entries.reduce((sum, e) => sum + e.size, 0)
    if (total > RUN_FLOW.archive.maxExtractBytes)
        throw new ArchiveError(`${rel} is too large to open`)
    const tmp = mkdtempSync(join(tmpdir(), "baysol-book-"))
    try {
        extractNamesSync(
            archive,
            entries.map((e) => e.name),
            tmp,
        )
        const folder = treeFolder(rel)
        const root = join(tmp, ...folder.split("/"))
        const files = filesUnder(root)
        for (const file of files) {
            utimesSync(join(root, ...file.split("/")), FIXED_TIME, FIXED_TIME)
        }
        const zip = join(tmp, "book.zip")
        zipFolderSync(root, zipOrder(files), zip)
        mkdirSync(dirname(out), { recursive: true })
        const staging = `${out}.tmp.${process.pid}`
        // copied, not renamed: the temporary folder may be on another file system
        copyFileSync(zip, staging)
        renameSync(staging, out)
    } finally {
        rmSync(tmp, { recursive: true, force: true })
    }
}
