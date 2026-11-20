// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/template-defs.ts: the custom and table definitions of a template, their
// validators and the dispatcher `rowsFor`. The key check: a custom definition holding the
// numbers of a shipped buffer gives the shipped buffer's rows. Also
// store/buffer-templates.ts: the engine that turns a standard buffer, its concentration
// and the pH into rows. Its
// expected numbers are the hand calculations of the fitting scripts
// (`test/fitting_tests/<ID>/<ID>.jl`) and the validation table of
// `notes/buffer-templates.md` (section 4), which the engine reproduces.

import assert from "node:assert/strict"
import { test } from "node:test"
import { rowProblem } from "../src/store/buffer.js"
import {
    computeTemplate,
    ionicPerMM,
    type Outcome,
    offered,
    type RowSpec,
    restIonicStrength,
    SET_TEMPERATURE_C,
    templateById,
    templateLine,
    titrantChoices,
} from "../src/store/buffer-templates.js"
import { bufferRow, type Solute } from "../src/store/solutes.js"
import {
    type CustomDefinition,
    checkCustomDefinition,
    checkDefinition,
    checkTableDefinition,
    customToTemplate,
    normalizeDefinition,
    type RowsResult,
    rowsFor,
    type TableDefinition,
    tableRowsAt,
} from "../src/store/template-defs.js"
import { soluteFromSpec } from "../src/store/template-rows.js"

/** `actual` is within `rel` (a fraction) of `expected`. */
function close(actual: number, expected: number, rel: number, what: string): void {
    const gap = Math.abs(actual - expected) / Math.abs(expected)
    assert.ok(gap <= rel, `${what}: ${actual} vs ${expected} (${(gap * 100).toFixed(4)} %)`)
}

/** The rows of a result, which must not be an error. */
function rowsOf(r: RowsResult): Extract<RowsResult, { rows: unknown }> {
    assert.ok(!("error" in r), "error" in r ? r.error : "")
    return r
}

/** The snapshot of a custom solute. */
const DYE = { z: 40, pmv: 300, "sigmaPmv": null }

/** A Tris-like custom buffer at the shipped constants (dH is not part of a definition). */
const tris = (extra: Partial<CustomDefinition> = {}): CustomDefinition => ({
    kind: "custom",
    name: "My Tris",
    solute: "tris",
    steps: [{ pKa25: 8.072, dpKaDT: -0.0279, zAcid: 1 }],
    titrant: { kind: "acid", ion: "chloride" },
    mM: 10,
    sigmaMM: 0.2,
    pHSetAt: 25,
    restMM: 100,
    ...extra,
})

/** A phosphate-like custom buffer at the shipped numbers, titrated with sodium. */
const phosphate = (): CustomDefinition => ({
    kind: "custom",
    name: "My phosphate",
    solute: "phosphoric acid",
    steps: [
        { pKa25: 2.148, dpKaDT: 0.0047, zAcid: 0 },
        { pKa25: 7.198, dpKaDT: -0.0021, zAcid: -1 },
        { pKa25: 12.35, dpKaDT: -0.0094, zAcid: -2 },
    ],
    titrant: { kind: "base", ion: "sodium(1+)" },
    mM: 50,
    sigmaMM: 1,
    pHSetAt: 25,
})

const table = (): TableDefinition => ({
    kind: "table",
    points: [
        { pH: 6, rows: [row("sodium chloride", 100, 2), row("tris", 10, 0.5)] },
        { pH: 8, rows: [row("tris", 30, 1.5), row("sodium chloride", 120, 4)] },
        { pH: 9, rows: [row("sodium chloride", 120, 4), row("tris", 40, 2)] },
    ],
})

function row(arg: string, mM: number, sigmaMM: number) {
    return { name: arg, arg, mM, sigmaMM }
}

const has = (problems: string[], part: string): boolean =>
    problems.some((p) => p.includes(part))

// ========================================================================================
// 1. Validators
// ========================================================================================

test("a good custom definition has no problems", () => {
    assert.deepEqual(checkCustomDefinition(tris()), [])
    assert.deepEqual(checkCustomDefinition(phosphate()), [])
    assert.deepEqual(checkDefinition(tris()), [])
})

test("custom: every rule has its message", () => {
    const bad = (patch: Partial<CustomDefinition>) => checkCustomDefinition(tris(patch))
    assert.ok(has(bad({ name: "" }), "name must be 1 to 40"))
    assert.ok(has(bad({ name: " ".repeat(5) }), "name must be 1 to 40"))
    assert.ok(has(bad({ name: "x".repeat(41) }), "name must be 1 to 40"))
    assert.ok(has(bad({ solute: "no such solute at all" }), "not in the solute tables"))
    // a custom solute needs its snapshot; with it the definition is good
    assert.ok(has(bad({ solute: "my dye" }), "my dye is not in the solute tables"))
    assert.deepEqual(
        checkCustomDefinition(tris({ solute: "my dye", soluteData: DYE })),
        [],
    )
    assert.ok(has(bad({ solute: "my dye", soluteData: { ...DYE, z: 0 } }), "whole number"))
    // an ion's volume may be negative
    assert.deepEqual(
        checkCustomDefinition(tris({ solute: "my dye", soluteData: { ...DYE, pmv: -5 } })),
        [],
    )
    assert.ok(
        has(
            bad({ solute: "my dye", soluteData: { ...DYE, "sigmaPmv": -1 } }),
            "uncertainty",
        ),
    )
    assert.ok(has(bad({ mM: 0 }), "concentration must be above 0"))
    assert.ok(has(bad({ mM: -3 }), "concentration must be above 0"))
    assert.ok(has(bad({ sigmaMM: -1 }), "sigma must not be negative"))
    assert.ok(has(bad({ steps: [] }), "at least one step"))
    const step = (pKa25: number, zAcid: number) => ({ pKa25, zAcid })
    assert.ok(has(bad({ steps: [step(17, 1)] }), "outside -2 to 16"))
    assert.ok(has(bad({ steps: [step(-2.5, 1)] }), "outside -2 to 16"))
    assert.ok(has(bad({ steps: [step(7, 1.5)] }), "not an integer"))
    assert.ok(has(bad({ steps: [step(7, 5)] }), "charge 5 is outside -4 to 4"))
    assert.ok(has(bad({ steps: [step(7, -4)] }), "base form would have charge -5"))
    assert.ok(
        has(bad({ steps: [step(3, 1), step(7, 1)] }), "step 2: charge 1 must be 0"),
    )
    const four = [step(2, 2), step(4, 1), step(6, 0), step(8, -1)]
    assert.ok(has(bad({ steps: four }), "at most 3 steps"))
    assert.ok(has(bad({ titrant: { kind: "acid", ion: "unobtainium" } }), "must be one of"))
    assert.ok(has(bad({ titrant: { kind: "base", ion: "chloride" } }), "must be one of"))
    assert.ok(has(bad({ pHSetAt: 150 }), "pH set at"))
    assert.ok(has(bad({ restMM: -1 }), "rest of the recipe"))
})

