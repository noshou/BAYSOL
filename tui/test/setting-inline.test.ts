// SPDX-License-Identifier: LGPL-3.0-or-later

// The inline number editor, the tuple editor part by part, and the rounded-box legend of
// the smooth footer.
//
// Contents:
//   1. A number typed into its row
//   2. A tuple edited part by part
//   3. The table: an editor in a cell, a note under a row
//   4. The legend of the smooth footer

import assert from "node:assert/strict"
import { test } from "node:test"
import { renderToString, Text } from "ink"
import { createElement } from "react"
import {
    CAP_NOTE,
    maxNumberText,
    noteLines,
    openNumber,
    openTuple,
    pasteNumber,
    pasteTuple,
    stepNumber,
    stepTuple,
    takeColour,
} from "../src/screens/screen-rules.js"
import { defaultCatalog } from "../src/store/settings.js"
import { Frame, legendStyle } from "../src/ui/frame.js"
import { boxesFit, legendFor, legendHeight } from "../src/ui/grid.js"
import { KeyInput, keys } from "../src/ui/interaction.js"
import { fieldCells, TextBuffer } from "../src/ui/text-input.js"
import { DataTable } from "../src/ui/theme.js"

const catalog = defaultCatalog()
const typed = (text: string): KeyInput => new KeyInput(text.toLowerCase(), false, text)

/** The keys of a text, one press each. */
const typeAll = <S>(
    state: S,
    text: string,
    step: (s: S, p: KeyInput) => { state: S },
): S => [...text].reduce((s, ch) => step(s, typed(ch)).state, state)

// ========================================================================================
// 1. A number typed into its row
// ========================================================================================

test("a number opens as its value with the cursor at the end", () => {
    const edit = openNumber(catalog.require("N_ADAPT"), 300)
    assert.equal(edit.buffer.text, "300")
    assert.equal(edit.buffer.cursor, 3)
})

test("a number: typing, the cursor keys and backspace edit the text", () => {
    const def = catalog.require("N_ADAPT")
    let edit = openNumber(def, 300)
    edit = stepNumber(edit, keys.home).state
    assert.equal(edit.buffer.cursor, 0)
    edit = stepNumber(edit, typed("1")).state
    edit = stepNumber(edit, keys.right).state
    edit = stepNumber(edit, keys.delete).state
    assert.equal(edit.buffer.text, "130")
    edit = stepNumber(edit, keys.end).state
    edit = stepNumber(edit, keys.left).state
    edit = stepNumber(edit, keys.backspace).state
    assert.equal(edit.buffer.text, "10")
})

test("a number: a blank is dropped, a character past the cap says so", () => {
    const def = catalog.require("N_ADAPT")
    let edit = openNumber(def, 1)
    edit = stepNumber(edit, typed(" ")).state
    assert.equal(edit.buffer.text, "1")
    assert.equal(edit.error, undefined)
    edit = typeAll(edit, "2".repeat(maxNumberText), stepNumber)
    assert.equal(edit.buffer.length, maxNumberText)
    assert.equal(edit.error, CAP_NOTE)
    // the next editing key clears the message
    edit = stepNumber(edit, keys.backspace).state
    assert.equal(edit.error, undefined)
})

test("a number: Enter takes a good number, a wrong one stays as an error", () => {
    const def = catalog.require("N_ADAPT")
    const good = stepNumber(openNumber(def, 250), keys.enter)
    assert.deepEqual(good.end, { kind: "done", value: 250 })
    const bad = stepNumber(openNumber(def, 0), keys.enter)
    assert.equal(bad.end, undefined)
    assert.match(bad.state.error ?? "", /at least 1/)
    const empty = stepNumber(openNumber(def, 5), keys.backspace)
    assert.ok(stepNumber(empty.state, keys.enter).state.error)
    const decimal = typeAll(openNumber(def, 5), ".5", stepNumber)
    assert.ok(stepNumber(decimal, keys.enter).state.error)
})

