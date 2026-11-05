// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import {
    existsSync,
    mkdirSync,
    mkdtempSync,
    readdirSync,
    readFileSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { hasRuns, recordRun, runIds, stamp } from "../src/store/runs.js"

const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

test("stamps sort as text and hold no separator", () => {
    assert.equal(stamp(new Date("2026-11-02T15:30:45.123Z")), "20261102T153045123Z")
    assert.doesNotMatch(stamp(new Date()), /[:/\\]/)
})

test("a run is recorded", () => {
    const project = tempRoot()
    writeFileSync(join(project, "settings.json"), '{"settings": 1}\n')
    const out = tempRoot()
    writeFileSync(join(out, "m1.xlsx"), "x")
    writeFileSync(join(out, "m1.txt"), "plot")
    mkdirSync(join(out, "plots"))
    writeFileSync(join(out, "plots", "m1.tex"), "tex")
    const log = join(tempRoot(), "demo.LOG")
    writeFileSync(log, "log")
    // a new project has no logs/ or data/, so no runs
    assert.equal(existsSync(join(project, "logs")), false)
    assert.equal(hasRuns(project, "logs"), false)
    assert.equal(hasRuns(project, "data"), false)
    // a successful run fills logs/<time> and data/<time>
    const { id, logs, data } = recordRun(project, {
        models: ["m1"],
        logFile: log,
        outputDir: out,
    })
    assert.deepEqual(
        new Set(readdirSync(logs)),
        new Set(["models.json", "settings.json", "demo.LOG"]),
    )
    assert.deepEqual(JSON.parse(readFileSync(join(logs, "models.json"), "utf-8")), ["m1"])
    assert.equal(readFileSync(join(logs, "settings.json"), "utf-8"), '{"settings": 1}\n')
    assert.ok(data !== undefined)
    assert.deepEqual(new Set(readdirSync(data)), new Set(["m1.xlsx", "m1.txt", "plots"]))
    assert.ok(existsSync(join(data, "plots", "m1.tex")))
    assert.deepEqual(runIds(project, "logs"), [id])
    assert.deepEqual(runIds(project, "data"), [id])
    // a failed run leaves a log record and no data
    const failed = recordRun(project, { models: ["m1"], logFile: log })
    assert.equal(failed.data, undefined)
    assert.equal(runIds(project, "logs").length, 2)
    assert.equal(runIds(project, "data").length, 1)
    assert.ok(!runIds(project, "data").includes(failed.id))
    // runs in quick succession never share or overwrite a folder
    for (let i = 0; i < 5; i++) recordRun(project, { models: [] })
    assert.equal(new Set(runIds(project, "logs")).size, 7)
})
