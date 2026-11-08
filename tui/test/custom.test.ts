// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { ChangedOnDiskError, UnusableFileError, writeJson } from "../src/core/file-system.js"
import { formatNumber } from "../src/core/terminal.js"
import {
    addEntry,
    addUnit,
    type CustomEntry,
    customFile,
    customSolutesFileName,
    entryProblem,
    fieldMessage,
    fieldProblem,
    getField,
    type NonbioEntry,
    nonbioPreview,
    parseCell,
    parseField,
    problems,
    readCustomSolutes,
    removeCustomSolute,
    removeUnit,
    setField,
    sigmaShown,
    snapshot,
    writeCustomSolutes,
} from "../src/store/custom.js"
import { takeFormula } from "../src/store/formula.js"
import { Drafts } from "../src/store/lists.js"
import {
    blankUnit,
    type CompletePolymer,
    chainValues,
    compactUnits,
    defaultLabel,
    type EntryUnit,
    formatRounded,
    labelShown,
    POLYMER_UNKNOWN_REL_UNC,
    type PolymerEntry,
    polymerPreview,
    takeEndsFormula,
    unitSigmaShown,
    usedRows,
} from "../src/store/polymers.js"
import { isBuiltinName } from "../src/store/solutes.js"
import { fixture, fixtureText, tempDir as tempRoot } from "./support/fixtures.js"

/** The fixtures the Julia loader is tested against too (`test/fixtures/buffer`). */
const fixtureSolutes = () => fixture("buffer/custom-solutes.json").solutes as CustomEntry[]
const fixtureRows = () => fixture("buffer/buffer.json").solutes as Record<string, unknown>[]

const nonbio = (): NonbioEntry => ({
    kind: "nonbiological",
    name: "NACE",
    formula: "C7H13NO3S",
    z: 100,
    pmv: 118.4,
    sigma: 4.0,
})

const unitA = (): EntryUnit => ({
    label: "A",
    formula: "C2H4O",
    z: 24,
    slope: 36.73,
    sigma: 0.37,
})
const unitB = (): EntryUnit => ({
    label: "B",
    formula: "C3H6O",
    z: 32,
    slope: 53.1,
    sigma: null,
})

const polymer = (): PolymerEntry => ({
    kind: "polymer",
    name: "chain",
    "z-ends": 10,
    "pmv-ends": 19.24,
    "sigma-ends": null,
    units: [unitA()],
})

/** The first problem of an entry alone in a table: `[row, message]`. */
const p = (e: CustomEntry) => problems(Drafts.of([e]))

/** A polymer with a unit cell changed. */
const withUnit = (k: keyof EntryUnit, v: unknown, e = polymer()): PolymerEntry => ({
    ...e,
    units: e.units.map((u, i) => (i === 0 ? { ...u, [k]: v } : u)),
})

test("rows and marks", () => {
    const s = Drafts.of<CustomEntry>([nonbio()])
    assert.equal(s.mark(0), undefined)
    assert.equal(s.dirty, false)
    // a new row is a draft with the blank of its kind
    const t = addEntry(s, "polymer")
    assert.equal(t.value(1)?.kind, "polymer")
    assert.equal(t.mark(1), "*")
    assert.equal(t.dirty, true)
    assert.equal(t.undo(1).length, 1, "undo of a never-saved row drops it")
    assert.equal(t.remove(1).length, 1, "so does remove")
    // an edit is a draft and setting it back removes the draft
    const e = setField(s, 0, "pmv", 120)
    assert.equal(e.mark(0), "*")
    assert.equal((e.value(0) as NonbioEntry).pmv, 120)
    assert.equal(setField(e, 0, "pmv", 118.4).rows[0]?.draft, undefined)
    assert.equal(e.undo(0).rows[0]?.draft, undefined)
    // remove marks a saved row, undo brings it back, commit drops it
    const r = s.remove(0)
    assert.equal(r.mark(0), "-")
    assert.deepEqual(r.toSave(), [])
    assert.equal(r.undo(0).mark(0), undefined)
    assert.equal(r.commit().length, 0)
})