test("a number: a float takes decimals, Esc drops, Ctrl-X leaves", () => {
    const flt = catalog.defs().find((d) => d.kind === "float")
    assert.ok(flt)
    const edit = stepNumber(openNumber(flt, 1), keys.backspace).state
    const typedIn = typeAll(edit, "0.25", stepNumber)
    assert.deepEqual(stepNumber(typedIn, keys.enter).end?.kind, "done")
    assert.deepEqual(stepNumber(typedIn, keys.escape).end, { kind: "cancel" })
    assert.deepEqual(stepNumber(typedIn, keys.back).end, { kind: "back" })
    assert.equal(typedIn.buffer.text, "0.25")
})

test("pasting into a number drops the blanks and clears the error", () => {
    const def = catalog.require("N_ADAPT")
    let edit = stepNumber(openNumber(def, 0), keys.enter).state
    assert.ok(edit.error)
    edit = pasteNumber(stepNumber(edit, keys.backspace).state, " 1 2\n3 ")
    assert.equal(edit.buffer.text, "123")
    assert.equal(edit.error, undefined)
})

test("an error under a value wraps to the column, two lines at most", () => {
    const lines = noteLines("must be at least 1 and at most a very large number", 12)
    assert.equal(lines.length, 2)
    assert.ok(lines.every((l) => l.length <= 12))
    assert.deepEqual(noteLines("short", 12), ["short"])
})

test("a field takes the text and a cursor cell, never more than its room", () => {
    assert.equal(fieldCells(new TextBuffer("abc"), 10), 4)
    assert.equal(fieldCells(new TextBuffer("abc", 1), 10), 3)
    assert.equal(fieldCells(new TextBuffer("abcdefgh"), 5), 5)
    assert.equal(fieldCells(new TextBuffer(""), 5), 1)
})

// ========================================================================================
// 2. A tuple edited part by part
// ========================================================================================

const radii = catalog.require("CHAIN_START_RADII")
const colourPair = catalog.require("PLOT_COLOUR_ERRORBAR")

test("a tuple opens on its first part, number parts fresh, colour parts not", () => {
    const edit = openTuple(radii, [4, 10, 20])
    assert.deepEqual(edit.texts, ["4", "10", "20"])
    assert.equal(edit.focus, 0)
    assert.deepEqual([...edit.fresh], [0, 1, 2])
    const pair = openTuple(colourPair, ["gray40", 0.6])
    assert.deepEqual([...pair.fresh], [1])
})

test("a tuple: left, right and tab move the focus, stopping or going round", () => {
    let edit = openTuple(radii, [4, 10, 20])
    edit = stepTuple(edit, keys.left).state
    assert.equal(edit.focus, 0)
    edit = stepTuple(edit, keys.right).state
    edit = stepTuple(edit, keys.right).state
    edit = stepTuple(edit, keys.right).state
    assert.equal(edit.focus, 2)
    edit = stepTuple(edit, keys.tab).state
    assert.equal(edit.focus, 0)
})

test("a tuple: the first key replaces a part, later keys add, backspace takes off", () => {
    let edit = openTuple(radii, [4, 10, 20])
    edit = typeAll(edit, "7", stepTuple)
    assert.deepEqual(edit.texts, ["7", "10", "20"])
    assert.equal(edit.fresh.has(0), false)
    edit = typeAll(edit, ".5", stepTuple)
    assert.equal(edit.texts[0], "7.5")
    edit = stepTuple(edit, keys.backspace).state
    assert.equal(edit.texts[0], "7.")
    assert.equal(stepTuple(edit, typed(" ")).state.texts[0], "7.")
})

test("a tuple: Enter on a number part takes the whole tuple", () => {
    let edit = openTuple(radii, [4, 10, 20])
    edit = typeAll(edit, "5", stepTuple)
    const done = stepTuple(edit, keys.enter)
    assert.deepEqual(done.end, { kind: "done", value: [5, 10, 20] })
})

test("a tuple: a wrong part puts the focus on it and names it", () => {
    let edit = openTuple(radii, [4, 10, 20])
    edit = stepTuple(edit, keys.right).state
    edit = typeAll(edit, "x", stepTuple)
    const bad = stepTuple(edit, keys.enter)
    assert.equal(bad.end, undefined)
    assert.match(bad.state.error ?? "", /^second: /)
    assert.equal(bad.state.focus, 1)
    // a key clears it
    assert.equal(stepTuple(bad.state, keys.right).state.error, undefined)
})

