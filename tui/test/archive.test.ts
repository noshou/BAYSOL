// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of core/archive.ts (7-Zip packing and reading) and store/run-archive.ts (what a
// run packs, and the readers that take the archive or the plain folders).
//
// Contents:
//   1. Names and the tool
//   2. Packing: round trip, atomic failures, the lock, removing the packed files
//   3. Reading: entry names, the size cap, the listing kept, extraction, the temp folder
//   4. A run: what is packed, readers for packed, plain and older runs
//   5. Workbooks in a run's archive (store/workbook-tree.ts): packed as the tree of
//      their XML files, rebuilt as proper `.xlsx` files that read back the same

import assert from "node:assert/strict"
import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { basename, join, normalize } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import { crc32 } from "node:zlib"
import * as XLSX from "xlsx"
import {
    ArchiveError,
    archiveTool,
    extractEntries,
    isSafeEntryName,
    listEntries,
    packFiles,
    readEntry,
    removePacked,
    setArchiveTool,
    withTempFolder,
    zipFolderAsync,
    zipFolderSync,
} from "../src/core/archive.js"
import { isWindows, RUN_FLOW, readSystem } from "../src/core/environment.js"
import { readRunObject, runIds } from "../src/store/projects.js"
import {
    archivePath,
    archivesOf,
    isPacked,
    materializeRunFile,
    materializeRunFileAsync,
    packableFiles,
    packRun,
    RunFileMissing,
    RunFileTooLarge,
    readRunBytes,
    readRunText,
    runFiles,
    warmRunWorkbooks,
} from "../src/store/run-archive.js"
import { listOpenRuns, readRunFile, runFileSizes } from "../src/store/run-logs.js"
import { rebuildWorkbook } from "../src/store/workbook-tree.js"
import { makeRun } from "./support/fake-run.js"
import { runOn, scratchProject, tempDir, writeFiles } from "./support/fixtures.js"
import { sheetsOf, tinyWorkbook } from "./support/workbook.js"

const write = writeFiles

/** Every file below `dir`, as sorted relative paths with their sizes (folders by name). */
function snapshot(dir: string, prefix = ""): string[] {
    return readdirSync(dir)
        .flatMap((n) => {
            const rel = prefix === "" ? n : `${prefix}/${n}`
            return statSync(join(dir, n)).isDirectory()
                ? [`${rel}/`, ...snapshot(join(dir, n), rel)]
                : [`${rel}:${statSync(join(dir, n)).size}`]
        })
        .sort()
}

/**
 * What the stand-in 7-Zip does besides passing the call on (see support/archive-stub.cjs).
 */
type Stub = { fail?: string; log?: string }

/**
 * A 7-Zip that is the real one, except that it fails (exit 2, a message on stderr) for the
 * command letter `on`; the stand-in of a disk that fills up (`a`) or an archive that
 * does not test (`t`).
 */
const failingTool = (on: string): Stub => ({ fail: on })

/** A 7-Zip that is the real one and writes a line to `log` for every extraction (`x`). */
const countingTool = (log: string): Stub => ({ log })

/**
 * Runs `fn` with the archive tool replaced by the stand-in, and puts the real one back.
 * The tool is `node` itself with a preloaded script, so it is a plain executable that
 * spawns the same way on Linux, macOS and Windows (no shell, no compiler).
 */
async function withTool<T>(stub: Stub, fn: () => Promise<T>): Promise<T> {
    const real = archiveTool()
    const keys = ["NODE_OPTIONS", "BAYSOL_STUB_REAL", "BAYSOL_STUB_FAIL", "BAYSOL_STUB_LOG"]
    const saved = keys.map((k) => process.env[k])
    const preload = fileURLToPath(new URL("./support/archive-stub.cjs", import.meta.url))
    process.env.NODE_OPTIONS = `--require ${JSON.stringify(preload.replaceAll("\\", "/"))}`
    process.env.BAYSOL_STUB_REAL = real
    if (stub.fail === undefined) delete process.env.BAYSOL_STUB_FAIL
    else process.env.BAYSOL_STUB_FAIL = stub.fail
    if (stub.log === undefined) delete process.env.BAYSOL_STUB_LOG
    else process.env.BAYSOL_STUB_LOG = stub.log
    setArchiveTool(process.execPath)
    try {
        return await fn()
    } finally {
        setArchiveTool(real)
        keys.forEach((k, i) => {
            const v = saved[i]
            if (v === undefined) delete process.env[k]
            else process.env[k] = v
        })
    }
}

