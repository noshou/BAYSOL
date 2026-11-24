// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of template recipes: the definition inside a recipe (`store/template-recipes.ts`),
// the rows it loads, its file round trip, a definition as the link of a row (`custom` and
// `table` follow the pH in the buffer table), and the wizard that makes definitions
// (`store/template-wizard.ts`). Also the later parts of the templates: custom solutes in
// the wizard and in the rows, editing a definition (the wizard starts from it), turning
// the rows of a buffer into a table template, the three-answer question of saving, and
// what loading and saving a recipe comes to (the pure parts of `screens/menus.tsx`).

import assert from "node:assert/strict"
import { writeFileSync } from "node:fs"
import { test } from "node:test"
import { saveAsTemplateQuestion } from "../src/screens/screen-rules.js"
import {
    type BufferRow,
    type Conditions,
    type Recipe,
    readRecipes,
    recipesFile,
    rowProblem,
    saveRecipe,
} from "../src/store/buffer.js"
import { offered } from "../src/store/buffer-templates.js"
import type { NonbioEntry } from "../src/store/custom.js"
import { Drafts } from "../src/store/lists.js"
import type { Solute } from "../src/store/solutes.js"
import {
    type CustomDefinition,
    checkDefinition,
    type Definition,
    rowsFor,
    type TableDefinition,
} from "../src/store/template-defs.js"
import {
    definitionOf,
    kindOf,
    linkFor,
    offersTemplate,
    recipeLoad,
    recipeSave,
    templateOf,
    templateOfRows,
    templateRows,
    withTemplate,
} from "../src/store/template-recipes.js"
import {
    linkOf,
    recompute,
    seedOfRows,
    soluteFromSpec,
} from "../src/store/template-rows.js"
import { TemplateWizard, type WizardOptions } from "../src/store/template-wizard.js"
import { answerOf, questionLegend } from "../src/ui/input.js"
import { KeyInput, keys } from "../src/ui/interaction.js"
import { tempDir } from "./support/fixtures.js"

const CONDITIONS = { pH: 8, sigmaPH: 0.1, temperatureC: 25 }

const NACL: BufferRow = {
    kind: "nonbiological",
    name: "sodium chloride",
    arg: "sodium chloride",
    mM: 100,
    "sigmaMm": 1,
}

const builtin = (): Definition => ({
    kind: "builtin",
    id: "tris",
    mM: 10,
    sigmaMM: 0.2,
    restMM: 100,
})

const custom = (): CustomDefinition => ({
    kind: "custom",
    name: "My Tris",
    solute: "tris",
    steps: [{ pKa25: 8.072, dpKaDT: -0.0279, zAcid: 1 }],
    titrant: { kind: "acid", ion: "chloride" },
    mM: 10,
    sigmaMM: 0.2,
})

const row = (arg: string, mM: number, sigmaMM: number) => ({ name: arg, arg, mM, sigmaMM })

const table = (): TableDefinition => ({
    kind: "table",
    points: [
        { pH: 6, rows: [row("tris", 10, 1)] },
        { pH: 8, rows: [row("tris", 30, 3)] },
    ],
})

/** A recipe holding the fixed row and a definition. */
const recipe = (template: unknown) => ({
    name: "T",
    solutes: [NACL],
    template,
})

test("a recipe's kind: ordinary, a template of a kind, or invalid", () => {
    assert.equal(kindOf({}), "recipe")
    assert.equal(kindOf(recipe(builtin())), "builtin")
    assert.equal(kindOf(recipe(custom())), "custom")
    assert.equal(kindOf(recipe(table())), "table")
    assert.equal(kindOf(recipe({ kind: "custom", name: "x" })), "invalid")
    assert.equal(kindOf(recipe("nonsense")), "invalid")
    const bad = templateOf(recipe({ kind: "builtin", id: "nothing" }))
    assert.ok(bad && "problem" in bad && bad.problem.includes("nothing"))
})

test("a link and a definition stand for each other", () => {
    for (const def of [builtin(), custom(), table()]) {
        const link = linkOf(linkFor(def))
        assert.ok(link, `${def.kind} link is valid`)
        assert.deepEqual(definitionOf(link), def)
    }
    // a definition that does not check gives no link: the row stays ordinary
    const badCustom = { id: "custom", definition: { ...custom(), mM: -1 } }
    const noPoints = { id: "table", definition: { kind: "table", points: [] } }
    assert.equal(linkOf(badCustom), undefined)
    assert.equal(linkOf(noPoints), undefined)
})

