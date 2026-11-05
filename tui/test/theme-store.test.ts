// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { readThemeMode, themeFile, writeThemeMode } from "../src/store/theme-store.js"

const folder = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

test("no file means dark", () => {
    assert.equal(readThemeMode(folder()), "dark")
})

test("what is saved is what is read", () => {
    const dir = folder()
    assert.ok(writeThemeMode(dir, "light"))
    assert.equal(readThemeMode(dir), "light")
    assert.ok(writeThemeMode(dir, "dark"))
    assert.equal(readThemeMode(dir), "dark")
})

test("a file that says something else, or is garbled, means dark", () => {
    const dir = folder()
    writeFileSync(themeFile(dir), '{"mode":"pink"}')
    assert.equal(readThemeMode(dir), "dark")
    writeFileSync(themeFile(dir), "{ not json")
    assert.equal(readThemeMode(dir), "dark")
})

test("a garbled file is kept as .corrupt when the theme is saved", () => {
    const dir = folder()
    writeFileSync(themeFile(dir), "{ not json")
    assert.ok(writeThemeMode(dir, "light"))
    assert.equal(readFileSync(`${themeFile(dir)}.corrupt`, "utf-8"), "{ not json")
    assert.equal(readThemeMode(dir), "light")
    assert.ok(existsSync(themeFile(dir)))
})

test("an unwritable folder is not an error", () => {
    assert.equal(writeThemeMode("/proc/baysol-nope", "light"), false)
})
