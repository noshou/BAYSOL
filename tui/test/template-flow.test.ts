// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the buffer template flow: the state machine (`store/template-flow.ts`) in the
// way of `add-flow.test.ts`, the steps drawn at 80 x 24, and the rows that follow the pH
// (`store/template-rows.ts`): the link of a row to its template, the rows worked out
// again at a new pH, the groups that stop following, and the link in the files.

import assert from "node:assert/strict"
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { createElement, type ReactNode } from "react"
import { displayWidth } from "../src/core/terminal.js"
import { useBufferTemplate } from "../src/screens/buffer-template.js"
import { useTableScreen } from "../src/screens/screen-rules.js"
import {
    readRecipes,
    readSolutes,
    recipeSolutes,
    rowProblem,
    saveRecipe,
    writeSolutes,
} from "../src/store/buffer.js"
import { computeTemplate, offered } from "../src/store/buffer-templates.js"
import { Drafts, MAX_ROWS } from "../src/store/lists.js"
import {
    bufferRow,
    type ConcUnit,
    rowOf,
    type Solute,
    soluteOf,
} from "../src/store/solutes.js"
import { TemplateFlow, type TemplateStep } from "../src/store/template-flow.js"
import {
    changedGroups,
    cleanRow,
    detach,
    linkOf,
    recompute,
    setAtTemperature,
    signatures,
} from "../src/store/template-rows.js"
import { Frame } from "../src/ui/frame.js"
import { type Column, DataTable } from "../src/ui/theme.js"
import { drawLines, tempDir } from "./support/fixtures.js"

const nonbio = (name: string, mM: number): Solute => ({
    kind: "nonbiological",
    name,
    arg: name,
    mM,
    sigmaMM: mM / 100,
})

/** A row a template made (it has a link), as the rows of an earlier flow are. */
const linked = (name: string, mM: number): Solute => ({
    ...nonbio(name, mM),
    template: { id: "tris", mM: 10, "sigmaMm": 0.2, titrant: "chloride" },
})

/** The index of a template in the dropdown. */
const indexOf = (id: string) => offered().findIndex((t) => t.id === id)

/** A flow started on a table of rows, with a pH row or none. */
function begin(
    rows: Solute[] = [],
    pH: number | undefined = undefined,
    unit: ConcUnit = "mM",
): TemplateFlow {
    const conditions = pH === undefined ? undefined : { pH, "sigmaPh": 0.1 }
    return new TemplateFlow({ drafts: Drafts.of(rows), conditions, unit })
}

/** Answers each prompt with its text; the `pH set at` dropdown after the pH takes its first
 * choice (the buffer's temperature). */
function answer(flow: TemplateFlow, texts: string[]): void {
    for (const text of texts) {
        flow.submit(text)
        if (flow.step.type === "setat") flow.pick(0)
    }
}

/** The link of a row made by a template. */
const linkOfSolute = (s: Solute) => s.template as { "setAt"?: unknown } | undefined

/** What the flow ended with (a function, so a check before it does not narrow). */
const done = (flow: TemplateFlow) => flow.done

/** The step as one of its kinds. */
function stepOf<T extends TemplateStep["type"]>(
    flow: TemplateFlow,
    type: T,
): Extract<TemplateStep, { type: T }> {
    const step = flow.step
    assert.equal(step.type, type, JSON.stringify(step).slice(0, 200))
    return step as Extract<TemplateStep, { type: T }>
}

// ========================================================================================
// 1. The flow
// ========================================================================================

test("the dropdown offers the available templates, labelled", () => {
    const { items } = stepOf(begin(), "pick")
    assert.equal(items.length, 32)
    const texts = items.map((i) => i.text)
    assert.ok(texts.includes("Tris, pH 7.1-9.1"))
    assert.ok(texts.includes("PBS, mixture"))
    assert.ok(texts.includes("TAPS, pH 7.4-9.4 (constants not cross-checked)"))
    assert.ok(!texts.some((t) => t.startsWith("HEPPS") || t.startsWith("ACES")))
})

