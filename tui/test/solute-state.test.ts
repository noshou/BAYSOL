// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { Drafts } from "../src/store/draft.js"
import {
    addBlankRow,
    firstProblem,
    names,
    problem,
    type Solute,
    setField,
    swatch,
} from "../src/store/solutes.js"

const base = { kind: "nonbiological", sigmaMM: 10 }
const nacl: Solute = { ...base, name: "NaCl", arg: "NaCl", mM: 200 }
const tris: Solute = { ...base, name: "tris", arg: "tris", mM: 10, sigmaMM: 0.5 }
const complete = () => undefined
const incomplete = () => "unknown kind"
const marks = (s: Drafts<Solute>) => s.rows.map((_, i) => s.mark(i))

test("drafts and removals of solutes", () => {
    const s = Drafts.of([nacl, tris])
    const e = setField(s, 0, "mM", 150)
    assert.deepEqual(marks(e), ["*", undefined])
    assert.equal(e.value(0)?.mM, 150)
    assert.deepEqual(marks(setField(e, 0, "mM", 200)), [undefined, undefined])
    // the name is a label: the arg stays
    const renamed = setField(s, 0, "name", "KCl").value(0)
    assert.deepEqual([renamed?.name, renamed?.arg], ["KCl", "NaCl"])
    // a new blank row is marked and goes with undo or remove
    const a = addBlankRow(s)
    assert.deepEqual(marks(a), [undefined, undefined, "*"])
    assert.equal(a.undo(2).length, 2)
    assert.equal(a.remove(2).length, 2)
    // a saved row is only marked to go; a save keeps the rest as it is
    const r = s.remove(0)
    const edited = setField(r, 1, "mM", 11)
    assert.deepEqual(edited.toSave(), [{ ...tris, mM: 11 }])
    assert.equal(edited.commit().dirty, false)
})

test("what is missing", () => {
    assert.equal(problem(nacl, complete), undefined)
    assert.equal(problem({ ...nacl, name: " " }, complete), "name needed")
    assert.equal(problem({ ...nacl, mM: null }, complete), "mM must be > 0")
    assert.equal(problem({ ...nacl, mM: 0 }, complete), "mM must be > 0")
    assert.equal(problem({ ...nacl, sigmaMM: null }, complete), "±mM needed")
    assert.equal(problem({ ...nacl, sigmaMM: 0 }, complete), undefined)
    assert.equal(problem(nacl, incomplete), "row incomplete")
    const s = setField(addBlankRow(Drafts.of([nacl, tris])), 2, "name", "x")
    assert.deepEqual(firstProblem(s, complete), [2, "mM must be > 0"])
    assert.equal(firstProblem(s.remove(2), complete), undefined)
})

test("the colours have names and colours", () => {
    const list = names("PLOT_COLOUR_MAP", "colour")
    assert.ok(list.length > 600)
    for (const n of ["crimson", "darkorange", "gray20", "black", "antiquewhite4"]) {
        assert.ok(list.includes(n), n)
    }
    assert.deepEqual(swatch("crimson"), [220, 20, 60])
    assert.deepEqual(swatch("antiquewhite4"), [139, 131, 120])
    assert.deepEqual(swatch("#ff0000"), [255, 0, 0])
    assert.equal(swatch("nope"), undefined)
    assert.equal(swatch("#ff00"), undefined)
})

test("fonts are the math fonts or the text fonts", () => {
    const math = ["Neo Euler", "TeX Gyre Pagella Math"]
    const fonts = { math, text: ["Pagella", "Times"] }
    assert.deepEqual(names("PLOT_MATH_FONT", "font", fonts), fonts.math)
    assert.deepEqual(names("PLOT_TEXT_FONT", "font", fonts), fonts.text)
    assert.deepEqual(names("X", "other", fonts), [])
    assert.deepEqual(names("PLOT_TEXT_FONT", "font"), [])
})
