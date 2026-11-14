// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/solutes.ts: the solute rows of a table and the index.

import assert from "node:assert/strict"
import { statSync } from "node:fs"
import { test } from "node:test"
import { assetPath } from "../src/core/environment.js"
import type { CustomEntry } from "../src/store/custom.js"
import { Drafts } from "../src/store/lists.js"
import {
    allFamilies,
    draftProblem,
    family,
    familyArg,
    firstProblem,
    isBuiltinName,
    type PolymerFamily,
    polymerBasis,
    resolveBuiltin,
    type Solute,
    search,
    setSoluteField,
} from "../src/store/solutes.js"

// ========================================================================================
// 1. Solute rows
// ========================================================================================

const base = { kind: "nonbiological", sigmaMM: 10 }
const nacl: Solute = { ...base, name: "NaCl", arg: "NaCl", mM: 200 }
const tris: Solute = { ...base, name: "tris", arg: "tris", mM: 10, sigmaMM: 0.5 }
const complete = () => undefined
const blank: Solute = { kind: "nonbiological", name: "", arg: "", mM: null, sigmaMM: null }
const incomplete = () => "unknown kind"
const marks = (s: Drafts<Solute>) => s.rows.map((_, i) => s.mark(i))

test("drafts and removals of solutes", () => {
    const s = Drafts.of([nacl, tris])
    const e = setSoluteField(s, 0, "mM", 150)
    assert.deepEqual(marks(e), ["*", undefined])
    assert.equal(e.value(0)?.mM, 150)
    assert.deepEqual(marks(setSoluteField(e, 0, "mM", 200)), [undefined, undefined])
    // the name is a label: the arg stays
    const renamed = setSoluteField(s, 0, "name", "KCl").value(0)
    assert.deepEqual([renamed?.name, renamed?.arg], ["KCl", "NaCl"])
    // a new blank row is marked and goes with undo or remove
    const a = s.add(blank)
    assert.deepEqual(marks(a), [undefined, undefined, "*"])
    assert.equal(a.undo(2).length, 2)
    assert.equal(a.remove(2).length, 2)
    // a saved row is only marked to go; a save keeps the rest as it is
    const r = s.remove(0)
    const edited = setSoluteField(r, 1, "mM", 11)
    assert.deepEqual(edited.toSave(), [{ ...tris, mM: 11 }])
    assert.equal(edited.commit().dirty, false)
})

test("what is missing", () => {
    assert.equal(draftProblem(nacl, complete), undefined)
    assert.equal(draftProblem({ ...nacl, name: " " }, complete), "name needed")
    assert.equal(draftProblem({ ...nacl, mM: null }, complete), "mM must be > 0")
    assert.equal(draftProblem({ ...nacl, mM: 0 }, complete), "mM must be > 0")
    assert.equal(draftProblem({ ...nacl, sigmaMM: null }, complete), "±mM needed")
    assert.equal(draftProblem({ ...nacl, sigmaMM: 0 }, complete), undefined)
    assert.equal(draftProblem(nacl, incomplete), "row incomplete")
    const s = setSoluteField(Drafts.of([nacl, tris]).add(blank), 2, "name", "x")
    assert.deepEqual(firstProblem(s, complete), [2, "mM must be > 0"])
    assert.equal(firstProblem(s.remove(2), complete), undefined)
})

// ========================================================================================
// 2. Index
// ========================================================================================

const chain: CustomEntry = {
    kind: "polymer",
    name: "chain-2",
    units: [{ label: "A", formula: "C2H4O", z: 24, slope: 36.7, sigma: null }],
    "zEnds": 10,
    "pmvEnds": 19.2,
    "sigmaEnds": null,
}
const cnb: CustomEntry = {
    kind: "nonbiological",
    name: "Tris-like",
    formula: "C4H11NO3",
    z: 66,
    pmv: 90,
    sigma: null,
}
const names = (results: { name: string }[]) => results.map((r) => r.name)
/** A family of the file, which the test needs to be there. */
function need(id: string): PolymerFamily {
    const found = family(id)
    if (!found) throw new Error(`no family ${id}`)
    return found
}
const peg = () => need("peg")
const dextran = () => need("dextran")
const brij = () => need("alkyl-ethoxylate")

