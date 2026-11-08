// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/buffer.ts: the buffer file and the recipes file.

import assert from "node:assert/strict"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { test } from "node:test"
import { ChangedOnDiskError, UnusableFileError } from "../src/core/file-system.js"
import {
    type BufferRow,
    bufferFile,
    conditionLimits,
    conditionsOf,
    conditionsProblem,
    indexOfRecipe,
    kinds,
    kindsSummary,
    listRecipes,
    MAX_NAME,
    type Recipe,
    readConcUnit,
    readConditions,
    readRecipes,
    readSolutes,
    recipeConditions,
    recipeNameProblem,
    recipeSolutes,
    recipesFile,
    removeRecipe,
    renameProblem,
    renameRecipe,
    resetBuffer,
    rowProblem,
    saveRecipe,
    withConditions,
    writeConcUnit,
    writeRecipes,
    writeSolutes,
} from "../src/store/buffer.js"
import { MAX_ROWS } from "../src/store/lists.js"
import { fixture, tempDir as tempRoot } from "./support/fixtures.js"

/** The fixture the Julia loader is tested against too, `custom-polymer` rows included. */
const fixtureMap = fixture("buffer/buffer.json")
const fixtureRows = fixtureMap.solutes as BufferRow[]
const fixtureText = `${JSON.stringify(fixtureMap, null, 2)}\n`

/** A copy of a fixture row, to change and check. */
const row = (kind: string, n = 0): Record<string, unknown> =>
    structuredClone(fixtureRows.filter((r) => r.kind === kind)[n]) as Record<
        string,
        unknown
    >

/** A project folder whose buffer.json holds `text`. */
function projectWith(text: string): string {
    const dir = tempRoot()
    writeFileSync(bufferFile(dir), text)
    return dir
}

test("every row of the shared fixture is valid, one of each kind at least", () => {
    for (const r of fixtureRows) assert.equal(rowProblem(r), undefined, JSON.stringify(r))
    for (const kind of kinds)
        assert.ok(
            fixtureRows.some((r) => r.kind === kind),
            kind,
        )
})

test("a custom-solutes entry is no buffer row, but its snapshot is", () => {
    type Entry = Record<string, unknown> & { name: string; units: unknown[] }
    const file = fixture("buffer/custom-solutes.json") as { solutes: Entry[] }
    const entries = file.solutes
    for (const entry of entries)
        assert.notEqual(rowProblem({ ...entry, mM: 1, "sigma-mM": 0 }), undefined)
    for (const e of entries) {
        const base = { name: e.name, custom: e.name, mM: 1, "sigma-mM": 0 }
        const nonbio = () => ({
            kind: "custom-nonbio",
            ...base,
            z: e.z,
            pmv: e.pmv,
            "sigma-pmv": e.sigma,
        })
        const polymer = () => ({
            kind: "custom-polymer",
            ...base,
            units: e.units,
            counts: e.units.map(() => 3),
            "z-ends": e["z-ends"],
            "pmv-ends": e["pmv-ends"],
            "sigma-ends": e["sigma-ends"],
        })
        const snapshot = e.kind === "nonbiological" ? nonbio() : polymer()
        assert.equal(rowProblem(snapshot), undefined, e.name)
    }
})

test("the common keys", () => {
    assert.equal(rowProblem("x"), "a row is not a map")
    assert.equal(rowProblem([]), "a row is not a map")
    assert.equal(rowProblem(null), "a row is not a map")
    assert.equal(rowProblem({ ...row("dna"), kind: "lipid" }), "unknown kind")
    assert.equal(rowProblem({ ...row("dna"), kind: undefined }), "unknown kind")
    for (const bad of [0, -1, Number.NaN, "5", null, undefined, true])
        assert.equal(
            rowProblem({ ...row("dna"), mM: bad }),
            "mM must be above 0",
            String(bad),
        )
    for (const bad of [-0.1, Number.NaN, "1", null, undefined, false])
        assert.equal(
            rowProblem({ ...row("dna"), "sigma-mM": bad }),
            "sigma-mM must be 0 or more",
            String(bad),
        )
    assert.equal(rowProblem({ ...row("dna"), "sigma-mM": 0 }), undefined)
    // the name is only a label
    assert.equal(rowProblem({ ...row("dna"), name: "" }), undefined)
})

