// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import { isDict, type ReadOptions } from "../core/files.js"
import { ListFile } from "./list-file.js"
import { inProject } from "./projects.js"

/**
 * The buffer of a project: `buffer.json` in the project's folder, a JSON object whose
 * `solutes` is an array of the solutes of the buffer, one object each:
 *
 *     {"kind": "nonbiological", "name": "NaCl", "arg": "NaCl", "mM": 200, "sigma-mM": 10}
 *
 * `name` is what the user calls it, `arg` what BAYSOL is given (the solute's name for a
 * non-biological one), `mM` the concentration and `sigma-mM` its standard uncertainty,
 * both in millimolar as they were typed (BAYSOL takes molar; that is for the run). The
 * keys keep their file spelling (`"sigma-mM"`), so a row is what the file holds. Other
 * keys of the file's map are kept as they are when the solutes are written, so what the
 * buffer gets later (pH, temperature) does not need a new file. A missing or empty file
 * is a buffer with no solutes; a file that is not a JSON object (or whose `solutes` is
 * not an array of objects, or has a row that [[rowProblem]] refuses, or has more than
 * [[MAX_ROWS]]) is unusable, and is never written over.
 *
 * The kinds of row are the ones of `test/fixtures/buffer/buffer.json`, the file the Julia
 * loader (`BAYSOL.Pipeline.load_buffer`, `src/Pipeline/Buffer.jl`) is tested against
 * too. [[rowProblem]] checks the same keys and types as the loader, so a row the screen
 * writes is one the loader reads.
 */

/** The most units a custom polymer row has (the loader's `CUSTOM_POLYMER_MAX_UNITS`). */
const maxUnits = 4

/** The name of the file in a project's folder. */
export const bufferFileName = "buffer.json"

/** The kinds a row may have. */
export const kinds = [
    "nonbiological",
    "polymer",
    "dna",
    "rna",
    "protein",
    "custom-nonbio",
    "custom-polymer",
] as const

/**
 * What every row has.
 *
 * @property name - the label the user gave it (the loader does not check it).
 * @property mM - the concentration, above 0.
 * @property sigma-mM - its standard uncertainty, 0 or more; required.
 */
export type RowBase = {
    name: string
    mM: number
    "sigma-mM": number
}

/** A row whose `arg` is a name BAYSOL looks up: a table name or a grade or family. */
type NamedRow = RowBase & {
    kind: "nonbiological" | "polymer"
    arg: string
}

/**
 * A row of a sequence: `arg` is the clean sequence; `source` (a file name, no folder)
 * and `record` (the record's id) are provenance only.
 */
type SequenceRow = RowBase & {
    kind: "dna" | "rna" | "protein"
    arg: string
    source?: string
    record?: string
}

/**
 * A row of a custom non-biological solute: a snapshot of the custom entry.
 *
 * @property custom - the entry's name.
 * @property z - its electrons.
 * @property pmv - its partial molar volume.
 * @property sigma-pmv - its uncertainty, `null` for the fallback.
 */
export type CustomNonbioRow = RowBase & {
    kind: "custom-nonbio"
    custom: string
    z: number
    pmv: number
    "sigma-pmv": number | null
}

/**
 * One kind of repeat unit of a custom polymer.
 *
 * @property label - the name the user chose (not checked by the loader).
 * @property formula - its formula (not checked by the loader).
 * @property z - electrons per unit.
 * @property slope - its volume per unit.
 * @property sigma - its absolute uncertainty, `null` for none.
 */
type CustomUnit = {
    label?: string
    formula?: string
    z: number
    slope: number
    sigma: number | null
}

/**
 * A row of a custom polymer: a snapshot of the custom entry and the counts of the row.
 *
 * @property counts - the number of each unit, in order of `units`.
 * @property z-ends - the electrons of the end groups.
 * @property pmv-ends - their volume.
 * @property sigma-ends - its uncertainty, `null` for none.
 */
export type CustomPolymerRow = RowBase & {
    kind: "custom-polymer"
    custom: string
    units: CustomUnit[]
    counts: number[]
    "z-ends": number
    "pmv-ends": number
    "sigma-ends": number | null
}

/** A row of the buffer: one of the seven kinds, told apart by `kind`. */
export type BufferRow = NamedRow | SequenceRow | CustomNonbioRow | CustomPolymerRow

/**
 * The buffer file of a project.
 *
 * @param projectDir - the project's folder.
 * @returns `<project>/buffer.json`.
 */
export function bufferFile(projectDir: string): string {
    return join(projectDir, bufferFileName)
}

// --- what a row must have (the loader's rules)

type Dict = Record<string, unknown>

/**
 * Whether a value is a number (not `NaN`; a boolean is none). The one test of "is a
 * number" that the loader's rules ([[rowProblem]]) and the custom entries share.
 *
 * @param x - any value.
 * @returns the answer.
 */
export function isNumber(x: unknown): x is number {
    return typeof x === "number" && !Number.isNaN(x)
}

/** Whether a value is a whole number (a boolean is none). */
function isInt(x: unknown): boolean {
    return Number.isInteger(x)
}

/** Whether a value is a string with something in it besides white space. */
function isName(x: unknown): x is string {
    return typeof x === "string" && x.trim() !== ""
}

