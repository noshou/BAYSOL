// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { pickNote } from "../src/screens/models-screen.js"
import { destructiveQuestion, questionNote } from "../src/ui/use-confirm.js"

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

test("the deletion question names the model and warns", () => {
    const q = questionNote(destructiveQuestion("model a.pdb"))
    assert.match(q, /^delete model a\.pdb\?/)
    assert.match(q, /cannot be undone/)
    assert.equal(q, "delete model a.pdb? this cannot be undone!")
    // a long name is cut, never the warning behind it
    const long = questionNote(destructiveQuestion(`model ${"x".repeat(80)}`))
    assert.ok(long.endsWith("? this cannot be undone!"))
    assert.ok(long.includes("…"))
    assert.ok(long.length <= 7 + 24 + 24)
})