// ========================================================================================
// 1. Names and the tool
// ========================================================================================

test("an entry name is a relative path of plain parts", () => {
    for (const ok of ["a", "logs/run.LOG", "m/output/plots_76x10.txt", "ρ/α.tex", "a b/c"])
        assert.equal(isSafeEntryName(ok), true, ok)
    for (const bad of [
        "",
        "/etc/passwd",
        "../x",
        "a/../b",
        "a/./b",
        "a//b",
        "a/",
        "C:\\x",
        "C:x",
        "a\\b",
        "a\0b",
        "a\nb",
        "x".repeat(1025),
    ])
        assert.equal(isSafeEntryName(bad), false, JSON.stringify(bad))
    for (const odd of [undefined, null, 5, {}, ["a"]])
        assert.equal(isSafeEntryName(odd), false)
})

test("the tool is a 7-Zip that runs (the bundled binary gets its execute bit)", () => {
    const tool = archiveTool()
    assert.ok(existsSync(tool))
    // Windows has no execute mode bits: an .exe runs by its extension
    if (isWindows(readSystem())) assert.match(tool, /\.exe$/i)
    else assert.ok((statSync(tool).mode & 0o111) !== 0, "executable")
})

// ========================================================================================
// 2. Packing
// ========================================================================================

test("pack and read back: names, sizes, bytes; no staging or lock left", async () => {
    const dir = tempDir()
    const binary = Buffer.from([0, 1, 2, 250, 255, 0, 10, 13])
    const files = {
        "logs/run.LOG": "datetime\tnow\n",
        "m/output/plots.txt": "plot\n".repeat(500),
        "m/output/ρ.tex": "\\documentclass{standalone}\n",
        "m/blob.bin": binary,
        "top.txt": "top",
    }
    write(dir, files)
    const names = Object.keys(files).sort()
    await packFiles(dir, "run.7z", names)
    const archive = join(dir, "run.7z")
    assert.deepEqual(
        listEntries(archive)
            .map((e) => e.name)
            .sort(),
        names,
    )
    for (const [rel, body] of Object.entries(files)) {
        const got = readEntry(archive, rel)
        assert.deepEqual(got, Buffer.isBuffer(body) ? body : Buffer.from(body), rel)
        assert.equal(listEntries(archive).find((e) => e.name === rel)?.size, got.length)
    }
    // the archive compresses (-mx=9): the repetitive plot is far smaller inside
    assert.ok(statSync(archive).size < 1500)
    // nothing else was made, and packFiles itself removed nothing
    assert.deepEqual(
        readdirSync(dir).filter((n) => n.includes(".tmp.") || n.startsWith(".pack")),
        [],
    )
    for (const rel of names) assert.ok(existsSync(join(dir, ...rel.split("/"))), rel)
})

test("removing packed files empties their folders and spares the others", () => {
    const dir = tempDir()
    write(dir, { "a/b/c.txt": "1", "a/d.txt": "2", "x/y/z.txt": "3", "x/keep.xlsx": "4" })
    removePacked(dir, ["a/b/c.txt", "a/d.txt", "x/y/z.txt", "gone/already.txt"])
    assert.deepEqual(snapshot(dir), ["x/", "x/keep.xlsx:1"])
})

test("a 7-Zip that fails while adding leaves the folder as it was", async () => {
    const dir = tempDir()
    write(dir, { "logs/run.LOG": "x", "m/m.LOG": "y" })
    const before = snapshot(dir)
    await withTool(failingTool("a"), async () => {
        await assert.rejects(
            packFiles(dir, "run.7z", ["logs/run.LOG", "m/m.LOG"]),
            (e: Error) => e instanceof ArchiveError && /simulated failure/.test(e.message),
        )
    })
    assert.deepEqual(snapshot(dir), before)
})

