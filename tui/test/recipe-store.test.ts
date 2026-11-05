// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { UnusableFileError } from "../src/core/files.js"
import type { BufferRow } from "../src/store/buffer.js"
import {
    deleteRecipe,
    indexOfName,
    kindsSummary,
    listRecipes,
    nameProblem,
    readRecipes,
    recipeSolutes,
    recipesFile,
    renameProblem,
    renameRecipe,
    saveRecipe,
    writeRecipes,
} from "../src/store/recipe-store.js"
import { fixture, fixtureText } from "./support/fixtures.js"

const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))
const rows = fixture("buffer/buffer.json").solutes as BufferRow[]
const row = rows[0] as BufferRow

const unusable = (f: () => unknown) =>
    assert.throws(f, (e) => e instanceof UnusableFileError && e.kind === "recipes")

test("the fixture round trips", () => {
    const root = tempRoot()
    writeFileSync(recipesFile(root), fixtureText("buffer/recipes.json"))
    const recipes = readRecipes(root)
    assert.deepEqual(
        recipes.map((r) => r.name),
        ["SEC buffer", "Everything", "Customs", "empty"],
    )
    assert.deepEqual(
        recipes.map((r) => r.solutes.length),
        [3, 11, 4, 0],
    )
    assert.deepEqual(recipes[1]?.solutes, rows, "every kind of row survives")
    writeRecipes(root, recipes)
    assert.deepEqual(readRecipes(root), recipes)
    assert.equal(existsSync(join(root, "recipes.json.tmp")), false)
    assert.equal(
        recipeSolutes(root, "sec BUFFER")?.length,
        3,
        "found without regard to case",
    )
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
    saveRecipe(root, "B", [row])
    assert.deepEqual(
        readRecipes(root).map((r) => r.name),
        ["A", "B"],
    )
    saveRecipe(root, " a ", [row, row])
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

test("unusable files are told and never overwritten", () => {
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
        unusable(() => readRecipes(root))
        unusable(() => saveRecipe(root, "B", [row]))
        unusable(() => writeRecipes(root, []))
        assert.equal(readFileSync(recipesFile(root), "utf-8"), text, "never overwritten")
    }
})

test("invalid writes are refused", () => {
    const root = tempRoot()
    unusable(() => writeRecipes(root, [{ name: "A", solutes: [{ kind: "x" } as never] }]))
    unusable(() => writeRecipes(root, [{ name: " ", solutes: [] }]))
    unusable(() =>
        writeRecipes(root, [
            { name: "A", solutes: [] },
            { name: "A ", solutes: [] },
        ]),
    )
    assert.equal(existsSync(recipesFile(root)), false, "nothing was made")
})

test("the caps", () => {
    const root = tempRoot()
    const many = Array.from({ length: 999 }, (_, i) => ({ name: `r${i}`, solutes: [] }))
    writeRecipes(root, many)
    assert.equal(readRecipes(root).length, 999)
    unusable(() => saveRecipe(root, "one more", [row]))
    saveRecipe(root, "R5", [row])
    assert.equal(readRecipes(root).length, 999, "a replace is fine at the cap")
    writeRecipes(root, [])
    const full = Array.from({ length: 999 }, () => row)
    saveRecipe(root, "full", full)
    assert.equal(recipeSolutes(root, "full")?.length, 999)
    unusable(() => saveRecipe(root, "full", [...full, row]))
    const thousand = Array.from(
        { length: 1000 },
        (_, i) => `{"name": "r${i}", "solutes": []}`,
    )
    writeFileSync(recipesFile(root), `{"recipes": [${thousand.join(",")}]}`)
    unusable(() => readRecipes(root))
})

test("names", () => {
    assert.equal(nameProblem("SEC buffer"), undefined)
    assert.equal(nameProblem("x".repeat(40)), undefined)
    assert.equal(nameProblem("x".repeat(41)), "40 characters at most")
    assert.equal(nameProblem("   "), "type a name first!")
    assert.equal(nameProblem(""), "type a name first!")
    assert.equal(nameProblem("a\tb"), "no control characters")
    assert.equal(nameProblem("ångström ± 😀"), undefined)
    const recipes = [{ name: "Alpha" }, { name: "beta" }]
    assert.equal(indexOfName(recipes, " ALPHA "), 0)
    assert.equal(indexOfName(recipes, "Beta"), 1)
    assert.equal(indexOfName(recipes, "gamma"), undefined)
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

test("list, rename and delete", () => {
    const root = tempRoot()
    writeFileSync(recipesFile(root), fixtureText("buffer/recipes.json"))
    assert.deepEqual(listRecipes(root)[0], {
        name: "SEC buffer",
        solutes: 3,
        kinds: "1 solute 2 polymer",
    })
    assert.equal(renameRecipe(root, "sec buffer", "SEC BUFFER"), undefined, "case only")
    assert.equal(readRecipes(root)[0]?.name, "SEC BUFFER")
    assert.equal(renameRecipe(root, "SEC BUFFER", "customs"), "name in use")
    assert.equal(renameRecipe(root, "nope", "x"), "no such recipe")
    assert.equal(renameRecipe(root, "empty", "none"), undefined)
    assert.equal(deleteRecipe(root, "NONE"), true)
    assert.equal(deleteRecipe(root, "none"), false)
    assert.deepEqual(
        readRecipes(root).map((r) => r.name),
        ["SEC BUFFER", "Everything", "Customs"],
    )
})

test("kinds", () => {
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
    assert.equal(
        kindsSummary(rows.slice(0, 11)),
        "1 solute 3 polymer 4 custom 3 seq",
        "the fixture's rows",
    )
    assert.ok(kindsSummary(rows).includes("seq"))
})