test("the index file is small and loads fast", () => {
    assert.ok(statSync(assetPath("data", "solute_index.json")).size < 1_500_000)
    const t0 = performance.now()
    resolveBuiltin("nacl")
    assert.ok(performance.now() - t0 < 5000)
})

test("aliases resolve to their target", () => {
    assert.deepEqual(resolveBuiltin("nacl"), {
        name: "nacl",
        kind: "nonbiological",
        target: "sodium chloride",
        tag: "solute",
        basis: null,
    })
    assert.equal(
        resolveBuiltin("  TRIS ")?.target,
        "2-amino-2-(hydroxymethyl)propane-1,3-diol",
    )
    assert.equal(
        resolveBuiltin("Glucose")?.target,
        "(2r,3s,4r,5r)-2,3,4,5,6-pentahydroxyhexanal",
    )
    const ficoll = resolveBuiltin("ficoll 400")
    assert.deepEqual(
        [ficoll?.kind, ficoll?.tag, ficoll?.basis, ficoll?.target],
        ["polymer", "polymer", "per 1000 Da", "ficoll"],
    )
    assert.equal(resolveBuiltin("peg 1450")?.basis, null)
    assert.equal(resolveBuiltin("pvp")?.basis, "per monomer unit")
    assert.equal(resolveBuiltin("a8-35")?.basis, "per monomer unit")
})

test("a family name is the family, which wins over a grade of the same name", () => {
    const e = resolveBuiltin("PEG")
    assert.deepEqual(
        [e?.kind, e?.target, e?.family, e?.tag],
        ["polymer-family", "peg", "peg", "polymer"],
    )
    assert.equal(resolveBuiltin("dextran")?.kind, "polymer-family")
})

test("unknown names", () => {
    assert.equal(resolveBuiltin("no such solute"), undefined)
    assert.equal(resolveBuiltin(""), undefined)
    assert.ok(isBuiltinName("NaCl"))
    assert.ok(!isBuiltinName("my own thing"))
})

test("search: a blank query finds nothing", () => {
    assert.deepEqual(search("", []), [])
    assert.deepEqual(search("   ", []), [])
})

test("search: exact, then starts with, then contains; each by length then alphabet", () => {
    const found = names(search("tris", []))
    const group = (n: string) => (n === "tris" ? 0 : n.startsWith("tris") ? 1 : 2)
    const groups = found.map(group)
    assert.equal(found[0], "tris")
    assert.deepEqual(groups, [...groups].sort())
    assert.ok(groups.includes(2), "the last group is not empty")
    for (const g of [1, 2]) {
        const inGroup = found.filter((n) => group(n) === g)
        const sorted = [...inGroup].sort((a, b) =>
            a.length !== b.length ? a.length - b.length : a < b ? -1 : a > b ? 1 : 0,
        )
        assert.deepEqual(inGroup, sorted)
    }
})

test("search: case-insensitive, an alias shows as typed", () => {
    assert.deepEqual(search("NACL", []), search("nacl", []))
    assert.equal(search("NaCl", [])[0].name, "nacl")
})

test("search: the result count is capped, by default at 200", () => {
    assert.equal(search("a", []).length, 200)
    assert.equal(search("a", [], 7).length, 7)
    assert.deepEqual(search("a", []).slice(0, 7), search("a", [], 7))
})

test("search: kinds and tags", () => {
    const r = search("peg", [])
    assert.equal(r[0].kind, "polymer-family")
    assert.ok(r.every((e) => ["solute", "polymer", "custom"].includes(e.tag)))
    const only = search("peg", [], 200, new Set(["polymer-family"]))
    assert.ok(only.length > 0 && only.every((e) => e.kind === "polymer-family"))
    assert.deepEqual(search("qzxqzxqzx", []), [])
})

