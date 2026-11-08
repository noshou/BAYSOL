// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the screen kit (`ui/frame.tsx`, `ui/input.tsx`, `ui/grid.tsx`): the corner,
// the form fields, the input status, the menu taskbar.
//
// Contents:
//   1. Frame: the corner label
//   2. Fields: widths and cursor moves of a form
//   3. Input: the position status
//   4. Grid: the menu taskbar

import assert from "node:assert/strict"
import { test } from "node:test"
import { displayWidth } from "../src/core/terminal.js"
import { cornerLabel, fitCorner, moveCell, placeAt } from "../src/ui/frame.js"
import { positionStatus } from "../src/ui/input.js"

// ========================================================================================
// 1. Frame: the corner label
// ========================================================================================

test("the corner names the project, and the run once one is chosen", () => {
    assert.equal(cornerLabel("demo"), "project: demo")
    assert.equal(
        cornerLabel("demo", "20261106T193308Z"),
        "project: demo · run: 19:33:08:000 UTC +00:00 · 2026-11-06",
    )
})

test("a corner that fits is drawn whole", () => {
    const label = cornerLabel("demo", "20261106T193308Z")
    assert.equal(fitCorner(label, 78, "logs", "runs"), label)
    const fresh = cornerLabel("demo", "23-35-29-123_EST_-0500_2026-11-07")
    assert.equal(fresh, "project: demo · run: 23:35:29:123 EST -05:00 · 2026-11-07")
    assert.equal(fitCorner(fresh, 78, "open", "runs"), fresh)
})

test("a corner is cut before it can push the title, and never wider than its room", () => {
    const label = cornerLabel("a-very-long-project-name", "20261106T193308Z")
    const title = "logs"
    const subtitle = "view settings"
    for (const columns of [78, 60, 50, 40]) {
        const shown = fitCorner(label, columns, title, subtitle)
        const used = displayWidth(title) + 1 + displayWidth(`· ${subtitle}`)
        if (shown !== undefined) {
            assert.ok(displayWidth(shown) + used < columns, `${columns}: ${shown}`)
            if (displayWidth(label) > columns - used - 2) assert.match(shown, /…$/)
        }
    }
    assert.match(fitCorner(label, 60, title, subtitle) ?? "", /^project: a-very/)
})

test("with too little room the corner is left out, not shown as a stump", () => {
    assert.equal(fitCorner("project: demo", 20, "logs", "a long subtitle here"), undefined)
    assert.equal(fitCorner("project: demo", 10, "logs"), undefined)
})

test("the title with no subtitle leaves its room to the corner", () => {
    assert.equal(fitCorner("project: demo", 30, "logs"), "project: demo")
})

// ========================================================================================
// 2. Fields: widths and cursor moves of a form
// ========================================================================================

/** The shape of the polymer form: name, four unit rows, the end groups (no column 0). */
const unit = [0, 1, 2, 3, 4]
const valid = [[0], unit, unit, unit, unit, [1, 2, 3, 4]]

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

// ========================================================================================
// 3. Input: the position status
// ========================================================================================

test("positionStatus counts from one", () => {
    assert.equal(positionStatus(0, 12), "1 of 12")
    assert.equal(positionStatus(11, 12), "12 of 12")
})