test("the argument of a row that has one", () => {
    for (const kind of ["nonbiological", "polymer", "dna", "rna", "protein"])
        for (const bad of [undefined, null, "", "  ", 3]) {
            assert.equal(
                rowProblem({ ...row(kind), arg: bad }),
                "arg must be a name",
                kind,
            )
        }
    const { arg: _arg, ...without } = row("dna")
    assert.equal(rowProblem(without), "arg must be a name")
    // provenance is optional
    const { source: _s, record: _r, ...plain } = row("dna")
    assert.equal(rowProblem(plain), undefined)
})

test("custom non-biological rows", () => {
    const base = row("custom-nonbio")
    assert.equal(rowProblem({ ...base, custom: " " }), "custom must be a name")
    assert.equal(rowProblem({ ...base, z: 1.5 }), "z must be an integer")
    assert.equal(rowProblem({ ...base, z: "102" }), "z must be an integer")
    assert.equal(rowProblem({ ...base, pmv: "x" }), "pmv must be a number")
    assert.equal(
        rowProblem({ ...base, "sigma-pmv": "x" }),
        "sigma-pmv must be a number or null",
    )
    // the key must be there, null or a number
    const { "sigma-pmv": _gone, ...missing } = base
    assert.equal(rowProblem(missing), "sigma-pmv must be a number or null")
    assert.equal(rowProblem({ ...base, "sigma-pmv": null }), undefined)
    // no :arg is needed
    assert.equal("arg" in base, false)
})

test("custom polymer rows", () => {
    const base = row("custom-polymer", 1)
    const units = base.units as Record<string, unknown>[]
    assert.equal(rowProblem({ ...base, custom: "" }), "custom must be a name")
    assert.equal(rowProblem({ ...base, units: [] }), "units needs 1 to 4")
    assert.equal(
        rowProblem({ ...base, units: [...units, units[0]] }),
        "units needs 1 to 4",
    )
    assert.equal(rowProblem({ ...base, units: "x" }), "units needs 1 to 4")
    assert.equal(
        rowProblem({ ...base, units: ["x", ...units.slice(1)] }),
        "a unit is not a map",
    )
    assert.equal(
        rowProblem({ ...base, units: [{ ...units[0], z: 1.5 }, ...units.slice(1)] }),
        "unit z must be an integer",
    )
    assert.equal(
        rowProblem({ ...base, units: [{ ...units[0], slope: null }, ...units.slice(1)] }),
        "unit slope must be a number",
    )
    const { sigma: _s, ...noSigma } = units[0] as Record<string, unknown>
    assert.equal(
        rowProblem({ ...base, units: [noSigma, ...units.slice(1)] }),
        "unit sigma must be a number or null",
    )
    assert.equal(rowProblem({ ...base, counts: [1, 2, 3] }), "counts needs one per unit")
    assert.equal(rowProblem({ ...base, counts: [1, 2, 3, "x"] }), "counts must be numbers")
    assert.equal(rowProblem({ ...base, counts: 3 }), "counts must be numbers")
    assert.equal(rowProblem({ ...base, "z-ends": 0.5 }), "z-ends must be an integer")
    assert.equal(rowProblem({ ...base, "pmv-ends": "x" }), "pmv-ends must be a number")
    assert.equal(
        rowProblem({ ...base, "sigma-ends": "x" }),
        "sigma-ends must be a number or null",
    )
})

test("a missing or empty file is a buffer with no solutes", () => {
    const dir = tempRoot()
    assert.deepEqual(readSolutes(dir), [])
    for (const text of ["", "  \n", "{}", '{"solutes": []}'])
        assert.deepEqual(readSolutes(projectWith(text)), [], JSON.stringify(text))
})

