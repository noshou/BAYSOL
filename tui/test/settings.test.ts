// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/settings.ts: the definitions and the validation, and the tabs of a `set`
// setting (`openTabs`/`stepTabs`, `tabLabel`, the boxes legend).

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    type LogsFlow,
    type PlotsFlow,
    type RunFlow,
    readAssetJson,
} from "../src/core/environment.js"
import { openTabs, PICK_ONE_NOTE, stepTabs } from "../src/screens/screen-rules.js"
import { colourNames } from "../src/store/colours.js"
import type { ImportTunables } from "../src/store/data-table.js"
import {
    type BrokenRelation,
    checkRelations,
    defaultCatalog,
    type Relation,
    reasonFor,
    type SettingDef,
    type SettingValue,
    settingNames,
    validateValue,
} from "../src/store/settings.js"
import { wipeInvalid } from "../src/store/settings-store.js"
import type { ViewerLimits } from "../src/store/view.js"
import { boxesFit, legendFor } from "../src/ui/grid.js"
import { keys, tabLabel } from "../src/ui/interaction.js"
import { fixture } from "./support/fixtures.js"

// ========================================================================================
// 1. Definitions
// ========================================================================================

const catalog = defaultCatalog()
const defaults = readAssetJson<Record<string, Record<string, unknown>>>(
    "data",
    "default_settings.json",
)

test("every default is known and sits in one group of a sheet", () => {
    assert.deepEqual(
        catalog.sheets.map((s) => s.id),
        ["sampler", "model", "output", "plots"],
    )
    const names = catalog.defs().map((d) => d.name)
    assert.equal(names.length, Object.keys(defaults).length)
    assert.deepEqual([...names].sort(), Object.keys(defaults).sort())
    assert.equal(new Set(names).size, names.length)
    // every setting is on a sheet, in one of its groups, but those the owner took off
    // the sheets (`FIGURES_COMPILE`: `open runs` compiles plots with a key; the setting
    // stays a keyword of Julia's `results` for the command line)
    const offSheet = catalog.defs().filter((d) => catalog.sheet(d.sheet) === undefined)
    assert.deepEqual(
        offSheet.map((d) => d.name),
        ["FIGURES_COMPILE"],
    )
    for (const def of catalog.defs().filter((d) => !offSheet.includes(d)))
        assert.ok(
            catalog.sheet(def.sheet)?.groups.some((g) => g.title === def.group),
            def.name,
        )
    for (const sheet of catalog.sheets) assert.ok(sheet.groups.length > 0)
})

test("a setting is found by name; an unknown name is not", () => {
    const def = catalog.require("N_ADAPT")
    assert.equal(def.kind, "int")
    assert.equal(def.sheet, "sampler")
    assert.equal(def.default, 300)
    assert.deepEqual(def.limits, { at_least: 1 })
    assert.ok(def.description.length > 0)
    assert.equal(catalog.get("NOPE"), undefined)
    assert.throws(() => catalog.require("NOPE"), /not a setting/)
})

test("tuples know their parts, sets their choices", () => {
    const size = catalog.require("PLOT_PREVIEW_SIZE")
    assert.equal(size.isRecord, true)
    assert.deepEqual(size.partNames, ["width", "height"])
    assert.deepEqual(size.partKinds, ["int", "int"])
    const band = catalog.require("PLOT_COLOUR_BAND")
    assert.equal(band.isRecord, false)
    assert.deepEqual(band.partKinds, ["colour", "float"])
    assert.deepEqual(catalog.require("FIGURES_FORMATS").choices, ["pdf", "png", "svg"])
})

test("every entry is complete and the data is sound", () => {
    for (const def of catalog.defs()) {
        assert.ok(def.default !== undefined, def.name)
        // only an optional number may default to "not given"
        assert.equal(def.default === null, def.kind.startsWith("optional"), def.name)
        assert.ok(
            Object.keys(def.limits).every((k) =>
                ["above", "below", "at_least", "at_most"].includes(k),
            ),
            def.name,
        )
    }
    const values: Record<string, SettingValue> = {}
    for (const def of catalog.defs()) {
        const r = validateValue(def, def.default)
        assert.ok(r.ok, `${def.name}: its default ${JSON.stringify(def.default)}`)
        values[def.name] = r.value
    }
    assert.deepEqual(checkRelations(catalog.relations, values), [])
})

