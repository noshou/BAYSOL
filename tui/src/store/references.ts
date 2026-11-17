// SPDX-License-Identifier: LGPL-3.0-or-later

// Reference fits: the reference curves of a project, kept in `<project>/reference-fit.7z`
// (`store/packs.ts`, notes/models-7z.md) or, in a project that has no archive yet, in its
// old `<project>/reference-fit/` folder, which is read and never changed or removed here.
//
// Julia reads every `.tsv`, `.dat` or `.txt` file with two or three numeric columns
// (q, I and an optional sigma that it reads and ignores; q in the units of `data.json`,
// divided by 10 for `nm-1`) as one curve named by the file's stem, and draws it with the
// comparison of a run; it reads the run's copies (`reference-fit-<file>`, made by
// `copyReferences` from either place), not the project. The `data` screen puts curves
// there from any table (its import
// screen in the reference mode), as CLEAN files: two or three tab-separated columns, no
// header, named by the stem of the source made safe, never over a file that is there.
// Nothing here deletes anything by itself; a delete is asked for with the stem's name.

import { readFileSync, statSync, writeFileSync } from "node:fs"
import { basename, extname, join } from "node:path"
import type { Locked } from "../core/archive.js"
import { isFile } from "../core/file-system.js"
import { numberText } from "../core/terminal.js"
import { readDataInfo, type Units } from "./data.js"
import { DataFileError, type DataPoints } from "./data-table.js"
import {
    type Pack,
    packAddText,
    packChangeAsync,
    packFile,
    packNames,
    packRemove,
    readPackFile,
} from "./packs.js"
import { lockedIn } from "./projects.js"

/** The folder of a project that holds the reference curves. */
const REFERENCES_FOLDER = "reference-fit"

/** The extensions Julia reads (compared in lower case). */
const REFERENCE_EXTENSIONS: readonly string[] = [".tsv", ".dat", ".txt"]

/** What is said when a reference is added before the project has data. */
export const IMPORT_DATA_FIRST = "import the data first"

/** The biggest reference file read, in bytes (it is read whole). */
const MAX_REFERENCE_BYTES = 20 * 1024 * 1024

/** The longest a stem made safe is (cells). */
const MAX_STEM = 60

/** The pack of the reference curves: `reference-fit.7z` and the folder it replaced. */
const REFERENCES_PACK: Pack = {
    archive: "reference-fit.7z",
    folder: REFERENCES_FOLDER,
    accepts: (name) => isReferenceFile(name),
}

/** @returns the path of a project's `reference-fit.7z` (it may not exist). */
export const referencesArchive = (projectDir: string): string =>
    packFile(projectDir, REFERENCES_PACK)

/** @returns the old `reference-fit/` folder of a project (it may not exist). */
export const referencesDir = (projectDir: string): string =>
    join(projectDir, REFERENCES_FOLDER)

/**
 * One file of the `reference-fit/` folder.
 *
 * @property file - the file name (with its extension).
 * @property name - the curve's name: the file's stem.
 * @property points - the points Julia draws (finite q and I above 0), `undefined` when
 *     the file is unusable.
 * @property qMin - the smallest q of those points, `undefined` when unusable.
 * @property qMax - the biggest q of those points, `undefined` when unusable.
 * @property unusable - why Julia would skip the file (a short reason), absent when it is
 *     a curve.
 */
export type ReferenceEntry = {
    file: string
    name: string
    points?: number
    qMin?: number
    qMax?: number
    unusable?: string
}

/** A cell that is a number to Julia's `tryparse`: a decimal one, or an infinity or NaN. */
const isCell = (cell: string): boolean =>
    numberText(cell) !== undefined || /^[-+]?(inf|infinity|nan)$/i.test(cell)

/**
 * Reads the text of a reference file the way Julia does (`_readReference`): lines are cut
 * at a `#`, blanks skipped, cells split on blanks, commas and semicolons, text lines
 * before the first numbers are a header; afterwards a line that is not 2 or 3 numbers is a
 * problem.
 *
 * @returns the points Julia draws and their q range.
 * @throws [[DataFileError]] with a short reason: no row of numbers, a line that is not 2
 *     or 3 numbers, no usable point.
 */
function parseReference(text: string): {
    points: number
    qMin: number
    qMax: number
} {
    let rows = 0
    let points = 0
    let qMin = Number.POSITIVE_INFINITY
    let qMax = Number.NEGATIVE_INFINITY
    for (const [k, raw] of text.split(/\r\n|\r|\n/).entries()) {
        const line = (raw.split("#", 1)[0] ?? "").trim()
        if (line === "") continue
        const cells = line.split(/[\s,;]+/).filter((c) => c !== "")
        if (!cells.every(isCell)) {
            if (rows === 0) continue // a header before the first numbers
            throw new DataFileError(`line ${k + 1}: a cell is no number`)
        }
        if (cells.length !== 2 && cells.length !== 3)
            throw new DataFileError(
                `line ${k + 1}: ${cells.length} columns, not 2 or 3`,
            )
        rows++
        const q = Number(cells[0])
        const intensity = Number(cells[1])
        if (Number.isFinite(q) && Number.isFinite(intensity) && q > 0 && intensity > 0) {
            points++
            qMin = Math.min(qMin, q)
            qMax = Math.max(qMax, q)
        }
    }
    if (rows === 0) throw new DataFileError("no row of numbers")
    if (points === 0) throw new DataFileError("no usable point")
    return { points, qMin, qMax }
}

