// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the runs of a project: the open runs and their rows, the run list, the
// deletion of a run, the files of a run and the restores of the logs menu.
//
// Contents:
//   1. Open runs
//   2. Run list, delete run and the files of a run
//   3. The options and the restores

import assert from "node:assert/strict"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { dirname, join, sep } from "node:path"
import { test } from "node:test"
import { RUN_FLOW } from "../src/core/environment.js"
import { ChangedOnDiskError, isFolder, writeJson } from "../src/core/file-system.js"
import { LogsRuns } from "../src/screens/logs-menu.js"
import { noWorkbookNote, openRowText, TextPager } from "../src/screens/open-runs.js"
import {
    type BufferRow,
    readConditions,
    readSolutes,
    writeSolutes,
} from "../src/store/buffer.js"
import { readDataInfo, writeData } from "../src/store/data.js"
import { isoStamp, RunInProgressError } from "../src/store/projects.js"
import {
    conditionsText,
    deleteRun,
    firstErrorLine,
    folderSize,
    listOpenRuns,
    listRuns,
    type OpenRun,
    openRows,
    prettyJson,
    RUN_GONE,
    readLogText,
    readRunFile,
    runFilePath,
    runFileSizes,
    runItems,
    sizeText,
} from "../src/store/run-logs.js"
import {
    bufferFacts,
    RestoreError,
    restoreBuffer,
    restoreErrorNote,
    restoreSettings,
    restoreUnits,
    watchBuffer,
} from "../src/store/run-restores.js"
import { settingsFile } from "../src/store/settings-store.js"
import { fixture, runOn, tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. Open runs
// ========================================================================================

/** Makes `runs/<id>/run.json` and the files (paths relative to the run folder). */
function makeOpenRun(
    project: string,
    id: string,
    json: unknown,
    files: string[] = [],
): void {
    const run = join(project, "runs", id)
    mkdirSync(run, { recursive: true })
    if (json !== undefined) writeFileSync(join(run, "run.json"), JSON.stringify(json))
    for (const f of files) {
        mkdirSync(dirname(join(run, f)), { recursive: true })
        writeFileSync(join(run, f), "x")
    }
}

test("runs and models: newest first, statuses, workbook only for a done model", () => {
    const p = tempDir()
    makeOpenRun(p, runOn("2026-11-01"), {
        status: "failed",
        models: [
            { name: "a", status: "done", files: ["a.xlsx"] },
            { name: "b", status: "failed", error: "WLSError: need n ≥ 3 points" },
            { name: "c", status: "skipped" },
        ],
    }, ["a.xlsx", "b-plots.txt"])
    const one = {
        status: "done",
        models: [{ name: "one", status: "done", files: ["res.xlsx"] }],
    }
    makeOpenRun(p, runOn("2026-11-02"), one, ["res.xlsx"])
    // `running` with nobody behind it: its models are interrupted, never openable
    makeOpenRun(p, runOn("2026-11-03"), {
        status: "running", pid: 999999999, host: "elsewhere",
        models: [{ name: "x", status: "running" }, { name: "../evil", status: "done" }],
    }, ["x.xlsx"])
    makeOpenRun(p, runOn("2026-11-04"), undefined)
    const runs = listOpenRuns(p)
    assert.deepEqual(runs.map((r) => r.id), [
        runOn("2026-11-04"), runOn("2026-11-03"), runOn("2026-11-02"), runOn("2026-11-01"),
    ])
    assert.equal(runs[0]?.state, "unknown")
    assert.deepEqual(runs[0]?.models, [])
    // the bad name is dropped, the unfinished model has no workbook
    assert.deepEqual(runs[1]?.models.map((m) => [m.name, m.state, m.workbook]),
        [["x", "interrupted", undefined]])
    assert.match(runs[2]?.models[0]?.workbook ?? "", /res\.xlsx$/)
    const [a, b, c] = runs[3]?.models ?? []
    assert.equal(a?.state, "done")
    assert.match(a?.workbook ?? "", /a\.xlsx$/)
    assert.equal(b?.state, "failed")
    assert.equal(b?.workbook, undefined)
    assert.equal(b?.error, "WLSError: need n ≥ 3 points")
    assert.match(b?.plots ?? "", /b-plots\.txt$/)
    assert.equal(c?.state, "skipped")
})

test("old and new run names list together, newest instant first, an odd name last", () => {
    const p = tempDir()
    const done = { status: "done", models: [{ name: "one", status: "done" }] }
    for (const id of [
        runOn("2026-11-01"),
        "10-00-00-000_GMT_+0100_2026-11-08", // 09:00Z on the 8th
        "23-35-29-123_EST_-0500_2026-11-07", // 04:35Z on the 8th
        runOn("2026-11-08"),
        "odd-name",
    ])
        makeOpenRun(p, id, done)
    assert.deepEqual(
        listOpenRuns(p).map((r) => r.id),
        [
            "10-00-00-000_GMT_+0100_2026-11-08",
            "23-35-29-123_EST_-0500_2026-11-07",
            runOn("2026-11-08"),
            runOn("2026-11-01"),
            "odd-name",
        ],
    )
})

test("a vanishing project folder gives no runs, a live model stays running", () => {
    assert.deepEqual(listOpenRuns(join(tempDir(), "gone")), [])
    const p = tempDir()
    const stamp = (ms: number): string => `${new Date(ms).toISOString().slice(0, 19)}Z`
    makeOpenRun(p, runOn("2026-11-01"), {
        status: "running", pid: process.pid, host: hostname(), heartbeat: stamp(Date.now()),
        models: [{ name: "m", status: "running" }],
    })
    assert.equal(listOpenRuns(p)[0]?.state, "live")
    assert.equal(listOpenRuns(p)[0]?.models[0]?.state, "running")
})

test("rows: several models are listed under a heading, one model goes straight on", () => {
    const model = (name: string) => ({
        name, state: "done" as const, error: undefined, workbook: undefined, plots: "",
        plotSizes: [], overrides: [] as string[], tex: [] as string[],
    })
    const run = (id: string, names: string[]): OpenRun => ({
        id, dir: "", state: "done", models: names.map(model), compare: undefined,
    })
    const rows = openRows([run("r3", []), run("r2", ["one"]), run("r1", ["a", "b"])])
    assert.deepEqual(
        rows.map((r) =>
            r.kind === "run" ? `run ${r.run.id}`
                : `${r.model.name}${r.nested ? " nested" : ""}`,
        ),
        ["run r3", "one", "run r1", "a nested", "b nested"],
    )
    const [, single, , nested] = rows
    assert.match(single && openRowText(single).text, /^r2 +one$/)
    assert.equal(nested && openRowText(nested).text, "  a")
})

test("rows: the comparison is a row only for a run of several models", () => {
    const model = (name: string) => ({
        name, state: "done" as const, error: undefined, workbook: undefined, plots: "",
        plotSizes: [], overrides: [] as string[], tex: [] as string[],
    })
    const run = (id: string, names: string[]): OpenRun => ({
        id, dir: "", state: "done", models: names.map(model), compare: model("comparison"),
    })
    const kinds = (r: OpenRun) => openRows([r]).map((row) => row.kind)
    assert.deepEqual(kinds(run("r1", ["a"])), ["model"])
    assert.deepEqual(kinds(run("r2", ["a", "b"])), ["run", "model", "model", "compare"])
})

test("the comparison and the overrides of a run, and its plot sizes", () => {
    const p = tempDir()
    const sizes = [
        { file: "one-plots_130x13.txt", width: 130, rows: 18 },
        { file: "one-plots_76x5.txt", width: 76, rows: 10 },
        { file: "../evil.txt", width: 76, rows: 10 },
        { file: "/abs.txt", width: 76, rows: 10 },
        { file: "a\\b.txt", width: 76, rows: 10 },
        { file: "one-plots_x.txt", width: "wide", rows: 10 },
    ]
    makeOpenRun(p, runOn("2026-11-01"), {
        status: "done",
        models: [
            {
                name: "one", status: "done", files: ["one.xlsx"],
                plot_sizes: sizes, overrides: ["Q_MAX", 7],
            },
            { name: "two", status: "done" },
        ],
        compare: {
            status: "done",
            files: ["compare.tsv", "compare-plots.txt"],
            models: ["one", "two"],
            references: [],
            plot_sizes: [{ file: "compare-plots_76x5.txt", width: 76, rows: 9 }],
        },
    }, ["one.xlsx", "compare.tsv"])
    makeOpenRun(p, runOn("2026-11-02"), {
        status: "done",
        models: [{ name: "one", status: "done" }],
        compare: { status: "failed", files: [], error: "boom: no references" },
    })
    makeOpenRun(p, runOn("2026-11-03"), { status: "done", models: [] })
    const [none, failed, run] = listOpenRuns(p)
    assert.equal(none?.compare, undefined)
    assert.equal(failed?.compare?.state, "failed")
    assert.equal(failed?.compare?.error, "boom: no references")
    assert.equal(failed?.compare?.workbook, undefined)
    const [one, two] = run?.models ?? []
    assert.deepEqual(one?.overrides, ["Q_MAX"])
    assert.deepEqual(two?.overrides, [])
    // the odd names are dropped, the sizes come smallest first, inside the run folder
    assert.deepEqual(
        one?.plotSizes.map((f) => [f.path.slice(run?.dir.length), f.width, f.rows]),
        [
            [`${sep}one-plots_76x5.txt`, 76, 10],
            [`${sep}one-plots_130x13.txt`, 130, 18],
        ],
    )
    const c = run?.compare
    assert.equal(c?.name, "comparison")
    assert.match(c?.workbook ?? "", /compare\.tsv$/)
    assert.match(c?.plots ?? "", /compare-plots\.txt$/)
    assert.equal(c?.plotSizes.length, 1)
    // the row comes after the models, nested under a heading; a lone model has none
    const rows = openRows([run as OpenRun, failed as OpenRun])
    assert.deepEqual(
        rows.map((r) => (r.kind === "run" ? "run" : `${r.kind}:${r.model.name}`)),
        [
            "run", "model:one", "model:two", "compare:comparison",
            "model:one",
        ],
    )
    assert.equal(rows[3] && openRowText(rows[3]).text, "  comparison")
    assert.equal(rows.length, 5)
    assert.equal(rows[1] && openRowText(rows[1]).text, "  one *")
    assert.equal(rows[2] && openRowText(rows[2]).text, "  two")
    assert.equal(
        noWorkbookNote((failed as OpenRun).compare as never),
        "comparison failed: boom: no references",
    )
})

test("a path of run.json is safe only inside the run folder", () => {
    const d = join("x", "run")
    assert.equal(runFilePath(d, "a/b.txt"), join(d, "a", "b.txt"))
    for (const bad of ["../x", "a/../x", "/x", "", "a//b", "C:/x", "a\\b", 5, null])
        assert.equal(runFilePath(d, bad), undefined, String(bad))
})

test("notes for a model with nothing to open say why", () => {
    const m = (state: string, error?: string) =>
        ({ name: "m", state, error, workbook: undefined, plots: "" }) as never
    assert.equal(noWorkbookNote(m("running")), "m is still running")
    assert.equal(noWorkbookNote(m("failed", "WLSError: x")), "m failed: x")
    assert.equal(noWorkbookNote(m("failed")), "m failed")
    assert.equal(noWorkbookNote(m("aborted")), "m was aborted: no workbook")
    assert.equal(noWorkbookNote(m("done")), "m has no workbook")
})

test("the first error line comes from the ERRORS section, without the model prefix", () => {
    const log = [
        "datetime\tnow", "--- result ---", "status\tfailed", "", "=== ERRORS ===",
        "model crambin: WLSError: need n ≥ 3 points (got 2)", "Stacktrace:", " [1] foo",
        "", "model other: Boom",
    ].join("\n")
    assert.equal(firstErrorLine(log), "WLSError: need n ≥ 3 points (got 2)")
    const tui = "=== ERRORS ===\n\ntui: julia ended unexpectedly (exit code 3)\n"
    assert.equal(firstErrorLine(tui), "tui: julia ended unexpectedly (exit code 3)")
    assert.equal(firstErrorLine("no errors here"), undefined)
    assert.equal(firstErrorLine("=== ERRORS ===\n\n"), undefined)
})

// ========================================================================================
// 2. Run list, delete run and the files of a run
// ========================================================================================

/** A project folder with an empty `runs/`. */
function project(): string {
    const dir = tempDir()
    mkdirSync(join(dir, "runs"))
    return dir
}

/** Makes `runs/<id>/` with a `run.json` of `json` (none for `undefined`) and log files. */
function makeRun(
    dir: string,
    id: string,
    json?: unknown,
    files: Record<string, string> = {},
) {
    const run = join(dir, "runs", id)
    mkdirSync(run, { recursive: true })
    if (json !== undefined) writeFileSync(join(run, "run.json"), writeJson(json))
    for (const [name, text] of Object.entries(files)) writeFileSync(join(run, name), text)
    return run
}

/** The `run.json` of a run whose process is alive (this one) and beats now. */
const liveJson = {
    status: "running",
    pid: process.pid,
    host: hostname(),
    heartbeat: isoStamp(Date.now()),
}

test("delete run removes the whole folder and only that one", () => {
    const dir = project()
    const keep = makeRun(dir, runOn("2026-11-01"), { status: "done" }, { "run.LOG": "x" })
    const run = makeRun(dir, runOn("2026-11-02"), { status: "done" }, { "run.LOG": "y" })
    mkdirSync(join(run, "model"))
    writeFileSync(join(run, "model", "model.LOG"), "z")
    deleteRun(dir, runOn("2026-11-02"))
    assert.equal(existsSync(run), false)
    assert.equal(isFolder(keep), true)
    deleteRun(dir, runOn("2026-11-02")) // already gone: no error
})

test("delete run is refused while a run is live, and nothing is removed", () => {
    const dir = project()
    const live = makeRun(dir, runOn("2026-11-02"), liveJson)
    const old = makeRun(dir, runOn("2026-11-01"), { status: "done" })
    for (const id of [runOn("2026-11-02"), runOn("2026-11-01")])
        assert.throws(() => deleteRun(dir, id), RunInProgressError, id)
    assert.equal(isFolder(live), true)
    assert.equal(isFolder(old), true)
})

test("delete run takes a name of runs/ only, never a path", () => {
    const dir = project()
    const run = makeRun(dir, runOn("2026-11-01"), { status: "done" })
    for (const bad of ["", ".start", "..", "../runs", "a/b"])
        assert.throws(() => deleteRun(dir, bad), /not a run/, JSON.stringify(bad))
    assert.equal(isFolder(run), true)
})

test("the run.LOG text is read plain, with a cap, and says why it cannot be", () => {
    const dir = project()
    const files = { "run.LOG": "a\tb\n" }
    const run = makeRun(dir, runOn("2026-11-01"), { status: "done" }, files)
    assert.equal(readLogText(run), "a\tb\n")
    const bare = makeRun(dir, runOn("2026-11-02"), { status: "done" })
    assert.throws(() => readLogText(bare), /no run\.LOG/)
    writeFileSync(join(bare, "run.LOG"), "x".repeat(RUN_FLOW.log.maxBytes + 1))
    assert.throws(() => readLogText(bare), /too large/)
    rmSync(run, { recursive: true })
    assert.throws(() => readLogText(run), new RegExp(RUN_GONE))
    assert.equal(isFolder(run), false)
})

test("a run's files are read plain: any name, a cap, and why one cannot be", () => {
    const dir = project()
    const files = { "plots.txt": "p\n" }
    const run = makeRun(dir, runOn("2026-11-01"), { status: "done" }, files)
    assert.equal(readRunFile(run, "plots.txt"), "p\n")
    assert.throws(() => readRunFile(run, "buffer.json"), /this run has no buffer\.json/)
    assert.deepEqual(
        [...runFileSizes(run).keys()].sort(),
        ["plots.txt", "run.json"],
        "the files of the run",
    )
    assert.equal(runFileSizes(join(dir, "nope")).size, 0)
    writeFileSync(join(run, "settings.json"), "x".repeat(RUN_FLOW.log.maxBytes + 1))
    assert.throws(() => readRunFile(run, "settings.json"), /settings\.json is too large/)
})

test("the run list: newest first, each state, models, and a bad file is `unknown`", () => {
    const dir = project()
    makeRun(dir, runOn("2026-11-01"), { status: "done", models: [{ name: "a" }] })
    makeRun(dir, runOn("2026-11-02"), { status: "failed", models: [{ path: "/x/b.cif" }] })
    makeRun(dir, runOn("2026-11-03"), { status: "aborted" })
    // `running` with nobody behind it: interrupted (a dead pid on this host)
    makeRun(dir, runOn("2026-11-04"), {
        status: "running",
        pid: 2 ** 22 + 5,
        host: hostname(),
        heartbeat: isoStamp(Date.now()),
    })
    makeRun(dir, runOn("2026-11-05"))
    writeFileSync(join(dir, "runs", runOn("2026-11-05"), "run.json"), "{ not json")
    const list = listRuns(dir)
    assert.deepEqual(
        list.map((r) => r.id),
        [
            runOn("2026-11-05"),
            runOn("2026-11-04"),
            runOn("2026-11-03"),
            runOn("2026-11-02"),
            runOn("2026-11-01"),
        ],
    )
    assert.deepEqual(
        list.map((r) => r.state),
        ["unknown", "interrupted", "aborted", "failed", "done"],
    )
    assert.deepEqual(list[3]?.models, ["b.cif"])
    assert.deepEqual(list[4]?.models, ["a"])
    assert.ok(list.every((r) => !r.live))
})

test("a live run is listed as live, with its models and size", () => {
    const dir = project()
    const json = { ...liveJson, models: [{ name: "m" }] }
    makeRun(dir, runOn("2026-11-01"), json, { "run.LOG": "x" })
    const [run] = listRuns(dir)
    assert.equal(run?.state, "live")
    assert.equal(run?.live, true)
    assert.deepEqual(run?.models, ["m"])
    assert.ok((run?.size ?? 0) > 0)
})

test("a project without runs, and files among the runs, list nothing odd", () => {
    const dir = tempDir()
    assert.deepEqual(listRuns(dir), [])
    mkdirSync(join(dir, "runs"))
    writeFileSync(join(dir, "runs", "notes.txt"), "x")
    assert.deepEqual(listRuns(dir), [])
})

test("a folder that vanishes while the list is made is skipped, nothing throws", () => {
    const dir = project()
    makeRun(dir, runOn("2026-11-01"), { status: "done" })
    const gone = makeRun(dir, runOn("2026-11-02"), { status: "done" })
    rmSync(gone, { recursive: true })
    assert.deepEqual(
        listRuns(dir).map((r) => r.id),
        [runOn("2026-11-01")],
    )
    assert.equal(folderSize(gone), 0, "a folder that is gone is nothing")
})

test("sizes read in bytes, then KB, MB, GB", () => {
    assert.equal(sizeText(0), "0 B")
    assert.equal(sizeText(812), "812 B")
    assert.equal(sizeText(1024), "1.0 KB")
    assert.equal(sizeText(12.3 * 1024), "12.3 KB")
    assert.equal(sizeText(4 * 1024 * 1024), "4.0 MB")
    assert.equal(sizeText(3 * 1024 ** 3), "3.0 GB")
})

test("delete run: a deleted run is gone for the open pages, and the list loses it", () => {
    const dir = project()
    const run = makeRun(dir, runOn("2026-11-01"), { status: "done" }, { "run.LOG": "x" })
    deleteRun(dir, runOn("2026-11-01"))
    assert.deepEqual(listRuns(dir), [])
    // what a page open on the run reads now
    assert.throws(() => readRunFile(run, "run.LOG"), new RegExp(RUN_GONE))
})

test("the logs menu and `open runs` share ONE pager", () => {
    assert.equal(typeof TextPager, "function")
    assert.equal(typeof LogsRuns, "function")
})

// ========================================================================================
// 3. The options and the restores
// ========================================================================================

const rows = fixture("buffer/buffer.json").solutes as BufferRow[]
const DATA = "0.01\t100\t1\n0.02\t90\t1\n0.03\t80\t1\n0.04\t70\t1\n"
const MAPPING = {
    path: "/x/curve.dat",
    separator: "auto",
    sheet: "",
    skipRows: 2,
    comments: true,
    header: "auto",
    columns: {
        q: { spec: "col:1", column: 1 },
        i: { spec: "col:2", column: 2 },
        sigma: { spec: "col:3", column: 3 },
    },
}

test("the options: buffer, not recipe; every restore has its view; no delete-a-log", () => {
    assert.equal(runItems[0]?.label, "view run.LOG")
    for (const item of runItems) assert.ok(!item.file.includes("/"), item.label)
    for (const kind of ["settings", "buffer", "units"]) {
        assert.ok(runItems.some((i) => i.restore === kind && i.action === "restore"), kind)
        const view = kind === "units" ? "view units and energy" : `view ${kind}`
        assert.ok(runItems.some((i) => i.label === view), kind)
    }
    assert.ok(runItems.some((i) => i.label === "restore buffer"))
    assert.ok(!runItems.some((i) => /recipe/.test(i.label)))
    assert.ok(runItems.some((i) => i.action === "conditions"))
    assert.ok(runItems.some((i) => i.file === "solutes.json"))
    assert.ok(runItems.some((i) => i.file === "models.json"))
    assert.ok(!runItems.some((i) => /delete/.test(i.label)), "no delete in the logs menu")
})

test("pretty JSON for the pager, any other text as it is", () => {
    assert.equal(prettyJson('{"a":1}'), '{\n  "a": 1\n}\n')
    assert.equal(prettyJson("not json"), "not json")
})

test("the conditions are the first rows of each name of the LOG", () => {
    const log =
        "datetime\tnow\ntemperature_c       \t22.5\nph\t7.4\nsigma_ph\t0.1\n" +
        "energy_ev\t12000\n" +
        "\n--- output ---\nph\t99\n"
    assert.equal(
        conditionsText(log),
        "temperature 22.5 °C\npH          7.4\nσ           0.1\nenergy      12000 eV\n",
    )
    assert.equal(conditionsText("datetime\tnow\n"), "the LOG records no conditions\n")
})

test("restore settings: the run's values are set, a saved one it lacks is reset", () => {
    const root = tempDir()
    const dir = join(root, "projects", "p")
    mkdirSync(dir, { recursive: true })
    writeFileSync(settingsFile(dir), writeJson({ sampler: { N_DRAWS: { value: 1234 } } }))
    restoreSettings(dir, root, writeJson({}))
    assert.ok(!/1234/.test(readFileSync(settingsFile(dir), "utf-8")), "back to the default")
    assert.throws(() => restoreSettings(dir, root, "[1]"), RestoreError)
    assert.throws(() => restoreSettings(dir, root, "{ no"), /settings.json is not usable/)
})

test("restore buffer: one write of solutes, pH and σ; a concurrent save stays", () => {
    const dir = project()
    writeSolutes(dir, [rows[0] as BufferRow], { pH: 6, "sigma-pH": 0.2 })
    const text = writeJson({ solutes: rows, pH: 7.4, "sigma-pH": 0.1 })
    assert.deepEqual(bufferFacts(text).conditions, { pH: 7.4, "sigma-pH": 0.1 })
    restoreBuffer(dir, text)
    assert.equal(readSolutes(dir).length, rows.length)
    assert.deepEqual(readConditions(dir), { pH: 7.4, "sigma-pH": 0.1 })
    // the question reads the file, another copy saves, the restore refuses
    watchBuffer(dir)
    const other = writeJson({ solutes: [rows[1]], pH: 5, "sigma-pH": 0.3 })
    writeFileSync(join(dir, "buffer.json"), other)
    assert.throws(() => restoreBuffer(dir, text), ChangedOnDiskError)
    assert.match(restoreErrorNote(new ChangedOnDiskError("x")), /changed on disk/)
    assert.equal(readFileSync(join(dir, "buffer.json"), "utf-8"), other)
    assert.throws(() => restoreBuffer(dir, "{}"), /no solutes/)
    const bad = writeJson({ solutes: [{ kind: "?" }] })
    assert.throws(() => restoreBuffer(dir, bad), RestoreError)
})

test("restore units: only data.json changes, and there must be data", () => {
    const dir = project()
    const unitsOf = { units: "A-1", energy: 8000, energy_unit: "eV" }
    const info = writeJson({ ...unitsOf, mapping: MAPPING })
    assert.throws(() => restoreUnits(dir, info), /no data yet/)
    const curve = { q: [1, 2, 3, 4], i: [4, 3, 2, 1], sigma: [1, 1, 1, 1], dropped: 0 }
    writeData(dir, curve, "s", "nm-1", 5000)
    const table = readFileSync(join(dir, "data.tsv"), "utf-8")
    restoreUnits(dir, info)
    const status = readDataInfo(dir)
    assert.ok(status?.kind === "ok" && status.info.units === "A-1")
    assert.ok(status?.kind === "ok" && status.info.energy === 8000)
    assert.ok(status?.kind === "ok" && status.info.mapping === undefined, "no mapping")
    assert.equal(readFileSync(join(dir, "data.tsv"), "utf-8"), table)
    const bad = writeJson({ units: "x", energy_unit: "eV" })
    assert.throws(() => restoreUnits(dir, bad), RestoreError)
})

test("restore units brings the energy back with its unit label (required)", () => {
    const dir = project()
    const curve = { q: [1, 2, 3, 4], i: [4, 3, 2, 1], sigma: [1, 1, 1, 1], dropped: 0 }
    writeData(dir, curve, "s", "nm-1", 5000)
    restoreUnits(dir, writeJson({ units: "A-1", energy: 12, energy_unit: "keV" }))
    let status = readDataInfo(dir)
    assert.ok(status?.kind === "ok" && status.info.energy === 12)
    assert.ok(status?.kind === "ok" && status.info.energy_unit === "keV")
    // a snapshot without the label is not usable
    assert.throws(
        () => restoreUnits(dir, writeJson({ units: "A-1", energy: 8000 })),
        RestoreError,
    )
    status = readDataInfo(dir)
    assert.ok(status?.kind === "ok" && status.info.energy === 12)
    assert.throws(
        () => restoreUnits(dir, writeJson({ units: "A-1", energy: 8, energy_unit: "x" })),
        RestoreError,
    )
})

test("every restore refuses a live run and writes nothing", () => {
    const root = tempDir()
    const dir = join(root, "projects", "p")
    mkdirSync(join(dir, "runs"), { recursive: true })
    makeRun(dir, runOn("2026-11-01"), liveJson)
    const text = writeJson({ solutes: rows, pH: 7.4, "sigma-pH": 0.1 })
    const info = writeJson({ units: "nm-1", energy: 12000, energy_unit: "eV" })
    const calls: [string, () => void][] = [
        ["settings", () => restoreSettings(dir, root, "{}")],
        ["buffer", () => restoreBuffer(dir, text)],
        ["units", () => restoreUnits(dir, info)],
    ]
    for (const [name, call] of calls) assert.throws(call, RunInProgressError, name)
    for (const file of ["buffer.json", "data.json"])
        assert.equal(existsSync(join(dir, file)), false, file)
    assert.match(restoreErrorNote(new RunInProgressError(123)), /123/)
    assert.equal(restoreErrorNote(new Error("boom")), "could not restore")
})

test("a restore reads the plain files of a run and never writes into the run", () => {
    const dir = project()
    const text = writeJson({ solutes: rows, pH: 7.4, "sigma-pH": 0.1 })
    const files = {
        "buffer.json": text,
        "data.tsv": DATA,
        "data.json": writeJson({
            units: "A-1", energy: 9000, energy_unit: "eV", source: "c.dat", points: 4,
        }),
    }
    const run = makeRun(dir, runOn("2026-11-01"), { status: "done" }, files)
    const before = folderSize(run)
    const target = project()
    restoreBuffer(target, readRunFile(run, "buffer.json"))
    assert.equal(readSolutes(target).length, rows.length)
    for (const [name, body] of Object.entries(files))
        assert.equal(readFileSync(join(run, name), "utf-8"), body, name)
    assert.equal(folderSize(run), before)
    assert.deepEqual(
        [...runFileSizes(run).keys()].sort(),
        ["buffer.json", "data.json", "data.tsv", "run.json"],
    )
})
