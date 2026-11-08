// SPDX-License-Identifier: LGPL-3.0-or-later

// Data: reading a table into a curve, and the data files of a project.
//
// Contents:
//   1. Table parse: reading a table into a curve
//   2. Project data files

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
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import { fold, numberText, truncate } from "../core/terminal.js"
import { lockedIn } from "./projects.js"

// ========================================================================================
// 1. Table parse: reading a table into a curve
// ========================================================================================

/**
 * Turns any table a user has (delimited text with comments, free-text header lines,
 * an optional header row; or the first sheet of an `.xlsx`) into rows of cells, names
 * the columns and picks three of them as the curve q, I, sigma. Everything here is
 * pure apart from [[loadSource]] (reads a file): the `data` import screen shows the
 * result of [[parseTable]] as a live preview and calls [[extractCurve]] to write.
 *
 * Nothing is skipped quietly except the structure the user can see and switch (the
 * comment lines, the first rows to skip, blank rows, the header): a row that does not
 * give a number in a chosen column STOPS the import with a message that names the line
 * and the column, because it means the wrong column was picked or the file is messed
 * up. Every message is short enough for the line above the keys.
 */

/**
 * The fewest points a curve may have: the fewest BAYSOL itself can run with. The scale
 * and background of every model curve are a weighted least-squares fit (`wls`) that needs
 * at least 3 points on the fitted grid (a 2-parameter fit with a residual); with 1 or 2
 * points a run stops with a `WLSError`. Measured in smoke runs of `run_project`: 1 and 2
 * points fail, 3 run to the end (reduced chi-square infinite, no degrees of freedom left).
 * The limit is not ours to choose, so it is that need and no more.
 */
const MIN_POINTS = 3

/** The biggest file read, in bytes (it is read whole). */
const MAX_DATA_BYTES = 20 * 1024 * 1024

/**
 * The error of a file or a choice that is not a usable curve. The message is short and
 * is shown as it is.
 */
export class DataFileError extends Error {}

/**
 * The curve: three columns of equal length.
 *
 * @property q - the scattering vector, strictly increasing and above 0.
 * @property i - the intensity.
 * @property sigma - its uncertainty, above 0; empty for a curve without one (a reference).
 * @property dropped - the rows left out because their q was not above 0 (0 if none).
 */
export type DataPoints = { q: number[]; i: number[]; sigma: number[]; dropped: number }

/**
 * The tunables of the import: the preview rows, the lines sniffed, the characters that
 * start a comment line and the lower-case header names that tell a column's role.
 */
export const IMPORT_TUNABLES = {
    previewRows: 12,
    sniffLines: 40,
    commentChars: ["#", ";", "%", "!"],
    guesses: {
        q: ["q", "s", "qa", "qnm", "scatteringvector", "scattering"],
        i: ["i", "iq", "intensity", "iobs", "iexp", "signal", "counts"],
        sigma: [
            "sigma", "sig", "err", "error", "di", "ierr", "erri", "sigmai", "sigmaiq",
            "stdev", "sd", "uncertainty", "dev", "deltai",
        ],
    } as Record<"q" | "i" | "sigma", string[]>,
}

/**
 * The separators the user can pick by name, in the order they cycle. `auto` lets SheetJS
 * sniff the text (it knows comma, tab, semicolon and pipe); `whitespace` splits on runs
 * of blanks. Anything else the user types is taken as the characters themselves (see
 * [[separatorPlan]]).
 */
export const separatorPresets: readonly string[] = [
    "auto",
    "tab",
    "comma",
    "semicolon",
    "pipe",
    "whitespace",
]

/** Whether the first remaining row is a header: sniffed, or the user says. */
export type HeaderMode = "auto" | "yes" | "no"

/** Every choice of the header, in the order they cycle. */
export const headerModes: readonly HeaderMode[] = ["auto", "yes", "no"]

/**
 * How a source is read into a table.
 *
 * @property separator - how a text line is split (ignored for a workbook): `auto`, a
 *     name of [[separatorPresets]], or any characters as typed (`\t` and `space` are
 *     spelled out).
 * @property sheet - the sheet of a workbook by name; `""` is the first non-empty one (a
 *     name that is not in the file also falls back to it).
 * @property skipRows - rows dropped from the top of the file before anything else
 *     (free-text headers of a `.dat`); blank lines count.
 * @property comments - drop the lines that start with one of the comment characters.
 * @property header - whether the first remaining row names the columns.
 */
