// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { fitWidths, moveCell, placeAt } from "../src/ui/form-layout.js"

/** The shape of the polymer form: name, four unit rows, the end groups (no column 0). */
const unit = [0, 1, 2, 3, 4]
const valid = [[0], unit, unit, unit, unit, [1, 2, 3, 4]]

test("fitWidths keeps natural widths that fit", () => {
    assert.deepEqual(fitWidths([5, 10, 3], 30), [5, 10, 3])
})

test("fitWidths squeezes the widest column first", () => {
    assert.deepEqual(fitWidths([10, 4], 10), [6, 4])
    assert.deepEqual(fitWidths([8, 8], 12), [6, 6])
})

test("fitWidths stops at the floor", () => {
    assert.deepEqual(fitWidths([10, 10], 2), [3, 3])
    assert.deepEqual(fitWidths([10, 10], 2, 5), [5, 5])
})

test("up and down keep the column asked for", () => {
    let pos = placeAt(1, 3)
    pos = moveCell(valid, pos, -1, 0)
    assert.deepEqual(pos, { row: 0, col: 0, want: 3 })
    pos = moveCell(valid, pos, 1, 0)
    assert.deepEqual(pos, { row: 1, col: 3, want: 3 })
})

test("the end groups have no column 0: the cursor goes to the nearest", () => {
    const pos = moveCell(valid, placeAt(4, 0), 1, 0)
    assert.deepEqual(pos, { row: 5, col: 1, want: 0 })
})

test("left and right stay on the row and change the column asked for", () => {
    let pos = moveCell(valid, placeAt(1, 0), 0, 1)
    assert.deepEqual(pos, { row: 1, col: 1, want: 1 })
    pos = moveCell(valid, placeAt(1, 4), 0, 1)
    assert.equal(pos.col, 4)
    pos = moveCell(valid, placeAt(5, 1), 0, -1)
    assert.equal(pos.col, 1)
    pos = moveCell(valid, placeAt(0, 0), 0, 1)
    assert.equal(pos.col, 0)
})

test("up and down stop at the ends", () => {
    assert.equal(moveCell(valid, placeAt(0, 0), -1, 0).row, 0)
    assert.equal(moveCell(valid, placeAt(5, 1), 1, 0).row, 5)
})