/** Whether a map has a key that holds a number or `null`: the key must be there. */
function isOptNum(m: Dict, key: string): boolean {
    return key in m && (m[key] === null || isNumber(m[key]))
}

/**
 * What is wrong with one unit of a custom polymer.
 *
 * @param u - the unit.
 * @returns the message, or `undefined`.
 */
function unitProblem(u: unknown): string | undefined {
    if (!isDict(u)) return "a unit is not a map"
    if (!isInt(u.z)) return "unit z must be an integer"
    if (!isNumber(u.slope)) return "unit slope must be a number"
    if (!isOptNum(u, "sigma")) return "unit sigma must be a number or null"
    return undefined
}

/**
 * What is wrong with the keys of a custom row.
 *
 * @param row - a row whose `kind` is `custom-nonbio` or `custom-polymer`.
 * @returns the message, or `undefined`.
 */
function customProblem(row: Dict): string | undefined {
    if (row.kind === "custom-nonbio") {
        if (!isName(row.custom)) return "custom must be a name"
        if (!isInt(row.z)) return "z must be an integer"
        if (!isNumber(row.pmv)) return "pmv must be a number"
        if (!isOptNum(row, "sigma-pmv")) return "sigma-pmv must be a number or null"
        return undefined
    }
    const { units, counts } = row
    if (!isName(row.custom)) return "custom must be a name"
    if (!Array.isArray(units) || units.length < 1 || units.length > maxUnits)
        return "units needs 1 to 4"
    for (const u of units) {
        const problem = unitProblem(u)
        if (problem !== undefined) return problem
    }
    if (!Array.isArray(counts) || !counts.every(isNumber)) return "counts must be numbers"
    if (counts.length !== units.length) return "counts needs one per unit"
    if (!isInt(row["z-ends"])) return "z-ends must be an integer"
    if (!isNumber(row["pmv-ends"])) return "pmv-ends must be a number"
    if (!isOptNum(row, "sigma-ends")) return "sigma-ends must be a number or null"
    return undefined
}

/**
 * What is wrong with a buffer row for the Julia loader: a map of a known `kind` with an
 * `mM` above 0 and a `sigma-mM` of 0 or more (numbers), and the keys its kind needs
 * (see the top of this file). The name of a row is only a label and is not checked.
 *
 * @param row - the row, as read from a file or built by a screen.
 * @returns a short text, or `undefined` when the row is fine.
 */
export function rowProblem(row: unknown): string | undefined {
    if (!isDict(row)) return "a row is not a map"
    if (!(kinds as readonly unknown[]).includes(row.kind)) return "unknown kind"
    if (!(isNumber(row.mM) && Number(row.mM) > 0)) return "mM must be above 0"
    if (!(isNumber(row["sigma-mM"]) && Number(row["sigma-mM"]) >= 0))
        return "sigma-mM must be 0 or more"
    if (row.kind === "custom-nonbio" || row.kind === "custom-polymer")
        return customProblem(row)
    if (!isName(row.arg)) return "arg must be a name"
    return undefined
}

// --- the file

/**
 * The list file of the buffer: the mechanics (tracked read, locked write, unusable files,
 * the cap, the other keys kept) are [[ListFile]]'s. A project's folder that is gone is
 * not made again.
 */
const list = new ListFile<BufferRow>({
    fileName: bufferFileName,
    key: "solutes",
    kind: "buffer",
    plural: "solutes",
    noun: "buffer row",
    problem: rowProblem,
    createParents: false,
})

/**
 * The solutes of the buffer of a project.
 *
 * @param projectDir - the project's folder.
 * @param options - `track: true` when the rows are read to be edited and saved: the
 *     version read is then the one [[writeSolutes]] checks against, so a save after
 *     another copy saved the file is refused. A plain read changes nothing about that.
 * @returns the rows (empty for none).
 * @throws UnusableFileError if the file cannot be used.
 */
export function readSolutes(projectDir: string, options: ReadOptions = {}): BufferRow[] {
    return list.read(projectDir, options)
}

/**
 * Writes the solutes of the buffer of a project, the other keys of the file kept,
 * through a temporary file that replaces it in one step. The file is made if there is
 * none; one that cannot be used is not touched.
 *
 * @param projectDir - the project's folder.
 * @param solutes - the rows, at most [[MAX_ROWS]].
 * @returns the file.
 * @throws ChangedOnDiskError if another copy of the program saved the file after this
 *     one read it (nothing is written); UnusableFileError (`not a valid buffer row: ...`,
 *     `too many solutes ...`, nothing written) for a row that [[rowProblem]] refuses or
 *     more than [[MAX_ROWS]] rows, or a file that cannot be used; ProjectGoneError when
 *     the project's folder is gone.
 */
export function writeSolutes(projectDir: string, solutes: readonly BufferRow[]): string {
    return inProject(projectDir, () => list.write(projectDir, solutes))
}

/**
 * Starts the buffer over after the file was found unusable: the file is renamed to
 * `buffer.json.corrupt` (replacing an older one), so nothing is lost and a new buffer
 * can be written.
 *
 * @param projectDir - the project's folder.
 * @returns the path of the kept file, or `undefined` if there was no file.
 * @throws if it cannot be renamed.
 */
export function resetBuffer(projectDir: string): string | undefined {
    return list.reset(projectDir)
}