// ========================================================================================
// 2. Validation
// ========================================================================================

type Case = {
    setting: string
    value: unknown
    valid: boolean
    expect?: unknown
    mention?: string
    with?: Record<string, unknown>
}

/** Judges a case like `load_settings` (settings-file.jl): what the wipe makes of a file. */
function judge(c: Case) {
    const stored: Record<string, Record<string, unknown>> = {}
    for (const [name, value] of Object.entries({
        ...(c.with ?? {}),
        [c.setting]: value0(c),
    })) {
        const sheet = catalog.require(name).sheet
        stored[sheet] ??= {}
        stored[sheet][name] = { value }
    }
    return wipeInvalid(catalog, stored)
}

const value0 = (c: Case): unknown => c.value

const cases = fixture("settings/cases.json").cases as Case[]

test("the fixture covers every setting, with valid and refused values", () => {
    assert.ok(cases.length > 200)
    assert.deepEqual(
        new Set(cases.map((c) => c.setting)),
        new Set(catalog.defs().map((d) => d.name)),
    )
    assert.ok(cases.filter((c) => c.valid).length > 60)
    assert.ok(cases.filter((c) => !c.valid).length > 140)
})

test("the cases both sides judge alike (test/fixtures/settings/cases.json)", () => {
    for (const c of cases) {
        const { saved, wiped } = judge(c)
        const label = `${c.setting} = ${JSON.stringify(c.value)}`
        if (c.valid) {
            assert.deepEqual(wiped, [], `${label} should be kept`)
            if ("expect" in c)
                assert.deepEqual(saved.get(c.setting), c.expect, label)
        } else {
            assert.ok(wiped.length > 0, `${label} should be wiped`)
            assert.ok(
                wiped.some((w) => w.reason.includes(c.mention as string)),
                `${label}: ${wiped.map((w) => w.reason).join(" | ")} lacks ${c.mention}`,
            )
            assert.ok(
                wiped.some((w) => w.setting === c.setting || w.reason.includes(c.setting)),
                `${label}: ${c.setting} is not named`,
            )
            for (const w of wiped)
                assert.equal(saved.has(w.setting), false, `${w.setting} kept after a wipe`)
        }
    }
})

const def = (name: string): SettingDef => catalog.require(name)
const kept = (name: string, raw: unknown): SettingValue | string => {
    const r = validateValue(def(name), raw)
    return r.ok ? r.value : r.error
}

test("numbers: a whole number setting, limits and their edges", () => {
    assert.equal(kept("N_ADAPT", 5), 5)
    assert.equal(kept("N_ADAPT", 1), 1)
    assert.equal(kept("N_ADAPT", 0), "must be at least 1")
    for (const bad of [2.5, "5", null, true, [5], 10n ** 20n, 2 ** 60])
        assert.equal(kept("N_ADAPT", bad), "must be a whole number", String(bad))
    assert.equal(kept("TARGET_ACCEPT", 50), 50)
    assert.equal(kept("TARGET_ACCEPT", 0), "must be above 0")
    assert.equal(kept("TARGET_ACCEPT", 100), "must be below 100")
    assert.equal(kept("RNG_SEED", -7), -7)
})

test("numbers: a float setting takes a whole number and refuses what is not finite", () => {
    assert.equal(kept("OPTIMUM_CHAIN_FRACTION", 1), 1)
    assert.equal(kept("OPTIMUM_CHAIN_FRACTION", 0.5), 0.5)
    assert.equal(kept("OPTIMUM_CHAIN_FRACTION", 0), "must be above 0")
    assert.equal(kept("OPTIMUM_CHAIN_FRACTION", -0), "must be above 0")
    assert.equal(kept("OPTIMUM_CHAIN_FRACTION", 1.0000001), "must be at most 1")
    for (const bad of [Number.NaN, Number.POSITIVE_INFINITY, "0.5", null, false])
        assert.equal(
            kept("OPTIMUM_CHAIN_FRACTION", bad),
            "must be a finite number",
            String(bad),
        )
})