test("custom: electroneutrality of the extremes picks the titrant", () => {
    const acidic = tris({ steps: [{ pKa25: 4.8, zAcid: 0 }] })
    assert.ok(has(checkCustomDefinition(acidic), "an acid titrant needs a positive"))
    const baseTitrated = tris({ titrant: { kind: "base", ion: "sodium(1+)" } })
    assert.ok(has(checkCustomDefinition(baseTitrated), "a base titrant needs a negative"))
    // acetate: neutral acid form, base titrant: fine
    const acetate = tris({
        solute: "acetic acid",
        steps: [{ pKa25: 4.76, zAcid: 0 }],
        titrant: { kind: "base", ion: "potassium(1+)" },
    })
    assert.deepEqual(checkCustomDefinition(acetate), [])
})

test("custom: malformed input never throws", () => {
    const junk: unknown[] = [
        undefined, null, 0, "x", [], {}, { kind: "custom" },
        { kind: "custom", name: 3, steps: "a", titrant: null, mM: "10" },
        { kind: "custom", name: "a", solute: "tris", steps: [null], titrant: {} },
        { kind: "custom", steps: [{ pKa25: "8", zAcid: "1" }], mM: Number.NaN },
        { kind: "table" }, { kind: "table", points: [null, 3] },
        { kind: "table", points: [{ pH: "1", rows: null }, { pH: 2 }] },
        { kind: "builtin" }, { kind: "builtin", id: 5 }, { kind: "zzz" },
    ]
    const cond = { pH: 7, sigmaPH: 0.1, temperatureC: 25 }
    for (const j of junk) {
        assert.doesNotThrow(() => checkDefinition(j))
        assert.doesNotThrow(() => checkCustomDefinition(j))
        assert.doesNotThrow(() => checkTableDefinition(j))
        assert.doesNotThrow(() => normalizeDefinition(j))
        assert.ok(checkDefinition(j).length > 0, JSON.stringify(j))
        const r = rowsFor(j, cond)
        assert.ok("error" in r, JSON.stringify(j))
    }
    assert.ok("error" in rowsFor(tris(), null as never))
    const strPH = { pH: "7", sigmaPH: 0.1, temperatureC: 25 } as never
    assert.ok("error" in rowsFor(tris(), strPH))
    assert.ok("error" in tableRowsAt(null, 7))
    assert.ok("error" in tableRowsAt(table(), Number.NaN))
})

test("table: every rule has its message", () => {
    assert.deepEqual(checkTableDefinition(table()), [])
    const t = (f: (d: TableDefinition) => void) => {
        const d = structuredClone(table())
        f(d)
        return checkTableDefinition(d)
    }
    assert.ok(has(t((d) => d.points.splice(1)), "at least 2 points"))
    assert.ok(has(t((d) => (d.points[1].pH = 6)), "must be above 6"))
    assert.ok(has(t((d) => (d.points[2].pH = 7)), "must be above 8"))
    assert.ok(has(t((d) => (d.points[0].pH = -1)), "outside 0 to 14"))
    assert.ok(has(t((d) => (d.points[2].pH = 15)), "outside 0 to 14"))
    assert.ok(has(t((d) => d.points[1].rows.pop()), "lists other rows than point 1"))
    assert.ok(has(t((d) => (d.points[1].rows[0].arg = "urea")), "other rows"))
    assert.ok(has(t((d) => (d.points[0].rows[0].mM = -1)), "mM must not be negative"))
    assert.ok(has(t((d) => (d.points[0].rows[0].sigmaMM = -1)), "sigma must not be"))
    assert.ok(has(t((d) => (d.points[0].rows[0].mM = "5" as never)), "mM is not a number"))
    assert.ok(has(t((d) => d.points[0].rows.push(row("TRIS", 1, 1))), "listed twice"))
    const many = Array.from({ length: 13 }, (_, i) => ({
        pH: i,
        rows: [row("tris", 1, 1)],
    }))
    assert.ok(has(checkTableDefinition({ kind: "table", points: many }), "at most 12"))
    const rows61 = Array.from({ length: 61 }, (_, i) => row(`s${i}`, 1, 1))
    const big = {
        kind: "table",
        points: [{ pH: 1, rows: rows61 }, { pH: 2, rows: rows61 }],
    }
    assert.ok(has(checkTableDefinition(big), "at most 60 rows"))
})

test("table: a duplicate is found through the resolved name", () => {
    const d = structuredClone(table())
    // the bundled table resolves "chloride" and "Cl-" to one solute
    d.points[0].rows = [row("chloride", 1, 1), row("Cl-", 1, 1)]
    assert.ok(has(checkTableDefinition(d), "listed twice"))
})