export type ParseOptions = {
    separator: string
    sheet: string
    skipRows: number
    comments: boolean
    header: HeaderMode
}

/** What the options are before the user changes anything. */
export const DEFAULT_PARSE_OPTIONS: ParseOptions = {
    separator: "auto",
    sheet: "",
    skipRows: 0,
    comments: true,
    header: "auto",
}

/** One row of a source: the number of its line (or sheet row) and its text or cells. */
type SourceRow = { line: number; text?: string; cells?: string[] }

/** One non-empty sheet of a workbook. */
type Sheet = { name: string; rows: SourceRow[] }

/**
 * The content of a file before it is split.
 *
 * @property kind - `text`: delimited text; `workbook`: any spreadsheet SheetJS reads.
 * @property rows - every line of a text file, blank ones included, so numbers stay true.
 * @property sheets - the non-empty sheets of a workbook, each with all its rows.
 */
export type Source = { kind: "text" | "workbook"; rows: SourceRow[]; sheets: Sheet[] }

/** @returns the names of the sheets of a source (none for text). */
export const sheetNames = (source: Source): string[] => source.sheets.map((s) => s.name)

/** @returns the named sheet of a workbook, else its first one. */
const sheetOf = (source: Source, name: string): Sheet | undefined =>
    source.sheets.find((s) => s.name === name) ?? source.sheets[0]

/**
 * The rows of a source to read: the lines of a text, the rows of the chosen sheet.
 *
 * @param sheet - the sheet's name; the first sheet when it is `""` or unknown.
 */
export function rowsOf(source: Source, sheet: string): SourceRow[] {
    if (source.kind === "text") return source.rows
    return sheetOf(source, sheet)?.rows ?? []
}

/** One row of a parsed table: the line it came from and its cells (trimmed). */
export type TableRow = { line: number; cells: string[] }

/**
 * A parsed table.
 *
 * @property kind - what the source was.
 * @property separator - the separator used, for the user (the sniffed one for `auto`).
 * @property sheet - the sheet read (`""` for text).
 * @property header - whether the first remaining row was taken as the header.
 * @property names - the column names: the header's, else `col:1`, `col:2`, ...
 * @property rows - the data rows (no header, no comments, no blank rows).
 */
export type Table = {
    kind: Source["kind"]
    separator: string
    sheet: string
    header: boolean
    names: string[]
    rows: TableRow[]
}

/** The name of a column without a header. */
const columnName = (index: number): string => `col:${index}`

/**
 * Reads a file whole, refusing a huge one.
 *
 * @throws [[DataFileError]] for a file over the limit or one that cannot be read.
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

/** A cell as text: a number as `String(number)` (full precision), nothing as empty. */
const cellText = (cell: unknown): string =>
    cell === null || cell === undefined ? "" : String(cell).trim()

/** The text of a delimited file as a source: a row per line, a byte order mark dropped. */
export function textSource(text: string): Source {
    const lines = text.replace(/^\uFEFF/, "").split(/\r\n|\r|\n/)
    return {
        kind: "text",
        rows: lines.map((line, k) => ({ line: k + 1, text: line })),
        sheets: [],
    }
}

/**
 * The non-empty sheets of a SheetJS workbook as a source.
 *
 * @returns the source, one row per sheet row, every sheet with something in it.
 * @throws [[DataFileError]] for a workbook without data.
 */
function bookSource(book: XLSX.WorkBook): Source {
    const sheets: Sheet[] = []
    for (const name of book.SheetNames) {
        const sheet = book.Sheets[name]
        if (sheet === undefined || sheet["!ref"] === undefined) continue
        const start = XLSX.utils.decode_range(sheet["!ref"]).s.r
        const rows = XLSX.utils
            .sheet_to_json<unknown[]>(sheet, { header: 1, raw: true, blankrows: true })
            .map((cells, k) => ({
                line: start + k + 1,
                cells: Array.from(cells, cellText),
            }))
        if (rows.some((r) => r.cells.some((c) => c !== ""))) sheets.push({ name, rows })
    }
    if (sheets.length === 0) throw new DataFileError("the file has no data")
    return { kind: "workbook", rows: [], sheets }
}