test("yes/no", () => {
    assert.equal(kept("FIGURES_TEX", true), true)
    assert.equal(kept("FIGURES_TEX", false), false)
    for (const bad of [null, 0, 1, "true", [true], {}])
        assert.equal(kept("FIGURES_TEX", bad), "must be true or false")
})

test("fonts are the math fonts or the text fonts", () => {
    const fonts = { math: ["Pagella Math"], text: ["Pagella", "Times"] }
    assert.deepEqual(settingNames("PLOT_MATH_FONT", "font", fonts), fonts.math)
    assert.deepEqual(settingNames("PLOT_TEXT_FONT", "font", fonts), fonts.text)
    assert.deepEqual(settingNames("X", "other", fonts), [])
    assert.deepEqual(settingNames("PLOT_TEXT_FONT", "font"), [])
    assert.deepEqual(settingNames("X", "colour"), colourNames())
})

test("colours: a name of the list or a colour code", () => {
    for (const good of [
        "crimson",
        "antiquewhite4",
        "gray20",
        "#ff0000",
        "#A0b1C2",
        "#fff",
        "rgb(1, 2, 3)",
    ])
        assert.deepEqual(validateValue(def("PLOT_COLOUR_MAP"), good), {
            ok: true,
            value: good,
        })
    // any spelling of a listed name is kept as the listed name; a name Julia does not
    // read is kept as its #rrggbb
    assert.deepEqual(validateValue(def("PLOT_COLOUR_MAP"), "Sky Blue"), {
        ok: true,
        value: "skyblue",
    })
    for (const bad of [
        "notacolour",
        5,
        null,
        "#ff00000",
        "#GGGGGG",
        "",
        "a/crimson",
        ["red"],
        {},
        "ff0000",
    ])
        assert.deepEqual(validateValue(def("PLOT_COLOUR_MAP"), bad), {
            ok: false,
            error: "is not a colour",
        })
    assert.deepEqual(validateValue(def("PLOT_COLOUR_MAP"), "crimson"), {
        ok: true,
        value: "crimson",
    })
    assert.deepEqual(validateValue(def("PLOT_COLOUR_MAP"), "nope"), {
        ok: false,
        error: "is not a colour",
    })
})

test("fonts", () => {
    assert.equal(kept("PLOT_TEXT_FONT", "κ Font δ"), "κ Font δ")
    assert.equal(kept("PLOT_TEXT_FONT", "x".repeat(100)), "x".repeat(100))
    for (const bad of [
        "",
        "   ",
        "x".repeat(101),
        "a\u0001b",
        "a\nb",
        "a\tb",
        5,
        null,
        ["f"],
    ])
        assert.equal(kept("PLOT_TEXT_FONT", bad), "must be a font name")
})

test("choices come in the order of the choices", () => {
    assert.deepEqual(kept("FIGURES_FORMATS", ["svg", "pdf"]), [
        "pdf",
        "svg",
    ])
    assert.deepEqual(validateValue(def("FIGURES_FORMATS"), ["svg", "png"]), {
        ok: true,
        value: ["png", "svg"],
    })
    for (const bad of [
        [],
        ["gif"],
        ["pdf", "pdf"],
        "pdf",
        null,
        {},
    ])
        assert.match(
            String((validateValue(def("FIGURES_FORMATS"), bad) as { error: string }).error),
            /must be some of pdf, png, svg, at least one/,
        )
})

test("tuples: arrays, pairs of colour and opacity, objects", () => {
    assert.deepEqual(kept("CHAIN_START_RADII", [1, 2, 3]), [1, 2, 3])
    assert.equal(kept("CHAIN_START_RADII", [1, 2]), "must have 3 parts")
    assert.equal(kept("CHAIN_START_RADII", 5), "must have 3 parts")
    assert.equal(kept("CHAIN_START_RADII", { a: 1 }), "must have 3 parts")
    assert.equal(kept("CHAIN_START_RADII", ["a", 1, 2]), "a part must be a finite number")
    assert.equal(kept("CHAIN_START_RADII", [1, 2, null]), "a part must be a finite number")
    assert.deepEqual(kept("PLOT_COLOUR_BAND", ["blue", 1]), ["blue", 1])
    assert.equal(kept("PLOT_COLOUR_BAND", ["nope", 0.5]), "a part must be a colour")
    assert.equal(kept("PLOT_COLOUR_BAND", [0.5, "red"]), "a part must be a colour")
    assert.deepEqual(kept("PLOT_PREVIEW_SIZE", { height: 24, width: 80 }), {
        width: 80,
        height: 24,
    })
    assert.equal(
        kept("PLOT_PREVIEW_SIZE", { width: 7.5, height: 3 }),
        "a part must be a whole number",
    )
    for (const bad of [{ width: 70 }, { width: 70, height: 18, depth: 1 }, [70, 18]])
        assert.match(
            String(kept("PLOT_PREVIEW_SIZE", bad)),
            /must have exactly width, height/,
        )
})

