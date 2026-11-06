// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { type BufferRow, bufferFile, writeSolutes } from "../src/store/buffer.js"
import { setEnergy, writeData } from "../src/store/data.js"
import { addModel } from "../src/store/models.js"
import { projectReadiness } from "../src/store/readiness.js"
import { fixture } from "./support/fixtures.js"

const row = (fixture("buffer/buffer.json").solutes as BufferRow[])[0] as BufferRow

/** A project folder and a model file in another folder. */
function setup(): { dir: string; model: string } {
    const dir = mkdtempSync(join(tmpdir(), "baysol-test-"))
    const model = join(mkdtempSync(join(tmpdir(), "baysol-test-")), "m.pdb")
    writeFileSync(model, "ATOM\n")
    return { dir, model }
}

const curve = {
    q: Array.from({ length: 10 }, (_, k) => 0.01 * (k + 1)),
    i: Array.from({ length: 10 }, (_, k) => 10 - k),
    sigma: Array.from({ length: 10 }, () => 0.1),
}

test("readiness: a run needs a model and a non-empty buffer", () => {
    const { dir, model } = setup()
    const ref = { id: "p", dir }
    assert.deepEqual(projectReadiness(ref), {
        models: false, buffer: false, data: false, run: false,
    })
    addModel(dir, model)
    assert.deepEqual(projectReadiness(ref), {
        models: true, buffer: false, data: false, run: false,
    })
    writeSolutes(dir, [])
    assert.equal(projectReadiness(ref).run, false, "an empty buffer is not a buffer")
    writeSolutes(dir, [row])
    assert.deepEqual(projectReadiness(ref), {
        models: true, buffer: true, data: false, run: false,
    })
    // data without an energy is not ready; the energy makes it ready
    writeData(dir, curve, "c.dat", "A-1")
    assert.equal(projectReadiness(ref).data, false)
    assert.equal(projectReadiness(ref).run, false)
    setEnergy(dir, 12400)
    assert.deepEqual(projectReadiness(ref), {
        models: true, buffer: true, data: true, run: true,
    })
    writeFileSync(join(dir, "data.json"), "{ garbled")
    assert.equal(projectReadiness(ref).run, false)
})

test("readiness: an unreadable buffer or a missing folder counts as missing", () => {
    const { dir, model } = setup()
    addModel(dir, model)
    writeFileSync(bufferFile(dir), "{ not json")
    assert.equal(projectReadiness({ id: "p", dir }).buffer, false)
    mkdirSync(join(dir, "x"))
    const gone = join(dir, "nowhere")
    assert.equal(projectReadiness({ id: "g", dir: gone }).run, false)
})
