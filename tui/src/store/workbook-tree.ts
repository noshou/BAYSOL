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
    readdirSync,
    renameSync,
    rmSync,
    statSync,
    utimesSync,
} from "node:fs"
import { dirname, join } from "node:path"
import {
    ArchiveError,
    type Entry,
    extractAllAsync,
    extractNamesAsync,
    extractNamesSync,
    listEntries,
    zipFolderAsync,
    zipFolderSync,
} from "../core/archive.js"
import { RUN_FLOW } from "../core/environment.js"
import { scratchTemp } from "../core/scratch.js"

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
export async function expandWorkbook(runDir: string, rel: string): Promise<string[]> {
    const folder = treeFolder(rel)
    const tree = join(runDir, ...folder.split("/"))
    if (existsSync(tree)) throw new ArchiveError(`${folder} is in the way of ${rel}`)
    try {
        await extractAllAsync(join(runDir, ...rel.split("/")), tree)
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

/** Counts this process's staging files, so two rebuilds of one file never share one. */
let stagings = 0

/**
 * What a rebuild extracts: the archives that hold a tree, with its entries.
 *
 * @throws [[ArchiveError]] when no archive holds a tree, or it is over the size an
 *     extraction may take.
 */
function planRebuild(
    archives: string | readonly string[],
    rel: string,
): { archive: string; entries: Entry[] }[] {
    const parts = (typeof archives === "string" ? [archives] : archives)
        .map((archive) => ({ archive, entries: treeEntries(archive, rel) }))
        .filter((part) => part.entries.length > 0)
    const entries = parts.flatMap((part) => part.entries)
    if (entries.length === 0) throw new ArchiveError(`the archive holds no ${rel}`)
    const total = entries.reduce((sum, e) => sum + e.size, 0)
    if (total > RUN_FLOW.archive.maxExtractBytes)
        throw new ArchiveError(`${rel} is too large to open`)
    return parts
}

/** Gives the extracted files the fixed time and returns the tree's root and file order. */
function orderTree(tmp: string, rel: string): { root: string; order: string[] } {
    const root = join(tmp, ...treeFolder(rel).split("/"))
    const files = filesUnder(root)
    for (const file of files) {
        utimesSync(join(root, ...file.split("/")), FIXED_TIME, FIXED_TIME)
    }
    return { root, order: zipOrder(files) }
}

/** Puts the finished zip at `out` (copied, not renamed: another file system, maybe). */
function publishZip(zip: string, out: string): void {
    mkdirSync(dirname(out), { recursive: true })
    stagings += 1
    const staging = `${out}.tmp.${process.pid}.${stagings}`
    copyFileSync(zip, staging)
    renameSync(staging, out)
}

/**
 * Makes the `.xlsx` of a workbook that the archive holds as a tree. The entries are
 * stored, not compressed (the copy is temporary), so the same tree gives the same bytes.
 *
 * @param archives - the archive's path, or the archives of a run that hold the tree
 *     together (the big `draws` sheet may be in an archive of its own).
 * @param rel - the workbook's name in it.
 * @param out - where the workbook is written (its folder is made); a file there is
 *     replaced.
 * @throws [[ArchiveError]] when the archive holds no tree for it, the tree is over the
 *     size an extraction may take, or 7-Zip fails.
 */
export function rebuildWorkbook(
    archives: string | readonly string[],
    rel: string,
    out: string,
): void {
    const parts = planRebuild(archives, rel)
    const tmp = scratchTemp("book")
    try {
        for (const part of parts)
            extractNamesSync(
                part.archive,
                part.entries.map((e) => e.name),
                tmp,
            )
        const { root, order } = orderTree(tmp, rel)
        const zip = join(tmp, "book.zip")
        // stored, not deflated: the copy is temporary, and level 9 cost seconds on a
        // big sheet
        zipFolderSync(root, order, zip, 0)
        publishZip(zip, out)
    } finally {
        rmSync(tmp, { recursive: true, force: true })
    }
}

/**
 * [[rebuildWorkbook]] without blocking: 7-Zip runs as a child process and the screen keeps
 * drawing (the walk of the extracted folder is the only synchronous part).
 *
 * @throws [[ArchiveError]] (as a rejection), as [[rebuildWorkbook]].
 */
export async function rebuildWorkbookAsync(
    archives: string | readonly string[],
    rel: string,
    out: string,
): Promise<void> {
    const parts = planRebuild(archives, rel)
    const tmp = scratchTemp("book")
    try {
        for (const part of parts)
            await extractNamesAsync(
                part.archive,
                part.entries.map((e) => e.name),
                tmp,
            )
        const { root, order } = orderTree(tmp, rel)
        const zip = join(tmp, "book.zip")
        await zipFolderAsync(root, order, zip, 0)
        publishZip(zip, out)
    } finally {
        rmSync(tmp, { recursive: true, force: true })
    }
}