test("an archive that fails `7z t` is never renamed into place", async () => {
    const dir = tempDir()
    write(dir, { "logs/run.LOG": "x", "m/m.LOG": "y" })
    const before = snapshot(dir)
    await withTool(failingTool("t"), async () => {
        await assert.rejects(
            packFiles(dir, "run.7z", ["logs/run.LOG", "m/m.LOG"]),
            (e: Error) =>
                e instanceof ArchiveError &&
                /7-Zip failed: .*simulated failure/.test(e.message),
        )
    })
    assert.deepEqual(snapshot(dir), before, "no run.7z, no staging, no lock, files intact")
    // the same folder packs fine afterwards
    await packFiles(dir, "run.7z", ["logs/run.LOG", "m/m.LOG"])
    assert.ok(existsSync(join(dir, "run.7z")))
})

test("packing refuses what it cannot do, and says why", async () => {
    const dir = tempDir()
    write(dir, { "a.txt": "1" })
    await assert.rejects(packFiles(dir, "run.7z", []), /nothing to pack/)
    await assert.rejects(packFiles(dir, "run.7z", ["../a.txt"]), /not a safe name/)
    await assert.rejects(
        packFiles(dir, "run.7z", ["a.txt", "/etc/hosts"]),
        /not a safe name/,
    )
    await packFiles(dir, "run.7z", ["a.txt"])
    await assert.rejects(packFiles(dir, "run.7z", ["a.txt"]), /exists already/)
    // a file that is not there fails the 7-Zip step and leaves nothing behind
    const other = tempDir()
    await assert.rejects(packFiles(other, "run.7z", ["missing.txt"]), ArchiveError)
    assert.deepEqual(snapshot(other), [])
})

test("two packs of one folder cannot overlap: one is refused", async () => {
    const dir = tempDir()
    write(dir, { "a.txt": "1", "b/b.txt": "2" })
    const results = await Promise.allSettled([
        packFiles(dir, "run.7z", ["a.txt", "b/b.txt"]),
        packFiles(dir, "run.7z", ["a.txt", "b/b.txt"]),
    ])
    assert.deepEqual(results.map((r) => r.status).sort(), ["fulfilled", "rejected"])
    const refused = results.find((r) => r.status === "rejected") as PromiseRejectedResult
    assert.match(String(refused.reason), /being packed|exists already/)
    assert.equal(listEntries(join(dir, "run.7z")).length, 2)
})

// ========================================================================================
// 3. Reading
// ========================================================================================

/** An archive of three small files, in a fresh folder. */
async function sample(): Promise<string> {
    const dir = tempDir()
    write(dir, { "logs/run.LOG": "hello\n", "m/plots.txt": "p".repeat(100), "t.txt": "t" })
    await packFiles(dir, "run.7z", ["logs/run.LOG", "m/plots.txt", "t.txt"])
    return join(dir, "run.7z")
}

test("readEntry refuses unsafe names, absent entries and a size over the cap", async () => {
    const archive = await sample()
    assert.equal(readEntry(archive, "logs/run.LOG").toString(), "hello\n")
    for (const bad of ["../run.7z", "/etc/passwd", "logs/../t.txt", "", "a\\b"])
        assert.throws(() => readEntry(archive, bad), /not a safe entry name/, bad)
    assert.throws(() => readEntry(archive, "nope.txt"), /holds no nope\.txt/)
    // a name with wildcards is read literally, so it matches nothing
    assert.throws(() => readEntry(archive, "logs/*"), /holds no logs\/\*/)
    assert.throws(() => readEntry(archive, "m/plots.txt", 99), /too large to show/)
    assert.equal(readEntry(archive, "m/plots.txt", 100).length, 100)
    assert.throws(() => listEntries(join(tmpdir(), "no-such-archive.7z")), /is not there/)
})

test("a file that is no archive is an error, not a crash", () => {
    const file = join(tempDir(), "fake.7z")
    writeFileSync(file, "this is not a 7z archive")
    assert.throws(() => listEntries(file), ArchiveError)
})

test("the listing is kept while the archive stays, redone when it changes", async () => {
    const dir = tempDir()
    write(dir, { "a.txt": "1" })
    await packFiles(dir, "one.7z", ["a.txt"])
    const archive = join(dir, "one.7z")
    assert.equal(listEntries(archive), listEntries(archive), "the same list object")
    write(dir, { "b.txt": "22" })
    // another archive under the same name (replace, as a re-pack would)
    await packFiles(dir, "two.7z", ["a.txt", "b.txt"])
    writeFileSync(archive, readFileSync(join(dir, "two.7z")))
    assert.equal(listEntries(archive).length, 2)
})