test("a value is written as JSON so that it is read back as itself", () => {
    for (const d of catalog.defs()) {
        const r = validateValue(d, d.default)
        assert.ok(r.ok, d.name)
        const again = validateValue(d, JSON.parse(JSON.stringify(r.value)))
        assert.deepEqual(again, r, d.name)
    }
})

test("optional numbers: null is not given, else a number under the limits", () => {
    for (const name of ["Q_MIN", "Q_MAX"]) {
        assert.equal(kept(name, null), null)
        assert.equal(kept(name, 0.05), 0.05)
        assert.equal(kept(name, 1), 1)
        assert.equal(kept(name, 0), "must be above 0")
        for (const bad of ["0.05", true, [0.1], Number.NaN, {}])
            assert.equal(kept(name, bad), "must be a finite number or null", String(bad))
    }
    assert.equal(kept("LMAX", null), null)
    assert.equal(kept("LMAX", 1), 1)
    assert.equal(kept("LMAX", 0), "must be at least 1")
    for (const bad of [2.5, "3", false])
        assert.equal(kept("LMAX", bad), "must be a whole number or null", String(bad))
    const whole = "must be a whole number"
    assert.equal(kept("N_ADAPT", null), whole, "null only where optional")
})

test("ranges: pairs of q with 0 <= lo < hi, any number, may overlap", () => {
    assert.deepEqual(kept("EXCLUDE_Q", []), [])
    assert.deepEqual(kept("EXCLUDE_Q", [[0, 0.1], [0.05, 0.2]]), [[0, 0.1], [0.05, 0.2]])
    assert.equal(kept("EXCLUDE_Q", [[0.2, 0.1]]), "each range needs 0 <= q_lo < q_hi")
    assert.equal(kept("EXCLUDE_Q", [[0.1, 0.1]]), "each range needs 0 <= q_lo < q_hi")
    assert.equal(kept("EXCLUDE_Q", [[-1, 0.1]]), "each range needs 0 <= q_lo < q_hi")
    for (const bad of [[[0.1]], [[0.1, 0.2, 0.3]], [0.1, 0.2], [null]])
        assert.equal(kept("EXCLUDE_Q", bad), "each range must be a pair (q_lo, q_hi)")
    assert.equal(kept("EXCLUDE_Q", [["a", 1]]), "each range must be a pair of numbers")
    for (const bad of [0.1, "0.1-0.2", null, {}])
        assert.equal(kept("EXCLUDE_Q", bad), "must be a list of (q_lo, q_hi) pairs")
})

test("chains: unique single characters, case counts, none is all", () => {
    assert.deepEqual(kept("CHAINS", []), [])
    assert.deepEqual(kept("CHAINS", ["B", "A", "a", "1"]), ["B", "A", "a", "1"])
    assert.equal(kept("CHAINS", ["A", "A"]), "must not repeat a chain")
    for (const bad of [["AB"], [""], [" "], ["\t"], ["A", 1], [null]])
        assert.equal(kept("CHAINS", bad), "each chain must be one character")
    for (const bad of ["A", null, {}])
        assert.equal(kept("CHAINS", bad), "must be a list of chain ids")
})

const rule = (r: Relation): Relation => r
const broken = (r: Relation, values: Record<string, SettingValue>): boolean =>
    checkRelations([r], values).length > 0

