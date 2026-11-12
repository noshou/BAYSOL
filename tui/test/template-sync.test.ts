// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the rows that follow the pH: the link of a row to its buffer template
// (`store/template-link.ts`), the rows worked out again at a new pH and the groups that
// stop following (`store/template-sync.ts`), and the link in the files.

import assert from "node:assert/strict"
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import {
    readRecipes,
    readSolutes,
    recipeSolutes,
    rowProblem,
    saveRecipe,
    writeSolutes,
} from "../src/store/buffer.js"
import { computeTemplate, offered } from "../src/store/buffer-templates.js"
import { Drafts } from "../src/store/lists.js"
import { bufferRow, rowOf, type Solute, soluteOf } from "../src/store/solutes.js"
import { TemplateFlow } from "../src/store/template-flow.js"
import { cleanRow, linkOf } from "../src/store/template-link.js"
import {
    changedGroups,
    detach,
    recompute,
    setAtTemperature,
    signatures,
} from "../src/store/template-sync.js"
import { tempDir } from "./support/fixtures.js"

const LINK = {
    id: "tris", mM: 10, "sigma-mM": 0.2, titrant: "chloride", "rest-mM": 100,
    "set-at": "buffer",
}

/** Answers each prompt with its text; the `pH set at` dropdown after the pH takes its first
 * choice (the buffer's temperature). */
function answer(flow: TemplateFlow, texts: string[]): void {
    for (const text of texts) {
        flow.submit(text)
        if (flow.step.type === "setat") flow.pick(0)
    }
}

/** The table a Tris flow makes at pH 7.5 beside a hand-typed NaCl row. */
function tris(): Drafts<Solute> {
    const nacl: Solute = {
        kind: "nonbiological",
        name: "sodium chloride",
        arg: "sodium chloride",
        mM: 100,
        sigmaMM: 1,
    }
    const flow = new TemplateFlow({
        drafts: Drafts.of([nacl]),
        conditions: { pH: 7.5, "sigma-pH": 0.1 },
        unit: "mM",
    })
    flow.pick(offered().findIndex((t) => t.id === "tris"))
    answer(flow, ["10", "0.2", "7.5", "100"])
    flow.accept()
    return flow.done?.drafts as Drafts<Solute>
}

const mM = (d: Drafts<Solute>, i: number) => (d.value(i) as Solute).mM

test("the flow links every row of the group, not the rows of others", () => {
    const d = tris()
    assert.equal((d.value(0) as Solute).template, undefined)
    assert.deepEqual((d.value(1) as Solute).template, LINK)
    assert.deepEqual((d.value(2) as Solute).template, LINK)
    assert.equal(rowProblem(bufferRow(d.value(2) as Solute)), undefined)
})

test("a PBS has no link (its pH is fixed); TBS follows the pH", () => {
    const run = (id: string) => {
        const f = new TemplateFlow({ drafts: Drafts.of([]), conditions: undefined })
        f.pick(offered().findIndex((t) => t.id === id))
        while (f.step.type === "prompt" || f.step.type === "setat") {
            if (f.step.type === "setat") f.pick(0)
            else f.submit(f.step.initial)
        }
        f.accept()
        return f.done?.drafts as Drafts<Solute>
    }
    assert.ok(run("pbs").rows.every((_, i, a) => !(a[i].draft as Solute).template))
    const want = { id: "tbs", "rest-mM": 0, "set-at": "buffer" }
    assert.deepEqual((run("tbs").value(0) as Solute).template, want)
})

test("a new pH works the group out again: Tris 10 mM from pH 7.5 to 8.0", () => {
    const d = tris()
    const { drafts, changed } = recompute(d, 8.0, 0.1)
    assert.ok(changed)
    const want = computeTemplate({ id: "tris", mM: 10, pH: 8.0, restI_mM: 100 })
    const chloride = want.rows.find((r) => r.name === "chloride")
    assert.equal(mM(drafts, 2), chloride?.mM)
    assert.equal((drafts.value(2) as Solute).sigmaMM, chloride?.sigmaMM)
    assert.ok((chloride?.mM as number) < 8.5, "less chloride at the higher pH")
    // the hand-typed row and the buffer's own row stay
    assert.equal(mM(drafts, 0), 100)
    assert.equal(mM(drafts, 1), 10)
    assert.equal(drafts.mark(2), "*")
    // the same pH again changes nothing
    assert.equal(recompute(d, 7.5, 0.1).changed, false)
    // a draft undo gives a saved row back its amount
    const saved = Drafts.of(d.rows.map((_, i) => d.value(i) as Solute))
    const moved = recompute(saved, 8.0, 0.1).drafts
    assert.notEqual(mM(moved, 2), mM(saved, 2))
    assert.equal(mM(moved.undo(2), 2), mM(saved, 2))
})

