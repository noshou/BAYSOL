// SPDX-License-Identifier: LGPL-3.0-or-later

// View: the data of the read-only viewers (sheets, plots, the `run.LOG` pager), no drawing.
//
// Contents:
//   1. Sheets: a workbook or delimited file read into sheets and cells
//   2. Plots: the terminal plots of a run (`plots.txt`) cut into tabs and windows
//   3. Pager: the arithmetic of the text pager and how a text becomes its lines
//   4. Search, jump, copy: finding cells, `B7` jumps, TSV for the clipboard, formulas

import { stripVTControlCharacters } from "node:util"
import * as XLSX from "xlsx"
import { readAssetJson } from "../core/environment.js"
import { readBounded } from "../core/file-system.js"
import { displayWidth } from "../core/terminal.js"
import { scrollTo } from "../ui/interaction.js"

// ========================================================================================
// 1. Sheets
// ========================================================================================

/**
 * The model of the read-only file viewer: a workbook or a delimited file read into
 * sheets of display text (SheetJS is the one reader), and everything the viewer asks of
 * a sheet without drawing it: cell references (`B7`), column widths and the columns that
 * fit. No React here, so all of it is tested. The file is only ever read.
 */

/**
 * The limits of the viewer: the largest file opened, the most rows, columns and cells
 * held of a sheet (rows are cut to fit), the narrowest and widest column drawn, the rows
 * that decide a column's width and the longest tab name (`assets/data/sheet_viewer.json`).
 */
export type ViewerLimits = {
    maxBytes: number
    maxRows: number
    maxColumns: number
    maxCells: number
    minColumnWidth: number
    maxColumnWidth: number
    widthSampleRows: number
    maxTabName: number
}

/** The limits of the viewer (see [[ViewerLimits]]). */
export const VIEWER_LIMITS: ViewerLimits = readAssetJson<ViewerLimits>(
    "data",
    "sheet_viewer.json",
)

/** A file that cannot be viewed; the message is short and fit to show as a note. */
export class ViewerFileError extends Error {}

/**
 * One sheet, as text.
 *
 * @property name - the sheet's name (the file name for a delimited file).
 * @property cells - `rows` lines of `columns` cells of display text (control characters
 *     are replaced by a space, so a cell is one clean line).
 * @property rows - the rows held.
 * @property columns - the columns held.
 * @property fullRows - the rows the sheet has (more than `rows` when it was cut).
 * @property fullColumns - the columns the sheet has.
 * @property header - the first row is text over data, so the viewer keeps it in view.
 * @property widths - the width of each column, from its text.
 * @property formulas - the text of the formula (`=SUM(A1:A2)`) of each cell that has one,
 *     empty for the others; `undefined` when the sheet has none (a delimited file).
 */
export type Sheet = {
    name: string
    cells: string[][]
    rows: number
    columns: number
    fullRows: number
    fullColumns: number
    header: boolean
    widths: number[]
    formulas?: string[][]
}

/** A file opened for viewing: its sheet names now, its sheets when asked for. */
export type Workbook = {
    names: string[]
    sheet: (index: number) => Sheet
}

/** What SheetJS gives for a cell, the parts used here. */
type RawCell = { t?: string; v?: unknown; w?: string; f?: string }

/**
 * A cell's text as it is shown: the formatted text SheetJS made, else the value.
 * Control characters (tab, newline, escape, ...) become one space, so a cell is a clean
 * line that cannot move the cursor of the terminal or break a TSV row.
 */
export function cellDisplay(cell: RawCell): string {
    return cleanText(
        cell.w ?? (cell.v === undefined || cell.v === null ? "" : String(cell.v)),
    )
}

/** A text with every run of control characters replaced by one space. */
function cleanText(text: string): string {
    // biome-ignore lint/suspicious/noControlCharactersInRegex: that is what is matched
    return text.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ")
}

/**
 * The width of each column: its widest text among the first rows (and the column's
 * letter), between the limits.
 *
 * @param max - the widest and narrowest allowed, and how many rows are sampled.
 */