test("rules: inside, width, ordered, all above, at most, opacity", () => {
    const inside = rule({ rule: "inside", setting: "M", of: "B" })
    assert.equal(broken(inside, { M: 1, B: [0, 2] }), false)
    assert.equal(broken(inside, { M: 0, B: [0, 2] }), true)
    assert.equal(broken(inside, { M: 2, B: [0, 2] }), true)
    assert.equal(
        broken(inside, { M: 1 }),
        false,
        "a rule whose other setting has no value is skipped",
    )
    const width = rule({ rule: "within_width", setting: "E", of: "B" })
    assert.equal(broken(width, { E: 0.5, B: [1, 1.5] }), false)
    assert.equal(broken(width, { E: 0.6, B: [1, 1.5] }), true)
    assert.equal(broken(width, { E: 0, B: [1, 1.5] }), true)
    const ordered = rule({ rule: "ordered", setting: "P" })
    const floor = rule({ rule: "ordered", setting: "P", above: 0 })
    assert.equal(broken(ordered, { P: [-5, 3] }), false)
    assert.equal(broken(ordered, { P: [3, -5] }), true)
    assert.equal(broken(ordered, { P: [1, 1] }), true)
    assert.equal(broken(floor, { P: [0.5, 1] }), false)
    assert.equal(broken(floor, { P: [0, 1] }), true)
    const above = rule({ rule: "all_above", setting: "R", bound: 0 })
    assert.equal(broken(above, { R: [1, 2, 3] }), false)
    assert.equal(broken(above, { R: { width: 70, height: 18 } }), false)
    assert.equal(broken(above, { R: [1, 0, 3] }), true)
    assert.equal(broken(above, { R: { width: 0, height: 18 } }), true)
    const atMost = rule({ rule: "at_most_setting", setting: "A", of: "B" })
    assert.equal(broken(atMost, { A: 5, B: 5 }), false)
    assert.equal(broken(atMost, { A: 6, B: 5 }), true)
    const below = rule({ rule: "below_setting", setting: "A", of: "B" })
    assert.equal(broken(below, { A: 1, B: 2 }), false)
    assert.equal(broken(below, { A: 2, B: 2 }), true)
    assert.equal(broken(below, { A: 3, B: 2 }), true)
    assert.equal(broken(below, { A: null, B: 2 }), false, "a side that is null skips it")
    assert.equal(broken(below, { A: 3, B: null }), false)
    assert.equal(broken(below, { A: null, B: null }), false)
    assert.equal(checkRelations([below], { A: 3, B: 2 })[0]?.reason, "must be below B")
    const opacity = rule({ rule: "opacity", setting: "C" })
    assert.equal(broken(opacity, { C: ["red", 0] }), false)
    assert.equal(broken(opacity, { C: ["red", 1] }), false)
    assert.equal(broken(opacity, { C: ["red", 1.0001] }), true)
    assert.equal(broken(opacity, { C: ["red", -0.0001] }), true)
    assert.equal(
        broken(rule({ rule: "mystery" as never, setting: "X" }), { X: 1 }),
        true,
        "an unknown rule is no pass",
    )
})

// --- the list kinds: colours, markers, sizes

const accepts = (name: string, raw: unknown) => validateValue(def(name), raw)

test("colours: a non-empty list of names or colour codes, repeats allowed", () => {
    const n = "PLOT_COMPARE_COLOURS"
    const goods = [["red"], ["#D55E00", "#0072b2", "crimson"], ["red", "red"]]
    for (const good of [...goods, ["#fff"], ["rgb(1, 2, 3)"]])
        assert.deepEqual(accepts(n, good), { ok: true, value: good })
    // a name is kept in its listed spelling (lower case), as Julia reads it
    assert.deepEqual(accepts(n, ["Red"]), { ok: true, value: ["red"] })
    for (const bad of [[], "red", null, {}])
        assert.deepEqual(accepts(n, bad), {
            ok: false,
            error: "must be a non-empty list of colours",
        })
    for (const bad of [["nope"], ["rgb(1,2)"], ["red", 5], [["red"]]])
        assert.deepEqual(accepts(n, bad), {
            ok: false,
            error: "must hold only colours",
        })
})

test("markers: a non-empty list of the catalog's names, repeats allowed", () => {
    const n = "PLOT_COMPARE_MARKERS"
    assert.ok(def(n).choices.includes("square*"))
    for (const good of [["o"], ["square*", "+", "x", "o", "o"], ["*", "oplus"]])
        assert.deepEqual(accepts(n, good), { ok: true, value: good })
    for (const bad of [[], "o", null])
        assert.deepEqual(accepts(n, bad), {
            ok: false,
            error: "must be a non-empty list of markers",
        })
    for (const bad of [["circle"], ["o", 1], ["O"]])
        assert.deepEqual(accepts(n, bad), {
            ok: false,
            error: "must hold only markers of the list",
        })
})