test("Tris: concentration, uncertainty, pH, rest of the recipe, then the rows", () => {
    // the table has 100 mM NaCl and no pH yet
    const flow = begin([nonbio("sodium chloride", 100)])
    flow.pick(indexOf("tris"))
    assert.equal(stepOf(flow, "prompt").label, "concentration [mM]:")
    flow.submit("10")
    const sigma = stepOf(flow, "prompt")
    assert.equal(sigma.label, "uncertainty [mM]:")
    assert.equal(sigma.initial, "0.2", "2 % of the concentration")
    flow.submit("0.2")
    // no titrant question for Tris (chloride is the only counter-ion)
    const ph = stepOf(flow, "prompt")
    assert.equal(ph.label, "pH:")
    assert.equal(ph.initial, "", "no pH set in the table")
    flow.submit("7.5")
    // `pH set at`: the buffer's temperature (not set here), room, or another
    const setAt = stepOf(flow, "setat")
    assert.deepEqual(setAt.items.map((i) => i.text), [
        "buffer temperature (not set: 22 °C)",
        "22 °C (room)",
        "other",
    ])
    flow.pick(0)
    const rest = stepOf(flow, "prompt")
    assert.equal(rest.label, "rest of the recipe, ionic strength [mM]:")
    assert.equal(rest.initial, "100", "from the sodium chloride row")
    flow.submit("100")
    const confirm = stepOf(flow, "confirm")
    assert.equal(confirm.phLine, "sets the pH to 7.5")
    assert.deepEqual(
        confirm.outcome.rows.map((r) => r.name),
        ["tris", "chloride"],
    )
    flow.accept()
    const done = flow.done
    assert.ok(done && !done.cancelled)
    assert.equal(done.added, 2)
    assert.deepEqual(done.conditions, { pH: 7.5, "sigmaPh": 0.1 })
    // ordinary rows: new drafts, complete, passing the loader's check
    assert.equal(done.drafts.length, 3)
    const marks = done.drafts.rows.map((_, i) => done.drafts.mark(i))
    assert.deepEqual(marks, [undefined, "*", "*"])
    for (let i = 1; i < 3; i++) {
        const s = done.drafts.value(i) as Solute
        assert.equal(rowProblem(bufferRow(s)), undefined)
        assert.equal(s.kind, "nonbiological")
    }
    const chloride = done.drafts.value(2) as Solute
    assert.equal(chloride.name, "chloride")
    assert.ok(Math.abs((chloride.mM as number) - 8.5374) < 0.001)
})

test("HEPES asks the titrant; the pH comes from the table", () => {
    const flow = begin([], 7.4)
    flow.pick(indexOf("hepes"))
    flow.submit("25")
    flow.submit("0.5")
    const ion = stepOf(flow, "ion")
    assert.deepEqual(ion.items.map((i) => i.text), ["NaOH (sodium)", "KOH (potassium)"])
    flow.pick(1)
    assert.equal(stepOf(flow, "prompt").initial, "7.4", "the table's pH")
    answer(flow, ["7.4"])
    assert.equal(stepOf(flow, "prompt").initial, "", "nothing to add up: blank is 0")
    flow.submit("")
    const confirm = stepOf(flow, "confirm")
    assert.equal(confirm.phLine, undefined, "the pH of the table is the pH asked")
    assert.deepEqual(
        confirm.outcome.rows.map((r) => r.name),
        ["hepes", "potassium(1+)"],
    )
    flow.accept()
    assert.equal(flow.done?.conditions, undefined, "the pH row is left alone")
})

test("the table's unit: typed and shown in it, stored in mM", () => {
    const flow = begin([], undefined, "M")
    flow.pick(indexOf("tris"))
    assert.equal(stepOf(flow, "prompt").label, "concentration [M]:")
    flow.submit("0.01")
    const sigma = stepOf(flow, "prompt")
    assert.equal(sigma.initial, "0.0002")
    answer(flow, [sigma.initial, "7.5", ""])
    const tris = stepOf(flow, "confirm").outcome.rows[0]
    assert.deepEqual([tris.name, tris.mM, tris.sigmaMM], ["tris", 10, 0.2])
})

