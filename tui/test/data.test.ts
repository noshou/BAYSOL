// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import * as XLSX from "xlsx"
import {
    DataFileError,
    type DataPoints,
    dataIsReady,
    dataJsonFile,
    dataTsvFile,
    parseDataFile,
    parseDataText,
    parseXlsx,
    readDataInfo,
    resetData,
    setEnergy,
    setUnits,
    unitLabel,
    writeData,
} from "../src/store/data.js"
import { ProjectGoneError } from "../src/store/projects.js"

const temp = (): string => mkdtempSync(join(tmpdir(), "baysol-test-"))

/** Twelve points: q 0.01 .. 0.12, I falling, sigma 0.01. */
const rows = Array.from({ length: 12 }, (_, k) => [0.01 * (k + 1), 100 - k, 0.01])

/** The rows as text with a separator. */
const textOf = (sep: string, extra = ""): string =>
    `${extra}${rows.map((r) => r.join(sep)).join("\n")}\n`

const expected: DataPoints = {
    q: rows.map((r) => r[0] as number),
    i: rows.map((r) => r[1] as number),
    sigma: rows.map((r) => r[2] as number),
}

const failure = (text: string): string => {
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

test("data: bad files give a short message that names the row", () => {
    // the first row that is not numbers is a header, so the bad cell is in row 2
    const abc = textOf(",").split("\n")
    abc[1] = "0.02,99,abc"
    assert.match(failure(abc.join("\n")), /^row 2: "abc"/)
    assert.match(failure(textOf(",").split("\n").slice(0, 9).join("\n")), /only 9 points/)
    assert.match(failure(rows.map((r) => r.slice(0, 2).join(",")).join("\n")), /need 3 col/)
    const lines = textOf(",").split("\n")
    lines[4] = "0.03,5,0.01"
    assert.equal(failure(lines.join("\n")), "row 5: q must increase")
    lines[4] = "-1,5,0.01"
    assert.equal(failure(`# c\n${lines.join("\n")}`), "row 6: q must be above 0")
    lines[4] = "0.05,5,0"
    assert.equal(failure(lines.join("\n")), "row 5: sigma must be above 0")
    lines[4] = "0.05,NaN,0.1"
    assert.match(failure(lines.join("\n")), /^row 5: "NaN" is no number/)
    lines[4] = "0.05,,0.1"
    assert.match(failure(lines.join("\n")), /^row 5: .* no number/)
    for (const text of ["", "# only\n", "q,I,sigma\n"]) assert.ok(failure(text).length < 60)
    assert.ok(failure("hello").length < 60)
})

test("data: an .xlsx workbook is read, first sheet, header and text numbers", () => {
    const dir = temp()
    const sheet = XLSX.utils.aoa_to_sheet([["q", "I", "sigma"], ...rows])
    const other = XLSX.utils.aoa_to_sheet([["x"]])
    const book = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(book, sheet, "curve")
    XLSX.utils.book_append_sheet(book, other, "other")
    const file = join(dir, "curve.xlsx")
    writeFileSync(file, XLSX.write(book, { type: "buffer", bookType: "xlsx" }))
    assert.deepEqual(parseXlsx(file), expected)
    // recognised by its content, not its name
    const renamed = join(dir, "curve.dat")
    writeFileSync(renamed, readFileSync(file))
    assert.deepEqual(parseDataFile(renamed), expected)
    // the rule on the rows applies: a bad row is named by its sheet row
    const bad = XLSX.utils.aoa_to_sheet([["q", "I", "sigma"], ...rows, [0.05, 1, 1]])
    const wb = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(wb, bad, "s")
    writeFileSync(file, XLSX.write(wb, { type: "buffer", bookType: "xlsx" }))
    assert.throws(() => parseXlsx(file), /row 14: q must increase/)
    writeFileSync(file, "PK not a zip")
    assert.throws(() => parseDataFile(file), DataFileError)
})

test("data: binary files are refused", () => {
    const dir = temp()
    const file = join(dir, "b.dat")
    writeFileSync(file, Buffer.from([1, 2, 0, 3]))
    assert.throws(() => parseDataFile(file), /not a text file/)
    writeFileSync(file, Buffer.from("d0cf11e000", "hex"))
    assert.throws(() => parseDataFile(file), /\.xls/)
    assert.throws(() => parseDataFile(join(dir, "none.dat")), /cannot read/)
})

test("data: writeData makes a clean TSV and data.json last", () => {
    const dir = temp()
    const odd: DataPoints = { q: [], i: [], sigma: [] }
    for (let k = 1; k <= 10; k++) {
        odd.q.push(k / 3)
        odd.i.push(1e-7 * k)
        odd.sigma.push(0.1)
    }
    const info = writeData(dir, odd, "/some/where/My Curve.csv", "nm-1", 12400)
    assert.deepEqual(info, {
        units: "nm-1", energy: 12400, source: "My Curve.csv", points: 10,
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
    const dir = temp()
    writeData(dir, expected, "c.dat", "A-1")
    assert.equal(dataIsReady(dir), false, "no energy yet")
    const before = readFileSync(dataTsvFile(dir))
    setUnits(dir, "nm-1")
    setEnergy(dir, 8048)
    assert.deepEqual(readFileSync(dataTsvFile(dir)), before)
    const status = readDataInfo(dir)
    assert.equal(status?.kind === "ok" && status.info.units, "nm-1")
    assert.equal(status?.kind === "ok" && status.info.energy, 8048)
    assert.ok(dataIsReady(dir))
    assert.throws(() => setEnergy(dir, 0), DataFileError)
    assert.throws(() => setEnergy(dir, Number.NaN), DataFileError)
    assert.throws(() => setEnergy(dir, -5), DataFileError)
    // no leftovers
    assert.equal(existsSync(`${dataJsonFile(dir)}.lock`), false)
    const empty = temp()
    assert.throws(() => setUnits(empty, "nm-1"), /no data yet/)
    assert.equal(readDataInfo(empty), undefined)
})

test("data: the unit labels have the right superscripts", () => {
    assert.equal(unitLabel("nm-1"), "nm⁻¹")
    assert.equal(unitLabel("A-1"), "Å⁻¹")
    assert.equal(unitLabel("A-1").codePointAt(0), 0xc5)
})

test("data: a vanished project is an error with a note, nothing is recreated", () => {
    const dir = join(temp(), "gone")
    assert.throws(() => writeData(dir, expected, "c.dat", "A-1"), ProjectGoneError)
    assert.equal(existsSync(dir), false)
    const live = temp()
    writeData(live, expected, "c.dat", "A-1", 1000)
    rmSync(live, { recursive: true })
    assert.throws(() => setUnits(live, "nm-1"), ProjectGoneError)
    assert.throws(() => resetData(live), ProjectGoneError)
    assert.equal(readDataInfo(live), undefined)
    assert.equal(dataIsReady(live), false)
    assert.equal(existsSync(live), false)
})

test("data: garbled files are unusable, never overwritten, reset keeps them", () => {
    const dir = temp()
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
    const dir = temp()
    writeData(dir, expected, "c.dat", "A-1", 1000)
    writeFileSync(dataTsvFile(dir), "garbage\n")
    assert.equal(readDataInfo(dir)?.kind, "unusable")
    writeData(dir, expected, "c.dat", "A-1", 1000)
    writeFileSync(dataTsvFile(dir), textOf("\t").split("\n").slice(0, 11).join("\n"))
    assert.equal(readDataInfo(dir)?.kind, "unusable")
    rmSync(dataTsvFile(dir))
    assert.equal(readDataInfo(dir)?.kind, "unusable")
})