test("a pH that needs other rows adds and removes them", () => {
    const f = new TemplateFlow({ drafts: Drafts.of([]), conditions: undefined })
    f.pick(offered().findIndex((t) => t.id === "phosphate"))
    f.submit("50")
    f.submit("1")
    f.pick(0)
    answer(f, ["7.0", ""])
    f.accept()
    const d = f.done?.drafts as Drafts<Solute>
    assert.equal(d.length, 2)
    const low = recompute(d, 2.0, 0.1).drafts
    const names = low.rows.map((_, i) => (low.value(i) as Solute).name)
    assert.ok(names.includes("phosphoric acid"), names.join(","))
})

test("a hand edit or a removal takes the whole group off the pH", () => {
    const d = tris()
    const before = signatures(d)
    assert.equal(before.size, 1)
    assert.deepEqual(changedGroups(before, signatures(d)), [])
    // an edit of the chloride row
    const edited = d.set(2, { ...(d.value(2) as Solute), mM: 9 })
    const stale = changedGroups(before, signatures(edited))
    assert.equal(stale.length, 1)
    const free = detach(edited, stale)
    assert.equal(signatures(free).size, 0)
    assert.equal((free.value(1) as Solute).template, undefined)
    assert.equal((free.value(2) as Solute).mM, 9, "the edit stays")
    assert.equal(recompute(free, 8.0, 0.1).changed, false, "nothing follows any more")
    // a removal of the Tris row
    const removed = d.remove(1)
    assert.equal(changedGroups(before, signatures(removed)).length, 1)
    // sorting the rows is no edit
    const sorted = d.sorted((s) => s.name)
    assert.deepEqual(changedGroups(before, signatures(sorted)), [])
})

test("a link that is not valid is dropped and the row stays", () => {
    const row = { kind: "nonbiological", name: "x", arg: "x", mM: 1, sigmaMM: 0 }
    const bad = [
        { ...LINK, id: "nonsense" },
        { ...LINK, mM: -1 },
        { ...LINK, mM: "10" },
        { ...LINK, titrant: 5 },
        { ...LINK, "rest-mM": -2 },
        { id: "pbs" },
        "tris",
        null,
        [],
    ]
    for (const template of bad) {
        const cleaned: Record<string, unknown> = cleanRow({ ...row, template })
        assert.ok(!("template" in cleaned), JSON.stringify(template))
        assert.equal(cleaned.name, "x")
    }
    assert.deepEqual(linkOf({ ...LINK, extra: 1 }), LINK)
    assert.deepEqual(cleanRow({ ...row, template: LINK }).template, LINK)
    // the loader's check never minds the key
    assert.equal(rowProblem(bufferRow({ ...row, template: "junk" } as Solute)), undefined)
})

test("the link is kept by the buffer file and a recipe; a bad one is dropped", () => {
    const d = tris()
    const rows = d.rows.map((_, i) => rowOf(d.value(i) as Solute))
    const dir = tempDir()
    writeSolutes(dir, rows)
    const back = readSolutes(dir)
    assert.deepEqual((back[2] as { template?: unknown }).template, LINK)
    assert.deepEqual(soluteOf(back[1]).template, LINK)
    // a recipe round trip
    saveRecipe(dir, "mine", rows, { pH: 7.5, "sigma-pH": 0.1 })
    const recipe = recipeSolutes(dir, "mine") as unknown as { template?: unknown }[]
    assert.deepEqual(recipe[1].template, LINK)
    assert.equal(recipe[0].template, undefined)
    assert.equal(readRecipes(dir).length, 1)
    // a file with a bad link opens, the row an ordinary one
    const odd = [{ ...rows[2], template: { ...LINK, id: "nonsense" } }]
    writeFileSync(join(dir, "buffer.json"), JSON.stringify({ solutes: odd }))
    const read = readSolutes(dir)
    assert.equal(read.length, 1)
    assert.ok(!("template" in read[0]))
})

// ----------------------------------------------------------------------------------------
// `pH set at`: the temperature of a link, and the rows that follow the buffer's
// ----------------------------------------------------------------------------------------

/** The flow of Tris 10 mM, pH 7.5, whose `pH set at` is the choice (0 buffer, 1 room). */
function trisAt(choice: number, temperature?: number): Drafts<Solute> {
    const flow = new TemplateFlow({
        drafts: Drafts.of([]),
        conditions: { pH: 7.5, "sigma-pH": 0.1, ...(temperature && { temperature }) },
        unit: "mM",
    })
    flow.pick(offered().findIndex((t) => t.id === "tris"))
    for (const text of ["10", "0.2", "7.5"]) flow.submit(text)
    flow.pick(choice)
    flow.submit("")
    flow.accept()
    return flow.done?.drafts as Drafts<Solute>
}

const chlorideOf = (d: Drafts<Solute>) =>
    d.rows.map((_, i) => d.value(i) as Solute).find((s) => s.name === "chloride")