test("a refused answer keeps the question and says why", () => {
    const flow = begin()
    flow.pick(indexOf("tris"))
    flow.submit("-3")
    assert.equal(stepOf(flow, "prompt").problem, "mM must be > 0")
    flow.submit("abc")
    assert.equal(stepOf(flow, "prompt").label, "concentration [mM]:")
    flow.submit("10")
    flow.submit("-1")
    assert.equal(stepOf(flow, "prompt").problem, "not below 0")
    flow.submit("0.2")
    flow.submit("20")
    assert.match(stepOf(flow, "prompt").problem ?? "", /^pH from /)
    answer(flow, ["7.5"])
    flow.submit("-5")
    assert.equal(stepOf(flow, "prompt").problem, "not below 0")
    assert.equal(flow.done, undefined)
})

test("a mixture: PBS has no questions; TBS asks the pH of its own", () => {
    const pbs = begin([], 7.0)
    pbs.pick(indexOf("pbs"))
    const confirm = stepOf(pbs, "confirm")
    assert.equal(confirm.phLine, "changes the pH 7 to 7.4")
    assert.equal(confirm.outcome.rows.length, 5)
    pbs.accept()
    assert.deepEqual(pbs.done?.conditions, { pH: 7.4, "sigmaPh": 0.1 })
    assert.equal(pbs.done?.added, 5)

    const tbs = begin()
    tbs.pick(indexOf("tbs"))
    assert.equal(stepOf(tbs, "prompt").initial, "7.6", "the recipe's pH")
    tbs.submit("7.6")
    tbs.pick(0)
    assert.equal(stepOf(tbs, "prompt").label, "rest of the recipe, ionic strength [mM]:")
    tbs.submit("")
    assert.equal(stepOf(tbs, "confirm").outcome.rows.length, 3)
})

test("Esc leaves the table as it was", () => {
    const flow = begin([nonbio("sodium chloride", 100)])
    flow.pick(indexOf("pbs"))
    flow.cancel()
    assert.ok(flow.done?.cancelled)
    assert.equal(flow.done?.drafts.length, 1)
    assert.equal(flow.done?.added, 0)
})

test("rows of the same names are replaced only after the question", () => {
    const flow = begin([linked("tris", 5), nonbio("glycerol", 1000), linked("chloride", 1)])
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2", "7.5", ""])
    stepOf(flow, "confirm")
    flow.accept()
    // asked, nothing changed yet
    assert.equal(done(flow), undefined)
    assert.deepEqual(stepOf(flow, "replace").names, ["tris", "chloride"])
    flow.accept()
    const drafts = done(flow)?.drafts as Drafts<Solute>
    assert.equal(drafts.length, 3, "replaced in place, not duplicated")
    assert.equal((drafts.value(0) as Solute).mM, 10)
    assert.equal(drafts.mark(0), "*", "an edited row")
    assert.equal(drafts.mark(1), undefined)
    assert.ok(Math.abs(((drafts.value(2) as Solute).mM as number) - 8.5) < 0.2)
    assert.equal(done(flow)?.added, 2)
})

test("a hand-typed row of the same solute is refused, not replaced", () => {
    // `cl-` and `chloride` are one solute: the typed row blocks the template's chloride
    const flow = begin([{ ...nonbio("cl-", 5), arg: "chloride" }])
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2", "7.5", ""])
    const confirm = stepOf(flow, "confirm")
    assert.equal(confirm.problem, "chloride already in the buffer: remove or edit it first")
    flow.accept()
    assert.equal(done(flow), undefined, "Enter adds nothing")
})

test("a refused replacement leaves the table alone", () => {
    const flow = begin([linked("tris", 5)])
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2", "7.5", ""])
    flow.accept()
    stepOf(flow, "replace")
    flow.cancel()
    assert.ok(flow.done?.cancelled)
    assert.equal((done(flow)?.drafts.value(0) as Solute | undefined)?.mM, 5)
})

test("a removed row of the same name does not count", () => {
    const table = Drafts.of([linked("tris", 5)]).remove(0)
    const flow = new TemplateFlow({ drafts: table, conditions: undefined })
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2", "7.5", ""])
    flow.accept()
    assert.equal(flow.done?.drafts.length, 3, "added after the removed one")
})

