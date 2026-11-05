// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { writeJson } from "../src/core/files.js"
import { defaultCatalog } from "../src/store/settings-defs.js"
import {
    loadGlobal,
    loadProject,
    settingsFile,
} from "../src/store/settings-store.js"

const catalog = defaultCatalog()

/** A new empty folder below the temporary folder. */
const tmp = (): string => mkdtempSync(join(tmpdir(), "baysol-test-"))

/** A project folder in a BAYSOL folder. */
function projectIn(root: string, id: string): string {
    const dir = join(root, "projects", id)
    mkdirSync(dir, { recursive: true })
    return dir
}

const text = (dir: string, name: string): string | undefined => {
    const file = join(dir, name)
    return existsSync(file) ? readFileSync(file, "utf-8") : undefined
}

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
    const file = JSON.parse(text(dir, "settings.json") as string) as Record<
        string,
        Record<string, { value: unknown }>
    >
    const out: Record<string, unknown> = {}
    for (const sheet of Object.values(file))
        for (const [name, entry] of Object.entries(sheet)) out[name] = entry.value
    return out
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
    assert.equal(text(p, "settings.json"), text(g, "settings.json"))
    assert.equal(r.settings.get("N_ADAPT"), 450)
    assert.deepEqual(r.wiped, [])
    assert.equal(r.reset, false)
    const g2 = tmp()
    const p2 = projectIn(g2, "q")
    loadProject(p2, g2)
    assert.ok(text(g2, "settings.json") !== undefined, "the global settings are made first")
    assert.equal(text(p2, "settings.json"), text(g2, "settings.json"))
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
    const log = text(p, "settings.log") as string
    assert.match(log, /N_ADAPT: 0 is not valid/)
    assert.match(log, /reset to its global value 450/)
    assert.equal(text(g, "settings.log"), undefined, "the global folder has nothing to log")
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
        assert.equal(text(p, "settings.json.corrupt"), bad)
        assert.equal(r.settings.get("N_ADAPT"), 450)
        assert.equal(text(p, "settings.json"), text(g, "settings.json"))
        assert.match(text(p, "settings.log") as string, /copy of the global settings/)
        assert.equal(loadProject(p, g).reset, false, "and it reads again")
    }
})

test("a save in a project stays in the project", () => {
    const g = tmp()
    loadGlobal(g)
    const before = text(g, "settings.json")
    const p = projectIn(g, "p")
    const { settings } = loadProject(p, g)
    assert.equal(settings.set({ N_ADAPT: 500 }).ok, true)
    settings.save()
    assert.deepEqual(savedValues(p), { N_ADAPT: 500 })
    assert.equal(text(g, "settings.json"), before, "the global file did not change")
    assert.equal(loadProject(p, g).settings.get("N_ADAPT"), 500)
    const file = text(p, "settings.json")
    for (const changes of [
        { N_ADAPT: 0 },
        { PLOT_COLOUR_MAP: "nope" },
        { SASA_N_OCC: 9999 },
        { "MODE_δρ₁₂": 50 },
    ])
        assert.equal(settings.set(changes).ok, false)
    settings.save()
    assert.equal(text(p, "settings.json"), file)
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
    assert.equal(text(p, "settings.json"), text(g, "settings.json"))
})