/**
 * [[parseReference]] of a file.
 *
 * @throws [[DataFileError]] as [[parseReference]], or `too large` / `cannot be read`.
 */
export function readReferenceFile(path: string): {
    points: number
    qMin: number
    qMax: number
} {
    let text: string
    try {
        if (statSync(path).size > MAX_REFERENCE_BYTES) throw new DataFileError("too large")
        text = readFileSync(path, "utf-8")
    } catch (error) {
        if (error instanceof DataFileError) throw error
        throw new DataFileError("cannot be read")
    }
    return parseReference(text)
}

/** The stem of a file name: without its last extension. */
const stemOf = (file: string): string => file.slice(0, file.length - extname(file).length)

/** @returns whether a file name has one of Julia's reference extensions (any case). */
const isReferenceFile = (file: string): boolean =>
    REFERENCE_EXTENSIONS.includes(extname(file).toLowerCase())

/**
 * The names of the reference files of a project that Julia would try to read (a reference
 * extension in any case): the entries of `reference-fit.7z`, else the files of the old
 * `reference-fit/` folder; in name order without regard to case.
 */
export const referenceFiles = (projectDir: string): string[] =>
    packNames(projectDir, REFERENCES_PACK)

/**
 * The reference files of a project that Julia would try to read, in name order (without
 * regard to case), each as a curve or as unusable with the reason. No reference files
 * means none. Nothing is changed, whatever the files are.
 */
export function listReferences(projectDir: string): ReferenceEntry[] {
    return referenceFiles(projectDir).map((file) => {
        const name = stemOf(file)
        try {
            const bytes = readPackFile(projectDir, REFERENCES_PACK, file)
            if (bytes.length > MAX_REFERENCE_BYTES) throw new DataFileError("too large")
            return { file, name, ...parseReference(bytes.toString("utf-8")) }
        } catch (error) {
            const unusable = error instanceof DataFileError ? error.message : "unusable"
            return { file, name, unusable }
        }
    })
}

/**
 * Writes the project's reference files into a run folder as `reference-fit-<file>`, the
 * names Julia reads (the run's copies; from the archive or the old folder alike).
 *
 * @param into - the run's folder.
 * @returns how many files were written.
 * @throws ArchiveError, or the system's error of a read or write that fails.
 */
export function copyReferences(projectDir: string, into: string): number {
    const files = referenceFiles(projectDir)
    for (const file of files)
        writeFileSync(
            join(into, `reference-fit-${file}`),
            readPackFile(projectDir, REFERENCES_PACK, file),
        )
    return files.length
}

/**
 * The project's ONE reference curve: the file its reference entry names (`fit`, see
 * `model-references.ts`) when the project has it and Julia can read it, else, for a folder
 * made before the single reference, the usable file changed most recently (ties by name).
 * Nothing is changed.
 *
 * @param fit - the `fit` of the project's reference entry (`""` for none).
 * @returns the curve, `undefined` when the folder holds no usable file.
 */
export function currentReference(
    projectDir: string,
    fit: string,
): ReferenceEntry | undefined {
    const usable = listReferences(projectDir).filter((e) => e.unusable === undefined)
    const named = usable.find((e) => e.file === fit)
    if (named !== undefined) return named
    // an archive keeps no time of its own for an entry (all tie, the name order stays);
    // the files of an old folder have theirs
    const dir = referencesDir(projectDir)
    const packed = isFile(packFile(projectDir, REFERENCES_PACK))
    const changed = (e: ReferenceEntry): number => {
        if (packed) return 0
        try {
            return statSync(join(dir, e.file)).mtimeMs
        } catch {
            return 0
        }
    }
    return [...usable].sort((a, b) => changed(b) - changed(a))[0]
}

/**
 * A name for a file from the name of its source: the stem with every character that is
 * not a letter, a digit, `-`, `_` or `.` turned into `_`, no leading dot, at most 60
 * cells; `reference` when nothing is left.
 */
export function safeStem(sourceName: string): string {
    const file = basename(sourceName)
    const stem = stemOf(file)
        .replace(/[^\p{L}\p{N}_.-]/gu, "_")
        .replace(/^\.+/, "")
        .slice(0, MAX_STEM)
    return stem === "" ? "reference" : stem
}

