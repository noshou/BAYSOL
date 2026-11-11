// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/references.ts: the reference curves of a project, the reference mode of
// the import (an optional sigma) and the pure parts of the references screen.

import assert from "node:assert/strict"
import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    rmSync,
    writeFileSync,
} from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import {
    referenceCells,
    referenceNote,
    referenceSummary,
} from "../src/screens/references-screen.js"
import { setUnits, writeData } from "../src/store/data.js"
import {
    DataFileError,
    type DataPoints,
    DEFAULT_PARSE_OPTIONS,
    extractCurve,
    isNoSigma,
    parseTable,
    resolveReferenceColumns,
    textSource,
} from "../src/store/data-table.js"
import { ProjectGoneError } from "../src/store/projects.js"
import {
    addReference,
    deleteReference,
    freeStem,
    listReferences,
    migrateReferences,
    readReferenceFile,
    referencesDir,
    referenceText,
    referenceUnits,
    safeStem,
} from "../src/store/references.js"
import { tempDir as temp } from "./support/fixtures.js"

/** A curve of `n` points with a sigma (or without). */
function curve(n: number, sigma = true): DataPoints {
    const data: DataPoints = { q: [], i: [], sigma: [], dropped: 0 }
    for (let k = 1; k <= n; k++) {
        data.q.push(k / 100)
        data.i.push(100 / k)
        if (sigma) data.sigma.push(0.5)
    }
    return data
}

/** A project folder with data (so references may be added). */
function project(units: "A-1" | "nm-1" = "A-1"): string {
    const dir = temp()
    writeData(dir, curve(12), "data.dat", units, 12400)
    return dir
}

const failure = (run: () => unknown): string => {
    try {
        run()
    } catch (error) {
        if (error instanceof DataFileError) return error.message
        throw error
    }
    return ""
}

// ========================================================================================
// 1. The reference mode of the import
// ========================================================================================

test("reference: sigma may be none, a curve without it keeps only q and I", () => {
    const table = parseTable(
        textSource("q I\n0.1 5\n0.2 4\n0.3 3\n0.4 2\n"),
        DEFAULT_PARSE_OPTIONS,
    )
    const none = resolveReferenceColumns({ q: "1", i: "2", sigma: "none" }, table.names)
    assert.deepEqual(none, {
        q: 1,
        i: 2,
        sigma: undefined,
    })
    const columns = resolveReferenceColumns({ q: "q", i: "I", sigma: "" }, table.names)
    const data = extractCurve(table, columns)
    assert.deepEqual(data.q, [0.1, 0.2, 0.3, 0.4])
    assert.deepEqual(data.sigma, [])
    assert.ok(isNoSigma(" None "))
    assert.ok(!isNoSigma("3"))
})

test("reference: a chosen sigma is read, and a row with q or sigma <= 0 is dropped", () => {
    const text = "0 5 1\n0.1 5 1\n0.2 4 0\n0.3 3 1\n0.4 2 1\n0.5 1 1\n"
    const table = parseTable(textSource(text), DEFAULT_PARSE_OPTIONS)
    const columns = resolveReferenceColumns({ q: "1", i: "2", sigma: "3" }, table.names)
    const data = extractCurve(table, columns)
    assert.equal(data.q.length, 4)
    assert.equal(data.dropped, 2)
    assert.equal(data.sigma.length, 4)
    // with no sigma only q <= 0 is dropped, and three points are still the least
    const bare = extractCurve(table, { q: 1, i: 2 })
    assert.equal(bare.q.length, 5)
    assert.equal(bare.dropped, 1)
    const two = parseTable(textSource("0.1 1\n0.2 1\n"), DEFAULT_PARSE_OPTIONS)
    assert.match(
        failure(() => extractCurve(two, { q: 1, i: 2 })),
        /only 2 points: need 3/,
    )
})

test("reference: the roles must name different columns, and unknown ones fail", () => {
    const names = ["q", "I", "err"]
    assert.match(
        failure(() => resolveReferenceColumns({ q: "1", i: "1", sigma: "none" }, names)),
        /different columns/,
    )
    assert.match(
        failure(() => resolveReferenceColumns({ q: "1", i: "x", sigma: "none" }, names)),
        /^I\(q\): no column "x"/,
    )
    assert.match(
        failure(() => resolveReferenceColumns({ q: "1", i: "2", sigma: "9" }, names)),
        /^sigma: no column 9/,
    )
})

// ========================================================================================
// 2. The files
// ========================================================================================

