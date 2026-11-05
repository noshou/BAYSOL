// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import {
    existsSync,
    mkdtempSync,
    readdirSync,
    readFileSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { writeJson } from "../src/core/files.js"
import { defaultCatalog } from "../src/store/settings-defs.js"
import {
    type LoadResult,
    loadGlobal,
    settingsFile,
    soundCatalog,
} from "../src/store/settings-store.js"
import { checkRelations } from "../src/store/settings-validate.js"

const catalog = defaultCatalog()

/** A new empty folder below the temporary folder. */
const tmp = (): string => mkdtempSync(join(tmpdir(), "baysol-test-"))

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

test("the first load makes an empty file that Julia reads, and logs nothing", () => {
    const dir = tmp()
    const r = loadGlobal(dir)
    assert.deepEqual(JSON.parse(read(dir, "settings.json") as string), {})
    assert.deepEqual(r.wiped, [])
    assert.equal(r.reset, false)
    assert.equal(read(dir, "settings.log"), undefined)
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
    assert.equal(read(dir, "settings.log"), undefined)
})

test("a value that is not valid is wiped, logged and noticed, once", () => {
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
    const log = (read(dir, "settings.log") as string).trim().split("\n")
    assert.equal(log.length, 2)
    assert.match(log.join("\n"), /N_ADAPT: 0 is not valid/)
    assert.match(log.join("\n"), /reset to its default 300/)
    assert.match(log.join("\n"), /PLOT_COLOUR_MAP: "nope" is not valid/)
    assert.deepEqual(
        r.notices.map((n) => n.message),
        ["reset to default", "reset to default"],
    )
    assert.equal(r.settings.notices.get("N_ADAPT"), "reset to default")
    assert.equal(r.settings.notices.has("N_DRAWS"), false)
    const again = loadGlobal(dir)
    assert.deepEqual(again.wiped, [])
    assert.equal((read(dir, "settings.log") as string).trim().split("\n").length, 2)
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
        assert.match(read(dir, "settings.log") as string, /could not be read/)
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
    assert.equal((read(dir, "settings.log") as string).trim().split("\n").length, 12)
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
        assert.ok(
            [...ev.errors.values()].every(
                (e) => e.message.length > 0 && e.short.length > 0,
            ),
        )
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
    assert.match(low.errors.get("SHELL_SAMPLE")?.message ?? "", /SASA_N_OCC|SHELL_SAMPLE/)
    assert.equal(low.errors.get("SHELL_SAMPLE")?.short, "below SASA_N_OCC")
    assert.equal(settings.get("SHELL_SAMPLE"), 300)
    assert.equal(
        settings.set({ SASA_N_OCC: 301 }).errors.get("SASA_N_OCC")?.short,
        "above SHELL_SAMPLE",
    )
    assert.equal(settings.set({ SASA_N_OCC: 300 }).ok, true, "at the edge is fine")
    const both = settings.set({ SHELL_SAMPLE: 100, SASA_N_OCC: 90 })
    assert.equal(both.ok, true, "two settings of a rule can change together")
    assert.deepEqual(checkRelations(catalog.relations, settings.values()), [])
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

test("the bundled data is sound", () => {
    assert.equal(soundCatalog(), catalog)
})
