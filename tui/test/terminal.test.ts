// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of `core/terminal.ts`: text in terminal cells and numbers.

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    displayWidth,
    formatNumber,
    numberText,
    padWidth,
    parseNumber,
    plainNumber,
    takeWidth,
    truncate,
} from "../src/core/terminal.js"

test("numberText takes a decimal number as typed and nothing else", () => {
    for (const [text, x] of [
        ["5", 5],
        ["-2.5", -2.5],
        ["+.5", 0.5],
        ["1e-3", 0.001],
        ["7.", 7],
    ] as const)
        assert.equal(numberText(text), x, text)
    const bad = ["", " 5", "5 ", "0x10", "NaN", "Infinity", "1e999", "1,5", "--1"]
    for (const text of bad)
        assert.equal(numberText(text), undefined, JSON.stringify(text))
})

test("plainNumber writes no exponent", () => {
    assert.equal(plainNumber(22), "22")
    assert.equal(plainNumber(1e21), "1000000000000000000000")
    assert.equal(plainNumber(1.5e21), "1500000000000000000000")
    assert.equal(plainNumber(1e-7), "0.0000001")
    assert.equal(plainNumber(1.25e-7), "0.000000125")
})

test("formatNumber is plain text, empty for none", () => {
    assert.equal(formatNumber(200), "200")
    assert.equal(formatNumber(1e-5), "0.00001")
    assert.equal(formatNumber(null), "")
    assert.equal(formatNumber(undefined), "")
})

test("parseNumber: the rules are what a cell accepts", () => {
    assert.deepEqual(parseNumber(" -2.5 "), { value: -2.5 })
    assert.deepEqual(parseNumber(""), { error: "a number, please" })
    assert.deepEqual(parseNumber("1e999"), { error: "a number, please" })
    // blank is a value of an optional cell
    assert.deepEqual(parseNumber("  ", { blank: true }), { value: null })
    // limits: above is strict, at least is not
    const above = { above: { limit: 0, message: "too low" } }
    assert.deepEqual(parseNumber("0", above), { error: "too low" })
    assert.deepEqual(parseNumber("0.1", above), { value: 0.1 })
    const least = { atLeast: { limit: 0, message: "below 0" } }
    assert.deepEqual(parseNumber("0", least), { value: 0 })
    assert.deepEqual(parseNumber("-1", least), { error: "below 0" })
    // whole numbers: unsigned unless allowed, digits counted without leading zeros
    const notWhole = { error: "a whole number, please" }
    assert.deepEqual(parseNumber("2.5", { whole: true }), notWhole)
    assert.deepEqual(parseNumber("-2", { whole: true }), notWhole)
    assert.deepEqual(parseNumber("-2", { whole: true, signed: true }), { value: -2 })
    const cap = { whole: true, maxDigits: 3 }
    assert.deepEqual(parseNumber("0123", cap), { value: 123 })
    assert.deepEqual(parseNumber("1234", cap), { error: "a whole number, please" })
    assert.deepEqual(parseNumber("1234", { ...cap, digitsMessage: "3 digits" }), {
        error: "3 digits",
    })
})

test("countZeros counts leading zeros too (the custom Z cells)", () => {
    const rules = { whole: true, maxDigits: 9, countZeros: true }
    assert.ok("value" in parseNumber("123456789", rules))
    assert.ok("error" in parseNumber("0000000005", rules))
    // without it, leading zeros are free
    assert.ok("value" in parseNumber("0000000005", { whole: true, maxDigits: 9 }))
})

test("displayWidth measures the way Ink does, ambiguous width included", async () => {
    // Ink lays text out with `string-width`'s defaults, so the text helpers must give the
    // same cells for every character the screens use, or a line is cut or padded wrongly
    const { default: inkWidth } = await import("string-width")
    const samples = ["σ", "±", "Å", "°", "α", "μ", "ρ", "δ", "·", "…", "⏎", "↑↓", "⌫", "×"]
    for (const c of [...samples, "pH σ: ^g"])
        assert.equal(displayWidth(c), inkWidth(c), c)
    for (const c of ["σ", "±", "Å", "°", "μ", "·", "…"]) assert.equal(displayWidth(c), 1, c)
    // truncating and padding agree with that measure
    assert.equal(truncate("pH ± σ pH ± σ", 6), "pH ± …")
    assert.equal(displayWidth(padWidth("σ", 4)), 4)
    assert.equal(takeWidth("σσσσ", 3), "σσσ")
})