test("the row cap is respected", () => {
    const full = Drafts.of(
        Array.from({ length: MAX_ROWS - 1 }, (_, i) => nonbio(`salt ${i}`, 1)),
    )
    const flow = new TemplateFlow({ drafts: full, conditions: undefined })
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2", "7.5", ""])
    const confirm = stepOf(flow, "confirm")
    assert.equal(confirm.problem, `too many rows (${MAX_ROWS} at most)`)
    flow.accept()
    assert.equal(flow.done, undefined, "Enter adds nothing")
})

// ========================================================================================
// 2. The steps drawn at 80 x 24
// ========================================================================================

const rule: Column<Solute>[] = [{ title: "solute", grow: 1, text: (s) => s.name }]

/** A screen that is the buffer table with the template flow open at a step. */
function Harness(props: { flow: TemplateFlow }): ReactNode {
    const t = useTableScreen<Solute>({
        items: [nonbio("sodium chloride", 100)],
        save: () => undefined,
        check: () => undefined,
        adds: [],
    })
    const tmpl = useBufferTemplate(t, undefined, () => undefined, props.flow)
    return createElement(
        Frame,
        { design: "blocky", title: "buffer", legend: tmpl.legend, note: tmpl.note },
        tmpl.page ??
            createElement(DataTable<Solute>, {
                border: "double",
                columns: rule,
                rows: t.drafts.rows.map((r) => r.saved as Solute),
                cursor: 0,
                offset: 0,
                pageSize: 3,
                width: t.width,
            }),
        tmpl.entry,
    )
}

/** The lines of a step drawn, after checking they fit 80 x 24. */
function draw(flow: TemplateFlow): string {
    const lines = drawLines(createElement(Harness, { flow }))
    const text = lines.join("\n")
    if (process.env.SHOW) console.log(text)
    assert.ok(lines.length <= 24, `${lines.length} rows\n${text}`)
    for (const line of lines) assert.ok(displayWidth(line) <= 80, `too wide: ${line}`)
    return text
}

test("the template list: a dropdown to type in, with the usable pH ranges", () => {
    const text = draw(begin())
    assert.ok(text.includes("buffer template:"), text)
    assert.ok(text.includes("type to find"), text)
    assert.ok(text.includes("Tris, pH 7.1-9.1"), text)
})

test("a prompt: the question, the field and its keys", () => {
    const flow = begin()
    flow.pick(indexOf("tris"))
    const text = draw(flow)
    assert.ok(text.includes("concentration [mM]:"), text)
    flow.submit("10")
    const sigma = draw(flow)
    assert.ok(sigma.includes("uncertainty [mM]:") && sigma.includes("0.2"), sigma)
    flow.submit("-1")
    assert.ok(draw(flow).includes("not below 0"))
})

test("the confirm page: the rows, the working and the warnings", () => {
    const flow = begin([nonbio("sodium chloride", 100)], 7.4)
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2", "7.0", "100"])
    const text = draw(flow)
    assert.ok(text.includes("add: tris 10 mM"), text)
    assert.ok(/chloride\s+║\s+9\.4\d+\s+║\s+0\.2\d+/.test(text), text)
    assert.ok(text.includes("outside the usable range"), "the warning is shown")
    assert.ok(text.includes("add rows"), "Enter adds")
    assert.ok(text.includes("cancel"), text)
    assert.ok(text.includes("pH 7 set at 22"), "the working is shown")
})

test("the confirm page of the longest recipes fits 80 x 24", () => {
    for (const id of ["pbs", "tbs", "hbs", "ssc"]) {
        const flow = begin([], 7.0)
        flow.pick(indexOf(id))
        // a mixture with a buffer asks the pH and the rest first
        while (flow.step.type === "prompt" || flow.step.type === "setat") {
            if (flow.step.type === "setat") flow.pick(0)
            else flow.submit(flow.step.initial)
        }
        const text = draw(flow)
        assert.ok(text.includes("add rows"), `${id}\n${text}`)
    }
    const flow = begin()
    flow.pick(indexOf("citrate"))
    answer(flow, ["100", "2"])
    flow.pick(0)
    answer(flow, ["6.0", ""])
    const text = draw(flow)
    assert.ok(text.includes("trisodium citrate"), text)
})