test("a file that cannot be used is told and never written over", () => {
    const unusable = [
        "[1 2 3]",
        '"a string"',
        "42",
        "{ truncated",
        "// a comment",
        '{"solutes": null}',
        '{"solutes": {}}',
        '{"solutes": [1]}',
        '{"solutes": [{"kind": "dna", "name": "x", "arg": "AC", "mM": 0, "sigma-mM": 0}]}',
    ]
    for (const text of unusable) {
        const dir = projectWith(text)
        assert.throws(() => readSolutes(dir), UnusableFileError, text)
        assert.throws(() => writeSolutes(dir, []), UnusableFileError, text)
        assert.equal(readFileSync(bufferFile(dir), "utf-8"), text)
    }
    // more than 999 solutes
    const rows = Array.from({ length: MAX_ROWS + 1 }, () => fixtureRows[0] as BufferRow)
    assert.throws(() => writeSolutes(tempRoot(), rows), /too many/)
    const one =
        '{"kind": "polymer", "name": "p", "arg": "PEG 3350", "mM": 1, "sigma-mM": 0}'
    const text = `{"solutes": [${rows.map(() => one).join(",")}]}`
    assert.throws(() => readSolutes(projectWith(text)), UnusableFileError)
    const full = rows.slice(1).map(() => fixtureRows[0] as BufferRow)
    const dir = tempRoot()
    writeSolutes(dir, full)
    assert.equal(readSolutes(dir).length, MAX_ROWS)
})

test("the fixture is read, and what is written reads back the same", () => {
    const dir = projectWith(fixtureText)
    const solutes = readSolutes(dir)
    assert.deepEqual(solutes, fixtureRows)
    const other = tempRoot()
    writeSolutes(other, solutes)
    assert.deepEqual(readSolutes(other), solutes)
    // the kind goes out as a plain string, two-space indented, ending in a newline
    const text = readFileSync(bufferFile(other), "utf-8")
    assert.match(text, /"kind": "custom-nonbio"/)
    assert.ok(text.endsWith("}\n"))
})

test("writing keeps the other keys of the file and refuses a bad row", () => {
    const dir = projectWith('{"solutes": [], "ph": 7.4}')
    const rows = [fixtureRows[0] as BufferRow]
    writeSolutes(dir, rows)
    const written = JSON.parse(readFileSync(bufferFile(dir), "utf-8")) as Record<
        string,
        unknown
    >
    assert.equal(written.ph, 7.4)
    assert.deepEqual(written.solutes, rows)
    const before = readFileSync(bufferFile(dir), "utf-8")
    assert.throws(
        () => writeSolutes(dir, [{ ...rows[0], mM: 0 } as BufferRow]),
        /not a valid buffer row: mM must be above 0/,
    )
    assert.equal(readFileSync(bufferFile(dir), "utf-8"), before)
})

test("a reset keeps the unusable file as .corrupt", () => {
    const dir = projectWith("[1, 2, 3]")
    const kept = resetBuffer(dir)
    assert.equal(kept, `${bufferFile(dir)}.corrupt`)
    assert.equal(readFileSync(`${bufferFile(dir)}.corrupt`, "utf-8"), "[1, 2, 3]")
    assert.equal(existsSync(bufferFile(dir)), false)
    assert.deepEqual(readSolutes(dir), [])
    assert.equal(resetBuffer(dir), undefined) // nothing to rename now
})

test("the shared fixture has valid conditions; the limits come from the asset file", () => {
    const map = fixture("buffer/buffer.json")
    assert.equal(conditionsProblem(map), undefined)
    assert.deepEqual(conditionsOf(map), { pH: 7.4, "sigma-pH": 0.1 })
    const { pH, sigmaPh } = conditionLimits()
    assert.deepEqual([pH.min, pH.max, sigmaPh.min, sigmaPh.default], [0, 14, 0, 0.1])
})

test("conditions: both or neither, numbers within the limits", () => {
    assert.equal(conditionsProblem({}), undefined, "none is a buffer that cannot run")
    assert.equal(conditionsProblem({ pH: 0, "sigma-pH": 0 }), undefined)
    assert.equal(conditionsProblem({ pH: 14, "sigma-pH": 14 }), undefined)
    const bad: Record<string, unknown>[] = [
        { pH: 7 },
        { "sigma-pH": 0.1 },
        { pH: -0.1, "sigma-pH": 0.1 },
        { pH: 14.1, "sigma-pH": 0.1 },
        { pH: 7, "sigma-pH": -1 },
        { pH: 7, "sigma-pH": 15 },
        { pH: "7", "sigma-pH": 0.1 },
        { pH: 7, "sigma-pH": null },
        { pH: Number.NaN, "sigma-pH": 0.1 },
        { pH: true, "sigma-pH": 0.1 },
    ]
    for (const m of bad) assert.notEqual(conditionsProblem(m), undefined, JSON.stringify(m))
    assert.equal(conditionsOf({ pH: 7 }), undefined)
    assert.equal(conditionsOf({}), undefined)
})