test("extracting takes only the named entries, keeps their paths, has a cap", async () => {
    const archive = await sample()
    const into = join(tempDir(), "out")
    await extractEntries(archive, ["m/plots.txt"], into)
    assert.deepEqual(snapshot(into), ["m/", "m/plots.txt:100"])
    await assert.rejects(extractEntries(archive, ["nope.txt"], into), /holds no nope\.txt/)
    const cap = RUN_FLOW.archive.maxExtractBytes
    RUN_FLOW.archive.maxExtractBytes = 50
    try {
        await assert.rejects(
            extractEntries(archive, ["m/plots.txt"], into),
            /too large to extract/,
        )
    } finally {
        RUN_FLOW.archive.maxExtractBytes = cap
    }
})

test("the temporary folder is removed after success and after a failure", async () => {
    let seen = ""
    const made = await withTempFolder("baysol-test-tmp", async (folder) => {
        seen = folder
        writeFileSync(join(folder, "x"), "1")
        return "ok"
    })
    assert.equal(made, "ok")
    assert.equal(existsSync(seen), false)
    await assert.rejects(
        withTempFolder("baysol-test-tmp", async (folder) => {
            seen = folder
            writeFileSync(join(folder, "x"), "1")
            throw new Error("boom")
        }),
        /boom/,
    )
    assert.equal(existsSync(seen), false)
})

// ========================================================================================
// 4. A run: what is packed, the readers for packed, plain and older runs
// ========================================================================================

/** The names of the entries of all the archives of a run. */
const entriesOf = (dir: string): string[] =>
    archivesOf(dir).flatMap((a) => listEntries(a).map((e) => e.name))

test("a packed run is its archives beside its folder, all its files in them", async () => {
    const p = scratchProject()
    const { dir } = await makeRun(p)
    assert.equal(isPacked(dir), true)
    assert.equal(existsSync(dir), false, "the folder is gone")
    assert.deepEqual(readdirSync(join(p, "runs")).sort(), [
        `${basename(dir)}.7z`,
        `${basename(dir)}.meta.7z`,
    ])
    assert.ok(listEntries(archivePath(dir, "meta")).some((e) => e.name === "run.json"))
    const inside = entriesOf(dir)
    for (const name of [
        "run.json",
        "run.LOG",
        "settings.json",
        "buffer.json",
        "data.tsv",
        "data.json",
        "m.LOG",
        "m-plots.txt",
        "m-76x10.txt",
        "m-100x14.txt",
        "m.tex",
        "m_residuals.tex",
        "compare.tsv",
        "compare.tex",
        "compare-plots.txt",
        "compare-76x10.txt",
    ])
        assert.ok(inside.includes(name), name)
    // the workbook is held as the tree of its XML files, not as the .xlsx
    assert.equal(inside.includes("m.xlsx"), false)
    for (const name of ["m/[Content_Types].xml", "m/_rels/.rels", "m/xl/workbook.xml"])
        assert.ok(inside.includes(name), name)
    assert.equal(
        inside.some((n) => (n.includes("/") && !n.startsWith("m/")) || n.startsWith(".")),
        false,
        "flat but for the workbook's tree, no dot files",
    )
    // a second pack finds nothing: there is no folder any more
    assert.equal(await packRun(dir), 0)
})

test("packableFiles: the rules, and odd names left alone", async () => {
    const p = scratchProject()
    const { dir } = await makeRun(p, async () => 0)
    assert.equal(isPacked(dir), false)
    write(dir, { "m.XLSX": "x", "~$m.xlsx": "x", ".hidden": "x", ".stage-m/a.tex": "x" })
    // a backslash is a name on POSIX; on Windows it is a separator (a file in a folder)
    const backslash = !isWindows(readSystem())
    if (backslash) write(dir, { "out\\put.txt": "x" })
    const files = packableFiles(dir)
    assert.ok(files.includes("run.LOG") && files.includes("m.tex"))
    assert.ok(files.includes("run.json") && files.includes("m.xlsx"), "everything")
    // a case-insensitive file system holds m.XLSX and m.xlsx as one file
    const folded = isWindows(readSystem()) || readSystem().os === "darwin"
    assert.ok((folded || files.includes("m.XLSX")) && files.includes("compare.tsv"))
    for (const left of [
        ".claim",
        ".hidden",
        ".stage-m/a.tex",
        "~$m.xlsx",
        ...(backslash ? ["out\\put.txt"] : []),
    ])
        assert.equal(files.includes(left), false, left)
    assert.deepEqual(files, [...files].sort())
})