test("sizes: [width, height] pairs within 24x3..400x100, growing in both", () => {
    const n = "PLOT_TUI_SIZES"
    for (const good of [[[76, 5]], [[24, 3], [400, 100]], [[80, 10], [81, 11]]])
        assert.deepEqual(accepts(n, good), { ok: true, value: good })
    const refused: [unknown, string][] = [
        [[], "must be a non-empty list of sizes"],
        ["76x5", "must be a non-empty list of sizes"],
        [[76, 5], "each size must be a pair [width, height]"],
        [[[76]], "each size must be a pair [width, height]"],
        [[[76, 5, 1]], "each size must be a pair [width, height]"],
        [[[76.5, 5]], "each size must be whole numbers"],
        [[["76", 5]], "each size must be whole numbers"],
        [[[true, 5]], "each size must be whole numbers"],
        [[[23, 5]], "each size needs 24-400 x 3-100"],
        [[[76, 2]], "each size needs 24-400 x 3-100"],
        [[[401, 5]], "each size needs 24-400 x 3-100"],
        [[[76, 101]], "each size needs 24-400 x 3-100"],
        [[[100, 9], [76, 5]], "must grow in both width and height"],
        [[[76, 5], [76, 9]], "must grow in both width and height"],
        [[[76, 5], [100, 5]], "must grow in both width and height"],
    ]
    for (const [bad, error] of refused)
        assert.deepEqual(accepts(n, bad), { ok: false, error }, JSON.stringify(bad))
    for (const d of ["colours", "markers", "sizes"])
        for (const e of catalog.defs().filter((x) => x.kind === d))
            assert.ok(accepts(e.name, e.default).ok, e.name)
})

test("the messages of the list kinds stay within 40 characters", () => {
    for (const [n, bad] of [
        ["PLOT_COMPARE_COLOURS", []],
        ["PLOT_COMPARE_COLOURS", ["x"]],
        ["PLOT_COMPARE_MARKERS", []],
        ["PLOT_COMPARE_MARKERS", ["z"]],
        ["PLOT_TUI_SIZES", []],
        ["PLOT_TUI_SIZES", [[1]]],
        ["PLOT_TUI_SIZES", [[1.5, 5]]],
        ["PLOT_TUI_SIZES", [[1, 5]]],
        ["PLOT_TUI_SIZES", [[76, 5], [70, 9]]],
    ] as [string, unknown][]) {
        const r = accepts(n, bad)
        assert.ok(!r.ok && r.error.length <= 40, JSON.stringify(r))
    }
})

test("a broken rule is told on each of its rows in its own words", () => {
    const [b] = checkRelations(catalog.relations, { Q_MIN: 0.4, Q_MAX: 0.2 })
    assert.equal(reasonFor(b as BrokenRelation, "Q_MIN"), "must be below Q_MAX")
    assert.equal(reasonFor(b as BrokenRelation, "Q_MAX"), "must be above Q_MIN")
})

// --- fuzzing

const junk: unknown[] = [
    null,
    true,
    false,
    0,
    1,
    -1,
    2,
    2.5,
    -0,
    1e300,
    "",
    "x",
    "#ff0000",
    "#zzzzzz",
    "pdf",
    "red",
    "notacolour",
    "a/b",
    [],
    [1],
    [1, 2],
    [1, 2, 3],
    ["red", 0.5],
    ["pdf", "png"],
    {},
    { width: 1, height: 2 },
    { a: 1 },
    [[1]],
    [[0.1, 0.2]],
    [[0.2, 0.1], [0, 1]],
    [[0, 1e-300]],
    [["a", 1]],
    ["A", "B"],
    ["A", "A"],
    ["AB"],
    ["a", "A", "0"],
    0.05,
    99999,
    [0, 0, 0],
    [null, null],
    "a\nb",
    ["red", 2],
    [-1, 5],
    { width: 0, height: 0 },
    "y".repeat(120),
    ["red", "#D55E00", "red"],
    ["o", "square*", "+", "o"],
    ["circle"],
    [[76, 5], [100, 9]],
    [[24, 3], [400, 100]],
    [[100, 9], [76, 5]],
    [[76.5, 5]],
    [["76", 5]],
    [[23, 5]],
    Number.NaN,
    Number.POSITIVE_INFINITY,
    10n ** 20n,
    3,
    2 ** 60,
]

