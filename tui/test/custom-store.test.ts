// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import {
    existsSync,
    mkdtempSync,
    readFileSync,
    rmSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { ChangedOnDiskError, UnusableFileError, writeJson } from "../src/core/files.js"
import type {
    CustomEntry,
    EntryUnit,
    NonbioEntry,
    PolymerEntry,
} from "../src/store/custom.js"
import {
    customFile,
    customSolutesFileName,
    readCustomSolutes,
    removeCustomSolute,
    writeCustomSolutes,
} from "../src/store/custom-store.js"
import { fixture, fixtureText } from "./support/fixtures.js"

const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

const nonbio = (name = "NACE"): NonbioEntry => ({
    kind: "nonbiological",
    name,
    formula: "C7H13NO3S",
    z: 100,
    pmv: 118.4,
    sigma: 4,
})
const unit: EntryUnit = { label: "A", formula: "C2H4O", z: 1, slope: 1, sigma: null }
const polymer = (units: unknown[] = [unit]): PolymerEntry =>
    ({
        kind: "polymer",
        name: "chain",
        "z-ends": 10,
        "pmv-ends": 19.24,
        "sigma-ends": null,
        units,
    }) as PolymerEntry

const unusable = (f: () => unknown) =>
    assert.throws(f, (e) => e instanceof UnusableFileError && e.kind === "custom-solutes")

test("the fixture round trips", () => {
    const root = tempRoot()
    writeFileSync(customFile(root), fixtureText("buffer/custom-solutes.json"))
    const entries = fixture("buffer/custom-solutes.json").solutes as CustomEntry[]
    const read = readCustomSolutes(root)
    assert.deepEqual(read, entries)
    assert.equal(read.length, 4)
    writeCustomSolutes(root, read)
    assert.deepEqual(readCustomSolutes(root), read)
    assert.match(readFileSync(customFile(root), "utf-8"), /"kind": "nonbiological"/)
    assert.equal(existsSync(`${customFile(root)}.tmp`), false)
})

test("polymers of the wrong shape are unusable", () => {
    const root = tempRoot()
    const old = {
        kind: "polymer",
        name: "o",
        formula: "C2H4O",
        z: 24,
        "pmv-intercept": 1,
        "pmv-slope": 2,
        sigma: null,
    }
    const five = Array.from({ length: 5 }, () => unit)
    for (const bad of [
        old,
        polymer([]),
        polymer(five),
        polymer([1]),
        polymer([unit, "x"]),
    ]) {
        writeFileSync(
            customFile(root),
            writeJson({ solutes: [{ ...bad, kind: "polymer" }] }),
        )
        assert.throws(() => readCustomSolutes(root))
        assert.throws(() => writeCustomSolutes(root, [nonbio()]))
    }
    rmSync(customFile(root))
    unusable(() => writeCustomSolutes(root, [old as unknown as CustomEntry]))
    unusable(() => writeCustomSolutes(root, [polymer([])]))
    assert.equal(existsSync(customFile(root)), false, "nothing was made")
    readCustomSolutes(root, { track: true }) // reopened: the folder has no file now
    writeCustomSolutes(root, [polymer(Array.from({ length: 4 }, () => unit))])
    assert.equal((readCustomSolutes(root)[0] as PolymerEntry).units.length, 4)
})

test("the file is in the data folder and written atomically", () => {
    const root = tempRoot()
    // no file is no entries
    assert.deepEqual(readCustomSolutes(root), [])
    writeFileSync(customFile(root), "")
    assert.deepEqual(readCustomSolutes(root), [])
    // write then read back
    writeCustomSolutes(root, [nonbio(), polymer()])
    assert.deepEqual(readCustomSolutes(root), [nonbio(), polymer()])
    assert.equal(customFile(root), join(root, customSolutesFileName))
    assert.equal(existsSync(join(root, "custom-solutes.json.tmp")), false)
    // other keys are kept
    writeFileSync(customFile(root), '{"solutes": [], "note": "x"}')
    readCustomSolutes(root, { track: true }) // reopened
    writeCustomSolutes(root, [nonbio()])
    assert.equal(
        (JSON.parse(readFileSync(customFile(root), "utf-8")) as { note: string }).note,
        "x",
    )
})

test("unusable files throw and are not written over", () => {
    const root = tempRoot()
    for (const bad of [
        '{"solutes"',
        "[1, 2]",
        '{"solutes": {}}',
        '{"solutes": [1]}',
        ";; a comment",
    ]) {
        writeFileSync(customFile(root), bad)
        unusable(() => readCustomSolutes(root))
        unusable(() => writeCustomSolutes(root, [nonbio()]))
        assert.equal(readFileSync(customFile(root), "utf-8"), bad)
    }
})

test("999 entries are fine, 1000 unusable", () => {
    const root = tempRoot()
    const many = (n: number) => Array.from({ length: n }, (_, i) => nonbio(`s${i}`))
    writeCustomSolutes(root, many(999))
    assert.equal(readCustomSolutes(root).length, 999)
    unusable(() => writeCustomSolutes(root, many(1000)))
    writeFileSync(
        customFile(root),
        `{"solutes": [${many(1000)
            .map(() => "{}")
            .join(",")}]}`,
    )
    unusable(() => readCustomSolutes(root))
})

test("names are unique, case-insensitively, at a write", () => {
    const root = tempRoot()
    unusable(() => writeCustomSolutes(root, [nonbio("A"), nonbio(" a ")]))
    assert.equal(existsSync(customFile(root)), false)
    writeCustomSolutes(root, [nonbio("A"), nonbio("B")])
    assert.equal(readCustomSolutes(root).length, 2)
})

test("removing one entry keeps the others and refuses after another copy saved", () => {
    const root = tempRoot()
    writeCustomSolutes(root, [nonbio("A"), nonbio("B"), nonbio("C")])
    const names = () => readCustomSolutes(root).map((e) => e.name)
    readCustomSolutes(root, { track: true })
    assert.equal(removeCustomSolute(root, "b"), true, "case does not matter")
    assert.deepEqual(names(), ["A", "C"])
    assert.equal(removeCustomSolute(root, "B"), false)
    // another copy saves: this one's view is stale and the removal refuses
    writeFileSync(
        customFile(root),
        writeJson({ solutes: [nonbio("A"), nonbio("C"), nonbio("D")] }),
    )
    assert.throws(() => removeCustomSolute(root, "A"), ChangedOnDiskError)
    assert.deepEqual(names(), ["A", "C", "D"], "nothing was written")
})