test("builtin: known id, positive numbers", () => {
    const ok = { kind: "builtin", id: "tris", mM: 20, sigmaMM: 1 }
    assert.deepEqual(checkDefinition(ok), [])
    assert.ok(has(checkDefinition({ ...ok, id: "nope" }), "no buffer template"))
    assert.ok(has(checkDefinition({ ...ok, mM: 0 }), "above 0"))
    assert.ok(has(checkDefinition({ ...ok, sigmaMM: -1 }), "not be negative"))
    assert.ok(has(checkDefinition({ ...ok, ion: "chloride" }), "ion must be one of"))
    assert.deepEqual(checkDefinition({ kind: "builtin", id: "pbs" }), [])
})

// ========================================================================================
// 2. The key validation: a custom definition equals the shipped template
// ========================================================================================

test("custom Tris at the shipped constants equals the shipped Tris (25 C)", () => {
    const shipped = computeTemplate({
        id: "tris", mM: 10, sigmaMM: 0.2, pH: 7.5, sigmaPH: 0.1,
        restIonicMM: 100, tempC: 25,
    })
    const mine = rowsOf(
        rowsFor(tris(), { pH: 7.5, sigmaPH: 0.1, temperatureC: 4 }),
    )
    assert.equal(mine.rows.length, shipped.rows.length)
    for (const s of shipped.rows) {
        const m = mine.rows.find((r) => r.arg === s.arg)
        assert.ok(m, s.name)
        close(m.mM, s.mM, 0.001, `${s.name} mM`)
        close(m.sigmaMM, s.sigmaMM, 0.05, `${s.name} sigma`)
    }
    close(mine.I as number, shipped.I, 0.001, "I")
    assert.ok(mine.warnings.includes("constants not sourced"))
    console.log(
        "Tris 25 C chloride:",
        mine.rows.find((r) => r.name === "chloride")?.mM,
        "vs",
        shipped.rows.find((r) => r.name === "chloride")?.mM,
    )
})

test("custom Tris at 22 C: linear dpKa/dT against Clarke-Glew, reported", () => {
    const shipped = computeTemplate({
        id: "tris", mM: 10, sigmaMM: 0.2, pH: 7.5, sigmaPH: 0.1,
        restIonicMM: 100, tempC: 22,
    })
    const mine = rowsOf(
        rowsFor(tris({ pHSetAt: 22 }), { pH: 7.5, sigmaPH: 0.1, temperatureC: 4 }),
    )
    const a = mine.rows.find((r) => r.name === "chloride")?.mM as number
    const b = shipped.rows.find((r) => r.name === "chloride")?.mM as number
    const pct = (((a - b) / b) * 100).toFixed(4)
    console.log("Tris 22 C chloride:", a, "vs", b, `(${pct} %)`)
    close(a, b, 0.005, "chloride at 22 C")
})

test("pH set at defaults to the buffer's temperature", () => {
    const d = tris()
    delete d.pHSetAt
    const a = rowsOf(rowsFor(d, { pH: 7.5, sigmaPH: 0.1, temperatureC: 4 }))
    const warm = { pH: 7.5, sigmaPH: 0.1, temperatureC: 30 }
    const b = rowsOf(rowsFor({ ...d, pHSetAt: 4 }, warm))
    assert.deepEqual(a.rows, b.rows)
})

test("custom phosphate-like (3 steps) equals the shipped fractions and sodium", () => {
    const pH = 7.0
    const shipped = computeTemplate({
        id: "phosphate",
        mM: 50,
        sigmaMM: 1,
        pH,
        sigmaPH: 0.1,
        tempC: 25,
        cation: "sodium(1+)",
    })
    const mine = rowsOf(rowsFor(phosphate(), { pH, sigmaPH: 0.1, temperatureC: 25 }))
    // the shipped fractions use Clarke-Glew with dH and dCp; the custom one is linear,
    // which at 25 C (the reference) is the same pK
    const f = shipped.fractions as number[]
    mine.fractions?.forEach((x, i) => {
        assert.ok(Math.abs(x - f[i]) < 0.001, `fraction ${i}: ${x} vs ${f[i]}`)
    })
    const na = (rows: { name: string; mM: number }[]) =>
        rows.reduce((s, r) => {
            const n = r.name.startsWith("trisodium") ? 3 : r.name.startsWith("disodium")
                ? 2 : r.name.startsWith("sodium") ? 1 : 0
            return s + n * r.mM
        }, 0)
    const customNa = mine.rows
        .filter((r) => r.name.startsWith("sodium"))
        .reduce((s, r) => s + r.mM, 0)
    close(customNa, na(shipped.rows), 0.002, "sodium")
    console.log("phosphate sodium custom vs shipped:", customNa, na(shipped.rows))
})

test("custom: a pH sweep 0..14 is finite and not negative", () => {
    for (const def of [tris(), phosphate()]) {
        for (let pH = 0; pH <= 14.0001; pH += 0.25) {
            const r = rowsOf(rowsFor(def, { pH, sigmaPH: 0.1, temperatureC: 10 }))
            for (const x of r.rows) {
                assert.ok(Number.isFinite(x.mM) && x.mM >= 0, `${x.name} mM at ${pH}`)
                assert.ok(Number.isFinite(x.sigmaMM) && x.sigmaMM >= 0, `${x.name} sigma`)
            }
            assert.ok(Number.isFinite(r.I))
        }
    }
})

test("customToTemplate: the engine's shape, unverified", () => {
    const t = customToTemplate(phosphate())
    assert.equal(t.verified, false)
    assert.equal(t.kind, "buffer")
    assert.equal(t.groups?.length, 3)
    assert.deepEqual(
        t.groups?.map((g) => [g.zAcid, g.zBase]),
        [[0, -1], [-1, -2], [-2, -3]],
    )
    assert.equal(t.notes, "constants not sourced")
    assert.ok(templateById("tris"), "the shipped list is untouched")
})