test("a template recipe loads its fixed rows and its definition's linked rows", () => {
    for (const def of [builtin(), custom(), table()]) {
        const made = templateRows(recipe(def), CONDITIONS)
        assert.ok("rows" in made, "error" in made ? made.error : "")
        assert.equal(made.rows[0], NACL)
        assert.ok(made.rows.length >= 2)
        for (const r of made.rows.slice(1)) assert.deepEqual(r.template, linkFor(def))
    }
})

test("a table loads exact at its points, linear between, refused outside", () => {
    const at = (pH: number) => templateRows(recipe(table()), { ...CONDITIONS, pH })
    const mM = (x: ReturnType<typeof at>) =>
        "rows" in x ? (x.rows[1] as { mM: number }).mM : x.error
    assert.equal(mM(at(6)), 10)
    assert.equal(mM(at(7)), 20)
    assert.equal(mM(at(8)), 30)
    assert.match(String(mM(at(9))), /outside/)
})

test("a row both fixed and made by the definition is refused", () => {
    const tris: BufferRow = { ...NACL, name: "tris", arg: "tris" }
    const made = templateRows({ name: "T", solutes: [tris], template: table() }, CONDITIONS)
    assert.ok("error" in made && made.error.includes("tris"))
})

test("saving the buffer as a template: one linked group becomes the definition", () => {
    const rows: BufferRow[] = [NACL, ...(templateRows(recipe(builtin()), CONDITIONS) as {
        rows: BufferRow[]
    }).rows.slice(1)]
    const made = templateOfRows(rows)
    assert.ok(made && "definition" in made)
    assert.deepEqual(made.fixed, [NACL])
    assert.equal(made.definition.kind, "builtin")
    assert.equal(templateOfRows([NACL]), undefined)
    // two groups: no single definition
    const other = { ...rows[1], template: linkFor(custom()) } as BufferRow
    const two = templateOfRows([...rows, other])
    assert.ok(two && "problem" in two)
})

test("a template recipe round trips; a plain save over it drops the definition", () => {
    const root = tempDir()
    const conditions = { pH: 7, "sigmaPh": 0.1, temperature: 4 }
    saveRecipe(root, "T", [NACL], conditions, undefined, custom())
    const [saved] = readRecipes(root)
    assert.deepEqual(saved?.template, custom())
    assert.equal(kindOf(saved as object), "custom")
    saveRecipe(root, "t", [NACL])
    const [plain] = readRecipes(root)
    assert.equal(plain?.template, undefined)
    assert.equal(withTemplate(saved as never).template, undefined)
})

test("a bad definition leaves the file usable and the recipe read-only (invalid)", () => {
    const root = tempDir()
    writeFileSync(
        recipesFile(root),
        JSON.stringify({
            recipes: [
                { name: "good", solutes: [] },
                { name: "bad", solutes: [], template: { kind: "custom", name: "x" } },
            ],
        }),
    )
    const recipes = readRecipes(root)
    assert.deepEqual(recipes.map((r) => kindOf(r)), ["recipe", "invalid"])
    const made = templateRows(recipes[1] as never, CONDITIONS)
    assert.ok("error" in made)
})

/** A table of one group: its draft rows. */
function linked(def: Definition, pH: number): Drafts<Solute> {
    const made = templateRows(recipe(def), { ...CONDITIONS, pH }) as { rows: BufferRow[] }
    const drafts = made.rows.map(
        (r) => ({ ...r, sigmaMM: r.sigmaMm }) as Solute,
    )
    return Drafts.of(drafts)
}

test("rows of a table or custom definition follow the pH of the buffer table", () => {
    const d = linked(table(), 6)
    const up = recompute(d, 7, 0.1, 25)
    assert.ok(up.changed)
    assert.equal((up.drafts.value(1) as Solute).mM, 20)
    assert.deepEqual(up.errors, [])
    // a pH outside the points: the rows stay and the error is told
    const out = recompute(up.drafts, 9, 0.1, 25)
    assert.equal(out.changed, false)
    assert.equal(out.errors.length, 1)
    assert.equal((out.drafts.value(1) as Solute).mM, 20)
    const c = linked(custom(), 7.5)
    const moved = recompute(c, 8.5, 0.1, 25)
    assert.ok(moved.changed)
})

