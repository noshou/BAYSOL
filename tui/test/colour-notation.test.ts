// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/colour-notation.ts: every named colour written in HEX, RGB, HSL and CMYK
// reads back as the same 8-bit colour, and the strings are those of the golden file that
// the Julia resolver (test_colournames.jl) reads too.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { test } from "node:test"
import { readAssetJson } from "../src/core/environment.js"
import {
    colourNotations,
    fromHex,
    parseColourCode,
    toHex,
} from "../src/store/colour-notation.js"
import { namesOfCode } from "../src/store/colours.js"

type Golden = {
    colours: { hex: string; rgb: string; hsl: string; cmyk: string }[]
    codes: { text: string; hex: string }[]
    invalid: string[]
}

const golden = JSON.parse(
    readFileSync(
        new URL("../../test/fixtures/colours/notations.json", import.meta.url),
        "utf8",
    ),
) as Golden

test("every named colour round-trips through every notation", () => {
    const file = readAssetJson<Record<string, string>>("data", "colours.json")
    for (const [name, hex] of Object.entries(file)) {
        const rgb = fromHex(hex)
        const n = colourNotations(rgb)
        assert.equal(n.hex, hex, name)
        for (const text of [n.hex, n.rgb, n.hsl, n.cmyk])
            assert.deepEqual(parseColourCode(text), rgb, `${name}: ${text}`)
    }
})

test("the strings equal the golden file of the Julia resolver", () => {
    assert.ok(golden.colours.length > 100)
    for (const row of golden.colours) {
        const n = colourNotations(fromHex(row.hex))
        assert.deepEqual(n, { hex: row.hex, rgb: row.rgb, hsl: row.hsl, cmyk: row.cmyk })
    }
    for (const row of golden.codes)
        assert.deepEqual(parseColourCode(row.text), fromHex(row.hex), row.text)
    for (const text of golden.invalid)
        assert.equal(parseColourCode(text), undefined, text)
})

test("a typed value lists every name with exactly that colour", () => {
    const file = readAssetJson<Record<string, string>>("data", "colours.json")
    const byHex = new Map<string, string[]>()
    for (const [name, hex] of Object.entries(file))
        byHex.set(hex, [...(byHex.get(hex) ?? []), name])
    let shared = 0
    for (const [hex, names] of byHex) {
        const n = colourNotations(fromHex(hex))
        for (const text of [n.hex, n.rgb, n.hsl, n.cmyk])
            assert.deepEqual(namesOfCode(text), names, text)
        if (names.length > 1) shared++
    }
    assert.ok(shared > 0)
    assert.deepEqual(namesOfCode("#a52a2a")?.includes("brown"), true)
    assert.deepEqual(namesOfCode("rgb(1, 2, 3)"), [])
    assert.equal(namesOfCode("brown"), undefined)
    assert.equal(toHex([1, 2, 255]), "#0102ff")
})
