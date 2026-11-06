// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync, statSync } from "node:fs"
import { basename, join } from "node:path"
import * as XLSX from "xlsx"
import {
    isDict,
    isFile,
    parseJson,
    quarantine,
    saveErrorNote,
    sleepSync,
    UnusableFileError,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/files.js"
import { numberText, truncate } from "../core/text.js"
import { inProject } from "./projects.js"

/**
 * The measured curve of a project: the `data` screen turns any delimited text file or
 * `.xlsx` workbook into a CLEAN `data.tsv` in the project (exactly three tab-separated
 * columns q, I, sigma, one measurement per row, no header, no comments, no unit text;
 * the original file is never touched) and writes what the numbers mean into
 * `data.json` (units of q, X-ray energy in eV, the source's file name, the point
 * count). The units are not in the TSV so changing them later edits `data.json` only.
 *
 * Reading goes through SheetJS (one reader for the rows of a text file and of a
 * workbook; it sniffs the separator of a text file by itself). This layer adds what
 * SheetJS does not: `#` comment lines are blanked BEFORE SheetJS sees the text, a
 * single-column result (a `.dat` with aligned columns) is split on runs of whitespace,
 * an optional header row is skipped, the first three columns are taken and validated.
 * Every message is short enough for the line under a field.
 */

/** The kind of file of the errors, for [[UnusableFileError]]. */
const DATA_KIND = "data"

/** The clean table of a project, one measurement per row. */
const dataTsvName = "data.tsv"

/** What the numbers mean: units, energy, source, point count. */
const dataJsonName = "data.json"

/** The fewest points a curve may have. */
const MIN_POINTS = 10

/** The biggest file read, in bytes (it is read whole). */
const MAX_DATA_BYTES = 20 * 1024 * 1024

/** The units of q a data file may be in. */
export type Units = "nm-1" | "A-1"

/** Every unit of q, in the order of the `units` tabs. */
export const unitsList: readonly Units[] = ["nm-1", "A-1"]

/**
 * How a unit is written for the user: `nm⁻¹` and `Å⁻¹` (a superscript minus and a
 * superscript one; the Å is the precomposed letter U+00C5).
 *
 * @param units - the unit.
 * @returns the label.
 */
export function unitLabel(units: Units): string {
    return units === "nm-1" ? "nm⁻¹" : "Å⁻¹"
}

/**
 * The error of a file whose content is not a usable curve. The message is short and
 * is shown as it is.
 */
export class DataFileError extends Error {
    constructor(message: string) {
        super(message)
        this.name = "DataFileError"
    }
}

/**
 * The curve: three columns of equal length.
 *
 * @property q - the scattering vector, strictly increasing and above 0.
 * @property i - the intensity.
 * @property sigma - its uncertainty, above 0.
 */
export type DataPoints = { q: number[]; i: number[]; sigma: number[] }

/** One row of a file with the number of the line (or sheet row) it came from. */
type RawRow = { line: number; cells: unknown[] }

/** @returns `true` for a cell with nothing in it. */
const blank = (cell: unknown): boolean =>
    cell === null || cell === undefined || (typeof cell === "string" && cell.trim() === "")

/**
 * The number in a cell: a number as it is, a text as a decimal.
 *
 * @param cell - the cell.
 * @returns the finite number, or `undefined`.
 */
function cellNumber(cell: unknown): number | undefined {
    if (typeof cell === "number") return Number.isFinite(cell) ? cell : undefined
    if (typeof cell === "string") return numberText(cell.trim())
    return undefined
}

/** @returns the text of a cell cut short for a message. */
const shown = (cell: unknown): string => truncate(String(cell ?? "").trim(), 12)

/**
 * Checks the rows and takes their first three columns.
 *
 * Blank rows and rows whose first cell starts with `#` are skipped; the first other
 * row is a header when its first three cells are not all numbers. Then every row must
 * have three numbers, q above 0 and increasing, sigma above 0, and there must be at
 * least [[MIN_POINTS]] of them.
 *
 * @param rows - the rows.
 * @returns the curve.
 * @throws [[DataFileError]] naming the row that is wrong.
 */
function rowsToData(rows: RawRow[]): DataPoints {
    const data: DataPoints = { q: [], i: [], sigma: [] }
    let first = true
    for (const { line, cells } of rows) {
        if (cells.every(blank)) continue
        const lead = cells[0]
        if (typeof lead === "string" && lead.trim().startsWith("#")) continue
        const three = cells.slice(0, 3)
        const numeric = three.every((c) => cellNumber(c) !== undefined)
        const isFirst = first
        first = false
        // a first row that is not numbers is a header (a row of 2 numbers is data)
        if (isFirst && !numeric) continue
        if (three.length < 3) throw new DataFileError(`row ${line}: need 3 columns`)
        const [q, i, sigma] = three.map(cellNumber)
        for (const [k, v] of [q, i, sigma].entries()) {
            if (v === undefined)
                throw new DataFileError(`row ${line}: "${shown(three[k])}" is no number`)
        }
        if ((q as number) <= 0) throw new DataFileError(`row ${line}: q must be above 0`)
        if ((sigma as number) <= 0)
            throw new DataFileError(`row ${line}: sigma must be above 0`)
        const before = data.q[data.q.length - 1]
        if (before !== undefined && (q as number) <= before)
            throw new DataFileError(`row ${line}: q must increase`)
        data.q.push(q as number)
        data.i.push(i as number)
        data.sigma.push(sigma as number)
    }
    if (data.q.length < MIN_POINTS)
        throw new DataFileError(`only ${data.q.length} points: need ${MIN_POINTS}`)
    return data
}

/**
 * The rows of a SheetJS workbook's first sheet, each with its sheet row number.
 *
 * @param workbook - the workbook.
 * @returns the rows, blank ones included (so numbers stay true).
 * @throws [[DataFileError]] for a workbook without a sheet.
 */
function sheetRows(workbook: XLSX.WorkBook): RawRow[] {
    const sheet = workbook.Sheets[workbook.SheetNames[0] ?? ""]
    if (sheet === undefined || sheet["!ref"] === undefined)
        throw new DataFileError("the file has no data")
    const start = XLSX.utils.decode_range(sheet["!ref"]).s.r
    const rows = XLSX.utils.sheet_to_json<unknown[]>(sheet, {
        header: 1,
        raw: true,
        blankrows: true,
    })
    return rows.map((cells, k) => ({ line: start + k + 1, cells }))
}

/**
 * Runs SheetJS on bytes or text, turning its failures into a [[DataFileError]].
 *
 * @param input - the content.
 * @param type - what `input` is.
 * @returns the rows of the first sheet.
 */
function readSheetRows(input: string | Buffer, type: "string" | "buffer"): RawRow[] {
    try {
        return sheetRows(XLSX.read(input, { type, raw: true }))
    } catch (error) {
        if (error instanceof DataFileError) throw error
        throw new DataFileError("cannot read that file")
    }
}

/**
 * The text with every `#` comment line blanked (not removed, so the row numbers of the
 * messages are the file's own line numbers), a byte order mark dropped.
 *
 * @param text - the file's text.
 * @returns the text.
 */
function blankComments(text: string): string {
    return text
        .replace(/^﻿/, "")
        .split(/\r\n|\r|\n/)
        .map((line) => (line.trimStart().startsWith("#") ? "" : line))
        .join("\n")
}

/**
 * The curve in delimited text: tab, comma, semicolon or pipe (sniffed by SheetJS) or
 * runs of whitespace (split here when SheetJS finds a single column).
 *
 * @param text - the text of the file.
 * @returns the first three columns as the curve.
 * @throws [[DataFileError]] with a short message: fewer than 3 columns, a cell that is
 *     no number, q not above 0 or not increasing, sigma not above 0, fewer than 10
 *     points (the row is named).
 */
export function parseDataText(text: string): DataPoints {
    const clean = blankComments(text)
    let rows = readSheetRows(clean, "string")
    const single = rows.every(({ cells }) => cells.filter((c) => !blank(c)).length <= 1)
    if (single) {
        // aligned columns: SheetJS does not split on runs of spaces
        rows = clean.split("\n").map((line, k) => ({
            line: k + 1,
            cells: line.trim() === "" ? [] : line.trim().split(/\s+/),
        }))
    }
    return rowsToData(rows)
}

/**
 * The curve in the first sheet of an `.xlsx` workbook.
 *
 * @param path - the file.
 * @returns the first three columns as the curve.
 * @throws [[DataFileError]] as [[parseDataText]] does, or `cannot read that file`.
 */
export function parseXlsx(path: string): DataPoints {
    return rowsToData(readSheetRows(readBounded(path), "buffer"))
}

/**
 * Reads a file whole, refusing a huge one.
 *
 * @param path - the file.
 * @returns its bytes.
 * @throws [[DataFileError]] for a file over [[MAX_DATA_BYTES]] or one that cannot be read.
 */
function readBounded(path: string): Buffer {
    try {
        if (statSync(path).size > MAX_DATA_BYTES) throw new DataFileError("file too large")
        return readFileSync(path)
    } catch (error) {
        if (error instanceof DataFileError) throw error
        throw new DataFileError("cannot read that file")
    }
}

/**
 * The curve in a file of any kind: a workbook (a ZIP, recognised by its first bytes, not
 * by its name) or delimited text. The old `.xls` and other binary files are refused.
 *
 * @param path - the file.
 * @returns the curve.
 * @throws [[DataFileError]] with a short message.
 */
export function parseDataFile(path: string): DataPoints {
    const bytes = readBounded(path)
    if (bytes.subarray(0, 2).toString("latin1") === "PK")
        return rowsToData(readSheetRows(bytes, "buffer"))
    if (bytes.subarray(0, 4).toString("hex") === "d0cf11e0")
        throw new DataFileError("old .xls: save it as .xlsx")
    if (bytes.includes(0)) throw new DataFileError("not a text file")
    return parseDataText(bytes.toString("utf-8"))
}

/**
 * What `data.json` holds.
 *
 * @property units - the units of q in `data.tsv`.
 * @property energy - the X-ray energy in eV, `null` until the user gives it.
 * @property source - the name (no folder) of the file the data came from.
 * @property points - the number of rows of `data.tsv`.
 */
export type DataInfo = {
    units: Units
    energy: number | null
    source: string
    points: number
}

/** The units a freshly loaded file has when the project had none: Å⁻¹. */
export const DEFAULT_UNITS: Units = "A-1"

/**
 * The text of the clean table: `q<TAB>I<TAB>sigma` per line, every number as
 * `String(number)` (full precision), no header.
 *
 * @param data - the curve.
 * @returns the text, with a final newline.
 */
function tsvText(data: DataPoints): string {
    return `${data.q.map((q, k) => `${q}\t${data.i[k]}\t${data.sigma[k]}`).join("\n")}\n`
}

/** @returns the path of the project's `data.tsv`. */
export const dataTsvFile = (projectDir: string): string => join(projectDir, dataTsvName)

/** @returns the path of the project's `data.json`. */
export const dataJsonFile = (projectDir: string): string => join(projectDir, dataJsonName)

/** The error of a data file that cannot be used, for the screens. */
const unusableData = (what: string): UnusableFileError =>
    new UnusableFileError(`${what} is unusable`, DATA_KIND)

/**
 * `data.json` as the file holds it.
 *
 * @param file - the file; it must exist.
 * @returns the info.
 * @throws [[UnusableFileError]] when it is not JSON or not a valid info.
 */
function readInfoFile(file: string): DataInfo {
    let value: unknown
    try {
        value = parseJson(readFileSync(file, "utf-8"))
    } catch {
        throw unusableData(dataJsonName)
    }
    if (!isDict(value)) throw unusableData(dataJsonName)
    const { units, energy, source, points } = value
    const ok =
        (units === "nm-1" || units === "A-1") &&
        (energy === null || (typeof energy === "number" && energy > 0)) &&
        typeof source === "string" &&
        typeof points === "number" &&
        Number.isInteger(points) &&
        points >= MIN_POINTS
    if (!ok) throw unusableData(dataJsonName)
    return { units, energy, source, points } as DataInfo
}

/**
 * Writes the data of a project: `data.tsv` first, `data.json` LAST (so a reader that
 * finds the JSON finds the whole table), each atomically under its own lock, inside the
 * project (a deleted project is never brought back). An existing `data.json` that
 * cannot be used is never written over.
 *
 * @param projectDir - the project's folder.
 * @param data - the curve, as [[parseDataFile]] returns it.
 * @param source - the original file's name; only its last part is kept.
 * @param units - the units of q.
 * @param energy - the energy in eV, or `undefined` while it is not known.
 * @returns the info written.
 * @throws ProjectGoneError, FileInUseError, UnusableFileError (an old `data.json`),
 *     or whatever the write throws.
 */
export function writeData(
    projectDir: string,
    data: DataPoints,
    source: string,
    units: Units,
    energy?: number,
): DataInfo {
    const info: DataInfo = {
        units,
        energy: energy ?? null,
        source: basename(source),
        points: data.q.length,
    }
    const tsv = dataTsvFile(projectDir)
    const json = dataJsonFile(projectDir)
    const options = { createParents: false }
    return inProject(projectDir, () =>
        withFileLock(
            tsv,
            () =>
                withFileLock(
                    json,
                    () => {
                        if (isFile(json)) readInfoFile(json) // never over an unusable one
                        writeAtomic(tsv, tsvText(data), options)
                        writeAtomic(json, writeJson(info), options)
                        return info
                    },
                    options,
                ),
            options,
        ),
    )
}

/**
 * What [[readDataInfo]] found when there is data.
 *
 * @property kind - `"ok"`: both files are valid; `"unusable"`: a file is there but is
 *     not valid (never overwritten; see [[resetData]]).
 * @property info - the info (`ok`).
 * @property qMin - the smallest q of the table (`ok`).
 * @property qMax - the biggest q of the table (`ok`).
 * @property message - what is wrong (`unusable`).
 */
export type DataStatus =
    | { kind: "ok"; info: DataInfo; qMin: number; qMax: number }
    | { kind: "unusable"; message: string }

/**
 * One look at the data files.
 *
 * @param projectDir - the project's folder.
 * @returns what is there, or `undefined` when there is no data at all.
 */
function lookAtData(projectDir: string): DataStatus | undefined {
    const tsv = dataTsvFile(projectDir)
    const json = dataJsonFile(projectDir)
    const haveTsv = isFile(tsv)
    const haveJson = isFile(json)
    if (!haveTsv && !haveJson) return undefined
    try {
        if (!haveJson) throw unusableData(dataJsonName)
        const info = readInfoFile(json)
        if (!haveTsv) throw unusableData(dataTsvName)
        let table: DataPoints
        try {
            table = parseDataText(readFileSync(tsv, "utf-8"))
        } catch {
            throw unusableData(dataTsvName)
        }
        if (table.q.length !== info.points) throw unusableData(dataTsvName)
        return {
            kind: "ok",
            info,
            qMin: table.q[0] as number,
            qMax: table.q[table.q.length - 1] as number,
        }
    } catch (error) {
        if (error instanceof UnusableFileError)
            return { kind: "unusable", message: error.message }
        return { kind: "unusable", message: "data files cannot be read" }
    }
}

/**
 * The data of a project and a short summary of it. Nothing is written. A table and an
 * info that disagree may be a load in progress in another copy, so the look is repeated
 * once after a moment before it is called unusable.
 *
 * @param projectDir - the project's folder.
 * @returns `undefined` when there is no `data.tsv` and no `data.json`; the data
 *     (`kind: "ok"`: info, q range); or `kind: "unusable"` with the message.
 */
export function readDataInfo(projectDir: string): DataStatus | undefined {
    const first = lookAtData(projectDir)
    if (first?.kind !== "unusable") return first
    sleepSync(60)
    return lookAtData(projectDir)
}

/**
 * Whether the data of a project is complete for a run: valid files and an energy.
 *
 * @param projectDir - the project's folder.
 * @returns the answer; `false` for anything that cannot be read.
 */
export function dataIsReady(projectDir: string): boolean {
    const status = readDataInfo(projectDir)
    return status?.kind === "ok" && status.info.energy !== null
}

/**
 * Changes a field of `data.json` (and nothing else: never the table), under its lock,
 * inside the project.
 *
 * @param projectDir - the project's folder.
 * @param change - the new info from the old.
 * @returns the info written.
 * @throws [[DataFileError]] `no data yet`; UnusableFileError; ProjectGoneError;
 *     FileInUseError.
 */
function editInfo(projectDir: string, change: (old: DataInfo) => DataInfo): DataInfo {
    const json = dataJsonFile(projectDir)
    const options = { createParents: false }
    return inProject(projectDir, () =>
        withFileLock(
            json,
            () => {
                if (!isFile(json)) throw new DataFileError("no data yet")
                const info = change(readInfoFile(json))
                writeAtomic(json, writeJson(info), options)
                return info
            },
            options,
        ),
    )
}

/**
 * Sets the units of q. Only `data.json` is written.
 *
 * @param projectDir - the project's folder.
 * @param units - the units.
 * @returns the info written.
 * @throws as the edit of `data.json` does: no data yet, unusable, project gone.
 */
export function setUnits(projectDir: string, units: Units): DataInfo {
    return editInfo(projectDir, (old) => ({ ...old, units }))
}

/** What [[setEnergy]] says of an energy that is not above 0. */
export const ENERGY_PROBLEM = "above 0, please"

/**
 * Sets the X-ray energy. Only `data.json` is written.
 *
 * @param projectDir - the project's folder.
 * @param energy - the energy in eV, above 0.
 * @returns the info written.
 * @throws [[DataFileError]] for an energy that is not above 0 (and finite); otherwise
 *     as [[setUnits]].
 */
export function setEnergy(projectDir: string, energy: number): DataInfo {
    if (!Number.isFinite(energy) || energy <= 0) throw new DataFileError(ENERGY_PROBLEM)
    return editInfo(projectDir, (old) => ({ ...old, energy }))
}

/**
 * Puts unusable data files aside as `<name>.corrupt`, the explicit reset: after it the
 * project has no data and a file can be loaded again.
 *
 * @param projectDir - the project's folder.
 * @throws ProjectGoneError, FileInUseError, or if a file cannot be renamed.
 */
export function resetData(projectDir: string): void {
    const options = { createParents: false }
    inProject(projectDir, () => {
        for (const file of [dataJsonFile(projectDir), dataTsvFile(projectDir)])
            withFileLock(file, () => quarantine(file), options)
    })
}

/**
 * The words for a failure of one of the functions above, for the line of a screen.
 *
 * @param error - what was thrown.
 * @returns the message of a data or unusable-file error, else the words of
 *     `saveErrorNote` (another copy changed things, the project is gone, ...).
 */
export function dataErrorNote(error: unknown): string {
    if (error instanceof DataFileError || error instanceof UnusableFileError)
        return error.message
    return saveErrorNote(error)
}
