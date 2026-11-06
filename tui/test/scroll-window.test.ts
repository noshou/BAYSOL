// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    centredWindow,
    clampWindow,
    scrollTo,
    scrollWindow,
    stepIndex,
} from "../src/ui/scroll-window.js"

test("the window of a table follows the cursor with the least movement", () => {
    assert.equal(scrollWindow(0, 0, 5, 20), 0)
    assert.equal(scrollWindow(4, 0, 5, 20), 0)
    assert.equal(scrollWindow(5, 0, 5, 20), 1)
    assert.equal(scrollWindow(2, 10, 5, 20), 2)
    assert.equal(scrollWindow(19, 0, 5, 20), 15)
    // the window shrank (a prompt opened) and the cursor stays in view
    assert.equal(scrollWindow(9, 7, 3, 20), 7)
    assert.equal(scrollWindow(9, 5, 3, 20), 7)
    // a short list shows from the top, a size of 0 is taken as 1
    assert.equal(scrollWindow(1, 3, 10, 4), 0)
    assert.equal(scrollWindow(2, 0, 0, 4), 2)
})

test("clampWindow keeps the window inside the list", () => {
    assert.equal(clampWindow(-3, 5, 20), 0)
    assert.equal(clampWindow(18, 5, 20), 15)
    assert.equal(clampWindow(4, 5, 20), 4)
    assert.equal(clampWindow(4, 5, 3), 0)
})

test("centredWindow puts the highlight in the middle, clamped at both ends", () => {
    assert.equal(centredWindow(3, 2, 5), 0)
    assert.equal(centredWindow(20, 0, 5), 0)
    assert.equal(centredWindow(20, 10, 5), 8)
    assert.equal(centredWindow(20, 19, 5), 15)
})

test("scrollTo moves the top only as far as the fitting rows need", () => {
    assert.equal(
        scrollTo(0, 7, () => 3),
        5,
    )
    assert.equal(
        scrollTo(6, 2, () => 3),
        2,
    )
    assert.equal(
        scrollTo(1, 2, () => 3),
        1,
    )
})

test("stepIndex stops at the ends, or goes round when it wraps", () => {
    assert.equal(stepIndex(1, 4, true), 2)
    assert.equal(stepIndex(3, 4, true), 3)
    assert.equal(stepIndex(0, 4, false), 0)
    assert.equal(stepIndex(3, 4, true, true), 0)
    assert.equal(stepIndex(0, 4, false, true), 3)
    assert.equal(stepIndex(2, 4, false, true), 1)
    // an empty list keeps the highlight on 0
    assert.equal(stepIndex(0, 0, true, true), 0)
})
