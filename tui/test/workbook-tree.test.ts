// SPDX-License-Identifier: LGPL-3.0-or-later

// Workbooks in a run's archive (`store/workbook-tree.ts`): packed as the tree of their XML
// files, rebuilt as proper `.xlsx` files that read back the same.

import assert from "node:assert/strict"
import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import * as XLSX from "xlsx"
import { listEntries } from "../src/core/archive.js"
import {
    archivePath,
    materializeRunFile,
    packRun,
    runFiles,
} from "../src/store/run-archive.js"
import { rebuildWorkbook } from "../src/store/workbook-tree.js"
import { runOn, tempDir } from "./support/fixtures.js"
import { sheetsOf, tinyWorkbook } from "./support/workbook.js"

/** A run folder (beside which its archive is made) holding `m.xlsx` and a log. */
function runWith(book: Buffer | string = tinyWorkbook()): string {
    const dir = join(tempDir(), "runs", runOn("2026-11-12"))
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, "m.xlsx"), book)
    writeFileSync(join(dir, "run.LOG"), "datetime\tnow\n")
    return dir
}

test("a packed run holds a workbook as its XML tree, folder left clean", async () => {
    const dir = runWith()
    assert.equal(await packRun(dir), 2)
    const names = listEntries(archivePath(dir)).map((e) => e.name)
    assert.equal(names.includes("m.xlsx"), false)
    for (const name of [
        "m/[Content_Types].xml",
        "m/_rels/.rels",
        "m/xl/workbook.xml",
        "run.LOG",
    ])
        assert.ok(names.includes(name), name)
    assert.equal(existsSync(dir), false, "no folder, no tree left behind")
    // the files of the run still list it as a workbook, by its own name
    assert.ok(runFiles(dir).has("m.xlsx"))
})

test("the rebuilt workbook reads back the same, formulas included", async () => {
    const original = tinyWorkbook()
    const dir = runWith(original)
    await packRun(dir)
    const copy = materializeRunFile(dir, join(dir, "m.xlsx"))
    assert.deepEqual(sheetsOf(readFileSync(copy)), sheetsOf(original))
    // a second ask is the same file
    assert.equal(materializeRunFile(dir, join(dir, "m.xlsx")), copy)
})

test("a rebuilt workbook is a proper zip: [Content_Types].xml first", async () => {
    const dir = runWith()
    await packRun(dir)
    const folder = tempDir()
    const [a, b] = [join(folder, "a.xlsx"), join(folder, "b.xlsx")]
    rebuildWorkbook(archivePath(dir), "m.xlsx", a)
    rebuildWorkbook(archivePath(dir), "m.xlsx", b)
    const bytes = readFileSync(a)
    assert.equal(bytes.subarray(0, 4).toString("latin1"), "PK\u0003\u0004")
    // the first local header: method 8 (deflate), then the name of the first entry
    assert.equal(bytes.readUInt16LE(8), 8)
    const length = bytes.readUInt16LE(26)
    assert.equal(bytes.subarray(30, 30 + length).toString("utf-8"), "[Content_Types].xml")
    assert.ok(bytes.equals(readFileSync(b)), "deterministic")
    assert.deepEqual(readdirSync(folder).sort(), ["a.xlsx", "b.xlsx"], "no staging file")
})

test("a workbook that is not a zip stops the pack, the run stays as it was", async () => {
    const dir = runWith("not a workbook")
    await assert.rejects(packRun(dir))
    assert.deepEqual(readdirSync(dir).sort(), ["m.xlsx", "run.LOG"])
    assert.equal(existsSync(archivePath(dir)), false)
})

test("something in the way of a workbook's tree stops the pack", async () => {
    const dir = runWith()
    writeFileSync(join(dir, "m"), "in the way")
    await assert.rejects(packRun(dir), /in the way of m\.xlsx/)
    assert.deepEqual(readdirSync(dir).sort(), ["m", "m.xlsx", "run.LOG"])
})

test("the tree packs smaller than the workbook it came from", async () => {
    // many alike rows: what a results workbook is made of
    const rows = Array.from({ length: 4000 }, (_, i) => [i / 4000, 100 - i / 50, 0.3])
    const book = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(book, XLSX.utils.aoa_to_sheet(rows), "fit")
    const bytes = XLSX.write(book, { type: "buffer", bookType: "xlsx" }) as Buffer
    const dir = runWith(bytes)
    await packRun(dir)
    assert.ok(statSync(archivePath(dir)).size < bytes.length)
})