test("references: an added curve is a clean file, named by the safe stem", () => {
    const dir = project()
    const name = addReference(dir, curve(5), "/some/where/My Curve (CRYSOL).dat")
    assert.equal(name, "My_Curve__CRYSOL_")
    const file = join(referencesDir(dir), `${name}.tsv`)
    const text = readFileSync(file, "utf-8")
    assert.equal(text.split("\n").length, 6)
    assert.equal(text.split("\n")[0], "0.01\t100\t0.5")
    assert.ok(!text.includes(" "))
    // two columns when the curve has no sigma
    const bare = addReference(dir, curve(5, false), "plain.csv")
    const first2 = readFileSync(join(referencesDir(dir), `${bare}.tsv`), "utf-8")
    assert.equal(first2.split("\n")[0], "0.01\t100")
    assert.deepEqual(readdirSync(referencesDir(dir)).sort(), [`${name}.tsv`, "plain.tsv"])
    // the entries are read back the way Julia reads them
    const [first] = listReferences(dir)
    assert.equal(first?.name, "My_Curve__CRYSOL_")
    assert.equal(first?.points, 5)
    assert.equal(first?.qMin, 0.01)
    assert.equal(first?.qMax, 0.05)
})

test("references: a taken name gets -2, -3, never over a file", () => {
    const dir = project()
    assert.equal(addReference(dir, curve(4), "a.dat"), "a")
    const before = readFileSync(join(referencesDir(dir), "a.tsv"), "utf-8")
    assert.equal(addReference(dir, curve(6), "a.csv"), "a-2")
    assert.equal(addReference(dir, curve(7), "A.txt"), "A-3")
    assert.equal(readFileSync(join(referencesDir(dir), "a.tsv"), "utf-8"), before)
    // a file of another extension or case that Julia would also read takes the stem
    writeFileSync(join(referencesDir(dir), "b.DAT"), "1 2\n2 3\n3 4\n")
    assert.equal(addReference(dir, curve(4), "b.xlsx"), "b-2")
    assert.deepEqual(freeStem("x", ["x", "X-2", "x-3"]), "x-4")
    assert.equal(freeStem("y", ["x"]), "y")
})

test("references: the stem is made safe", () => {
    assert.equal(safeStem("/p/q/data 1.v2.dat"), "data_1.v2")
    assert.equal(safeStem("../..hidden.csv"), "hidden")
    assert.equal(safeStem("...dat"), "reference")
    assert.equal(safeStem("é-ß_1.tsv"), "é-ß_1")
    assert.equal(safeStem("a/b\\c:d*.dat"), "b_c_d_")
    assert.ok(safeStem(`${"x".repeat(200)}.dat`).length <= 60)
    assert.equal(safeStem(".dat"), "dat")
})

test("references: no data yet, or no project, adds nothing", () => {
    const empty = temp()
    assert.match(
        failure(() => addReference(empty, curve(4), "a.dat")),
        /import the data first/,
    )
    assert.ok(!existsSync(referencesDir(empty)))
    assert.match(failure(() => referenceUnits(empty)), /import the data first/)
    const gone = join(temp(), "deleted")
    assert.throws(
        () => addReference(gone, curve(4), "a.dat"),
        (e) => e instanceof DataFileError || e instanceof ProjectGoneError,
    )
    assert.ok(!existsSync(gone))
    // a project that is deleted between the check and the write is not brought back
    const dir = project()
    rmSync(dir, { recursive: true })
    assert.throws(() => addReference(dir, curve(4), "a.dat"))
    assert.ok(!existsSync(dir))
})

test("references: the units are the data's, and follow a change of them", () => {
    const dir = project("nm-1")
    assert.equal(referenceUnits(dir), "nm-1")
    setUnits(dir, "A-1")
    assert.equal(referenceUnits(dir), "A-1")
})

test("references: an unusable file is listed with its reason and never touched", () => {
    const dir = project()
    const folder = referencesDir(dir)
    mkdirSync(folder)
    const files: Record<string, string> = {
        "text.txt": "hello\nworld\n",
        "cell.tsv": "0.1 1\n0.2 x\n0.3 3\n",
        "wide.dat": "0.1 1 2 3\n0.2 1 2 3\n",
        "neg.dat": "-1 -1\n-2 -2\n",
        "good.dat": "# CRYSOL\nq I\n0.1 5\n0.2 4\n0.3 3\n",
        "ignored.csv": "0.1 5\n0.2 4\n0.3 3\n",
    }
    for (const [name, text] of Object.entries(files))
        writeFileSync(join(folder, name), text)
    mkdirSync(join(folder, "folder.dat"))
    const found = Object.fromEntries(listReferences(dir).map((e) => [e.file, e]))
    assert.deepEqual(Object.keys(found).sort(), [
        "cell.tsv", "good.dat", "neg.dat", "text.txt", "wide.dat",
    ])
    assert.match(found["text.txt"]?.unusable ?? "", /no row of numbers/)
    assert.match(found["cell.tsv"]?.unusable ?? "", /^line 2: a cell is no number/)
    assert.match(found["wide.dat"]?.unusable ?? "", /^line 1: 4 columns, not 2 or 3/)
    assert.match(found["neg.dat"]?.unusable ?? "", /no usable point/)
    assert.equal(found["good.dat"]?.unusable, undefined)
    assert.equal(found["good.dat"]?.points, 3)
    // listing changes nothing
    for (const [name, text] of Object.entries(files))
        assert.equal(readFileSync(join(folder, name), "utf-8"), text)
    // a file Julia reads in any case of the extension
    writeFileSync(join(folder, "UP.TSV"), "1 1\n2 2\n3 3\n")
    assert.equal(listReferences(dir).find((e) => e.file === "UP.TSV")?.points, 3)
})