export function fitWidths(
    cells: string[][],
    columns: number,
    max: Pick<ViewerLimits, "minColumnWidth" | "maxColumnWidth" | "widthSampleRows">,
): number[] {
    const widths = Array.from({ length: columns }, (_, c) =>
        Math.max(max.minColumnWidth, displayWidth(columnLabel(c))),
    )
    for (const row of cells.slice(0, max.widthSampleRows)) {
        for (let c = 0; c < columns; c++)
            widths[c] = Math.max(widths[c] as number, displayWidth(row[c] ?? ""))
    }
    return widths.map((w) => Math.min(w, max.maxColumnWidth))
}

/**
 * Turns one SheetJS worksheet into a [[Sheet]].
 *
 * @param ws - the worksheet, read with `sheetRows` so it holds at most `maxRows` rows.
 * @returns the sheet (empty, with no rows or columns, for a sheet without cells).
 */
export function buildSheet(name: string, ws: XLSX.WorkSheet, max: ViewerLimits): Sheet {
    const ref = ws["!ref"]
    if (ref === undefined)
        return {
            name,
            cells: [],
            rows: 0,
            columns: 0,
            fullRows: 0,
            fullColumns: 0,
            header: false,
            widths: [],
        }
    const held = XLSX.utils.decode_range(ref)
    // SheetJS keeps the size of the whole sheet in `!fullref` when `sheetRows` cut it
    const full = XLSX.utils.decode_range((ws["!fullref"] as string | undefined) ?? ref)
    const columns = Math.min(held.e.c + 1, max.maxColumns)
    const rows = Math.min(held.e.r + 1, max.maxRows, Math.floor(max.maxCells / columns))
    const cells = Array.from({ length: rows }, () => Array<string>(columns).fill(""))
    let firstRowText = true
    let firstRowCells = 0
    let formulas: string[][] | undefined
    for (const key of Object.keys(ws)) {
        if (key.startsWith("!")) continue
        const { r, c } = XLSX.utils.decode_cell(key)
        if (r >= rows || c >= columns) continue
        const cell = ws[key] as RawCell
        const text = cellDisplay(cell)
        ;(cells[r] as string[])[c] = text
        if (typeof cell.f === "string" && cell.f !== "") {
            formulas ??= Array.from({ length: rows }, () => Array<string>(columns).fill(""))
            ;(formulas[r] as string[])[c] = cleanText(`=${cell.f}`)
        }
        if (r === 0 && text !== "") {
            firstRowCells++
            if (cell.t !== "s") firstRowText = false
        }
    }
    return {
        name,
        cells,
        rows,
        columns,
        fullRows: Math.max(full.e.r + 1, rows),
        fullColumns: Math.max(full.e.c + 1, columns),
        header: rows > 1 && firstRowCells > 0 && firstRowText,
        widths: fitWidths(cells, columns, max),
        ...(formulas ? { formulas } : {}),
    }
}

/** Whether the first bytes are a ZIP (xlsx, ods) or an old binary workbook (xls). */
const isBinaryBook = (bytes: Buffer): boolean =>
    bytes.subarray(0, 2).toString("latin1") === "PK" ||
    bytes.subarray(0, 4).toString("hex") === "d0cf11e0"

/**
 * Opens a file for viewing, read only: the file is read once into memory and never
 * written, locked or touched. A workbook gives one tab per sheet; a delimited text file
 * (`.csv`, `.tsv`, `.txt`, separator found by SheetJS) is one sheet named after
 * `fallbackName`. A sheet is parsed only when it is first asked for (SheetJS reads just
 * that sheet, at most `maxRows` rows of it) and kept.
 *
 * @throws [[ViewerFileError]] when the file is gone, too large or cannot be read.
 */
