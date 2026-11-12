// SPDX-License-Identifier: LGPL-3.0-or-later

// The same solute twice is refused: two rows are duplicates when they resolve to the same
// solute of the bundled tables (`cl-` and `chloride`), in the add flow, in an edit, in the
// draft check and in a file that holds one (which still opens, with the problem told).

import assert from "node:assert/strict"
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { AddFlow } from "../src/store/add-flow.js"
import type { AddEvent, PromptStep } from "../src/store/add-state.js"
import { readSolutes, rowProblem } from "../src/store/buffer.js"
import { Drafts } from "../src/store/lists.js"
import {
    bufferRow,
    duplicateMessage,
    firstDuplicate,
    type Solute,
    sameSoluteKey,
    soluteOf,
} from "../src/store/solutes.js"
import { tempDir } from "./support/fixtures.js"

/** A solute row as the add flow makes it: the name typed and the table's name in `arg`. */
const row = (name: string, arg: string, kind = "nonbiological"): Solute => ({
    kind,
    name,
    arg,
    mM: 10,
    sigmaMM: 1,
})

const text = (t: string): AddEvent => ({ type: "text", text: t })
const submit: AddEvent = { type: "submit" }

/** The flow of an add key over a table, with `typed` entered and submitted. */
function adding(table: Drafts<Solute>, typed: string): AddFlow {
    const flow = AddFlow.add(table, "nonbio", { customs: [] })
    flow.send(text(typed))
    flow.send(submit)
    return flow
}

test("alias pairs are one solute; different species are different solutes", () => {
    const key = (name: string, arg: string) => sameSoluteKey(row(name, arg))
    // the typed arg is resolved through the same index the add flow uses
    assert.equal(key("cl-", "cl-"), key("chloride", "chloride"))
    assert.equal(key("chloride ion", "chloride ion"), key("chloride", "chloride"))
    assert.equal(key("NaCl", "NaCl"), key("sodium chloride", "sodium chloride"))
    assert.equal(key("table salt", "table salt"), key("sodium chloride", "sodium chloride"))
    assert.equal(key("na+", "na+"), key("sodium ion", "sodium(1+)"))
    assert.equal(key("Tris", " TRIS "), key("tris", "tris"), "case and blanks")
    // three different solutes: do not merge
    const three = ["sodium chloride", "chloride", "sodium(1+)"].map((n) => key(n, n))
    assert.equal(new Set(three).size, 3)
    // a polymer grade is another solute than another grade; the same grade twice is one
    assert.notEqual(
        sameSoluteKey(row("PEG 550", "peg 550", "polymer")),
        sameSoluteKey(row("PEG 1450", "peg 1450", "polymer")),
    )
    assert.equal(
        sameSoluteKey(row("a", "peg 550", "polymer")),
        sameSoluteKey(row("b", "PEG 550", "polymer")),
    )
    // the same letters of another kind are no duplicate; of the same kind they are
    assert.notEqual(
        sameSoluteKey(row("p", "acgt", "dna")),
        sameSoluteKey(row("q", "acgt", "rna")),
    )
    assert.equal(
        sameSoluteKey(row("p", "ACGT", "dna")),
        sameSoluteKey(row("q", "acgt", "dna")),
    )
})

test("the add flow refuses a second name of a solute, before the amounts", () => {
    const table = Drafts.of([row("chloride", "chloride")])
    const flow = adding(table, "cl-")
    const step = flow.step
    assert.equal(step.type, "dropdown")
    const problem = (step as { problem?: string }).problem
    assert.equal(problem, "cl- already in the buffer (as chloride)")
    // nothing moved on: the amounts are not asked
    assert.ok(!flow.done)
    // the owner's pair the other way round, and a different species is accepted
    const nacl = Drafts.of([row("NaCl", "sodium chloride")])
    assert.match(
        (adding(nacl, "sodium chloride").step as { problem?: string }).problem ?? "",
        /already in the buffer \(as NaCl\)/,
    )
    const other = adding(Drafts.of([row("sodium chloride", "sodium chloride")]), "chloride")
    assert.equal(other.step.type, "prompt")
    assert.equal((other.step as PromptStep).label, "mM")
})

test("editing a name only relabels: it cannot make a duplicate, the arg decides", () => {
    // the name of a row is a label; what the row is stays its `arg`
    const table = Drafts.of([row("chloride", "chloride"), row("tris", "tris")])
    const flow = AddFlow.edit(table, 1)
    flow.send(text("cl-"))
    flow.send(submit)
    const renamed = flow.table.value(1) as Solute
    assert.deepEqual([renamed.name, renamed.arg], ["cl-", "tris"])
    assert.equal(firstDuplicate(flow.table), undefined)
    const own = duplicateMessage(table, row("tris", "tris"), [1])
    assert.equal(own, undefined, "own row skipped")
})

test("a table with a solute twice: the first is told, removed rows skipped", () => {
    const table = Drafts.of([
        row("chloride", "chloride"),
        row("tris", "tris"),
        row("cl-", "cl-"),
    ])
    assert.deepEqual(firstDuplicate(table), [2, "cl- already in the buffer (as chloride)"])
    assert.equal(firstDuplicate(table.remove(2)), undefined)
    const different = Drafts.of([row("a", "chloride"), row("b", "sodium(1+)")])
    assert.equal(firstDuplicate(different), undefined)
    // a row without a name yet is no duplicate of another
    assert.equal(firstDuplicate(Drafts.of([row("", ""), row("", "")])), undefined)
})

test("a file with a duplicate still opens: the loader's row check does not mind", () => {
    const dir = tempDir()
    const rows = [
        { ...bufferRow(row("chloride", "chloride")), mM: 5 },
        { ...bufferRow(row("cl-", "cl-")), mM: 5 },
    ]
    writeFileSync(join(dir, "buffer.json"), JSON.stringify({ solutes: rows }))
    const read = readSolutes(dir)
    assert.equal(read.length, 2)
    for (const r of read) assert.equal(rowProblem(r), undefined)
    const table = Drafts.of(read.map(soluteOf))
    assert.deepEqual(firstDuplicate(table), [1, "cl- already in the buffer (as chloride)"])
    assert.equal(rowProblem(bufferRow(table.value(1) as Solute)), undefined)
})