// ========================================================================================
// 3. Table interpolation
// ========================================================================================

test("table: exact at the points, in the order of the first point", () => {
    const d = table()
    for (const p of d.points) {
        const r = tableRowsAt(d, p.pH)
        if ("error" in r) throw new Error(r.error)
        for (const want of p.rows) {
            const got: { mM: number; sigmaMM: number } | undefined = r.rows.find(
                (x) => x.arg === want.arg,
            )
            assert.deepEqual(
                [got?.mM, got?.sigmaMM],
                [want.mM, want.sigmaMM],
                `${want.arg} at ${p.pH}`,
            )
        }
    }
    const r = tableRowsAt(d, 8)
    assert.ok(!("error" in r))
    assert.deepEqual(r.rows.map((x) => x.arg), ["sodium chloride", "tris"])
})

test("table: linear between the points", () => {
    const d = table()
    const at = (pH: number) => {
        const r = tableRowsAt(d, pH)
        assert.ok(!("error" in r))
        return r.rows.find((x) => x.arg === "tris") as { mM: number; sigmaMM: number }
    }
    close(at(7).mM, 20, 1e-9, "midpoint mM")
    close(at(7).sigmaMM, 1, 1e-9, "midpoint sigma")
    close(at(6.5).mM, 15, 1e-9, "quarter")
    close(at(8.5).mM, 35, 1e-9, "second segment")
    // linearity: equal steps, equal increments
    const a = at(6.2).mM
    const b = at(6.4).mM
    const c = at(6.6).mM
    close(b - a, c - b, 1e-6, "increments")
    const out = rowsFor(d, { pH: 7, sigmaPH: 0.1, temperatureC: 25 })
    assert.equal(rowsOf(out).rows.length, 2)
})

test("table: outside the points is refused, never NaN", () => {
    const d = table()
    for (const pH of [5.999, 9.001, -1, 14, Number.NaN, Number.POSITIVE_INFINITY]) {
        const r = tableRowsAt(d, pH)
        assert.ok("error" in r, `pH ${pH}`)
    }
    const r = rowsFor(d, { pH: 10, sigmaPH: 0.1, temperatureC: 25 })
    assert.ok("error" in r && r.error.includes("outside"))
})

// ========================================================================================
// 4. normalizeDefinition and JSON
// ========================================================================================

test("normalizeDefinition: trims, drops unknown keys and bad optionals", () => {
    const n = normalizeDefinition({
        kind: "custom", name: "  My  ", solute: " tris ", junk: 1,
        steps: [{ pKa25: 8, zAcid: 1, dpKaDT: "x", extra: true }],
        titrant: { kind: "acid", ion: " chloride ", more: 2 },
        mM: 10, sigmaMM: 0.2, pHSetAt: "4", restMM: 5,
    }) as CustomDefinition
    assert.deepEqual(n, {
        kind: "custom", name: "My", solute: "tris",
        steps: [{ pKa25: 8, zAcid: 1 }],
        titrant: { kind: "acid", ion: "chloride" },
        mM: 10, sigmaMM: 0.2, restMM: 5,
    })
    assert.equal(normalizeDefinition({ kind: "custom", name: "a" }), undefined)
    assert.equal(normalizeDefinition({ ...tris(), mM: "10" }), undefined)
    const t = normalizeDefinition({
        kind: "table", x: 1,
        points: [{ pH: 1, extra: 1, rows: [{ arg: " tris ", mM: 1, sigmaMM: 0 }] }],
    })
    assert.deepEqual(t, {
        kind: "table",
        points: [{ pH: 1, rows: [{ name: "tris", arg: "tris", mM: 1, sigmaMM: 0 }] }],
    })
})

test("definitions survive a JSON round trip and hold no undefined", () => {
    const builtin = { kind: "builtin", id: "tris", mM: 5 }
    for (const d of [tris(), phosphate(), table(), builtin]) {
        const back = JSON.parse(JSON.stringify(d))
        assert.deepEqual(back, d)
        assert.deepEqual(normalizeDefinition(back), d)
        assert.equal(JSON.stringify(d).includes("null"), false)
    }
})

test("builtin through the dispatcher equals computeTemplate", () => {
    const def = {
        kind: "builtin",
        id: "tris",
        mM: 10,
        sigmaMM: 0.2,
        restMM: 100,
        pHSetAt: 22,
    }
    const r = rowsOf(rowsFor(def, { pH: 7.5, sigmaPH: 0.1, temperatureC: 4 }))
    const e = computeTemplate({
        id: "tris", mM: 10, sigmaMM: 0.2, pH: 7.5, sigmaPH: 0.1,
        restIonicMM: 100, tempC: 22,
    })
    assert.deepEqual(r.rows, e.rows)
    const flat = { pH: 5, sigmaPH: 0.1, temperatureC: 25 }
    const pbs = rowsOf(rowsFor({ kind: "builtin", id: "pbs" }, flat))
    assert.equal(pbs.pH, 7.4)
})

/** The row of a name, which must be there. */
function rowNamed(out: Outcome, name: string): RowSpec {
    const found = out.rows.find((r) => r.name === name)
    assert.ok(found, `${name} in ${out.rows.map((r) => r.name).join(", ")}`)
    return found
}

// ========================================================================================
// 5. Engine: the hand calculations of the repo, reproduced
// ========================================================================================