test("set-at: a valid value is kept, a bad or missing one makes the link invalid", () => {
    assert.equal(linkOf(LINK)?.["set-at"], "buffer")
    assert.equal(linkOf({ ...LINK, "set-at": 4 })?.["set-at"], 4)
    assert.equal(linkOf({ ...LINK, "set-at": 0 })?.["set-at"], 0)
    for (const bad of [150, -1, "25", "room", null, true, [], Number.NaN])
        assert.equal(linkOf({ ...LINK, "set-at": bad }), undefined, String(bad))
    const { "set-at": _gone, ...missing } = LINK
    assert.equal(linkOf(missing), undefined, "the key is required")
    // the key survives the file
    const dir = tempDir()
    writeSolutes(dir, [
        {
            kind: "nonbiological",
            name: "x",
            arg: "x",
            mM: 1,
            "sigma-mM": 0,
            template: { ...LINK, "set-at": 4 },
        },
    ])
    assert.equal((readSolutes(dir)[0] as { template: typeof LINK }).template["set-at"], 4)
})

test("setAtTemperature: the buffer's or a number", () => {
    assert.equal(setAtTemperature({ ...LINK, "set-at": "buffer" }, 4), 4)
    assert.equal(setAtTemperature({ ...LINK, "set-at": "buffer" }, undefined), 22)
    assert.equal(setAtTemperature({ ...LINK, "set-at": 30 }, 4), 30)
})

test("Tris set at 4 C needs more chloride than at 22 C (the pK rises as T falls)", () => {
    const cold = chlorideOf(trisAt(0, 4))?.mM as number
    const room = chlorideOf(trisAt(1, 4))?.mM as number
    const direct = (tempC: number) =>
        computeTemplate({ id: "tris", mM: 10, pH: 7.5, restI_mM: 0, tempC }).rows.find(
            (r) => r.name === "chloride",
        )?.mM as number
    assert.ok(cold > room, `${cold} > ${room}`)
    assert.equal(cold, direct(4))
    assert.equal(room, direct(22))
    // with no temperature in the buffer `buffer temperature` is 22 C
    assert.equal(chlorideOf(trisAt(0))?.mM, room)
})

test("a temperature change moves the buffer's groups, the fixed ones stay", () => {
    const follow = trisAt(0, 22)
    const fixed = trisAt(1, 22)
    const cl = (d: Drafts<Solute>) => chlorideOf(d)?.mM as number
    const linkOfRow = (d: Drafts<Solute>) => chlorideOf(d)?.template as typeof LINK
    assert.equal(linkOfRow(follow)["set-at"], "buffer")
    assert.equal(linkOfRow(fixed)["set-at"], 22)
    const moved = recompute(follow, 7.5, 0.1, 4)
    assert.ok(moved.changed)
    assert.ok(cl(moved.drafts) > cl(follow), "more chloride at 4 C")
    assert.equal(
        cl(moved.drafts),
        computeTemplate({ id: "tris", mM: 10, pH: 7.5, restI_mM: 0, tempC: 4 }).rows.find(
            (r) => r.name === "chloride",
        )?.mM,
    )
    assert.equal(recompute(fixed, 7.5, 0.1, 4).changed, false, "fixed at 22 C: no move")
    assert.equal(recompute(follow, 7.5, 0.1, 22).changed, false, "same temperature")
})

test("a pH that needs a row a typed row already is does not add a twin", () => {
    const flow = new TemplateFlow({
        drafts: Drafts.of([]),
        conditions: { pH: 3, "sigma-pH": 0.1 },
    })
    flow.pick(offered().findIndex((t) => t.id === "hepes"))
    for (const text of ["25", "0.5"]) flow.submit(text)
    flow.pick(0)
    for (const text of ["3", ""]) {
        flow.submit(text)
        if (flow.step.type === "setat") flow.pick(0)
    }
    flow.accept()
    const made = flow.done?.drafts as Drafts<Solute>
    const names = (d: Drafts<Solute>) => d.rows.map((_, i) => (d.value(i) as Solute).arg)
    assert.ok(!names(made).includes("sodium(1+)"), names(made).join(","))
    const typed = made.add({
        kind: "nonbiological",
        name: "sodium(1+)",
        arg: "sodium(1+)",
        mM: 2,
        sigmaMM: 0.1,
    })
    const out = recompute(typed, 7.4, 0.1)
    assert.deepEqual(out.skipped, ["sodium(1+)"])
    assert.equal(names(out.drafts).filter((a) => a === "sodium(1+)").length, 1)
    const row = out.drafts.rows.findIndex(
        (_, i) => (out.drafts.value(i) as Solute).arg === "sodium(1+)",
    )
    assert.equal(mM(out.drafts, row), 2, "the typed row is untouched")
    assert.equal((out.drafts.value(row) as Solute).template, undefined)
})

test("picking a template again replaces its group: one group per link", () => {
    const again = new TemplateFlow({
        drafts: tris(),
        conditions: { pH: 7.5, "sigma-pH": 0.1 },
    })
    again.pick(offered().findIndex((t) => t.id === "tris"))
    for (const text of ["10", "0.2", "7.5"]) again.submit(text)
    again.pick(0)
    again.submit("100")
    again.accept()
    again.accept()
    const d = again.done?.drafts as Drafts<Solute>
    assert.equal(d.length, 3, "replaced, not doubled")
    assert.equal(signatures(d).size, 1)
})
