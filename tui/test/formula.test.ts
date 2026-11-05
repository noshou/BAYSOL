// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    atomicNumber,
    breakdown,
    elementCounts,
    isProblem,
    parseFormula,
    parseUnit,
    stripUnit,
} from "../src/store/formula.js"

const z = (n: number, charge = 0) => ({ z: n, charge })

test("atoms and groups", () => {
    assert.deepEqual(parseFormula("NaCl"), z(28))
    assert.deepEqual(parseFormula("H2O"), z(10))
    assert.deepEqual(parseFormula("D2O"), z(10)) // D counts as hydrogen
    assert.deepEqual(parseFormula("Ca(OH)2"), z(38))
    assert.deepEqual(parseFormula("Fe2(SO4)3"), z(196))
    assert.deepEqual(parseFormula(" Fe2 ( SO4 ) 3 "), z(196)) // spaces ignored
    assert.deepEqual(parseFormula("Ca[OH]2"), parseFormula("Ca(OH)2"))
    assert.deepEqual(parseFormula("C(O(H)3)2"), z(6 + 2 * (8 + 3 * 1)))
})

test("hydrates and adducts", () => {
    assert.deepEqual(parseFormula("CuSO4·5H2O"), z(127))
    assert.deepEqual(parseFormula("CuSO4.5H2O"), parseFormula("CuSO4·5H2O"))
    assert.deepEqual(parseFormula("CuSO4*5H2O"), parseFormula("CuSO4·5H2O"))
    assert.deepEqual(parseFormula("CuSO4•5H2O"), parseFormula("CuSO4·5H2O"))
    assert.deepEqual(parseFormula("2H2O"), z(20))
})

test("charges", () => {
    assert.deepEqual(parseFormula("NH4+"), z(10, 1))
    assert.deepEqual(parseFormula("SO4 2-"), z(50, -2))
    assert.deepEqual(parseFormula("SO4^2-"), z(50, -2))
    assert.deepEqual(parseFormula("Al3+"), z(10, 3))
    assert.deepEqual(parseFormula("Cl-"), z(18, -1))
    assert.deepEqual(parseFormula("Cl -"), z(18, -1))
    assert.deepEqual(parseFormula("O2-"), z(10, -2))
    assert.deepEqual(parseFormula("[Fe(CN)6]3-"), z(26 + 6 * 13 + 3, -3))
    assert.deepEqual(parseFormula("SO4 2−"), z(50, -2)) // the Unicode minus
})

test("errors", () => {
    assert.deepEqual(parseFormula("Xx"), { error: "unknown element Xx" })
    assert.deepEqual(parseFormula("NaQ"), { error: "unknown element Q" })
    for (const bad of ["", "   ", "Ca(OH", "CaOH)2", "Na0", "na", "NaCl·"])
        assert.ok(isProblem(parseFormula(bad)), bad)
    for (const bad of ["Xx", "", "Ca(OH", "CaOH)2", "Na0", "na", "NaCl·", "N%", "Zzz"]) {
        const r = parseFormula(bad)
        assert.ok(isProblem(r) && r.error.length <= 22, bad)
    }
})

test("all the elements", () => {
    assert.equal(atomicNumber.get("Og"), 118)
    assert.equal(atomicNumber.get("H"), 1)
    const numbers = [...atomicNumber].filter(([s]) => s !== "D").map(([, n]) => n)
    assert.equal(new Set(numbers).size, 118)
})

test("polymer units", () => {
    const unit = { unit: "C2H4O", z: 24 }
    assert.deepEqual(parseUnit("C2H4O"), unit)
    assert.deepEqual(parseUnit("(C2H4O)n"), unit)
    assert.deepEqual(parseUnit(" ( C2H4O ) n "), unit)
    assert.equal(stripUnit("(C2H4O)n"), "C2H4O")
    assert.equal(stripUnit("Ca(OH)2"), "Ca(OH)2") // only a wrapper with n is stripped
    assert.deepEqual(parseUnit("C2H4O+"), { error: "no charge allowed" })
    assert.ok(isProblem(parseUnit("(Xx)n")))
})

test("element counts in Hill order, summed over parts and groups", () => {
    assert.deepEqual(elementCounts("C7H13NO3S"), {
        counts: [
            ["C", 7],
            ["H", 13],
            ["N", 1],
            ["O", 3],
            ["S", 1],
        ],
        charge: 0,
        z: 102,
    })
    const counts = (f: string) => (elementCounts(f) as { counts: unknown }).counts
    assert.deepEqual(counts("HCClBr"), [
        ["C", 1],
        ["H", 1],
        ["Br", 1],
        ["Cl", 1],
    ])
    assert.deepEqual(counts("Ca(OH)2"), [
        ["Ca", 1],
        ["H", 2],
        ["O", 2],
    ])
    assert.deepEqual(counts("CuSO4·5H2O"), [
        ["Cu", 1],
        ["H", 10],
        ["O", 9],
        ["S", 1],
    ])
    assert.deepEqual(counts("2H2O"), [
        ["H", 4],
        ["O", 2],
    ])
})

test("the counts add up to the electrons, whatever the charge", () => {
    for (const f of [
        "NaCl",
        "Ca(OH)2",
        "Fe2(SO4)3",
        "NH4+",
        "SO4 2-",
        "CuSO4·5H2O",
        "D2O",
    ]) {
        const r = elementCounts(f)
        assert.ok(!isProblem(r), f)
        if (isProblem(r)) continue
        assert.equal((parseFormula(f) as { z: number }).z, r.z, f)
        const atoms = r.counts.reduce(
            (sum, [s, n]) => sum + n * (atomicNumber.get(s) ?? 0),
            0,
        )
        assert.equal(r.charge + r.z, atoms, f)
    }
})

test("errors of the counts are the parser's, and the text of the sum", () => {
    assert.deepEqual(elementCounts("Xx"), parseFormula("Xx"))
    assert.equal(breakdown("Xx"), undefined)
    assert.equal(breakdown(""), undefined)
    assert.equal(
        breakdown("C7H13NO3S"),
        "7 C + 13 H + 1 N + 3 O + 1 S = 102 electrons, charge 0",
    )
    assert.equal(breakdown("SO4 2-"), "4 O + 1 S = 50 electrons, charge -2")
    assert.equal(breakdown("NH4+"), "4 H + 1 N = 10 electrons, charge +1")
})