test("Tris 10 mM, pH 7.5, 0.1 M NaCl: the chloride of the removed SASDEM7", () => {
    // the SASDEM7 script (removed): Cl- 0.008536 +- 0.000431 M, I = 0.1085 M; the notes
    // table: 0.008537
    const out = computeTemplate({ id: "tris", mM: 10, pH: 7.5, restIonicMM: 100 })
    close(rowNamed(out, "chloride").mM, 8.537, 0.001, "chloride")
    close(rowNamed(out, "chloride").sigmaMM, 0.431, 0.01, "sigma of chloride")
    close(out.I, 0.1085, 0.001, "I")
    assert.deepEqual(rowNamed(out, "tris"), {
        name: "tris",
        arg: "2-amino-2-(hydroxymethyl)propane-1,3-diol",
        mM: 10,
        sigmaMM: 0.2,
    })
    assert.equal(out.rows.length, 2)
})

test("Tris 10 mM with 0.2 M NaCl, 20 mM with 0.5 M: SASDMJ9, removed SASDMM3", () => {
    // notes table: 0.008588 +- 0.000422 (SASDMJ9 header), here 0.008589 +- 0.000424
    const mj = computeTemplate({ id: "tris", mM: 10, pH: 7.5, restIonicMM: 200 })
    close(rowNamed(mj, "chloride").mM, 8.589, 0.002, "SASDMJ9 chloride")
    close(rowNamed(mj, "chloride").sigmaMM, 0.424, 0.01, "SASDMJ9 sigma")
    // SASDMM3 (removed) header: 0.017209 +- 0.000838, here 0.017212 +- 0.000843 (I 0.5172)
    const mm = computeTemplate({ id: "tris", mM: 20, pH: 7.5, restIonicMM: 500 })
    close(rowNamed(mm, "chloride").mM, 17.212, 0.002, "SASDMM3 chloride")
    close(rowNamed(mm, "chloride").sigmaMM, 0.843, 0.01, "SASDMM3 sigma")
})

test("HEPES 25 mM, pH 7.4 with NaOH: the sodium of a removed fixture (SASDBA8)", () => {
    // the SASDBA8 script (removed): 0.456 x 25 mM = 11.40 mM (file 0.011402),
    // sigma 0.001681 (vendor dT);
    // notes table: 0.011395 M, sigma 0.001648, I 0.1739. The rest: 0.15 M NaCl + 2.5 mM
    // MgCl2 (7.5 mM) + 0.5 mM AMP-PNP(4-) with its 2 mM Na+ (5 mM) = 162.5 mM
    const out = computeTemplate({ id: "hepes", mM: 25, pH: 7.4, restIonicMM: 162.5 })
    close(rowNamed(out, "sodium(1+)").mM, 11.395, 0.002, "sodium")
    close(rowNamed(out, "sodium(1+)").sigmaMM, 1.648, 0.02, "sigma of sodium")
    close(out.I, 0.1739, 0.001, "I")
})

test("MES 25 mM, pH 6.5, 0.1 M NaCl + 0.2 M Arg-HCl: the sodium of SASDRJ8", () => {
    // SASDRJ8.jl: Na+ 0.017144 +- 0.001443, I 0.317; notes table 0.017140 +- 0.001440
    const out = computeTemplate({ id: "mes", mM: 25, pH: 6.5, restIonicMM: 300 })
    close(rowNamed(out, "sodium(1+)").mM, 17.14, 0.002, "sodium")
    close(rowNamed(out, "sodium(1+)").sigmaMM, 1.44, 0.01, "sigma of sodium")
    close(out.I, 0.3171, 0.001, "I")
})

test("phosphate 100 mM, pH 7.0 at 20 C: the split of the removed SASDV82", () => {
    const out = computeTemplate({ id: "phosphate", mM: 100, pH: 7.0, tempC: 20 })
    const hpo4 = rowNamed(out, "disodium hydrogen phosphate")
    const h2po4 = rowNamed(out, "sodium dihydrogen phosphate")
    // notes table: with dCp 60.01 / 39.99 (the table's dCp of -230 J/K/mol, this engine's)
    close(hpo4.mM, 60.01, 0.0005, "HPO4 with dCp")
    close(h2po4.mM, 39.99, 0.0005, "H2PO4 with dCp")
    // the SASDV82 script (removed): 60.1 / 39.9 mM (van't Hoff only), I 0.22
    close(hpo4.mM, 60.1, 0.003, "HPO4 of SASDV82")
    close(h2po4.mM, 39.9, 0.003, "H2PO4 of SASDV82")
    close(out.I, 0.22, 0.002, "I")
    // the sodium is inside the salt rows: no separate row
    assert.equal(out.rows.length, 2)
})

/** The sodium of a citrate salt row, per mole. */
const sodiumOf: Record<string, number> = {
    "trisodium citrate": 3,
    "disodium hydrogen citrate": 2,
    "sodium dihydrogen citrate": 1,
}

test("citrate 100 mM, pH 6.0 at 25 C: the species and sodium of SASDAX2", () => {
    // SASDAX2.jl: Cit3- 64.94 / HCit2- 34.28 / H2Cit- 0.78 mM, Na+ 0.264 M, I 0.49
    const out = computeTemplate({ id: "citrate", mM: 100, pH: 6.0, tempC: 25 })
    close(rowNamed(out, "trisodium citrate").mM, 64.94, 0.001, "Cit3-")
    close(rowNamed(out, "disodium hydrogen citrate").mM, 34.28, 0.001, "HCit2-")
    close(rowNamed(out, "sodium dihydrogen citrate").mM, 0.78, 0.01, "H2Cit-")
    const sodium = out.rows.reduce((s, r) => s + r.mM * (sodiumOf[r.name] ?? 0), 0)
    close(sodium, 264.2, 0.001, "Na+")
    close(out.I, 0.4932, 0.001, "I")
    // sigma of the main species: 0.012 M in the script, 11-12 mM here
    close(rowNamed(out, "trisodium citrate").sigmaMM, 12, 0.1, "sigma of Cit3-")
})

