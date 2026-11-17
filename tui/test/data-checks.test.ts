// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the warnings of the import (store/data-checks.ts), of the reference mode's
// defaults and preview (screens/data-import.tsx) and of the reference curve of a model
// (store/model-references.ts).
//
// Contents:
//   1. The warnings: sigma that is the model's curve, a reference off the data
//   2. The reference import screen: defaults, title, rounded cells, the warning
//   3. The reference curve of a model: the file and the screen
//   4. The energy units of the data screen (a label, never converted): the `energyUnit`
//      field of data.json and the summary line

import assert from "node:assert/strict"
import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { test } from "node:test"
import { createElement } from "react"
import { DataImportScreen } from "../src/screens/data-import.js"
import { energyText } from "../src/screens/data-screen.js"
import {
    DEFAULT_ENERGY_UNIT,
    dataJsonFile,
    energyUnitLabel,
    energyUnitsList,
    nextEnergyUnit,
    readDataInfo,
    setEnergy,
    setEnergyUnit,
    setUnits,
    writeData,
} from "../src/store/data.js"
import { referenceWarning, sigmaWarning } from "../src/store/data-checks.js"
import { type DataPoints, textSource } from "../src/store/data-table.js"
import {
    EMPTY_MODEL_REFERENCE,
    modelReference,
    modelReferencesFile,
    PROJECT_REFERENCE_KEY,
    projectReference,
    readModelReferences,
    saveModelReference,
    saveProjectReference,
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
            refChi2: "MultiFoXS 0.79",
            fit: "fit3.tsv",
            rescale: true,
        },
        m2: { refChi2: "CRYSOL 1.4" },
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

test("the project's one reference is the `*` entry, apart from the models' entries", () => {
    const dir = tempDir("baysol-projref-")
    assert.deepEqual(projectReference(dir), EMPTY_MODEL_REFERENCE)
    saveModelReference(dir, "m1", { ...EMPTY_MODEL_REFERENCE, fit: "old.tsv" })
    saveProjectReference(dir, { ...EMPTY_MODEL_REFERENCE, fit: "fit3.tsv", rescale: true })
    assert.deepEqual(JSON.parse(readFileSync(modelReferencesFile(dir), "utf-8")), {
        m1: { fit: "old.tsv" },
        [PROJECT_REFERENCE_KEY]: { fit: "fit3.tsv", rescale: true },
    })
    assert.equal(PROJECT_REFERENCE_KEY, "*")
    assert.equal(projectReference(dir).fit, "fit3.tsv")
    // loading another reference replaces it; emptying it leaves the model's entry
    saveProjectReference(dir, { ...EMPTY_MODEL_REFERENCE, fit: "fit4.tsv" })
    assert.equal(projectReference(dir).rescale, false)
    saveProjectReference(dir, EMPTY_MODEL_REFERENCE)
    assert.deepEqual([...readModelReferences(dir).keys()], ["m1"])
})

// ========================================================================================
// 4. The energy units
// ========================================================================================

const curve = {
    q: [0.01, 0.02, 0.03, 0.04],
    i: [4, 3, 2, 1],
    sigma: [0.1, 0.1, 0.1, 0.1],
    dropped: 0,
}
const fileOf = (dir: string) => JSON.parse(readFileSync(dataJsonFile(dir), "utf-8"))
const infoOf = (dir: string) => {
    const status = readDataInfo(dir)
    assert.equal(status?.kind, "ok")
    return status?.kind === "ok" ? status.info : assert.fail("no data")
}

test("energy: the unit cycle and the labels", () => {
    assert.deepEqual(
        energyUnitsList.map((u) => nextEnergyUnit(u)),
        ["A", "eV", "keV", "nm"],
    )
    assert.equal(DEFAULT_ENERGY_UNIT, "nm")
    assert.deepEqual([...energyUnitsList], ["nm", "A", "eV", "keV"])
    assert.equal(energyUnitLabel("A"), "Å")
    assert.equal(energyUnitLabel("A").codePointAt(0), 0xc5)
})

test("energy: the summary is the number as typed and its unit, no conversion", () => {
    assert.equal(energyText(null, "nm"), "not set")
    assert.equal(energyText(12000, "eV"), "12000 eV")
    assert.equal(energyText(12000, "keV"), "12000 keV")
    assert.equal(energyText(1.0332, "A"), "1.0332 Å")
})

test("energy: energyUnit in data.json, always written, invalid or missing refused", () => {
    const dir = tempDir()
    writeData(dir, curve, "c.dat", "A-1", 12000)
    assert.equal(infoOf(dir).energyUnit, "nm", "the default unit is written")
    assert.equal(fileOf(dir).energyUnit, "nm")
    setEnergyUnit(dir, "nm")
    assert.equal(infoOf(dir).energyUnit, "nm")
    assert.equal(fileOf(dir).energyUnit, "nm")
    // a label only: the number is not touched, and the other writers keep the unit
    assert.equal(infoOf(dir).energy, 12000)
    setEnergyUnit(dir, "keV")
    assert.equal(infoOf(dir).energy, 12000)
    setEnergyUnit(dir, "nm")
    setUnits(dir, "nm-1")
    setEnergy(dir, 8048, "nm")
    const kept = infoOf(dir)
    assert.equal(kept.energyUnit, "nm")
    assert.equal(kept.energy, 8048)
    setEnergy(dir, 1.5, "A")
    assert.equal(infoOf(dir).energyUnit, "A")
    setEnergy(dir, 8048, "nm")
    writeData(dir, curve, "d.dat", "A-1", 8048, undefined, kept.energyUnit)
    assert.equal(infoOf(dir).energyUnit, "nm")
    // eV is written like the others
    setEnergyUnit(dir, "eV")
    assert.equal(fileOf(dir).energyUnit, "eV")
    setEnergy(dir, 5, "nm")
    assert.equal(fileOf(dir).energyUnit, "nm")
    // an invalid value makes the file unusable
    for (const bad of ['"mm"', "3", "null", "undefined"]) {
        writeFileSync(
            dataJsonFile(dir),
            `{"units":"A-1","energy":1,"source":"s","points":4,"energyUnit":${bad}}`,
        )
        assert.equal(readDataInfo(dir)?.kind, "unusable", bad)
    }
    // a file without the unit is unusable too
    writeFileSync(
        dataJsonFile(dir),
        '{"units":"A-1","energy":1,"source":"s","points":4}',
    )
    assert.equal(readDataInfo(dir)?.kind, "unusable", "no energyUnit")
})
