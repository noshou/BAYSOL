// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { statSync } from "node:fs"
import { test } from "node:test"
import { assetPath } from "../src/core/assets.js"
import type { CustomEntry } from "../src/store/custom.js"
import {
    allFamilies,
    family,
    familyArg,
    isBuiltinName,
    type PolymerFamily,
    polymerBasis,
    resolveBuiltin,
    search,
} from "../src/store/solute-index.js"

const chain: CustomEntry = {
    kind: "polymer",
    name: "chain-2",
    units: [{ label: "A", formula: "C2H4O", z: 24, slope: 36.7, sigma: null }],
    "z-ends": 10,
    "pmv-ends": 19.2,
    "sigma-ends": null,
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
    assert.deepEqual(familyArg(peg(), 0, { n: "22" }), { arg: "PEG n=22" })
    assert.deepEqual(familyArg(peg(), 0, { n: 22.0 }), { arg: "PEG n=22" })
    assert.deepEqual(familyArg(peg(), 0, { n: " 22.5 " }), { arg: "PEG n=22.5" })
    assert.deepEqual(familyArg(peg(), 1, { Mn: "3350" }), { arg: "PEG 3350" })
    assert.deepEqual(familyArg(peg(), 1, { Mn: "1e6" }), { arg: "PEG 1000000" })
    const brijArg = familyArg(brij(), 0, { nC: "12", nEO: "23" })
    assert.deepEqual(brijArg, { arg: "Brij nC=12 nEO=23" })
})

test("family templates: errors", () => {
    assert.deepEqual(familyArg(peg(), 0, { n: "twenty" }), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 0, {}), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 0, { n: "NaN" }), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 0, { n: "" }), { error: "n: not a number" })
    assert.deepEqual(familyArg(peg(), 0, { n: "0" }), { error: "n: must be above 0" })
    assert.deepEqual(familyArg(peg(), 0, { n: "-3" }), { error: "n: must be above 0" })
    assert.deepEqual(familyArg(peg(), 0, { n: "1" }), { error: "n: at least 2" })
    assert.deepEqual(familyArg(peg(), 0, { n: "2" }), { arg: "PEG n=2" })
    const noEO = familyArg(brij(), 0, { nC: "12", nEO: "" })
    assert.deepEqual(noEO, { error: "nEO: not a number" })
    assert.deepEqual(familyArg(peg(), 5, { n: "2" }), { error: "no such form" })
})

test("dextran and pullulan: a molar mass below 1000 counts as kDa", () => {
    const note = "below 1000 counts as kDa"
    assert.deepEqual(familyArg(dextran(), 1, { Mn: "40" }), { arg: "dextran 40", note })
    assert.deepEqual(familyArg(dextran(), 1, { Mn: "40000" }), { arg: "dextran 40000" })
    assert.deepEqual(familyArg(dextran(), 0, { n: "250" }), { arg: "dextran n=250" })
    const glucan = familyArg(need("glucan"), 1, { Mn: "100" })
    assert.equal("note" in glucan && glucan.note, note)
    assert.ok(!("note" in familyArg(peg(), 1, { Mn: "100" })))
})

test("the polymer basis of a row", () => {
    assert.equal(polymerBasis("ficoll 70"), "per 1000 Da")
    assert.equal(polymerBasis(" Ficoll 70 "), "per 1000 Da")
    assert.equal(polymerBasis("PEG n=22"), undefined)
    assert.equal(polymerBasis("sodium chloride"), undefined)
    assert.equal(polymerBasis(null), undefined)
})