test("a potassium titrant: species rows and a potassium row as big as the sodium", () => {
    // trisodium/potassium salts of citrate: the table has only tripotassium citrate, so
    // the species rows are used and the cation is its own row
    const na = computeTemplate({ id: "citrate", mM: 100, pH: 6, tempC: 25 })
    const cation = "potassium(1+)"
    const k = computeTemplate({ id: "citrate", mM: 100, pH: 6, tempC: 25, cation })
    const sodium = na.rows.reduce((s, r) => s + r.mM * (sodiumOf[r.name] ?? 0), 0)
    close(rowNamed(k, "potassium(1+)").mM, sodium, 1e-3, "charge balance")
    assert.ok(k.rows.some((r) => r.name === "citrate"))
})

// ========================================================================================
// 6. Engine: mixtures
// ========================================================================================

test("PBS: the rows as listed and the chloride of the adjustment", () => {
    const out = computeTemplate({ id: "pbs" })
    assert.equal(out.pH, 7.4)
    assert.deepEqual(
        out.rows.map((r) => [r.name, r.mM]),
        [
            ["sodium chloride", 137],
            ["potassium chloride", 2.7],
            ["disodium hydrogen phosphate", 10],
            ["potassium dihydrogen phosphate", 1.8],
            ["chloride", 0.73],
        ],
    )
    assert.equal(rowNamed(out, "chloride").sigmaMM, 0.73, "sigma 100 % of the adjustment")
})

test("TBS, HBS and SSC: their buffer worked out at the pH of the recipe", () => {
    // notes section 5: Tris 50 mM at pH 7.6 gives chloride 41.40 +- 2.42 mM
    const tbs = computeTemplate({ id: "tbs" })
    close(rowNamed(tbs, "chloride").mM, 41.4, 0.001, "TBS chloride")
    close(rowNamed(tbs, "chloride").sigmaMM, 2.42, 0.01, "TBS sigma")
    // HEPES 25 mM at pH 7.05: sodium 6.76 +- 1.30 mM
    const hbs = computeTemplate({ id: "hbs" })
    close(rowNamed(hbs, "sodium(1+)").mM, 6.76, 0.002, "HBS sodium")
    close(rowNamed(hbs, "sodium(1+)").sigmaMM, 1.3, 0.01, "HBS sigma")
    // SSC 1x: Cit3- 14.22, HCit2- 0.78 mM, I 0.24 M
    const ssc = computeTemplate({ id: "ssc" })
    close(rowNamed(ssc, "trisodium citrate").mM, 14.22, 0.002, "SSC Cit3-")
    close(rowNamed(ssc, "disodium hydrogen citrate").mM, 0.78, 0.01, "SSC HCit2-")
    close(ssc.I, 0.24, 0.02, "SSC I")
    // a mixture at another pH than its own (the pH given wins)
    assert.equal(computeTemplate({ id: "tbs", pH: 7.4 }).pH, 7.4)
})

// ========================================================================================
// 7. Engine: what is offered, the warnings and the edge cases
// ========================================================================================

test("the unavailable templates are not offered and cannot be computed", () => {
    const ids = offered().map((t) => t.id)
    for (const id of ["aces", "hepps"]) {
        assert.equal(templateById(id)?.available, false)
        assert.ok(!ids.includes(id), id)
        assert.throws(() => computeTemplate({ id, mM: 10, pH: 7.5 }), RangeError)
    }
    assert.equal(ids.length, 34 - 2)
    assert.ok(ids.includes("tris") && ids.includes("pbs"))
})

test("an unknown id, a missing concentration or pH throw", () => {
    const unknown = () => computeTemplate({ id: "nonsense", mM: 10, pH: 7 })
    assert.throws(unknown, /no buffer template/)
    assert.throws(() => computeTemplate({ id: "tris", pH: 7.5 }), /concentration/)
    assert.deepEqual(computeTemplate({ id: "tris", mM: 0, pH: 7.5 }).rows, [])
    assert.throws(() => computeTemplate({ id: "tris", mM: -1, pH: 7.5 }), /concentration/)
    assert.throws(() => computeTemplate({ id: "tris", mM: 10 }), /pH is needed/)
})

test("the dropdown lines: the usable range, mixtures and the unverified label", () => {
    const line = (id: string) => templateLine(templateById(id) as never)
    assert.equal(line("tris"), "Tris, pH 7.1-9.1")
    assert.equal(line("pbs"), "PBS, mixture")
    assert.equal(line("taps"), "TAPS, pH 7.4-9.4 (constants not cross-checked)")
    assert.equal(line("tbs"), "TBS, mixture (constants not cross-checked)")
})

test("the titrant choices: cations for a base, none for an acid or a mixture", () => {
    const choices = (id: string) => titrantChoices(templateById(id) as never)
    assert.deepEqual(
        choices("hepes").map(([ion]) => ion),
        ["sodium(1+)", "potassium(1+)"],
    )
    assert.deepEqual(choices("tris"), [])
    assert.deepEqual(choices("pbs"), [])
})

test("a pH far outside the usable range warns", () => {
    const out = computeTemplate({ id: "tris", mM: 10, pH: 5.0 })
    assert.ok(out.warnings.some((w) => w.includes("outside the usable range 7.1-9.1")))
    // fully protonated: chloride is as much as the Tris
    close(rowNamed(out, "chloride").mM, 10, 0.001, "chloride at pH 5")
    const fine = computeTemplate({ id: "tris", mM: 10, pH: 7.5 })
    assert.deepEqual(fine.warnings, [])
})

test("an ionic strength above 0.5 M warns about Davies", () => {
    const out = computeTemplate({ id: "hepes", mM: 25, pH: 7.4, restIonicMM: 800 })
    assert.ok(out.warnings.some((w) => w.includes("Davies")), out.warnings.join("|"))
})

