// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    defaultCatalog,
    type Relation,
    type SettingDef,
    type SettingValue,
} from "../src/store/settings-defs.js"
import { wipeInvalid } from "../src/store/settings-store.js"
import {
    checkRelations,
    isColour,
    shortReason,
    shortReasonCells,
    shortReasonCellsTuple,
    validateValue,
} from "../src/store/settings-validate.js"
import { fixture } from "./support/fixtures.js"

const catalog = defaultCatalog()

type Case = {
    setting: string
    value: unknown
    valid: boolean
    expect?: unknown
    mention?: string
    with?: Record<string, unknown>
}

/** Judges a case like `BAYSOL.load_settings`: what the wipe makes of a file holding it. */
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

test("colours: a name of the list or #rrggbb", () => {
    for (const good of [
        "crimson",
        "antiquewhite4",
        "gray20",
        "#ff0000",
        "#A0b1C2",
    ])
        assert.deepEqual(validateValue(def("PLOT_COLOUR_MAP"), good), {
            ok: true,
            value: good,
        })
    for (const bad of [
        "notacolour",
        5,
        null,
        "#fff",
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
    assert.equal(isColour("red"), true)
    assert.equal(isColour("not a colour"), false)
    assert.equal(isColour(5), false)
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

test("what a broken rule says to the user fits the budget", () => {
    const tuples = new Set(
        catalog
            .defs()
            .filter((d) => d.kind === "tuple")
            .map((d) => d.name),
    )
    for (const r of catalog.relations) {
        for (const name of [r.setting, r.of]) {
            if (name === undefined) continue
            const reason = shortReason(r, name)
            assert.ok(reason.length > 0)
            const budget = tuples.has(name) ? shortReasonCellsTuple : shortReasonCells
            assert.ok(
                reason.length <= budget,
                `${reason} is ${reason.length} characters for ${name}`,
            )
        }
    }
    const r = rule({ rule: "at_most_setting", setting: "SASA_N_OCC", of: "SHELL_SAMPLE" })
    assert.equal(shortReason(r, "SASA_N_OCC"), "above SHELL_SAMPLE")
    assert.equal(shortReason(r, "SHELL_SAMPLE"), "below SASA_N_OCC")
    assert.equal(
        shortReason(rule({ rule: "ordered", setting: "B", above: 0 }), "B"),
        "first below second, above 0",
    )
    assert.equal(
        shortReason(rule({ rule: "ordered", setting: "B" }), "B"),
        "first must be below second",
    )
    assert.equal(
        shortReason(rule({ rule: "all_above", setting: "R", bound: 0 }), "R"),
        "every part above 0",
    )
    assert.equal(
        shortReason(rule({ rule: "opacity", setting: "C" }), "C"),
        "opacity from 0 to 1",
    )
    const inside = rule({ rule: "inside", setting: "M", of: "B" })
    assert.equal(shortReason(inside, "B"), "mode out of range")
    assert.equal(shortReason(inside, "M"), "outside the bounds")
    const width = rule({ rule: "within_width", setting: "E", of: "B" })
    assert.equal(shortReason(width, "B"), "bounds too narrow")
    assert.equal(shortReason(width, "E"), "wider than bounds")
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
    99999,
    [0, 0, 0],
    [null, null],
    "a\nb",
    ["red", 2],
    [-1, 5],
    { width: 0, height: 0 },
    "y".repeat(120),
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

test("an entry that is no map is wiped; a screen that is no map is left out", () => {
    const r = wipeInvalid(catalog, {
        sampler: { N_ADAPT: 5, N_DRAWS: null, RNG_SEED: { value: 3 } },
    })
    assert.deepEqual(
        new Set(r.wiped.map((w) => w.setting)),
        new Set(["N_ADAPT", "N_DRAWS"]),
    )
    assert.equal(r.saved.get("RNG_SEED"), 3)
    const s = wipeInvalid(catalog, { sampler: 5 })
    assert.equal(s.dropped.length, 1)
})
