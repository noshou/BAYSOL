// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { ChangedOnDiskError, UnusableFileError, writeJson } from "../src/core/files.js"
import { MAX_ROWS } from "../src/store/limits.js"
import { ListFile } from "../src/store/list-file.js"

type Item = { name: string; n: number }

const list = new ListFile<Item>({
    fileName: "items.json",
    key: "items",
    kind: "items",
    plural: "items",
    noun: "item",
    problem: (e) =>
        typeof (e as Item).n === "number" && (e as Item).n >= 0 ? undefined : "n is bad",
    nameOf: (e) => e.name,
})

const dir = () => mkdtempSync(join(tmpdir(), "baysol-test-"))
const item = (name: string, n = 1): Item => ({ name, n })

test("no file is an empty list; a write makes it and keeps the other keys", () => {
    const d = dir()
    assert.deepEqual(list.read(d), [])
    writeFileSync(list.file(d), writeJson({ other: { a: 1 }, items: [item("a")] }))
    list.write(d, [item("b")])
    const map = JSON.parse(readFileSync(list.file(d), "utf-8"))
    assert.deepEqual(map.other, { a: 1 })
    assert.deepEqual(list.read(d), [item("b")])
    assert.equal(existsSync(`${list.file(d)}.tmp`), false)
})

test("a tracked read makes a later write after another save refuse", () => {
    const d = dir()
    list.write(d, [item("a")])
    list.read(d, { track: true })
    writeFileSync(list.file(d), writeJson({ items: [item("z")] })) // another copy
    assert.throws(() => list.write(d, [item("b")]), ChangedOnDiskError)
    assert.deepEqual(list.read(d), [item("z")], "nothing was written")
    list.read(d, { track: true }) // reopened
    list.write(d, [item("b")])
})

test("a plain read does not move the base", () => {
    const d = dir()
    list.write(d, [item("a")])
    list.read(d, { track: true })
    writeFileSync(list.file(d), writeJson({ items: [item("z")] }))
    list.read(d)
    assert.throws(() => list.write(d, []), ChangedOnDiskError)
})

test("an unusable file is told and never written over; reset keeps it", () => {
    const d = dir()
    for (const text of ["nope", "[]", '{"items": 3}', '{"items": [{"name":"a","n":-1}]}']) {
        writeFileSync(list.file(d), text)
        assert.throws(
            () => list.read(d),
            (e) => e instanceof UnusableFileError && e.kind === "items",
        )
        assert.throws(() => list.write(d, []), UnusableFileError)
        assert.equal(readFileSync(list.file(d), "utf-8"), text)
    }
    const kept = list.reset(d)
    assert.equal(kept, `${list.file(d)}.corrupt`)
    assert.equal(existsSync(list.file(d)), false)
    assert.equal(list.reset(d), undefined)
    list.write(d, [item("a")])
})

test("names differ without regard to case, on write and on read", () => {
    const d = dir()
    assert.throws(() => list.write(d, [item("A"), item(" a")]), /name in use/)
    assert.equal(existsSync(list.file(d)), false)
    writeFileSync(list.file(d), writeJson({ items: [item("A"), item("a")] }))
    assert.throws(() => list.read(d), UnusableFileError)
})

test("an invalid entry is refused with its reason", () => {
    assert.throws(() => list.write(dir(), [item("a", -1)]), /not a valid item: n is bad/)
})

test("the cap is MAX_ROWS", () => {
    const d = dir()
    const many = Array.from({ length: MAX_ROWS + 1 }, (_, i) => item(`i${i}`))
    assert.throws(() => list.write(d, many), /too many items/)
    list.write(d, many.slice(0, MAX_ROWS))
    assert.equal(list.read(d).length, MAX_ROWS)
})

test("remove drops one entry by name and keeps the rest and the other keys", () => {
    const d = dir()
    writeFileSync(
        list.file(d),
        writeJson({ keep: 1, items: [item("a"), item("B"), item("c")] }),
    )
    assert.equal(list.remove(d, " b "), true)
    assert.deepEqual(list.read(d), [item("a"), item("c")])
    assert.equal(JSON.parse(readFileSync(list.file(d), "utf-8")).keep, 1)
    assert.equal(list.remove(d, "nothing"), false)
})

test("remove: guarded refuses after another copy saved, unguarded does not", () => {
    const d = dir()
    list.write(d, [item("a"), item("b")])
    list.read(d, { track: true })
    writeFileSync(list.file(d), writeJson({ items: [item("a"), item("b"), item("c")] }))
    assert.throws(() => list.remove(d, "a", { guarded: true }), ChangedOnDiskError)
    assert.equal(list.remove(d, "a"), true)
    assert.deepEqual(list.read(d), [item("b"), item("c")], "the other copy's entry kept")
})

test("update writes the change or leaves the file alone", () => {
    const d = dir()
    list.write(d, [item("a")])
    assert.equal(
        list.update(d, () => undefined),
        false,
    )
    assert.equal(
        list.update(d, (l) => [...l, item("b")]),
        true,
    )
    assert.deepEqual(list.read(d), [item("a"), item("b")])
})

test("createParents false does not make a folder that is gone", () => {
    const d = dir()
    const project = new ListFile<Item>({
        fileName: "p.json",
        key: "items",
        kind: "p",
        plural: "items",
        noun: "item",
        problem: () => undefined,
        createParents: false,
    })
    project.write(d, [item("a")])
    rmSync(d, { recursive: true })
    assert.throws(() => project.write(d, [item("a")]))
    assert.equal(existsSync(d), false)
})