test("conditions are written with the solutes, read back, and kept otherwise", () => {
    const dir = tempRoot()
    assert.equal(readConditions(dir), undefined)
    writeSolutes(dir, fixtureRows, { pH: 6.5, "sigma-pH": 0.2 })
    assert.deepEqual(readConditions(dir), { pH: 6.5, "sigma-pH": 0.2 })
    // a later write without conditions keeps the file's own
    writeSolutes(dir, fixtureRows.slice(0, 2))
    assert.deepEqual(readConditions(dir), { pH: 6.5, "sigma-pH": 0.2 })
    assert.equal(readSolutes(dir).length, 2)
    const saved = JSON.parse(readFileSync(bufferFile(dir), "utf-8"))
    assert.deepEqual(Object.keys(saved), ["solutes", "pH", "sigma-pH"])
    // a value that breaks the rules is refused before anything is written
    assert.throws(
        () => writeSolutes(dir, [], { pH: 15, "sigma-pH": 0.1 }),
        UnusableFileError,
    )
    assert.deepEqual(readConditions(dir), { pH: 6.5, "sigma-pH": 0.2 })
})

test("a file with a bad pH is unusable and never written over", () => {
    const extras = ['"pH": 7', '"pH": "x", "sigma-pH": 1', '"pH": 20, "sigma-pH": 1']
    for (const extra of extras) {
        const text = `{"solutes": [], ${extra}}`
        const dir = projectWith(text)
        assert.throws(() => readSolutes(dir), UnusableFileError, text)
        assert.throws(() => readConditions(dir), UnusableFileError, text)
        assert.throws(() => writeSolutes(dir, []), UnusableFileError, text)
        assert.equal(readFileSync(bufferFile(dir), "utf-8"), text)
    }
})

test("the concentration unit is kept in the file, per buffer", () => {
    const dir = projectWith(fixtureText)
    assert.equal(readConcUnit(dir), "mM")
    readSolutes(dir, { track: true })
    writeConcUnit(dir, "µM")
    assert.equal(readConcUnit(dir), "µM")
    // rows and the other keys stay, and a save after the switch is not refused
    assert.deepEqual(readSolutes(dir), fixtureRows)
    writeSolutes(dir, fixtureRows as BufferRow[], undefined, "M")
    assert.equal(readConcUnit(dir), "M")
    // a save without a unit leaves the file's own
    writeSolutes(dir, fixtureRows as BufferRow[])
    assert.equal(readConcUnit(dir), "M")
    // another buffer is its own
    assert.equal(readConcUnit(projectWith('{"solutes": []}')), "mM")
});

test("a bad unit opens in mM; a switch after a foreign save writes nothing", () => {
    for (const bad of ['"L"', "3", "null"])
        assert.equal(readConcUnit(projectWith(`{"conc-unit": ${bad}}`)), "mM")
    const none = tempRoot()
    writeConcUnit(none, "M")
    assert.equal(existsSync(bufferFile(none)), false)
    const dir = projectWith('{"solutes": []}')
    readSolutes(dir, { track: true })
    writeFileSync(bufferFile(dir), '{"solutes": [], "pH": 7, "sigma-pH": 0.1}\n')
    writeConcUnit(dir, "M")
    assert.equal(readConcUnit(dir), "mM")
    assert.throws(() => writeSolutes(dir, []), /changed on disk/)
})

// ========================================================================================
// Recipes (`recipes.json`)
// ========================================================================================

/** The shared recipes fixture, `custom-polymer` rows included. */
const recipesMap = fixture("buffer/recipes.json") as {
    recipes: { name: string; solutes: BufferRow[]; pH?: number; "sigma-pH"?: number }[]
}
const recipesText = `${JSON.stringify(recipesMap, null, 2)}\n`
const recipeRows = fixtureRows
const recipeRow = recipeRows[0] as BufferRow
const sec = { pH: 6.8, "sigma-pH": 0.05 }

const unusableRecipes = (f: () => unknown) =>
    assert.throws(f, (e) => e instanceof UnusableFileError && e.kind === "recipes")

