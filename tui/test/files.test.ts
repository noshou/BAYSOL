// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import {
    entryNames,
    isDict,
    isFile,
    isFolder,
    isReadable,
    parseJson,
    readJson,
    readMap,
    sortNoCase,
    UnusableFileError,
    writeAtomic,
    writeJson,
} from "../src/core/files.js"

const tmp = (): string => mkdtempSync(join(tmpdir(), "baysol-test-"))

test("parseJson is strict, and an empty text is null", () => {
    assert.equal(parseJson(""), null)
    assert.equal(parseJson(" \n"), null)
    assert.deepEqual(parseJson('{"a": [1, 2.5, null]}'), { a: [1, 2.5, null] })
    for (const bad of ["{", "{'a': 1}", '{"a": 1,}', "// c\n{}", "{} {}", "nil"])
        assert.throws(() => parseJson(bad), SyntaxError, bad)
})

test("writeJson indents by two and ends in a newline", () => {
    const text = writeJson({ a: [1], b: { c: null } })
    assert.equal(text, '{\n  "a": [\n    1\n  ],\n  "b": {\n    "c": null\n  }\n}\n')
    assert.equal(writeJson({}), "{}\n")
    assert.deepEqual(parseJson(writeJson({ k: "é", n: 0.1 })), { k: "é", n: 0.1 })
})

test("readJson gives the fallback for a file that is not JSON", () => {
    const dir = tmp()
    const file = join(dir, "x.json")
    writeFileSync(file, "{ nope")
    assert.equal(readJson(file, "fb"), "fb")
    writeFileSync(file, "")
    assert.equal(readJson(file, "fb"), null)
    writeFileSync(file, "[1]")
    assert.deepEqual(readJson(file, "fb"), [1])
    assert.equal(readJson(join(dir, "none.json"), "fb"), "fb")
})

test("readMap says 'is not JSON' and 'is not <expected>'", () => {
    const dir = tmp()
    const file = join(dir, "m.json")
    const spec = {
        kind: "m",
        name: "m.json",
        expected: "a map with a",
        valid: (map: Record<string, unknown>) => "a" in map,
    }
    assert.deepEqual(readMap(file, spec), {}, "no file")
    writeFileSync(file, "")
    assert.deepEqual(readMap(file, spec), {}, "empty file")
    writeFileSync(file, '{"a": 1}')
    assert.deepEqual(readMap(file, spec), { a: 1 })
    writeFileSync(file, "{ a")
    assert.throws(
        () => readMap(file, spec),
        (e) =>
            e instanceof UnusableFileError &&
            e.message === "m.json is not JSON" &&
            e.kind === "m",
    )
    for (const text of ["[1]", '{"b": 1}', "3", "null "]) {
        writeFileSync(file, text)
        if (text.trim() === "null") assert.deepEqual(readMap(file, spec), {})
        else assert.throws(() => readMap(file, spec), /m.json is not a map with a/, text)
    }
})

test("isDict, isFile, isFolder, isReadable, entryNames, sortNoCase", () => {
    assert.equal(isDict({}), true)
    for (const x of [[], null, 1, "a", undefined]) assert.equal(isDict(x), false)
    const dir = tmp()
    mkdirSync(join(dir, "Sub"))
    writeFileSync(join(dir, "b.txt"), "")
    writeFileSync(join(dir, "A.txt"), "")
    assert.equal(isFolder(dir), true)
    assert.equal(isFolder(join(dir, "b.txt")), false)
    assert.equal(isFolder(join(dir, "none")), false)
    assert.equal(isFile(join(dir, "b.txt")), true)
    assert.equal(isFile(dir), false)
    assert.equal(isFile(join(dir, "none")), false)
    assert.equal(isReadable(join(dir, "b.txt")), true)
    assert.equal(isReadable(join(dir, "none")), false)
    assert.deepEqual(sortNoCase(entryNames(dir)), ["A.txt", "b.txt", "Sub"])
    assert.deepEqual(entryNames(join(dir, "none")), [])
    assert.deepEqual(sortNoCase(["b", "B", "a"]), ["a", "b", "B"])
    writeAtomic(join(dir, "deep", "er", "f.json"), "x")
    assert.equal(isFile(join(dir, "deep", "er", "f.json")), true)
})

test("a failed atomic write leaves no temporary file behind", () => {
    const dir = mkdtempSync(join(tmpdir(), "baysol-test-"))
    // the target is a folder, so the rename cannot succeed
    mkdirSync(join(dir, "target"))
    assert.throws(() => writeAtomic(join(dir, "target"), "x"))
    assert.deepEqual(readdirSync(dir), ["target"])
})
