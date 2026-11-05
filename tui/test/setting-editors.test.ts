// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    capNote,
    descriptionLines,
    type EditEnd,
    firstOfGroup,
    groupJump,
    groupSettings,
    hexOf,
    indexOfName,
    maxNumberText,
    narrow,
    nextSetting,
    openNumber,
    openPicker,
    openTabs,
    openTuple,
    parseNumberText,
    pickerMatches,
    pickOneNote,
    type Step,
    settingFacts,
    sheetRows,
    stepNumber,
    stepPicker,
    stepTabs,
    stepTuple,
    swatchColour,
    tupleMatches,
    valueText,
    windowStart,
    withDraft,
} from "../src/screens/setting-edit.js"
import { defaultCatalog } from "../src/store/settings-defs.js"
import { tabLabel } from "../src/ui/choice-tabs.js"
import { KeyInput, keys } from "../src/ui/keys.js"

const catalog = defaultCatalog()
const def = (name: string) => catalog.require(name)

/** A typed character. */
const typed = (text: string): KeyInput => new KeyInput(text.toLowerCase(), false, text)

/** Feeds keys to an editor; returns the last state and how it ended, if it did. */
function drive<S, V>(
    step: (s: S, p: KeyInput) => Step<S, V>,
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

test("parseNumberText: whole numbers and decimals", () => {
    assert.deepEqual(parseNumberText("int", "12"), { value: 12 })
    assert.deepEqual(parseNumberText("int", "-3"), { value: -3 })
    assert.deepEqual(parseNumberText("int", "2.5"), { error: "a whole number, please" })
    assert.deepEqual(parseNumberText("int", ""), { error: "a whole number, please" })
    assert.deepEqual(parseNumberText("float", "1e-3"), { value: 0.001 })
    assert.deepEqual(parseNumberText("float", "5"), { value: 5 })
    assert.deepEqual(parseNumberText("float", ".5"), { value: 0.5 })
    assert.deepEqual(parseNumberText("float", "x"), { error: "a number, please" })
    assert.deepEqual(parseNumberText("float", ""), { error: "a number, please" })
    assert.deepEqual(parseNumberText("float", "1e999"), { error: "a number, please" })
})

test("parseNumberText: ints refuse more than 15 digits, leading zeros do not count", () => {
    assert.deepEqual(parseNumberText("int", "123456789012345"), { value: 123456789012345 })
    assert.deepEqual(parseNumberText("int", "1234567890123456"), {
        error: "15 digits at most",
    })
    assert.deepEqual(parseNumberText("int", "-0000000000000000005"), { value: -5 })
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
    assert.equal(indexOfName(names, "RED"), 3)
    assert.equal(indexOfName(names, "nothing"), 0)
})

const colours = ["black", "crimson", "gray", "gray20", "red"]

test("picker: type to narrow, up and down go round, Enter picks, Tab completes", () => {
    const start = openPicker("colour", colours, "gray")
    assert.equal(start.index, 2)
    const typedGr = drive(stepPicker, start, text("gr"))
    assert.deepEqual(pickerMatches(typedGr.state), ["gray", "gray20"])
    assert.equal(typedGr.state.index, 0)
    const down = drive(stepPicker, typedGr.state, [keys.down, keys.enter])
    assert.deepEqual(down.end, { kind: "done", value: "gray20" })
    // wraps upward from the first
    const up = drive(stepPicker, typedGr.state, [keys.up, keys.enter])
    assert.deepEqual(up.end, { kind: "done", value: "gray20" })
    // Tab takes the highlighted name into the text
    const tab = drive(stepPicker, typedGr.state, [keys.down, keys.tab])
    assert.equal(tab.state.buffer.text, "gray20")
    assert.deepEqual(pickerMatches(tab.state), ["gray20"])
})

test("picker: unknown names, hex colours, fonts with no list", () => {
    const none = drive(stepPicker, openPicker("colour", colours, "red"), [
        ...text("zzz"),
        keys.enter,
    ])
    assert.equal(none.state.error, "not a known colour")
    assert.equal(none.end, undefined)
    const hex = drive(stepPicker, openPicker("colour", colours, "red"), [
        ...text("#AB12cd"),
        keys.enter,
    ])
    assert.deepEqual(hex.end, { kind: "done", value: "#ab12cd" })
    const font = drive(stepPicker, openPicker("font", ["Alpha"], "Alpha"), [
        ...text("zz"),
        keys.enter,
    ])
    assert.equal(font.state.error, "not a known font")
    const noList = openPicker("font", [], "x")
    const offline = drive(stepPicker, noList, [...text("My Font"), keys.enter])
    assert.deepEqual(offline.end, { kind: "done", value: "My Font" })
    assert.equal(drive(stepPicker, noList, [keys.enter]).state.error, "not a known font")
    const red = openPicker("colour", colours, "red")
    assert.equal(drive(stepPicker, red, [keys.escape]).end?.kind, "cancel")
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

test("valueText, swatchColour, hexOf, settingFacts", () => {
    assert.equal(valueText(def("FIGURES_FORMATS"), ["pdf", "png"]), "pdf png")
    assert.equal(valueText(def("PLOT_PREVIEW_SIZE"), { width: 70, height: 18 }), "(70, 18)")
    const band = def("PLOT_COLOUR_BAND")
    assert.equal(valueText(band, ["darkorange", 0.15]), "(darkorange, 0.15)")
    assert.equal(valueText(def("N_ADAPT"), 1000), "1000")
    assert.equal(swatchColour(def("PLOT_COLOUR_BAND"), ["darkorange", 0.15]), "darkorange")
    assert.equal(swatchColour(def("N_ADAPT"), 1000), undefined)
    assert.equal(hexOf([255, 0, 16]), "#ff0010")
    assert.match(settingFacts(def("N_ADAPT")), /^whole number, at least \d+ · default \d+$/)
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

test("sheet rows: headings, then settings; moves skip headings", () => {
    const sheet = catalog.sheet("sampler")
    assert.ok(sheet !== undefined)
    const rows = sheetRows(sheet)
    assert.equal(rows[0]?.kind, "group")
    const count = sheet.groups.flatMap((g) => g.settings).length
    assert.equal(rows.filter((r) => r.kind === "setting").length, count)
    const first = firstOfGroup(rows, 0)
    assert.equal(first, 1)
    // down from the last setting of group 0 lands on the first of group 1, over the heading
    const lastOfZero = firstOfGroup(rows, 1) - 2
    assert.equal(rows[lastOfZero]?.kind, "setting")
    assert.equal(nextSetting(rows, lastOfZero, 1), firstOfGroup(rows, 1))
    assert.equal(nextSetting(rows, firstOfGroup(rows, 1), -1), lastOfZero)
    // no move past the ends
    assert.equal(nextSetting(rows, first, -1), first)
    assert.equal(nextSetting(rows, rows.length - 1, 1), rows.length - 1)
})

test("sheet rows: left and right jump to the previous and next group", () => {
    const sheet = catalog.sheet("plots")
    assert.ok(sheet !== undefined)
    const rows = sheetRows(sheet)
    const g1 = firstOfGroup(rows, 1)
    assert.equal(groupJump(rows, firstOfGroup(rows, 0) + 1, 1), g1)
    assert.equal(groupJump(rows, g1 + 1, -1), firstOfGroup(rows, 0))
    assert.equal(groupJump(rows, firstOfGroup(rows, 0), -1), firstOfGroup(rows, 0))
    const lastGroup = sheet.groups.length - 1
    const last = firstOfGroup(rows, lastGroup)
    assert.equal(groupJump(rows, last, 1), last)
    assert.deepEqual(
        groupSettings(rows, 0).map((d) => d.name),
        sheet.groups[0]?.settings.map((d) => d.name),
    )
})

test("windowStart keeps the heading in view above a group's first setting", () => {
    const sheet = catalog.sheet("model")
    assert.ok(sheet !== undefined)
    const rows = sheetRows(sheet)
    const g1 = firstOfGroup(rows, 1)
    assert.equal(windowStart(rows, g1, g1), g1 - 1)
    assert.equal(windowStart(rows, g1, g1 - 3), g1 - 3)
    assert.equal(windowStart(rows, g1 + 1, g1 + 1), g1 + 1)
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