test("every row of the shared recipes is valid", () => {
    for (const r of recipesMap.recipes)
        for (const row of r.solutes)
            assert.equal(rowProblem(row), undefined, JSON.stringify(row))
})

test("the recipes fixture round trips, its pH and σ with it", () => {
    const root = tempRoot()
    writeFileSync(recipesFile(root), recipesText)
    const recipes = readRecipes(root)
    assert.deepEqual(
        recipes.map((r) => r.name),
        ["SEC buffer", "Everything", "Customs", "empty"],
    )
    assert.deepEqual(recipes[0]?.solutes.length, 3)
    assert.deepEqual(recipeConditions(recipes[0] as Recipe), sec)
    assert.deepEqual(recipeConditions(recipes[1] as Recipe), {
        pH: 7.4,
        "sigma-pH": 0,
    })
    assert.equal(recipeConditions(recipes[2] as Recipe), undefined, "none given")
    writeRecipes(root, recipes)
    assert.deepEqual(readRecipes(root), recipes)
    assert.equal(existsSync(`${recipesFile(root)}.tmp`), false)
    assert.deepEqual(
        Object.keys(JSON.parse(readFileSync(recipesFile(root), "utf-8")).recipes[0]),
        ["name", "solutes", "pH", "sigma-pH"],
        "the keys keep the fixture's order",
    )
    assert.equal(recipeSolutes(root, "sec BUFFER")?.length, 3, "found without case")
    assert.equal(recipeSolutes(root, "nothing"), undefined)
})

test("no file, no recipes", () => {
    const root = tempRoot()
    assert.deepEqual(readRecipes(root), [])
    assert.equal(recipeSolutes(root, "x"), undefined)
    writeFileSync(recipesFile(root), "")
    assert.deepEqual(readRecipes(root), [])
})

test("save adds, replaces and keeps", () => {
    const root = tempRoot()
    writeFileSync(
        recipesFile(root),
        '{"recipes": [{"name": "A", "solutes": [], "note": 1}], "other": [1, 2]}',
    )
    saveRecipe(root, "B", [recipeRow])
    assert.deepEqual(
        readRecipes(root).map((r) => r.name),
        ["A", "B"],
    )
    saveRecipe(root, " a ", [recipeRow, recipeRow])
    const recipes = readRecipes(root)
    assert.deepEqual(
        recipes.map((r) => r.name),
        ["a", "B"],
        "replaced in place, under the new spelling",
    )
    assert.equal(recipes[0]?.solutes.length, 2)
    assert.equal(recipes[0]?.note, 1, "other keys of a recipe are kept")
    const { recipes: _r, ...others } = JSON.parse(
        readFileSync(recipesFile(root), "utf-8"),
    ) as Record<string, unknown>
    assert.deepEqual(others, { other: [1, 2] }, "other keys of the map are kept")
})

test("a save stores the buffer's pH and σ; a buffer without leaves none", () => {
    const root = tempRoot()
    saveRecipe(root, "SEC", [recipeRow], sec)
    assert.deepEqual(recipeConditions(readRecipes(root)[0] as Recipe), sec)
    assert.deepEqual(readRecipes(root)[0]?.pH, 6.8)
    assert.deepEqual(listRecipes(root)[0]?.conditions, sec)
    // replacing with a buffer that has other conditions
    saveRecipe(root, "sec", [recipeRow], { pH: 7.2, "sigma-pH": 0.1 })
    assert.deepEqual(recipeConditions(readRecipes(root)[0] as Recipe), {
        pH: 7.2,
        "sigma-pH": 0.1,
    })
    // replacing with a buffer without: the old pH does not stay
    saveRecipe(root, "SEC", [recipeRow])
    const recipe = readRecipes(root)[0] as Recipe
    assert.equal(recipeConditions(recipe), undefined)
    assert.ok(!("pH" in recipe) && !("sigma-pH" in recipe), "no stale pH")
    assert.equal(readRecipes(root).length, 1)
})