export function openWorkbook(path: string, fallbackName: string): Workbook {
    const max = VIEWER_LIMITS
    const bytes = readBounded(
        path,
        max.maxBytes,
        (message) => new ViewerFileError(message),
        `file too large (${max.maxBytes / 2 ** 20} MB at most)`,
    )
    const binary = isBinaryBook(bytes)
    if (!binary && bytes.includes(0)) throw new ViewerFileError("not a table")
    // text is decoded here (SheetJS would read bytes as Latin-1); a workbook is bytes
    const text = binary ? "" : bytes.toString("utf-8").replace(/^﻿/, "")
    const options: XLSX.ParsingOptions = {
        type: binary ? "buffer" : "string",
        sheetRows: max.maxRows,
        cellFormula: true,
    }
    const source: string | Buffer = binary ? bytes : text
    try {
        const names = binary
            ? XLSX.read(bytes, { type: "buffer", bookSheets: true }).SheetNames
            : [fallbackName]
        const kept = new Map<number, Sheet>()
        return {
            names,
            sheet(index: number): Sheet {
                const hit = kept.get(index)
                if (hit !== undefined) return hit
                const book = XLSX.read(source, { ...options, sheets: binary ? index : 0 })
                const name = names[index] ?? fallbackName
                // `sheets` keeps every name in `SheetNames`, parses only the one asked
                const ws = book.Sheets[name] ?? book.Sheets[book.SheetNames[0] as string]
                const built = buildSheet(name, ws ?? {}, max)
                kept.set(index, built)
                return built
            },
        }
    } catch {
        throw new ViewerFileError("cannot read that file")
    }
}

// --- cell references

/** The letters of a column, as in a spreadsheet. */
export const columnLabel = (index: number): string => XLSX.utils.encode_col(index)

/** The reference of a cell. */
export const cellRef = (row: number, column: number): string =>
    `${columnLabel(column)}${row + 1}`

// --- what fits

/**
 * How many items of a row of sizes fit from a first one: at least one, so a wide column
 * is cut rather than lost.
 */
export function fitCount(sizes: readonly number[], first: number, room: number): number {
    let used = 0
    let n = 0
    for (let k = first; k < sizes.length; k++) {
        used += sizes[k] as number
        if (used > room && n > 0) break
        n++
    }
    return n
}

/**
 * The first item of a row (columns, tabs) that keeps `selected` in view, moving as little
 * as possible.
 */
export function firstShown(
    sizes: readonly number[],
    first: number,
    selected: number,
    room: number,
): number {
    return scrollTo(Math.min(first, sizes.length - 1), selected, (f) =>
        fitCount(sizes, f, room),
    )
}

/**
 * Whether a text looks like a number, so the viewer right-aligns it.
 *
 * @returns `true` for a number, a percentage or a number with thousands separators.
 */
export const looksNumeric = (text: string): boolean =>
    /^[-+]?[\d.,]*\d[\d.,]*([eE][-+]?\d+)?%?$/.test(text)

// ========================================================================================
// 2. Plots
// ========================================================================================

/**
 * The terminal plots of a run (`plots.txt`, what `results(...; io = file)` prints): one
 * plot after another, each a title line above a boxed drawing, a blank line between.
 * Pure helpers for the viewer's plots mode: take the colour codes out, cut the text
 * into plots, and cut a line to a window of cells.
 */

/** One plot: its title (the tab) and its drawing, lines joined by a newline. */
export type Plot = { title: string; body: string }

/**
 * Takes out the ANSI sequences (colours), so the viewer paints in the theme's colours;
 * any other control character but the newline goes too.
 */
export function stripAnsi(text: string): string {
    const plain = stripVTControlCharacters(text).replace(/\r\n?/g, "\n")
    // biome-ignore lint/suspicious/noControlCharactersInRegex: that is what is matched
    return plain.replace(/[\u0000-\u0009\u000b-\u001f\u007f]/g, "")
}

/** The top-left corners of a box (UnicodePlots' `:corners` and the rounded ones). */
const boxTop = /[┌╭┏╔]/

