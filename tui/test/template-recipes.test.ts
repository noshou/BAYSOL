// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of template recipes: the definition inside a recipe (`store/template-recipes.ts`),
// the rows it loads, its file round trip, a definition as the link of a row (`custom` and
// `table` follow the pH in the buffer table), and the wizard that makes definitions
// (`store/template-wizard.ts`).

import assert from "node:assert/strict"
import { writeFileSync } from "node:fs"
import { test } from "node:test"
import {
    type BufferRow,
    readRecipes,
    recipesFile,
    saveRecipe,
} from "../src/store/buffer.js"
import { offered } from "../src/store/buffer-templates.js"
import { Drafts } from "../src/store/lists.js"
import type { Solute } from "../src/store/solutes.js"
import type {
    CustomDefinition,
    Definition,
    TableDefinition,
} from "../src/store/template-defs.js"
import { linkOf } from "../src/store/template-link.js"
import {
    definitionOf,
    kindOf,
    linkFor,
    templateOf,
    templateOfRows,
    templateRows,
    withTemplate,
} from "../src/store/template-recipes.js"
import { recompute } from "../src/store/template-sync.js"
import { TemplateWizard } from "../src/store/template-wizard.js"
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
        (r) => ({ ...r, sigmaMM: r.sigmaMm }) as unknown as Solute,
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