test("a recipe's conditions are both or neither, within the limits", () => {
    const { pH, sigmaPh } = conditionLimits()
    const base = { name: "A", solutes: [] as BufferRow[] }
    for (const bad of [
        { pH: 7 },
        { "sigma-pH": 0.1 },
        { pH: pH.max + 1, "sigma-pH": 0.1 },
        { pH: pH.min - 1, "sigma-pH": 0.1 },
        { pH: 7, "sigma-pH": -0.1 },
        { pH: 7, "sigma-pH": sigmaPh.max + 1 },
        { pH: "7", "sigma-pH": 0.1 },
    ]) {
        const root = tempRoot()
        const text = JSON.stringify({ recipes: [{ ...base, ...bad }] })
        writeFileSync(recipesFile(root), text)
        unusableRecipes(() => readRecipes(root))
        unusableRecipes(() => saveRecipe(root, "B", [recipeRow]))
        assert.equal(readFileSync(recipesFile(root), "utf-8"), text, "never overwritten")
        unusableRecipes(() => writeRecipes(tempRoot(), [{ ...base, ...bad } as Recipe]))
    }
    const root = tempRoot()
    writeRecipes(root, [{ ...base, pH: 7, "sigma-pH": 0 }])
    assert.deepEqual(recipeConditions(readRecipes(root)[0] as Recipe), {
        pH: 7,
        "sigma-pH": 0,
    })
})

test("withConditions sets and takes off the pH and σ, keeping the rest", () => {
    const recipe: Recipe = { name: "A", solutes: [], note: 1 }
    const set = withConditions(recipe, sec)
    assert.deepEqual(recipeConditions(set), sec)
    assert.equal(set.note, 1)
    const off = withConditions(set, undefined)
    assert.deepEqual(off, recipe)
    assert.equal(recipeConditions(withConditions(recipe, undefined)), undefined)
})

test("unusable recipe files are told and never overwritten", () => {
    for (const text of [
        "[1, 2]",
        '{"recipes": 3}',
        '{"recipes": [1]}',
        '{"recipes": [{"name": "", "solutes": []}]}',
        '{"recipes": [{"name": "A"}]}',
        '{"recipes": [{"name": "A", "solutes": [{"kind": "x"}]}]}',
        '{"recipes": [{"name": "A", "solutes": []}, {"name": "a", "solutes": []}]}',
        '{"recipes": [{"name": 4, "solutes": []}]}',
        '{"recipes": [{"solutes": []}]}',
        '{"recipes": (',
        '{"recipes": [{"name": "A", "solutes": {}}]}',
        "; a comment",
    ]) {
        const root = tempRoot()
        writeFileSync(recipesFile(root), text)
        unusableRecipes(() => readRecipes(root))
        unusableRecipes(() => saveRecipe(root, "B", [recipeRow]))
        unusableRecipes(() => writeRecipes(root, []))
        assert.equal(readFileSync(recipesFile(root), "utf-8"), text, "never overwritten")
    }
})

test("invalid recipe writes are refused", () => {
    const root = tempRoot()
    unusableRecipes(() =>
        writeRecipes(root, [{ name: "A", solutes: [{ kind: "x" } as never] }]),
    )
    unusableRecipes(() => writeRecipes(root, [{ name: " ", solutes: [] }]))
    unusableRecipes(() =>
        writeRecipes(root, [
            { name: "A", solutes: [] },
            { name: "A ", solutes: [] },
        ]),
    )
    assert.equal(existsSync(recipesFile(root)), false, "nothing was made")
})

test("the recipe caps", () => {
    const root = tempRoot()
    const many = Array.from({ length: MAX_ROWS }, (_, i) => ({
        name: `r${i}`,
        solutes: [],
    }))
    writeRecipes(root, many)
    assert.equal(readRecipes(root).length, MAX_ROWS)
    unusableRecipes(() => saveRecipe(root, "one more", [recipeRow]))
    saveRecipe(root, "R5", [recipeRow])
    assert.equal(readRecipes(root).length, MAX_ROWS, "a replace is fine at the cap")
    writeRecipes(root, [])
    const full = Array.from({ length: MAX_ROWS }, () => recipeRow)
    saveRecipe(root, "full", full)
    assert.equal(recipeSolutes(root, "full")?.length, MAX_ROWS)
    unusableRecipes(() => saveRecipe(root, "full", [...full, recipeRow]))
    const thousand = Array.from(
        { length: MAX_ROWS + 1 },
        (_, i) => `{"name": "r${i}", "solutes": []}`,
    )
    writeFileSync(recipesFile(root), `{"recipes": [${thousand.join(",")}]}`)
    unusableRecipes(() => readRecipes(root))
})

