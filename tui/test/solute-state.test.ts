// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { Drafts } from "../src/store/draft.js"
import {
    addBlankRow,
    draftProblem,
    firstProblem,
    type Solute,
    setSoluteField,
} from "../src/store/solutes.js"

const base = { kind: "nonbiological", sigmaMM: 10 }
const nacl: Solute = { ...base, name: "NaCl", arg: "NaCl", mM: 200 }
const tris: Solute = { ...base, name: "tris", arg: "tris", mM: 10, sigmaMM: 0.5 }
const complete = () => undefined
const incomplete = () => "unknown kind"
const marks = (s: Drafts<Solute>) => s.rows.map((_, i) => s.mark(i))

test("drafts and removals of solutes", () => {
    const s = Drafts.of([nacl, tris])
    const e = setSoluteField(s, 0, "mM", 150)
    assert.deepEqual(marks(e), ["*", undefined])
    assert.equal(e.value(0)?.mM, 150)
    assert.deepEqual(marks(setSoluteField(e, 0, "mM", 200)), [undefined, undefined])
    // the name is a label: the arg stays
    const renamed = setSoluteField(s, 0, "name", "KCl").value(0)
    assert.deepEqual([renamed?.name, renamed?.arg], ["KCl", "NaCl"])
    // a new blank row is marked and goes with undo or remove
    const a = addBlankRow(s)
    assert.deepEqual(marks(a), [undefined, undefined, "*"])
    assert.equal(a.undo(2).length, 2)
    assert.equal(a.remove(2).length, 2)
    // a saved row is only marked to go; a save keeps the rest as it is
    const r = s.remove(0)
    const edited = setSoluteField(r, 1, "mM", 11)
    assert.deepEqual(edited.toSave(), [{ ...tris, mM: 11 }])
    assert.equal(edited.commit().dirty, false)
})

test("what is missing", () => {
    assert.equal(draftProblem(nacl, complete), undefined)
    assert.equal(draftProblem({ ...nacl, name: " " }, complete), "name needed")
    assert.equal(draftProblem({ ...nacl, mM: null }, complete), "mM must be > 0")
    assert.equal(draftProblem({ ...nacl, mM: 0 }, complete), "mM must be > 0")
    assert.equal(draftProblem({ ...nacl, sigmaMM: null }, complete), "±mM needed")
    assert.equal(draftProblem({ ...nacl, sigmaMM: 0 }, complete), undefined)
    assert.equal(draftProblem(nacl, incomplete), "row incomplete")
    const s = setSoluteField(addBlankRow(Drafts.of([nacl, tris])), 2, "name", "x")
    assert.deepEqual(firstProblem(s, complete), [2, "mM must be > 0"])
    assert.equal(firstProblem(s.remove(2), complete), undefined)
})
