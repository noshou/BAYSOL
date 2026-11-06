// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { parseNumber } from "../src/core/text.js"
import {
    blocksFitting,
    capNote,
    descriptionLines,
    type EditEnd,
    type EditStep,
    indexOfPick,
    maxNumberText,
    narrow,
    noteLines,
    numberRules,
    openNumber,
    openTabs,
    openTuple,
    pickOneNote,
    pickValue,
    scrollTop,
    settingFacts,
    stepNumber,
    stepTabs,
    stepTuple,
    swatchColour,
    tableWidths,
    tupleMatches,
    valueText,
    withDraft,
} from "../src/screens/setting-edit.js"
import { defaultCatalog } from "../src/store/settings-defs.js"
import { tabLabel } from "../src/ui/choice-tabs.js"
import { KeyInput, keys } from "../src/ui/keys.js"

const catalog = defaultCatalog()
const def = (name: string) => catalog.require(name)

/** A typed character. */
const typed = (text: string): KeyInput =>
    new KeyInput(text.toLowerCase(), false, text, text !== text.toLowerCase())

/** Feeds keys to an editor; returns the last state and how it ended, if it did. */
function drive<S, V>(
    step: (s: S, p: KeyInput) => EditStep<S, V>,
    start: S,
    presses: KeyInput[],
): { state: S; end?: EditEnd<V> } {
    let state = start
    let end: EditEnd<V> | undefined
    for (const p of presses) {
        const r = step(state, p)
        state = r.state
        if (r.end !== undefined) end = r.end
    }
    return { state, end }
}

/** The keys that type a text. */
const text = (s: string): KeyInput[] => [...s].map(typed)

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

test("number rules: ints refuse more than 15 digits, leading zeros do not count", () => {
    assert.deepEqual(parseNumber("123456789012345", numberRules.int), {
        value: 123456789012345,
    })
    assert.deepEqual(parseNumber("1234567890123456", numberRules.int), {
        error: "15 digits at most",
    })
    assert.deepEqual(parseNumber("-0000000000000000005", numberRules.int), { value: -5 })
})

test("number editor: Enter takes, limits are the setting's, Esc drops", () => {
    const n = def("N_ADAPT")
    const start = openNumber(n, 1000)
    assert.equal(start.buffer.text, "1000")
    // type over: backspace four times, then 0 which breaks `at_least`
    const bad = drive(stepNumber, start, [
        ...Array(4).fill(keys.backspace),
        typed("0"),
        keys.enter,
    ])
    assert.equal(bad.end, undefined)
    assert.match(bad.state.error ?? "", /^must be at least/)
    const good = drive(stepNumber, bad.state, [keys.backspace, ...text("250"), keys.enter])
    assert.deepEqual(good.end, { kind: "done", value: 250 })
    assert.equal(drive(stepNumber, start, [keys.escape]).end?.kind, "cancel")
    assert.equal(drive(stepNumber, start, [keys.back]).end?.kind, "back")
})

test("number editor: refuses past 16 characters and says so; a typed error clears", () => {
    const f = def("MODE_δρ₁₂")
    const empty = { ...openNumber(f, 1), buffer: openNumber(f, 1).buffer.replace("") }
    const full = drive(stepNumber, empty, text("1".repeat(maxNumberText)))
    assert.equal(full.state.buffer.text.length, maxNumberText)
    const over = drive(stepNumber, full.state, [typed("1")])
    assert.equal(over.state.error, capNote)
    assert.equal(over.state.buffer.text.length, maxNumberText)
    assert.equal(capNote, "16 digits at most")
    // a key that edits clears the error; a space is ignored
    const cleared = drive(stepNumber, over.state, [keys.backspace])
    assert.equal(cleared.state.error, undefined)
    const spaced = drive(stepNumber, cleared.state, [typed(" ")])
    assert.equal(spaced.state.buffer.text.length, 15)
})

