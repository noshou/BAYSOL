// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the warnings of the import (store/data-checks.ts), of the reference mode's
// defaults and preview (screens/data-import.tsx) and of the reference curve of a model
// (store/model-references.ts).
//
// Contents:
//   1. The warnings: sigma that is the model's curve, a reference off the data
//   2. The reference import screen: defaults, title, rounded cells, the warning
//   3. The reference curve of a model: the file and the screen

import assert from "node:assert/strict"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { test } from "node:test"
import { createElement, } from "react"
import { DataImportScreen } from "../src/screens/data-import.js"
import { ModelReferenceScreen } from "../src/screens/model-reference.js"
import { writeData } from "../src/store/data.js"
import { referenceWarning, sigmaWarning } from "../src/store/data-checks.js"
import { type DataPoints, textSource } from "../src/store/data-table.js"
import {
    EMPTY_MODEL_REFERENCE,
    modelReference,
    modelReferencesFile,
    readModelReferences,
    saveModelReference,
} from "../src/store/model-references.js"
import { drawScreen, tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. The warnings
// ========================================================================================

/** A measured curve of `n` points: I falls off, sigma is a few per cent of it. */
function measured(n = 12): DataPoints {
    const q = Array.from({ length: n }, (_, k) => 0.01 + 0.01 * k)
    const i = q.map((x) => 1000 * Math.exp(-x * x * 100))
    return { q, i, sigma: i.map((v) => 0.03 * v + 0.01), dropped: 0 }
}

test("sigma that is about I is a warning, real errors are not", () => {
    const data = measured()
    assert.equal(sigmaWarning(data), undefined)
    // the model column of a fit file read as sigma
    const model = { ...data, sigma: data.i.map((v) => v * 1.02) }
    assert.match(sigmaWarning(model) ?? "", /sigma is about I/)
    // a curve that is too short to tell, or has no sigma, says nothing
    const few = measured(3)
    assert.equal(sigmaWarning({ ...few, sigma: few.i.map((v) => v * 1.02) }), undefined)
    assert.equal(sigmaWarning({ ...data, sigma: [] }), undefined)
})

test("a reference off the data, or the data itself, is a warning", () => {
    const data = measured()
    assert.equal(referenceWarning(data, undefined), undefined)
    // a curve close to the data (a few per cent off) is fine
    const close = { ...data, i: data.i.map((v) => v * 1.05), sigma: [] }
    assert.equal(referenceWarning(close, data), undefined)
    // the data's own column taken as the model
    assert.match(
        referenceWarning({ ...data, i: [...data.i], sigma: [] }, data) ?? "",
        /same numbers as the data/,
    )
    // another column: ten times the data
    const far = { ...data, i: data.i.map((v) => v * 10), sigma: [] }
    assert.match(referenceWarning(far, data) ?? "", /^10x off the data/)
    // a curve that does not reach the data's q (units)
    const apart = { ...data, q: data.q.map((x) => x * 10 + 5), sigma: [] }
    assert.match(referenceWarning(apart, data) ?? "", /q range does not meet/)
    // every warning is brief
    for (const text of [
        sigmaWarning({ ...data, sigma: data.i }),
        referenceWarning(far, data),
        referenceWarning(apart, data),
    ])
        assert.ok((text ?? "").length <= 48, String(text))
})

// ========================================================================================
// 2. The reference import screen
// ========================================================================================

/** A project folder with 12 points of data. */
function projectWithData(): { id: string; dir: string } {
    const dir = tempDir("baysol-checks-")
    writeData(dir, measured(), "data.dat", "A-1", 12400)
    return { id: "P", dir }
}

/** A fit file as SASBDB has it: q, the measured I, the model's I and the error. */
function fitFile(model: (k: number, i: number) => number, header = true): string {
    const data = measured()
    const rows = data.q.map(
        (q, k) =>
            `${q}\t${data.i[k]}\t${model(k, data.i[k] as number)}\t${data.sigma[k]}`,
    )
    return `${header ? "q\tI_exp\tI_fit\terr\n" : ""}${rows.join("\n")}\n`
}

test("the reference import starts at q col:1, I col:3 (the model) and no sigma", () => {
    const project = projectWithData()
    const text = fitFile((_, i) => i * 1.01234567)
    const out = drawScreen(
        createElement(DataImportScreen, {
            project,
            path: "/x/fit.dat",
            source: textSource(text),
            reference: true,
            onDone: () => {},
        }),
    )
    assert.match(out, /reference fit/)
    assert.match(out, /q\s+q col:1/)
    assert.match(out, /I\(q\)\s+I_fit col:3/)
    assert.match(out, /sigma\s+none/)
    // the preview cells are rounded to five digits: 0.01 stays, 1.234567... does not
    assert.ok(!/\d\.\d{6,}/.test(out.split("line")[1] ?? ""), out)
    // the model close to the data: no warning
    assert.ok(!out.includes("wrong column"), out)
})

test("the data import warns when sigma is the model's curve", () => {
    const project = projectWithData()
    const source = textSource(fitFile((_, i) => i * 1.01, false))
    const out = drawScreen(
        createElement(DataImportScreen, {
            project,
            path: "/x/fit.dat",
            source,
            onDone: () => {},
        }),
    )
    // the columns are guessed by position: q, I_exp, I_fit (as sigma)
    assert.match(out, /sigma is about I/)
})

test("the reference import warns about the data's own column", () => {
    const project = projectWithData()
    // the model column holds the measured intensity: same numbers
    const out = drawScreen(
        createElement(DataImportScreen, {
            project,
            path: "/x/fit.dat",
            source: textSource(fitFile((_, i) => i)),
            reference: true,
            onDone: () => {},
        }),
    )
    assert.match(out, /same numbers as the data/)
})

// ========================================================================================
// 3. The reference curve of a model
// ========================================================================================

test("a model's reference is kept sparse, in the JSON keys, beside the others", () => {
    const dir = tempDir("baysol-modref-")
    assert.deepEqual(modelReference(dir, "m1"), EMPTY_MODEL_REFERENCE)
    assert.equal(readModelReferences(dir).size, 0)
    // nothing to save and no file: no file is made
    saveModelReference(dir, "m1", EMPTY_MODEL_REFERENCE)
    assert.ok(!existsSync(modelReferencesFile(dir)))
    const ref = {
        tag: "fit3_model1",
        software: "MultiFoXS",
        refChi2: "MultiFoXS 0.79",
        fit: "fit3.tsv",
        rescale: true,
    }
    saveModelReference(dir, "m1", ref)
    saveModelReference(dir, "m2", { ...EMPTY_MODEL_REFERENCE, refChi2: "CRYSOL 1.4" })
    assert.deepEqual(JSON.parse(readFileSync(modelReferencesFile(dir), "utf-8")), {
        m1: {
            tag: "fit3_model1",
            software: "MultiFoXS",
            ref_chi2: "MultiFoXS 0.79",
            fit: "fit3.tsv",
            rescale: true,
        },
        m2: { ref_chi2: "CRYSOL 1.4" },
    })
    assert.deepEqual(modelReference(dir, "m1"), ref)
    // a model that is emptied loses its key, the other keeps its entry
    saveModelReference(dir, "m1", EMPTY_MODEL_REFERENCE)
    assert.deepEqual([...readModelReferences(dir).keys()], ["m2"])
    // a file that is no object is kept aside and replaced
    writeFileSync(modelReferencesFile(dir), "[1]")
    saveModelReference(dir, "m3", { ...EMPTY_MODEL_REFERENCE, tag: "x" })
    assert.ok(existsSync(`${modelReferencesFile(dir)}.corrupt`))
    assert.deepEqual([...readModelReferences(dir).keys()], ["m3"])
})

test("the reference screen of a model shows its rows at 80 columns", () => {
    const project = projectWithData()
    saveModelReference(project.dir, "m1", {
        ...EMPTY_MODEL_REFERENCE,
        software: "FoXS",
        fit: "gone.tsv",
    })
    const out = drawScreen(
        createElement(ModelReferenceScreen, { project, file: "m1.pdb", stem: "m1" }),
    )
    for (const row of ["model", "curve", "software", "tag", "chi2", "rescale"])
        assert.match(out, new RegExp(row))
    assert.match(out, /m1\.pdb/)
    assert.match(out, /gone\.tsv \(missing\)/)
    for (const line of out.split("\n")) assert.ok(line.length <= 80, line)
})