test("an unverified template and a step that is not the main one warn", () => {
    const taps = computeTemplate({ id: "taps", mM: 10, pH: 8.4 })
    assert.ok(taps.warnings.some((w) => w.includes("not cross-checked")))
    // phosphate far from pK2: the pH sits at pK1, an unverified step
    const phosphate = computeTemplate({ id: "phosphate", mM: 50, pH: 2.2 })
    assert.ok(phosphate.warnings.some((w) => w.includes("not the main step 2")))
    // a step with no temperature coefficient
    const btp = computeTemplate({ id: "bis-tris-propane", mM: 20, pH: 9.1 })
    assert.ok(btp.warnings.some((w) => w.includes("no temperature coefficient")))
})

test("no ionic strength from the rest of the recipe still solves", () => {
    const out = computeTemplate({ id: "tris", mM: 10, pH: 7.5 })
    // the buffer alone: I = 0.5 (TrisH+ + Cl-) = f x 10 mM
    close(out.I, 0.0085, 0.02, "I of the buffer alone")
    assert.ok(rowNamed(out, "chloride").mM > 8 && rowNamed(out, "chloride").mM < 9)
})

test("the counter-ion: chloride for an acid-titrated buffer, a cation for a base", () => {
    const tris = computeTemplate({ id: "tris", mM: 10, pH: 7.5 })
    assert.ok(tris.rows.some((r) => r.name === "chloride"))
    const hepes = computeTemplate({ id: "hepes", mM: 25, pH: 7.4, cation: "potassium(1+)" })
    assert.ok(hepes.rows.some((r) => r.name === "potassium(1+)"))
    assert.ok(!hepes.rows.some((r) => r.name === "sodium(1+)"))
    // notes section 7: sodium goes from 1 to 2 per PIPES over the buffering range
    const pipes = computeTemplate({ id: "pipes", mM: 20, pH: 6.9 })
    const na = rowNamed(pipes, "sodium(1+)").mM
    assert.ok(na > 20 && na < 40, `${na}`)
})

test("bis-tris propane (two pK): three species rows, closed-form fractions, Cl", () => {
    // 0.0001 mM and no other ions: I is about 1e-7 M, so the Davies terms are below 0.1 %
    // and the fractions are the textbook diprotic ones at the pK of 22 C
    // (pK1 6.65 - 0.016 x 3 K, pK2 9.1 without a slope)
    const pK1 = 6.65 - 0.016 * (SET_TEMPERATURE_C - 25)
    const pK2 = 9.1
    for (const pH of [5, pK1, 8, pK2, 10.5]) {
        const recipe = { id: "bis-tris-propane", mM: 0.0001, pH, restIonicMM: 0 }
        const out = computeTemplate(recipe)
        const w = [1, 10 ** (pH - pK1), 10 ** (2 * pH - pK1 - pK2)]
        const sum = w[0] + w[1] + w[2]
        assert.deepEqual(out.charges, [2, 1, 0])
        out.fractions?.forEach((f, i) => {
            assert.ok(Math.abs(f - w[i] / sum) < 0.002, `pH ${pH} species ${i}: ${f}`)
        })
        close(out.fractions?.reduce((a, b) => a + b, 0) as number, 1, 1e-12, "sum")
    }
    // 20 mM at pH 7.5 with 100 mM of other salt: all three species rows are the table's
    // species, the chloride is exactly the charge they carry
    const recipe = { id: "bis-tris-propane", mM: 20, pH: 7.5, restIonicMM: 100 }
    const out = computeTemplate(recipe)
    const species = [
        ["bis-tris propane dication", 2],
        ["bis-tris propane cation", 1],
        ["bis-tris propane", 0],
    ] as const
    let charge = 0
    for (const [name, z] of species) {
        const row = rowNamed(out, name)
        assert.ok(row.mM > 0, name)
        charge += z * row.mM
    }
    close(rowNamed(out, "chloride").mM, charge, 2e-3, "chloride balances the cations")
    // the total is the buffer's molarity
    const total = species.reduce((s, [name]) => s + rowNamed(out, name).mM, 0)
    close(total, 20, 1e-3, "species add up to the buffer")
    // above pK2 only the neutral species is left and nothing needs balancing
    const high = computeTemplate({ id: "bis-tris-propane", mM: 20, pH: 13 })
    assert.deepEqual(
        high.rows.map((r) => r.name),
        ["bis-tris propane"],
    )
})

test("glycylglycine (two pK): polymer rows, closed-form fractions, sodium", () => {
    // 0.0001 mM and no other ions: the Davies terms are below 0.1 %, so the fractions are
    // the textbook diprotic ones at the pK of 22 C (pK1 3.14 without a slope, pK2 8.265
    // with -0.0255 per K)
    const pK1 = 3.14
    const pK2 = 8.265 - 0.0255 * (SET_TEMPERATURE_C - 25)
    for (const pH of [2, pK1, 6, pK2, 10]) {
        const recipe = { id: "glycylglycine", mM: 0.0001, pH, restIonicMM: 0 }
        const out = computeTemplate(recipe)
        const w = [1, 10 ** (pH - pK1), 10 ** (2 * pH - pK1 - pK2)]
        const sum = w[0] + w[1] + w[2]
        assert.deepEqual(out.charges, [1, 0, -1])
        out.fractions?.forEach((f, i) => {
            assert.ok(Math.abs(f - w[i] / sum) < 0.002, `pH ${pH} species ${i}: ${f}`)
        })
    }
    // 20 mM at pH 8.3, 100 mM of other salt, titrated with NaOH: the three species are
    // rows of the polymer table (the zwitterion under its IUPAC name, which is not parsed
    // as the peptide GG), the sodium is the charge the anion carries
    const recipe = { id: "glycylglycine", mM: 20, pH: 8.3, restIonicMM: 100 }
    const out = computeTemplate(recipe)
    const zwitterion = "2-(2-aminoacetamido)acetic acid"
    const mine = out.rows.filter((r) => r.kind === "polymer")
    assert.ok(mine.length >= 2)
    const zwitter = out.rows.find((r) => r.arg === zwitterion)
    assert.ok(zwitter && zwitter.mM > 0)
    const anion = rowNamed(out, "glycylglycine(1-)")
    assert.equal(anion.arg, "glycylglycine(1-)")
    assert.equal(anion.kind, "polymer")
    close(rowNamed(out, "sodium(1+)").mM, anion.mM, 2e-3, "sodium balances the anion")
    close(mine.reduce((a, r) => a + r.mM, 0), 20, 1e-3, "species add up to the buffer")
    // at low pH the cation is balanced by chloride
    const acid = computeTemplate({ id: "glycylglycine", mM: 20, pH: 2, restIonicMM: 100 })
    assert.ok(acid.rows.some((r) => r.name === "glycylglycine(1+)"))
    assert.ok(acid.rows.some((r) => r.name === "chloride"))
    // the engine writes polymer rows with their kind
    const draft = soluteFromSpec(zwitter as RowSpec)
    assert.equal(draft.kind, "polymer")
    assert.equal(draft.arg, zwitterion)
})

