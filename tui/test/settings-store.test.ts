// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/settings-store.ts: the store, the theme and the project settings.

import assert from "node:assert/strict"
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { writeJson } from "../src/core/file-system.js"
import { checkRelations, defaultCatalog } from "../src/store/settings.js"
import {
    type LoadResult,
    loadGlobal,
    loadProject,
    readThemeName,
    settingsFile,
    themeFile,
    writeThemeName,
} from "../src/store/settings-store.js"
import { defaultTheme, type ThemeName, themeByName, themes } from "../src/ui/theme.js"
import { tempDir as tmp } from "./support/fixtures.js"

// ========================================================================================
// 1. Store
// ========================================================================================

const catalog = defaultCatalog()

/** A new empty folder below the temporary folder. */

const read = (dir: string, name: string): string | undefined => {
    const file = join(dir, name)
    return existsSync(file) ? readFileSync(file, "utf-8") : undefined
}

/** A settings file text that saves each `[setting, raw]` of `rows` on its sheet. */
function fileWith(...rows: [string, unknown][]): string {
    const sheets: Record<string, Record<string, { value: unknown }>> = {}
    for (const [name, value] of rows) {
        const sheet = catalog.require(name).sheet
        sheets[sheet] ??= {}
        sheets[sheet][name] = { value }
    }
    return writeJson(sheets)
}

/** The saved values of a folder's file, setting name to value. */
function savedValues(dir: string): Record<string, unknown> {
    const file = JSON.parse(read(dir, "settings.json") as string) as Record<
        string,
        Record<string, { value: unknown }>
    >
    const out: Record<string, unknown> = {}
    for (const sheet of Object.values(file))
        for (const [name, entry] of Object.entries(sheet)) out[name] = entry.value
    return out
}

const wipedSettings = (r: LoadResult): string[] => r.wiped.map((w) => w.setting).sort()

test("the first load makes an empty file that Julia reads, ", () => {
    const dir = tmp()
    const r = loadGlobal(dir)
    assert.deepEqual(JSON.parse(read(dir, "settings.json") as string), {})
    assert.deepEqual(r.wiped, [])
    assert.equal(r.reset, false)
    for (const d of catalog.defs()) assert.deepEqual(r.settings.get(d.name), d.default)
})

