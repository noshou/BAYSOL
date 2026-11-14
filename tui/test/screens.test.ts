// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the screens' pure parts: the setting editors, the legends and the table cells.
//
// Contents:
//   1. Setting edit (the text a setting is typed as)
//   2. Tables and forms
//   3. The file viewer
//   4. The custom solutes' text
//   5. The words of the recipes and the landings

import assert from "node:assert/strict"
import { test } from "node:test"
import { displayWidth, parseNumber } from "../src/core/terminal.js"
import {
    formulaCell,
    pmvCell,
    sigmaCell,
    zCell,
} from "../src/screens/custom-solutes.js"
import {
    bufferLandingOptions,
    finishTuple,
    fitName,
    formLegend,
    hasColourPart,
    indexOfPick,
    NO_RECIPES,
    narrow,
    numberRules,
    parsePart,
    parseSetting,
    pickValue,
    plural,
    recipeChoice,
    replaceBufferQuestion,
    replaceRecipeQuestion,
    savedAs,
    swatchColour,
    type TableFacts,
    tableLegend,
    tupleOf,
    tupleParts,
    unusable,
    valueText,
    withDraft,
    withModelDraft,
} from "../src/screens/screen-rules.js"
import { fileStatus } from "../src/screens/settings-screens.js"
import { draftOf, soluteProblem } from "../src/screens/solutes.js"
import { legendExtraRows, viewerFullLegend, viewerLegend } from "../src/screens/viewer.js"
import { type BufferRow, rowProblem } from "../src/store/buffer.js"
import { blankNonbio, type NonbioEntry } from "../src/store/custom.js"
import { blankPolymer, type PolymerEntry } from "../src/store/polymers.js"
import { defaultCatalog } from "../src/store/settings.js"
import { rowOf, soluteOf } from "../src/store/solutes.js"
import { entryLegend, legendFor } from "../src/ui/grid.js"
import { destructiveQuestion, questionLegend } from "../src/ui/input.js"
import { keys } from "../src/ui/interaction.js"
import { fixture } from "./support/fixtures.js"

// ========================================================================================
// 1. Setting edit
// ========================================================================================

const catalog = defaultCatalog()
const def = (name: string) => catalog.require(name)

test("number rules: whole numbers and decimals", () => {
    assert.deepEqual(parseNumber("12", numberRules.int), { value: 12 })
    assert.deepEqual(parseNumber("-3", numberRules.int), { value: -3 })
    const whole = { error: "a whole number, please" }
    assert.deepEqual(parseNumber("2.5", numberRules.int), whole)
    assert.deepEqual(parseNumber("", numberRules.int), { error: "a whole number, please" })
    assert.deepEqual(parseNumber("1e-3", numberRules.float), { value: 0.001 })
    assert.deepEqual(parseNumber("5", numberRules.float), { value: 5 })
    assert.deepEqual(parseNumber(".5", numberRules.float), { value: 0.5 })
    assert.deepEqual(parseNumber("x", numberRules.float), { error: "a number, please" })
    assert.deepEqual(parseNumber("", numberRules.float), { error: "a number, please" })
    assert.deepEqual(parseNumber("1e999", numberRules.float), { error: "a number, please" })
})

test("parseSetting: numbers keep to the limits, sets to the choices", () => {
    assert.deepEqual(parseSetting(def("N_ADAPT"), "250"), { value: 250 })
    const low = parseSetting(def("N_ADAPT"), "0")
    assert.ok("error" in low && /^must be at least/.test(low.error))
    assert.deepEqual(parseSetting(def("MODE_δρ₁₂"), "x"), { error: "a number, please" })
    const formats = def("FIGURES_FORMATS")
    assert.deepEqual(parseSetting(formats, "svg  pdf"), { value: ["pdf", "svg"] })
    assert.ok("error" in parseSetting(formats, ""))
    assert.ok("error" in parseSetting(formats, "pdf gif"))
})