/**
 * Reads a spreadsheet of any format SheetJS knows (`.xlsx`, `.xlsm`, `.xlsb`, `.xls`,
 * `.ods`, `.fods`, `.numbers`); SheetJS works the format out from the bytes.
 *
 * @throws [[DataFileError]] for a file that cannot be read or has no data.
 */
function workbookSource(bytes: Buffer): Source {
    try {
        return bookSource(XLSX.read(bytes, { type: "buffer", raw: true }))
    } catch (error) {
        if (error instanceof DataFileError) throw error
        throw new DataFileError("cannot read that file")
    }
}

/**
 * The content of a file of any kind, recognised by its CONTENT, never by its name: a ZIP
 * (`.xlsx`, `.xlsm`, `.xlsb`, `.ods`, `.numbers`) or a compound file (`.xls`) is a
 * workbook, a flat OpenDocument XML (`.fods`) too; any other file with no NUL byte is
 * delimited text.
 *
 * @throws [[DataFileError]] with a short message.
 */
export function loadSource(path: string): Source {
    const bytes = readBounded(path)
    const magic = bytes.subarray(0, 4).toString("hex")
    if (magic === "504b0304") {
        return workbookSource(bytes)
    }
    if (magic === "d0cf11e0") return workbookSource(bytes)
    if (bytes.includes(0)) throw new DataFileError("not a text file")
    const text = bytes.toString("utf-8")
    // flat OpenDocument (`.fods`) is XML text that SheetJS reads as a workbook
    if (text.slice(0, 2000).includes("urn:oasis:names:tc:opendocument"))
        return workbookSource(bytes)
    return textSource(text)
}

/**
 * Trims cells, unquotes a cell wrapped in double quotes and drops the empty cells at the
 * end of the row.
 */
function tidy(parts: string[]): string[] {
    const cells = parts.map((p) => p.trim().replace(/^"(.*)"$/, "$1"))
    while (cells.length > 0 && cells[cells.length - 1] === "") cells.pop()
    return cells
}

/** How the user's separator is applied. */
type SplitPlan = { kind: "auto" } | { kind: "runs" } | { kind: "chars"; text: string }

/** The characters of the separators that have a name. */
const namedSeparators: Record<string, string> = {
    tab: "\t",
    comma: ",",
    semicolon: ";",
    pipe: "|",
}

/**
 * What a separator typed by the user means: `auto` (SheetJS sniffs), `whitespace` or
 * `space` (runs of blanks), a name (`tab`, `comma`, `semicolon`, `pipe`), `\t`, or any
 * characters, taken as they are (a blank typed alone is a run of blanks).
 */
function separatorPlan(choice: string): SplitPlan {
    const key = choice.trim().toLowerCase()
    if (key === "auto" || choice === "") return { kind: "auto" }
    if (key === "" || key === "whitespace" || key === "space" || key === "spaces")
        return { kind: "runs" }
    const named = namedSeparators[key]
    if (named !== undefined) return { kind: "chars", text: named }
    return { kind: "chars", text: choice.replaceAll("\\t", "\t") }
}

/** Why a separator typed by the user cannot be used. */
export const separatorProblem = (text: string): string | undefined =>
    text === "" ? "type a separator, or auto" : undefined

/** @returns a separator's characters as a word for the user (`\t` is `tab`). */
function separatorName(text: string): string {
    const found = Object.entries(namedSeparators).find(([, chars]) => chars === text)
    return found ? found[0] : text
}

/** @returns whether a text line is a comment: its first character is a comment one. */
const isComment = (text: string): boolean =>
    IMPORT_TUNABLES.commentChars.includes(text.trimStart().charAt(0))

/** A cell as the number it spells: a decimal comma and a `D` exponent are accepted. */
function plainCell(cell: string, decimal: boolean): string {
    const text = cell.replace(/(\d)[dD]([-+]?\d+)$/, "$1e$2")
    return decimal ? text.replace(/^([-+]?\d*),(\d+(?:e[-+]?\d+)?)$/i, "$1.$2") : text
}

/** A text line of a file or a row of a sheet, as the parse sees it. */
type Line = { line: number; text?: string; cells?: string[]; comment: boolean }

