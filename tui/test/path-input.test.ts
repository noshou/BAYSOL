// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { accepted } from "../src/store/models.js"
import { checkPath, pathSuggestions } from "../src/store/path-input.js"

test("pathSuggestions show the name and complete to the whole path", () => {
    const dir = mkdtempSync(join(tmpdir(), "baysol-test-"))
    mkdirSync(join(dir, "sub"))
    writeFileSync(join(dir, "m1.pdb"), "")
    writeFileSync(join(dir, "notes.txt"), "")
    assert.deepEqual(pathSuggestions(`${dir}/`, accepted), [
        { label: "sub/", completion: `${dir}/sub/` },
        { label: "m1.pdb", completion: `${dir}/m1.pdb` },
    ])
    assert.deepEqual(
        pathSuggestions(`${dir}/m`, accepted).map((s) => s.completion),
        [`${dir}/m1.pdb`],
    )
    assert.deepEqual(pathSuggestions("relative", accepted), [])
    assert.deepEqual(pathSuggestions(`${dir}/nope/x`, accepted), [])
})

test("checkPath answers with the wording of its budget, in a fixed order", () => {
    const dir = mkdtempSync(join(tmpdir(), "baysol-test-"))
    const kind = { accept: (n: string) => n.endsWith(".ok"), message: "K" }
    writeFileSync(join(dir, "a.ok"), "")
    writeFileSync(join(dir, "a.no"), "")
    for (const budget of [22, 42] as const) {
        const empty =
            budget === 42
                ? "type the full path of a model file first!"
                : "type a path first!"
        assert.equal(checkPath(" ", budget), empty)
        assert.equal(checkPath(join(dir, "none.ok"), budget), "no such file")
        assert.equal(checkPath(join(dir, "a.no"), budget, kind), "K")
        assert.equal(checkPath(join(dir, "a.no"), budget), undefined)
        assert.equal(checkPath(join(dir, "a.ok"), budget, kind), undefined)
    }
    assert.equal(checkPath("a.ok", 22), "use a full path")
    assert.equal(checkPath("a.ok", 42), "use a full absolute path")
    assert.equal(checkPath(dir, 22), "that is a folder")
    assert.equal(checkPath(dir, 42), "that is a folder, not a file")
})

test("a path that is not absolute or not in a folder has no suggestions", () => {
    assert.deepEqual(pathSuggestions("relative/path", () => true), [])
    assert.deepEqual(pathSuggestions("/no/such/folder/ab", () => true), [])
})