test("every offered template gives complete rows that pass the loader's check", () => {
    for (const t of offered()) {
        const mid = t.usablePh ? (t.usablePh[0] + t.usablePh[1]) / 2 : undefined
        const out = computeTemplate({ id: t.id, mM: 20, pH: mid, restIonicMM: 100 })
        assert.ok(out.rows.length > 0, t.id)
        for (const r of out.rows) {
            assert.ok(r.mM > 0 && Number.isFinite(r.mM), `${t.id} ${r.name} ${r.mM}`)
            assert.ok(r.sigmaMM >= 0 && Number.isFinite(r.sigmaMM), `${t.id} ${r.name}`)
            const solute: Solute = { kind: r.kind ?? "nonbiological", ...r }
            assert.equal(rowProblem(bufferRow(solute)), undefined, `${t.id} ${r.name}`)
            assert.notEqual(r.arg, "", t.id)
        }
        assert.ok(out.I > 0.1, `${t.id} I ${out.I}`)
    }
})

test("the ionic strength of rows already in the table", () => {
    assert.equal(ionicPerMM("sodium chloride"), 1)
    assert.equal(ionicPerMM("magnesium dichloride"), 3)
    assert.equal(ionicPerMM("glycerol"), 0)
    const rows = [
        { arg: "sodium chloride", mM: 150 },
        { arg: "magnesium dichloride", mM: 2.5 },
        { arg: "glycerol", mM: 1000 },
        { arg: "tris", mM: null },
    ]
    assert.equal(restIonicStrength(rows), 157.5)
    assert.equal(restIonicStrength([]), 0)
})

// ========================================================================================
// 8. Engine: any pH: the engine never throws, never gives NaN or a negative amount
// ========================================================================================

/** The cation charges a salt row or an ion row carries per mole (chloride is -1). */
function cationCharge(name: string): number {
    if (name === "chloride") return -1
    const m = /^(tri|di)?(sodium|potassium)/.exec(name)
    if (!m) return 0
    return m[1] === "tri" ? 3 : m[1] === "di" ? 2 : 1
}

/** The pH of the sweep: 0 to 14 in halves, and beyond (which is clamped). */
const SWEEP = [-3, ...Array.from({ length: 29 }, (_, i) => i / 2), 20]

test("a sweep of the pH for every template: finite, positive, balanced, monotone", () => {
    for (const t of offered()) {
        for (const mM of [20, 1e-9]) {
            for (const restIonicMM of [0, 500]) {
                let previous = Number.POSITIVE_INFINITY
                for (const pH of SWEEP) {
                    const what = `${t.id} ${mM} mM, rest ${restIonicMM}, pH ${pH}`
                    const out = computeTemplate({ id: t.id, mM, pH, restIonicMM })
                    assert.ok(out.pH >= 0 && out.pH <= 14, what)
                    const told = out.warnings.some((w) => w.includes("0 to 14"))
                    assert.equal(told, pH < 0 || pH > 14)
                    assert.ok(Number.isFinite(out.I) && out.I >= 0, what)
                    for (const r of out.rows) {
                        assert.ok(r.mM > 0 && Number.isFinite(r.mM), `${what} ${r.name}`)
                        const sigma = r.sigmaMM
                        assert.ok(sigma >= 0 && Number.isFinite(sigma), `${what} ${r.name}`)
                    }
                    if (t.kind !== "buffer") continue
                    const f = out.fractions as number[]
                    const z = out.charges as number[]
                    assert.ok(f.every((x) => x >= 0 && x <= 1 + 1e-12), what)
                    close(f.reduce((a, b) => a + b, 0), 1, 1e-9, `${what}: fractions`)
                    // the mean charge only falls as the pH rises
                    const mean = f.reduce((s, x, i) => s + x * z[i], 0)
                    assert.ok(mean <= previous + 1e-9, `${what}: ${mean} after ${previous}`)
                    previous = Math.min(previous, mean)
                    // charge balance: the counter-ion cancels the net charge of the buffer
                    if (mM < 1) continue
                    const net = mean * mM
                    const cations = out.rows.reduce(
                        (s, r) => s + r.mM * cationCharge(r.name),
                        0,
                    )
                    const gap = Math.abs(cations + net)
                    assert.ok(gap <= 0.005 * mM, `${what}: ${cations} vs ${net}`)
                }
            }
        }
    }
})

test("a pH outside 0 to 14 is clamped with a warning", () => {
    const out = computeTemplate({ id: "tris", mM: 10, pH: 17 })
    assert.equal(out.pH, 14)
    assert.ok(out.warnings.some((w) => w.includes("17 is outside 0 to 14")))
    assert.equal(out.converged, true)
})