test("a pack that fails leaves the run folder as it was", async () => {
    const p = scratchProject()
    const { dir } = await makeRun(p, async () => 0)
    const before = snapshot(dir)
    await withTool(failingTool("a"), async () => {
        await assert.rejects(packRun(dir), ArchiveError)
    })
    assert.deepEqual(snapshot(dir), before)
    assert.equal(isPacked(dir), false)
    assert.equal(existsSync(`${dir}.7z`), false)
})

test("readers give the same files from a packed run and from a plain one", async () => {
    const packed = await makeRun(scratchProject())
    const plain = await makeRun(scratchProject(), async () => 0)
    assert.equal(isPacked(packed.dir), true)
    assert.equal(isPacked(plain.dir), false)
    for (const rel of ["settings.json", "data.tsv", "m-76x10.txt", "m.tex", "compare.tex"])
        assert.equal(readRunText(packed.dir, rel), readRunText(plain.dir, rel), rel)
    // the run.LOG differs only in its start time; the conditions row is the same
    for (const run of [packed, plain])
        assert.match(readRunFile(run.dir, "run.LOG"), /temperatureC\t25/)
    assert.deepEqual(
        [...runFileSizes(packed.dir).keys()].sort(),
        [...runFileSizes(plain.dir).keys()].sort(),
    )
    assert.ok(runFileSizes(packed.dir).has("run.LOG"))
    // run.json is read from the archive too, and the run list shows both
    assert.equal(readRunObject(packed.dir)?.status, "done")
    // a plain file wins when both exist (a pack that died after the rename)
    writeFileSync(join(plain.dir, "settings.json"), "plain wins")
    assert.equal(readRunText(plain.dir, "settings.json"), "plain wins")
})

test("readers refuse what is missing, too large, unsafe, or a broken archive", async () => {
    const run = await makeRun(scratchProject())
    assert.throws(() => readRunBytes(run.dir, "nope.txt"), RunFileMissing)
    assert.throws(() => readRunBytes(run.dir, "nope/nope.txt"), RunFileMissing)
    assert.throws(() => readRunBytes(run.dir, "data.tsv", 3), RunFileTooLarge)
    assert.throws(() => readRunBytes(run.dir, "../x"), /not a safe name/)
    assert.throws(() => readRunFile(run.dir, "nope.txt"), /this run has no nope\.txt/)
    assert.throws(
        () => readRunFile(join(run.dir, "gone"), "run.LOG"),
        /this run was deleted/,
    )
    const plain = await makeRun(scratchProject(), async () => 0)
    assert.throws(() => readRunBytes(plain.dir, "nope.txt"), RunFileMissing)
    assert.throws(() => readRunBytes(plain.dir, "data.tsv", 3), RunFileTooLarge)
    // an archive that is damaged is told, by name, and does not crash the page
    const broken = await makeRun(scratchProject())
    for (const archive of archivesOf(broken.dir)) writeFileSync(archive, "not an archive")
    assert.throws(
        () => readRunFile(broken.dir, "run.LOG"),
        /this run has no run\.LOG|the run's archive cannot be read/,
    )
})

test("open runs lists a packed run's files like a plain run's", async () => {
    const p = scratchProject()
    const packed = await makeRun(p)
    const plain = await makeRun(p, async () => 0)
    const runs = listOpenRuns(p)
    assert.equal(runs.length, 2)
    for (const run of runs) {
        const [m] = run.models
        assert.deepEqual(m?.tex, ["m.tex", "m_residuals.tex"])
        assert.deepEqual(run.compare?.tex, ["compare.tex"])
        assert.equal(m?.workbook, join(run.dir, "m.xlsx"))
        assert.equal(run.compare?.workbook, join(run.dir, "compare.tsv"))
        assert.deepEqual(
            m?.plotSizes.map((s) => [s.width, s.rows]),
            [
                [76, 10],
                [100, 14],
            ],
        )
        // the sized plot files are not on disk in the packed run, but they read
        const file = basename(m?.plotSizes[0]?.path ?? "")
        assert.match(readRunText(run.dir, file), /fit/)
    }
    assert.ok(
        [packed.dir, plain.dir].every((d) =>
            runs.some((r) => normalize(r.dir) === normalize(d)),
        ),
    )
})