/**
 * The stem to write under: `stem`, or `stem-2`, `stem-3`, ... for the first one no file
 * of the folder has (with any reference extension, any case), so nothing is overwritten
 * and Julia's own `-2` renaming never happens.
 */
export function freeStem(stem: string, taken: readonly string[]): string {
    const used = new Set(taken.map((t) => t.toLowerCase()))
    let name = stem
    for (let k = 2; used.has(name.toLowerCase()); k++) name = `${stem}-${k}`
    return name
}

/**
 * The text of a clean reference file: `q<TAB>I` or `q<TAB>I<TAB>sigma` per line, every
 * number as `String(number)`, no header.
 */
export function referenceText(data: DataPoints): string {
    const withSigma = data.sigma.length === data.q.length
    return `${data.q
        .map((q, k) => `${q}\t${data.i[k]}${withSigma ? `\t${data.sigma[k]}` : ""}`)
        .join("\n")}\n`
}

/**
 * The units of the project's data, which a reference is in too.
 *
 * @throws [[DataFileError]] `import the data first` without usable data.
 */
export function referenceUnits(projectDir: string): Units {
    const status = readDataInfo(projectDir)
    if (status?.kind !== "ok") throw new DataFileError(IMPORT_DATA_FIRST)
    return status.info.units
}

/**
 * Adds a curve to the project's `reference-fit.7z` (made if need be, from the old
 * `reference-fit/` folder plus the curve, the folder staying) as a clean `<stem>.tsv`,
 * under the archive's lock, inside the project (a deleted project is not brought back).
 * The stem comes from `source` made safe, and a taken one gets `-2`, `-3`, ...: nothing is
 * overwritten.
 *
 * @param data - the curve; `sigma` empty for none.
 * @param source - the source's path or file name.
 * @returns the name of the new curve (its stem).
 * @throws [[DataFileError]] `import the data first`; ProjectGoneError, FileInUseError,
 *     ArchiveError (7-Zip missing or failing, the old archive is then as it was), or
 *     whatever the write throws.
 */
export function addReference(projectDir: string, data: DataPoints, source: string): string {
    return lockedIn(projectDir, packFile(projectDir, REFERENCES_PACK), () => {
        referenceUnits(projectDir)
        const taken = referenceFiles(projectDir).map(stemOf)
        const name = freeStem(safeStem(source), taken)
        packAddText(projectDir, REFERENCES_PACK, `${name}.tsv`, referenceText(data))
        return name
    })
}

/**
 * Deletes one reference file, by its plain file name and only if the project lists it
 * (a name with a path in it is refused), under the archive's lock: the archive is
 * rewritten without it (the files of an old folder are packed without it first, the
 * folder staying).
 *
 * @returns whether the file was deleted: `false` when it was not there (another copy
 *     deleted it first) or the archive could not be rewritten.
 * @throws ProjectGoneError, FileInUseError.
 */
export function deleteReference(projectDir: string, file: string): boolean {
    return lockedIn(projectDir, packFile(projectDir, REFERENCES_PACK), () => {
        if (file !== basename(file) || !isReferenceFile(file)) return false
        try {
            return packRemove(projectDir, REFERENCES_PACK, file)
        } catch {
            return false
        }
    })
}

/** Holds the lock of the references archive for the last step of a background write. */
const referencesLock =
    (projectDir: string): Locked =>
    (step) =>
        lockedIn(projectDir, packFile(projectDir, REFERENCES_PACK), step)

/**
 * [[addReference]] without blocking the screen: the stem is chosen when the write's turn
 * comes (after the writes of this process queued before it), the archive is built in the
 * background and its lock is held only for the final rename.
 *
 * @returns the name of the new curve (its stem).
 * @throws as [[addReference]], and ArchiveError when another copy changed the archive
 *     meanwhile (nothing was changed).
 */
export async function addReferenceAsync(
    projectDir: string,
    data: DataPoints,
    source: string,
): Promise<string> {
    referenceUnits(projectDir)
    let name = ""
    await packChangeAsync(
        projectDir,
        REFERENCES_PACK,
        (state) => {
            name = freeStem(safeStem(source), state.names.map(stemOf))
            return { texts: new Map([[`${name}.tsv`, referenceText(data)]]) }
        },
        referencesLock(projectDir),
    )
    return name
}

/**
 * [[deleteReference]] without blocking the screen.
 *
 * @returns whether the file was deleted: `false` when it was not there or the archive
 *     could not be rewritten.
 * @throws never.
 */
export async function deleteReferenceAsync(
    projectDir: string,
    file: string,
): Promise<boolean> {
    if (file !== basename(file) || !isReferenceFile(file)) return false
    try {
        return await packChangeAsync(
            projectDir,
            REFERENCES_PACK,
            (state) => (state.names.includes(file) ? { drop: [file] } : undefined),
            referencesLock(projectDir),
        )
    } catch {
        return false
    }
}
