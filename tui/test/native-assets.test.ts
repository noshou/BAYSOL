// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of core/native-assets.ts: one unversioned native folder in the cache, a stamp
// written last, one version's files at a time, and the temporary fallback when the cache's
// files are locked. The cache and the fallback are folders made for the test.

import assert from "node:assert/strict"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { placeInCache, placeNative } from "../src/core/native-assets.js"
import { tempDir } from "./support/fixtures.js"

const bytes = (text: string): Uint8Array => new TextEncoder().encode(text)

test("the same version reuses the file and makes no versioned folder", () => {
    const dir = join(tempDir(), "native")
    const first = placeInCache(dir, "7za.exe", bytes("seven"), "v1")
    writeFileSync(first, "seven") // same size: a reuse leaves it as it is
    const mtime = readFileSync(first, "utf-8")
    assert.equal(placeInCache(dir, "7za.exe", bytes("seven"), "v1"), first)
    assert.equal(readFileSync(first, "utf-8"), mtime)
    assert.deepEqual(readdirSync(dir).sort(), [".version", "7za.exe"])
    // a second file of the same version joins the first
    placeInCache(dir, "pdfium.dll", bytes("pdf"), "v1")
    assert.deepEqual(readdirSync(dir).sort(), [".version", "7za.exe", "pdfium.dll"])
})

test("a new version replaces the old files", () => {
    const dir = join(tempDir(), "native")
    placeInCache(dir, "a.node", bytes("old-a"), "v1")
    placeInCache(dir, "b.node", bytes("old-b"), "v1")
    placeInCache(dir, "a.node", bytes("new-a!"), "v2")
    assert.deepEqual(readdirSync(dir).sort(), [".version", "a.node"])
    assert.equal(readFileSync(join(dir, "a.node"), "utf-8"), "new-a!")
    const stamp = JSON.parse(readFileSync(join(dir, ".version"), "utf-8"))
    assert.deepEqual(stamp, { version: "v2", files: { "a.node": 6 } })
})

test("a missing or corrupt stamp extracts again; a wrong size too", () => {
    const dir = join(tempDir(), "native")
    placeInCache(dir, "a.node", bytes("aaa"), "v1")
    writeFileSync(join(dir, ".version"), "{not json")
    writeFileSync(join(dir, "stray"), "x")
    placeInCache(dir, "a.node", bytes("aaa"), "v1")
    assert.deepEqual(readdirSync(dir).sort(), [".version", "a.node"])
    writeFileSync(join(dir, "a.node"), "cut")
    writeFileSync(join(dir, "a.node"), "c")
    placeInCache(dir, "a.node", bytes("aaa"), "v1")
    assert.equal(readFileSync(join(dir, "a.node"), "utf-8"), "aaa")
    assert.equal(existsSync(join(dir, ".version")), true)
})

test("a locked file leaves the cache alone and goes to the temporary folder", () => {
    const root = tempDir()
    const cache = join(root, "native")
    const fallback = join(root, "tmp-native")
    placeInCache(cache, "a.node", bytes("old"), "v1")
    const locked = (): never => {
        throw Object.assign(new Error("busy"), { code: "EBUSY" })
    }
    const path = placeNative(
        () => cache,
        () => fallback,
        "a.node",
        bytes("newer"),
        "v2",
        locked,
    )
    assert.equal(path, join(fallback, "a.node"))
    assert.equal(readFileSync(path, "utf-8"), "newer")
    // the cache still holds the old version, untouched, with no second copy
    assert.deepEqual(readdirSync(cache).sort(), [".version", "a.node"])
    assert.equal(readFileSync(join(cache, "a.node"), "utf-8"), "old")
    // an unusable cache folder falls back too
    const blocked = join(root, "file")
    writeFileSync(blocked, "x")
    const other = placeNative(
        () => join(blocked, "native"),
        () => fallback,
        "b.node",
        bytes("b"),
        "v2",
    )
    assert.equal(other, join(fallback, "b.node"))
})
