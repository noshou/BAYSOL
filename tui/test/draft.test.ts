// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { Drafts, MAX_ROWS } from "../src/store/draft.js"

const marks = (s: Drafts<string>) => s.rows.map((_, i) => s.mark(i))
const values = (s: Drafts<string>) => s.rows.map((_, i) => s.value(i))

test("saved rows are clean", () => {
    const s = Drafts.of(["a", "b"])
    assert.deepEqual(marks(s), [undefined, undefined])
    assert.deepEqual(values(s), ["a", "b"])
    assert.equal(s.dirty, false)
    assert.equal(Drafts.of([]).length, 0)
})

test("drafts, marks and undo", () => {
    const s = Drafts.of(["a", "b"]).set(0, "a2").add("c").add("d", "e")
    assert.deepEqual(marks(s), ["*", undefined, "*", "*", "*"])
    assert.deepEqual(values(s), ["a2", "b", "c", "d", "e"])
    assert.equal(s.dirty, true)
    assert.equal(s.count, 4)
    // set back to what was saved: no draft
    assert.deepEqual(marks(Drafts.of(["a", "b"]).set(0, "a")), [undefined, undefined])
    // undo of a draft, of a new row (it goes)
    assert.deepEqual(marks(s.undo(0)), [undefined, undefined, "*", "*", "*"])
    assert.deepEqual(values(s.undo(2)), ["a2", "b", "d", "e"])
    // removal of a saved row is a mark, undo brings it back; toSave skips it
    const r = s.remove(1)
    assert.deepEqual(marks(r), ["*", "-", "*", "*", "*"])
    assert.deepEqual(r.toSave(), ["a2", "c", "d", "e"])
    assert.deepEqual(marks(r.undo(1)), ["*", undefined, "*", "*", "*"])
    // removal of a row that was never saved is at once
    assert.equal(s.remove(2).length, 4)
    // commit drops the removed rows and cleans the others
    const c = r.commit()
    assert.deepEqual(marks(c), [undefined, undefined, undefined, undefined])
    assert.deepEqual(values(c), ["a2", "c", "d", "e"])
})

test("objects are compared by value when set back", () => {
    const s = Drafts.of([{ n: 1 }]).set(0, { n: 2 })
    assert.equal(s.mark(0), "*")
    assert.equal(s.set(0, { n: 1 }).mark(0), undefined)
})

test("drop and dropNew", () => {
    const s = Drafts.of(["a", "b", "c"])
    assert.deepEqual(values(s.drop(1)), ["a", "c"])
    assert.deepEqual(values(s.drop(0)), ["b", "c"])
    assert.throws(() => s.drop(3), RangeError)
    const a = s.add("x", "y")
    assert.deepEqual(values(a.dropNew([3])), ["a", "b", "c", "y"])
    assert.deepEqual(values(a.dropNew([3, 4])), ["a", "b", "c"])
    assert.deepEqual(values(s.dropNew([0, 1])), ["a", "b", "c"], "saved rows stay")
})

test("the state is immutable", () => {
    const s = Drafts.of(["a"])
    s.set(0, "b")
    s.remove(0)
    assert.equal(s.dirty, false)
})

test("room for another row", () => {
    assert.equal(Drafts.of(Array(MAX_ROWS - 1).fill(0)).hasRoom, true)
    assert.equal(Drafts.of(Array(MAX_ROWS).fill(0)).hasRoom, false)
    assert.equal(new Drafts().hasRoom, true)
})