/**
 * The tab name of a title line. UnicodePlots pads a title with the blank braille
 * character (U+2800, which `trim` keeps) and BAYSOL writes `fit   chi2 = 0.4` or
 * `rho   (MAP 0.33)`: the name is what comes before the first run of three spaces.
 */
function tabName(line: string): string {
    const clean = line.replace(/[\u2800\s]+/g, (run) => (run.length >= 3 ? "   " : " "))
    return (clean.trim().split("   ")[0] ?? "").trim()
}

/**
 * Cuts the text of a plots file into plots. A plot starts at a block whose first two
 * lines hold a box corner (the title line above, or the box itself with no title); a
 * block with no corner (a blank line inside a plot) belongs to the plot before it.
 *
 * @returns the plots in order (none for a text with no box), each with its title (`plot
 *     N` when it has none).
 */
export function splitPlots(text: string): Plot[] {
    const blocks = stripAnsi(text)
        .split(/\n[ \t]*\n/)
        .map((b) => b.replace(/^\n+|\s+$/g, ""))
        .filter((b) => b !== "")
    const plots: string[][] = []
    for (const block of blocks) {
        const lines = block.split("\n")
        const starts = lines.slice(0, 2).some((l) => boxTop.test(l))
        if (starts || plots.length === 0) plots.push(lines)
        else (plots[plots.length - 1] as string[]).push("", ...lines)
    }
    return plots
        .filter((lines) => lines.some((l) => boxTop.test(l)))
        .map((lines, k) => {
            const above = boxTop.test(lines[0] ?? "") ? "" : (lines[0] ?? "")
            const title = tabName(above)
            return { title: title === "" ? `plot ${k + 1}` : title, body: lines.join("\n") }
        })
}

/** Splits text into graphemes, once. */
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

/**
 * The part of a line from a cell to a width: for scrolling a wide plot sideways. A wide
 * character cut in half is replaced by a space.
 */
export function sliceCells(line: string, from: number, cells: number): string {
    let out = ""
    let at = 0
    for (const { segment } of graphemes.segment(line)) {
        const w = displayWidth(segment)
        if (at + w > from + cells) break
        if (at >= from) out += segment
        else if (at + w > from) out += " "
        at += w
    }
    return out
}

/**
 * Which of the files of one plot set, written at several sizes, to show: the largest
 * whose width and rows fit the area, or the smallest when none does.
 *
 * @param files - the candidates (`width` in cells, `rows` the lines of the tallest plot).
 * @param width - the cells the plot area is wide.
 * @param rows - the lines it is high.
 * @returns the index of the file, `undefined` for no candidates.
 */
export function pickPlotFile(
    files: readonly { width: number; rows: number }[],
    width: number,
    rows: number,
): number | undefined {
    let best: number | undefined
    let smallest: number | undefined
    for (const [i, f] of files.entries()) {
        const area = f.width * f.rows
        const small = files[smallest ?? i] as { width: number; rows: number }
        if (smallest === undefined || area < small.width * small.rows) smallest = i
        const fits = f.width <= width && f.rows <= rows
        const big = files[best ?? i] as { width: number; rows: number }
        if (fits && (best === undefined || area > big.width * big.rows)) best = i
    }
    return best ?? smallest
}

/** The widest line of a plot. */
export function plotWidth(body: string): number {
    return Math.max(0, ...body.split("\n").map(displayWidth))
}

// ========================================================================================
// 3. Pager
// ========================================================================================

/**
 * The arithmetic of the `run.LOG` pager, without any drawing: which line a
 * page turn lands on, where the end is, what the status line says, and how a text becomes
 * the lines the pager shows. All of it is pure, so all of it is tested.
 */

/**
 * The first line of the last page: the pager never scrolls past it, so the last page is
 * always full when the text is longer than a page.
 */
export function lastTop(count: number, rows: number): number {
    return Math.max(0, count - Math.max(1, rows))
}

/** Keeps a top line inside the text. */
export function clampTop(top: number, count: number, rows: number): number {
    return Math.min(Math.max(top, 0), lastTop(count, rows))
}

