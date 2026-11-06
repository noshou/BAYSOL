// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { hasFinishedRun, hasRuns, runIds, runStatus } from "../src/store/runs.js"

const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

/** Makes `runs/<id>/` with a `run.json` holding `json` (none when `undefined`). */
function makeRun(project: string, id: string, json?: string): void {
    const dir = join(project, "runs", id)
    mkdirSync(dir, { recursive: true })
    if (json !== undefined) writeFileSync(join(dir, "run.json"), json)
}

test("a project with no runs/ folder has no runs", () => {
    const project = tempRoot()
    assert.deepEqual(runIds(project), [])
    assert.equal(hasRuns(project), false)
    assert.equal(hasFinishedRun(project), false)
})

test("runs are the folders of runs/, oldest first, files are not runs", () => {
    const project = tempRoot()
    makeRun(project, "20261102T153045Z")
    makeRun(project, "20261101T000000Z")
    writeFileSync(join(project, "runs", "notes.txt"), "x")
    // the old layout is not read: logs/ and data/ hold no runs
    mkdirSync(join(project, "logs", "20250101T000000Z"), { recursive: true })
    mkdirSync(join(project, "data", "20250101T000000Z"), { recursive: true })
    assert.deepEqual(runIds(project), ["20261101T000000Z", "20261102T153045Z"])
    assert.equal(hasRuns(project), true)
})

test("run.json says how a run ended; a bad file says nothing", () => {
    const project = tempRoot()
    makeRun(project, "a", '{"status": "running"}')
    makeRun(project, "b", '{"status": "failed"}')
    makeRun(project, "c", '{"status": "bogus"}')
    makeRun(project, "d", "{ not json")
    makeRun(project, "e")
    assert.equal(runStatus(project, "a"), "running")
    assert.equal(runStatus(project, "b"), "failed")
    for (const id of ["c", "d", "e", "missing"])
        assert.equal(runStatus(project, id), undefined, id)
    // no run is done yet: runs exist, none finished
    assert.equal(hasRuns(project), true)
    assert.equal(hasFinishedRun(project), false)
    makeRun(project, "f", '{"status": "done", "models": []}')
    assert.equal(runStatus(project, "f"), "done")
    assert.equal(hasFinishedRun(project), true)
})
