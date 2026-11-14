// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the settings of single models (`model-settings.json`): the store, the rule
// that run-level settings are never per model (checked against the Julia source), the
// sheets a model shows and the models list's overrides.

import assert from "node:assert/strict"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import { modelMenuSpec } from "../src/screens/settings-screens.js"
import { ProjectGoneError } from "../src/store/projects.js"
import {
    defaultCatalog,
    isRunLevel,
    modelSheets,
    RUN_LEVEL_PREFIX,
    runLevelSettings,
} from "../src/store/settings.js"
import {
    loadGlobal,
    loadModel,
    loadProject,
    modelOverrides,
    modelSettingsFile,
    modelStem,
    settingsFile,
} from "../src/store/settings-store.js"
import { tempDir } from "./support/fixtures.js"

const catalog = defaultCatalog()

/** A global folder with the given global settings and a project folder in it. */
function setup(global: Record<string, unknown> = {}): { g: string; p: string } {
    const g = tempDir()
    const { settings } = loadGlobal(g)
    if (Object.keys(global).length > 0) {
        assert.equal(settings.set(global).ok, true)
        settings.save()
    }
    const p = join(g, "projects", "demo")
    mkdirSync(p, { recursive: true })
    loadProject(p, g)
    return { g, p }
}

/** The parsed `model-settings.json` of a project. */
const stored = (p: string): Record<string, Record<string, Record<string, unknown>>> =>
    JSON.parse(readFileSync(modelSettingsFile(p), "utf-8"))

// ========================================================================================
// 1. Run-level settings: the one list, and Julia's
// ========================================================================================

test("run-level: the TS list and the PLOT_ rule are Julia's", () => {
    const source = readFileSync(
        fileURLToPath(new URL("../src/store/settings-file.jl", import.meta.url)),
        "utf-8",
    )
    const list = /const RUN_LEVEL_SETTINGS\s*=\s*\(([^)]*)\)/.exec(source)
    assert.ok(list, "RUN_LEVEL_SETTINGS is in store/settings-file.jl")
    const julia = (list?.[1] ?? "")
        .split(",")
        .map((t) => t.trim().replace(/^:/, ""))
        .filter((t) => t !== "")
    assert.deepEqual([...julia].sort(), [...runLevelSettings].sort())
    const rule = new RegExp(
        String.raw`_isRunLevel\(name::Symbol\)\s*=\s*name in RUN_LEVEL_SETTINGS \|\|\s*` +
            String.raw`startswith\(String\(name\), "([^"]*)"\)`,
    ).exec(source)
    assert.ok(rule, "the PLOT_ rule is in _isRunLevel")
    assert.equal(rule?.[1], RUN_LEVEL_PREFIX)
    // every one named exists in the catalog; every PLOT_ setting is run-level
    for (const name of runLevelSettings) assert.ok(catalog.get(name), name)
    for (const def of catalog.defs())
        assert.equal(
            isRunLevel(def.name),
            runLevelSettings.includes(def.name) || def.name.startsWith("PLOT_"),
        )
})

test("model sheets: no run-level setting, no empty group, no plots sheet", () => {
    const sheets = modelSheets(catalog)
    assert.deepEqual(
        sheets.map((s) => s.id),
        ["sampler", "model", "output"].filter((id) => sheets.some((s) => s.id === id)),
    )
    assert.ok(!sheets.some((s) => s.id === "plots"))
    for (const sheet of sheets)
        for (const group of sheet.groups) {
            assert.ok(group.settings.length > 0)
            for (const d of group.settings) assert.ok(!isRunLevel(d.name), d.name)
        }
    const output = sheets.find((s) => s.id === "output")
    assert.deepEqual(output?.groups.map((g) => g.title), ["tables"])
    assert.deepEqual(output?.groups[0]?.settings.map((d) => d.name), ["VAL_SIGMA"])
    // every setting a model may have is on one of the sheets it shows
    const shown = new Set(
        sheets.flatMap((s) => s.groups.flatMap((g) => g.settings.map((d) => d.name))),
    )
    for (const sheet of catalog.sheets)
        for (const d of sheet.groups.flatMap((g) => g.settings))
            assert.equal(shown.has(d.name), !isRunLevel(d.name), d.name)
    // the menu offers exactly these sheets (the option `models` is the sheet `model`)
    const ids = modelMenuSpec.names.map((n) => (n === "models" ? "model" : n)).sort()
    assert.deepEqual(ids, sheets.map((s) => s.id).sort())
})