test("colours, markers and sizes are typed as one line and shown the same way", () => {
    const colours = def("PLOT_COMPARE_COLOURS")
    const typed = parseSetting(colours, "#D55E00, #0072B2  RED,crimson")
    assert.deepEqual(typed, { value: ["#D55E00", "#0072B2", "red", "crimson"] })
    assert.ok("error" in parseSetting(colours, ""))
    assert.ok("error" in parseSetting(colours, "red, nope"))
    const markers = def("PLOT_COMPARE_MARKERS")
    assert.deepEqual(parseSetting(markers, "o, square* +  x"), {
        value: ["o", "square*", "+", "x"],
    })
    assert.ok("error" in parseSetting(markers, "o circle"))
    assert.ok("error" in parseSetting(markers, " "))
    const sizes = def("PLOT_TUI_SIZES")
    const want = { value: [[76, 5], [100, 9]] }
    for (const text of ["76x5, 100x9", "76 x 5,100 × 9", "76X5 100x9"])
        assert.deepEqual(parseSetting(sizes, text), want, text)
    for (const text of ["76", "76x", "x5", "76x5x1", "ax5"])
        assert.deepEqual(parseSetting(sizes, text), {
            error: "a size is WIDTHxHEIGHT: 76x5",
        })
    assert.ok("error" in parseSetting(sizes, "100x9, 76x5"))
    assert.ok("error" in parseSetting(sizes, ""))
    // what a sheet shows is what is typed again, for the defaults and the values above
    for (const d of [colours, markers, sizes]) {
        assert.deepEqual(parseSetting(d, valueText(d, d.default)), { value: d.default })
    }
    assert.equal(valueText(sizes, [[76, 5], [100, 9]]), "76x5, 100x9")
    assert.equal(valueText(markers, ["o", "+"]), "o, +")
})

test("narrow: prefix first, then inside, case-insensitive", () => {
    const names = ["gray", "gray20", "darkgray", "red"]
    assert.deepEqual(narrow(names, ""), names)
    assert.deepEqual(narrow(names, "GR"), ["gray", "gray20"])
    assert.deepEqual(narrow(names, "dark"), ["darkgray"])
    assert.deepEqual(narrow(names, "ray"), ["gray", "gray20", "darkgray"])
    assert.deepEqual(narrow(names, "zzz"), [])
    assert.equal(indexOfPick(names, "RED"), 3)
    assert.equal(indexOfPick(names, "nothing"), 0)
})

test("picker: the highlighted name, or a typed hex colour that wins", () => {
    const names = ["gray", "red"]
    assert.deepEqual(pickValue("colour", names, "gr", "gray"), { value: "gray" })
    assert.deepEqual(pickValue("colour", names, " #AB12cd ", "red"), { value: "#AB12cd" })
    assert.deepEqual(pickValue("colour", names, "zzz", undefined), {
        error: "not a known colour",
    })
    // fonts: the highlighted name only, a hex text is no font
    assert.deepEqual(pickValue("font", ["Alpha"], "al", "Alpha"), { value: "Alpha" })
    assert.deepEqual(pickValue("font", ["Alpha"], "zz", undefined), {
        error: "not a known font",
    })
    assert.deepEqual(pickValue("font", ["Alpha"], "#ab12cd", undefined), {
        error: "not a known font",
    })
    // no list of fonts on this machine: the text as typed
    assert.deepEqual(pickValue("font", [], "My Font", undefined), { value: "My Font" })
    assert.deepEqual(pickValue("font", [], "", undefined), { error: "not a known font" })
})

test("a font is the text as typed; empty is the default font", () => {
    const font = def("PLOT_TEXT_FONT")
    assert.deepEqual(parseSetting(font, "  My Font "), { value: "My Font" })
    assert.deepEqual(parseSetting(font, ""), { value: font.default })
    assert.ok("error" in parseSetting(font, "x".repeat(101)))
})

