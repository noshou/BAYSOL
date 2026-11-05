// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { readAssetJson } from "../src/core/assets.js"
import {
    buildCatalog,
    defaultCatalog,
    formatValue,
    type Relation,
    SettingsCatalogError,
} from "../src/store/settings-defs.js"
import { catalogProblems } from "../src/store/settings-validate.js"

const catalog = defaultCatalog()
const defaults = readAssetJson<Record<string, Record<string, unknown>>>(
    "data",
    "default_settings.json",
)
const sheets = readAssetJson<Parameters<typeof buildCatalog>[1]>(
    "data",
    "setting_sheets.json",
)
const relations = readAssetJson<Relation[]>("data", "setting_relations.json")

test("every default belongs to exactly one group, and the sheets are the four ids", () => {
    assert.deepEqual(
        catalog.sheets.map((s) => s.id),
        ["sampler", "model", "output", "plots"],
    )
    const names = catalog.defs().map((d) => d.name)
    assert.equal(names.length, Object.keys(defaults).length)
    assert.deepEqual([...names].sort(), Object.keys(defaults).sort())
    assert.equal(new Set(names).size, names.length)
    for (const def of catalog.defs())
        assert.ok(catalog.sheet(def.sheet)?.groups.some((g) => g.title === def.group))
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
        assert.ok(def.default !== undefined && def.default !== null, def.name)
        assert.ok(
            Object.keys(def.limits).every((k) =>
                ["above", "below", "at_least", "at_most"].includes(k),
            ),
            def.name,
        )
    }
    assert.deepEqual(catalogProblems(catalog), [])
})

test("corrupt data is refused", () => {
    const corrupt = (change: (d: typeof defaults, s: typeof sheets) => void): void => {
        const d = structuredClone(defaults)
        const s = structuredClone(sheets)
        change(d, s)
        assert.throws(() => buildCatalog(d, s, relations), SettingsCatalogError)
    }
    corrupt((d) => {
        d.N_ADAPT.type = "mystery"
    })
    corrupt((d) => {
        d.N_ADAPT.limits = { above_all: 1 }
    })
    corrupt((d) => {
        delete d.N_ADAPT.default
    })
    corrupt((d) => {
        delete d.FIGURES_FORMATS.choices
    })
    corrupt((d) => {
        d.CHAIN_START_RADII.shape = ["float", "float"]
    })
    corrupt((d) => {
        delete d.CHAIN_START_RADII.parts
    })
    corrupt((d) => {
        d.NEW_SETTING = { default: 1, type: "int", limits: {} }
    })
    corrupt((_, s) => {
        s.sheets[0]?.groups[0]?.settings.push({ name: "N_DRAWS", description: "again" })
    })
    corrupt((_, s) => {
        s.sheets[0]?.groups[0]?.settings.push({ name: "GHOST", description: "none" })
    })
    assert.throws(() =>
        buildCatalog(defaults, sheets, [{ rule: "mystery" as never, setting: "N_ADAPT" }]),
    )
    assert.throws(() =>
        buildCatalog(defaults, sheets, [{ rule: "opacity", setting: "NOPE" }]),
    )
})

test("a value reads in the value cell, at most 17 cells", () => {
    assert.equal(formatValue(300), "300")
    assert.equal(formatValue(0.55), "0.55")
    assert.equal(formatValue(true), "true")
    assert.equal(formatValue("crimson"), "crimson")
    assert.equal(formatValue([4, 10, 20]), "(4, 10, 20)")
    assert.equal(formatValue(["gray40", 0.6]), "(gray40, 0.6)")
    assert.equal(formatValue({ width: 70, height: 18 }), "(70, 18)")
    assert.equal(formatValue("TeX Gyre Pagella Math"), "TeX Gyre Pagella…")
})
