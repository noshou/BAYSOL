// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the later parts of the templates: custom solutes in the wizard and in the rows,
// editing a definition (the wizard starts from it), turning the rows of a buffer into a
// table template, the three-answer question of saving, and what loading and saving a
// recipe comes to (the pure parts of `screens/menus.tsx`).

import assert from "node:assert/strict"
import { test } from "node:test"
import { saveAsTemplateQuestion } from "../src/screens/screen-rules.js"
import {
    type BufferRow,
    type Conditions,
    type Recipe,
    rowProblem,
} from "../src/store/buffer.js"
import type { NonbioEntry } from "../src/store/custom.js"
import { Drafts } from "../src/store/lists.js"
import type { Solute } from "../src/store/solutes.js"
import {
    checkDefinition,
    type Definition,
    rowsFor,
    type TableDefinition,
} from "../src/store/template-defs.js"
import { soluteFromSpec } from "../src/store/template-link.js"
import {
    linkFor,
    offersTemplate,
    recipeLoad,
    recipeSave,
    templateRows,
} from "../src/store/template-recipes.js"
import { recompute, seedOfRows } from "../src/store/template-sync.js"
import { TemplateWizard, type WizardOptions } from "../src/store/template-wizard.js"
import { answerOf, questionLegend } from "../src/ui/input.js"
import { KeyInput, keys } from "../src/ui/interaction.js"

const DYE: NonbioEntry = {
    kind: "nonbiological",
    name: "My Dye",
    formula: "",
    z: 40,
    pmv: 300,
    sigma: null,
}

const SNAPSHOT = { z: 40, pmv: 300, "sigma-pmv": null }

/** Answers the wizard step by step: the answers in order, a number picks, text types. */
function drive(options: WizardOptions, answers: (number | string)[]): Definition {
    const w = new TemplateWizard("my buffer", options)
    for (const answer of answers) {
        assert.ok(!w.done, "the wizard asked more than expected")
        if (typeof answer === "number") w.pick(answer)
        else w.submit(answer)
    }
    assert.ok(w.done && "definition" in w.done, w.problem ?? "no definition")
    return w.done.definition
}

/** Answers every step with what it starts from: an edit that changes nothing. */
function replay(options: WizardOptions): Definition {
    const w = new TemplateWizard("my buffer", options)
    for (let n = 0; !w.done && n < 200; n++) {
        const step = w.step
        if (step.type === "prompt") w.submit(step.initial)
        else {
            const text = (step.initial ?? "").toLowerCase()
            w.pick(Math.max(0, step.items.findIndex((i) => i.toLowerCase().includes(text))))
        }
    }
    assert.ok(w.done && "definition" in w.done, w.problem ?? "no definition")
    return w.done.definition
}

/** A table of a custom solute and chloride at two pH. */
const TABLE_ANSWERS = [
    2, // my own amounts
    "6",
    "my dye 10 0.1",
    "chloride 5 0.1",
    "",
    "8",
    "12 0.1",
    "6 0.1",
    "", // no third point
]