test("problems at save", () => {
    assert.equal(p(nonbio()), undefined)
    assert.equal(p(polymer()), undefined)
    assert.equal(
        p({ ...nonbio(), pmv: -5, sigma: null }),
        undefined,
        "negative PMV, blank ±",
    )
    assert.deepEqual(p({ ...nonbio(), name: " " }), [0, "name needed"])
    assert.deepEqual(p({ ...nonbio(), formula: "Xx", z: null }), [0, "formula unknown"])
    assert.equal(
        p({ ...nonbio(), formula: "Xx" }),
        undefined,
        "a formula not understood is fine with a Z",
    )
    assert.deepEqual(p({ ...nonbio(), z: 0 }), [0, "Z must be > 0"])
    assert.deepEqual(p({ ...nonbio(), formula: "", z: null }), [0, "Z must be > 0"])
    assert.deepEqual(p({ ...nonbio(), pmv: null }), [0, "PMV needed"])
    assert.deepEqual(p({ ...nonbio(), sigma: -1 }), [0, "± not below 0"])
})

test("names are unique, case-insensitively, among the rows that stay", () => {
    const s = Drafts.of<CustomEntry>([nonbio(), { ...polymer(), name: "nace" }])
    assert.deepEqual(problems(s), [1, "name in use"])
    assert.equal(problems(s.remove(1)), undefined)
})

test("a built-in name is refused only when a predicate is given", () => {
    const s = Drafts.of<CustomEntry>([{ ...nonbio(), name: "NaCl" }])
    const builtin = (n: string) => n.toLowerCase() === "nacl"
    assert.equal(problems(s), undefined)
    assert.equal(problems(s, undefined), undefined)
    assert.deepEqual(problems(s, builtin), [0, "name is built-in"])
    assert.ok("name is built-in".length <= 22)
    assert.equal(problems(Drafts.of<CustomEntry>([nonbio()]), builtin), undefined)
    assert.deepEqual(
        problems(Drafts.of<CustomEntry>([{ ...nonbio(), name: "peg" }]), isBuiltinName),
        [0, "name is built-in"],
    )
})

test("polymer units are addressed by unit and key", () => {
    const s = addEntry(Drafts.of<CustomEntry>([]), "polymer")
    const e = (t = s) => t.value(0) as PolymerEntry
    assert.deepEqual(e().units, [blankUnit()], "a blank polymer has one blank unit")
    assert.equal(e()["z-ends"], null)
    assert.equal(e()["pmv-ends"], null)
    const t = setField(s, 0, { unit: 0, key: "formula" }, "C2H4O")
    assert.equal(getField(e(t), { unit: 0, key: "formula" }), "C2H4O")
    assert.equal(e(t).units[0]?.formula, "C2H4O")
    assert.equal(getField(e(setField(t, 0, "z-ends", 5)), "z-ends"), 5)
    // units are added up to 4 and removed down to 1
    const s4 = addUnit(addUnit(addUnit(s, 0), 0), 0)
    assert.equal(e(s4).units.length, 4)
    assert.equal(e(addUnit(s4, 0)).units.length, 4)
    assert.equal(e(removeUnit(s, 0, 0)).units.length, 1)
    const u = setField(s4, 0, { unit: 2, key: "label" }, "C")
    const r = removeUnit(u, 0, 1)
    assert.equal(e(r).units.length, 3)
    assert.equal(e(r).units[1]?.label, "C", "the units after it move up")
    assert.deepEqual([0, 1, 2, 3, 4].map(defaultLabel), ["A", "B", "C", "D", ""])
})