/** Feeds a wizard: texts for prompts, a number for a choice. */
function feed(wizard: TemplateWizard, answers: (string | number)[]): void {
    for (const a of answers) {
        if (wizard.done) break
        if (typeof a === "number") wizard.pick(a)
        else wizard.submit(a)
    }
}

test("the wizard makes a custom definition", () => {
    const w = new TemplateWizard("My Tris")
    // kind custom; solute, 1 step (pKa, slope,
    // charge), acid, chloride, mM, sigma, set at, rest
    feed(w, [1, "tris", "1", "8.072", "-0.0279", "1", 0, 0, "10", "0.2", "", ""])
    assert.ok(w.done && "definition" in w.done, JSON.stringify(w.step))
    const def = w.done.definition as CustomDefinition
    assert.equal(def.kind, "custom")
    assert.equal(def.name, "My Tris")
    assert.deepEqual(def.steps, [{ pKa25: 8.072, dpKaDT: -0.0279, zAcid: 1 }])
    assert.equal(def.mM, 10)
    assert.equal(def.pHSetAt, undefined)
})

test("the wizard asks again with the problem for a bad answer", () => {
    const w = new TemplateWizard("x")
    feed(w, [1, "tris", "5"])
    assert.equal(w.step.type, "prompt")
    assert.match(w.step.problem ?? "", /steps/)
    feed(w, ["1", "20"])
    assert.match(w.step.problem ?? "", /pKa/)
})

test("the wizard makes a table definition", () => {
    const w = new TemplateWizard("x")
    feed(w, [2, "6", "tris 10 1", "", "8", "30 3", "", ])
    assert.ok(w.done && "definition" in w.done, JSON.stringify(w.step))
    const def = w.done.definition as TableDefinition
    assert.deepEqual(def.points.map((p) => p.pH), [6, 8])
    assert.deepEqual(def.points[1]?.rows[0], row("tris", 30, 3))
})

test("the wizard makes a builtin definition and can be cancelled", () => {
    const w = new TemplateWizard("x")
    const at = offered().findIndex((t) => t.id === "tris")
    feed(w, [0, at, "10", "0.2"])
    // the titrant dropdown is asked only for a template with a choice; then set at, rest
    while (!w.done) {
        if (w.step.type === "choice") w.pick(0)
        else w.submit("")
    }
    assert.ok("definition" in w.done)
    assert.equal((w.done.definition as { id: string }).id, "tris")
    const c = new TemplateWizard("x")
    c.cancel()
    assert.deepEqual(c.done, { cancelled: true })
})

test("a table the wizard cannot work out is refused with the problem", () => {
    const w = new TemplateWizard("x")
    // an unknown solute is refused at once as the row is typed
    feed(w, [2, "6", "unobtainium 1 1"])
    assert.match(w.step.problem ?? "", /not a solute/)
})

// ========================================================================================
// Later parts: custom solutes, editing, table templates, saving and loading a recipe
// ========================================================================================

const DYE: NonbioEntry = {
    kind: "nonbiological",
    name: "My Dye",
    formula: "",
    z: 40,
    pmv: 300,
    sigma: null,
}

const SNAPSHOT = { z: 40, pmv: 300, "sigmaPmv": null }

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

const soluteRow = (patch: Partial<Solute>): Solute => ({
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
        "sigmaPmv": null,
        mM: 10,
        sigmaMM: 0.1,
    }) as Solute

test("the rows that can follow the pH are the seed; the others stay", () => {
    const polymer = soluteRow({ kind: "polymer", name: "PEG", arg: "PEG" })
    const template = linkFor({ kind: "builtin", id: "tris", mM: 10 })
    const linked = soluteRow({ name: "sodium(1+)", arg: "sodium(1+)", template })
    const rows = [soluteRow({}), polymer, customRow(), linked, soluteRow({ arg: "z" })]
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
    const incomplete = Drafts.of<Solute>([soluteRow({ mM: null })])
    assert.deepEqual(seedOfRows(incomplete, 7), {
        problem: "row 1: the amount is not complete",
    })
    const none = Drafts.of<Solute>([soluteRow({ kind: "polymer" })])
    assert.deepEqual(seedOfRows(none, 7), { problem: "no solutes to turn into a template" })
})