test("a tuple is one line of comma-separated parts, checked as a whole", () => {
    const radii = def("CHAIN_START_RADII")
    assert.deepEqual(parseSetting(radii, "4, 12,20"), { value: [4, 12, 20] })
    assert.deepEqual(parseSetting(radii, "4, 12"), {
        error: "needs 3 values: first, second, third",
    })
    assert.deepEqual(parseSetting(radii, "4, x, 20"), { error: "second: a number, please" })
    const size = def("PLOT_PREVIEW_SIZE")
    assert.deepEqual(parseSetting(size, "80, 18"), { value: { width: 80, height: 18 } })
    assert.deepEqual(parseSetting(size, "80, .5"), {
        error: "height: a whole number, please",
    })
    const band = def("PLOT_COLOUR_BAND")
    assert.deepEqual(parseSetting(band, "Red, 0.5"), { value: ["red", 0.5] })
    assert.deepEqual(parseSetting(band, "#00FF00, 0.5"), { value: ["#00FF00", 0.5] })
    // the colour must exist (the opacity rule is checked at the save)
    assert.ok("error" in parseSetting(band, "nocolour, 0.5"))
})

test("optional numbers: blank, auto or none is not given", () => {
    for (const text of ["", "  ", "auto", "None", "AUTO"]) {
        assert.deepEqual(parseSetting(def("Q_MIN"), text), { value: null }, text)
        assert.deepEqual(parseSetting(def("LMAX"), text), { value: null }, text)
    }
    assert.deepEqual(parseSetting(def("Q_MIN"), "0.05"), { value: 0.05 })
    assert.deepEqual(parseSetting(def("Q_MAX"), "1e-1"), { value: 0.1 })
    assert.deepEqual(parseSetting(def("LMAX"), "12"), { value: 12 })
    assert.deepEqual(parseSetting(def("LMAX"), "2.5"), { error: "a whole number, please" })
    assert.deepEqual(parseSetting(def("Q_MIN"), "x"), { error: "a number, please" })
    assert.deepEqual(parseSetting(def("Q_MIN"), "0"), { error: "must be above 0" })
    assert.deepEqual(parseSetting(def("LMAX"), "0"), { error: "must be at least 1" })
    assert.equal(valueText(def("LMAX"), null), "auto")
    assert.equal(valueText(def("Q_MIN"), null), "none")
})

test("ranges are lo-hi pairs separated by commas; none or blank is no range", () => {
    const q = def("EXCLUDE_Q")
    assert.deepEqual(parseSetting(q, "0.1-0.2, 0.5 - 0.6"), {
        value: [[0.1, 0.2], [0.5, 0.6]],
    })
    assert.deepEqual(parseSetting(q, "1e-3-2e-3"), { value: [[0.001, 0.002]] })
    assert.deepEqual(parseSetting(q, "0-0.1"), { value: [[0, 0.1]] })
    for (const text of ["", " ", "none", "None"])
        assert.deepEqual(parseSetting(q, text), { value: [] }, text)
    assert.deepEqual(parseSetting(q, "0.2-0.1"), {
        error: "each range needs 0 <= q_lo < q_hi",
    })
    for (const text of ["0.1", "0.1-0.2-0.3", "0.1-0.2,", "-0.1-0.2", "0.1..0.2"])
        assert.ok("error" in parseSetting(q, text), text)
    assert.deepEqual(parseSetting(q, "a-0.2"), { error: "a-0.2: a number, please" })
    assert.equal(valueText(q, []), "none")
    const value = [[0.1, 0.2], [1e-7, 0.005]]
    assert.equal(valueText(q, value), "0.1-0.2, 1e-7-0.005")
    assert.deepEqual(parseSetting(q, valueText(q, value)), { value })
})

