// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/column-descriptions.ts: every column the pipeline writes has one
// sentence, each fits the status line of an 80-column terminal.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { test } from "node:test"
import { readAssetJson } from "../src/core/environment.js"
import { displayWidth } from "../src/core/terminal.js"
import {
    type ColumnDescriptions,
    cellDescription,
    DESCRIPTION_CELLS,
    describeColumn,
    descriptionGroup,
    fitDescription,
    WORST_COUNTER,
} from "../src/store/column-descriptions.js"
import { minColumns } from "../src/ui/interaction.js"

/** The sheets and headers `src/pipeline` writes (checked against its `_sheet` calls). */
const WRITTEN: [string, string[]][] = [
    ["run", ["section", "name", "value", "unit"]],
    ["map", ["parameter", "value"]],
    ["quantiles2sigma", ["parameter", "quantileLo", "quantileHi", "boundLo", "boundHi"]],
    ["stdevFromPrior", ["parameter", "zMap", "zQuantileLo", "zQuantileHi"]],
    ["modes", ["mode", "share", "logMass", "logMassErr", "chains", "kept"]],
    ["optima", ["optimum", "share", "chains", "started"]],
    ["formFactorLog", ["line"]],
    ["data", ["q", "I", "sigma"]],
    ["model", ["q", "I_map", "quantileLo", "quantileHi", "boundLo", "boundHi"]],
    ["residuals", ["q", "I", "sigma", "I_map", "residual"]],
    ["hist_rhoE", ["binLo", "binHi", "count"]],
    ["ref_crysol", ["q", "I"]],
    ["draws", [
        "chain",
        "draw",
        "rhoE (e-/A^3)",
        "deltaRho1 (0.03 e-/A^3)",
        "deltaRho2 (0.03 e-/A^3)",
        "deltaRho3 (0.03 e-/A^3)",
        "scale",
        "bkgrndCorr (a.u.)",
        "exclVolCorr (c1)",
        "chi2FitGrid",
        "logDensity",
        "divergent",
        "treeDepth",
        "nSteps",
        "stepSize",
        "acceptanceRate",
    ]],
    ["compare.tsv", [
        "q (A^-1)",
        "q (nm^-1)",
        "I_measured (a.u.)",
        "sigma (a.u.)",
        "fit_model1 (a.u.)",
        "ref_crysol (a.u.)",
    ]],
]
test("every column the pipeline writes has a description", () => {
    for (const [sheet, heads] of WRITTEN) {
        for (const head of heads)
            assert.ok(describeColumn(sheet, head), `${sheet}: ${head}`)
    }
    // the shown (superscripted) header finds the same sentence
    assert.equal(
        describeColumn("draws", "rhoE (e-/A³)"),
        describeColumn("draws", "rhoE (e-/A^3)"),
    )
    assert.ok(describeColumn("data", "qNm"))
    assert.equal(describeColumn("data", "unknownColumn"), undefined)
})

test("every description fits the status line at the smallest layout", () => {
    const all = readAssetJson<ColumnDescriptions>("data", "column_descriptions.json")
    // the panel text at 80 columns: the body is 2 less (useBodyColumns), border + padding 4
    const inner = minColumns - 2 - 4
    const room = inner - displayWidth(`${WORST_COUNTER} · `)
    assert.equal(room, DESCRIPTION_CELLS)
    for (const [group, entries] of Object.entries(all))
        for (const [key, text] of Object.entries(entries)) {
            assert.ok(
                displayWidth(text) <= room,
                `${group}.${key}: ${displayWidth(text)} cells, room ${room}`,
            )
            assert.ok(!text.includes("\n"))
        }
})

test("every row of the run sheet that the pipeline writes has its sentence", () => {
    const all = readAssetJson<ColumnDescriptions>("data", "column_descriptions.json")
    const source = readFileSync(
        new URL("../../src/pipeline/summary.jl", import.meta.url),
        "utf8",
    )
    const names = [...source.matchAll(/^ {4}"(\w+)" => \("/gm)].map((m) => m[1] ?? "")
    assert.ok(names.length > 40)
    for (const name of names) assert.ok(all.runRows?.[name], `runRows.${name}`)
    for (const name of Object.keys(all.runRows ?? {}))
        assert.ok(names.includes(name), `runRows.${name} is not a row`)
})

test("groups, the run sheet's row sentences and cutting", () => {
    assert.equal(descriptionGroup("hist_c1"), "hist")
    assert.equal(descriptionGroup("quantiles2sigma"), "quantiles")
    const cells = [
        ["section", "name", "value", "unit", "meaning"],
        ["model", "nAtoms", "1200", "atoms", "ignored: an older workbook's column"],
        ["model", "noSuchRow", "20", "", ""],
    ]
    const nAtoms = readAssetJson<ColumnDescriptions>("data", "column_descriptions.json")
        .runRows?.nAtoms
    assert.ok(nAtoms)
    assert.equal(cellDescription("run", cells, true, 1, 2), nAtoms)
    // a row without a sentence falls back to the column's
    assert.equal(cellDescription("run", cells, true, 2, 2), describeColumn("run", "value"))
    // a fifth column of an old workbook has no sentence of its own
    assert.equal(cellDescription("run", cells, true, 0, 4), undefined)
    assert.equal(cellDescription("run", cells, false, 0, 0), undefined)
    assert.equal(displayWidth(fitDescription("a".repeat(100), 20)), 20)
    assert.equal(fitDescription("short", 4), "")
})

test("the parameter rows of map, quantiles and stdevFromPrior describe themselves", () => {
    const all = readAssetJson<ColumnDescriptions>("data", "column_descriptions.json")
    const rhoE = all.parameterRows?.rhoE
    assert.ok(rhoE)
    const cells = [
        ["parameter", "value"],
        ["rhoE", "0.336"],
        ["noSuchParameter", "1"],
    ]
    for (const sheet of ["map", "quantiles2sigma", "stdevFromPrior"])
        assert.equal(cellDescription(sheet, cells, true, 1, 0), rhoE)
    // the value cell keeps its column's sentence; an unknown parameter falls back
    assert.equal(cellDescription("map", cells, true, 1, 1), describeColumn("map", "value"))
    assert.equal(
        cellDescription("map", cells, true, 2, 0),
        describeColumn("map", "parameter"),
    )
    // the pipeline's labels all have one
    const source = readFileSync(
        new URL("../../src/pipeline/pipeline.jl", import.meta.url),
        "utf8",
    )
    const pattern = /_REPORT_LABELS = Dict\{String,String\}\(([^)]*)\)/s
    const block = source.match(pattern)?.[1] ?? ""
    const labels = [...block.matchAll(/=>\s*"(\w+)"/g)].map((m) => m[1] ?? "")
    assert.ok(labels.length >= 8)
    for (const label of labels) {
        assert.ok(all.parameterRows?.[label], `parameterRows.${label}`)
    }
})