test("custom solutes are searched too", () => {
    const r = search("chain", [chain, cnb])
    const first = r[0]
    assert.deepEqual(
        [first.name, first.kind, first.tag, first.target],
        ["chain-2", "custom-polymer", "custom", "chain-2"],
    )
    assert.equal(first.entry, chain)
    // they rank with the built-in ones by group and length
    const t = search("tris", [cnb])
    const found = names(t)
    assert.equal(found[0], "tris")
    assert.equal(t.find((e) => e.name === "Tris-like")?.kind, "custom-nonbio")
    assert.ok(found.indexOf("tris-cl") < found.indexOf("Tris-like"))
    assert.equal(search("TRIS-LIKE", [cnb])[0].name, "Tris-like")
})

test("search is fast enough for a keystroke", () => {
    search("a", [])
    const t0 = performance.now()
    for (let i = 0; i < 20; i++) search("ethan", [chain, cnb])
    assert.ok((performance.now() - t0) / 20 < 100)
})

test("families", () => {
    assert.equal(peg().label, "PEG")
    assert.equal(peg().forms.length, 2)
    assert.equal(family("nope"), undefined)
    for (const f of allFamilies()) {
        assert.equal(family(f.id), f)
        for (const n of f.names) assert.equal(resolveBuiltin(n)?.family, f.id, n)
    }
})

test("family templates: numbers fill the placeholders", () => {
    assert.deepEqual(familyArg(peg(), 1, { n: "22" }), { arg: "PEG n=22" })
    assert.deepEqual(familyArg(peg(), 1, { n: 22.0 }), { arg: "PEG n=22" })
    assert.deepEqual(familyArg(peg(), 1, { n: " 22.5 " }), { arg: "PEG n=22.5" })
    // biome-ignore lint/style/useNamingConvention: polymer data key
    assert.deepEqual(familyArg(peg(), 0, { Mn: "3350" }), { arg: "PEG 3350" })
    // biome-ignore lint/style/useNamingConvention: polymer data key
    assert.deepEqual(familyArg(peg(), 0, { Mn: "1e6" }), { arg: "PEG 1000000" })
    const brijArg = familyArg(brij(), 0, { nC: "12", nEO: "23" })
    assert.deepEqual(brijArg, { arg: "Brij nC=12 nEO=23" })
})

test("family templates: errors", () => {
    assert.deepEqual(familyArg(peg(), 1, { n: "twenty" }), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 1, {}), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 1, { n: "NaN" }), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 1, { n: "" }), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 1, { n: "0" }), { error: "n: must be above 0" })
    assert.deepEqual(familyArg(peg(), 1, { n: "-3" }), { error: "n: must be above 0" })
    assert.deepEqual(familyArg(peg(), 1, { n: "1" }), { error: "n: at least 2" })
    assert.deepEqual(familyArg(peg(), 1, { n: "2" }), { arg: "PEG n=2" })
    const noEO = familyArg(brij(), 0, { nC: "12", nEO: "" })
    assert.deepEqual(noEO, { error: "nEO: not a number" })
    assert.deepEqual(familyArg(peg(), 5, { n: "2" }), { error: "no such form" })
})

test("dextran and pullulan: a molar mass below 1000 counts as kDa", () => {
    const note = "below 1000 counts as kDa"
    // biome-ignore lint/style/useNamingConvention: polymer data key
    assert.deepEqual(familyArg(dextran(), 0, { Mn: "40" }), { arg: "dextran 40", note })
    // biome-ignore lint/style/useNamingConvention: polymer data key
    assert.deepEqual(familyArg(dextran(), 0, { Mn: "40000" }), { arg: "dextran 40000" })
    assert.deepEqual(familyArg(dextran(), 1, { n: "250" }), { arg: "dextran n=250" })
    // biome-ignore lint/style/useNamingConvention: polymer data key
    const glucan = familyArg(need("glucan"), 0, { Mn: "100" })
    assert.equal("note" in glucan && glucan.note, note)
    // biome-ignore lint/style/useNamingConvention: polymer data key
    assert.ok(!("note" in familyArg(peg(), 0, { Mn: "100" })))
})

test("the polymer basis of a row", () => {
    assert.equal(polymerBasis("ficoll 70"), "per 1000 Da")
    assert.equal(polymerBasis(" Ficoll 70 "), "per 1000 Da")
    assert.equal(polymerBasis("PEG n=22"), undefined)
    assert.equal(polymerBasis("sodium chloride"), undefined)
    assert.equal(polymerBasis(null), undefined)
})
