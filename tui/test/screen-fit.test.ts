// SPDX-License-Identifier: LGPL-3.0-or-later

// The rule of the owner (2026-11-09): everything the program shows fits the smallest
// terminal (80 x 24) and is brief, with no message cut mid-sentence by an ellipsis. The
// screens are drawn (Ink's `renderToString`) at 80 columns and at a wider terminal, over a
// scratch project with a failed run, and every line is measured; the messages the screens
// build from their own words are listed and measured against the note row.
//
// Contents:
//   1. The screens at 80 and 100 columns
//   2. The messages: none longer than the note row, none cut
//   3. The brief form of an error

import assert from "node:assert/strict"
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { createElement, type ReactElement } from "react"
import { appDir } from "../src/core/environment.js"
import { ChangedOnDiskError } from "../src/core/file-system.js"
import { displayWidth, wrapLine } from "../src/core/terminal.js"
import { CustomSolutesTable, RecipesTable } from "../src/screens/custom-solutes.js"
import { DataScreen } from "../src/screens/data-screen.js"
import { LogsRuns, modelsCell } from "../src/screens/logs-menu.js"
import { BufferLanding, MainMenu, ProjectMenu } from "../src/screens/menus.js"
import { ModelReferenceScreen } from "../src/screens/model-reference.js"
import { ModelsScreen } from "../src/screens/models.js"
import { noWorkbookNote, OpenRuns } from "../src/screens/open-runs.js"
import { ReferencesScreen } from "../src/screens/references-screen.js"
import { RunScreen } from "../src/screens/run-screens.js"
import { SettingsMenu, SettingsSheet } from "../src/screens/settings-screens.js"
import { SolutesTable } from "../src/screens/solutes.js"
import {
    type BufferRow,
    readConditions,
    saveRecipe,
    writeSolutes,
} from "../src/store/buffer.js"
import { writeData } from "../src/store/data.js"
import type { RunView } from "../src/store/run.js"
import {
    BRIEF_ERROR_WIDTH,
    briefError,
    failedNote,
    type OpenModel,
} from "../src/store/run-logs.js"
import { restoreErrorNote } from "../src/store/run-restores.js"
import { runBrief } from "../src/store/run-stamp.js"
import { globalScope, projectScope } from "../src/store/settings-store.js"
import { cornerLabels, fitCorner, legendRoom } from "../src/ui/frame.js"
import { destructiveQuestion } from "../src/ui/input.js"
import { drawScreen, fixtureText, tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. The screens at 80 and 100 columns
// ========================================================================================

/** A model name as long as the owner's examples. */
const MODEL = "SASDCQ2_fit3_model1"

/** A run folder name as Julia and the TUI write it. */
const RUN = "14-19-18-912_EST_-0500_2026-11-09"

/** The long error line Julia gives a model that did not converge. */
const LONG_ERROR =
    "NotConvergedError: the run did not converge: the worst R̂, 1.52, is above 1.01; " +
    "the smallest bulk ESS, 20.1, is below 400."

/**
 * A scratch data folder with one project that has a model, a buffer, data and a failed
 * run, and the environment pointed at it (the real folders are never touched).
 *
 * @returns the project (`id`, `dir`).
 */
function scratchProject(): { id: string; dir: string } {
    const home = tempDir("baysol-fit-")
    process.env.BAYSOL_HOME = home
    process.env.BAYSOL_CACHE = join(home, "cache")
    const dir = join(home, "projects", "SASDCQ2")
    mkdirSync(join(dir, "models"), { recursive: true })
    writeFileSync(
        join(dir, "project.json"),
        '{"id":"SASDCQ2","created":"2026-11-09T19:11:03Z"}',
    )
    const molecules = join(import.meta.dirname, "..", "..", "test", "fixtures", "molecules")
    copyFileSync(join(molecules, "1CRN-TEST.pdb"), join(dir, "models", `${MODEL}.pdb`))
    writeFileSync(join(dir, "buffer.json"), fixtureText("buffer/buffer.json"))
    const q = [0.01, 0.02, 0.03, 0.04]
    const curve = { q, i: [4, 3, 2, 1], sigma: [0.1, 0.1, 0.1, 0.1], dropped: 0 }
    writeData(dir, curve, "x.dat", "A-1", 12000)
    const run = join(dir, "runs", RUN)
    mkdirSync(join(run, "logs"), { recursive: true })
    writeFileSync(
        join(run, "run.json"),
        JSON.stringify({
            schema: 1,
            status: "failed",
            pid: 1,
            host: "nowhere",
            started: "2026-11-09T19:19:18Z",
            heartbeat: "2026-11-09T19:19:20Z",
            ended: "2026-11-09T19:19:20Z",
            models: [
                { name: MODEL, status: "failed", error: LONG_ERROR },
                { name: "SASDCQ2_fit3_model2", status: "done" },
            ],
        }),
    )
    writeFileSync(
        join(run, "logs", "run.LOG"),
        `datetime\tnow\n\n=== ERRORS ===\nmodel ${MODEL}: ${LONG_ERROR}\n`,
    )
    // a newer run in the flat layout that is done and has everything: the open-runs
    // legend then shows every key it can
    const flat = join(dir, "runs", "10-00-00-000_EST_-0500_2026-11-10")
    mkdirSync(flat, { recursive: true })
    writeFileSync(
        join(flat, "run.json"),
        JSON.stringify({
            schema: 1,
            status: "done",
            pid: 1,
            host: "nowhere",
            started: "2026-11-10T15:00:00Z",
            heartbeat: "2026-11-10T15:00:20Z",
            ended: "2026-11-10T15:00:20Z",
            models: [
                {
                    name: MODEL,
                    status: "done",
                    files: [`${MODEL}.xlsx`, `${MODEL}.tex`, `${MODEL}-plots.txt`],
                },
            ],
            compare: {
                status: "done",
                files: ["compare.tsv", "compare.tex", "compare-plots.txt"],
            },
        }),
    )
    for (const name of [`${MODEL}.xlsx`, `${MODEL}.tex`, "compare.tsv", "compare.tex"])
        writeFileSync(join(flat, name), "x")
    writeFileSync(join(flat, "run.LOG"), "datetime\tnow\n")
    return { id: "SASDCQ2", dir }
}

/** The run screen's view of a run that failed, with the long lines Julia printed. */
const failedView: RunView = {
    id: RUN,
    project: "SASDCQ2",
    phase: "failed",
    startedMs: 0,
    endedMs: 152000,
    note: briefError(LONG_ERROR),
    lines: [
        "=== model SASDCQ2_fit3_model1 ===",
        "Fit finished: reduced χ² = 0.87 on the measured points",
        "  ρₑ   0.3378  (0.3377–0.3379)",
        "  δρ₁  0.07634  (−0.9438 – 1.745)",
        "  Checks:  converged (R̂ 1.002)",
        `model ${MODEL} failed: ${LONG_ERROR}`,
    ],
}

/** Draws a screen on the default theme at some columns (24 rows). */
function draw(screen: ReactElement, columns: number): string[] {
    return drawScreen(screen, columns).split("\n")
}

test("every screen fits 80 x 24 and a wider terminal, and shows no cut message", () => {
    const project = scratchProject()
    const screens: Record<string, ReactElement> = {
        "main menu": createElement(MainMenu),
        "project menu": createElement(ProjectMenu, { project }),
        models: createElement(ModelsScreen, { project }),
        "model reference": createElement(ModelReferenceScreen, {
            project,
            file: `${MODEL}.pdb`,
            stem: MODEL,
        }),
        data: createElement(DataScreen, { project }),
        "reference fit": createElement(ReferencesScreen, { project }),
        "buffer landing": createElement(BufferLanding, { project }),
        "custom solutes": createElement(CustomSolutesTable),
        recipes: createElement(RecipesTable),
        "project settings": createElement(SettingsMenu, { scope: projectScope(project) }),
        "global settings": createElement(SettingsMenu, { scope: globalScope }),
        logs: createElement(LogsRuns, { project }),
        "open runs": createElement(OpenRuns, { project }),
        run: createElement(RunScreen, {
            session: { subscribe: () => () => {}, snapshot: () => failedView } as never,
        }),
    }
    // every settings sheet, of the project and of the program (their rows carry long names)
    for (const sheetId of ["output", "model", "sampler", "plots"] as const)
        for (const scope of [projectScope(project), globalScope])
            screens[`${scope.kind} sheet ${sheetId}`] = createElement(SettingsSheet, {
                scope,
                sheetId,
            })
    for (const [name, screen] of Object.entries(screens)) {
        for (const columns of [80, 100]) {
            const lines = draw(screen, columns)
            assert.ok(lines.length <= 24, `${name} at ${columns}: ${lines.length} rows`)
            for (const line of lines) {
                assert.ok(
                    displayWidth(line) <= columns,
                    `${name} at ${columns}: ${displayWidth(line)} cells in ${line}`,
                )
                assert.ok(!line.includes("…"), `${name} at ${columns} cuts text: ${line}`)
            }
        }
    }
})

test("the project menu: no run without a temperature, then shift+r at once", () => {
    const project = scratchProject()
    // an old buffer: pH and σ, no temperature
    assert.equal(readConditions(project.dir)?.temperature, undefined)
    const old = draw(createElement(ProjectMenu, { project }), 80).join("\n")
    assert.ok(old.includes("missing: temperature"), old)
    assert.ok(!old.includes("shift+r"), old)
    // with a temperature the project is ready: the key is offered, and nothing asks
    const rows = JSON.parse(fixtureText("buffer/buffer.json")).solutes as BufferRow[]
    writeSolutes(project.dir, rows, { pH: 7.4, "sigmaPh": 0.1, temperature: 4 })
    for (const columns of [80, 100]) {
        const text = draw(createElement(ProjectMenu, { project }), columns).join("\n")
        assert.ok(/run:\s+shift\+r/.test(text), text)
        assert.ok(!text.includes("temperature"), text)
        assert.ok(!text.includes("cannot run"), text)
    }
})

test("the conditions row shows pH, σ and the temperature at 80 x 24", () => {
    const rows = JSON.parse(fixtureText("buffer/buffer.json")).solutes as BufferRow[]
    const cells = (conditions: object | undefined) =>
        draw(
            createElement(SolutesTable, {
                items: rows,
                conditions: conditions as never,
                onNotes: () => {},
                save: () => {},
            }),
            80,
        )
    const shown = cells({ pH: 7.5, "sigmaPh": 0.1, temperature: 4 })
    const head = shown.find((l) => l.includes("pH") && l.includes("σ")) ?? ""
    assert.ok(head.includes("T °C"), shown.join("\n"))
    assert.ok(shown.some((l) => /7\.5\s+║\s+0\.1\s+║\s+4\b/.test(l)), shown.join("\n"))
    // an old buffer: the temperature says it is not set
    assert.ok(cells({ pH: 7.5, "sigmaPh": 0.1 }).join("\n").includes("not set"))
    // no conditions at all
    assert.ok(cells(undefined).join("\n").includes("not set"))
})

test("the recipes table shows the recipe's temperature", () => {
    scratchProject() // points the data folder at a scratch one
    saveRecipe(appDir(), "cold", [], { pH: 7.5, "sigmaPh": 0.1, temperature: 4 })
    const text = draw(createElement(RecipesTable), 80)
    assert.ok(text.some((l) => l.includes("°C")), text.join("\n"))
    assert.ok(text.some((l) => /cold.*7\.5.*0\.1.*\b4\b/.test(l)), text.join("\n"))
    for (const line of text) assert.ok(displayWidth(line) <= 80, line)
})

test("the recipes table marks templates and offers new template at 80", () => {
    scratchProject()
    const definition = { kind: "builtin", id: "tris", mM: 10, sigmaMM: 0.2 }
    saveRecipe(appDir(), "T-buffer", [], undefined, undefined, definition as never)
    const broken = { kind: "custom", name: "x" }
    saveRecipe(appDir(), "broken", [], undefined, undefined, broken as never)
    saveRecipe(appDir(), "plain", [])
    const text = draw(createElement(RecipesTable), 80)
    const joined = text.join("\n")
    assert.ok(text.some((l) => /T-buf.*builtin/.test(l)), joined)
    assert.ok(text.some((l) => /broken.*invalid/.test(l)), joined)
    assert.ok(text.some((l) => /plain/.test(l) && !/builtin|invalid/.test(l)), joined)
    assert.ok(joined.includes("new template"), joined)
    for (const line of text) assert.ok(displayWidth(line) <= 80, line)
})

test("the open-runs legend with every file key fits 80 columns, nothing cut", () => {
    const project = scratchProject()
    const lines = draw(createElement(OpenRuns, { project }), 80)
    const text = lines.join("\n")
    for (const label of ["data", "tex", "compile plots"])
        assert.ok(text.includes(label), `${label} is in the legend:\n${text}`)
    assert.ok(lines.length <= 24)
    for (const line of lines) assert.ok(displayWidth(line) <= 80, line)
})

test("the models of a run are counted in the run list, never cut", () => {
    assert.equal(modelsCell([]), "-")
    assert.equal(modelsCell([MODEL]), "1")
    assert.equal(modelsCell([MODEL, "b"]), "2")
})

test("the run screen's long Julia lines wrap, nothing runs off the panel", () => {
    const rows = wrapLine(`model ${MODEL} failed: ${LONG_ERROR}`, 74)
    assert.ok(rows.length > 1)
    for (const row of rows) assert.ok(displayWidth(row) <= 74, row)
    assert.ok(rows.join(" ").replace(/\s+/g, " ").includes("is below 400."))
})

// ========================================================================================
// 2. The messages: none longer than the note row, none cut
// ========================================================================================

/** The cells of the note row of the narrowest footers at 80 columns (the blocky one). */
const NOTE_ROOM = legendRoom("blocky", 78)

/** What a model of the owner's example looks like in a list. */
const failedModel = (error?: string): OpenModel =>
    ({ name: MODEL, state: "failed", error }) as unknown as OpenModel

test("the messages the screens build fit the note row of a blocky footer", () => {
    assert.equal(NOTE_ROOM, 58)
    const messages = [
        destructiveQuestion(`model ${MODEL}`).text,
        destructiveQuestion(`run ${runBrief(RUN)}`).text,
        destructiveQuestion("project SASDCQ2-long-name").text,
        destructiveQuestion("recipe a-recipe-with-a-long-name").text,
        destructiveQuestion("reference crysol-first-model").text,
        noWorkbookNote(failedModel(LONG_ERROR), NOTE_ROOM),
        noWorkbookNote(failedModel(`SomeError: ${"x".repeat(200)}`), NOTE_ROOM),
        noWorkbookNote(failedModel(), NOTE_ROOM),
        failedNote("m".repeat(60), LONG_ERROR, NOTE_ROOM),
        restoreErrorNote(new ChangedOnDiskError("/a/b/buffer.json")),
        "settings.json unreadable: global used, old in .corrupt",
        "reset custom-solutes.json? the old one is kept as .corrupt",
        "custom-solutes.json reset; old one kept as .corrupt",
        "reset the data files? old ones kept as .corrupt",
        `${runBrief(RUN)} has no models`,
        "loaded 391 points, dropped 2 rows (bad q or sigma)",
        "not packed: 7-Zip failed: disk full",
    ]
    for (const text of messages)
        assert.ok(displayWidth(text) <= NOTE_ROOM + 1, `${displayWidth(text)}: ${text}`)
    // a name (user data) may lose its start; a fixed sentence never ends in an ellipsis
    for (const text of messages) assert.ok(!text.endsWith("…"), text)
})

test("a corner that does not fit whole drops to a shorter form, not to a stump", () => {
    const forms = cornerLabels("SASDCQ2", RUN)
    assert.equal(forms[0], "project: SASDCQ2 · run: 14:19:18:912 EST -05:00 · 2026-11-09")
    // beside `results · SASDCQ2_fit3_model2` the long form does not fit; the brief one does
    const shown = fitCorner(forms, 78, "results", "SASDCQ2_fit3_model2")
    assert.equal(shown, "project: SASDCQ2 · run: 14:19:18 2026-11-09")
    assert.ok(!(shown ?? "").includes("…"))
})

// ========================================================================================
// 3. The brief form of an error
// ========================================================================================

test("a failed model's error is told in a few words", () => {
    assert.equal(briefError(LONG_ERROR), "not converged")
    assert.equal(briefError(`model ${MODEL}: ${LONG_ERROR}`), "not converged")
    const wls = "WLSError: need n ≥ 3 points (got 2)"
    assert.equal(briefError(wls), "need n ≥ 3 points (got 2)")
    // the first sentence, the type left off, never cut with an ellipsis
    const two = "ArgumentError: the buffer is empty. Add a solute."
    assert.equal(briefError(two), "the buffer is empty")
    assert.equal(briefError("first line\nsecond line"), "first line")
    const long = briefError(`BoundsError: ${"word ".repeat(40)}`)
    assert.ok(displayWidth(long) <= BRIEF_ERROR_WIDTH && !long.endsWith(" "))
    assert.ok(!long.includes("…"))
    assert.equal(briefError(""), "")
})

test("a failed model's note keeps its sentence and cuts only the name", () => {
    assert.equal(failedNote(MODEL, LONG_ERROR, 58), `${MODEL} failed: not converged`)
    assert.equal(failedNote(MODEL, undefined, 58), `${MODEL} failed`)
    const tight = failedNote("SASDCQ2_with_a_name_much_too_long_for_it", LONG_ERROR, 40)
    assert.ok(tight.endsWith(" failed: not converged") && tight.startsWith("…"))
    assert.ok(displayWidth(tight) <= 40)
})