test("the wizard takes a custom solute for a custom buffer and stores its snapshot", () => {
    const def = drive({ customs: [DYE] }, [
        1, // my own buffer
        "my dye",
        "1",
        "7.5",
        "",
        "0",
        1, // a base
        0,
        "10",
        "0.2",
        "",
        "",
    ])
    assert.equal(def.kind, "custom")
    if (def.kind !== "custom") return
    assert.equal(def.solute, "My Dye")
    assert.deepEqual(def.soluteData, SNAPSHOT)
    assert.deepEqual(checkDefinition(def), [])
    const made = rowsFor(def, { pH: 7.5, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok(!("error" in made))
    const row = made.rows.find((r) => r.arg === "My Dye")
    assert.deepEqual(row?.custom, SNAPSHOT)
    assert.ok(made.rows.some((r) => r.custom === undefined), "the counter-ion is bundled")
})

test("a name that is neither bundled nor custom is refused with the problem", () => {
    const w = new TemplateWizard("x", { customs: [DYE] })
    w.pick(1)
    w.submit("no such solute")
    assert.equal(w.step.type, "prompt")
    assert.match(w.step.problem ?? "", /not a solute/)
})

test("a table takes custom solutes; later points keep the first point's rows", () => {
    const def = drive({ customs: [DYE] }, TABLE_ANSWERS) as TableDefinition
    assert.equal(def.kind, "table")
    assert.equal(def.points.length, 2)
    for (const point of def.points) assert.deepEqual(point.rows[0]?.custom, SNAPSHOT)
    assert.equal(def.points[1]?.rows[0]?.mM, 12)
    assert.deepEqual(checkDefinition(def), [])
    // halfway between the points
    const made = rowsFor(def, { pH: 7, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok(!("error" in made))
    assert.equal(made.rows[0]?.mM, 11)
    assert.deepEqual(made.rows[0]?.custom, SNAPSHOT)
})

test("a custom row in a definition needs its snapshot", () => {
    const def = drive({ customs: [DYE] }, TABLE_ANSWERS) as TableDefinition
    const bare = structuredClone(def)
    for (const point of bare.points) delete point.rows[0]?.custom
    assert.match(checkDefinition(bare)[0] ?? "", /My Dye is not in the solute tables/)
    const bad = structuredClone(def)
    const first = bad.points[0]?.rows[0]
    if (first?.custom) first.custom.z = 0
    assert.match(checkDefinition(bad)[0] ?? "", /z must be a whole number/)
})

test("the rows of a custom definition are custom-nonbio rows the loader accepts", () => {
    const def = drive({ customs: [DYE] }, TABLE_ANSWERS)
    const recipe: Recipe = { name: "dye", solutes: [], template: def }
    const made = templateRows(recipe, { pH: 7, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok(!("error" in made))
    const [row] = made.rows
    assert.equal(row?.kind, "custom-nonbio")
    assert.equal((row as { custom?: string }).custom, "My Dye")
    assert.equal(rowProblem(row), undefined)
    assert.ok(row?.template, "linked, so it follows the pH")
})

test("linked custom rows follow the pH and are never added twice", () => {
    const def = drive({ customs: [DYE] }, TABLE_ANSWERS)
    const link = linkFor(def)
    const first = rowsFor(def, { pH: 6, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok(!("error" in first))
    let drafts = Drafts.of<Solute>(first.rows.map((r) => soluteFromSpec(r, link)))
    const moved = recompute(drafts, 8, 0.1, 25)
    assert.ok(moved.changed)
    drafts = moved.drafts
    assert.equal(drafts.length, 2, "no row was added")
    const dye = drafts.value(0) as Solute
    assert.equal(dye.kind, "custom-nonbio")
    assert.equal(dye.mM, 12)
    assert.deepEqual(moved.skipped, [])
})

// ---- editing a definition

test("the wizard starts from a definition: every question is prefilled", () => {
    const custom = drive({ customs: [DYE] }, [
        1,
        "my dye",
        "2",
        "4.2",
        "",
        "1",
        "7.1",
        "0.002",
        "0",
        0, // an acid
        0,
        "10",
        "0.2",
        "25",
        "50",
    ])
    assert.deepEqual(replay({ initial: custom }), custom)
    const table = drive({ customs: [DYE] }, TABLE_ANSWERS)
    assert.deepEqual(replay({ initial: table }), table)
    const builtin: Definition = { kind: "builtin", id: "tris", mM: 10, sigmaMM: 0.2 }
    assert.deepEqual(replay({ initial: builtin }), builtin)
})

test("an edited definition keeps a custom solute that was deleted since", () => {
    const table = drive({ customs: [DYE] }, TABLE_ANSWERS)
    // no custom solutes any more: the snapshot of the definition is what resolves the name
    assert.deepEqual(replay({ initial: table, customs: [] }), table)
})

test("the edit can change a value", () => {
    const table = drive({ customs: [DYE] }, TABLE_ANSWERS) as TableDefinition
    const w = new TemplateWizard("t", { initial: table, customs: [DYE] })
    w.pick(2)
    w.submit("5") // the first point moves
    assert.equal(w.step.type === "prompt" && w.step.initial, "My Dye 10 0.1")
    w.submit("My Dye 11 0.1")
    w.submit("chloride 5 0.1")
    w.submit("")
    w.submit("8")
    w.submit("12 0.1")
    w.submit("6 0.1")
    w.submit("")
    assert.ok(w.done && "definition" in w.done)
    const done = (w.done as { definition: TableDefinition }).definition
    assert.equal(done.points[0]?.pH, 5)
    assert.equal(done.points[0]?.rows[0]?.mM, 11)
})

// ---- the rows of a buffer into a table template

const row = (patch: Partial<Solute>): Solute => ({
    kind: "nonbiological",
    name: "chloride",
    arg: "chloride",
    mM: 5,
    sigmaMM: 0.1,
    ...patch,
})

const customRow = (): Solute =>
    ({
        kind: "custom-nonbio",
        name: "My Dye",
        custom: "My Dye",
        z: 40,
        pmv: 300,
        "sigma-pmv": null,
        mM: 10,
        sigmaMM: 0.1,
    }) as unknown as Solute

test("the rows that can follow the pH are the seed; the others stay", () => {
    const polymer = row({ kind: "polymer", name: "PEG", arg: "PEG" })
    const template = linkFor({ kind: "builtin", id: "tris", mM: 10 })
    const linked = row({ name: "sodium(1+)", arg: "sodium(1+)", template })
    const rows = [row({}), polymer, customRow(), linked, row({ arg: "z" })]
    let drafts = Drafts.of<Solute>(rows)
    drafts = drafts.remove(4)
    const made = seedOfRows(drafts, 7.4)
    assert.ok("seed" in made)
    assert.deepEqual(made.indices, [0, 2])
    assert.equal(made.seed.pH, 7.4)
    assert.deepEqual(made.seed.rows[1]?.custom, SNAPSHOT)
    assert.equal(made.seed.rows[1]?.arg, "My Dye")
})

test("rows that are not complete, or none, are told", () => {
    const incomplete = Drafts.of<Solute>([row({ mM: null })])
    assert.deepEqual(seedOfRows(incomplete, 7), {
        problem: "row 1: the amount is not complete",
    })
    const none = Drafts.of<Solute>([row({ kind: "polymer" })])
    assert.deepEqual(seedOfRows(none, 7), { problem: "no solutes to turn into a template" })
})

test("a converted table gives the rows back exactly at the pH of the table", () => {
    const drafts = Drafts.of<Solute>([customRow(), row({})])
    const made = seedOfRows(drafts, 7)
    assert.ok("seed" in made)
    const w = new TemplateWizard("converted rows", { seed: made.seed, customs: [DYE] })
    assert.match(w.step.type === "prompt" ? w.step.label : "", /^pH of point 2/)
    w.submit("9")
    w.submit("20 0.2")
    w.submit("8 0.1")
    w.submit("")
    assert.ok(w.done && "definition" in w.done, w.problem ?? "")
    const def = w.done.definition
    assert.equal(def.kind, "table")
    const back = rowsFor(def, { pH: 7, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok(!("error" in back))
    assert.deepEqual(
        back.rows.map((r) => [r.arg, r.mM, r.sigmaMM]),
        [
            ["My Dye", 10, 0.1],
            ["chloride", 5, 0.1],
        ],
    )
    assert.deepEqual(back.rows[0]?.custom, SNAPSHOT)
    // at the other point, the typed amounts
    const far = rowsFor(def, { pH: 9, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok(!("error" in far))
    assert.equal(far.rows[0]?.mM, 20)
})

// ---- the question of saving, and the plans of loading and saving

test("the question names what each key does", () => {
    const q = saveAsTemplateQuestion("my buffer", 80)
    assert.match(q.text, /^save "my buffer" as a template\?/)
    assert.deepEqual(
        questionLegend(q).map((i) => [i.label, i.keys]),
        [
            ["template", "⏎"],
            ["plain recipe", "n"],
            ["cancel", "esc"],
        ],
    )
    // a question without a third answer has two keys
    assert.equal(questionLegend({ text: "?", yes: "a", no: "b" }).length, 2)
})

test("a key answers a question: Enter, n, Esc; n needs a third answer", () => {
    assert.equal(answerOf(new KeyInput("return"), true), "yes")
    assert.equal(answerOf(new KeyInput("escape"), true), "no")
    assert.equal(answerOf(new KeyInput("x", true), true), "no")
    assert.equal(answerOf(new KeyInput("n", false, "n"), true), "other")
    assert.equal(answerOf(new KeyInput("n", false, "n"), false), undefined)
    assert.equal(answerOf(new KeyInput("q", false, "q"), true), undefined)
    assert.ok(new KeyInput("n", false, "n").is(keys.otherAnswer))
})

const CONDITIONS: Conditions = { pH: 7, "sigma-pH": 0.1, temperature: 25 }

const SALT: BufferRow = {
    kind: "nonbiological",
    name: "sodium chloride",
    arg: "sodium chloride",
    mM: 100,
    "sigma-mM": 1,
}

const tableDefinition = (): Definition =>
    drive({ customs: [DYE] }, TABLE_ANSWERS)

test("loading a plain recipe is its rows", () => {
    const recipe: Recipe = { name: "plain", solutes: [SALT] }
    assert.deepEqual(recipeLoad(recipe, undefined), { rows: [SALT], template: false })
})

test("loading a template: its rows at the recipe's conditions, else the buffer's", () => {
    const recipe: Recipe = { name: "dye", solutes: [SALT], template: tableDefinition() }
    const own = recipeLoad({ ...recipe, pH: 6, "sigma-pH": 0.1 }, CONDITIONS)
    assert.ok("rows" in own && own.template)
    assert.equal(own.rows.length, 3, "the fixed row, then the table's two")
    assert.equal(own.rows[1]?.mM, 10, "the table at pH 6")
    // no temperature in the recipe: the buffer's
    assert.equal(own.conditions?.temperature, 25)
    const fromBuffer = recipeLoad(recipe, CONDITIONS)
    assert.ok("rows" in fromBuffer)
    assert.equal(fromBuffer.rows[1]?.mM, 11, "the buffer's pH 7: halfway")
    // neither has one: nothing is loaded
    const bare = recipeLoad(recipe, { pH: 7, "sigma-pH": 0.1 })
    assert.match((bare as { message: string }).message, /set the temperature first/)
    assert.ok(fromBuffer.rows.slice(1).every((r) => r.template !== undefined))
})

test("loading a template with no pH anywhere, or outside its table, loads nothing", () => {
    const recipe: Recipe = { name: "dye", solutes: [], template: tableDefinition() }
    assert.match(
        (recipeLoad(recipe, undefined) as { message: string }).message,
        /set the pH first/,
    )
    const far = recipeLoad(recipe, { pH: 12, "sigma-pH": 0.1, temperature: 25 })
    assert.match((far as { message: string }).message, /^dye: pH 12 is outside/)
})

test("a template that cannot be used loads its fixed rows with the problem", () => {
    const broken: Recipe = {
        name: "bad",
        solutes: [SALT],
        template: { kind: "table", points: [] },
    }
    const loaded = recipeLoad(broken, CONDITIONS)
    assert.ok("rows" in loaded)
    assert.deepEqual(loaded.rows, [SALT])
    assert.equal(loaded.template, false)
    assert.match(loaded.hint ?? "", /^template not used: /)
})

test("saving: one linked group may be a template, anything else is a plain recipe", () => {
    const def = tableDefinition()
    const link = linkFor(def)
    const made = rowsFor(def, { pH: 7, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok(!("error" in made))
    const linked = made.rows.map((r) => ({ ...rowOfSpec(r), template: link }))
    const rows = [SALT, ...linked] as BufferRow[]
    assert.equal(offersTemplate(rows), true)
    assert.equal(offersTemplate([SALT]), false)
    const asTemplate = recipeSave(rows, true)
    assert.deepEqual(asTemplate.solutes, [SALT])
    assert.equal(asTemplate.definition?.kind, "table")
    const plain = recipeSave(rows, false)
    assert.equal(plain.definition, undefined)
    assert.equal(plain.solutes.length, 3)
    // asked to make a template of rows with no group: the rows as they are
    assert.deepEqual(recipeSave([SALT], true), { solutes: [SALT] })
})

/** A buffer row of a template's row, as the file holds it. */
function rowOfSpec(r: { name: string; arg: string; mM: number; sigmaMM: number }): object {
    const { name, arg, mM } = r
    return { kind: "nonbiological", name, arg, mM, "sigma-mM": r.sigmaMM }
}