test("a converted table gives the rows back exactly at the pH of the table", () => {
    const drafts = Drafts.of<Solute>([customRow(), soluteRow({})])
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
            ["plain recipe", "shift+x"],
            ["cancel", "esc"],
        ],
    )
    // a question without a third answer has two keys
    assert.equal(questionLegend({ text: "?", yes: "a", no: "b" }).length, 2)
})

test("a key answers a question: Enter, shift+x, Esc; shift+x needs a third answer", () => {
    assert.equal(answerOf(new KeyInput("return"), true), "yes")
    assert.equal(answerOf(new KeyInput("escape"), true), "no")
    assert.equal(answerOf(new KeyInput("x", true), true), "no")
    const capX = new KeyInput("x", false, "X", true)
    assert.equal(answerOf(capX, true), "other")
    assert.equal(answerOf(capX, false), undefined)
    // the plain letter is no answer (only Ctrl or Shift keys act, besides navigation)
    assert.equal(answerOf(new KeyInput("x", false, "x"), true), undefined)
    assert.equal(answerOf(new KeyInput("q", false, "q"), true), undefined)
    assert.ok(capX.is(keys.otherAnswer))
})

const EXTRA_CONDITIONS: Conditions = { pH: 7, "sigmaPh": 0.1, temperature: 25 }

const SALT: BufferRow = {
    kind: "nonbiological",
    name: "sodium chloride",
    arg: "sodium chloride",
    mM: 100,
    "sigmaMm": 1,
}

const tableDefinition = (): Definition =>
    drive({ customs: [DYE] }, TABLE_ANSWERS)

test("loading a plain recipe is its rows", () => {
    const recipe: Recipe = { name: "plain", solutes: [SALT] }
    assert.deepEqual(recipeLoad(recipe, undefined), { rows: [SALT], template: false })
})

test("loading a template: its rows at the recipe's conditions, else the buffer's", () => {
    const recipe: Recipe = { name: "dye", solutes: [SALT], template: tableDefinition() }
    const own = recipeLoad({ ...recipe, pH: 6, "sigmaPh": 0.1 }, EXTRA_CONDITIONS)
    assert.ok("rows" in own && own.template)
    assert.equal(own.rows.length, 3, "the fixed row, then the table's two")
    assert.equal(own.rows[1]?.mM, 10, "the table at pH 6")
    // no temperature in the recipe: the buffer's
    assert.equal(own.conditions?.temperature, 25)
    const fromBuffer = recipeLoad(recipe, EXTRA_CONDITIONS)
    assert.ok("rows" in fromBuffer)
    assert.equal(fromBuffer.rows[1]?.mM, 11, "the buffer's pH 7: halfway")
    // neither has one: nothing is loaded
    const bare = recipeLoad(recipe, { pH: 7, "sigmaPh": 0.1 })
    assert.match((bare as { message: string }).message, /set the temperature first/)
    assert.ok(fromBuffer.rows.slice(1).every((r) => r.template !== undefined))
})

test("loading a template with no pH anywhere, or outside its table, loads nothing", () => {
    const recipe: Recipe = { name: "dye", solutes: [], template: tableDefinition() }
    assert.match(
        (recipeLoad(recipe, undefined) as { message: string }).message,
        /set the pH first/,
    )
    const far = recipeLoad(recipe, { pH: 12, "sigmaPh": 0.1, temperature: 25 })
    assert.match((far as { message: string }).message, /^dye: pH 12 is outside/)
})

test("a template that cannot be used loads its fixed rows with the problem", () => {
    const broken: Recipe = {
        name: "bad",
        solutes: [SALT],
        template: { kind: "table", points: [] },
    }
    const loaded = recipeLoad(broken, EXTRA_CONDITIONS)
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
    return { kind: "nonbiological", name, arg, mM, "sigmaMm": r.sigmaMM }
}