test("polymer problems", () => {
    const two: PolymerEntry = { ...polymer(), units: [unitA(), unitB()] }
    assert.equal(p(polymer()), undefined)
    assert.equal(p(two), undefined)
    assert.deepEqual(p({ ...polymer(), name: "" }), [0, "name needed"])
    assert.deepEqual(p(withUnit("label", " ")), [0, "label needed"])
    assert.deepEqual(
        p({
            ...withUnit("formula", "Xx"),
            units: [{ ...unitA(), formula: "Xx", z: null }],
        }),
        [0, "formula unknown"],
    )
    assert.deepEqual(p(withUnit("z", 0)), [0, "Z must be > 0"])
    assert.deepEqual(p(withUnit("slope", null)), [0, "slope needed"])
    assert.deepEqual(p(withUnit("sigma", -0.1)), [0, "± not below 0"])
    assert.deepEqual(p({ ...two, units: [unitA(), { ...unitB(), slope: null }] }), [
        0,
        "slope needed",
    ])
    assert.deepEqual(p({ ...two, units: [unitA(), { ...unitB(), label: "a" }] }), [
        0,
        "unit label used",
    ])
    assert.deepEqual(p({ ...polymer(), "z-ends": null }), [0, "end groups needed"])
    assert.deepEqual(p({ ...polymer(), "pmv-ends": null }), [0, "end groups needed"])
    assert.equal(p({ ...polymer(), "pmv-ends": -2 }), undefined, "negative is fine")
    assert.deepEqual(p({ ...polymer(), "sigma-ends": -1 }), [0, "ends ± not below 0"])
    assert.deepEqual(p({ ...polymer(), units: [] }), [0, "unit needed"])
    for (const m of [
        "label needed",
        "formula unknown",
        "Z must be > 0",
        "slope needed",
        "± not below 0",
        "unit label used",
        "end groups needed",
        "ends ± not below 0",
        "unit needed",
    ])
        assert.ok(m.length <= 22, m)
    // a blank new polymer is told first by its name, then its unit
    const s = setField(addEntry(Drafts.of<CustomEntry>([]), "polymer"), 0, "name", "x")
    assert.deepEqual(problems(s), [0, "label needed"])
})

test("field problems tell their field", () => {
    const two: PolymerEntry = { ...polymer(), units: [unitA(), unitB()] }
    assert.equal(fieldProblem(nonbio()), undefined)
    assert.deepEqual(fieldProblem({ ...nonbio(), name: "" }), {
        field: "name",
        message: "name needed",
    })
    assert.deepEqual(fieldProblem({ ...nonbio(), formula: "Xx", z: null }), {
        field: "formula",
        message: "formula unknown",
    })
    assert.deepEqual(fieldProblem({ ...nonbio(), z: null }), {
        field: "z",
        message: "Z must be > 0",
    })
    assert.deepEqual(fieldProblem({ ...nonbio(), pmv: null }), {
        field: "pmv",
        message: "PMV needed",
    })
    assert.deepEqual(fieldProblem({ ...nonbio(), sigma: -1 }), {
        field: "sigma",
        message: "± not below 0",
    })
    assert.deepEqual(fieldProblem(withUnit("label", "")), {
        field: { unit: 0, key: "label" },
        message: "label needed",
    })
    assert.deepEqual(
        fieldProblem({ ...two, units: [unitA(), { ...unitB(), slope: null }] }),
        {
            field: { unit: 1, key: "slope" },
            message: "slope needed",
        },
    )
    assert.deepEqual(
        fieldProblem({ ...two, units: [unitA(), { ...unitB(), label: "A" }] }),
        {
            field: { unit: 1, key: "label" },
            message: "unit label used",
        },
    )
    assert.equal(fieldProblem({ ...polymer(), "z-ends": null })?.field, "z-ends")
    assert.equal(fieldProblem({ ...polymer(), "pmv-ends": null })?.field, "pmv-ends")
    assert.equal(fieldProblem({ ...polymer(), "sigma-ends": -1 })?.field, "sigma-ends")
    for (const e of [nonbio(), polymer(), two, { ...nonbio(), pmv: null }])
        assert.equal(fieldMessage(e), fieldProblem(e)?.message)
    // one entry among the others: built-in and used names, case-insensitively
    assert.equal(entryProblem(nonbio(), undefined, ["x", "y"]), undefined)
    assert.deepEqual(entryProblem(nonbio(), undefined, ["x", " nace "]), {
        field: "name",
        message: "name in use",
    })
    assert.deepEqual(entryProblem({ ...nonbio(), name: "peg" }, isBuiltinName, []), {
        field: "name",
        message: "name is built-in",
    })
    assert.equal(
        entryProblem({ ...nonbio(), pmv: null, name: "peg" }, isBuiltinName, [])?.field,
        "pmv",
        "the entry's own fields come first",
    )
})

