// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/data.ts: reading a table, and the data files of a project.
//
// Contents:
//   1. Table parse
//   2. Project data files

import assert from "node:assert/strict"
import { existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import * as XLSX from "xlsx"
import { numberText } from "../src/core/terminal.js"
import {
    dataIsReady,
    dataJsonFile,
    dataTsvFile,
    makeMapping,
    parseDataText,
    readDataInfo,
    resetData,
    setEnergy,
    setUnits,
    unitLabel,
    writeData,
} from "../src/store/data.js"
import {
    DataFileError,
    type DataPoints,
    DEFAULT_PARSE_OPTIONS,
    extractCurve,
    guessColumns,
    loadSource,
    type ParseOptions,
    parseTable,
    resolveColumn,
    resolveColumns,
    rowsOf,
    sheetNames,
    suggestColumns,
    textSource,
} from "../src/store/data-table.js"
import { ProjectGoneError } from "../src/store/projects.js"
import { tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. Table parse
// ========================================================================================

/** Twelve points: q 0.01 .. 0.12, I falling, sigma 0.01. */
const rows = Array.from({ length: 12 }, (_, k) => [0.01 * (k + 1), 100 - k, 0.01])
const body = (sep: string): string => rows.map((r) => r.join(sep)).join("\n")
const opts = (change: Partial<ParseOptions> = {}): ParseOptions => ({
    ...DEFAULT_PARSE_OPTIONS,
    ...change,
})
const parse = (text: string, change: Partial<ParseOptions> = {}) =>
    parseTable(textSource(text), opts(change))

/** The first three columns, as the extraction wants them. */
const first3 = { q: 1, i: 2, sigma: 3 }

/** The text of the error of an extraction. */
const failure = (run: () => unknown): string => {
    try {
        run()
    } catch (error) {
        assert.ok(error instanceof DataFileError)
        return error.message
    }
    return assert.fail("no error")
}

test("table: separators are sniffed, each can be forced", () => {
    for (const [sep, name] of [
        ["\t", "tab"],
        [",", "comma"],
        [";", "semicolon"],
        ["   ", "whitespace"],
    ] as const) {
        const table = parse(body(sep))
        assert.equal(table.separator, name)
        assert.equal(table.rows.length, 12)
        assert.deepEqual(table.rows[0]?.cells, ["0.01", "100", "0.01"])
    }
    // a forced separator wins over the sniffed one
    assert.equal(parse(body(","), { separator: "semicolon" }).rows[0]?.cells.length, 1)
    // free-text lines with a stray comma do not decide
    const text = `Sample: lysozyme, 5 mg/ml\nBuffer: Tris, pH 7\n${body("\t")}`
    assert.equal(parse(text).separator, "tab")
    // quotes are dropped, CRLF and a BOM do not matter
    const quoted = `﻿"q","I","err"\r\n${body(",").replaceAll("\n", "\r\n")}`
    const table = parse(quoted)
    assert.deepEqual(table.names, ["q", "I", "err"])
    assert.equal(table.rows.length, 12)
})

test("table: pipe, any character, runs of spaces, multi-character separators", () => {
    // SheetJS sniffs the pipe by itself
    const pipe = parse(body("|"))
    assert.equal(pipe.separator, "pipe")
    assert.deepEqual(pipe.rows[0]?.cells, ["0.01", "100", "0.01"])
    // a character SheetJS does not sniff, typed by the user
    for (const sep of ["~", "^", "#x", "::", " | ", "\\t"]) {
        const real = sep === "\\t" ? "\t" : sep
        const table = parse(body(real), { separator: sep })
        assert.deepEqual(table.rows[0]?.cells, ["0.01", "100", "0.01"], sep)
        assert.equal(table.rows.length, 12, sep)
    }
    assert.equal(parse(body("~"), { separator: "~" }).separator, "~")
    // runs of spaces: SheetJS finds one column and the whitespace path takes over
    const runs = parse(rows.map((r) => `  ${r.join("     ")}  `).join("\n"))
    assert.equal(runs.separator, "whitespace")
    assert.deepEqual(runs.rows[3]?.cells, ["0.04", "97", "0.01"])
    // `space` spelled out means runs of blanks too
    assert.deepEqual(parse(body("   "), { separator: "space" }).rows[0]?.cells.length, 3)
    // an unsniffable file under `auto` stays one column: the user types the separator
    assert.equal(parse(body("~")).rows[0]?.cells.length, 1)
})

test("table: comment lines, blank lines, skip n rows", () => {
    const text = `# a\n% b\n! c\n; d\n\n${body(",")}\n`
    assert.equal(parse(text).rows.length, 12)
    assert.equal(parse(text).rows[0]?.line, 6, "line numbers are the file's own")
    // comments off: the '#' lines are header text above the data, never rows
    assert.equal(parse(text, { comments: false }).rows.length, 12)
    // skip n counts every line, blanks included
    const free = `Sample: x\nSASBDB entry\n\nq I sigma\n${body("  ")}`
    const skipped = parse(free, { skipRows: 3 })
    assert.deepEqual(skipped.names, ["q", "I", "sigma"])
    assert.equal(skipped.header, true)
    assert.equal(skipped.rows[0]?.line, 5)
    assert.equal(skipped.rows.length, 12)
})

test("table: header auto, yes, no and the names", () => {
    const text = `q,I,err\n${body(",")}`
    const auto = parse(text)
    assert.equal(auto.header, true)
    assert.deepEqual(auto.names, ["q", "I", "err"])
    assert.equal(auto.rows.length, 12)
    const noHeader = parse(body(","))
    assert.equal(noHeader.header, false)
    assert.deepEqual(noHeader.names, ["col:1", "col:2", "col:3"])
    // no: the text above the data is header text and not a row; yes: with no text above,
    // the first row of numbers is the header
    assert.equal(parse(text, { header: "no" }).rows.length, 12)
    const forced = parse(body(","), { header: "yes" })
    assert.deepEqual(forced.names, ["0.01", "100", "0.01"])
    assert.equal(forced.rows.length, 11)
    // an empty header cell keeps its col:N name
    assert.deepEqual(parse(`q,,err\n${body(",")}`).names, ["q", "col:2", "err"])
})

test("table: a column is a number, col:N or a header name, any case", () => {
    const names = ["q (1/nm)", "Intensity", "err"]
    assert.deepEqual(resolveColumn("2", names), { column: 2 })
    assert.deepEqual(resolveColumn("col:3", names), { column: 3 })
    assert.deepEqual(resolveColumn("COL:1", names), { column: 1 })
    assert.deepEqual(resolveColumn(" intensity ", names), { column: 2 })
    assert.deepEqual(resolveColumn("q (1/NM)", names), { column: 1 })
    assert.match((resolveColumn("4", names) as { error: string }).error, /no column 4/)
    const foo = resolveColumn("foo", names) as { error: string }
    assert.match(foo.error, /no column "foo"/)
    assert.ok("error" in resolveColumn("", names))
    const choice = resolveColumns({ q: "q (1/nm)", i: "2", sigma: "col:3" }, names)
    assert.deepEqual(choice.i, { spec: "2", column: 2 })
    assert.match(
        failure(() => resolveColumns({ q: "1", i: "2", sigma: "x" }, names)),
        /^sigma: no column "x"/,
    )
    assert.match(
        failure(() => resolveColumns({ q: "1", i: "1", sigma: "3" }, names)),
        /three different columns/,
    )
})

test("table: the guess uses names first, then the order", () => {
    assert.deepEqual(guessColumns(["q", "I(q)", "dI"], true), {
        q: "q",
        i: "I(q)",
        sigma: "dI",
    })
    assert.deepEqual(guessColumns(["Sigma", "Q", "Intensity"], true), {
        q: "Q",
        i: "Intensity",
        sigma: "Sigma",
    })
    assert.deepEqual(guessColumns(["s", "I", "err_I", "x"], true), {
        q: "s",
        i: "I",
        sigma: "err_I",
    })
    assert.deepEqual(guessColumns(["col:1", "col:2", "col:3"], false), {
        q: "col:1",
        i: "col:2",
        sigma: "col:3",
    })
    // a name it knows, the rest by position
    assert.deepEqual(guessColumns(["a", "b", "error"], true), {
        q: "a",
        i: "b",
        sigma: "error",
    })
    // no third column: sigma has no guess and is asked for
    assert.equal(guessColumns(["col:1", "col:2"], false).sigma, "")
})

test("table: the first bad cell stops the extraction with line and column", () => {
    const table = parse(`q,I,err\n${body(",")}`)
    const curve = extractCurve(table, { q: 1, i: 2, sigma: 3 })
    assert.equal(curve.q.length, 12)
    assert.deepEqual(curve.sigma, rows.map((r) => r[2]))
    // another order of the columns
    const swappedRows = rows.map((r) => [r[1], r[2], r[0]].join(","))
    const swapped = parse(`I,err,q\n${swappedRows.join("\n")}`)
    assert.deepEqual(extractCurve(swapped, { q: 3, i: 1, sigma: 2 }).q, curve.q)
    // a bad row in a chosen column names the line (the file's) and the column's name
    const lines = body(",").split("\n")
    lines[4] = "0.05,abc,0.01"
    const bad = parse(`q,I,err\n${lines.join("\n")}`)
    assert.equal(
        failure(() => extractCurve(bad, { q: 1, i: 2, sigma: 3 })),
        'line 6, column I: "abc" is no number',
    )
    // the wrong column (the text one) is caught the same way: nothing is skipped
    const wrong = parse(`n,q,I,err\n${rows.map((r) => ["pt", ...r].join(",")).join("\n")}`)
    assert.match(
        failure(() => extractCurve(wrong, { q: 1, i: 3, sigma: 4 })),
        /^line 2, column n: "pt" is no number/,
    )
    // a short row has no value
    lines[4] = "0.05,7"
    const short = parse(`q,I,err\n${lines.join("\n")}`)
    assert.equal(
        failure(() => extractCurve(short, { q: 1, i: 2, sigma: 3 })),
        "line 6, column err: no value",
    )
    // the checks of the curve
    lines[4] = "0.03,5,0.01"
    assert.equal(
        failure(() => extractCurve(parse(lines.join("\n")), { q: 1, i: 2, sigma: 3 })),
        "line 5: q must increase",
    )
    // the same q with other values is kept (q stored to three digits repeats)
    lines[4] = `${lines[3]?.split(",")[0]},7,0.01`
    const repeatedQ = extractCurve(parse(lines.join("\n")), { q: 1, i: 2, sigma: 3 })
    assert.equal(repeatedQ.q[3], repeatedQ.q[4])
    assert.equal(repeatedQ.i[4], 7)
    lines[4] = "0.03,5,0.01"
    // a row with q not above 0 is dropped and counted, not an error
    lines[4] = "-1,5,0.01"
    const dropped = extractCurve(parse(lines.join("\n")), { q: 1, i: 2, sigma: 3 })
    assert.equal(dropped.dropped, 1)
    assert.equal(dropped.q.length, rows.length - 1)
    assert.ok(dropped.q.every((q) => q > 0))
    // a row with sigma not above 0 is dropped too
    lines[4] = "0.05,5,0"
    assert.equal(
        extractCurve(parse(lines.join("\n")), { q: 1, i: 2, sigma: 3 }).dropped,
        1,
    )
})

test("table: too few rows is an error, an empty file too", () => {
    const few = parse(body(",").split("\n").slice(0, 2).join("\n"))
    assert.match(failure(() => extractCurve(few, first3)), /only 2 points: need 3/)
    const three = parse(body(",").split("\n").slice(0, 3).join("\n"))
    assert.equal(extractCurve(three, first3).q.length, 3)
    const none = parse("# nothing\n")
    assert.equal(none.rows.length, 0)
    assert.match(failure(() => extractCurve(none, first3)), /only 0 points/)
})

test("table: the preview limit keeps few rows but the header", () => {
    const table = parseTable(textSource(`q,I,err\n${body(",")}`), opts(), 3)
    assert.equal(table.rows.length, 3)
    assert.deepEqual(table.names, ["q", "I", "err"])
})

test("table: an .xlsx goes through the same path (first sheet, any name)", () => {
    const dir = tempDir()
    const sheet = XLSX.utils.aoa_to_sheet([
        ["Sample", "lysozyme"],
        ["q", "I", "sigma"],
        ...rows,
    ])
    const other = XLSX.utils.aoa_to_sheet([["x"]])
    const book = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(book, sheet, "curve")
    XLSX.utils.book_append_sheet(book, other, "other")
    const file = join(dir, "curve.dat")
    writeFileSync(file, XLSX.write(book, { type: "buffer", bookType: "xlsx" }))
    const source = loadSource(file)
    assert.equal(source.kind, "workbook")
    // the title row is header text: the names are the row with three cells
    assert.deepEqual(parseTable(source, opts()).names, ["q", "I", "sigma"])
    const table = parseTable(source, opts({ skipRows: 1 }))
    assert.deepEqual(table.names, ["q", "I", "sigma"])
    const curve = extractCurve(table, { q: 1, i: 2, sigma: 3 })
    assert.deepEqual(curve.q, rows.map((r) => r[0]))
    // a bad row is named by its sheet row
    const bad = XLSX.utils.aoa_to_sheet([["q", "I", "sigma"], ...rows, [0.05, 1, 1]])
    const wb = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(wb, bad, "s")
    writeFileSync(file, XLSX.write(wb, { type: "buffer", bookType: "xlsx" }))
    assert.match(
        failure(() =>
            extractCurve(parseTable(loadSource(file), opts()), { q: 1, i: 2, sigma: 3 }),
        ),
        /^row 14: q must increase/,
    )
    // a file that only starts like a workbook gives no curve
    writeFileSync(file, "PK not a zip")
    const fake = parseTable(loadSource(file), opts())
    assert.match(failure(() => extractCurve(fake, { q: 1, i: 2, sigma: 3 })), /only/)
})

test("table: binary, old .xls and missing files are refused", () => {
    const dir = tempDir()
    const file = join(dir, "b.dat")
    writeFileSync(file, Buffer.from([1, 2, 0, 3]))
    assert.throws(() => loadSource(file), /not a text file/)
    // a compound file that is no workbook gives no curve (an error now or at import)
    writeFileSync(file, Buffer.from("d0cf11e000", "hex"))
    assert.throws(() => extractCurve(parseTable(loadSource(file), opts()), first3))
    assert.throws(() => loadSource(join(dir, "none.dat")), /cannot read/)
})

test("table: a SASBDB-style .dat (free text, then q I sigma) imports with skip", () => {
    const dir = tempDir()
    const file = join(dir, "sasbdb.dat")
    writeFileSync(
        file,
        `Sample: lysozyme in buffer, 5 mg/ml\nSASBDB: SASDXX1\nq I sigma\n${body("  ")}\n`,
    )
    const source = loadSource(file)
    const table = parseTable(source, opts({ skipRows: 2 }))
    assert.deepEqual(table.names, ["q", "I", "sigma"])
    const guess = guessColumns(table.names, table.header)
    const choice = resolveColumns(guess, table.names)
    const columns = { q: choice.q.column, i: choice.i.column, sigma: choice.sigma.column }
    assert.equal(extractCurve(table, columns).q.length, 12)
})

test("table: typing narrows the column suggestions, starts first", () => {
    const table = parse(`q,I(q),sigma\n${body(",")}`)
    assert.deepEqual(
        suggestColumns(table, "").map((s) => s.label),
        ["q", "I(q)", "sigma"],
    )
    // `i` is in I(q) and in sigma; the name that starts with it comes first
    assert.deepEqual(
        suggestColumns(table, "i").map((s) => s.label),
        ["I(q)", "sigma"],
    )
    assert.deepEqual(
        suggestColumns(table, "col:3").map((s) => s.label),
        ["sigma"],
    )
    assert.equal(suggestColumns(table, "I(q)")[0]?.tag, "col:2  100")
    assert.deepEqual(suggestColumns(table, "zzz"), [])
    // without a header the names are col:N and the tag is the first value
    const plain = parse(body(","))
    assert.deepEqual(
        suggestColumns(plain, "2").map((s) => `${s.label} ${s.tag}`),
        ["col:2 100"],
    )
})

/** Writes a workbook of sheets of rows with a SheetJS book type, returns the path. */
const writeBook = (
    name: string,
    bookType: XLSX.BookType,
    sheets: [string, unknown[][]][],
): string => {
    const book = XLSX.utils.book_new()
    for (const [title, aoa] of sheets)
        XLSX.utils.book_append_sheet(book, XLSX.utils.aoa_to_sheet(aoa), title)
    const file = join(tempDir(), name)
    writeFileSync(file, XLSX.write(book, { type: "buffer", bookType }))
    return file
}

test("table: .xls, .ods, .xlsb and .xlsm are read by content, any name", () => {
    for (const [type, name] of [
        ["xls", "curve.dat"],
        ["ods", "curve.txt"],
        ["xlsb", "curve.csv"],
        ["xlsm", "curve.xlsx"],
        ["fods", "curve.fods"],
    ] as const) {
        const file = writeBook(name, type, [["curve", [["q", "I", "sigma"], ...rows]]])
        const source = loadSource(file)
        assert.equal(source.kind, "workbook", type)
        const table = parseTable(source, opts())
        assert.deepEqual(table.names, ["q", "I", "sigma"], type)
        assert.deepEqual(extractCurve(table, first3).q, rows.map((r) => r[0]), type)
    }
})

test("table: several sheets: the first non-empty one, then the chosen", () => {
    const file = writeBook("two.ods", "ods", [
        ["empty", [[]]],
        ["first", [["a", "b", "c"], ...rows]],
        ["second", [["q", "I", "sigma"], ...rows.map((r) => [r[0] * 2, r[1], r[2]])]],
    ])
    const source = loadSource(file)
    assert.deepEqual(sheetNames(source), ["first", "second"])
    assert.equal(parseTable(source, opts()).sheet, "first")
    const second = parseTable(source, opts({ sheet: "second" }))
    assert.equal(second.sheet, "second")
    assert.deepEqual(second.names, ["q", "I", "sigma"])
    assert.equal(extractCurve(second, first3).q[0], 0.02)
    // an unknown sheet name falls back to the first
    assert.equal(parseTable(source, opts({ sheet: "gone" })).sheet, "first")
    assert.equal(rowsOf(source, "second").length, 13)
})

// ========================================================================================
// 1b. The deposited curves of the fitting tests (test/fixtures/experiments), read in place
// ========================================================================================

const EXPERIMENTS = fileURLToPath(
    new URL("../../test/fixtures/experiments", import.meta.url),
)

/**
 * The 11 entries with no `experimental_data/<ID>.dat`: the file their script reads the
 * curve from, and the column its script takes as sigma (`readdlm(...; skipstart)`).
 */
const FIT_FILES: Record<string, [file: string, sigma: number]> = {
    SASDF42: ["SASDF42_fit1.fit", 3],
    SASDJ62: ["SASDJ62_fit1.dat", 4],
    SASDJ72: ["SASDJ72_fit1.fit", 3],
    SASDMZ9: ["SASDMZ9_fit1.dat", 4],
    SASDN32: ["SASDN32_fit1.dat", 4],
    SASDV94: ["SASDV94_fit1.fit", 3],
    SASDWZ9: ["SASDWZ9_fit1.fit", 3],
    SASDX52: ["SASDX52_fit1.fit", 3],
    SASDYW6: ["SASDYW6_fit2.fit", 3],
    SASDZC6: ["SASDZC6_fit1.dat", 4],
    SASDZZ9: ["SASDZZ9_fit1.fit", 3],
}

/**
 * The scripts' own reading (`_read_curve` in test/fitting_tests/common.jl): every line
 * with numbers in columns 1, 2 and `sigma` (commas read as blanks), and the line of the
 * first one.
 */
function scriptRead(text: string, sigma: number) {
    const out: { line: number; cells: string[] }[] = []
    for (const [k, line] of text.split(/\r?\n/).entries()) {
        const t = line.replaceAll(",", " ").trim().split(/\s+/)
        const cells = [t[0], t[1], t[sigma - 1]]
        const numeric = cells.every((c) => numberText(c ?? "") !== undefined)
        if (t.length >= Math.max(3, sigma) && numeric)
            out.push({ line: k + 1, cells: cells as string[] })
    }
    return out
}

test("real curves: every deposited file is detected, auto, as the scripts read it", () => {
    const ids = readdirSync(EXPERIMENTS).sort()
    // every fixture folder is read; the floor guards against a folder that went missing
    assert.ok(ids.length >= 57, `${ids.length} fixture folders`)
    const separators = new Set<string>()
    for (const id of ids) {
        const [name, sigma] = FIT_FILES[id] ?? [`experimental_data/${id}.dat`, 3]
        const file = join(EXPERIMENTS, id, name)
        const text = readFileSync(file, "utf-8")
        const want = scriptRead(text, sigma)
        const table = parseTable(loadSource(file), DEFAULT_PARSE_OPTIONS)
        const first = want[0] as { line: number; cells: string[] }
        const last = want[want.length - 1] as typeof first
        const at = `${id} ${name}`
        const tabbed = text.split(/\r?\n/)[first.line - 1]?.includes("\t")
        assert.equal(table.separator, tabbed ? "tab" : "whitespace", at)
        assert.equal(table.rows[0]?.line, first.line, `${at}: data start`)
        assert.equal(table.rows.length, want.length, `${at}: points`)
        const pick = (cells: string[] | undefined) =>
            [cells?.[0], cells?.[1], cells?.[sigma - 1]].map(Number)
        assert.deepEqual(pick(table.rows[0]?.cells), first.cells.map(Number), at)
        const end = pick(table.rows[table.rows.length - 1]?.cells)
        assert.deepEqual(end, last.cells.map(Number), at)
        // q increasing and above 0, sigma above 0, at least 3 points: the importer's checks
        const columns = { q: 1, i: 2, sigma }
        // every real file imports: rows with q or sigma not above 0 and rows repeated
        // exactly (SASDCQ2 has one) are dropped and counted
        const curve = extractCurve(table, columns)
        const kept = want.filter((r) => Number(r.cells[0]) > 0 && Number(r.cells[2]) > 0)
        let repeated = 0
        for (const [k, r] of kept.entries())
            if (k > 0 && r.cells.join(" ") === kept[k - 1]?.cells.join(" ")) repeated++
        const dropped = want.length - kept.length + repeated
        assert.equal(curve.dropped, dropped, at)
        assert.equal(curve.q.length, want.length - dropped, at)
        if (id === "SASDCQ2") assert.ok(repeated >= 1, "the repeated row of SASDCQ2")
        separators.add(table.separator)
    }
    assert.deepEqual([...separators].sort(), ["tab", "whitespace"])
})

// No real fixture has a decimal comma, a `D` exponent, a quoted header or a comment header
// (the SASBDB files are all tab or blank separated): a few tiny inline texts stand in.
test("table: decimal comma, D exponents, quoted header, comment header", () => {
    const comma = parse("0,01;1,5E+2;0,1\n0,02;1,4E+2;0,1\n0,03;1,3D+2;0,1\n")
    assert.equal(comma.separator, "semicolon")
    assert.deepEqual(comma.rows[2]?.cells, ["0.03", "1.3e+2", "0.1"])
    const quoted = parse(
        '"q","I(q), a.u.","err"\n0.01,5,1\n0.02,4,1\n0.03,3,1\nend of file\n',
    )
    assert.deepEqual(quoted.names, ["q", "I(q), a.u.", "err"])
    assert.equal(quoted.rows.length, 3, "a footer line ends the data")
    const hash = parse("# Sample, 5 mg/ml\n#  q  I  err\n0.01 5 1\n0.02 4 1\n0.03 3 1\n")
    assert.deepEqual(hash.names, ["q", "I", "err"])
    assert.equal(hash.rows[0]?.line, 3)
})

// ========================================================================================
// 2. Project data files
// ========================================================================================

/** The rows as text with a separator. */
const textOf = (sep: string, extra = ""): string =>
    `${extra}${rows.map((r) => r.join(sep)).join("\n")}\n`

const expected: DataPoints = {
    q: rows.map((r) => r[0] as number),
    i: rows.map((r) => r[1] as number),
    sigma: rows.map((r) => r[2] as number),
    dropped: 0,
}

const textFailure = (text: string): string => {
    try {
        parseDataText(text)
    } catch (error) {
        assert.ok(error instanceof DataFileError)
        return error.message
    }
    return assert.fail("no error")
}

test("data: every separator is sniffed, whitespace runs too", () => {
    for (const sep of ["\t", ",", ";", "|", "   ", " "])
        assert.deepEqual(parseDataText(textOf(sep)), expected, JSON.stringify(sep))
    assert.deepEqual(parseDataText(textOf("\t").replaceAll("\n", "\r\n")), expected)
})

test("data: comments, blank lines, a header and extra columns", () => {
    const text = textOf(",", "# measured at the beamline\n\nq,I,sigma\n# more\n")
    assert.deepEqual(parseDataText(text), expected)
    const wide = rows.map((r) => [...r, 9, 9].join("\t")).join("\n")
    assert.deepEqual(parseDataText(`q (1/nm)\tI\terr\tx\ty\n${wide}`), expected)
    assert.deepEqual(parseDataText(`# c\nq I sigma\n${textOf("  ")}`), expected)
})

test("data: bad files give a short message that names the line and the column", () => {
    // the first row that is not numbers is a header, so the bad cell is on line 2
    const abc = textOf(",").split("\n")
    abc[1] = "0.02,99,abc"
    assert.match(textFailure(abc.join("\n")), /^line 2, column col:3: "abc"/)
    const two = textOf(",").split("\n").slice(0, 2).join("\n")
    assert.match(textFailure(two), /only 2 points: need 3/)
    const twoColumns = rows.map((r) => r.slice(0, 2).join(",")).join("\n")
    assert.match(textFailure(twoColumns), /need 3 col/)
    const lines = textOf(",").split("\n")
    lines[4] = "0.03,5,0.01"
    assert.equal(textFailure(lines.join("\n")), "line 5: q must increase")
    lines[4] = "0,5,0.01"
    assert.equal(parseDataText(`# c\n${lines.join("\n")}`).dropped, 1)
    lines[4] = "0.05,5,0"
    assert.equal(parseDataText(`# c\n${lines.join("\n")}`).dropped, 1)
    lines[4] = "0.05,NaN,0.1"
    assert.match(textFailure(lines.join("\n")), /^line 5, column col:2: "NaN" is no number/)
    lines[4] = "0.05,,0.1"
    assert.match(textFailure(lines.join("\n")), /^line 5, column col:2: no value/)
    for (const text of ["", "# only\n", "q,I,sigma\n"])
        assert.ok(textFailure(text).length < 60)
    assert.ok(textFailure("hello").length < 60)
})

test("data: writeData makes a clean TSV and data.json last", () => {
    const dir = tempDir()
    const odd: DataPoints = { q: [], i: [], sigma: [], dropped: 0 }
    for (let k = 1; k <= 10; k++) {
        odd.q.push(k / 3)
        odd.i.push(1e-7 * k)
        odd.sigma.push(0.1)
    }
    const info = writeData(dir, odd, "/some/where/My Curve.csv", "nm-1", 12400)
    assert.deepEqual(info, {
        units: "nm-1", energy: 12400, source: "My Curve.csv", points: 10,
        energy_unit: "nm",
    })
    const text = readFileSync(dataTsvFile(dir), "utf-8")
    const lines = text.trimEnd().split("\n")
    assert.equal(lines.length, 10)
    const cell = "[-+0-9.e]+"
    for (const line of lines) assert.match(line, new RegExp(`^${cell}\t${cell}\t${cell}$`))
    assert.equal(lines[2], `${odd.q[2]}\t${odd.i[2]}\t0.1`)
    assert.deepEqual(JSON.parse(readFileSync(dataJsonFile(dir), "utf-8")), info)
    const status = readDataInfo(dir)
    assert.equal(status?.kind, "ok")
    assert.ok(dataIsReady(dir))
    // the table reads back as the same numbers
    assert.deepEqual(parseDataText(text), odd)
})

test("data: units and energy edit data.json only", () => {
    const dir = tempDir()
    writeData(dir, expected, "c.dat", "A-1")
    assert.equal(dataIsReady(dir), false, "no energy yet")
    const before = readFileSync(dataTsvFile(dir))
    setUnits(dir, "nm-1")
    setEnergy(dir, 8048, "eV")
    assert.deepEqual(readFileSync(dataTsvFile(dir)), before)
    const status = readDataInfo(dir)
    assert.equal(status?.kind === "ok" && status.info.units, "nm-1")
    assert.equal(status?.kind === "ok" && status.info.energy, 8048)
    assert.ok(dataIsReady(dir))
    assert.throws(() => setEnergy(dir, 0, "eV"), DataFileError)
    assert.throws(() => setEnergy(dir, Number.NaN, "eV"), DataFileError)
    assert.throws(() => setEnergy(dir, -5, "eV"), DataFileError)
    // no leftovers
    assert.equal(existsSync(`${dataJsonFile(dir)}.lock`), false)
    const empty = tempDir()
    assert.throws(() => setUnits(empty, "nm-1"), /no data yet/)
    assert.equal(readDataInfo(empty), undefined)
})

test("data: the unit labels have the right superscripts", () => {
    assert.equal(unitLabel("nm-1"), "nm⁻¹")
    assert.equal(unitLabel("A-1"), "Å⁻¹")
    assert.equal(unitLabel("A-1").codePointAt(0), 0xc5)
})

test("data: a vanished project is an error with a note, nothing is recreated", () => {
    const dir = join(tempDir(), "gone")
    assert.throws(() => writeData(dir, expected, "c.dat", "A-1"), ProjectGoneError)
    assert.equal(existsSync(dir), false)
    const live = tempDir()
    writeData(live, expected, "c.dat", "A-1", 1000)
    rmSync(live, { recursive: true })
    assert.throws(() => setUnits(live, "nm-1"), ProjectGoneError)
    assert.throws(() => resetData(live), ProjectGoneError)
    assert.equal(readDataInfo(live), undefined)
    assert.equal(dataIsReady(live), false)
    assert.equal(existsSync(live), false)
})

test("data: garbled files are unusable, never overwritten, reset keeps them", () => {
    const dir = tempDir()
    writeData(dir, expected, "c.dat", "A-1", 1000)
    writeFileSync(dataJsonFile(dir), "{ not json")
    assert.equal(readDataInfo(dir)?.kind, "unusable")
    assert.equal(dataIsReady(dir), false)
    assert.throws(() => writeData(dir, expected, "d.dat", "A-1"), /unusable/)
    assert.throws(() => setUnits(dir, "nm-1"), /unusable/)
    assert.equal(readFileSync(dataJsonFile(dir), "utf-8"), "{ not json")
    for (const bad of [
        '{"units":"mm","energy":1,"source":"s","points":12}',
        '{"units":"A-1","energy":-1,"source":"s","points":12}',
        '{"units":"A-1","energy":1,"source":3,"points":12}',
        "[]",
    ]) {
        writeFileSync(dataJsonFile(dir), bad)
        assert.equal(readDataInfo(dir)?.kind, "unusable", bad)
    }
    resetData(dir)
    assert.equal(readDataInfo(dir), undefined)
    assert.equal(readFileSync(`${dataJsonFile(dir)}.corrupt`, "utf-8").length > 0, true)
    assert.ok(existsSync(`${dataTsvFile(dir)}.corrupt`))
    writeData(dir, expected, "c.dat", "A-1")
    assert.equal(readDataInfo(dir)?.kind, "ok")
})

test("data: a table that does not match its json, or is garbled, is unusable", () => {
    const dir = tempDir()
    writeData(dir, expected, "c.dat", "A-1", 1000)
    writeFileSync(dataTsvFile(dir), "garbage\n")
    assert.equal(readDataInfo(dir)?.kind, "unusable")
    writeData(dir, expected, "c.dat", "A-1", 1000)
    writeFileSync(dataTsvFile(dir), textOf("\t").split("\n").slice(0, 11).join("\n"))
    assert.equal(readDataInfo(dir)?.kind, "unusable")
    rmSync(dataTsvFile(dir))
    assert.equal(readDataInfo(dir)?.kind, "unusable")
})

test("data: the mapping is remembered in data.json; units and energy keep it", () => {
    const dir = tempDir()
    const mapping = makeMapping(
        "/some/where/My Curve.dat",
        { separator: "auto", sheet: "", skipRows: 3, comments: true, header: "no" },
        {
            q: { spec: "1", column: 1 },
            i: { spec: "col:2", column: 2 },
            sigma: { spec: "err", column: 3 },
        },
    )
    const info = writeData(dir, expected, "/some/where/My Curve.dat", "A-1", 1000, mapping)
    assert.deepEqual(info.mapping, mapping)
    assert.deepEqual(JSON.parse(readFileSync(dataJsonFile(dir), "utf-8")).mapping, mapping)
    setUnits(dir, "nm-1")
    setEnergy(dir, 8048, "eV")
    const status = readDataInfo(dir)
    assert.equal(status?.kind, "ok")
    if (status?.kind === "ok") assert.deepEqual(status.info.mapping, mapping)
})

test("data: a file without a mapping loads, a malformed mapping is dropped", () => {
    const dir = tempDir()
    writeData(dir, expected, "c.dat", "A-1", 1000)
    const old = JSON.parse(readFileSync(dataJsonFile(dir), "utf-8"))
    assert.equal("mapping" in old, false)
    const status = readDataInfo(dir)
    assert.equal(status?.kind, "ok")
    if (status?.kind === "ok") assert.equal(status.info.mapping, undefined)
    // a mapping that is malformed never makes the data unusable
    writeFileSync(dataJsonFile(dir), JSON.stringify({ ...old, mapping: { path: 3 } }))
    const odd = readDataInfo(dir)
    assert.equal(odd?.kind, "ok")
    if (odd?.kind === "ok") assert.equal(odd.info.mapping, undefined)
})
