// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { readThemeName, themeFile, writeThemeName } from "../src/store/theme-store.js"
import { defaultTheme, type ThemeName, themeByName, themes } from "../src/ui/theme.js"

const folder = () => mkdtempSync(join(tmpdir(), "baysol-test-"))
const known = themes.map((theme) => theme.nm)
const read = (dir: string) => readThemeName(dir, known, defaultTheme.nm)

test("the default theme is one of the themes", () => {
    assert.ok(themes.includes(defaultTheme))
})

test("no file means the default", () => {
    assert.equal(read(folder()), defaultTheme.nm)
})

test("what is saved is what is read, for every theme there is", () => {
    const dir = folder()
    for (const name of known) {
        assert.ok(writeThemeName(dir, name))
        assert.equal(read(dir), name)
    }
})

test("a name no theme has, or a garbled file, means the default", () => {
    const dir = folder()
    writeFileSync(themeFile(dir), '{"theme":"no such theme"}')
    assert.equal(read(dir), defaultTheme.nm)
    writeFileSync(themeFile(dir), "{ not json")
    assert.equal(read(dir), defaultTheme.nm)
    // the file of the first version said `mode`, which no theme is called
    writeFileSync(themeFile(dir), '{"mode":"light"}')
    assert.equal(read(dir), defaultTheme.nm)
})

test("a garbled file is kept as .corrupt when the theme is saved", () => {
    const dir = folder()
    writeFileSync(themeFile(dir), "{ not json")
    assert.ok(writeThemeName(dir, "rose"))
    assert.equal(readFileSync(`${themeFile(dir)}.corrupt`, "utf-8"), "{ not json")
    assert.equal(read(dir), "rose")
    assert.ok(existsSync(themeFile(dir)))
})

test("an unwritable folder is not an error", () => {
    // a folder below a regular file can never be made
    const dir = folder()
    writeFileSync(join(dir, "a-file"), "x")
    assert.equal(writeThemeName(join(dir, "a-file", "sub"), "rose"), false)
})

test("the registry: unique names, a logo each, findable by name", () => {
    assert.equal(new Set(known).size, themes.length)
    for (const theme of themes) {
        assert.ok(theme.lg !== "" && theme.nm !== "")
        assert.equal(themeByName(theme.nm), theme)
    }
    assert.equal(themeByName("nope"), undefined)
})

test("a theme name is checked by the compiler against the theme arrays", () => {
    const real: ThemeName = "graphite"
    // @ts-expect-error a name that is in neither array does not compile
    const missing: ThemeName = "no such theme"
    // `tsc` fails here if the line above ever stops being an error
    assert.ok(themeByName(real))
    assert.equal(themeByName(missing), undefined)
})