test("recipe names", () => {
    assert.equal(recipeNameProblem("SEC buffer"), undefined)
    assert.equal(recipeNameProblem("x".repeat(MAX_NAME)), undefined)
    assert.equal(recipeNameProblem("x".repeat(MAX_NAME + 1)), "40 characters at most")
    assert.equal(recipeNameProblem("   "), "type a name first!")
    assert.equal(recipeNameProblem(""), "type a name first!")
    assert.equal(recipeNameProblem("a\tb"), "no control characters")
    assert.equal(recipeNameProblem("ångström ± 😀"), undefined)
    const recipes = [{ name: "Alpha" }, { name: "beta" }]
    assert.equal(indexOfRecipe(recipes, " ALPHA "), 0)
    assert.equal(indexOfRecipe(recipes, "Beta"), 1)
    assert.equal(indexOfRecipe(recipes, "gamma"), undefined)
})

test("a rename is unique among the others, a case-only change is allowed", () => {
    const recipes = [{ name: "Alpha" }, { name: "beta" }]
    assert.equal(renameProblem(recipes, "ALPHA", 0), undefined, "case only")
    assert.equal(renameProblem(recipes, "Alpha", 0), undefined, "the same name")
    assert.equal(renameProblem(recipes, " Beta ", 0), "name in use")
    assert.equal(renameProblem(recipes, "Beta"), "name in use", "a new recipe")
    assert.equal(renameProblem(recipes, "gamma", 0), undefined)
    assert.equal(renameProblem(recipes, "  ", 0), "type a name first!")
})

test("list, rename and delete recipes", () => {
    const root = tempRoot()
    writeFileSync(recipesFile(root), recipesText)
    assert.deepEqual(listRecipes(root)[0], {
        name: "SEC buffer",
        solutes: 3,
        kinds: "1 solute 2 polymer",
        conditions: sec,
    })
    assert.equal(listRecipes(root)[2]?.conditions, undefined)
    assert.equal(renameRecipe(root, "sec buffer", "SEC BUFFER"), undefined, "case only")
    assert.equal(readRecipes(root)[0]?.name, "SEC BUFFER")
    assert.deepEqual(
        recipeConditions(readRecipes(root)[0] as Recipe),
        sec,
        "a rename keeps the pH",
    )
    assert.equal(renameRecipe(root, "SEC BUFFER", "customs"), "name in use")
    assert.equal(renameRecipe(root, "nope", "x"), "no such recipe")
    assert.equal(renameRecipe(root, "empty", "none"), undefined)
    assert.equal(removeRecipe(root, "NONE"), true)
    assert.equal(removeRecipe(root, "none"), false)
    assert.deepEqual(
        readRecipes(root).map((r) => r.name),
        ["SEC BUFFER", "Everything", "Customs"],
    )
})

test("kinds of a recipe's rows", () => {
    assert.equal(kindsSummary([]), "none")
    const k = (kind: string, n = 1) => Array.from({ length: n }, () => ({ kind }))
    assert.equal(
        kindsSummary([
            ...k("nonbiological", 3),
            ...k("polymer"),
            ...k("custom-nonbio"),
            ...k("custom-polymer"),
            ...k("dna"),
            ...k("rna"),
            ...k("protein"),
            ...k("dna"),
        ]),
        "3 solute 1 polymer 2 custom 4 seq",
    )
    assert.equal(kindsSummary(k("nonbiological")), "1 solute")
    assert.ok(kindsSummary(recipeRows).includes("seq"))
})

test("removing one recipe keeps the others and refuses after another copy saved", () => {
    const root = tempRoot()
    writeFileSync(recipesFile(root), recipesText)
    const names = () => readRecipes(root).map((r) => r.name)
    const all = names()
    readRecipes(root, { track: true })
    assert.equal(removeRecipe(root, all[1] as string, { guarded: true }), true)
    assert.deepEqual(
        names(),
        all.filter((_, i) => i !== 1),
    )
    assert.equal(removeRecipe(root, "nope"), false)
    // another copy saves: this one's view is stale and the removal refuses
    const rest = names()
    writeFileSync(recipesFile(root), `${recipesText} `)
    const stale = () => removeRecipe(root, rest[0] as string, { guarded: true })
    assert.throws(stale, ChangedOnDiskError)
    assert.equal(names().length, all.length, "nothing was written")
})