test("fuzzing the value of every setting: one answer, kept again unchanged", () => {
    for (const d of catalog.defs()) {
        for (const v of junk) {
            const r = validateValue(d, v)
            assert.ok(r.ok ? !("error" in r) : typeof r.error === "string")
            if (!r.ok) continue
            assert.deepEqual(
                validateValue(d, r.value),
                r,
                `${d.name} = ${String(v)} is not stable`,
            )
            if (d.kind === "int") assert.ok(Number.isSafeInteger(r.value))
            if (d.kind === "float") assert.ok(Number.isFinite(r.value))
            if (d.kind === "set")
                assert.ok((r.value as string[]).every((c) => d.choices.includes(c)))
            if (d.kind === "tuple")
                assert.equal(Object.keys(r.value as object).length, d.partNames.length)
            const { above, below, at_least: atLeast, at_most: atMost } = d.limits
            if (typeof r.value === "number") {
                if (above !== undefined) assert.ok(r.value > above)
                if (below !== undefined) assert.ok(r.value < below)
                if (atLeast !== undefined) assert.ok(r.value >= atLeast)
                if (atMost !== undefined) assert.ok(r.value <= atMost)
            }
        }
    }
})

test("fuzzing whole files: what is kept keeps every rule and every type", () => {
    let seed = 20261101
    const next = (n: number): number => {
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    }
    const names = catalog.defs().map((d) => d.name)
    for (let i = 0; i < 600; i++) {
        const stored: Record<string, Record<string, unknown>> = {}
        for (let k = 1 + next(6); k > 0; k--) {
            const name = names[next(names.length)] as string
            const sheet = catalog.require(name).sheet
            stored[sheet] ??= {}
            stored[sheet][name] = { value: junk[next(junk.length)] }
        }
        const { saved, wiped } = wipeInvalid(catalog, stored)
        const values = Object.fromEntries(
            catalog.defs().map((d) => [d.name, saved.get(d.name) ?? d.default]),
        )
        assert.deepEqual(
            checkRelations(catalog.relations, values),
            [],
            JSON.stringify(stored, (_, v) => (typeof v === "bigint" ? String(v) : v)),
        )
        for (const [name, value] of saved)
            assert.deepEqual(validateValue(catalog.require(name), value), {
                ok: true,
                value,
            })
        for (const w of wiped) assert.ok(names.includes(w.setting))
    }
})

test("an entry that is no map is wiped; a screen that is no map is ignored", () => {
    const r = wipeInvalid(catalog, {
        sampler: { N_ADAPT: 5, N_DRAWS: null, RNG_SEED: { value: 3 } },
    })
    assert.deepEqual(
        new Set(r.wiped.map((w) => w.setting)),
        new Set(["N_ADAPT", "N_DRAWS"]),
    )
    assert.equal(r.saved.get("RNG_SEED"), 3)
    assert.equal(wipeInvalid(catalog, { sampler: 5 }).saved.size, 0)
})

const choices = ["svg", "pdf", "png"]

test("tabs: left and right stop at the ends, tab goes round", () => {
    let edit = openTabs(choices, ["pdf"])
    edit = stepTabs(edit, keys.left).state
    assert.equal(edit.focus, 0)
    edit = stepTabs(edit, keys.right).state
    edit = stepTabs(edit, keys.right).state
    edit = stepTabs(edit, keys.right).state
    assert.equal(edit.focus, 2)
    edit = stepTabs(edit, keys.tab).state
    assert.equal(edit.focus, 0)
})

test("tabs: enter and space toggle the tab in focus, esc ends with the choices", () => {
    let edit = openTabs(choices, ["pdf"])
    edit = stepTabs(edit, keys.enter).state
    assert.deepEqual([...edit.selected].sort(), ["pdf", "svg"])
    edit = stepTabs(edit, keys.right).state
    edit = stepTabs(edit, keys.space).state
    assert.deepEqual([...edit.selected], ["svg"])
    const done = stepTabs(edit, keys.escape)
    assert.deepEqual(done.end, { kind: "done", value: ["svg"] })
})