/**
 * Splits a text on `delimiter` (`null`: runs of blanks); a delimiter inside double
 * quotes does not split, the quotes are dropped.
 */
function splitText(text: string, delimiter: string | null): string[] {
    if (delimiter === null) return tidy(text.trim().split(/\s+/))
    const parts: string[] = []
    let part = ""
    let quoted = false
    for (let k = 0; k < text.length; ) {
        if (text[k] === '"') quoted = !quoted
        if (!quoted && text.startsWith(delimiter, k)) {
            parts.push(part)
            part = ""
            k += delimiter.length
        } else part += text[k++]
    }
    return tidy([...parts, part])
}

/** @returns the cells of a line; a comment line loses its comment characters. */
const cellsOf = (row: Line, delimiter: string | null, bare = false): string[] =>
    row.cells ??
    splitText(
        bare ? (row.text ?? "").replace(/^\s*[#;%!]+/, "") : (row.text ?? ""),
        delimiter,
    )

/** @returns whether the cell is a number. */
const isNumber = (cell: string, decimal: boolean): boolean =>
    numberText(plainCell(cell, decimal)) !== undefined

/**
 * The rows of a source after the rows to skip, blank ones dropped, comments flagged.
 */
function linesOf(source: Source, options: ParseOptions): Line[] {
    const out: Line[] = []
    for (const row of rowsOf(source, options.sheet).slice(Math.max(0, options.skipRows))) {
        const first = row.text ?? row.cells?.[0] ?? ""
        if ((row.text ?? (row.cells ?? []).join("")).trim() === "") continue
        const comment = options.comments && isComment(first)
        out.push({ ...row, comment })
    }
    return out
}

/**
 * Parses a source into a table. The delimiter is the candidate (tab, comma, semicolon,
 * pipe, runs of blanks; the user's one when typed) that splits the most lines into the
 * same number of 2 or more numbers, ties to the order listed. The data start at the
 * first such line and end at the first line that is no data row (a footer); everything
 * before it is header text, and the names are the line just above (a comment line
 * too) with as many fields as the data have.
 *
 * @param limit - the most data rows to return (all when left out); a preview needs few.
 */
export function parseTable(
    source: Source,
    options: ParseOptions,
    limit: number = Number.POSITIVE_INFINITY,
): Table {
    const text = source.kind === "text"
    const plan = separatorPlan(options.separator)
    // tab, comma, semicolon, pipe, runs of blanks (`null`); or the user's one
    let candidates: (string | null)[] = [null]
    if (text && plan.kind === "auto") candidates = ["\t", ",", ";", "|", null]
    else if (text && plan.kind === "chars") candidates = [plan.text]
    const all = linesOf(source, options)
    const body = all.filter((row) => !row.comment)
    // the candidate with the most lines of one count of numbers, the first of them wins;
    // a file with no such lines is split by the delimiter that gives the most equal counts
    let best = { delimiter: candidates[0] ?? null, start: -1, width: 0, score: 0 }
    for (const strict of [true, false]) {
        for (const delimiter of candidates) {
            const found = { delimiter, start: -1, width: 0, score: 0 }
            const decimal = delimiter !== ","
            for (const [n, row] of body.entries()) {
                const cells = cellsOf(row, delimiter)
                if (cells.length < 2) continue
                if (strict && !cells.every((c) => isNumber(c, decimal))) continue
                if (found.start < 0) Object.assign(found, { start: n, width: cells.length })
                if (cells.length === found.width) found.score++
                if (found.score >= IMPORT_TUNABLES.sniffLines) break
            }
            if (found.score > best.score) best = found
        }
        if (best.score > 0) {
            if (!strict) best.start = -1
            break
        }
    }
    const { delimiter, width } = best
    const found = best.start >= 0
    const decimal = delimiter !== ","
    // a data row has as many cells as the first one with a number in it, or is all numbers
    const isData = (cells: string[]): boolean =>
        (cells.length >= 2 && cells.every((c) => isNumber(c, decimal))) ||
        (found && cells.length === width && cells.some((c) => isNumber(c, decimal)))
    const rest = body.slice(Math.max(0, best.start))
    const end = found ? rest.findIndex((row) => !isData(cellsOf(row, delimiter))) : -1
    const rows = (end < 0 ? rest : rest.slice(0, end)).slice(0, limit + 1)
    const split: TableRow[] = rows.map((row) => ({
        line: row.line,
        cells: cellsOf(row, delimiter).map((c) => {
            const plain = plainCell(c, decimal)
            return numberText(plain) === undefined ? c : plain
        }),
    }))
    // the header: the line just above the data if it has the data's width (or if asked)
    const above = all.slice(0, found ? all.indexOf(rest[0] as Line) : 0)
    const row = above[above.length - 1]
    const named = row ? cellsOf(row, delimiter, true) : []
    let names: string[] | undefined
    let data = split
    if (options.header !== "no") {
        if (row && (options.header === "yes" || (found && named.length === width)))
            names = named
        else if (split[0] && (options.header === "yes" || !found)) {
            // no text above: the first row, if asked or if nothing was sniffed
            const numbers = split[0].cells.every((c) => isNumber(c, true))
            if (options.header === "yes" || !numbers) {
                names = split[0].cells
                data = split.slice(1)
            }
        }
    }
    data = data.slice(0, limit)
    const columns = Math.max(names?.length ?? 0, ...data.map((r) => r.cells.length))
    const labels = Array.from({ length: columns }, (_, k) =>
        names?.[k] ? names[k] : columnName(k + 1),
    ) as string[]
    let used = delimiter === null ? "whitespace" : separatorName(delimiter)
    if (!text) used = ""
    else if (!found && plan.kind === "auto") used = "auto"
    const sheet = text ? "" : (sheetOf(source, options.sheet)?.name ?? "")
    return {
        kind: source.kind,
        separator: used,
        sheet,
        header: names !== undefined,
        names: labels,
        rows: data,
    }
}

/**
 * The column a typed text means: `col:N`, a bare number N (both count from 1, in every
 * table, with or without a header) or a header name (case-insensitive).
 */
export function resolveColumn(
    spec: string,
    names: readonly string[],
): { column: number } | { error: string } {
    const text = spec.trim()
    if (text === "") return { error: "needs a column" }
    const number = /^(?:col:)?(\d+)$/i.exec(text)
    if (number) {
        const column = Number(number[1])
        if (column >= 1 && column <= names.length) return { column }
        return { error: `no column ${column} (${names.length} columns)` }
    }
    const index = names.findIndex((name) => fold(name) === fold(text))
    if (index >= 0) return { column: index + 1 }
    return { error: `no column "${truncate(text, 14)}"` }
}

/** The three columns of the curve. */
export type Role = "q" | "i" | "sigma"

/** Every role, in the order the screen asks for them: q, I(q), sigma. */
export const roles: readonly Role[] = ["q", "i", "sigma"]

/** What a role is called for the user. */
export const roleLabel: Record<Role, string> = { q: "q", i: "I(q)", sigma: "sigma" }

/**
 * A column the user chose.
 *
 * @property spec - what was typed (a number, `col:N` or a header name).
 * @property column - the column it meant, counting from 1.
 */
export type ColumnChoice = { spec: string; column: number }

/**
 * Resolves the three typed specs against the columns of a table.
 *
 * @throws [[DataFileError]] naming the role whose column is unknown, or when two roles
 *     mean the same column.
 */
export function resolveColumns(
    specs: Record<Role, string>,
    names: readonly string[],
): Record<Role, ColumnChoice> {
    const choice = {} as Record<Role, ColumnChoice>
    for (const role of roles) {
        const found = resolveColumn(specs[role], names)
        if ("error" in found) throw new DataFileError(`${roleLabel[role]}: ${found.error}`)
        choice[role] = { spec: specs[role].trim(), column: found.column }
    }
    if (new Set(roles.map((r) => choice[r].column)).size < roles.length)
        throw new DataFileError("q, I(q) and sigma need three different columns")
    return choice
}

/**
 * The columns to start from: by name (`q`, `s`, `I`, `intensity`, `err`, `sigma`, `dI`,
 * ... from `data_import.json`), else by position (q, I, sigma in the columns not taken),
 * written as the header name when there is a header and as `col:N` otherwise.
 */
export function guessColumns(
    names: readonly string[],
    header: boolean,
): Record<Role, string> {
    const taken = new Set<number>()
    const found: Partial<Record<Role, number>> = {}
    const letters = (name: string): string => fold(name).replace(/[^a-z0-9]/g, "")
    const lead = (name: string): string => /^[a-z]+/.exec(fold(name))?.[0] ?? ""
    for (const matcher of [letters, lead]) {
        for (const role of ["q", "i", "sigma"] as const) {
            if (found[role] !== undefined) continue
            const known = IMPORT_TUNABLES.guesses[role]
            const index = names.findIndex(
                (name, k) => !taken.has(k) && known.includes(matcher(name)),
            )
            if (index < 0) continue
            found[role] = index
            taken.add(index)
        }
    }
    // by position: the free columns, in order, for the roles still without one
    const free = names.map((_, k) => k).filter((k) => !taken.has(k))
    for (const role of ["q", "i", "sigma"] as const)
        if (found[role] === undefined) found[role] = free.shift()
    const spec = (role: Role): string => {
        const index = found[role]
        if (index === undefined) return ""
        return header ? (names[index] as string) : columnName(index + 1)
    }
    return { q: spec("q"), i: spec("i"), sigma: spec("sigma") }
}

/** The columns of a curve, counting from 1; a curve without a `sigma` has none. */
export type CurveColumns = { q: number; i: number; sigma?: number }

/**
 * Takes the chosen columns of a table as the curve and checks it. A row with q or sigma
 * not above 0 is dropped and counted (`dropped`), as the fitting scripts do with real
 * SASBDB files. Without a `sigma` column (a reference curve) only q is checked and
 * `sigma` of the result is empty.
 *
 * @param columns - the columns, counting from 1 (see [[resolveColumns]]).
 * @throws [[DataFileError]] for the FIRST problem: a cell that is empty or no number
 *     (the message names the line and the column), q not increasing, or fewer than
 *     [[MIN_POINTS]] rows.
 */
export function extractCurve(table: Table, columns: CurveColumns): DataPoints {
    const data: DataPoints = { q: [], i: [], sigma: [], dropped: 0 }
    const where = table.kind === "workbook" ? "row" : "line"
    const wanted = roles.filter((role) => role !== "sigma" || columns.sigma !== undefined)
    for (const { line, cells } of table.rows) {
        const value: Record<Role, number> = { q: 0, i: 0, sigma: 1 }
        for (const role of wanted) {
            const index = (columns[role] as number) - 1
            const cell = cells[index] ?? ""
            const number = cell === "" ? undefined : numberText(cell)
            const column = truncate(table.names[index] ?? "", 14)
            const label = `${where} ${line}, column ${column}`
            if (cell === "") throw new DataFileError(`${label}: no value`)
            if (number === undefined)
                throw new DataFileError(`${label}: "${truncate(cell, 12)}" is no number`)
            value[role] = number
        }
        if (value.q <= 0 || value.sigma <= 0) {
            data.dropped++
            continue
        }
        const before = data.q[data.q.length - 1]
        if (before !== undefined && value.q <= before)
            throw new DataFileError(`${where} ${line}: q must increase`)
        data.q.push(value.q)
        data.i.push(value.i)
        if (columns.sigma !== undefined) data.sigma.push(value.sigma)
    }
    if (data.q.length < MIN_POINTS)
        throw new DataFileError(`only ${data.q.length} points: need ${MIN_POINTS}`)
    return data
}

/** What a reference curve's sigma is typed as when it has none. */
export const NO_SIGMA = "none"

/** Whether a typed sigma means no column: `none` or nothing. */
export const isNoSigma = (spec: string): boolean =>
    ["", NO_SIGMA].includes(spec.trim().toLowerCase())

/**
 * The columns of a reference curve: q and I(q) as for [[resolveColumns]], and an optional
 * sigma (`none`, or nothing typed, is no column).
 *
 * @returns the columns, counting from 1; `sigma` is absent for none.
 * @throws [[DataFileError]] as [[resolveColumns]] does, for the roles that are chosen.
 */
export function resolveReferenceColumns(
    specs: Record<Role, string>,
    names: readonly string[],
): CurveColumns {
    const chosen: readonly Role[] = isNoSigma(specs.sigma) ? ["q", "i"] : roles
    const found: Partial<Record<Role, number>> = {}
    for (const role of chosen) {
        const one = resolveColumn(specs[role], names)
        if ("error" in one) throw new DataFileError(`${roleLabel[role]}: ${one.error}`)
        found[role] = one.column
    }
    const used = Object.values(found)
    if (new Set(used).size < used.length)
        throw new DataFileError("q, I(q) and sigma need different columns")
    return { q: found.q as number, i: found.i as number, sigma: found.sigma }
}

/** A column offered while the user types: its name, and `col:N` with a sample value. */
export type ColumnSuggestion = { label: string; tag: string }

/**
 * The suggestions for a column prompt: every column as its name with `col:N` and the
 * first value as the tag, the ones that contain the typed text only, those that start
 * with it first.
 *
 * @returns the suggestions; all columns for a blank text (the shape of a `Suggestion`
 *     of the UI kit).
 */
export function suggestColumns(table: Table, text: string): ColumnSuggestion[] {
    const want = text.trim().toLowerCase()
    const first = table.rows[0]
    const all = table.names.map((name, k) => ({
        label: name,
        tag: `${name.startsWith("col:") ? "" : `col:${k + 1}  `}${first?.cells[k] ?? ""}`
            .trim(),
        key: `${name} col:${k + 1}`.toLowerCase(),
        start: name.toLowerCase().startsWith(want) || `col:${k + 1}`.startsWith(want),
    }))
    return all
        .filter((c) => want === "" || c.key.includes(want))
        .sort((a, b) => Number(b.start) - Number(a.start))
        .map(({ label, tag }) => ({ label, tag }))
}

// ========================================================================================
// 2. Project data files
// ========================================================================================

/**
 * The measured curve of a project: the `data` screen turns any delimited text file or
 * `.xlsx` workbook into a CLEAN `data.tsv` in the project (exactly three tab-separated
 * columns q, I, sigma, one measurement per row, no header, no comments, no unit text;
 * the original file is never touched) and writes what the numbers mean into
 * `data.json` (units of q, X-ray energy in eV, the source's file name, the point
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
 * missing (an old file) or malformed is simply absent and never makes the data unusable.
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
    const chosen = typeof sheet === "string" ? sheet : "" // absent in older files
    return { ...(value as unknown as ParseOptions), sheet: chosen, path, columns }
}

/**
 * What `data.json` holds.
 *
 * @property units - the units of q in `data.tsv`.
 * @property energy - the X-ray energy in eV, `null` until the user gives it.
 * @property source - the name (no folder) of the file the data came from.
 * @property points - the number of rows of `data.tsv`.
 * @property mapping - where the curve came from and how it was read; absent in a file
 *     written before the import remembered it.
 */
export type DataInfo = {
    units: Units
    energy: number | null
    source: string
    points: number
    mapping?: DataMapping
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
    const { units, energy, source, points } = value
    const ok =
        (units === "nm-1" || units === "A-1") &&
        (energy === null || (typeof energy === "number" && energy > 0)) &&
        typeof source === "string" &&
        typeof points === "number" &&
        Number.isInteger(points) &&
        points >= MIN_POINTS
    if (!ok) throw unusableData(dataJsonName)
    const info = { units, energy, source, points } as DataInfo
    const mapping = readMapping(value.mapping)
    return mapping === undefined ? info : { ...info, mapping }
}

/**
 * Writes the data of a project: `data.tsv` first, `data.json` LAST (so a reader that
 * finds the JSON finds the whole table), each atomically under its own lock, inside the
 * project (a deleted project is never brought back). An existing `data.json` that
 * cannot be used is never written over.
 *
 * @param energy - the energy in eV, or `undefined` while it is not known.
 * @param mapping - where the curve came from, to remember (see [[DataMapping]]).
 * @throws ProjectGoneError, FileInUseError, UnusableFileError (an old `data.json`),
 *     or whatever the write throws.
 */
export function writeData(
    projectDir: string,
    data: DataPoints,
    source: string,
    units: Units,
    energy?: number,
    mapping?: DataMapping,
): DataInfo {
    const info: DataInfo = {
        units,
        energy: energy ?? null,
        source: basename(source),
        points: data.q.length,
        ...(mapping === undefined ? {} : { mapping }),
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

/** What [[setEnergy]] says of an energy that is not above 0. */
export const ENERGY_PROBLEM = "above 0, please"

/**
 * Sets the X-ray energy. Only `data.json` is written.
 *
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
