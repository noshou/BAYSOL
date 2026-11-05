// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    fileStatus,
    formulaCell,
    landingOptions,
    pmvCell,
    sigmaCell,
    zCell,
} from "../src/screens/custom-text.js"
import {
    blankNonbio,
    blankPolymer,
    type NonbioEntry,
    type PolymerEntry,
} from "../src/store/custom.js"

/** The polymer of the documentation: two kinds of unit and end groups. */
const polymer: PolymerEntry = {
    ...blankPolymer(),
    name: "chain-2",
    units: [
        { label: "A", formula: "C2H4O", z: 24, slope: 36.9, sigma: null },
        { label: "B", formula: "C3H6O", z: 32, slope: 53.1, sigma: null },
    ],
    "z-ends": 10,
    "pmv-ends": 9,
}

const nonbio: NonbioEntry = {
    ...blankNonbio(),
    name: "x",
    formula: "C7H13NO3S",
    z: 100,
    pmv: 118.4,
}

test("a polymer's cells are sums by the labels of its units", () => {
    assert.equal(formulaCell(polymer), "A:C2H4O B:C3H6O")
    assert.equal(zCell(polymer), "24A+32B+10")
    assert.equal(pmvCell(polymer), "36.9A+53.1B+9")
})

test("a first minus is kept and a missing term is left out", () => {
    const e: PolymerEntry = {
        ...polymer,
        units: [{ label: "A", formula: "", z: 24, slope: -5.2, sigma: null }],
        "pmv-ends": 3,
        "z-ends": null,
    }
    assert.equal(pmvCell(e), "-5.2A+3")
    assert.equal(zCell(e), "24A")
    assert.equal(formulaCell(e), "")
    assert.equal(pmvCell({ ...e, "pmv-ends": -3 }), "-5.2A-3")
})

test("a non-biological row shows its numbers and the fallback for a blank ±", () => {
    assert.equal(formulaCell(nonbio), "C7H13NO3S")
    assert.equal(zCell(nonbio), "100")
    assert.equal(pmvCell(nonbio), "118.4")
    assert.equal(sigmaCell(nonbio, 3.044643), "(3.04)")
    assert.equal(sigmaCell({ ...nonbio, sigma: 4 }, 3.044643), "4")
    assert.equal(zCell(blankNonbio()), "")
})

test("the ± of a polymer is the units' when they agree, … when not, (2%) blank", () => {
    assert.equal(sigmaCell(polymer, 3), "(2%)")
    const same: PolymerEntry = {
        ...polymer,
        units: polymer.units.map((u) => ({ ...u, sigma: 0.5 })),
    }
    assert.equal(sigmaCell(same, 3), "0.5")
    const [a, b] = polymer.units as [PolymerEntry["units"][0], PolymerEntry["units"][0]]
    assert.equal(sigmaCell({ ...polymer, units: [{ ...a, sigma: 0.1 }, b] }, 3), "…")
})

test("the landing counts and says what the files hold", () => {
    assert.deepEqual(landingOptions(3, 12), ["recipes (3)", "solutes (12)"])
    assert.deepEqual(landingOptions("unusable", 0), ["recipes (?)", "solutes (0)"])
    assert.equal(fileStatus("recipes.json", 3, "recipe"), "recipes.json: 3 recipes")
    assert.equal(fileStatus("a", 1, "solute"), "a: 1 solute")
    assert.equal(fileStatus("a", 0, "solute"), "a: none yet")
    assert.equal(fileStatus("a", "unusable", "solute"), "a unusable!")
})