test("a workbook that is only in the archive is opened from a copy on disk", async () => {
    const { dir } = await makeRun(scratchProject())
    const path = materializeRunFile(dir, join(dir, "m.xlsx"))
    // rebuilt from the tree the archive holds: a proper workbook with the same sheets
    assert.deepEqual(sheetsOf(readFileSync(path)), sheetsOf(tinyWorkbook()))
    assert.ok(!path.startsWith(dir))
    // a plain file is its own copy
    const plain = await makeRun(scratchProject(), async () => 0)
    const there = join(plain.dir, "m.xlsx")
    assert.equal(materializeRunFile(plain.dir, there), there)
    assert.throws(() => materializeRunFile(dir, join(dir, "nope.xlsx")), RunFileMissing)
})

// ========================================================================================
// 5. Workbooks in a run's archive
// ========================================================================================

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
    const names = entriesOf(dir)
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
    // the first local header: method 0 (stored: the copy
    // is temporary), then the name of the first entry
    assert.equal(bytes.readUInt16LE(8), 0)
    const length = bytes.readUInt16LE(26)
    assert.equal(bytes.subarray(30, 30 + length).toString("utf-8"), "[Content_Types].xml")
    assert.ok(bytes.equals(readFileSync(b)), "deterministic")
    assert.deepEqual(readdirSync(folder).sort(), ["a.xlsx", "b.xlsx"], "no staging file")
})

/** The entries of a zip read from its local headers: name, method, CRC, data. */
function localEntries(
    zip: Buffer,
): { name: string; method: number; crc: number; data: Buffer }[] {
    const out = []
    let at = 0
    while (zip.readUInt32LE(at) === 0x04034b50) {
        const flags = zip.readUInt16LE(at + 6)
        assert.equal(flags & 0x8, 0, "no data descriptor")
        assert.equal(flags & 0x800, 0x800, "names are UTF-8")
        const size = zip.readUInt32LE(at + 18)
        const start = at + 30 + zip.readUInt16LE(at + 26) + zip.readUInt16LE(at + 28)
        out.push({
            name: zip
                .subarray(at + 30, at + 30 + zip.readUInt16LE(at + 26))
                .toString("utf-8"),
            method: zip.readUInt16LE(at + 8),
            crc: zip.readUInt32LE(at + 14),
            data: zip.subarray(start, start + size),
        })
        at = start + size
    }
    return out
}