/**
 * The first line after turning a page down (or up): a page is the rows shown less the
 * `overlap` lines that stay in view, and a turn is at least one line.
 */
export function pageTop(
    top: number,
    count: number,
    rows: number,
    overlap: number,
    down: boolean,
): number {
    const step = Math.max(1, rows - overlap)
    return clampTop(top + (down ? step : -step), count, rows)
}

/** The status line: which lines are shown and how far down the text they are. */
export function pagerStatus(top: number, count: number, rows: number): string {
    if (count === 0) return "empty"
    const last = Math.min(count, top + Math.max(1, rows))
    return `lines ${top + 1}-${last} of ${count} · ${Math.round((last / count) * 100)}%`
}

/**
 * A line with its tabs replaced by spaces up to the next tab stop, so a `name<TAB>value`
 * row of a LOG lines up at any width and a cell count is the line's width.
 */
export function expandTabs(line: string, width: number): string {
    let out = ""
    const stop = Math.max(1, width)
    for (const ch of line) {
        if (ch === "\t") out += " ".repeat(stop - (displayWidth(out) % stop))
        else out += ch
    }
    return out
}

/**
 * The lines a pager shows for a text: split at line ends, tabs expanded, other control
 * characters (an escape would move the cursor of the terminal) replaced by a space, and
 * the empty line after a final newline left out.
 */
export function pagerLines(text: string, tabWidth: number): string[] {
    if (text === "") return []
    const lines = text.split(/\r\n|\r|\n/)
    if (lines[lines.length - 1] === "") lines.pop()
    return lines.map((line) =>
        // biome-ignore lint/suspicious/noControlCharactersInRegex: that is what is matched
        expandTabs(line, tabWidth).replace(/[\u0000-\u001f\u007f-\u009f]/g, " "),
    )
}

// ========================================================================================
// 4. Search, jump, copy
// ========================================================================================

/** The text each cell shows: the formulas where `formulas` is on and a cell has one. */
export function shownCells(sheet: Sheet, formulas: boolean): string[][] {
    const f = sheet.formulas
    if (!formulas || f === undefined) return sheet.cells
    return sheet.cells.map((line, r) => line.map((t, c) => f[r]?.[c] || t))
}

/** A cell, 0-based. */
export type CellAt = { row: number; column: number }

/**
 * The cells whose text contains `text`, case-insensitively, row by row.
 *
 * @param cells - the text of the sheet.
 * @param text - what is searched (empty: no match).
 * @returns the cells in row-major order.
 */
export function findCells(cells: readonly string[][], text: string): CellAt[] {
    const wanted = text.toLowerCase()
    if (wanted === "") return []
    const out: CellAt[] = []
    cells.forEach((line, row) => {
        line.forEach((t, column) => {
            if (t.toLowerCase().includes(wanted)) out.push({ row, column })
        })
    })
    return out
}

/**
 * The match a search lands on from a cursor: the first at or after it, else (wrapping)
 * the first.
 *
 * @returns the index in `matches`, `undefined` with none.
 */
export function matchFrom(matches: readonly CellAt[], row: number, column: number) {
    if (matches.length === 0) return undefined
    const from = (m: CellAt) => m.row > row || (m.row === row && m.column >= column)
    const at = matches.findIndex(from)
    return Math.max(at, 0)
}

/**
 * The next (`dir` 1) or previous (-1) match of a cursor, wrapping at both ends: from a cell
 * that is no match, the next is the first after it and the previous the last before it.
 *
 * @returns the index in `matches`, `undefined` with none.
 */
export function matchStep(
    matches: readonly CellAt[],
    row: number,
    column: number,
    dir: 1 | -1,
): number | undefined {
    const n = matches.length
    if (n === 0) return undefined
    const after = (m: CellAt) => m.row > row || (m.row === row && m.column > column)
    if (dir === 1) {
        const at = matches.findIndex(after)
        return Math.max(at, 0)
    }
    const before = matches.findLastIndex(
        (m) => m.row < row || (m.row === row && m.column < column),
    )
    return before < 0 ? n - 1 : before
}