test("model: the stem is the name without the last extension", () => {
    assert.equal(modelStem("crambin.pdb"), "crambin")
    assert.equal(modelStem("a.b.cif"), "a.b")
    assert.equal(modelStem("noext"), "noext")
})

// ========================================================================================
// 2. The store
// ========================================================================================

test("model: no file or no table reads as empty and makes nothing", () => {
    const { g, p } = setup({ N_ADAPT: 450 })
    const r = loadModel(p, "crambin", g)
    assert.deepEqual(r.settings.overrides(), [])
    assert.equal(r.settings.get("N_ADAPT"), 450, "the project's value")
    assert.equal(r.settings.isSaved("N_ADAPT"), false)
    assert.equal(r.reset, false)
    assert.deepEqual(r.wiped, [])
    assert.ok(!existsSync(modelSettingsFile(p)))
    assert.deepEqual(modelOverrides(p), new Map())
})

test("model: an override is written sparse, in the shape Julia reads", () => {
    const { g, p } = setup({ N_ADAPT: 450 })
    const { settings } = loadModel(p, "crambin", g)
    assert.equal(settings.set({ Q_MAX: 0.3, N_CHAINS: 6, N_ADAPT: 450 }).ok, true)
    settings.save()
    assert.deepEqual(stored(p), {
        crambin: { model: { Q_MAX: { value: 0.3 } }, sampler: { N_CHAINS: { value: 6 } } },
    })
    // the project's file is not touched
    assert.ok(!readFileSync(settingsFile(p), "utf-8").includes("Q_MAX"))
    const again = loadModel(p, "crambin", g).settings
    assert.deepEqual(again.overrides(), ["N_CHAINS", "Q_MAX"])
    assert.equal(again.get("Q_MAX"), 0.3)
    assert.equal(again.resetValue("Q_MAX"), null, "back to the project's value")
    assert.deepEqual(modelOverrides(p), new Map([["crambin", ["N_CHAINS", "Q_MAX"]]]))
})

test("model: a value equal to the project's removes the override", () => {
    const { g, p } = setup({ N_ADAPT: 450 })
    const a = loadModel(p, "crambin", g).settings
    a.set({ N_ADAPT: 500, Q_MAX: 0.3 })
    a.save()
    loadModel(p, "other", g).settings.set({ N_DRAWS: 650 })
    const b = loadModel(p, "other", g).settings
    b.set({ N_DRAWS: 650 })
    b.save()
    const c = loadModel(p, "crambin", g).settings
    // N_ADAPT back to the project's 450: no override
    c.set({ N_ADAPT: 450 })
    assert.equal(c.isSaved("N_ADAPT"), false)
    c.save()
    assert.deepEqual(Object.keys(stored(p).crambin ?? {}), ["model"])
    const d = loadModel(p, "crambin", g).settings
    d.reset(["Q_MAX"])
    d.save()
    assert.deepEqual(Object.keys(stored(p)), ["other"], "the file stays sparse")
    // everything inherited: the file is `{}`, never deleted
    const e = loadModel(p, "other", g).settings
    e.reset(["N_DRAWS"])
    e.save()
    assert.deepEqual(stored(p), {})
})

test("model: an override equal to the project's value in the file is kept", () => {
    const { g, p } = setup({ N_ADAPT: 450 })
    writeFileSync(
        modelSettingsFile(p),
        JSON.stringify({
            m: { sampler: { N_ADAPT: { value: 450 }, N_DRAWS: { value: 600 } } },
        }),
    )
    const r = loadModel(p, "m", g)
    assert.deepEqual(r.settings.overrides(), ["N_ADAPT", "N_DRAWS"])
    assert.deepEqual(r.wiped, [], "not an error")
    assert.deepEqual(modelOverrides(p), new Map([["m", ["N_ADAPT", "N_DRAWS"]]]))
    // saving another setting does not drop it
    r.settings.set({ N_DRAWS: 650 })
    r.settings.save()
    assert.deepEqual(stored(p).m?.sampler, {
        N_ADAPT: { value: 450 },
        N_DRAWS: { value: 650 },
    })
    assert.ok(!existsSync(join(p, "settings.log")))
    // an edit to the project's value, or a reset, removes it
    const again = loadModel(p, "m", g).settings
    again.set({ N_ADAPT: 450 })
    assert.equal(again.isSaved("N_ADAPT"), false)
    again.save()
    assert.deepEqual(stored(p).m?.sampler, { N_DRAWS: { value: 650 } })
})