test("chains are letters or digits, split by commas, spaces or nothing", () => {
    const c = def("CHAINS")
    for (const text of ["A B", "A,B", "AB", " A , B ", "A, B"])
        assert.deepEqual(parseSetting(c, text), { value: ["A", "B"] }, text)
    assert.deepEqual(parseSetting(c, "Ab"), { value: ["A", "b"] })
    assert.deepEqual(parseSetting(c, "A a"), { value: ["A", "a"] })
    for (const text of ["", "  ", "all", "ALL"])
        assert.deepEqual(parseSetting(c, text), { value: [] }, text)
    assert.deepEqual(parseSetting(c, "A A"), { error: "must not repeat a chain" })
    assert.deepEqual(parseSetting(c, "AA"), { error: "must not repeat a chain" })
    assert.equal(valueText(c, []), "all")
    assert.equal(valueText(c, ["A", "b"]), "A, b")
    assert.deepEqual(parseSetting(c, valueText(c, ["A", "b"])), { value: ["A", "b"] })
})

test("a tuple with a colour part is edited part by part and checked as a whole", () => {
    for (const name of [
        "PLOT_COLOUR_ERRORBAR",
        "PLOT_COLOUR_BAND",
        "PLOT_COLOUR_BAND_RESID",
        "PLOT_COLOUR_HIST",
    ])
        assert.ok(hasColourPart(def(name)), name)
    for (const name of ["PLOT_WIDTH_HEIGHT_CM", "PLOT_PREVIEW_SIZE", "N_ADAPT"])
        assert.ok(!hasColourPart(def(name)), name)
    const band = def("PLOT_COLOUR_BAND")
    assert.deepEqual(tupleParts(band, ["darkorange", 0.15]), ["darkorange", 0.15])
    // the colour part is a name, a code or a notation; the other part a number
    assert.deepEqual(finishTuple(band, ["Sky Blue", 0.5]), { value: ["skyblue", 0.5] })
    assert.deepEqual(finishTuple(band, ["#0AF", 1]), { value: ["#0AF", 1] })
    assert.deepEqual(finishTuple(band, ["nocolour", 0.5]), {
        error: "a part must be a colour",
    })
    // a colour Julia does not read by name is kept as #rrggbb
    assert.deepEqual(finishTuple(band, ["nunavut yellow", 0.5]), {
        value: ["#e7a615", 0.5],
    })
    assert.deepEqual(parsePart("float", "0.25"), { value: 0.25 })
    assert.ok("error" in parsePart("float", "x"))
    assert.ok("error" in parsePart("int", "0.5"))
    // the stored shape is unchanged: an array of [colour, number]
    assert.ok(Array.isArray(tupleOf(band, ["red", 0.3])))
    assert.deepEqual(tupleOf(def("PLOT_PREVIEW_SIZE"), [70, 18]), { width: 70, height: 18 })
})

test("valueText and swatchColour", () => {
    assert.equal(valueText(def("FIGURES_FORMATS"), ["pdf", "png"]), "pdf png")
    assert.equal(valueText(def("PLOT_PREVIEW_SIZE"), { width: 70, height: 18 }), "70, 18")
    const band = def("PLOT_COLOUR_BAND")
    assert.equal(valueText(band, ["darkorange", 0.15]), "darkorange, 0.15")
    assert.equal(valueText(def("N_ADAPT"), 1000), "1000")
    assert.equal(swatchColour(def("PLOT_COLOUR_BAND"), ["darkorange", 0.15]), "darkorange")
    assert.equal(swatchColour(def("N_ADAPT"), 1000), undefined)
})

test("valueText says yes or no for a yes/no setting", () => {
    const flag = catalog.defs().find((d) => d.kind === "bool")
    assert.ok(flag !== undefined)
    assert.equal(valueText(flag, true), "yes")
    assert.equal(valueText(flag, false), "no")
})

test("withDraft: no draft when the value is the saved one", () => {
    const none = new Map<string, number>()
    const d1 = withDraft(none, "A", 1, 2)
    assert.deepEqual([...d1], [["A", 2]])
    assert.equal(withDraft(d1, "A", 1, 1).size, 0)
    assert.equal(withDraft(none, "A", [1, 2], [1, 2]).size, 0)
    assert.equal(withDraft(none, "A", { x: 1 }, { x: 2 }).size, 1)
    // the original is not changed
    assert.equal(d1.size, 1)
})

