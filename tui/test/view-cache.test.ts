// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/view-cache.ts: the size cap of the viewers' temporary copies. Every
// function is given a folder made for the test, so the real temporary folder is never
// touched. (Where the folder is and who sweeps it: test/scratch.test.ts.)

import assert from "node:assert/strict"
import { existsSync, mkdirSync, utimesSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { touchCopy, trimCopies } from "../src/store/view-cache.js"
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

test("the cap removes the oldest copies first and never the one kept", () => {
    const base = tempDir()
    const folder = join(base, "view")
    mkdirSync(folder)
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
    const folder = join(tempDir(), "view")
    mkdirSync(folder)
    copy(folder, "a", 400, 300)
    copy(folder, "b", 400, 200)
    touchCopy(join(folder, "a"))
    // the file inside is still old, but the folder was touched: measured by its own time
    // as well, so `a` is now the newest and `b` goes
    utimesSync(join(folder, "a", "book.xlsx"), new Date(), new Date())
    assert.deepEqual(trimCopies(folder, 400), ["b"])
})