test("model: run-level settings are refused on a change and wiped from the file", () => {
    const { g, p } = setup()
    const { settings } = loadModel(p, "crambin", g)
    for (const name of ["PLOT_COMPARE", "TABLE_SIGFIGS", "FIGURES_TEX", "PLOT_LW_MAP"]) {
        const ev = settings.set({ [name]: catalog.require(name).default })
        assert.equal(ev.ok, false, name)
        assert.match(ev.errors.get(name) ?? "", /whole run/)
    }
    assert.equal(settings.evaluate({ PLOT_COMPARE: false, Q_MAX: 0.3 }).ok, false)
    assert.equal(settings.isSaved("Q_MAX"), false, "nothing of a refused change is made")
    assert.equal(settings.reset(["PLOT_COMPARE"]).ok, false)
    writeFileSync(
        modelSettingsFile(p),
        JSON.stringify({
            crambin: {
                plots: { PLOT_COMPARE: { value: false } },
                output: { FIGURES_FORMATS: { value: ["svg"] }, VAL_SIGMA: { value: 3 } },
            },
            kept: { plots: { PLOT_COMPARE: { value: false } } },
        }),
    )
    const r = loadModel(p, "crambin", g)
    assert.deepEqual(
        r.wiped.map((w) => w.setting).sort(),
        ["FIGURES_FORMATS", "PLOT_COMPARE"],
    )
    assert.deepEqual(r.settings.overrides(), ["VAL_SIGMA"])
    assert.deepEqual(r.notices, [], "a setting the sheets do not show has no notice")
    assert.deepEqual(stored(p).crambin, { output: { VAL_SIGMA: { value: 3 } } })
    // another model's table is not ours to touch, even with a run-level setting in it
    assert.deepEqual(stored(p).kept, { plots: { PLOT_COMPARE: { value: false } } })
    const log = readFileSync(join(p, "settings.log"), "utf-8")
    assert.match(
        log,
        /\tmodel crambin: PLOT_COMPARE\tfalse\tis a setting of the whole run\n/,
    )
    // and they never appear in the overrides of the list
    assert.deepEqual(modelOverrides(p).get("kept"), undefined)
})

test("model: an invalid value is wiped on load, with a notice and a log line", () => {
    const { g, p } = setup()
    writeFileSync(
        modelSettingsFile(p),
        JSON.stringify({
            m: { sampler: { N_CHAINS: { value: -3 }, N_DRAWS: { value: 300 } } },
            n: { sampler: { N_CHAINS: { value: 2 } } },
        }),
    )
    const r = loadModel(p, "m", g)
    assert.deepEqual(r.wiped.map((w) => w.setting), ["N_CHAINS"])
    assert.deepEqual(r.notices, [{ setting: "N_CHAINS", message: "reset to project" }])
    assert.equal(r.settings.notices.get("N_CHAINS"), "reset to project")
    assert.deepEqual(stored(p), {
        m: { sampler: { N_DRAWS: { value: 300 } } },
        n: { sampler: { N_CHAINS: { value: 2 } } },
    })
    assert.match(
        readFileSync(join(p, "settings.log"), "utf-8"),
        /\tmodel m: N_CHAINS\t-3\tmust be at least 1\n/,
    )
    assert.equal(loadModel(p, "m", g).wiped.length, 0, "wiped once")
})