test("snapshots equal the buffer fixture", () => {
    const entries = fixtureSolutes()
    const byName = (n: string) => entries.find((e) => e.name === n) as CustomEntry
    const cut = (r: Record<string, unknown>) => {
        const { name: _n, mM: _m, "sigma-mM": _s, ...rest } = r
        return rest
    }
    const rows = fixtureRows()
    for (const r of rows.filter((x) => x.kind === "custom-nonbio"))
        assert.deepEqual(cut(r), snapshot(byName(r.custom as string) as NonbioEntry))
    const polymers = rows.filter((x) => x.kind === "custom-polymer")
    assert.equal(polymers.length, 2)
    for (const r of polymers)
        assert.deepEqual(
            cut(r),
            snapshot(byName(r.custom as string) as PolymerEntry, r.counts as number[]),
        )
    assert.deepEqual(snapshot(polymer(), [3]).counts, [3])
    assert.throws(() => snapshot(polymer(), [1, 2]))
    assert.throws(() => snapshot(polymer(), undefined as unknown as number[]))
})

test("typed cells", () => {
    assert.equal(formatNumber(118.4), "118.4")
    assert.equal(formatNumber(200), "200")
    assert.equal(formatNumber(1e-5), "0.00001")
    assert.equal(formatNumber(null), "")
    assert.equal(formatRounded(3.044643), "3.04")
    assert.equal(formatRounded(3.0001), "3")
    assert.equal(formatRounded(null), undefined)
    assert.deepEqual(parseField("z", " 24 "), { value: 24 })
    assert.ok("error" in parseField("z", "0"))
    assert.ok("error" in parseField("z", "2.5"))
    assert.deepEqual(parseField("pmv", "-3.5"), { value: -3.5 })
    assert.deepEqual(parseField("pmv-ends", "19.24"), { value: 19.24 })
    assert.deepEqual(parseField("slope", "-1.5"), { value: -1.5 })
    assert.deepEqual(parseField("slope", "x"), { error: "a number, please" })
    assert.deepEqual(parseField("z-ends", "10"), { value: 10 })
    assert.deepEqual(parseField("z-ends", "0"), { value: 0 })
    assert.ok("error" in parseField("z-ends", "1.5"))
    assert.deepEqual(parseField("label", " A "), { value: "A" })
    assert.ok("error" in parseField("label", ""))
    assert.deepEqual(parseField("label", "a b"), { error: "one word, please" })
    assert.deepEqual(parseField("label", "123456789"), { error: "at most 8 characters" })
    assert.deepEqual(parseField("sigma-ends", ""), { value: null })
    assert.ok("error" in parseField("sigma-ends", "-1"))
    assert.deepEqual(parseField("sigma", "  "), { value: null })
    assert.deepEqual(parseField("sigma", "-1"), { error: "not below 0" })
    assert.deepEqual(parseField("name", ""), { error: "name needed" })
    // a form cell may be blank: it clears the cell
    assert.deepEqual(parseCell("name", ""), { value: "" })
    assert.deepEqual(parseCell("label", " "), { value: "" })
    assert.deepEqual(parseCell("formula", ""), { value: "" })
    assert.deepEqual(parseCell("z", ""), { value: null })
    assert.deepEqual(parseCell("slope", ""), { value: null })
    assert.deepEqual(parseCell("z-ends", ""), { value: null })
    assert.deepEqual(parseCell("z", "5"), { value: 5 })
    assert.ok("error" in parseCell("z", "x"))
})

test("a formula taken into an entry", () => {
    const e = { formula: "NaCl", z: 28 as number | null }
    const u: EntryUnit = blankUnit()
    // a changed formula gets the computed Z
    assert.deepEqual(takeFormula(e, "H2O", false), {
        value: { formula: "H2O", z: 10 },
        note: undefined,
    })
    // an unchanged formula keeps a Z typed by hand
    assert.deepEqual(takeFormula({ ...e, z: 99 }, " NaCl ", false), {
        value: { formula: "NaCl", z: 99 },
        note: undefined,
    })
    // a formula not understood: no Z, the reason as the note
    assert.deepEqual(takeFormula(e, "Xx", false), {
        value: { formula: "Xx", z: null },
        note: "unknown element Xx",
    })
    // a blank formula says nothing
    assert.deepEqual(takeFormula(e, "", false), {
        value: { formula: "", z: null },
        note: undefined,
    })
    // a unit drops ( )n, takes no charge and gets the offered label
    assert.deepEqual(takeFormula(u, "(C2H4O)n", true, "B"), {
        value: { ...u, formula: "C2H4O", z: 24, label: "B" },
        note: undefined,
    })
    assert.equal(takeFormula({ ...u, label: "mine" }, "CH2", true, "B").value.label, "mine")
    assert.equal(takeFormula(u, "NH4+", true, "A").note, "no charge allowed")
})