test("a tuple: Esc drops, Ctrl-X leaves", () => {
    const edit = openTuple(radii, [4, 10, 20])
    assert.deepEqual(stepTuple(edit, keys.escape).end, { kind: "cancel" })
    assert.deepEqual(stepTuple(edit, keys.back).end, { kind: "back" })
})

test("a tuple: Enter on a colour part asks for the picker, typing does nothing", () => {
    const edit = openTuple(colourPair, ["gray40", 0.6])
    assert.equal(stepTuple(edit, keys.enter).pick, true)
    assert.deepEqual(stepTuple(edit, typed("r")).state, edit)
})

test("a tuple: the colour picked is taken and the focus goes on", () => {
    const edit = openTuple(colourPair, ["gray40", 0.6])
    const next = takeColour(edit, "red")
    assert.deepEqual(next.state.texts, ["red", "0.6"])
    assert.equal(next.state.focus, 1)
    assert.equal(next.end, undefined)
    const done = stepTuple(typeAll(next.state, "0.3", stepTuple), keys.enter)
    assert.deepEqual(done.end, { kind: "done", value: ["red", 0.3] })
})

test("pasting into a tuple drops the blanks, and ignores a colour part", () => {
    let edit = openTuple(radii, [4, 10, 20])
    edit = pasteTuple(edit, " 1 5 ")
    assert.equal(edit.texts[0], "15")
    const pair = openTuple(colourPair, ["gray40", 0.6])
    assert.equal(pasteTuple(pair, "red"), pair)
})

// ========================================================================================
// 3. The table: an editor in a cell, a note under a row
// ========================================================================================

test("a table draws a node in place of one cell and a note under its row", () => {
    const text = renderToString(
        createElement(DataTable<{ a: string; b: string }>, {
            columns: [
                { title: "name", width: 6, text: (r) => r.a },
                { title: "value", width: 12, text: (r) => r.b },
            ],
            rows: [
                { a: "one", b: "1" },
                { a: "two", b: "2" },
            ],
            cursor: 1,
            offset: 0,
            pageSize: 6,
            width: 40,
            inline: {
                row: 1,
                column: 1,
                node: createElement(Text, null, "42|"),
                cells: 3,
            },
            note: { row: 1, column: 1, lines: ["bad one", "line two"] },
        }),
    )
    const lines = text.split("\n")
    const two = lines.findIndex((l) => l.includes("two"))
    assert.match(lines[two] as string, /two {3}.*│ 42\|/)
    assert.doesNotMatch(text, /│ 2 /)
    assert.match(lines[two + 1] as string, /bad one/)
    assert.match(lines[two + 2] as string, /line two/)
    // the separators of the note lines stand where those of the row do
    const bar = (lines[two] as string).indexOf("│")
    assert.equal((lines[two + 1] as string).indexOf("│"), bar)
})

// ========================================================================================
// 4. The legend of the smooth footer
// ========================================================================================

const items = (n: number) =>
    Array.from({ length: n }, (_, i) => legendFor(`key${i}`, keys.save))

test("the smooth footer draws its keys in boxes, the blocky one in columns", () => {
    assert.equal(legendStyle("smooth"), "boxes")
    assert.equal(legendStyle("blocky"), "columns")
})

test("boxes take three rows when they fit one row, columns when they do not", () => {
    const few = items(3)
    assert.ok(boxesFit(few, 80))
    assert.equal(legendHeight(few, 80, "boxes"), 3)
    assert.equal(legendHeight(items(1), 80, "boxes"), 3)
    // too wide for one row: the height of the columns it falls back to
    const many = items(12)
    assert.ok(!boxesFit(many, 60))
    assert.equal(legendHeight(many, 60, "boxes"), legendHeight(many, 60, "columns"))
    assert.equal(legendHeight([], 60, "boxes"), 0)
})

test("a smooth frame shows its keys as rounded boxes and still fits 80 x 24", () => {
    const text = renderToString(
        createElement(Frame, {
            title: "demo",
            legend: [legendFor("back", keys.back), legendFor("save", keys.save)],
        },
            createElement(Text, null, "body"),
        ),
        { columns: 80 },
    )
    assert.match(text, /╭[─]+╮/)
    assert.match(text, /│ back: /)
    assert.ok(text.split("\n").length <= 24)
})