// ========================================================================================
// 2. Tables and forms
// ========================================================================================

/** Facts of a table with rows, the cursor in the middle, nothing unsaved. */
const base: TableFacts = {
    rows: 3,
    cursor: 1,
    canEdit: true,
    canAdd: true,
    locked: false,
    canRemove: true,
    canUndo: false,
    dirty: false,
}
const adds = [legendFor("add", keys.addNonbio)]
const keysOf = (items: { keys: string }[]) => items.map((i) => i.keys)

test("table legend: a locked table changes nothing", () => {
    const locked = tableLegend(
        {
            ...base,
            locked: true,
            canEdit: false,
            canAdd: false,
            dirty: true,
            canUndo: true,
        },
        adds,
    )
    assert.deepEqual(
        locked.map((i) => i.label),
        ["back", "move"],
    )
})

test("entry legend: move for several entries, tab for a highlighted one", () => {
    const none = entryLegend({ count: 0, pick: true })
    assert.deepEqual(keysOf(none), ["esc"])
    const one = entryLegend({ count: 1, pick: true })
    assert.deepEqual(keysOf(one), ["⏎", "tab", "esc"])
    const many = entryLegend({ count: 4, pick: true })
    assert.deepEqual(keysOf(many), ["⏎", "↑↓", "tab", "esc"])
    // a plain prompt always takes its text
    assert.deepEqual(keysOf(entryLegend({ count: 0 })), ["⏎", "esc"])
    assert.deepEqual(keysOf(entryLegend({ count: 0, canTake: false })), ["esc"])
    const del = [legendFor("delete", keys.remove)]
    const extra = entryLegend({ count: 2, pick: true, extras: del })
    assert.deepEqual(keysOf(extra), ["⏎", "↑↓", "tab", "^r", "esc"])
    // keys that need an entry are dropped for none; a browsed list has no take
    const listed = { count: 0, pick: true, listedExtras: del }
    assert.deepEqual(keysOf(entryLegend(listed)), ["esc"])
    const listedOne = entryLegend({ ...listed, count: 1 })
    assert.deepEqual(keysOf(listedOne), ["⏎", "tab", "^r", "esc"])
    const browsed = entryLegend({
        count: 3,
        pick: true,
        take: null,
        cancel: "close",
        back: true,
    })
    assert.deepEqual(
        browsed.map((i) => i.label),
        ["move", "complete", "close", "back"],
    )
})

test("a question is a value; its note and legend come from the same fields", () => {
    const q = destructiveQuestion("model x")
    const text = "delete model x? this cannot be undone!"
    assert.deepEqual(q, { text, yes: "delete", no: "keep" })
    // a wording change of the question cannot turn the legend into yes/no
    const other = { text: "go on?", yes: "go", no: "stay" }
    assert.deepEqual(questionLegend(other).map((i) => i.label), ["go", "stay"])
})

test("question legend reads the answers from the question", () => {
    assert.deepEqual(questionLegend(destructiveQuestion("model x")), [
        legendFor("delete", keys.enter),
        legendFor("keep", keys.escape),
    ])
    const sure = questionLegend({ text: "sure?", yes: "yes", no: "no" })
    assert.deepEqual(keysOf(sure), ["⏎", "esc"])
})

test("form legend: accept only when complete, undo only on a changed cell", () => {
    const f = {
        editing: false,
        moves: { up: true },
        canRestore: false,
        complete: false,
        acceptLabel: "add to table",
    }
    assert.deepEqual(keysOf(formLegend(f)), ["esc", "⏎", "↑"])
    const ready = formLegend({ ...f, complete: true, canRestore: true })
    assert.deepEqual(keysOf(ready), ["esc", "^w", "⏎", "↑", "^u"])
    assert.equal(ready[1]?.label, "add to table")
    assert.deepEqual(keysOf(formLegend({ ...f, editing: true })), ["⏎", "esc"])
})