test("the end groups' formula gives z-ends", () => {
    const r = takeEndsFormula(polymer(), "", "H2O")
    assert.equal(r.entry["z-ends"], 10)
    assert.equal(r.endsFormula, "H2O")
    assert.equal(r.note, undefined)
    // the same formula keeps a Z typed over it
    const same = takeEndsFormula({ ...polymer(), "z-ends": 7 }, "H2O", "H2O")
    assert.equal(same.entry["z-ends"], 7)
    // a formula not understood leaves no Z
    assert.equal(takeEndsFormula(polymer(), "", "Xx").entry["z-ends"], null)
    // a charged formula that sums below 0 is refused
    const neg = takeEndsFormula(polymer(), "", "H2+")
    assert.equal(neg.entry["z-ends"], null)
    assert.equal(neg.note, "Z must be >= 0")
})

test("rows of the unit table", () => {
    const blank = blankUnit()
    const a = { ...blank, label: "A", formula: "C2H4O", z: 24, slope: 36.9 }
    const c = { ...blank, formula: "CH2", z: 8, slope: 5.3 }
    assert.deepEqual(usedRows([blank, blank, blank, blank]), [0], "row 0 is always used")
    assert.deepEqual(usedRows([a, blank, c, blank]), [0, 2], "an all-blank row is ignored")
    assert.deepEqual(
        usedRows([a, { ...blank, slope: 1 }, blank, blank]),
        [0, 1],
        "a half-filled row is used",
    )
    assert.deepEqual(usedRows([blank, blank, blank, c]), [0, 3])
    // compacting keeps the order and offers the label of the row's place
    assert.deepEqual(
        compactUnits([a, blank, c, blank]).map((u) => u.label),
        ["A", "C"],
    )
    assert.deepEqual(
        compactUnits([blank, blank, blank, blank]).map((u) => u.label),
        ["A"],
    )
    assert.deepEqual(
        compactUnits([{ ...a, label: "mine" }, blank, blank, blank]).map((u) => u.label),
        ["mine"],
    )
})

test("what the cells show", () => {
    assert.equal(sigmaShown(null, 3.044643), "(3.04)")
    assert.equal(sigmaShown(4, 3.044643), "4")
    assert.equal(unitSigmaShown(null, true), "(2%)")
    assert.equal(unitSigmaShown(null, false), "")
    assert.equal(unitSigmaShown(0.1, false), "0.1")
    assert.equal(labelShown("", 1, true), "(B)")
    assert.equal(labelShown("", 1, false), "")
    assert.equal(labelShown("PO", 1, true), "PO")
})

test("the preview of a non-biological entry", () => {
    const blank = { ...nonbio(), name: "", formula: "", z: null, pmv: null, sigma: null }
    assert.deepEqual(nonbioPreview(blank, 3.044643), [])
    assert.deepEqual(nonbioPreview(nonbio(), 3.044643, "sum"), [
        "sum",
        "Z = 100   PMV = 118.4 cm³/mol   σ = 4 cm³/mol",
    ])
    assert.deepEqual(
        nonbioPreview({ ...nonbio(), pmv: 118.4, sigma: null, formula: "" }, 3.044643),
        ["Z = 100   PMV = 118.4 cm³/mol   σ = 3.04 cm³/mol (fallback)"],
    )
    assert.deepEqual(nonbioPreview({ ...blank, sigma: 4 }, 3.044643), ["σ = 4 cm³/mol"])
    assert.deepEqual(nonbioPreview({ ...blank, pmv: -5 }, 3.044643), [
        "PMV = -5 cm³/mol   σ = 3.04 cm³/mol (fallback)",
    ])
})