test("references: Julia's reader rules: comments, separators, header, I <= 0", () => {
    const dir = temp()
    const file = join(dir, "r.dat")
    writeFileSync(
        file,
        "name of the fit\nq; I; err\n0.1;5;1 # first\n\n0.2,4,1\n0.3\t0\t1\n" +
            "0.4 2\n-0.5 2\n",
    )
    assert.deepEqual(readReferenceFile(file), { points: 3, qMin: 0.1, qMax: 0.4 })
    writeFileSync(file, "0.1 5\ntext 4\n")
    assert.throws(() => readReferenceFile(file), /line 2: a cell is no number/)
    assert.throws(() => readReferenceFile(join(dir, "none.dat")), /cannot be read/)
    // the text of a clean file reads back
    writeFileSync(file, referenceText(curve(9)))
    assert.equal(readReferenceFile(file).points, 9)
})

test("references: delete takes a listed plain name; one already gone is no error", () => {
    const dir = project()
    const a = addReference(dir, curve(4), "a.dat")
    addReference(dir, curve(4), "b.dat")
    writeFileSync(join(temp(), "outside.tsv"), "x")
    assert.equal(deleteReference(dir, "../data.tsv"), false)
    assert.equal(deleteReference(dir, "data.json"), false)
    assert.ok(existsSync(join(dir, "data.tsv")))
    assert.equal(deleteReference(dir, `${a}.tsv`), true)
    assert.equal(deleteReference(dir, `${a}.tsv`), false)
    assert.deepEqual(
        listReferences(dir).map((e) => e.name),
        ["b"],
    )
    assert.equal(deleteReference(temp(), "x.tsv"), false)
})

test("references: copies adding the same stem both succeed, with different names", () => {
    const dir = project()
    const names = [1, 2, 3, 4].map((k) => addReference(dir, curve(3 + k), "same.dat"))
    assert.deepEqual(names, ["same", "same-2", "same-3", "same-4"])
    assert.equal(listReferences(dir).length, 4)
    // a copy that deletes the file another one lists: the list is read again, no crash
    const [entry] = listReferences(dir)
    assert.equal(deleteReference(dir, (entry as { file: string }).file), true)
    assert.equal(deleteReference(dir, (entry as { file: string }).file), false)
})

test("references: an old references/ folder is moved to reference-fit/", () => {
    const dir = project()
    const old = join(dir, "references")
    mkdirSync(old)
    writeFileSync(join(old, "CRYSOL.tsv"), "0.1\t2\n0.2\t1\n0.3\t1\n")
    writeFileSync(join(old, "notes.md"), "kept")
    assert.deepEqual(
        listReferences(dir).map((e) => e.name),
        ["CRYSOL"],
    )
    assert.ok(!existsSync(old), "the old folder is gone (renamed)")
    assert.ok(existsSync(join(referencesDir(dir), "notes.md")), "every file came along")
    assert.equal(migrateReferences(dir), false, "nothing more to move")
    // adding to a project that still has the old folder moves it first
    const second = project()
    mkdirSync(join(second, "references"))
    writeFileSync(join(second, "references", "a.tsv"), "0.1\t2\n0.2\t1\n0.3\t1\n")
    assert.equal(addReference(second, curve(4), "b.dat"), "b")
    assert.deepEqual(readdirSync(referencesDir(second)).sort(), ["a.tsv", "b.tsv"])
    assert.ok(!existsSync(join(second, "references")))
    // both folders present: the new one wins and the old one is left alone
    const both = project()
    mkdirSync(join(both, "references"))
    mkdirSync(referencesDir(both))
    assert.equal(migrateReferences(both), false)
    assert.ok(existsSync(join(both, "references")))
})

// ========================================================================================
// 3. The screen's pure parts
// ========================================================================================

test("references screen: cells, note and the data screen's summary line", () => {
    const dir = project()
    addReference(dir, curve(5), "one.dat")
    addReference(dir, curve(5), "two.dat")
    writeFileSync(join(referencesDir(dir), "bad.txt"), "no")
    const entries = listReferences(dir)
    const bad = entries.find((e) => e.name === "bad")
    assert.deepEqual(referenceCells(bad as never), ["bad", "unusable", ""])
    assert.deepEqual(referenceCells(entries.find((e) => e.name === "one") as never), [
        "one",
        "5",
        "0.01 to 0.05",
    ])
    assert.equal(referenceNote(bad), "bad.txt: no row of numbers")
    assert.equal(referenceNote(entries[1]), undefined)
    assert.equal(referenceNote(undefined), undefined)
    assert.equal(referenceSummary(entries, 80), "2 (one, two), 1 unusable")
    assert.equal(referenceSummary([], 80), undefined)
    assert.ok((referenceSummary(entries, 12) as string).length <= 12)
})