test("model: a rule over the project's values wipes the override that breaks it", () => {
    const { g, p } = setup({ Q_MAX: 0.2 })
    writeFileSync(
        modelSettingsFile(p),
        JSON.stringify({ m: { model: { Q_MIN: { value: 0.5 } } } }),
    )
    const r = loadModel(p, "m", g)
    assert.deepEqual(r.wiped.map((w) => w.setting), ["Q_MIN"])
    assert.equal(r.settings.get("Q_MIN"), null)
    // a change is checked against the project's value too
    const { settings } = loadModel(p, "m", g)
    const ev = settings.evaluate({ Q_MIN: 0.5 })
    assert.equal(ev.ok, false)
    assert.equal(ev.errors.get("Q_MIN"), "must be below Q_MAX")
    assert.equal(settings.evaluate({ Q_MIN: 0.05 }).ok, true)
})

test("model: a file or table that cannot be read is kept as .corrupt", () => {
    const { g, p } = setup()
    writeFileSync(modelSettingsFile(p), "[1,2")
    const r = loadModel(p, "m", g)
    assert.equal(r.reset, true)
    assert.ok(existsSync(`${modelSettingsFile(p)}.corrupt`))
    assert.ok(!existsSync(modelSettingsFile(p)))
    assert.deepEqual(r.settings.overrides(), [])
    // a table that is no object is replaced (Julia refuses it), the others kept
    writeFileSync(
        modelSettingsFile(p),
        JSON.stringify({ m: 5, n: { sampler: { N_DRAWS: { value: 9 } } } }),
    )
    const r2 = loadModel(p, "m", g)
    assert.equal(r2.reset, true)
    assert.deepEqual(stored(p), { n: { sampler: { N_DRAWS: { value: 9 } } } })
    assert.deepEqual(modelOverrides(p), new Map([["n", ["N_DRAWS"]]]))
})

test("model: two copies changing different settings or models both keep their work", () => {
    const { g, p } = setup()
    const a = loadModel(p, "crambin", g).settings
    const b = loadModel(p, "crambin", g).settings
    const other = loadModel(p, "other", g).settings
    a.set({ Q_MAX: 0.3 })
    b.set({ N_CHAINS: 6, N_DRAWS: 100 })
    other.set({ N_DRAWS: 650 })
    a.save()
    b.save()
    other.save()
    assert.deepEqual(stored(p), {
        crambin: {
            model: { Q_MAX: { value: 0.3 } },
            sampler: { N_CHAINS: { value: 6 }, N_DRAWS: { value: 100 } },
        },
        other: { sampler: { N_DRAWS: { value: 650 } } },
    })
    // the same setting: the last save wins; a copy that reset one setting removes only it
    a.set({ N_CHAINS: 4 })
    b.reset(["Q_MAX"])
    a.save()
    b.save()
    const final = loadModel(p, "crambin", g).settings
    assert.equal(final.get("N_CHAINS"), 4)
    assert.equal(final.isSaved("Q_MAX"), false)
    assert.equal(final.get("N_DRAWS"), 100)
    // this copy took over what was written
    assert.deepEqual(b.overrides().sort(), ["N_CHAINS", "N_DRAWS"])
})

test("model: saving into a deleted project makes nothing", () => {
    const { g, p } = setup()
    const { settings } = loadModel(p, "crambin", g)
    settings.set({ Q_MAX: 0.3 })
    rmSync(p, { recursive: true })
    assert.throws(() => settings.save(), ProjectGoneError)
    assert.ok(!existsSync(p))
    assert.throws(() => loadModel(p, "crambin", g), ProjectGoneError)
    assert.ok(!existsSync(p))
})

test("model: the overrides of the list are read without a change", () => {
    const { g, p } = setup()
    assert.deepEqual(modelOverrides(p), new Map())
    writeFileSync(
        modelSettingsFile(p),
        JSON.stringify({
            a: {
                sampler: { N_CHAINS: { value: 4 } },
                model: { Q_MAX: { value: 0.3 }, NOT_A_SETTING: { value: 1 } },
            },
            b: {},
            c: 3,
        }),
    )
    const before = readFileSync(modelSettingsFile(p), "utf-8")
    assert.deepEqual(modelOverrides(p), new Map([["a", ["N_CHAINS", "Q_MAX"]]]))
    assert.equal(readFileSync(modelSettingsFile(p), "utf-8"), before)
    void g
})