/** The index of a cell among the matches, `undefined` when it is none. */
export const matchIndex = (matches: readonly CellAt[], row: number, column: number) => {
    const at = matches.findIndex((m) => m.row === row && m.column === column)
    return at < 0 ? undefined : at
}

/**
 * Reads what `j` takes: a cell (`B7`), a row (`7`) or a column (`B`). A part left out
 * keeps the cursor's. A place outside the sheet is refused, not clamped: the user typed it.
 *
 * @param text - what was typed.
 * @param at - the cursor.
 * @param rows - the rows of the sheet.
 * @param columns - the columns of the sheet.
 * @returns the cell, or the note.
 */
export function parseJump(
    text: string,
    at: CellAt,
    rows: number,
    columns: number,
): CellAt | { error: string } {
    const typed = text.trim()
    const match = /^([A-Za-z]{1,3})?(\d{1,7})?$/.exec(typed)
    if (typed === "" || match === null)
        return { error: "a cell like B7, a row or a column" }
    const [, letters, digits] = match
    const column =
        letters === undefined ? at.column : XLSX.utils.decode_col(letters.toUpperCase())
    const row = digits === undefined ? at.row : Number(digits) - 1
    if (row < 0 || row >= rows || column >= columns)
        return { error: `outside the sheet (A1:${cellRef(rows - 1, columns - 1)})` }
    return { row, column }
}

/** The most bytes a copy may send through the terminal (OSC 52 has limits). */
export const COPY_LIMIT = 70 * 1024

/** What a copy takes: a rectangle, or a whole row or column. */
export type CopyWhat =
    | { kind: "range"; from: CellAt; to: CellAt }
    | { kind: "row"; row: number }
    | { kind: "column"; column: number }

/**
 * The text of a copy: the cells TAB-separated, a line break between rows, and what the
 * note says. Control characters of a cell are already a space (and are cleaned again).
 *
 * @param cells - the text of the sheet.
 * @param what - what to copy.
 * @returns the text, the note (`copied A1:B2 (4 cells)`) or the refusal.
 */
export function copyText(
    cells: readonly string[][],
    what: CopyWhat,
): { text: string; note: string } | { error: string } {
    const rows = cells.length
    const columns = cells[0]?.length ?? 0
    const [r0, r1, c0, c1, label] =
        what.kind === "row"
            ? [what.row, what.row, 0, columns - 1, `row ${what.row + 1}`]
            : what.kind === "column"
                ? [
                    0,
                    rows - 1,
                    what.column,
                    what.column,
                    `column ${columnLabel(what.column)}`,
                ]
                : [
                    Math.min(what.from.row, what.to.row),
                    Math.max(what.from.row, what.to.row),
                    Math.min(what.from.column, what.to.column),
                    Math.max(what.from.column, what.to.column),
                    "",
                ]
    const lines: string[] = []
    for (let r = r0; r <= r1; r++) {
        const line: string[] = []
        for (let c = c0; c <= c1; c++) line.push(cleanText(cells[r]?.[c] ?? ""))
        lines.push(line.join("\t"))
    }
    const text = lines.join("\n")
    if (Buffer.byteLength(text) > COPY_LIMIT)
        return { error: `too much to copy (${COPY_LIMIT / 1024} KB at most)` }
    const count = (r1 - r0 + 1) * (c1 - c0 + 1)
    const name =
        label ||
        (count === 1 ? cellRef(r0, c0) : `${cellRef(r0, c0)}:${cellRef(r1, c1)}`)
    return { text, note: `copied ${name} (${count} ${count === 1 ? "cell" : "cells"})` }
}

/**
 * The terminal sequence that puts a text on the clipboard (OSC 52, which also works
 * over SSH).
 *
 * @param text - the text.
 * @returns the sequence.
 */
export const clipboardSequence = (text: string): string =>
    `\x1b]52;c;${Buffer.from(text, "utf-8").toString("base64")}\x07`