// ========================================================================================
// 3. The file viewer
// ========================================================================================

const all = { up: true, down: true, left: true, right: true }
const facts = {
    plots: false,
    sheets: 3,
    active: 1,
    hasPlots: true,
    move: all,
    zoom: { in: true, out: true },
    cells: false,
    marked: false,
    hasFormulas: false,
    matches: false,
}
const labels = (f = facts) => viewerLegend(f).map((i) => i.label)

test("the legend lists only keys that work now", () => {
    const one = { ...facts, sheets: 1, active: 0, hasPlots: false }
    assert.deepEqual(labels(one), ["move", "back"])
    assert.deepEqual(labels(), ["next sheet", "prev sheet", "move", "plots", "back"])
    // the keys are written the way they are pressed
    const keysOf = (f = facts) => viewerLegend(f).map((i) => `${i.label}=${i.keys}`)
    assert.ok(keysOf().includes("next sheet=tab"))
    assert.ok(keysOf().includes("prev sheet=shift+tab"))
    assert.ok(keysOf({ ...facts, plots: true }).includes("zoom in=shift++"))
    // the first tab has no previous one, the last has no next one
    assert.ok(!labels({ ...facts, active: 0 }).includes("prev sheet"))
    assert.ok(!labels({ ...facts, active: 2 }).includes("next sheet"))
    // an arrow that cannot move is not shown
    const top = { ...facts, move: { ...all, up: false, left: false } }
    assert.deepEqual(viewerLegend(top).find((i) => i.label === "move")?.keys, "↓→")
    // the plots mode: plots are named, zoom keys appear when a size exists
    const plots = labels({ ...facts, plots: true })
    assert.deepEqual(plots, [
        "next plot", "prev plot", "move", "zoom in", "zoom out", "sheets", "back",
    ])
    assert.ok(!labels({ ...facts, plots: true, zoom: { in: false, out: true } })
        .includes("zoom in"))
    assert.ok(!labels({ ...facts, plots: true, hasPlots: false }).includes("sheets"))
})

test("sheet keys: find, go to, mark, copy; formulas and matches when they work", () => {
    const sheets = { ...facts, cells: true }
    assert.deepEqual(labels(sheets), [
        "next sheet", "prev sheet", "move", "find", "go to", "mark", "copy",
        "plots", "back",
    ])
    const pressed = (f = sheets) => viewerLegend(f).map((i) => `${i.label}=${i.keys}`)
    assert.ok(pressed().includes("find=/"))
    assert.ok(pressed().includes("go to=j"))
    assert.ok(pressed().includes("mark=␣"))
    assert.ok(pressed().includes("copy=c"))
    const more = { ...sheets, hasFormulas: true, matches: true, marked: true }
    assert.ok(pressed(more).includes("formulas=f"))
    assert.ok(pressed(more).includes("next match=."))
    assert.ok(pressed(more).includes("prev match=,"))
    assert.ok(pressed(more).includes("unmark=␣"))
    assert.ok(!labels(more).includes("mark"))
    // the plots mode has none of them
    assert.ok(!labels({ ...more, plots: true }).includes("find"))
    // the fullest legend holds them all
    const full = viewerFullLegend({ hasPlots: true }).map((i) => i.label)
    const wanted = ["find", "go to", "unmark", "copy", "formulas", "next match"]
    for (const l of [...wanted, "prev match"]) assert.ok(full.includes(l), l)
})

test("the fullest viewer legend leaves the grid room at 80x24", () => {
    // frame 7 + tabs/status 4 + letters 2 + header 2 = 15 rows besides the extra bands;
    // 78 is the body width of an 80-column terminal: the 12 keys stay in one band
    const extra = legendExtraRows(viewerFullLegend({ hasPlots: true }), 78, "smooth")
    assert.equal(extra, 0)
    assert.ok(24 - 15 - extra >= 8)
})

