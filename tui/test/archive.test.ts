// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of core/archive.ts (7-Zip packing and reading) and store/run-archive.ts (what a
// run packs, and the readers that take the archive or the plain folders).
//
// Contents:
//   1. Names and the tool
//   2. Packing: round trip, atomic failures, the lock, removing the packed files
//   3. Reading: entry names, the size cap, the listing kept, extraction, the temp folder
//   4. A run folder: what is packed and what stays, readers for packed and plain runs

import assert from "node:assert/strict"
import {
    chmodSync,
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
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
} from "../src/core/archive.js"
import { RUN_FLOW } from "../src/core/environment.js"
import {
    isPacked,
    packableFiles,
    packRun,
    RUN_ARCHIVE,
    RunFileMissing,
    RunFileTooLarge,
    readRunBytes,
    readRunText,
    runFolderFiles,
} from "../src/store/run-archive.js"
import { listOpenRuns, readRunFile, runFileSizes } from "../src/store/run-logs.js"
import { makeRun } from "./support/fake-run.js"
import { tempDir } from "./support/fixtures.js"

/** A project folder with the inputs of a run. */
function project(): string {
    const dir = tempDir()
    writeFileSync(join(dir, "buffer.json"), '{"solutes": []}\n')
    writeFileSync(join(dir, "data.tsv"), "0.1\t5\t0.1\n")
    writeFileSync(join(dir, "data.json"), '{"units": "A-1", "energy": 8000}\n')
    return dir
}

/** Writes files (paths relative to `dir`, `/`-separated) with the given contents. */
function write(dir: string, files: Record<string, string | Buffer>): void {
    for (const [rel, body] of Object.entries(files)) {
        const path = join(dir, ...rel.split("/"))
        mkdirSync(join(path, ".."), { recursive: true })
        writeFileSync(path, body)
    }
}

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
 * A 7-Zip that is the real one, except that it fails (exit 2, a message on stderr) for the
 * command letter `fails`; the stand-in of a disk that fills up (`a`) or an archive that
 * does not test (`t`).
 */
function failingTool(on: string): string {
    const script = join(tempDir(), "7z-fails")
    writeFileSync(
        script,
        [
            "#!/bin/sh",
            `if [ "$1" = "${on}" ]; then echo "ERROR: simulated failure" >&2; exit 2; fi`,
            `exec "${archiveTool()}" "$@"`,
            "",
        ].join("\n"),
    )
    chmodSync(script, 0o755)
    return script
}