test("a stored zip keeps the order given, on every OS, and reads back", async () => {
    const folder = tempDir()
    const files: Record<string, string> = {
        "[Content_Types].xml": "<Types/>",
        "_rels/.rels": "<Relationships/>",
        "docProps/app.xml": "<Properties/>",
        "xl/Worksheets/ρ.xml": "<worksheet/>".repeat(50),
        "empty.xml": "",
    }
    write(folder, files)
    // the order a case-insensitive sort would break, and a reverse one
    for (const order of [Object.keys(files), Object.keys(files).reverse()]) {
        for (const mode of ["sync", "async"]) {
            const out = join(tempDir(), "o.zip")
            if (mode === "sync") zipFolderSync(folder, order, out, 0)
            else await zipFolderAsync(folder, order, out, 0)
            const entries = localEntries(readFileSync(out))
            assert.deepEqual(
                entries.map((e) => e.name),
                order,
            )
            for (const e of entries) {
                assert.equal(e.method, 0)
                assert.equal(e.crc, crc32(Buffer.from(files[e.name] as string)))
                assert.equal(e.data.toString("utf-8"), files[e.name])
            }
            // 7-Zip reads it, with the same bytes
            assert.deepEqual(
                listEntries(out)
                    .map((e) => e.name)
                    .sort(),
                order.slice().sort(),
            )
            for (const name of order)
                assert.equal(readEntry(out, name).toString("utf-8"), files[name])
        }
    }
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

test("a run is packed in groups: meta apart, a big sheet apart, all readable", async () => {
    // 30000 rows x 6 columns of numbers: the sheet XML is well over the big-sheet size
    const rows = Array.from({ length: 30000 }, (_, i) => [i, i / 7, i / 3, i * 2, i, 0.5])
    const book = XLSX.utils.book_new()
    XLSX.utils.book_append_sheet(book, XLSX.utils.aoa_to_sheet(rows), "draws")
    const bytes = XLSX.write(book, { type: "buffer", bookType: "xlsx" }) as Buffer
    const dir = runWith(bytes)
    writeFileSync(join(dir, "run.json"), '{"status":"done"}')
    writeFileSync(join(dir, "m-plots.txt"), "plots\n")
    writeFileSync(join(dir, "m.tex"), "\\documentclass{standalone}\n")
    const before = readFileSync(join(dir, "m.xlsx"))
    await packRun(dir)
    const names = (group: "meta" | "main" | "draws"): string[] =>
        listEntries(archivePath(dir, group))
            .map((e) => e.name)
            .sort()
    assert.deepEqual(names("meta"), ["m-plots.txt", "run.LOG", "run.json"])
    assert.deepEqual(names("draws"), ["m/xl/worksheets/sheet1.xml"])
    for (const name of ["m.tex", "m/xl/workbook.xml"])
        assert.ok(names("main").includes(name), name)
    assert.deepEqual(
        readdirSync(join(dir, "..")).sort(),
        (["meta", "draws", "main"] as const)
            .map((g) => basename(archivePath(dir, g)))
            .sort(),
    )
    // reads find a file in whichever archive holds it, and the listing counts the run once
    assert.equal(readRunText(dir, "run.json"), '{"status":"done"}')
    assert.equal(readRunText(dir, "m.tex"), "\\documentclass{standalone}\n")
    assert.ok(runFiles(dir).has("m.xlsx") && runFiles(dir).has("run.json"))
    assert.deepEqual(runIds(join(dir, "..", "..")), [basename(dir)])
    // the workbook comes back whole from two archives
    const out = join(tempDir(), "back.xlsx")
    rebuildWorkbook([archivePath(dir, "main"), archivePath(dir, "draws")], "m.xlsx", out)
    const back = XLSX.read(readFileSync(out))
    const sheet = back.Sheets.draws as XLSX.WorkSheet
    assert.equal(XLSX.utils.sheet_to_json(sheet).length, 29999)
    assert.ok(before.length > 0)
    assert.ok(readFileSync(materializeRunFile(dir, join(dir, "m.xlsx"))).length > 0)
})

test("a run packed as ONE archive (the older layout) still reads", async () => {
    const dir = runWith()
    await packFiles(dir, archivePath(dir), ["run.LOG"])
    rmSync(join(dir, "run.LOG"))
    assert.deepEqual(archivesOf(dir), [archivePath(dir)])
    assert.match(readRunText(dir, "run.LOG"), /datetime/)
})

/** How many extractions the counting tool has seen. */
const extractions = (log: string): number =>
    existsSync(log) ? readFileSync(log, "utf-8").trim().split("\n").length : 0

test("the workbook copy is made async and warm-ups share one rebuild", async () => {
    const original = tinyWorkbook()
    const dir = runWith(original)
    await packRun(dir)
    const log = join(tempDir(), "x.log")
    await withTool(countingTool(log), async () => {
        const path = join(dir, "m.xlsx")
        // two asks at once share one rebuild
        const [a, b] = await Promise.all([
            materializeRunFileAsync(dir, path),
            materializeRunFileAsync(dir, path),
        ])
        assert.equal(a, b)
        assert.deepEqual(sheetsOf(readFileSync(a)), sheetsOf(original))
        const made = extractions(log)
        assert.equal(made, 1)
        // a warm-up of a run whose copy exists makes nothing, and the sync reader agrees
        await warmRunWorkbooks(dir)
        assert.equal(materializeRunFile(dir, path), a)
        assert.equal(extractions(log), made)
    })
})

test("a warm-up of a missing run or a damaged archive does not throw", async () => {
    await warmRunWorkbooks(join(tempDir(), "runs", runOn("2026-11-12")))
    const dir = runWith()
    await packRun(dir)
    for (const archive of archivesOf(dir)) writeFileSync(archive, "not an archive")
    await warmRunWorkbooks(dir)
    await assert.rejects(materializeRunFileAsync(dir, join(dir, "m.xlsx")))
})
