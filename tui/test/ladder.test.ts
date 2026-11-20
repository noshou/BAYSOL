// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the retry-ladder setting (`LADDER`, kind `ladder`): a map from failure class to
// rungs. The catalog binds the settings a rung may override, `validateValue` refuses what
// Julia refuses, the one-line form (`parseLadder`/`ladderText`) round-trips, the editor's
// list operations keep the map valid, and the setting is per model like any other.

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    dropRung,
    ladderRows,
    ladderText,
    moveRung,
    parseLadder,
    parseRung,
    parseSetting,
    putRung,
    rungText,
    valueText,
} from "../src/screens/screen-rules.js"
import {
    isRunLevel,
    type LadderMap,
    type SettingValue,
    validateValue,
} from "../src/store/settings.js"
import { settingDef } from "./support/fixtures.js"

const def = settingDef("LADDER")
const base = def.default as LadderMap

test("ladder: the default is a map of the six classes with the validated rungs", () => {
    assert.deepEqual(Object.keys(base), [...def.classes])
    assert.deepEqual(def.classes, [
        "stepCollapse",
        "splitChains",
        "divergent",
        "structural",
        "marginal",
        "generic",
    ])
    assert.deepEqual(base.divergent?.[0]?.overrides, { TARGET_ACCEPT: 99 })
    assert.deepEqual(base.divergent?.[1]?.overrides, {
        TARGET_ACCEPT: 99,
        CHAIN_START_RADII: [1, 2, 3],
        RETRY_N_ADAPT: 4000,
        RETRY_N_DRAWS: 4000,
    })
    assert.equal(base.divergent?.[2]?.overrides.RNG_SEED_STEP, 1)
    assert.deepEqual(base.structural?.[0]?.overrides, { SAMPLE_C1: true })
    assert.equal(validateValue(def, base as SettingValue).ok, true)
})

test("ladder: a rung overrides only the settings Julia lists, each checked", () => {
    assert.ok(def.overridable.includes("TARGET_ACCEPT"))
    assert.ok(def.overrideDefs.has("TARGET_ACCEPT"))
    assert.equal(def.overridable.includes("PLOT_LW_MAP"), false)
    const refuse = (value: unknown, mention: string): void => {
        const out = validateValue(def, value as SettingValue)
        assert.ok(!out.ok, JSON.stringify(value))
        assert.ok(out.error.includes(mention), `${out.error} lacks ${mention}`)
    }
    const one = (rung: unknown) => ({ divergent: [rung] })
    refuse(one({ overrides: { PLOT_LW_MAP: 2 } }), "fitting setting")
    refuse(one({ overrides: { LADDER: [] } }), "fitting setting")
    refuse(one({ overrides: { TARGET_ACCEPT: 0 } }), "above 0")
    refuse(one({ overrides: { SAMPLE_C1: 1 } }), "true or false")
    refuse(one({ overrides: { RNG_SEED_STEP: 1.5 } }), "whole number")
    refuse(one({ overrides: {} }), "at least one")
    refuse(one({ name: "x" }), "needs overrides")
    refuse({ kink: [] }, "not a failure class")
    refuse({ divergent: 5 }, "list of rungs")
    refuse("no", "map from failure class")
    refuse([], "map from failure class")
})

test("ladder: a class left out keeps its default, [] is off, false is all off", () => {
    const out = validateValue(def, { generic: [] } as SettingValue)
    assert.ok(out.ok)
    const map = out.value as LadderMap
    assert.deepEqual(map.generic, [])
    assert.deepEqual(map.divergent, base.divergent)
    for (const off of [false, "off"]) {
        const all = validateValue(def, off as SettingValue)
        assert.ok(all.ok)
        assert.ok(Object.values(all.value as LadderMap).every((r) => r.length === 0))
    }
})

