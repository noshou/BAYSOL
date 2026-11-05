// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { displayWidth } from "../src/core/text.js"
import {
    bufferStatus,
    fitName,
    landingOptions,
    plural,
    recipeChoice,
    replaceBufferQuestion,
    replaceRecipeQuestion,
    savedAs,
    unusable,
} from "../src/screens/buffer-text.js"
import {
    flowChanges,
    rowOf,
    soluteOf,
    soluteProblem,
    windowOffset,
} from "../src/screens/solute-rows.js"
import { flowLegend, pathSuggestions } from "../src/screens/use-solute-flow.js"
import { AddFlow } from "../src/store/add-flow.js"
import type { BufferRow } from "../src/store/buffer.js"
import { rowProblem } from "../src/store/buffer.js"
import { Drafts } from "../src/store/draft.js"
import type { Solute } from "../src/store/solutes.js"
import { fixture } from "./support/fixtures.js"

const rows = fixture("buffer/buffer.json").solutes as BufferRow[]

test("the options of the landing apply only when they can", () => {
    const labels = (n: Parameters<typeof landingOptions>[0]) =>
        landingOptions(n).map((o) => o.label)
    assert.deepEqual(labels(0), ["load a recipe", "new recipe"])
    assert.deepEqual(labels("unusable"), ["load a recipe", "new recipe"])
    assert.deepEqual(labels(1), [
        "edit current recipe (1 solute)",
        "load a recipe",
        "new recipe",
        "save current recipe globally",
    ])
    assert.equal(labels(12)[0], "edit current recipe (12 solutes)")
    assert.deepEqual(
        landingOptions(3).map((o) => o.id),
        ["edit", "load", "new", "save"],
    )
})

test("what the landing says of the file", () => {
    assert.equal(bufferStatus("buffer.json", 0), "buffer.json: none yet")
    assert.equal(bufferStatus("buffer.json", 1), "buffer.json: 1 solute")
    assert.equal(bufferStatus("buffer.json", 12), "buffer.json: 12 solutes")
    assert.equal(bufferStatus("buffer.json", "unusable"), "buffer.json unusable!")
    assert.equal(unusable("recipes.json"), "recipes.json unusable!")
    assert.equal(plural(1, "solute"), "1 solute")
    assert.equal(recipeChoice("SEC buffer", 3), "SEC buffer (3)")
})

test("a long name is cut so that the keys of a question stay in view", () => {
    const room = 76
    const long = "N".repeat(40)
    const q = replaceBufferQuestion(11, long, room)
    assert.ok(displayWidth(q) <= room, q)
    assert.ok(q.endsWith('"?  enter: replace  esc: keep'), q)
    assert.ok(q.startsWith("replace 11 solutes with recipe \"N"), q)
    assert.equal(
        replaceBufferQuestion(1, "SEC", room),
        'replace 1 solute with recipe "SEC"?  enter: replace  esc: keep',
    )
    assert.equal(
        replaceRecipeQuestion("my BUFFER", room),
        'replace "my BUFFER"?  enter: replace  esc: keep',
    )
    assert.ok(displayWidth(replaceRecipeQuestion(long, room)) <= room)
    assert.equal(savedAs("My buffer", room), 'saved as "My buffer"')
    // never narrower than eight cells, however tight the room
    assert.equal(displayWidth(fitName("abcdefghijklmnop", 10, 9)), 8)
})

test("a file row and a draft are the same solute", () => {
    for (const row of rows) {
        const s = soluteOf(row)
        assert.equal("sigma-mM" in s, false)
        assert.equal(s.sigmaMM, row["sigma-mM"])
        assert.deepEqual(rowOf(s), row, row.name)
        assert.equal(soluteProblem(s), undefined, row.name)
        assert.equal(rowProblem(rowOf(s)), undefined)
    }
    const zero = { ...soluteOf(rows[0] as BufferRow), mM: 0 }
    assert.equal(soluteProblem(zero), "mM must be above 0")
})

test("the window of a table follows the cursor with the least movement", () => {
    assert.equal(windowOffset(0, 0, 5, 20), 0)
    assert.equal(windowOffset(4, 0, 5, 20), 0)
    assert.equal(windowOffset(5, 0, 5, 20), 1)
    assert.equal(windowOffset(2, 10, 5, 20), 2)
    assert.equal(windowOffset(19, 0, 5, 20), 15)
    // the window shrank (a prompt opened) and the cursor stays in view
    assert.equal(windowOffset(9, 7, 3, 20), 7)
    assert.equal(windowOffset(9, 5, 3, 20), 7)
    // a short list shows from the top, a size of 0 is taken as 1
    assert.equal(windowOffset(1, 3, 10, 4), 0)
    assert.equal(windowOffset(2, 0, 0, 4), 2)
})

test("what a flow changed in the table", () => {
    const saved = Drafts.of(rows.slice(0, 2).map(soluteOf))
    // an add of a non-biological solute: name, mM, ±
    const add = AddFlow.add(saved, "nonbio")
    add.send({ type: "text", text: "sodium chloride" })
    add.send({ type: "submit" })
    add.send({ type: "text", text: "150" })
    add.send({ type: "submit" })
    add.send({ type: "text", text: "5" })
    const end = add.send({ type: "submit" })
    assert.equal(end.type, "done")
    const added = flowChanges(saved, add.table)
    assert.deepEqual(added.replaced, [])
    assert.equal(added.appended.length, 1)
    assert.equal(added.appended[0]?.mM, 150)
    assert.equal(added.appended[0]?.sigmaMM, 5)

    // a cancelled add leaves nothing
    const gone = AddFlow.add(saved, "nonbio")
    gone.send({ type: "cancel" })
    assert.deepEqual(flowChanges(saved, gone.table), { replaced: [], appended: [] })

    // an edit that was stopped keeps what was taken
    const edit = AddFlow.edit(saved, 0)
    edit.send({ type: "text", text: "renamed" })
    edit.send({ type: "submit" })
    edit.send({ type: "cancel" })
    const changed = flowChanges(saved, edit.table)
    assert.deepEqual(changed.appended, [])
    assert.equal(changed.replaced.length, 1)
    assert.equal(changed.replaced[0]?.[0], 0)
    assert.equal(changed.replaced[0]?.[1].name, "renamed")
})

test("the keys of each step and the hints of the path prompt", () => {
    const flow = AddFlow.add(new Drafts<Solute>(), "nonbio")
    assert.deepEqual(
        flowLegend(flow.step, false).map((i) => i.label),
        ["take", "move", "complete", "cancel"],
    )
    const protein = AddFlow.add(new Drafts<Solute>(), "protein")
    const labels = (canPick: boolean) =>
        flowLegend(protein.step, canPick).map((i) => i.label)
    assert.ok(labels(true).includes("file picker"))
    assert.equal(labels(false).includes("file picker"), false)
    const nuc = AddFlow.add(new Drafts<Solute>(), "nucleotide")
    assert.deepEqual(
        flowLegend(nuc.step, false).map((i) => i.label),
        ["take", "move", "cancel"],
    )
    // a path that is not absolute has no hints, and a folder that is not there none
    assert.deepEqual(pathSuggestions("relative/path"), [])
    assert.deepEqual(pathSuggestions("/no/such/folder/ab"), [])
})