/** Runs `fn` with the archive tool replaced, and puts the real one back. */
async function withTool<T>(tool: string, fn: () => Promise<T>): Promise<T> {
    const real = archiveTool()
    setArchiveTool(tool)
    try {
        return await fn()
    } finally {
        setArchiveTool(real)
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
    assert.ok((statSync(tool).mode & 0o111) !== 0, "executable")
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
// 4. A run folder
// ========================================================================================

test("a run packs everything but run.json, the workbooks and the dot files", async () => {
    const p = project()
    const { dir } = await makeRun(p)
    assert.equal(isPacked(dir), true)
    // what stays: run.json, the workbooks (in place), the claim marker
    assert.deepEqual(
        snapshot(dir).filter((x) => !x.startsWith(`${RUN_ARCHIVE}:`)),
        [
            `.claim:${statSync(join(dir, ".claim")).size}`,
            "compare/",
            "compare/res_compare.xlsx:11",
            "m/",
            "m/output/",
            "m/output/m.xlsx:11",
            `run.json:${statSync(join(dir, "run.json")).size}`,
        ],
    )
    // what is inside: paths relative to the run folder
    const inside = listEntries(join(dir, RUN_ARCHIVE)).map((e) => e.name)
    for (const name of [
        "logs/run.LOG",
        "logs/settings.json",
        "logs/buffer.json",
        "logs/data.tsv",
        "logs/data.json",
        "m/m.LOG",
        "m/output/plots.txt",
        "m/output/plots_76x10.txt",
        "m/output/plots_100x14.txt",
        "m/output/plots/m.tex",
        "m/output/plots/m_residuals.tex",
        "compare/plots.txt",
        "compare/plots_76x10.txt",
        "compare/plots/res_compare.tex",
    ])
        assert.ok(inside.includes(name), name)
    assert.equal(inside.some((n) => /xlsx$|run\.json$/.test(n) || n.startsWith(".")), false)
    // a second pack of the same run finds nothing left to pack, and changes nothing
    const before = snapshot(dir)
    assert.equal(await packRun(dir), 0, "nothing left to pack")
    assert.deepEqual(snapshot(dir), before)
})

test("packableFiles on a plain run: the rules, and odd names left alone", async () => {
    const p = project()
    const { dir } = await makeRun(p, async () => 0)
    assert.equal(isPacked(dir), false)
    write(dir, { "m/output/m.XLSX": "x", "m/output/~$m.xlsx": "x", ".hidden": "x" })
    write(dir, { "run.7z.tmp.123": "x", "m/out\\put.txt": "x" })
    const files = packableFiles(dir)
    assert.ok(files.includes("logs/run.LOG") && files.includes("m/output/plots/m.tex"))
    for (const left of [
        "run.json",
        ".claim",
        ".hidden",
        "m/output/m.xlsx",
        "m/output/m.XLSX",
        "m/output/~$m.xlsx",
        "compare/res_compare.xlsx",
        "run.7z.tmp.123",
        "m/out\\put.txt",
    ])
        assert.equal(files.includes(left), false, left)
    assert.deepEqual(files, [...files].sort())
})

test("readers give the same files from a packed run and from a plain one", async () => {
    const packed = await makeRun(project())
    const plain = await makeRun(project(), async () => 0)
    assert.equal(isPacked(packed.dir), true)
    assert.equal(isPacked(plain.dir), false)
    for (const rel of [
        "logs/settings.json",
        "logs/data.tsv",
        "m/output/plots_76x10.txt",
        "m/output/plots/m.tex",
        "compare/plots/res_compare.tex",
    ])
        assert.equal(readRunText(packed.dir, rel), readRunText(plain.dir, rel), rel)
    // the run.LOG differs only in its start time; the conditions row is the same
    for (const run of [packed, plain])
        assert.match(readRunFile(run.dir, "run.LOG"), /temperature_c\t25/)
    assert.deepEqual(
        [...runFileSizes(packed.dir).keys()].sort(),
        [...runFileSizes(plain.dir).keys()].sort(),
    )
    assert.ok(runFileSizes(packed.dir).has("run.LOG"))
    assert.deepEqual(
        [...runFolderFiles(packed.dir, "m/output/plots").keys()].sort(),
        ["m.tex", "m_residuals.tex"],
    )
    // a plain file wins when both exist (a pack that died after the rename)
    mkdirSync(join(packed.dir, "logs"))
    writeFileSync(join(packed.dir, "logs", "settings.json"), "plain wins")
    assert.equal(readRunText(packed.dir, "logs/settings.json"), "plain wins")
})

test("readers refuse what is missing, too large, unsafe, or a broken archive", async () => {
    const run = await makeRun(project())
    assert.throws(() => readRunBytes(run.dir, "logs/nope.txt"), RunFileMissing)
    assert.throws(() => readRunBytes(run.dir, "nope/nope.txt"), RunFileMissing)
    assert.throws(() => readRunBytes(run.dir, "logs/data.tsv", 3), RunFileTooLarge)
    assert.throws(() => readRunBytes(run.dir, "../x"), /not a safe name/)
    assert.throws(() => readRunFile(run.dir, "nope.txt"), /this run has no nope\.txt/)
    assert.throws(
        () => readRunFile(join(run.dir, "gone"), "run.LOG"),
        /this run was deleted/,
    )
    const plain = await makeRun(project(), async () => 0)
    assert.throws(() => readRunBytes(plain.dir, "logs/nope.txt"), RunFileMissing)
    assert.throws(() => readRunBytes(plain.dir, "logs/data.tsv", 3), RunFileTooLarge)
    // an archive that is damaged is told, by name, and does not crash the page
    const broken = await makeRun(project())
    writeFileSync(join(broken.dir, RUN_ARCHIVE), "not an archive")
    assert.throws(
        () => readRunFile(broken.dir, "run.LOG"),
        /the run's archive cannot be read/,
    )
})

test("open runs lists a packed run's figures and sizes like a plain run's", async () => {
    const p = project()
    const packed = await makeRun(p)
    const plain = await makeRun(p, async () => 0)
    const runs = listOpenRuns(p)
    assert.equal(runs.length, 2)
    for (const run of runs) {
        const [m] = run.models
        assert.deepEqual(m?.tex, [
            "m/output/plots/m.tex",
            "m/output/plots/m_residuals.tex",
        ])
        assert.deepEqual(run.compare?.tex, ["compare/plots/res_compare.tex"])
        assert.equal(m?.workbook, join(run.dir, "m", "output", "m.xlsx"))
        assert.deepEqual(
            m?.plotSizes.map((s) => [s.width, s.rows]),
            [
                [76, 10],
                [100, 14],
            ],
        )
        // the sized plot files are not on disk in the packed run, but they read
        const file = m?.plotSizes[0]?.path.split("/").pop() ?? ""
        assert.match(readRunText(run.dir, `m/output/${file}`), /fit/)
    }
    assert.ok([packed.dir, plain.dir].every((d) => runs.some((r) => r.dir === d)))
})
