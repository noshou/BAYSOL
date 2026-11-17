// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/view-cache.ts: the folder of the viewers' temporary copies, the sweep of
// the folders that dead processes left, and the size cap. Every function is given a base
// folder made for the test, so the real temporary folder is never touched.

import assert from "node:assert/strict"
import { existsSync, mkdirSync, utimesSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import {
    makeViewFolder,
    pidAlive,
    removeProcessFolder,
    sweepDeadFolders,
    touchCopy,
    trimCopies,
    viewFolder,
} from "../src/store/view-cache.js"
import { tempDir } from "./support/fixtures.js"

/** Makes a copy folder holding one file of `bytes` bytes, last used `age` seconds ago. */
function copy(folder: string, name: string, bytes: number, age: number): void {
    const dir = join(folder, name)
    mkdirSync(dir, { recursive: true })
    const file = join(dir, "book.xlsx")
    writeFileSync(file, Buffer.alloc(bytes))
    const time = new Date(Date.now() - age * 1000)
    utimesSync(file, time, time)
    utimesSync(dir, time, time)
}

test("a process's copies live in <base>/baysol-<pid>/view and go with its folder", () => {
    const base = tempDir()
    const folder = makeViewFolder(base, 4242)
    assert.equal(folder, viewFolder(base, 4242))
    assert.equal(folder, join(base, "baysol-4242", "view"))
    assert.ok(existsSync(folder))
    removeProcessFolder(base, 4242)
    assert.equal(existsSync(join(base, "baysol-4242")), false)
})

test("the sweep removes only baysol-<pid> folders of dead pids", () => {
    const base = tempDir()
    const dead = makeViewFolder(base, 111)
    makeViewFolder(base, 222)
    makeViewFolder(base, 333)
    // names that are close but not the pattern, and a plain file with the pattern's name
    const others = ["baysol-abc", "baysol-12x", "baysol-0", "baysol-111-x", "other-111"]
    for (const other of others)
        mkdirSync(join(base, other))
    writeFileSync(join(base, "baysol-444"), "a file")
    writeFileSync(join(dead, "book.xlsx"), "x")
    const removed = sweepDeadFolders(base, 333, (pid) => pid === 222)
    assert.deepEqual(removed, ["baysol-111"])
    assert.equal(existsSync(join(base, "baysol-111")), false)
    // alive, own, near-misses and the file stay
    for (const kept of [
        "baysol-222",
        "baysol-333",
        "baysol-abc",
        "baysol-12x",
        "baysol-0",
        "baysol-111-x",
        "other-111",
        "baysol-444",
    ])
        assert.ok(existsSync(join(base, kept)), kept)
})

test("the sweep with the real check keeps this process and a missing base is fine", () => {
    const base = tempDir()
    makeViewFolder(base, process.pid)
    assert.deepEqual(sweepDeadFolders(base, process.pid + 1), [])
    assert.ok(existsSync(join(base, `baysol-${process.pid}`)))
    assert.deepEqual(sweepDeadFolders(join(base, "nope"), 1), [])
    assert.equal(pidAlive(process.pid), true)
})

test("the cap removes the oldest copies first and never the one kept", () => {
    const base = tempDir()
    const folder = makeViewFolder(base, 1)
    copy(folder, "old", 400, 300)
    copy(folder, "mid", 400, 200)
    copy(folder, "new", 400, 100)
    // under the cap: nothing goes
    assert.deepEqual(trimCopies(folder, 1200), [])
    // 1200 bytes against a cap of 900: the oldest goes
    assert.deepEqual(trimCopies(folder, 900), ["old"])
    // the oldest is kept, so the next oldest goes instead
    assert.deepEqual(trimCopies(folder, 400, "mid"), ["new"])
    assert.ok(existsSync(join(folder, "mid")))
    // the one kept stays even when it alone is over the cap
    assert.deepEqual(trimCopies(folder, 10, "mid"), [])
    assert.deepEqual(trimCopies(join(base, "none"), 1), [])
})

test("a copy that was used again is the newest", () => {
    const folder = makeViewFolder(tempDir(), 1)
    copy(folder, "a", 400, 300)
    copy(folder, "b", 400, 200)
    touchCopy(join(folder, "a"))
    // the file inside is still old, but the folder was touched: measured by its own time
    // as well, so `a` is now the newest and `b` goes
    utimesSync(join(folder, "a", "book.xlsx"), new Date(), new Date())
    assert.deepEqual(trimCopies(folder, 400), ["b"])
})