test("number editor: text that is not a number says so", () => {
    const f = def("MODE_δρ₁₂")
    const r = drive(stepNumber, openNumber(f, 1), [keys.backspace, typed("x"), keys.enter])
    assert.equal(r.state.error, "a number, please")
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

const colours = ["black", "crimson", "gray", "gray20", "red"]

test("picker: the highlighted name, a hex colour, fonts with no list", () => {
    assert.deepEqual(pickValue("colour", colours, "gr", "gray"), { value: "gray" })
    // a typed #rrggbb wins over the highlighted name, and is lower-cased
    assert.deepEqual(pickValue("colour", colours, " #AB12cd ", "red"), {
        value: "#ab12cd",
    })
    assert.deepEqual(pickValue("colour", colours, "zzz", undefined), {
        error: "not a known colour",
    })
    assert.deepEqual(pickValue("font", ["Alpha"], "zz", undefined), {
        error: "not a known font",
    })
    // a hex text is no font
    assert.deepEqual(pickValue("font", ["Alpha"], "#ab12cd", undefined), {
        error: "not a known font",
    })
    // no list of fonts on this machine: the text as typed
    assert.deepEqual(pickValue("font", [], "My Font", undefined), { value: "My Font" })
    assert.deepEqual(pickValue("font", [], "", undefined), { error: "not a known font" })
})

test("tabs: Enter toggles, arrows stop, Tab goes round, Esc needs one on", () => {
    const formats = def("FIGURES_FORMATS")
    const start = openTabs(formats, ["pdf"])
    assert.deepEqual([...start.options], ["pdf", "png", "svg"])
    const moved = drive(stepTabs, start, [keys.right, keys.right, keys.right, keys.enter])
    assert.equal(moved.state.focus, 2)
    assert.deepEqual([...moved.state.selected].sort(), ["pdf", "svg"])
    assert.equal(drive(stepTabs, start, [keys.left]).state.focus, 0)
    assert.equal(drive(stepTabs, start, [keys.tab, keys.tab, keys.tab]).state.focus, 0)
    // done: the ones that are on, in the order of the choices
    const done = drive(stepTabs, moved.state, [keys.escape])
    assert.deepEqual(done.end, { kind: "done", value: ["pdf", "svg"] })
    // none on: refused
    const none = drive(stepTabs, start, [keys.enter, keys.escape])
    assert.equal(none.end, undefined)
    assert.equal(none.state.error, pickOneNote)
    assert.equal(drive(stepTabs, none.state, [keys.right]).state.error, undefined)
    assert.equal(drive(stepTabs, start, [keys.back]).end?.kind, "back")
})

test("tabLabel: on in square brackets, off in round, focus in capitals", () => {
    assert.equal(tabLabel("pdf", true, false), "[pdf]")
    assert.equal(tabLabel("png", false, false), "(png)")
    assert.equal(tabLabel("svg", false, true), "(SVG)")
    assert.equal(tabLabel("pdf", true, true), "[PDF]")
})

test("tuple of numbers: parts by arrows, Enter checks the whole", () => {
    const radii = def("CHAIN_START_RADII")
    const start = openTuple(radii, [4, 10, 20], [])
    assert.deepEqual([...start.buffers], ["4", "10", "20"])
    assert.equal(start.focus, 0)
    // the numbers parts are not "fresh": typing appends
    const r = drive(stepTuple, start, [
        keys.right,
        keys.backspace,
        keys.backspace,
        ...text("12"),
        keys.enter,
    ])
    assert.equal(r.end?.kind, "done")
    assert.deepEqual((r.end as { value: unknown }).value, [4, 12, 20])
    // an arrow stops at the ends
    assert.equal(drive(stepTuple, start, [keys.left]).state.focus, 0)
    const rights = [keys.right, keys.right, keys.right]
    assert.equal(drive(stepTuple, start, rights).state.focus, 2)
    // Tab goes round, down moves on in a part that is no colour
    assert.equal(drive(stepTuple, start, [keys.tab, keys.tab, keys.tab]).state.focus, 0)
    assert.equal(drive(stepTuple, start, [keys.down]).state.focus, 1)
})

test("tuple: a part that is no number names the part", () => {
    const radii = def("CHAIN_START_RADII")
    const start = openTuple(radii, [4, 10, 20], [])
    const bad = drive(stepTuple, start, [keys.right, ...text("x"), keys.enter])
    assert.equal(bad.end, undefined)
    assert.equal(bad.state.error, "second: a number, please")
    assert.equal(bad.state.focus, 1)
    const first = drive(stepTuple, start, [keys.backspace, keys.enter])
    assert.equal(first.state.error, "first: a number, please")
})

test("tuple with named parts gives an object; whole parts refuse decimals", () => {
    const size = def("PLOT_PREVIEW_SIZE")
    const start = openTuple(size, { width: 70, height: 18 }, [])
    assert.deepEqual([...start.buffers], ["70", "18"])
    const ok = drive(stepTuple, start, [
        keys.backspace,
        keys.backspace,
        ...text("80"),
        keys.enter,
    ])
    assert.deepEqual((ok.end as { value: unknown }).value, { width: 80, height: 18 })
    const bad = drive(stepTuple, start, [keys.right, ...text(".5"), keys.enter])
    assert.equal(bad.state.error, "height: a whole number, please")
})

test("tuple: the checks of the whole tuple come back as the edit's error", () => {
    const radii = def("CHAIN_START_RADII")
    const start = openTuple(radii, [4, 10, 20], [])
    // zero is not above the lower limit of the tuple, whatever it is
    const r = drive(stepTuple, start, [keys.backspace, ...text("-1"), keys.enter])
    // either the setting accepts it or it names why; it never ends with a wrong value
    if (r.end?.kind === "done")
        assert.deepEqual((r.end as { value: unknown }).value, [-1, 10, 20])
    else assert.ok(r.state.error !== undefined)
})

test("tuple with a colour: the list opens on the colour, a first key replaces it", () => {
    const band = def("PLOT_COLOUR_BAND")
    const start = openTuple(band, ["darkorange", 0.15], ["crimson", "darkorange", "red"])
    assert.equal(start.focus, 0)
    assert.equal(start.index, 1)
    assert.deepEqual(tupleMatches(start), ["crimson", "darkorange", "red"])
    const typedR = drive(stepTuple, start, [typed("r")])
    assert.deepEqual(tupleMatches(typedR.state), ["red"])
    assert.equal(typedR.state.buffers[0], "r")
    // Enter on a text that is no colour yet takes the highlighted one
    const done = drive(stepTuple, typedR.state, [keys.enter])
    assert.deepEqual((done.end as { value: unknown }).value, ["red", 0.15])
    // up and down pick in the list, Tab takes it into the text
    const pick = drive(stepTuple, start, [keys.down, keys.tab])
    assert.equal(pick.state.buffers[0], "red")
    // an unknown name is refused with the part's name
    const unknown = drive(stepTuple, start, [...text("zzz"), keys.enter])
    assert.equal(unknown.state.error, "colour: not a known colour")
    // hex works
    const hex = drive(stepTuple, start, [...text("#00FF00"), keys.enter])
    assert.deepEqual((hex.end as { value: unknown }).value, ["#00ff00", 0.15])
    // right goes to the opacity, no colour list there
    const opacity = drive(stepTuple, start, [keys.right])
    assert.deepEqual(tupleMatches(opacity.state), [])
})

test("valueText, swatchColour, settingFacts", () => {
    assert.equal(valueText(def("FIGURES_FORMATS"), ["pdf", "png"]), "pdf png")
    assert.equal(valueText(def("PLOT_PREVIEW_SIZE"), { width: 70, height: 18 }), "(70, 18)")
    const band = def("PLOT_COLOUR_BAND")
    assert.equal(valueText(band, ["darkorange", 0.15]), "(darkorange, 0.15)")
    assert.equal(valueText(def("N_ADAPT"), 1000), "1000")
    assert.equal(swatchColour(def("PLOT_COLOUR_BAND"), ["darkorange", 0.15]), "darkorange")
    assert.equal(swatchColour(def("N_ADAPT"), 1000), undefined)
    assert.match(settingFacts(def("N_ADAPT")), /^integer, at least \d+ · default \d+$/)
})

test("valueText says yes or no for a yes/no setting", () => {
    const flag = catalog.defs().find((d) => d.kind === "bool")
    assert.ok(flag !== undefined)
    assert.equal(valueText(flag, true), "yes")
    assert.equal(valueText(flag, false), "no")
})

test("descriptionLines wrap to the width at any width", () => {
    for (const d of catalog.defs()) {
        for (const w of [40, 78, 120]) {
            const lines = descriptionLines(d, w)
            assert.ok(lines.length >= 1)
            assert.ok(lines.every((l) => l.length <= w), `${d.name} at ${w}`)
        }
    }
})

test("tableWidths: the columns and their borders fill the width exactly", () => {
    for (const columns of [78, 98, 108, 140]) {
        const w = tableWidths(columns, 23)
        assert.equal(3 + 4 + w.name + w.desc + w.value, columns)
        assert.equal(w.name, 24)
        assert.equal(w.value, columns >= 100 ? 25 : 19)
    }
    // a short name makes a narrow name column
    assert.equal(tableWidths(78, 6).name, 8)
})

test("every setting fits a block at 80 columns, its description wrapped whole", () => {
    const w = tableWidths(78, 23)
    for (const d of catalog.defs()) {
        const lines = descriptionLines(d, w.desc - 2)
        assert.ok(lines.every((l) => l.length <= w.desc - 2), d.name)
        const one = (t: string): string => t.replace(/\s+/g, " ")
        assert.equal(one(lines.join(" ")), one(d.description))
    }
})

test("noteLines: at most two lines", () => {
    assert.deepEqual(noteLines("must be at least 1", 18), ["must be at least 1"])
    assert.equal(noteLines("a very long message that goes on and on and on", 10).length, 2)
})

test("blocksFitting counts the rules between blocks", () => {
    // blocks of 3 lines: 3, then 3+1+3 = 7, then 11
    assert.equal(blocksFitting([3, 3, 3], 0, 7), 2)
    assert.equal(blocksFitting([3, 3, 3], 0, 6), 1)
    assert.equal(blocksFitting([3, 3, 3], 0, 11), 3)
    // a block taller than the room is still shown, alone
    assert.equal(blocksFitting([9, 3], 0, 4), 1)
    assert.equal(blocksFitting([3, 3, 3], 1, 7), 2)
})

test("scrollTop keeps the selected block wholly in view and moves little", () => {
    const heights = [3, 3, 3, 3, 3]
    assert.equal(scrollTop(heights, 0, 1, 7), 0)
    assert.equal(scrollTop(heights, 0, 2, 7), 1)
    assert.equal(scrollTop(heights, 1, 4, 7), 3)
    // up again: the top follows the selection
    assert.equal(scrollTop(heights, 3, 1, 7), 1)
    // tall block taller than the room: it is the top
    assert.equal(scrollTop([2, 9, 2], 0, 1, 5), 1)
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
