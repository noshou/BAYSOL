// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    compareNoCase,
    fold,
    formatNumber,
    numberText,
    plainNumber,
    tooLong,
} from "../src/core/text.js"

test("tooLong has one wording", () => {
    assert.equal(tooLong("name", 40), "name too long (40 at most)")
    assert.equal(tooLong("text", 300), "text too long (300 at most)")
})

test("fold trims and lower-cases, and takes null for empty", () => {
    assert.equal(fold("  NaCl "), "nacl")
    assert.equal(fold(null), "")
    assert.equal(fold(undefined), "")
})

test("compareNoCase orders by code unit without regard to case", () => {
    assert.deepEqual(["b", "A", "a", "B"].sort(compareNoCase), ["A", "a", "b", "B"])
    assert.equal(compareNoCase("x", "X"), 0)
    assert.ok(compareNoCase("a", "b") < 0)
})

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