test("a save writes the shape Julia reads, in the order of the sheets", () => {
    const dir = tmp()
    const { settings } = loadGlobal(dir)
    assert.equal(
        settings.set({
            N_DRAWS: 900,
            N_ADAPT: 450,
            PLOT_COLOUR_MAP: "darkorange",
            FIGURES_FORMATS: ["svg", "pdf"],
        }).ok,
        true,
    )
    settings.save()
    const text = read(dir, "settings.json") as string
    assert.deepEqual(JSON.parse(text), {
        sampler: { N_ADAPT: { value: 450 }, N_DRAWS: { value: 900 } },
        output: { FIGURES_FORMATS: { value: ["pdf", "svg"] } },
        plots: { PLOT_COLOUR_MAP: { value: "darkorange" } },
    })
    assert.ok(text.endsWith("}\n"), "a final newline")
    assert.match(text, /\n {2}"sampler": \{\n {4}"N_ADAPT": \{\n {6}"value": 450/)
    assert.ok(text.indexOf('"N_ADAPT"') < text.indexOf('"N_DRAWS"'))
    assert.deepEqual(
        readdirSync(dir).filter((f) => f.endsWith(".tmp")),
        [],
    )
    const again = loadGlobal(dir)
    assert.equal(again.settings.get("N_ADAPT"), 450)
    assert.equal(again.settings.get("PLOT_COLOUR_MAP"), "darkorange")
    assert.deepEqual(again.settings.get("FIGURES_FORMATS"), ["pdf", "svg"])
    assert.equal(again.settings.get("N_CHAINS"), catalog.require("N_CHAINS").default)
    assert.deepEqual(again.wiped, [])
})

test("colours, tuples and records are written as plain JSON", () => {
    const dir = tmp()
    const { settings } = loadGlobal(dir)
    assert.equal(
        settings.set({
            PLOT_COLOUR_DATA: "#ff0000",
            PLOT_COLOUR_BAND: ["red", 0.5],
            PLOT_PREVIEW_SIZE: { width: 80, height: 24 },
        }).ok,
        true,
    )
    settings.save()
    const text = read(dir, "settings.json") as string
    const plots = JSON.parse(text).plots
    assert.deepEqual(plots.PLOT_COLOUR_DATA, { value: "#ff0000" })
    assert.deepEqual(plots.PLOT_COLOUR_BAND, { value: ["red", 0.5] })
    assert.deepEqual(plots.PLOT_PREVIEW_SIZE, { value: { width: 80, height: 24 } })
})

test("a load of a good file changes nothing", () => {
    const dir = tmp()
    const text = fileWith(
        ["N_ADAPT", 450],
        ["PLOT_COLOUR_MAP", "darkorange"],
        ["FIGURES_FORMATS", ["svg", "pdf"]],
    )
    writeFileSync(settingsFile(dir), text)
    const r = loadGlobal(dir)
    assert.equal(read(dir, "settings.json"), text)
    assert.equal(r.settings.get("N_ADAPT"), 450)
    assert.deepEqual(r.settings.get("FIGURES_FORMATS"), ["pdf", "svg"])
    assert.deepEqual(r.wiped, [])
})

test("a wiped value is a line of settings.log: time, setting, bad value, reason", () => {
    const dir = tmp()
    writeFileSync(settingsFile(dir), fileWith(["N_ADAPT", 0], ["N_DRAWS", 900]))
    assert.equal(read(dir, "settings.log"), undefined, "nothing loaded, nothing logged")
    loadGlobal(dir)
    const lines = (read(dir, "settings.log") as string).trim().split("\n")
    assert.equal(lines.length, 1)
    const [stamp, setting, value, reason] = (lines[0] as string).split("\t")
    assert.ok(!Number.isNaN(Date.parse(stamp as string)))
    assert.deepEqual([setting, value], ["N_ADAPT", "0"])
    assert.match(reason as string, /at least 1/)
    // a clean load adds nothing
    loadGlobal(dir)
    assert.equal((read(dir, "settings.log") as string).trim().split("\n").length, 1)
})

test("a value that is not valid is wiped and noticed, once", () => {
    const dir = tmp()
    writeFileSync(
        settingsFile(dir),
        fileWith(["N_ADAPT", 0], ["N_DRAWS", 900], ["PLOT_COLOUR_MAP", "nope"]),
    )
    const r = loadGlobal(dir)
    assert.equal(r.settings.get("N_ADAPT"), 300)
    assert.equal(r.settings.get("PLOT_COLOUR_MAP"), "crimson")
    assert.equal(r.settings.get("N_DRAWS"), 900)
    assert.deepEqual(wipedSettings(r), ["N_ADAPT", "PLOT_COLOUR_MAP"])
    const adapt = r.wiped.find((w) => w.setting === "N_ADAPT")
    assert.equal(adapt?.value, 0)
    assert.match(adapt?.reason ?? "", /at least 1/)
    assert.deepEqual(savedValues(dir), { N_DRAWS: 900 })
    assert.deepEqual(
        r.notices.map((n) => n.message),
        ["reset to default", "reset to default"],
    )
    assert.equal(r.settings.notices.get("N_ADAPT"), "reset to default")
    assert.equal(r.settings.notices.has("N_DRAWS"), false)
    const again = loadGlobal(dir)
    assert.deepEqual(again.wiped, [])
    again.settings.notices.set("N_ADAPT", "x")
    assert.equal(again.settings.set({ N_ADAPT: 400 }).ok, true)
    assert.equal(
        again.settings.notices.has("N_ADAPT"),
        false,
        "setting takes the notice away",
    )
})

test("every kind of bad entry is wiped", () => {
    const cases: [string, string][] = [
        ["an entry that is no map", '{"sampler": {"N_ADAPT": 5}}'],
        ["an entry that is null", '{"sampler": {"N_ADAPT": null}}'],
        ["an entry that is an array", '{"sampler": {"N_ADAPT": [1, 2]}}'],
        ["a value of the wrong type", fileWith(["N_ADAPT", "300"])],
        ["a value out of range", fileWith(["N_ADAPT", -1])],
        ["a null value", fileWith(["N_ADAPT", null])],
        [
            "a fraction given to a whole number setting",
            '{"sampler": {"N_ADAPT": {"value": 300.5}}}',
        ],
    ]
    for (const [what, text] of cases) {
        const dir = tmp()
        writeFileSync(settingsFile(dir), text)
        const r = loadGlobal(dir)
        assert.equal(r.settings.get("N_ADAPT"), 300, what)
        assert.deepEqual(wipedSettings(r), ["N_ADAPT"], what)
        assert.deepEqual(savedValues(dir), {}, what)
    }
})

test("a file that cannot be read is kept aside and replaced", () => {
    const bad = [
        "{ this is not (json",
        "",
        "  \n  ",
        "[1, 2, 3]",
        "42",
        '"hello"',
        "null",
        '{"sampler": {"N_ADAPT": {"value": 5}}',
        "}",
        "{'a': 1}",
        '{"a": 1,}',
        '// a comment\n{"sampler": {}}',
        "\u0001\u0002\u0003\u0000￿",
    ]
    for (const text of bad) {
        const dir = tmp()
        writeFileSync(settingsFile(dir), text)
        const r = loadGlobal(dir)
        assert.equal(r.reset, true, JSON.stringify(text))
        assert.equal(read(dir, "settings.json.corrupt"), text, "the old file is kept")
        assert.deepEqual(JSON.parse(read(dir, "settings.json") as string), {})
        const again = loadGlobal(dir)
        assert.equal(again.reset, false, "the replacement reads")
        assert.deepEqual(again.wiped, [])
    }
})

test("values that break a rule together are wiped together, with a default alone", () => {
    const dir = tmp()
    writeFileSync(settingsFile(dir), fileWith(["SASA_N_OCC", 200], ["SHELL_SAMPLE", 100]))
    const r = loadGlobal(dir)
    assert.equal(r.settings.get("SASA_N_OCC"), 104)
    assert.equal(r.settings.get("SHELL_SAMPLE"), 256)
    assert.deepEqual(wipedSettings(r), ["SASA_N_OCC", "SHELL_SAMPLE"])
    assert.deepEqual(savedValues(dir), {})
    writeFileSync(settingsFile(dir), fileWith(["BOUNDS_δρ₁₂", [-3, 0.5]], ["κ_δρ₁₂", 20]))
    const alone = loadGlobal(dir)
    assert.deepEqual(alone.settings.get("BOUNDS_δρ₁₂"), [-10, 2])
    assert.equal(alone.settings.get("κ_δρ₁₂"), 20)
    assert.deepEqual(savedValues(dir), { "κ_δρ₁₂": 20 })
})

test("a file of many bad values is cleaned in one load", () => {
    const dir = tmp()
    const rows: [string, unknown][] = [
        ["N_ADAPT", 0],
        ["N_DRAWS", "x"],
        ["N_CHAINS", -3],
        ["TARGET_ACCEPT", 100],
        ["VAL_SIGMA", 0],
        ["FIGURES_TEX", 1],
        ["FIGURES_FORMATS", []],
        ["PLOT_COLOUR_MAP", "not-a-colour"],
        ["PLOT_TEXT_FONT", ""],
        ["CHAIN_START_RADII", [1, 2]],
        ["PLOT_PREVIEW_SIZE", { width: 0, height: 1 }],
        ["PLOT_COLOUR_BAND", ["red", 9]],
    ]
    writeFileSync(settingsFile(dir), fileWith(...rows))
    const r = loadGlobal(dir)
    assert.equal(r.wiped.length, 12)
    assert.deepEqual(savedValues(dir), {})
    for (const d of catalog.defs()) assert.deepEqual(r.settings.get(d.name), d.default)
})

test("unknown names and screens are dropped quietly", () => {
    const dir = tmp()
    writeFileSync(
        settingsFile(dir),
        '{"sampler": {"N_ADAPT": {"value": 450}, "NOT_A_SETTING": {"value": 1}},' +
            ' "nowhere": {"X": {"value": 2}}}',
    )
    const r = loadGlobal(dir)
    assert.equal(r.settings.get("N_ADAPT"), 450)
    assert.deepEqual(r.wiped, [])
    assert.equal(r.settings.catalog.get("NOT_A_SETTING"), undefined)
})

test("a change is checked before it is made", () => {
    const { settings } = loadGlobal(tmp())
    const bad: Record<string, unknown>[] = [
        { N_ADAPT: 0 },
        { N_ADAPT: "9" },
        { N_ADAPT: 2.5 },
        { TARGET_ACCEPT: 100 },
        { PLOT_COLOUR_MAP: "nope" },
        { PLOT_TEXT_FONT: "" },
        { FIGURES_FORMATS: [] },
        { FIGURES_FORMATS: ["gif"] },
        { PLOT_COLOUR_BAND: ["red", 2] },
        { SASA_N_OCC: 9999 },
        { "MODE_δρ₁₂": 50 },
        { NOT_A_SETTING: 1 },
    ]
    for (const changes of bad) {
        const ev = settings.set(changes)
        assert.equal(ev.ok, false, JSON.stringify(changes))
        assert.equal(ev.values.size, 0)
        assert.ok([...ev.errors.values()].every((e) => e.length > 0))
    }
    for (const d of catalog.defs()) assert.deepEqual(settings.get(d.name), d.default)
    assert.equal(settings.isSaved("N_ADAPT"), false)
})

test("rules that tie settings together hold across a change, also among several", () => {
    const { settings } = loadGlobal(tmp())
    assert.equal(settings.set({ SHELL_SAMPLE: 300 }).ok, true)
    assert.equal(settings.set({ SASA_N_OCC: 250 }).ok, true)
    const low = settings.set({ SHELL_SAMPLE: 200 })
    assert.equal(low.ok, false)
    assert.match(low.errors.get("SHELL_SAMPLE") ?? "", /SASA_N_OCC|SHELL_SAMPLE/)
    assert.equal(settings.get("SHELL_SAMPLE"), 300)
    assert.ok(settings.set({ SASA_N_OCC: 301 }).errors.has("SASA_N_OCC"))
    assert.equal(settings.set({ SASA_N_OCC: 300 }).ok, true, "at the edge is fine")
    const both = settings.set({ SHELL_SAMPLE: 100, SASA_N_OCC: 90 })
    assert.equal(both.ok, true, "two settings of a rule can change together")
    assert.deepEqual(checkRelations(catalog.relations, settings.values()), [])
})

test("q limits: Q_MIN below Q_MAX when both are given; null is saved as null", () => {
    const dir = tmp()
    const { settings } = loadGlobal(dir)
    const bad = settings.evaluate({ Q_MIN: 0.05, Q_MAX: 0.02 })
    assert.equal(bad.ok, false)
    assert.equal(bad.errors.get("Q_MIN"), "must be below Q_MAX")
    assert.equal(bad.errors.get("Q_MAX"), "must be above Q_MIN")
    assert.equal(settings.set({ Q_MAX: 0.3 }).ok, true)
    assert.equal(settings.evaluate({ Q_MIN: 0.4 }).ok, false, "against the saved Q_MAX")
    assert.equal(settings.set({ Q_MIN: 0.05, Q_MAX: null }).ok, true)
    assert.equal(settings.get("Q_MAX"), null)
    assert.equal(settings.set({ Q_MIN: null }).ok, true)
    settings.set({
        EXCLUDE_Q: [[0.1, 0.2]],
        CHAINS: ["A", "B"],
        LMAX: null,
        MODEL: 2,
        ADD_HYDROGENS: false,
    })
    settings.save()
    const saved = savedValues(dir)
    assert.deepEqual(saved.Q_MIN, null)
    assert.deepEqual(saved.Q_MAX, null)
    assert.deepEqual(saved.EXCLUDE_Q, [[0.1, 0.2]])
    assert.deepEqual(saved.CHAINS, ["A", "B"])
    assert.deepEqual(saved.LMAX, null)
    assert.equal(saved.ADD_HYDROGENS, false)
    const again = loadGlobal(dir)
    assert.deepEqual(again.wiped, [])
    assert.equal(again.settings.get("Q_MAX"), null)
    assert.deepEqual(again.settings.get("CHAINS"), ["A", "B"])
    const crossed = loadGlobal(
        (() => {
            const d = tmp()
            const text = fileWith(["Q_MIN", 0.5], ["Q_MAX", 0.1])
            writeFileSync(join(d, "settings.json"), text)
            return d
        })(),
    )
    assert.deepEqual(wipedSettings(crossed), ["Q_MAX", "Q_MIN"])
})

test("reset goes back to the default, and the file follows", () => {
    const dir = tmp()
    const { settings } = loadGlobal(dir)
    settings.set({ N_ADAPT: 450, N_DRAWS: 900 })
    assert.equal(settings.resetValue("N_ADAPT"), 300)
    assert.equal(settings.reset(["N_ADAPT"]).ok, true)
    assert.equal(settings.get("N_ADAPT"), 300)
    assert.equal(settings.isSaved("N_ADAPT"), false)
    settings.save()
    assert.deepEqual(savedValues(dir), { N_DRAWS: 900 })
    settings.set({ SHELL_SAMPLE: 400, SASA_N_OCC: 300 })
    assert.equal(
        settings.reset(["SHELL_SAMPLE"]).ok,
        false,
        "it would break the rule with SASA_N_OCC",
    )
    assert.equal(settings.get("SHELL_SAMPLE"), 400)
    assert.equal(settings.reset(["SHELL_SAMPLE", "SASA_N_OCC"]).ok, true)
})

// ========================================================================================
// 2. Theme preference
// ========================================================================================

const known = themes.map((theme) => theme.nm)
const readTheme = (dir: string) => readThemeName(dir, known, defaultTheme.nm)

test("the default theme is one of the themes", () => {
    assert.ok(themes.includes(defaultTheme))
})

test("no file means the default", () => {
    assert.equal(readTheme(tmp()), defaultTheme.nm)
})

test("what is saved is what is read, for every theme there is", () => {
    const dir = tmp()
    for (const name of known) {
        assert.ok(writeThemeName(dir, name))
        assert.equal(readTheme(dir), name)
    }
})

test("a name no theme has, or a garbled file, means the default", () => {
    const dir = tmp()
    writeFileSync(themeFile(dir), '{"theme":"no such theme"}')
    assert.equal(readTheme(dir), defaultTheme.nm)
    writeFileSync(themeFile(dir), "{ not json")
    assert.equal(readTheme(dir), defaultTheme.nm)
    // the file of the first version said `mode`, which no theme is called
    writeFileSync(themeFile(dir), '{"mode":"light"}')
    assert.equal(readTheme(dir), defaultTheme.nm)
})

test("a garbled file is kept as .corrupt when the theme is saved", () => {
    const dir = tmp()
    writeFileSync(themeFile(dir), "{ not json")
    assert.ok(writeThemeName(dir, "rose"))
    assert.equal(readFileSync(`${themeFile(dir)}.corrupt`, "utf-8"), "{ not json")
    assert.equal(readTheme(dir), "rose")
    assert.ok(existsSync(themeFile(dir)))
})

test("an unwritable folder is not an error", () => {
    // a folder below a regular file can never be made
    const dir = tmp()
    writeFileSync(join(dir, "a-file"), "x")
    assert.equal(writeThemeName(join(dir, "a-file", "sub"), "rose"), false)
})

test("the registry: unique names, a logo each, findable by name", () => {
    assert.equal(new Set(known).size, themes.length)
    for (const theme of themes) {
        assert.ok(theme.lg !== "" && theme.nm !== "")
        assert.equal(themeByName(theme.nm), theme)
    }
    assert.equal(themeByName("nope"), undefined)
})

test("a theme name is checked by the compiler against the theme arrays", () => {
    const real: ThemeName = "graphite"
    // @ts-expect-error a name that is in neither array does not compile
    const missing: ThemeName = "no such theme"
    // `tsc` fails here if the line above ever stops being an error
    assert.ok(themeByName(real))
    assert.equal(themeByName(missing), undefined)
})

// ========================================================================================
// 3. Project settings
// ========================================================================================

/** A project folder in a BAYSOL folder. */
function projectIn(root: string, id: string): string {
    const dir = join(root, "projects", id)
    mkdirSync(dir, { recursive: true })
    return dir
}

/** A global folder whose settings hold `values`, saved. */
function globalWith(values: Record<string, unknown>): string {
    const g = tmp()
    const { settings } = loadGlobal(g)
    assert.equal(settings.set(values).ok, true)
    settings.save()
    return g
}

test("the first load makes an exact copy of the global settings", () => {
    const g = globalWith({ N_ADAPT: 450 })
    const p = projectIn(g, "p")
    const r = loadProject(p, g)
    assert.equal(read(p, "settings.json"), read(g, "settings.json"))
    assert.equal(r.settings.get("N_ADAPT"), 450)
    assert.deepEqual(r.wiped, [])
    assert.equal(r.reset, false)
    const g2 = tmp()
    const p2 = projectIn(g2, "q")
    loadProject(p2, g2)
    assert.ok(read(g2, "settings.json") !== undefined, "the global settings are made first")
    assert.equal(read(p2, "settings.json"), read(g2, "settings.json"))
})

test("a project does not follow later changes; a reset goes to the global value", () => {
    const g = tmp()
    const p = projectIn(g, "p")
    loadProject(p, g)
    const global = loadGlobal(g).settings
    global.set({ N_ADAPT: 900 })
    global.save()
    const r = loadProject(p, g)
    assert.equal(r.settings.get("N_ADAPT"), 300, "its own value is what it was")
    assert.equal(r.settings.resetValue("N_ADAPT"), 900)
    assert.equal(
        r.settings.resetValue("N_DRAWS"),
        700,
        "a setting the global ones did not change",
    )
    assert.equal(
        loadGlobal(g).settings.resetValue("N_ADAPT"),
        300,
        "the global ones reset to the defaults",
    )
    assert.equal(r.settings.reset(["N_ADAPT"]).ok, true)
    assert.equal(r.settings.get("N_ADAPT"), 900)
    r.settings.save()
    assert.deepEqual(savedValues(p).N_ADAPT, 900)
})

test("an invalid value goes back to the global value", () => {
    const g = globalWith({ N_ADAPT: 450, PLOT_COLOUR_MAP: "darkorange" })
    const p = projectIn(g, "p")
    writeFileSync(
        settingsFile(p),
        fileWith(
            ["N_ADAPT", 0],
            ["N_DRAWS", 900],
            ["PLOT_COLOUR_MAP", "nope"],
            ["RNG_SEED", 7],
        ),
    )
    const r = loadProject(p, g)
    assert.equal(r.settings.get("N_ADAPT"), 450, "the global value, not the default 300")
    assert.equal(r.settings.get("PLOT_COLOUR_MAP"), "darkorange")
    assert.equal(r.settings.get("N_DRAWS"), 900)
    assert.equal(r.settings.get("RNG_SEED"), 7)
    assert.deepEqual(r.wiped.map((w) => w.setting).sort(), ["N_ADAPT", "PLOT_COLOUR_MAP"])
    assert.deepEqual(savedValues(p), {
        N_ADAPT: 450,
        N_DRAWS: 900,
        PLOT_COLOUR_MAP: "darkorange",
        RNG_SEED: 7,
    })
    assert.deepEqual(
        r.notices.map((n) => n.message),
        ["reset to global", "reset to global"],
    )
    assert.equal(r.settings.notices.get("N_ADAPT"), "reset to global")
    assert.equal(r.settings.notices.has("N_DRAWS"), false)
})

test("a wiped value at the global default goes to that default", () => {
    const g = tmp()
    loadGlobal(g)
    const p = projectIn(g, "p")
    writeFileSync(settingsFile(p), fileWith(["N_ADAPT", "x"]))
    const r = loadProject(p, g)
    assert.equal(r.settings.get("N_ADAPT"), 300)
    assert.deepEqual(
        r.wiped.map((w) => w.setting),
        ["N_ADAPT"],
    )
})

test("values that break a rule together go back to the global ones", () => {
    const g = globalWith({ SHELL_SAMPLE: 300 })
    const p = projectIn(g, "p")
    writeFileSync(settingsFile(p), fileWith(["SASA_N_OCC", 250], ["SHELL_SAMPLE", 100]))
    const r = loadProject(p, g)
    assert.equal(r.settings.get("SHELL_SAMPLE"), 300)
    assert.equal(r.settings.get("SASA_N_OCC"), 104)
    assert.deepEqual(r.wiped.map((w) => w.setting).sort(), ["SASA_N_OCC", "SHELL_SAMPLE"])
})

test("a project file that cannot be read is replaced by the global settings", () => {
    const g = globalWith({ N_ADAPT: 450 })
    const p = projectIn(g, "p")
    for (const bad of ["{ not json", "", "[1, 2]", "null", "42"]) {
        writeFileSync(settingsFile(p), bad)
        const r = loadProject(p, g)
        assert.equal(r.reset, true, JSON.stringify(bad))
        assert.equal(read(p, "settings.json.corrupt"), bad)
        assert.equal(r.settings.get("N_ADAPT"), 450)
        assert.equal(read(p, "settings.json"), read(g, "settings.json"))
        assert.equal(loadProject(p, g).reset, false, "and it reads again")
    }
})

test("a save in a project stays in the project", () => {
    const g = tmp()
    loadGlobal(g)
    const before = read(g, "settings.json")
    const p = projectIn(g, "p")
    const { settings } = loadProject(p, g)
    assert.equal(settings.set({ N_ADAPT: 500 }).ok, true)
    settings.save()
    assert.deepEqual(savedValues(p), { N_ADAPT: 500 })
    assert.equal(read(g, "settings.json"), before, "the global file did not change")
    assert.equal(loadProject(p, g).settings.get("N_ADAPT"), 500)
    const file = read(p, "settings.json")
    for (const changes of [
        { N_ADAPT: 0 },
        { PLOT_COLOUR_MAP: "nope" },
        { SASA_N_OCC: 9999 },
        { "MODE_δρ₁₂": 50 },
    ])
        assert.equal(settings.set(changes).ok, false)
    settings.save()
    assert.equal(read(p, "settings.json"), file)
})

test("projects are independent", () => {
    const g = tmp()
    loadGlobal(g)
    const a = projectIn(g, "a")
    const b = projectIn(g, "b")
    const sa = loadProject(a, g).settings
    const sb = loadProject(b, g).settings
    sa.set({ N_ADAPT: 111 })
    sa.save()
    sb.set({ N_ADAPT: 222 })
    sb.save()
    assert.equal(loadProject(a, g).settings.get("N_ADAPT"), 111)
    assert.equal(loadProject(b, g).settings.get("N_ADAPT"), 222)
    assert.equal(loadGlobal(g).settings.get("N_ADAPT"), 300)
})

test("a bad global file is mended by a project load too", () => {
    const g = tmp()
    const p = projectIn(g, "p")
    writeFileSync(settingsFile(g), fileWith(["N_ADAPT", -4]))
    const r = loadProject(p, g)
    assert.equal(r.settings.get("N_ADAPT"), 300)
    assert.deepEqual(savedValues(g), {})
    assert.equal(read(p, "settings.json"), read(g, "settings.json"))
})