// ========================================================================================
// 4. The custom solutes' text
// ========================================================================================

/** The polymer of the documentation: two kinds of unit and end groups. */
const polymer: PolymerEntry = {
    ...blankPolymer(),
    name: "chain-2",
    units: [
        { label: "A", formula: "C2H4O", z: 24, slope: 36.9, sigma: null },
        { label: "B", formula: "C3H6O", z: 32, slope: 53.1, sigma: null },
    ],
    "zEnds": 10,
    "pmvEnds": 9,
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
        "pmvEnds": 3,
        "zEnds": null,
    }
    assert.equal(pmvCell(e), "-5.2A+3")
    assert.equal(zCell(e), "24A")
    assert.equal(formulaCell(e), "")
    assert.equal(pmvCell({ ...e, "pmvEnds": -3 }), "-5.2A-3")
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

// the shared fixture, its `custom-polymer` rows included (Julia reads them too)
const rows = fixture("buffer/buffer.json").solutes as BufferRow[]

test("a file row and a draft are the same solute", () => {
    for (const row of rows) {
        const s = soluteOf(row)
        assert.equal("sigmaMm" in s, false)
        assert.equal(s.sigmaMM, row.sigmaMm)
        assert.deepEqual(rowOf(s), row, row.name)
        assert.equal(soluteProblem(s), undefined, row.name)
        assert.equal(rowProblem(rowOf(s)), undefined)
    }
    const zero = { ...soluteOf(rows[0] as BufferRow), mM: 0 }
    assert.equal(soluteProblem(zero), "mM must be above 0")
})

test("model drafts: a value equal to the project's removes an override", () => {
    const project = 450
    const sheet = (saved: boolean, now: number) => ({
        get: () => now,
        isSaved: () => saved,
        resetValue: () => project,
    })
    const none = new Map<string, number>()
    // no override: the project's value again is no change, another value is one
    assert.equal(withModelDraft(none, "N_ADAPT", sheet(false, 450), 450).size, 0)
    const other = withModelDraft(none, "N_ADAPT", sheet(false, 450), 500)
    assert.equal(other.get("N_ADAPT"), 500)
    // an override of 500: the project's value is a change (saving removes the override),
    // the same 500 is none
    assert.equal(withModelDraft(none, "N_ADAPT", sheet(true, 500), 450).get("N_ADAPT"), 450)
    assert.equal(withModelDraft(none, "N_ADAPT", sheet(true, 500), 500).size, 0)
    // an override that equals the project's value can still be removed
    assert.equal(withModelDraft(none, "N_ADAPT", sheet(true, 450), 450).get("N_ADAPT"), 450)
})

// ========================================================================================
// 5. The words of the recipes and the landings
// ========================================================================================

const labelsOf = (b: number | "unusable", c: number | "unusable" = 0) =>
    bufferLandingOptions(b, c).map((o) => o.label)

test("the buffer landing offers what applies", () => {
    assert.deepEqual(labelsOf(0), [
        "buffer (0 solutes)",
        "custom solutes (0)",
        "load a recipe",
        "new recipe",
    ])
    assert.deepEqual(labelsOf("unusable", "unusable"), [
        "buffer (?)",
        "custom solutes (?)",
        "load a recipe",
        "new recipe",
    ])
    assert.deepEqual(labelsOf(1, 3), [
        "buffer (1 solute)",
        "custom solutes (3)",
        "load a recipe",
        "new recipe",
        "save current recipe globally",
    ])
    assert.deepEqual(
        bufferLandingOptions(12, 0).map((o) => o.id),
        ["buffer", "custom", "load", "new", "save"],
    )
})

test("the landings say what their files hold", () => {
    assert.equal(fileStatus("recipes", 0, "recipe"), "recipes: none yet")
    assert.equal(fileStatus("recipes", 1, "recipe"), "recipes: 1 recipe")
    assert.equal(fileStatus("recipes", 3, "recipe"), "recipes: 3 recipes")
    assert.equal(fileStatus("custom solutes", 0, "solute"), "custom solutes: none yet")
    assert.equal(fileStatus("a", "unusable", "solute"), "a: unusable!")
})