test("tabs: a set needs one choice on, and ctrl-x leaves", () => {
    let edit = openTabs(choices, ["svg"])
    edit = stepTabs(edit, keys.enter).state
    const blocked = stepTabs(edit, keys.escape)
    assert.equal(blocked.end, undefined)
    assert.equal(blocked.state.error, PICK_ONE_NOTE)
    assert.deepEqual(stepTabs(edit, keys.back).end, { kind: "back" })
})

test("tab labels: on in brackets, off in parentheses, focus in capitals", () => {
    assert.equal(tabLabel("pdf", true, false), "[pdf]")
    assert.equal(tabLabel("pdf", false, true), "(PDF)")
})

test("a boxes legend fits one row only when the boxes and their gaps fit", () => {
    const items = [legendFor("take", keys.enter), legendFor("cancel", keys.escape)]
    const width = items.reduce((n, i) => n + i.label.length + 2 + i.keys.length + 4, 0) + 1
    assert.ok(boxesFit(items, width))
    assert.ok(!boxesFit(items, width - 1))
})

/** The keys of a type as a tree: `"array"` for an array, `"value"` for any other leaf. */
type KeyTree<T> = T extends readonly unknown[] ? "array" : Branches<T>
type Branches<T> = T extends object ? { [K in keyof T]-?: KeyTree<T[K]> } : "value"

/** The same tree of parsed JSON. */
function keyTree(json: unknown): unknown {
    if (Array.isArray(json)) return "array"
    if (typeof json !== "object" || json === null) return "value"
    return Object.fromEntries(Object.entries(json).map(([k, v]) => [k, keyTree(v)]))
}

test("each tunables JSON asset has exactly the keys of its TypeScript type", () => {
    // The types are erased at run time, so each shape is written once here, typed: a key
    // added to a type without the JSON (or the reverse) fails to compile or to match.
    const shapes: [string, unknown][] = []
    const runFlow: KeyTree<RunFlow> = {
        temperature: { default: "value", min: "value", max: "value", maxLength: "value" },
        liveness: { staleSeconds: "value", claimRefreshSeconds: "value" },
        claim: { maxStampTries: "value" },
        abort: { graceSeconds: "value", killWaitSeconds: "value" },
        screen: { tailLines: "value" },
        julia: { threads: "value" },
        log: { maxBytes: "value" },
        archive: {
            extension: "value",
            level: "value",
            wordSize: "value",
            solid: "value",
            maxEntryBytes: "value",
            maxExtractBytes: "value",
        },
    }
    const plotsFlow: KeyTree<PlotsFlow> = {
        compileSeconds: "value",
        engineArguments: "array",
        searched: "array",
        accepted: "array",
        folder: "value",
        dataFolder: "value",
    }
    const logsFlow: KeyTree<LogsFlow> = {
        pager: { overlap: "value", sideStep: "value", tabWidth: "value" },
        list: { stampWidth: "value", statusWidth: "value", sizeWidth: "value" },
        options: { fileWidth: "value", sizeWidth: "value" },
        watch: { pollSeconds: "value", closeSeconds: "value" },
        corner: { separator: "value", minCells: "value" },
    }
    const viewerLimits: KeyTree<ViewerLimits> = {
        maxBytes: "value",
        maxRows: "value",
        maxColumns: "value",
        maxCells: "value",
        minColumnWidth: "value",
        maxColumnWidth: "value",
        widthSampleRows: "value",
        maxTabName: "value",
    }
    const importTunables: KeyTree<ImportTunables> = {
        previewRows: "value",
        sniffLines: "value",
        commentChars: "array",
        guesses: { q: "array", i: "array", sigma: "array" },
    }
    shapes.push(
        ["run_flow.json", runFlow],
        ["plots_flow.json", plotsFlow],
        ["logs.json", logsFlow],
        ["sheet_viewer.json", viewerLimits],
        ["data_import.json", importTunables],
    )
    for (const [file, expected] of shapes) {
        assert.deepEqual(keyTree(readAssetJson("data", file)), expected, file)
    }
})
