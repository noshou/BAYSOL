// SPDX-License-Identifier: LGPL-3.0-or-later

// Data: the data files of a project (`data.tsv`, `data.json`). Reading a table into a
// curve is in `data-table.ts`.

import { readFileSync } from "node:fs"
import { basename, join } from "node:path"
import {
    isDict,
    isFile,
    parseJson,
    quarantine,
    saveErrorNote,
    sleepSync,
    UnusableFileError,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import {
    type ColumnChoice,
    DataFileError,
    type DataPoints,
    DEFAULT_PARSE_OPTIONS,
    extractCurve,
    type HeaderMode,
    headerModes,
    MIN_POINTS,
    type ParseOptions,
    parseTable,
    type Role,
    roles,
    textSource,
} from "./data-table.js"
import { lockedIn } from "./projects.js"

// ========================================================================================
// 2. Project data files
// ========================================================================================

/**
 * The measured curve of a project: the `data` screen turns any delimited text file or
 * `.xlsx` workbook into a CLEAN `data.tsv` in the project (exactly three tab-separated
 * columns q, I, sigma, one measurement per row, no header, no comments, no unit text;
 * the original file is never touched) and writes what the numbers mean into
 * `data.json` (units of q, X-ray energy and its unit, the source's file name, the point
 * count). The units are not in the TSV so changing them later edits `data.json` only.
 *
 * `data.json` also REMEMBERS where the curve came from (the source path, the parse
 * options and the three chosen columns, see [[DataMapping]]), so the `data` screen can
 * show it and re-open the import with the same choices. Julia reads only `data.tsv`,
 * `units` and `energy`. Reading a file into rows, the columns and the checks of the
 * curve live in the first part of this file; the rest of it stores the result.
 */

/** The kind of file of the errors, for [[UnusableFileError]]. */
const DATA_KIND = "data"

/** The clean table of a project, one measurement per row. */
const dataTsvName = "data.tsv"

/** What the numbers mean: units, energy, source, point count. */
const dataJsonName = "data.json"

/** The units of q a data file may be in. */
export type Units = "nm-1" | "A-1"

/** Every unit of q, in the order of the `units` tabs. */
export const unitsList: readonly Units[] = ["nm-1", "A-1"]

/**
 * How a unit is written for the user: `nm⁻¹` and `Å⁻¹` (a superscript minus and a
 * superscript one; the Å is the precomposed letter U+00C5).
 */
export function unitLabel(units: Units): string {
    return units === "nm-1" ? "nm⁻¹" : "Å⁻¹"
}

/**
 * The unit the X-ray energy is read in: only a LABEL, like the units of q (the number is
 * kept as typed, changing the unit never converts it; Julia converts to eV at run time).
 */
export type EnergyUnit = "eV" | "keV" | "nm" | "A"

/** Every energy unit, in the order `^k` turns them. */
export const energyUnitsList: readonly EnergyUnit[] = ["nm", "A", "eV", "keV"]

/**
 * The unit a NEW energy is entered in (a wavelength in nm is the most common). A
 * `data.json` without the field is older and holds eV: readers default to eV, not this.
 */
export const DEFAULT_ENERGY_UNIT: EnergyUnit = "nm"

/** How an energy unit is written for the user (`Å` is the precomposed U+00C5). */
export const energyUnitLabel = (unit: EnergyUnit): string => (unit === "A" ? "Å" : unit)

/** @returns the next unit of the cycle nm, Å, eV, keV, nm. */
export function nextEnergyUnit(unit: EnergyUnit): EnergyUnit {
    const at = energyUnitsList.indexOf(unit)
    return energyUnitsList[(at + 1) % energyUnitsList.length] as EnergyUnit
}

/**
 * The curve in delimited text, the first three columns (the clean `data.tsv`, and any
 * table whose first three columns are q, I, sigma): the separator is sniffed, comment
 * lines and a header are dropped.
 *
 * @throws [[DataFileError]] with a short message that names the line: fewer than 3
 *     columns, a cell that is no number, q not increasing, sigma not above 0, fewer than
 *     [[MIN_POINTS]] points.
 */
export function parseDataText(text: string): DataPoints {
    const table = parseTable(textSource(text), DEFAULT_PARSE_OPTIONS)
    if (table.rows.length > 0 && table.names.length < 3)
        throw new DataFileError("need 3 columns")
    return extractCurve(table, { q: 1, i: 2, sigma: 3 })
}

/**
 * Where a curve came from and how it was read, kept in `data.json`.
 *
 * @property path - the source file (absolute, as the user gave it).
 * @property separator - the separator as the user gave it (`auto`, a name, or characters).
 * @property sheet - the sheet of a workbook (`""`: the first).
 * @property skipRows - the rows skipped at the top.
 * @property comments - whether comment lines were dropped.
 * @property header - the header choice.
 * @property columns - the columns chosen for q, I and sigma, as typed and as the number
 *     they were resolved to (counting from 1).
 */
export type DataMapping = ParseOptions & {
    path: string
    columns: Record<Role, ColumnChoice>
}

/** The mapping of a source, from the options and choices of the import screen. */
export const makeMapping = (
    path: string,
    options: ParseOptions,
    columns: Record<Role, ColumnChoice>,
): DataMapping => ({ path, ...options, columns })

/**
 * Reads the mapping of `data.json` leniently: a mapping is a convenience, so one that is
 * missing or malformed is simply absent and never makes the data unusable.
 */
export function readMapping(value: unknown): DataMapping | undefined {
    if (!isDict(value) || !isDict(value.columns)) return undefined
    const { path, separator, sheet, skipRows, comments, header } = value
    const ok =
        typeof path === "string" &&
        typeof separator === "string" &&
        separator !== "" &&
        typeof skipRows === "number" &&
        Number.isInteger(skipRows) &&
        skipRows >= 0 &&
        typeof comments === "boolean" &&
        typeof sheet === "string" &&
        headerModes.includes(header as HeaderMode)
    if (!ok) return undefined
    const columns = {} as Record<Role, ColumnChoice>
    for (const role of roles) {
        const c = value.columns[role]
        if (!isDict(c) || typeof c.spec !== "string") return undefined
        if (typeof c.column !== "number" || !Number.isInteger(c.column) || c.column < 1)
            return undefined
        columns[role] = { spec: c.spec, column: c.column }
    }
    return { ...(value as unknown as ParseOptions), sheet, path, columns }
}

/**
 * What `data.json` holds.
 *
 * @property units - the units of q in `data.tsv`.
 * @property energy - the X-ray energy as typed, in `energyUnit`; `null` until given.
 * @property source - the name (no folder) of the file the data came from.
 * @property points - the number of rows of `data.tsv`.
 * @property mapping - where the curve came from and how it was read; absent when the
 *     data was not imported from a file.
 * @property energyUnit - the unit of `energy` (a label, never converted here).
 */
export type DataInfo = {
    units: Units
    energy: number | null
    source: string
    points: number
    mapping?: DataMapping
    energyUnit: EnergyUnit
}

/** The units a freshly loaded file has when the project had none: Å⁻¹. */
export const DEFAULT_UNITS: Units = "A-1"

/**
 * The text of the clean table: `q<TAB>I<TAB>sigma` per line, every number as
 * `String(number)` (full precision), no header.
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
    const { units, energy, source, points, energyUnit } = value
    const ok =
        (units === "nm-1" || units === "A-1") &&
        (energy === null || (typeof energy === "number" && energy > 0)) &&
        typeof source === "string" &&
        typeof points === "number" &&
        Number.isInteger(points) &&
        points >= MIN_POINTS &&
        energyUnitsList.includes(energyUnit as EnergyUnit)
    if (!ok) throw unusableData(dataJsonName)
    const info = { units, energy, source, points, energyUnit } as DataInfo
    const mapping = readMapping(value.mapping)
    if (mapping !== undefined) info.mapping = mapping
    return info
}

/**
 * Writes the data of a project: `data.tsv` first, `data.json` LAST (so a reader that
 * finds the JSON finds the whole table), each atomically under its own lock, inside the
 * project (a deleted project is never brought back). An existing `data.json` that
 * cannot be used is never written over.
 *
 * @param energy - the energy as typed (in `energyUnit`), or `undefined` while unknown.
 * @param mapping - where the curve came from, to remember (see [[DataMapping]]).
 * @param energyUnit - the unit the energy is shown in.
 * @throws ProjectGoneError, FileInUseError, UnusableFileError (a `data.json` that
 *     cannot be read), or whatever the write throws.
 */
export function writeData(
    projectDir: string,
    data: DataPoints,
    source: string,
    units: Units,
    energy?: number,
    mapping?: DataMapping,
    energyUnit: EnergyUnit = DEFAULT_ENERGY_UNIT,
): DataInfo {
    const info: DataInfo = {
        units,
        energy: energy ?? null,
        source: basename(source),
        points: data.q.length,
        ...(mapping === undefined ? {} : { mapping }),
        energyUnit: energyUnit,
    }
    const tsv = dataTsvFile(projectDir)
    const json = dataJsonFile(projectDir)
    const options = { createParents: false }
    return lockedIn(projectDir, [tsv, json], () => {
        if (isFile(json)) readInfoFile(json) // never over an unusable one
        writeAtomic(tsv, tsvText(data), options)
        writeAtomic(json, writeJson(info), options)
        return info
    })
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

/** One look at the data files. */
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
 * @returns `undefined` when there is no `data.tsv` and no `data.json`; the data
 *     (`kind: "ok"`: info, q range); or `kind: "unusable"` with the message.
 */
export function readDataInfo(projectDir: string): DataStatus | undefined {
    const first = lookAtData(projectDir)
    if (first?.kind !== "unusable") return first
    sleepSync(60)
    return lookAtData(projectDir)
}

/** Whether the data of a project is complete for a run: valid files and an energy. */
export function dataIsReady(projectDir: string): boolean {
    const status = readDataInfo(projectDir)
    return status?.kind === "ok" && status.info.energy !== null
}

/**
 * Changes a field of `data.json` (and nothing else: never the table), under its lock,
 * inside the project.
 *
 * @throws [[DataFileError]] `no data yet`; UnusableFileError; ProjectGoneError;
 *     FileInUseError.
 */
function editInfo(projectDir: string, change: (old: DataInfo) => DataInfo): DataInfo {
    const json = dataJsonFile(projectDir)
    return lockedIn(projectDir, json, () => {
        if (!isFile(json)) throw new DataFileError("no data yet")
        const info = change(readInfoFile(json))
        writeAtomic(json, writeJson(info), { createParents: false })
        return info
    })
}

/**
 * Sets the units of q. Only `data.json` is written.
 *
 * @throws as the edit of `data.json` does: no data yet, unusable, project gone.
 */
export function setUnits(projectDir: string, units: Units): DataInfo {
    return editInfo(projectDir, (old) => ({ ...old, units }))
}

/**
 * Sets the unit the energy is shown in (always written). Only `data.json` is
 * written.
 *
 * @throws as [[setUnits]].
 */
export function setEnergyUnit(projectDir: string, unit: EnergyUnit): DataInfo {
    return editInfo(projectDir, (old) => ({ ...old, energyUnit: unit }))
}

/** What [[setEnergy]] says of an energy that is not above 0. */
export const ENERGY_PROBLEM = "above 0, please"

/**
 * Sets the X-ray energy as typed, and its unit. Only `data.json` is written.
 *
 * @throws [[DataFileError]] for an energy that is not above 0 (and finite); otherwise
 *     as [[setUnits]].
 */
export function setEnergy(
    projectDir: string,
    energy: number,
    unit: EnergyUnit,
): DataInfo {
    if (!Number.isFinite(energy) || energy <= 0) throw new DataFileError(ENERGY_PROBLEM)
    return editInfo(projectDir, (old) => ({ ...old, energy, energyUnit: unit }))
}

/**
 * Puts unusable data files aside as `<name>.corrupt`, the explicit reset: after it the
 * project has no data and a file can be loaded again.
 *
 * @throws ProjectGoneError, FileInUseError, or if a file cannot be renamed.
 */
export function resetData(projectDir: string): void {
    for (const file of [dataJsonFile(projectDir), dataTsvFile(projectDir)])
        lockedIn(projectDir, file, () => quarantine(file))
}

/**
 * The words for a failure of one of the functions above, for the line of a screen.
 *
 * @returns the message of a data or unusable-file error, else the words of
 *     `saveErrorNote` (another copy changed things, the project is gone, ...).
 */
export function dataErrorNote(error: unknown): string {
    if (error instanceof DataFileError || error instanceof UnusableFileError)
        return error.message
    return saveErrorNote(error)
}