test("the replace question: the confirm page stays, the note asks", () => {
    const flow = new TemplateFlow({
        drafts: Drafts.of([linked("tris", 5)]),
        conditions: undefined,
    })
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2", "7.5", ""])
    flow.accept()
    const text = draw(flow)
    assert.ok(text.includes("replace the existing tris?"), text)
    assert.ok(text.includes("replace") && text.includes("cancel"), text)
    assert.ok(/chloride\s+║\s+8\.3/.test(text), "the rows are still shown")
})

test("pH set at: buffer temperature (default), room, or another number", () => {
    const run = (pick: number, other?: string) => {
        const flow = new TemplateFlow({
            drafts: Drafts.of([]),
            conditions: { pH: 7.5, "sigmaPh": 0.1, temperature: 4 },
        })
        flow.pick(indexOf("tris"))
        for (const text of ["10", "0.2", "7.5"]) flow.submit(text)
        const items = stepOf(flow, "setat").items.map((i) => i.text)
        assert.deepEqual(items, ["buffer temperature (4 °C)", "22 °C (room)", "other"])
        flow.pick(pick)
        if (other !== undefined) {
            const ask = stepOf(flow, "prompt")
            assert.equal(ask.label, "pH set at, temperature °C:")
            flow.submit(other)
            if (flow.step.type === "prompt" && flow.step.problem) return flow
        }
        flow.submit("")
        return flow
    }
    const setAt = (flow: TemplateFlow) => {
        flow.accept()
        const drafts = done(flow)?.drafts as Drafts<Solute>
        return linkOfSolute(drafts.value(1) as Solute)?.setAt
    }
    assert.equal(setAt(run(0)), "buffer", "the default")
    assert.equal(setAt(run(1)), 22)
    assert.equal(setAt(run(2, "30")), 30)
    // the working uses that temperature
    assert.ok(stepOf(run(0), "confirm").outcome.explain.join(" ").includes("set at 4 °C"))
    assert.ok(stepOf(run(1), "confirm").outcome.explain.join(" ").includes("set at 22 °C"))
    const explain = (flow: TemplateFlow) =>
        stepOf(flow, "confirm").outcome.explain.join(" ")
    assert.ok(explain(run(2, "30")).includes("set at 30"))
    // `other` is checked like a temperature and keeps the question
    for (const [text, why] of [["150", "from 0 to 100 °C"], ["x", "a number, please"]]) {
        const flow = run(2, text)
        assert.equal(stepOf(flow, "prompt").problem, why, text)
    }
    // the pH row of a flow that sets the pH keeps the buffer's temperature
    const flow = new TemplateFlow({
        drafts: Drafts.of([]),
        conditions: { pH: 7, "sigmaPh": 0.1, temperature: 4 },
    })
    flow.pick(indexOf("tris"))
    for (const text of ["10", "0.2", "7.5"]) flow.submit(text)
    flow.pick(0)
    flow.submit("")
    flow.accept()
    assert.deepEqual(done(flow)?.conditions, { pH: 7.5, "sigmaPh": 0.1, temperature: 4 })
})

test("pH set at is asked where the pH is asked: a mixture with a buffer, not PBS", () => {
    const tbs = begin([], 7.6)
    tbs.pick(indexOf("tbs"))
    tbs.submit("7.6")
    assert.equal(tbs.step.type, "setat")
    tbs.pick(1)
    tbs.submit("")
    tbs.accept()
    const made = done(tbs)?.drafts as Drafts<Solute>
    assert.equal(linkOfSolute(made.value(0) as Solute)?.setAt, 22)
    const pbs = begin()
    pbs.pick(indexOf("pbs"))
    assert.equal(pbs.step.type, "confirm")
})

test("the pH set at dropdown is drawn at 80 x 24", () => {
    const flow = begin([], 7.5)
    flow.pick(indexOf("tris"))
    answer(flow, ["10", "0.2"])
    flow.submit("7.5")
    const text = draw(flow)
    assert.ok(text.includes("pH set at:"), text)
    assert.ok(text.includes("buffer temperature") && text.includes("22 °C (room)"), text)
    assert.ok(text.includes("other"), text)
})

