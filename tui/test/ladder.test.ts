// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the retry-ladder setting (`LADDER`, kind `ladder`): a map from failure class to
// rungs. The catalog binds the settings a rung may override, `validateValue` refuses what
// Julia refuses, the one-line form (`parseLadder`/`ladderText`) round-trips, the editor's
// list operations keep the map valid, and the setting is per model like any other.

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    addableOverrides,
    conditionLabel,
    dropOverride,
    dropRung,
    LADDER_CONDITIONS,
    ladderRungs,
    moveOverride,
    moveRung,
    overrideDef,
    putRung,
    recondition,
    renameRung,
    rungPlace,
    rungRowText,
    setOverride,
    valueText,
} from "../src/screens/screen-rules.js"
import {defaultCatalog,
    isRunLevel,
    type LadderMap,
    type LadderRung,
    type SettingValue,
    validateValue
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

test("ladder: valueText says off, default or how many classes differ", () => {
    const none = Object.fromEntries(def.classes.map((c) => [c, []]))
    assert.equal(valueText(def, none as SettingValue), "off")
    const edited = { ...base, generic: [] } as SettingValue
    assert.equal(valueText(def, edited), "edited: 1 of 6 classes")
    assert.equal(valueText(def, def.default), "default")
})

test("ladder: the editor's list operations add, remove and reorder rungs", () => {
    const rungs = ladderRungs(base, def.classes)
    assert.deepEqual(rungs[0], { cls: "stepCollapse", index: 0 })
    assert.equal(rungs.length, Object.values(base).flat().length)
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

test("ladder: the overridable settings are exactly the sampler sheet's, no drift", () => {
    // the sampler groups a rung may touch; the seed
    // becomes a step and `LADDER` is the setting itself
    const groups = ["sampling", "chains", "MAP search", "MAP jitter", "basins and harvest"]
    const sampler = defaultCatalog().sheet("sampler")
    assert.ok(sampler)
    const names = new Set<string>()
    for (const title of groups) {
        const group: { settings: { name: string }[] } | undefined = sampler.groups.find(
            (g) => g.title === title,
        )
        assert.ok(group, `no group ${title}`)
        for (const s of group.settings) names.add(s.name)
    }
    names.delete("RNG_SEED")
    names.delete("LADDER")
    names.add("RNG_SEED_STEP")
    names.add("SAMPLE_C1")
    assert.deepEqual([...def.overridable].sort(), [...names].sort())
})

test("ladder: every class has a plain-language condition, the ids stay", () => {
    assert.deepEqual(Object.keys(LADDER_CONDITIONS), [...def.classes])
    assert.equal(conditionLabel("divergent"), "divergent draws")
    assert.equal(conditionLabel("unknown"), "unknown")
    const rung = base.divergent?.[0] as LadderRung
    const row = rungRowText(rung, "divergent", 22)
    assert.ok(row.startsWith("divergent draws"))
    assert.ok(row.endsWith("▸ delta 99 ▸ 1 override"))
    const unnamed = rungRowText({ name: "", overrides: { A: 1, B: 2 } }, "generic", 22)
    assert.ok(unnamed.includes("(unnamed) ▸ 2 overrides"))
})

test("ladder: the rung and override operations keep the map valid", () => {
    const ref = { cls: "divergent", index: 1 }
    // a rung under another condition ends that class's rungs; the original is untouched
    const moved = recondition(base, ref, "generic")
    assert.deepEqual(moved.ref, { cls: "generic", index: (base.generic?.length ?? 0) })
    assert.equal(moved.map.divergent?.length, (base.divergent?.length ?? 0) - 1)
    assert.equal(base.divergent?.length, 3)
    assert.equal(recondition(base, ref, "divergent").map, base)
    assert.equal(rungPlace(base, def.classes, { cls: "stepCollapse", index: 1 }), 1)
    const named = renameRung(base, ref, "wide")
    assert.equal(named.divergent?.[1]?.name, "wide")
    // set, replace, move and drop an override
    const one = setOverride(base, ref, "N_CHAINS", 4)
    assert.deepEqual(Object.keys(one.divergent?.[1]?.overrides ?? {}).at(-1), "N_CHAINS")
    const again = setOverride(one, ref, "TARGET_ACCEPT", 90)
    assert.equal(again.divergent?.[1]?.overrides.TARGET_ACCEPT, 90)
    const shifted = moveOverride(one, ref, "N_CHAINS", -1)
    const order = Object.keys(shifted.divergent?.[1]?.overrides ?? {})
    assert.equal(order.at(-2), "N_CHAINS")
    assert.equal(moveOverride(one, ref, "N_CHAINS", 1), one)
    assert.deepEqual(
        dropOverride(one, ref, "N_CHAINS").divergent?.[1]?.overrides,
        base.divergent?.[1]?.overrides,
    )
    for (const m of [moved.map, named, one, again, shifted]) {
        assert.ok(validateValue(def, m as SettingValue).ok)
    }
})

test("ladder: the overrides on offer come from the catalog, less those already set", () => {
    const rung = base.divergent?.[2] as LadderRung
    const addable = addableOverrides(def, rung)
    assert.equal(addable.includes("TARGET_ACCEPT"), false)
    assert.equal(addable.includes("RNG_SEED_STEP"), false)
    assert.ok(addable.includes("N_CHAINS"))
    assert.ok(addable.includes("SAMPLE_C1"))
    for (const name of addable) assert.ok(overrideDef(def, name), name)
    const empty = addableOverrides(def, { name: "", overrides: {} })
    assert.ok(empty.includes("RNG_SEED_STEP"))
    assert.equal(overrideDef(def, "RNG_SEED_STEP")?.kind, "int")
    assert.equal(overrideDef(def, "SAMPLE_C1")?.kind, "bool")
    assert.equal(overrideDef(def, "PLOT_LW_MAP"), undefined)
})
