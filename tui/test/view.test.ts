// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/view.ts: the sheets, the plots, the pager, search, jump and copy.

import assert from "node:assert/strict"
import { readFileSync, statSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import * as XLSX from "xlsx"
import {
    buildSheet,
    COPY_LIMIT,
    cellDisplay,
    cellRef,
    clampTop,
    clipboardSequence,
    columnLabel,
    copyText,
    expandTabs,
    findCells,
    firstShown,
    fitCount,
    lastTop,
    looksNumeric,
    matchFrom,
    matchIndex,
    matchStep,
    openWorkbook,
    pagerLines,
    pagerStatus,
    pageTop,
    parseJump,
    pickPlotFile,
    plotWidth,
    shownCells,
    sliceCells,
    splitPlots,
    stripAnsi,
    VIEWER_LIMITS,
    ViewerFileError,
    type ViewerLimits,
} from "../src/store/view.js"
import { tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. Sheets
// ========================================================================================

/** A workbook of two sheets in a temp folder: `one` has a header. */
function workbook(): string {
    const wb = XLSX.utils.book_new()
    const rows: unknown[][] = [["name", "value"]]
    for (let i = 1; i <= 30; i++) rows.push([`row${i}`, i * 1.5])
    const one = XLSX.utils.aoa_to_sheet(rows)
    one.C2 = { t: "n", v: 3 }
    one["!ref"] = "A1:C31"
    XLSX.utils.book_append_sheet(wb, one, "one")
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([[1, 2], [3, "日本語"]]), "two")
    const path = join(tempDir(), "book.xlsx")
    writeFileSync(path, XLSX.write(wb, { type: "buffer", bookType: "xlsx" }))
    return path
}

test("a workbook has one tab per sheet and parses a sheet when asked", () => {
    const book = openWorkbook(workbook(), "x")
    assert.deepEqual(book.names, ["one", "two"])
    const one = book.sheet(0)
    assert.equal(one.rows, 31)
    assert.equal(one.columns, 3)
    assert.equal(one.header, true)
    assert.equal(one.cells[1]?.[0], "row1")
    assert.equal(one.cells[1]?.[2], "3")
    assert.equal(book.sheet(0), one, "a sheet is kept once read")
    const two = book.sheet(1)
    assert.equal(two.header, false, "a header is text over data")
    assert.equal(two.cells[1]?.[1], "日本語")
    assert.ok((two.widths[1] as number) >= 6, "wide characters count two cells")
})

test("a delimited file is one tab, read as UTF-8", () => {
    const path = join(tempDir(), "t.csv")
    writeFileSync(path, "a,b\n1,日本語\n2,\"x,y\"\n")
    const book = openWorkbook(path, "t.csv")
    assert.deepEqual(book.names, ["t.csv"])
    const s = book.sheet(0)
    assert.equal(s.cells[1]?.[1], "日本語")
    assert.equal(s.cells[2]?.[1], "x,y")
    assert.equal(s.header, true)
})

test("the file is only read: its bytes and times do not change", () => {
    const path = workbook()
    const before = [readFileSync(path).toString("hex"), statSync(path).mtimeMs]
    openWorkbook(path, "x").sheet(1)
    assert.deepEqual([readFileSync(path).toString("hex"), statSync(path).mtimeMs], before)
})

test("a missing, binary or oversize file is a short error", () => {
    assert.throws(() => openWorkbook(join(tempDir(), "nope.xlsx"), "x"), ViewerFileError)
    const bin = join(tempDir(), "b.bin")
    writeFileSync(bin, Buffer.from([1, 0, 2, 0]))
    assert.throws(() => openWorkbook(bin, "b"), /not a table/)
})

test("a sheet cut by the limits says how big it was", () => {
    const max: ViewerLimits = { ...VIEWER_LIMITS, maxRows: 5, maxColumns: 2 }
    const ws = XLSX.utils.aoa_to_sheet(
        Array.from({ length: 20 }, (_, r) => [r, r, r, r]),
    )
    const file = XLSX.write(
        { SheetNames: ["s"], Sheets: { s: ws } },
        { type: "buffer", bookType: "xlsx" },
    )
    const cut = XLSX.read(file, { type: "buffer", sheetRows: 5 })
    const s = buildSheet("s", cut.Sheets.s as XLSX.WorkSheet, max)
    assert.equal(s.rows, 5)
    assert.equal(s.fullRows, 20)
    assert.equal(s.columns, 2)
    assert.equal(s.fullColumns, 4)
    // the cell cap cuts rows too
    const roomy = { ...max, maxRows: 100, maxColumns: 4, maxCells: 12 }
    const capped = buildSheet("s", ws, roomy)
    assert.equal(capped.rows, 3)
    assert.equal(capped.fullRows, 20)
})

test("an empty sheet has no rows", () => {
    const s = buildSheet("e", {}, VIEWER_LIMITS)
    assert.equal(s.rows, 0)
    assert.equal(s.columns, 0)
})

test("control characters in a cell become a space", () => {
    assert.equal(cellDisplay({ w: "a\tb\nc\u001b[31md" }), "a b c [31md")
    assert.equal(cellDisplay({ v: 4 }), "4")
    assert.equal(cellDisplay({}), "")
})

test("column letters and cell references, both ways", () => {
    assert.equal(columnLabel(0), "A")
    assert.equal(columnLabel(25), "Z")
    assert.equal(columnLabel(26), "AA")
    assert.equal(columnLabel(701), "ZZ")
    assert.equal(columnLabel(702), "AAA")
    assert.equal(cellRef(6, 1), "B7")
})

test("what fits: columns from a first one, the first shown follows the cursor", () => {
    const sizes = [10, 10, 10, 10]
    assert.equal(fitCount(sizes, 0, 25), 2)
    assert.equal(fitCount(sizes, 2, 100), 2)
    assert.equal(fitCount([50], 0, 20), 1, "a wide column is cut, not lost")
    assert.equal(firstShown(sizes, 0, 1, 25), 0)
    assert.equal(firstShown(sizes, 0, 3, 25), 2)
    assert.equal(firstShown(sizes, 3, 0, 25), 0)
})

test("numbers are told from text", () => {
    for (const t of ["1", "-2.5", "1e-6", "1,234.5", "12%", "+3"])
        assert.ok(looksNumeric(t), t)
    for (const t of ["", "abc", "B2", "-", "1-2"]) assert.ok(!looksNumeric(t), t)
})

// ========================================================================================
// 2. Plots
// ========================================================================================

const box = (title: string, ...rows: string[]): string =>
    [`   ${title}`, "┌────┐", ...rows.map((r) => `│${r}│`), "└────┘"].join("\n")

test("colour codes and control characters go, the newline stays", () => {
    assert.equal(stripAnsi("\u001b[38;2;1;2;3mab\u001b[0m\r\nc\u0007d"), "ab\ncd")
    assert.equal(stripAnsi("\u001b]52;c;QQ==\u0007x"), "x")
})

test("a plots file is cut into plots with their titles", () => {
    const fit = box("fit (chi2 = 2.4)", "ab  ", "  cd")
    const text = `${fit}\n\n${box("residuals", "xxxx")}\n\n`
    const plots = splitPlots(`\u001b[31m${text}\u001b[0m`)
    assert.equal(plots.length, 2)
    assert.equal(plots[0]?.title, "fit (chi2 = 2.4)")
    assert.equal(plots[1]?.title, "residuals")
    assert.equal(plots[0]?.body.split("\n").length, 5)
})

test("a title is cut at three spaces and the braille blanks are no text", () => {
    const pad = "\u2800".repeat(9)
    const plots = splitPlots(
        `${pad}fit   \u03c7\u00b2 = 0.4${pad}\n┌──┐\n└──┘\n\n`
            + `${pad}\u03c1 (MAP 3)\n┌──┐\n└──┘\n`,
    )
    assert.deepEqual(plots.map((p) => p.title), ["fit", "\u03c1 (MAP 3)"])
    assert.equal(splitPlots(`${pad}\n┌──┐\n└──┘`)[0]?.title, "plot 1")
})

test("a blank line inside a plot does not cut it, a plot with no title is numbered", () => {
    const inner = ["   t", "┌────┐", "│ab  │", "", "│cd  │", "└────┘"].join("\n")
    const plots = splitPlots(`${inner}\n\n┌──┐\n└──┘\n`)
    assert.equal(plots.length, 2)
    assert.equal(plots[0]?.body.split("\n").length, 6)
    assert.equal(plots[1]?.title, "plot 2")
})

test("a text with no plot gives none", () => {
    assert.deepEqual(splitPlots(""), [])
    assert.deepEqual(splitPlots("just words\n\nmore words"), [])
})

test("a window of a line is cut by cells, wide characters never split", () => {
    assert.equal(sliceCells("abcdef", 2, 3), "cde")
    assert.equal(sliceCells("abc", 5, 3), "")
    assert.equal(sliceCells("日本語", 0, 3), "日")
    assert.equal(sliceCells("日本語", 1, 4), " 本")
    assert.equal(plotWidth("ab\n日本語\nc"), 6)
})

// ========================================================================================
// 3. Pager
// ========================================================================================

test("the last top leaves a full last page, and 0 for a text that fits", () => {
    assert.equal(lastTop(100, 20), 80)
    assert.equal(lastTop(20, 20), 0)
    assert.equal(lastTop(5, 20), 0)
    assert.equal(lastTop(0, 20), 0)
    assert.equal(lastTop(10, 0), 9, "a page of no rows is taken as one row")
})

test("clamping keeps the top inside the text", () => {
    assert.equal(clampTop(-5, 100, 20), 0)
    assert.equal(clampTop(50, 100, 20), 50)
    assert.equal(clampTop(500, 100, 20), 80)
})

test("a page turn moves by the rows less the overlap, and stops at both ends", () => {
    // 100 lines, 20 rows, 1 line kept: 19 per turn
    assert.equal(pageTop(0, 100, 20, 1, true), 19)
    assert.equal(pageTop(19, 100, 20, 1, true), 38)
    assert.equal(pageTop(38, 100, 20, 1, false), 19)
    assert.equal(pageTop(5, 100, 20, 1, false), 0, "up stops at the top")
    assert.equal(pageTop(70, 100, 20, 1, true), 80, "down stops at the last page")
    assert.equal(pageTop(80, 100, 20, 1, true), 80)
    // a bigger overlap, and an overlap as big as the page still moves a line
    assert.equal(pageTop(0, 100, 20, 5, true), 15)
    assert.equal(pageTop(0, 100, 20, 20, true), 1)
    assert.equal(pageTop(0, 100, 20, 50, true), 1)
    // a text that fits never moves
    assert.equal(pageTop(0, 10, 20, 1, true), 0)
})

test("paging a whole text visits every line", () => {
    const count = 137
    const rows = 13
    const seen = new Set<number>()
    let top = 0
    for (let turns = 0; turns < 50; turns++) {
        for (let i = top; i < Math.min(count, top + rows); i++) seen.add(i)
        const next = pageTop(top, count, rows, 1, true)
        if (next === top) break
        top = next
    }
    assert.equal(seen.size, count)
})

test("the status line says which lines and how far", () => {
    assert.equal(pagerStatus(0, 130, 20), "lines 1-20 of 130 · 15%")
    assert.equal(pagerStatus(110, 130, 20), "lines 111-130 of 130 · 100%")
    assert.equal(pagerStatus(0, 5, 20), "lines 1-5 of 5 · 100%")
    assert.equal(pagerStatus(0, 0, 20), "empty")
})

test("tabs go to the next stop, by the cells of what came before", () => {
    assert.equal(expandTabs("a\tb", 8), "a       b")
    assert.equal(expandTabs("name     \tvalue", 8), "name            value")
    assert.equal(expandTabs("\tx", 4), "    x")
    assert.equal(expandTabs("ab\t", 4), "ab  ")
    // a wide character is two cells
    assert.equal(expandTabs("狐\tx", 4), "狐  x")
})

test("a text becomes lines without tabs or control characters", () => {
    assert.deepEqual(pagerLines("", 8), [])
    assert.deepEqual(pagerLines("a\nb\n", 8), ["a", "b"], "the final newline is no line")
    assert.deepEqual(pagerLines("a\r\nb\rc", 8), ["a", "b", "c"])
    assert.deepEqual(pagerLines("x\n\ny", 8), ["x", "", "y"], "blank lines stay")
    const cut = pagerLines("a\u001b[31mb", 8)
    assert.deepEqual(cut, ["a [31mb"], "an escape cannot move the cursor")
    assert.deepEqual(pagerLines("k\tv", 8), ["k       v"])
})

test("the plot size shown is the largest that fits, else the smallest", () => {
    const files = [
        { width: 76, rows: 10 },
        { width: 100, rows: 14 },
        { width: 130, rows: 18 },
        { width: 170, rows: 23 },
    ]
    assert.equal(pickPlotFile([], 80, 20), undefined)
    assert.equal(pickPlotFile(files, 76, 10), 0)
    assert.equal(pickPlotFile(files, 100, 13), 0, "the rows do not fit")
    assert.equal(pickPlotFile(files, 100, 14), 1)
    assert.equal(pickPlotFile(files, 129, 40), 1, "the width does not fit")
    assert.equal(pickPlotFile(files, 130, 18), 2)
    assert.equal(pickPlotFile(files, 400, 100), 3)
    assert.equal(pickPlotFile(files, 40, 5), 0, "none fits: the smallest")
    assert.equal(pickPlotFile([...files].reverse(), 40, 5), 3, "whatever the order")
})

// ========================================================================================
// 4. Search, jump, copy, formulas
// ========================================================================================

const grid = [
    ["Name", "Value", "note"],
    ["alpha", "1", "a NAME here"],
    ["beta", "2", ""],
    ["name2", "3", "x"],
]

test("search is case-insensitive, row by row, and wraps with n and shift+n", () => {
    const hits = findCells(grid, "name")
    assert.deepEqual(hits, [
        { row: 0, column: 0 },
        { row: 1, column: 2 },
        { row: 3, column: 0 },
    ])
    assert.deepEqual(findCells(grid, ""), [])
    assert.deepEqual(findCells(grid, "zzz"), [])
    // the first match at or after the cursor, wrapping to the first
    assert.equal(matchFrom(hits, 0, 0), 0)
    assert.equal(matchFrom(hits, 0, 1), 1)
    assert.equal(matchFrom(hits, 1, 2), 1)
    assert.equal(matchFrom(hits, 3, 1), 0)
    assert.equal(matchFrom([], 0, 0), undefined)
    // next and previous, from a match and from a cell that is none
    assert.equal(matchStep(hits, 0, 0, 1), 1)
    assert.equal(matchStep(hits, 3, 0, 1), 0, "next wraps")
    assert.equal(matchStep(hits, 0, 0, -1), 2, "previous wraps")
    assert.equal(matchStep(hits, 2, 1, 1), 2)
    assert.equal(matchStep(hits, 2, 1, -1), 1)
    assert.equal(matchStep([], 0, 0, 1), undefined)
    assert.equal(matchIndex(hits, 1, 2), 1)
    assert.equal(matchIndex(hits, 2, 2), undefined)
})

test("jump reads a cell, a row or a column and refuses what is outside", () => {
    const at = { row: 4, column: 2 }
    assert.deepEqual(parseJump("B7", at, 60, 8), { row: 6, column: 1 })
    assert.deepEqual(parseJump(" b7 ", at, 60, 8), { row: 6, column: 1 })
    assert.deepEqual(parseJump("7", at, 60, 8), { row: 6, column: 2 })
    assert.deepEqual(parseJump("B", at, 60, 8), { row: 4, column: 1 })
    assert.deepEqual(parseJump("AA1", at, 60, 30), { row: 0, column: 26 })
    for (const bad of ["", "7B", "B 7", "$B$7", "B-7", "1.5", "ABCD1"])
        assert.ok("error" in parseJump(bad, at, 60, 8), bad)
    const outside = parseJump("B61", at, 60, 8)
    assert.deepEqual(outside, { error: "outside the sheet (A1:H60)" })
    assert.ok("error" in parseJump("I1", at, 60, 8))
    assert.ok("error" in parseJump("0", at, 60, 8))
})

test("a copy is TSV by range, row or column, with the note that says what", () => {
    const out = (what: Parameters<typeof copyText>[1]) => copyText(grid, what)
    assert.deepEqual(
        out({ kind: "range", from: { row: 1, column: 1 }, to: { row: 0, column: 0 } }),
        { text: "Name\tValue\nalpha\t1", note: "copied A1:B2 (4 cells)" },
    )
    const beta = { row: 2, column: 0 }
    assert.deepEqual(out({ kind: "range", from: beta, to: beta }), {
        text: "beta",
        note: "copied A3 (1 cell)",
    })
    assert.deepEqual(out({ kind: "row", row: 1 }), {
        text: "alpha\t1\ta NAME here",
        note: "copied row 2 (3 cells)",
    })
    assert.deepEqual(out({ kind: "column", column: 2 }), {
        text: "note\na NAME here\n\nx",
        note: "copied column C (4 cells)",
    })
})

test("a copy cleans control characters and refuses over 70 KB", () => {
    const dirty = [["a\tb\x1b]52;c;x\x07", "ok\nline"]]
    const out = copyText(dirty, { kind: "row", row: 0 })
    assert.ok("text" in out)
    assert.equal(out.text, "a b ]52;c;x \tok line")
    assert.ok([...out.text].every((ch) => ch === "\t" || ch >= " "))
    const big = [["x".repeat(COPY_LIMIT)], ["y"]]
    assert.deepEqual(copyText(big, { kind: "column", column: 0 }), {
        error: "too much to copy (70 KB at most)",
    })
    const fits = [["x".repeat(COPY_LIMIT)]]
    assert.ok("text" in copyText(fits, { kind: "row", row: 0 }))
})

test("the clipboard sequence is OSC 52 with the text in base64", () => {
    assert.equal(clipboardSequence("a\tb\nc"), "\x1b]52;c;YQliCmM=\x07")
    const base64 = Buffer.from("日本").toString("base64")
    assert.equal(clipboardSequence("日本"), `\x1b]52;c;${base64}\x07`)
})

test("formulas are read from a workbook and shown instead of the values", () => {
    const wb = XLSX.utils.book_new()
    const ws = XLSX.utils.aoa_to_sheet([[1], [2], [0]])
    ws.A3 = { t: "n", v: 3, f: "SUM(A1:A2)" }
    XLSX.utils.book_append_sheet(wb, ws, "f")
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([[1, 2]]), "plain")
    const path = join(tempDir(), "formulas.xlsx")
    writeFileSync(path, XLSX.write(wb, { type: "buffer", bookType: "xlsx" }))
    const book = openWorkbook(path, "x")
    const sheet = book.sheet(0)
    assert.equal(sheet.cells[2]?.[0], "3")
    assert.equal(sheet.formulas?.[2]?.[0], "=SUM(A1:A2)")
    assert.deepEqual(shownCells(sheet, true)[2], ["=SUM(A1:A2)"])
    const plainValue = shownCells(sheet, true)[0]
    assert.deepEqual(plainValue, ["1"], "a cell without a formula shows its value")
    assert.equal(shownCells(sheet, false), sheet.cells)
    assert.equal(book.sheet(1).formulas, undefined, "no formulas, no toggle")
    const csv = join(tempDir(), "t.csv")
    writeFileSync(csv, "a,b\n1,2\n")
    assert.equal(openWorkbook(csv, "t").sheet(0).formulas, undefined)
})
