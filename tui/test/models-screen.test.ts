// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { deleteQuestion, pathSuggestions, pickNote } from "../src/screens/models-screen.js"

test("pickNote tells copied and skipped files", () => {
    assert.equal(pickNote({ copied: [], skipped: [] }), "nothing was picked")
    assert.equal(pickNote({ copied: ["a.pdb"], skipped: [] }), "copied a.pdb")
    assert.equal(pickNote({ copied: ["a.pdb", "b.cif"], skipped: [] }), "copied 2 files")
    assert.equal(
        pickNote({
            copied: ["a.pdb"],
            skipped: [["/x/b.txt", "only .cif and .pdb files"]],
        }),
        "copied a.pdb, skipped 1: only .cif and .pdb files",
    )
    assert.equal(
        pickNote({ copied: [], skipped: [["/x/b.txt", "no such file"], ["/y", "z"]] }),
        "skipped 2: no such file",
    )
})

test("pathSuggestions show the name and complete to the whole path", () => {
    const dir = mkdtempSync(join(tmpdir(), "baysol-test-"))
    mkdirSync(join(dir, "sub"))
    writeFileSync(join(dir, "m1.pdb"), "")
    writeFileSync(join(dir, "notes.txt"), "")
    assert.deepEqual(pathSuggestions(`${dir}/`), [
        { label: "sub/", completion: `${dir}/sub/` },
        { label: "m1.pdb", completion: `${dir}/m1.pdb` },
    ])
    assert.deepEqual(
        pathSuggestions(`${dir}/m`).map((s) => s.completion),
        [`${dir}/m1.pdb`],
    )
    assert.deepEqual(pathSuggestions("relative"), [])
    assert.deepEqual(pathSuggestions(`${dir}/nope/x`), [])
})

test("the deletion question names the model and warns", () => {
    const q = deleteQuestion("a.pdb")
    assert.match(q, /^remove a\.pdb\?/)
    assert.match(q, /destructive/)
    assert.ok(q.endsWith("enter: delete  esc: keep"))
    assert.ok(deleteQuestion("x".repeat(80)).endsWith("enter: delete  esc: keep"))
})
