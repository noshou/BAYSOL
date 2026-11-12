// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the energy units of the data screen (a label, never converted): the
// `energy_unit` field of data.json and the summary line.

import assert from "node:assert/strict"
import { readFileSync, writeFileSync } from "node:fs"
import { test } from "node:test"
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
import { tempDir } from "./support/fixtures.js"

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

test("energy: energy_unit in data.json, always written, invalid or missing refused", () => {
    const dir = tempDir()
    writeData(dir, curve, "c.dat", "A-1", 12000)
    assert.equal(infoOf(dir).energy_unit, "nm", "the default unit is written")
    assert.equal(fileOf(dir).energy_unit, "nm")
    setEnergyUnit(dir, "nm")
    assert.equal(infoOf(dir).energy_unit, "nm")
    assert.equal(fileOf(dir).energy_unit, "nm")
    // a label only: the number is not touched, and the other writers keep the unit
    assert.equal(infoOf(dir).energy, 12000)
    setEnergyUnit(dir, "keV")
    assert.equal(infoOf(dir).energy, 12000)
    setEnergyUnit(dir, "nm")
    setUnits(dir, "nm-1")
    setEnergy(dir, 8048, "nm")
    const kept = infoOf(dir)
    assert.equal(kept.energy_unit, "nm")
    assert.equal(kept.energy, 8048)
    setEnergy(dir, 1.5, "A")
    assert.equal(infoOf(dir).energy_unit, "A")
    setEnergy(dir, 8048, "nm")
    writeData(dir, curve, "d.dat", "A-1", 8048, undefined, kept.energy_unit)
    assert.equal(infoOf(dir).energy_unit, "nm")
    // eV is written like the others
    setEnergyUnit(dir, "eV")
    assert.equal(fileOf(dir).energy_unit, "eV")
    setEnergy(dir, 5, "nm")
    assert.equal(fileOf(dir).energy_unit, "nm")
    // an invalid value makes the file unusable
    for (const bad of ['"mm"', "3", "null", "undefined"]) {
        writeFileSync(
            dataJsonFile(dir),
            `{"units":"A-1","energy":1,"source":"s","points":4,"energy_unit":${bad}}`,
        )
        assert.equal(readDataInfo(dir)?.kind, "unusable", bad)
    }
    // a file without the unit is unusable too
    writeFileSync(
        dataJsonFile(dir),
        '{"units":"A-1","energy":1,"source":"s","points":4}',
    )
    assert.equal(readDataInfo(dir)?.kind, "unusable", "no energy_unit")
})