test("the recipe words", () => {
    assert.equal(plural(1, "solute"), "1 solute")
    assert.equal(plural(12, "solute"), "12 solutes")
    assert.equal(recipeChoice("SEC buffer", 3), "SEC buffer (3)")
    assert.equal(unusable("recipes.json"), "recipes.json unusable!")
    assert.equal(savedAs("SEC", 40), 'saved as "SEC"')
    assert.equal(NO_RECIPES, "no saved recipes!")
})

test("the replace questions fit their room and keep the name when they can", () => {
    const q = replaceBufferQuestion(1, "r1", 60)
    assert.equal(q.text, 'replace 1 solute with recipe "r1"?')
    assert.deepEqual([q.yes, q.no], ["replace", "keep"])
    assert.ok(replaceBufferQuestion(11, "SEC", 80).text.startsWith("replace 11 solutes"))
    assert.equal(replaceRecipeQuestion("my BUFFER", 60).text, 'replace "my BUFFER"?')
    const long = "a very long recipe name that cannot fit anywhere near the room"
    for (const room of [22, 30, 40]) {
        assert.ok(displayWidth(replaceRecipeQuestion(long, room).text) <= room, `${room}`)
        assert.ok(displayWidth(replaceBufferQuestion(999, long, room).text) <= room + 30)
        assert.ok(displayWidth(savedAs(long, room)) <= room, `saved as ${room}`)
    }
    // the name keeps at least 8 cells however small the room
    assert.ok(replaceRecipeQuestion(long, 5).text.length >= 'replace ""?'.length + 8)
    assert.equal(fitName("abc", 20, 5), "abc")
})

test("a loaded recipe's pH and σ are an unsaved draft of the buffer", () => {
    const own = { pH: 7, "sigmaPh": 0.1 }
    const recipe = { pH: 6.8, "sigmaPh": 0.05 }
    assert.deepEqual(draftOf(recipe, own), recipe, "the recipe's, unsaved")
    assert.deepEqual(draftOf(recipe, undefined), recipe, "a buffer without any")
    assert.equal(draftOf(undefined, own), undefined, "a recipe without leaves the own")
    assert.equal(draftOf(undefined, undefined), undefined)
    assert.equal(draftOf({ ...own }, own), undefined, "the same is no change")
})

test("a recipe's temperature is a draft; one without leaves the table's own", () => {
    const own = { pH: 7, "sigmaPh": 0.1, temperature: 4 }
    const cold = { pH: 6.8, "sigmaPh": 0.05, temperature: 10 }
    assert.deepEqual(draftOf(cold, own), cold, "the recipe's temperature, unsaved")
    // a recipe with a pH but no temperature keeps the table's temperature
    const bare = { pH: 6.8, "sigmaPh": 0.05 }
    assert.deepEqual(draftOf(bare, own), { ...bare, temperature: 4 })
    assert.equal(draftOf({ pH: 7, "sigmaPh": 0.1 }, own), undefined, "same pH: no change")
    // a table without a temperature takes the recipe's, or stays without
    assert.deepEqual(draftOf(cold, { pH: 7, "sigmaPh": 0.1 }), cold)
    assert.deepEqual(draftOf(bare, { pH: 7, "sigmaPh": 0.1 }), bare)
})

test("table legend: find and sort follow the row keys, the adds come last", () => {
    const more = [legendFor("find", keys.find)]
    const withMore = tableLegend(base, adds, "edit", more)
    const labels = withMore.map((i) => i.label)
    assert.ok(labels.indexOf("find") < labels.indexOf(adds[0]?.label ?? ""), "adds last")
    assert.equal(tableLegend(base, adds).some((i) => i.label === "find"), false)
})
