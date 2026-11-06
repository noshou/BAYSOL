// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { columnBar, lineSets, ruleLine } from "../src/ui/table-lines.js"

test("ruleLine: double lines, framed, as wide as the table", () => {
    const w = [4, 6, 3]
    assert.equal(ruleLine("double", "top", w), "╔════╦══════╦═══╗")
    assert.equal(ruleLine("double", "mid", w), "╠════╬══════╬═══╣")
    assert.equal(ruleLine("double", "bottom", w), "╚════╩══════╩═══╝")
})

test("ruleLine: single lines, any number of columns", () => {
    assert.equal(ruleLine("single", "top", [2]), "┌──┐")
    assert.equal(ruleLine("single", "mid", [1, 2]), "├─┼──┤")
    assert.equal(ruleLine("single", "bottom", [3, 1, 2]), "└───┴─┴──┘")
})

test("ruleLine: without a frame only the crosses, after a lead", () => {
    assert.equal(ruleLine("single", "mid", [3, 4], { frame: false, lead: 2 }), "─────┼────")
    assert.equal(ruleLine("single", "mid", [3], { frame: false }), "───")
})

test("ruleLine: a width below zero draws nothing", () => {
    assert.equal(ruleLine("single", "mid", [-1, 1]), "├┼─┤")
})

test("columnBar: one vertical per line", () => {
    assert.equal(columnBar("double", 3), "║\n║\n║")
    assert.equal(columnBar("single", 1), lineSets.single.vertical)
    assert.equal(columnBar("single", 0), "")
})
