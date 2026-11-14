// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/template-defs.ts: the custom and table definitions of a template, their
// validators and the dispatcher `rowsFor`. The key check: a custom definition holding the
// numbers of a shipped buffer gives the shipped buffer's rows.

import assert from "node:assert/strict"
import { test } from "node:test"
import { computeTemplate, templateById } from "../src/store/buffer-templates.js"
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