test("the preview of a polymer form", () => {
    const blank = blankUnit()
    const form = (units: EntryUnit[], over: Partial<PolymerEntry> = {}): PolymerEntry => ({
        ...polymer(),
        name: "chain",
        "z-ends": 10,
        "pmv-ends": 9,
        "sigma-ends": null,
        units,
        ...over,
    })
    const ab: EntryUnit[] = [
        { label: "A", formula: "C2H4O", z: 24, slope: 36.92, sigma: null },
        { label: "B", formula: "C3H6O", z: 32, slope: 53.13, sigma: null },
        blank,
        blank,
    ]
    assert.deepEqual(polymerPreview(form(ab)), [
        "PMV = 9 + 36.92·nA + 53.13·nB",
        "Z = 10 + 24·nA + 32·nB",
        "n = 10 of each: Z = 570, PMV = 909.5 cm³/mol, σ = 18.19 cm³/mol",
        "n = 100 of each: Z = 5610, PMV = 9014 cm³/mol, σ = 180.28 cm³/mol",
    ])
    // nothing before anything is given
    assert.deepEqual(
        polymerPreview(form([blank], { "z-ends": null, "pmv-ends": null })),
        [],
    )
    // what is missing is a ?, and no values are shown
    const half: EntryUnit = { ...blank, formula: "C2H4O", z: 24, label: "A" }
    assert.deepEqual(polymerPreview(form([half], { "z-ends": null, "pmv-ends": null })), [
        "PMV = ? + ?·nA",
        "Z = ? + 24·nA",
    ])
    // a negative slope is a minus, a blank label is the one offered
    assert.equal(
        polymerPreview(form([{ ...half, slope: -5.2, label: "" }]))[0],
        "PMV = 9 - 5.2·nA",
    )
})

test("the chain rule of the Julia type", () => {
    const unit = (z: number, slope: number, sigma: number | null) => ({
        label: "",
        formula: "",
        z,
        slope,
        sigma,
    })
    const chain = (
        units: ReturnType<typeof unit>[],
        zEnds: number,
        pmvEnds: number,
        sEnds: number | null,
    ): CompletePolymer => ({
        kind: "polymer",
        name: "",
        units,
        "z-ends": zEnds,
        "pmv-ends": pmvEnds,
        "sigma-ends": sEnds,
    })
    const two = (s1: number | null, s2: number | null, sEnds: number | null) =>
        chain([unit(24, 36.92, s1), unit(32, 53.13, s2)], 10, 9, sEnds)
    const near = (a: number, b: number) => assert.ok(Math.abs(a - b) < 1e-9, `${a} vs ${b}`)
    // the numbers of test_customsolutes.jl: counts 100 and 65, ends Z 10, PMV 9
    const r = chainValues(two(null, null, null), [100, 65])
    assert.equal(r.z, 4490)
    near(r.pmv, 7154.45)
    near(r.sigma, POLYMER_UNKNOWN_REL_UNC * 7154.45)
    // σ of each unit and of the ends add in quadrature
    near(
        chainValues(two(0.3, 0.5, 8), [100, 65]).sigma,
        Math.sqrt((0.3 * 100) ** 2 + (0.5 * 65) ** 2 + 64),
    )
    // a unit that states none contributes 2 % of its own part
    const po = POLYMER_UNKNOWN_REL_UNC * 53.13 * 65
    near(
        chainValues(two(0.3, null, null), [100, 65]).sigma,
        Math.sqrt((0.3 * 100) ** 2 + po * po),
    )
    // only the ends' σ stated: the units get 2 % of their parts
    const a = POLYMER_UNKNOWN_REL_UNC * 36.92 * 100
    const b = POLYMER_UNKNOWN_REL_UNC * 53.13 * 65
    near(chainValues(two(null, null, 5), [100, 65]).sigma, Math.sqrt(a * a + b * b + 25))
    // one unit, the PEG line: Z = 10 + 24 n
    assert.equal(chainValues(chain([unit(24, 36.73, null)], 10, 19.24, null), [22]).z, 538)
    // Z rounds halves to even like Julia's round
    const one = chain([unit(1, 1, null)], 0, 0, null)
    assert.equal(chainValues(one, [2.5]).z, 2)
    assert.equal(chainValues(one, [3.5]).z, 4)
})

// ========================================================================================
// The custom solutes file
// ========================================================================================