// ========================================================================================
// Rows that follow the pH (was template-rows.test.ts)
// ========================================================================================

const LINK = {
    id: "tris", mM: 10, "sigmaMm": 0.2, titrant: "chloride", "restMm": 100,
    "setAt": "buffer",
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
        conditions: { pH: 7.5, "sigmaPh": 0.1 },
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
    const want = { id: "tbs", "restMm": 0, "setAt": "buffer" }
    assert.deepEqual((run("tbs").value(0) as Solute).template, want)
})

test("a new pH works the group out again: Tris 10 mM from pH 7.5 to 8.0", () => {
    const d = tris()
    const { drafts, changed } = recompute(d, 8.0, 0.1)
    assert.ok(changed)
    const want = computeTemplate({ id: "tris", mM: 10, pH: 8.0, restIonicMM: 100 })
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
        { ...LINK, "restMm": -2 },
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
    saveRecipe(dir, "mine", rows, { pH: 7.5, "sigmaPh": 0.1 })
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
        conditions: { pH: 7.5, "sigmaPh": 0.1, ...(temperature && { temperature }) },
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

test("setAt: a valid value is kept, a bad or missing one makes the link invalid", () => {
    assert.equal(linkOf(LINK)?.setAt, "buffer")
    assert.equal(linkOf({ ...LINK, "setAt": 4 })?.setAt, 4)
    assert.equal(linkOf({ ...LINK, "setAt": 0 })?.setAt, 0)
    for (const bad of [150, -1, "25", "room", null, true, [], Number.NaN])
        assert.equal(linkOf({ ...LINK, "setAt": bad }), undefined, String(bad))
    const { "setAt": _gone, ...missing } = LINK
    assert.equal(linkOf(missing), undefined, "the key is required")
    // the key survives the file
    const dir = tempDir()
    writeSolutes(dir, [
        {
            kind: "nonbiological",
            name: "x",
            arg: "x",
            mM: 1,
            "sigmaMm": 0,
            template: { ...LINK, "setAt": 4 },
        },
    ])
    assert.equal((readSolutes(dir)[0] as { template: typeof LINK }).template.setAt, 4)
})

test("setAtTemperature: the buffer's or a number", () => {
    assert.equal(setAtTemperature({ ...LINK, "setAt": "buffer" }, 4), 4)
    assert.equal(setAtTemperature({ ...LINK, "setAt": "buffer" }, undefined), 22)
    assert.equal(setAtTemperature({ ...LINK, "setAt": 30 }, 4), 30)
})

test("Tris set at 4 C needs more chloride than at 22 C (the pK rises as T falls)", () => {
    const cold = chlorideOf(trisAt(0, 4))?.mM as number
    const room = chlorideOf(trisAt(1, 4))?.mM as number
    const direct = (tempC: number) =>
        computeTemplate({ id: "tris", mM: 10, pH: 7.5, restIonicMM: 0, tempC }).rows.find(
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
    assert.equal(linkOfRow(follow).setAt, "buffer")
    assert.equal(linkOfRow(fixed).setAt, 22)
    const moved = recompute(follow, 7.5, 0.1, 4)
    assert.ok(moved.changed)
    assert.ok(cl(moved.drafts) > cl(follow), "more chloride at 4 C")
    assert.equal(
        cl(moved.drafts),
        computeTemplate({
            id: "tris", mM: 10, pH: 7.5, restIonicMM: 0, tempC: 4,
        }).rows.find(
            (r) => r.name === "chloride",
        )?.mM,
    )
    assert.equal(recompute(fixed, 7.5, 0.1, 4).changed, false, "fixed at 22 C: no move")
    assert.equal(recompute(follow, 7.5, 0.1, 22).changed, false, "same temperature")
})

test("a pH that needs a row a typed row already is does not add a twin", () => {
    const flow = new TemplateFlow({
        drafts: Drafts.of([]),
        conditions: { pH: 3, "sigmaPh": 0.1 },
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
        conditions: { pH: 7.5, "sigmaPh": 0.1 },
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
