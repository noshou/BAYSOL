// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { formLegend, type TableFacts, tableLegend } from "../src/screens/table-legend.js"
import { keys } from "../src/ui/keys.js"
import { chunks, entryLegend, legendFor } from "../src/ui/legend.js"
import {
    destructiveQuestion,
    questionLegend,
    questionNote,
} from "../src/ui/use-confirm.js"

/** Facts of a table with rows, the cursor in the middle, nothing unsaved. */
const base: TableFacts = {
    rows: 3,
    cursor: 1,
    canEdit: true,
    canAdd: true,
    locked: false,
    canRemove: true,
    canUndo: false,
    dirty: false,
}
const adds = [legendFor("add", keys.addNonbio)]
const keysOf = (items: { keys: string }[]) => items.map((i) => i.keys)

test("table legend: arrows only where the cursor can go", () => {
    assert.ok(keysOf(tableLegend(base, adds)).includes("↑↓"))
    assert.ok(keysOf(tableLegend({ ...base, cursor: 0 }, adds)).includes("↓"))
    assert.ok(keysOf(tableLegend({ ...base, cursor: 2 }, adds)).includes("↑"))
    const one = tableLegend({ ...base, rows: 1, cursor: 0 }, adds)
    assert.equal(one.some((i) => i.label === "move"), false)
})

test("table legend: an empty table offers only back and the adds", () => {
    const empty: TableFacts = {
        ...base,
        rows: 0,
        cursor: 0,
        canEdit: false,
        canRemove: false,
    }
    assert.deepEqual(keysOf(tableLegend(empty, adds)), ["^x", "^n"])
})

test("table legend: remove, undo and save only where they act", () => {
    const labels = (f: TableFacts) => tableLegend(f, adds).map((i) => i.label)
    assert.equal(labels(base).includes("undo"), false)
    assert.equal(labels(base).includes("save"), false)
    const edited = labels({ ...base, canUndo: true, dirty: true })
    assert.ok(edited.includes("undo") && edited.includes("save"))
    assert.equal(labels({ ...base, canRemove: false }).includes("remove"), false)
    assert.equal(labels({ ...base, canAdd: false }).includes("add"), false)
    assert.equal(labels({ ...base, canEdit: false }).includes("edit"), false)
})

test("table legend: a table that erases calls ^r delete", () => {
    const items = tableLegend({ ...base, removeLabel: "delete" }, adds)
    const found = items.find((i) => i.keys === "^r")
    assert.equal(found?.label, "delete")
    const plain = tableLegend(base, adds).find((i) => i.keys === "^r")
    assert.equal(plain?.label, "remove")
})

test("table legend: a locked table changes nothing", () => {
    const locked = tableLegend(
        {
            ...base,
            locked: true,
            canEdit: false,
            canAdd: false,
            dirty: true,
            canUndo: true,
        },
        adds,
    )
    assert.deepEqual(
        locked.map((i) => i.label),
        ["back", "move"],
    )
})

test("entry legend: move for several entries, tab for a highlighted one", () => {
    const none = entryLegend({ count: 0, pick: true })
    assert.deepEqual(keysOf(none), ["esc"])
    const one = entryLegend({ count: 1, pick: true })
    assert.deepEqual(keysOf(one), ["⏎", "tab", "esc"])
    const many = entryLegend({ count: 4, pick: true })
    assert.deepEqual(keysOf(many), ["⏎", "↑↓", "tab", "esc"])
    // a plain prompt always takes its text
    assert.deepEqual(keysOf(entryLegend({ count: 0 })), ["⏎", "esc"])
    assert.deepEqual(keysOf(entryLegend({ count: 0, canTake: false })), ["esc"])
    const del = [legendFor("delete", keys.remove)]
    const extra = entryLegend({ count: 2, pick: true, extras: del })
    assert.deepEqual(keysOf(extra), ["⏎", "↑↓", "tab", "^r", "esc"])
    // keys that need an entry are dropped for none; a browsed list has no take
    const listed = { count: 0, pick: true, listedExtras: del }
    assert.deepEqual(keysOf(entryLegend(listed)), ["esc"])
    const listedOne = entryLegend({ ...listed, count: 1 })
    assert.deepEqual(keysOf(listedOne), ["⏎", "tab", "^r", "esc"])
    const browsed = entryLegend({
        count: 3,
        pick: true,
        take: null,
        cancel: "close",
        back: true,
    })
    assert.deepEqual(
        browsed.map((i) => i.label),
        ["move", "complete", "close", "back"],
    )
})

test("a question is a value; its note and legend come from the same fields", () => {
    const q = destructiveQuestion("model x")
    const text = "delete model x? this cannot be undone!"
    assert.deepEqual(q, { text, yes: "delete", no: "keep" })
    // the note is the text alone: the keys that answer it are in the legend
    assert.equal(questionNote(q), text)
    // a wording change of the question cannot turn the legend into yes/no
    const other = { text: "go on?", yes: "go", no: "stay" }
    assert.equal(questionNote(other), "go on?")
    assert.deepEqual(questionLegend(other).map((i) => i.label), ["go", "stay"])
})

test("question legend reads the answers from the question", () => {
    assert.deepEqual(questionLegend(destructiveQuestion("model x")), [
        legendFor("delete", keys.enter),
        legendFor("keep", keys.escape),
    ])
    const sure = questionLegend({ text: "sure?", yes: "yes", no: "no" })
    assert.deepEqual(keysOf(sure), ["⏎", "esc"])
})

test("form legend: accept only when complete, undo only on a changed cell", () => {
    const f = {
        editing: false,
        moves: { up: true },
        canRestore: false,
        complete: false,
        acceptLabel: "add to table",
    }
    assert.deepEqual(keysOf(formLegend(f)), ["esc", "⏎", "↑"])
    const ready = formLegend({ ...f, complete: true, canRestore: true })
    assert.deepEqual(keysOf(ready), ["esc", "^w", "⏎", "↑", "^u"])
    assert.equal(ready[1]?.label, "add to table")
    assert.deepEqual(keysOf(formLegend({ ...f, editing: true })), ["⏎", "esc"])
})

test("legend columns: the fewest columns, as even as possible", () => {
    const sizes = (n: number) =>
        chunks(Array.from({ length: n }, (_, i) => i), 3).map((c) => c.length)
    assert.deepEqual(sizes(0), [])
    assert.deepEqual(sizes(3), [3])
    assert.deepEqual(sizes(4), [2, 2])
    assert.deepEqual(sizes(5), [3, 2])
    assert.deepEqual(sizes(7), [3, 2, 2])
    assert.deepEqual(sizes(9), [3, 3, 3])
})