const storeNonbio = (name = "NACE"): NonbioEntry => ({
    kind: "nonbiological",
    name,
    formula: "C7H13NO3S",
    z: 100,
    pmv: 118.4,
    sigma: 4,
})
const storeUnit: EntryUnit = { label: "A", formula: "C2H4O", z: 1, slope: 1, sigma: null }
const storePolymer = (units: unknown[] = [storeUnit]): PolymerEntry =>
    ({
        kind: "polymer",
        name: "chain",
        "z-ends": 10,
        "pmv-ends": 19.24,
        "sigma-ends": null,
        units,
    }) as PolymerEntry

const unusable = (f: () => unknown) =>
    assert.throws(f, (e: unknown) => e instanceof UnusableFileError && e.kind === "custom-solutes")

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
    const five = Array.from({ length: 5 }, () => storeUnit)
    for (const bad of [
        old,
        storePolymer([]),
        storePolymer(five),
        storePolymer([1]),
        storePolymer([storeUnit, "x"]),
    ]) {
        writeFileSync(
            customFile(root),
            writeJson({ solutes: [{ ...bad, kind: "polymer" }] }),
        )
        assert.throws(() => readCustomSolutes(root))
        assert.throws(() => writeCustomSolutes(root, [storeNonbio()]))
    }
    rmSync(customFile(root))
    unusable(() => writeCustomSolutes(root, [old as unknown as CustomEntry]))
    unusable(() => writeCustomSolutes(root, [storePolymer([])]))
    assert.equal(existsSync(customFile(root)), false, "nothing was made")
    readCustomSolutes(root, { track: true }) // reopened: the folder has no file now
    writeCustomSolutes(root, [storePolymer(Array.from({ length: 4 }, () => storeUnit))])
    assert.equal((readCustomSolutes(root)[0] as PolymerEntry).units.length, 4)
})

test("the file is in the data folder and written atomically", () => {
    const root = tempRoot()
    // no file is no entries
    assert.deepEqual(readCustomSolutes(root), [])
    writeFileSync(customFile(root), "")
    assert.deepEqual(readCustomSolutes(root), [])
    // write then read back
    writeCustomSolutes(root, [storeNonbio(), storePolymer()])
    assert.deepEqual(readCustomSolutes(root), [storeNonbio(), storePolymer()])
    assert.equal(customFile(root), join(root, customSolutesFileName))
    assert.equal(existsSync(join(root, "custom-solutes.json.tmp")), false)
    // other keys are kept
    writeFileSync(customFile(root), '{"solutes": [], "note": "x"}')
    readCustomSolutes(root, { track: true }) // reopened
    writeCustomSolutes(root, [storeNonbio()])
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
        unusable(() => writeCustomSolutes(root, [storeNonbio()]))
        assert.equal(readFileSync(customFile(root), "utf-8"), bad)
    }
})

test("999 entries are fine, 1000 unusable", () => {
    const root = tempRoot()
    const many = (n: number) => Array.from({ length: n }, (_, i) => storeNonbio(`s${i}`))
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
    unusable(() => writeCustomSolutes(root, [storeNonbio("A"), storeNonbio(" a ")]))
    assert.equal(existsSync(customFile(root)), false)
    writeCustomSolutes(root, [storeNonbio("A"), storeNonbio("B")])
    assert.equal(readCustomSolutes(root).length, 2)
})

test("removing one entry keeps the others and refuses after another copy saved", () => {
    const root = tempRoot()
    writeCustomSolutes(root, [storeNonbio("A"), storeNonbio("B"), storeNonbio("C")])
    const names = () => readCustomSolutes(root).map((e) => e.name)
    readCustomSolutes(root, { track: true })
    assert.equal(removeCustomSolute(root, "b"), true, "case does not matter")
    assert.deepEqual(names(), ["A", "C"])
    assert.equal(removeCustomSolute(root, "B"), false)
    // another copy saves: this one's view is stale and the removal refuses
    writeFileSync(
        customFile(root),
        writeJson({ solutes: [storeNonbio("A"), storeNonbio("C"), storeNonbio("D")] }),
    )
    assert.throws(() => removeCustomSolute(root, "A"), ChangedOnDiskError)
    assert.deepEqual(names(), ["A", "C", "D"], "nothing was written")
})