test("ladder: the typed line reads and writes the same map", () => {
    const typed =
        "divergent: wide: TARGET_ACCEPT=97 | N_ADAPT=500; N_DRAWS=700; " +
            "RNG_SEED_STEP=2 // marginal: off"
    const parsed = parseLadder(typed)
    assert.deepEqual(parsed, {
        value: {
            divergent: [
                { name: "wide", overrides: { TARGET_ACCEPT: 97 } },
                { name: "", overrides: { N_ADAPT: 500, N_DRAWS: 700, RNG_SEED_STEP: 2 } },
            ],
            marginal: [],
        },
    })
    assert.deepEqual(parseLadder(ladderText(base)), { value: base })
    assert.deepEqual(parseRung("SAMPLE_C1=true"), {
        value: { name: "", overrides: { SAMPLE_C1: true } },
    })
    assert.equal(
        rungText({ name: "a", overrides: { CHAIN_START_RADII: [1, 2, 3] } }),
        "a: CHAIN_START_RADII=1,2,3",
    )
    const none = Object.fromEntries(def.classes.map((c) => [c, []]))
    assert.equal(ladderText(none), "off")
    for (const off of ["", "  ", "off", "None"]) {
        assert.deepEqual(parseLadder(off), { value: false })
    }
    assert.ok("error" in parseLadder("TARGET_ACCEPT=99"))
    assert.ok("error" in parseLadder("divergent: TARGET_ACCEPT"))
    assert.ok("error" in parseLadder("divergent: TARGET_ACCEPT=fast"))
})

test("ladder: parseSetting and valueText go through the catalog's rules", () => {
    const off = parseSetting(def, "off")
    assert.ok("value" in off)
    assert.equal(valueText(def, off.value), "off")
    assert.ok("error" in parseSetting(def, "divergent: PLOT_LW_MAP=2"))
    assert.ok("error" in parseSetting(def, "divergent: CHAIN_START_RADII=1,2"))
    const ok = parseSetting(def, "divergent: TARGET_ACCEPT=98")
    assert.ok("value" in ok)
    assert.ok(valueText(def, ok.value).startsWith("stepCollapse: "))
    assert.ok(valueText(def, ok.value).includes("divergent: TARGET_ACCEPT=98"))
})

test("ladder: the editor's list operations add, remove and reorder rungs", () => {
    const rows = ladderRows(base, def.classes)
    assert.deepEqual(rows[0], { cls: "stepCollapse" })
    assert.deepEqual(rows[1], { cls: "stepCollapse", rung: 0 })
    assert.equal(rows.length, def.classes.length + Object.values(base).flat().length)
    const rungX = { name: "x", overrides: { TARGET_ACCEPT: 90 } }
    const added = putRung(base, "marginal", 99, rungX)
    assert.equal(added.marginal?.length, (base.marginal?.length ?? 0) + 1)
    assert.equal(added.marginal?.at(-1)?.name, "x")
    const rungY = { name: "y", overrides: { TARGET_ACCEPT: 98 } }
    const edited = putRung(base, "divergent", 0, rungY)
    assert.equal(edited.divergent?.length, base.divergent?.length)
    assert.equal(edited.divergent?.[0]?.name, "y")
    assert.equal(dropRung(base, "divergent", 0).divergent?.length, 2)
    assert.deepEqual(dropRung(base, "divergent", undefined).divergent, [])
    const moved = moveRung(base, "divergent", 0, 1)
    assert.deepEqual(moved.divergent?.[1], base.divergent?.[0])
    assert.equal(moveRung(base, "divergent", 0, -1), base)
    assert.equal(moveRung(base, "structural", 0, 1), base)
    // the original is never changed, and every result is still a valid ladder
    assert.equal(base.divergent?.[0]?.overrides.TARGET_ACCEPT, 99)
    for (const m of [added, edited, moved]) {
        assert.ok(validateValue(def, m as SettingValue).ok)
    }
})

test("ladder: it is a setting of single models, not of the run", () => {
    assert.equal(isRunLevel("LADDER"), false)
})
