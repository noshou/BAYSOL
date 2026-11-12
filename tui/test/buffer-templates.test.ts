// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/buffer-templates.ts: the engine that turns a standard buffer, its
// concentration and the pH into rows. The expected numbers are the hand calculations of
// the fitting scripts (`test/fitting_tests/<ID>/<ID>.jl`) and the validation table of
// `notes/buffer-templates.md` (section 4), which this engine reproduces.

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
    templateById,
    templateLine,
    titrantChoices,
} from "../src/store/buffer-templates.js"
import { bufferRow, type Solute } from "../src/store/solutes.js"

/** The row of a name, which must be there. */
function row(out: Outcome, name: string): RowSpec {
    const found = out.rows.find((r) => r.name === name)
    assert.ok(found, `${name} in ${out.rows.map((r) => r.name).join(", ")}`)
    return found
}

/** `actual` is within `rel` (a fraction) of `expected`. */
function close(actual: number, expected: number, rel: number, what: string): void {
    const gap = Math.abs(actual - expected) / Math.abs(expected)
    assert.ok(gap <= rel, `${what}: ${actual} vs ${expected} (${(gap * 100).toFixed(3)} %)`)
}

// ========================================================================================
// 1. The hand calculations of the repo, reproduced
// ========================================================================================

test("Tris 10 mM, pH 7.5, 0.1 M NaCl: the chloride of SASDEM7", () => {
    // SASDEM7.jl: Cl- 0.008536 +- 0.000431 M, I = 0.1085 M; the notes table: 0.008537
    const out = computeTemplate({ id: "tris", mM: 10, pH: 7.5, restI_mM: 100 })
    close(row(out, "chloride").mM, 8.537, 0.001, "chloride")
    close(row(out, "chloride").sigmaMM, 0.431, 0.01, "sigma of chloride")
    close(out.I, 0.1085, 0.001, "I")
    assert.deepEqual(row(out, "tris"), {
        name: "tris",
        arg: "2-amino-2-(hydroxymethyl)propane-1,3-diol",
        mM: 10,
        sigmaMM: 0.2,
    })
    assert.equal(out.rows.length, 2)
})

test("Tris 10 mM with 0.2 M NaCl, 20 mM with 0.5 M: SASDMJ9 and SASDMM3", () => {
    // notes table: 0.008588 +- 0.000422 (SASDMJ9 header), here 0.008589 +- 0.000424
    const mj = computeTemplate({ id: "tris", mM: 10, pH: 7.5, restI_mM: 200 })
    close(row(mj, "chloride").mM, 8.589, 0.002, "SASDMJ9 chloride")
    close(row(mj, "chloride").sigmaMM, 0.424, 0.01, "SASDMJ9 sigma")
    // SASDMM3 header: 0.017209 +- 0.000838, here 0.017212 +- 0.000843 (I 0.5172)
    const mm = computeTemplate({ id: "tris", mM: 20, pH: 7.5, restI_mM: 500 })
    close(row(mm, "chloride").mM, 17.212, 0.002, "SASDMM3 chloride")
    close(row(mm, "chloride").sigmaMM, 0.843, 0.01, "SASDMM3 sigma")
})

test("HEPES 25 mM, pH 7.4 with NaOH: the sodium of SASDBA8", () => {
    // SASDBA8.jl: 0.456 x 25 mM = 11.40 mM (file 0.011402), sigma 0.001681 (vendor dT);
    // notes table: 0.011395 M, sigma 0.001648, I 0.1739. The rest: 0.15 M NaCl + 2.5 mM
    // MgCl2 (7.5 mM) + 0.5 mM AMP-PNP(4-) with its 2 mM Na+ (5 mM) = 162.5 mM
    const out = computeTemplate({ id: "hepes", mM: 25, pH: 7.4, restI_mM: 162.5 })
    close(row(out, "sodium(1+)").mM, 11.395, 0.002, "sodium")
    close(row(out, "sodium(1+)").sigmaMM, 1.648, 0.02, "sigma of sodium")
    close(out.I, 0.1739, 0.001, "I")
})

test("MES 25 mM, pH 6.5, 0.1 M NaCl + 0.2 M Arg-HCl: the sodium of SASDRJ8", () => {
    // SASDRJ8.jl: Na+ 0.017144 +- 0.001443, I 0.317; notes table 0.017140 +- 0.001440
    const out = computeTemplate({ id: "mes", mM: 25, pH: 6.5, restI_mM: 300 })
    close(row(out, "sodium(1+)").mM, 17.14, 0.002, "sodium")
    close(row(out, "sodium(1+)").sigmaMM, 1.44, 0.01, "sigma of sodium")
    close(out.I, 0.3171, 0.001, "I")
})

test("phosphate 100 mM, pH 7.0 at 20 C: the split of SASDV82", () => {
    const out = computeTemplate({ id: "phosphate", mM: 100, pH: 7.0, tempC: 20 })
    const hpo4 = row(out, "disodium hydrogen phosphate")
    const h2po4 = row(out, "sodium dihydrogen phosphate")
    // notes table: with dCp 60.01 / 39.99 (the table's dCp of -230 J/K/mol, this engine's)
    close(hpo4.mM, 60.01, 0.0005, "HPO4 with dCp")
    close(h2po4.mM, 39.99, 0.0005, "H2PO4 with dCp")
    // SASDV82.jl: 60.1 / 39.9 mM (van't Hoff only), I 0.22
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
    close(row(out, "trisodium citrate").mM, 64.94, 0.001, "Cit3-")
    close(row(out, "disodium hydrogen citrate").mM, 34.28, 0.001, "HCit2-")
    close(row(out, "sodium dihydrogen citrate").mM, 0.78, 0.01, "H2Cit-")
    const sodium = out.rows.reduce((s, r) => s + r.mM * (sodiumOf[r.name] ?? 0), 0)
    close(sodium, 264.2, 0.001, "Na+")
    close(out.I, 0.4932, 0.001, "I")
    // sigma of the main species: 0.012 M in the script, 11-12 mM here
    close(row(out, "trisodium citrate").sigmaMM, 12, 0.1, "sigma of Cit3-")
})

test("a potassium titrant: species rows and a potassium row as big as the sodium", () => {
    // trisodium/potassium salts of citrate: the table has only tripotassium citrate, so
    // the species rows are used and the cation is its own row
    const na = computeTemplate({ id: "citrate", mM: 100, pH: 6, tempC: 25 })
    const cation = "potassium(1+)"
    const k = computeTemplate({ id: "citrate", mM: 100, pH: 6, tempC: 25, cation })
    const sodium = na.rows.reduce((s, r) => s + r.mM * (sodiumOf[r.name] ?? 0), 0)
    close(row(k, "potassium(1+)").mM, sodium, 1e-3, "charge balance")
    assert.ok(k.rows.some((r) => r.name === "citrate"))
})

// ========================================================================================
// 2. Mixtures
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
    assert.equal(row(out, "chloride").sigmaMM, 0.73, "sigma 100 % of the adjustment")
})

test("TBS, HBS and SSC: their buffer worked out at the pH of the recipe", () => {
    // notes section 5: Tris 50 mM at pH 7.6 gives chloride 41.40 +- 2.42 mM
    const tbs = computeTemplate({ id: "tbs" })
    close(row(tbs, "chloride").mM, 41.4, 0.001, "TBS chloride")
    close(row(tbs, "chloride").sigmaMM, 2.42, 0.01, "TBS sigma")
    // HEPES 25 mM at pH 7.05: sodium 6.76 +- 1.30 mM
    const hbs = computeTemplate({ id: "hbs" })
    close(row(hbs, "sodium(1+)").mM, 6.76, 0.002, "HBS sodium")
    close(row(hbs, "sodium(1+)").sigmaMM, 1.3, 0.01, "HBS sigma")
    // SSC 1x: Cit3- 14.22, HCit2- 0.78 mM, I 0.24 M
    const ssc = computeTemplate({ id: "ssc" })
    close(row(ssc, "trisodium citrate").mM, 14.22, 0.002, "SSC Cit3-")
    close(row(ssc, "disodium hydrogen citrate").mM, 0.78, 0.01, "SSC HCit2-")
    close(ssc.I, 0.24, 0.02, "SSC I")
    // a mixture at another pH than its own (the pH given wins)
    assert.equal(computeTemplate({ id: "tbs", pH: 7.4 }).pH, 7.4)
})

// ========================================================================================
// 3. What is offered, the warnings and the edge cases
// ========================================================================================

test("the unavailable templates are not offered and cannot be computed", () => {
    const ids = offered().map((t) => t.id)
    for (const id of ["aces", "glycylglycine", "hepps"]) {
        assert.equal(templateById(id)?.available, false)
        assert.ok(!ids.includes(id), id)
        assert.throws(() => computeTemplate({ id, mM: 10, pH: 7.5 }), RangeError)
    }
    assert.equal(ids.length, 31 - 3)
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
    close(row(out, "chloride").mM, 10, 0.001, "chloride at pH 5")
    const fine = computeTemplate({ id: "tris", mM: 10, pH: 7.5 })
    assert.deepEqual(fine.warnings, [])
})

test("an ionic strength above 0.5 M warns about Davies", () => {
    const out = computeTemplate({ id: "hepes", mM: 25, pH: 7.4, restI_mM: 800 })
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
    assert.ok(row(out, "chloride").mM > 8 && row(out, "chloride").mM < 9)
})

test("the counter-ion: chloride for an acid-titrated buffer, a cation for a base", () => {
    const tris = computeTemplate({ id: "tris", mM: 10, pH: 7.5 })
    assert.ok(tris.rows.some((r) => r.name === "chloride"))
    const hepes = computeTemplate({ id: "hepes", mM: 25, pH: 7.4, cation: "potassium(1+)" })
    assert.ok(hepes.rows.some((r) => r.name === "potassium(1+)"))
    assert.ok(!hepes.rows.some((r) => r.name === "sodium(1+)"))
    // notes section 7: sodium goes from 1 to 2 per PIPES over the buffering range
    const pipes = computeTemplate({ id: "pipes", mM: 20, pH: 6.9 })
    const na = row(pipes, "sodium(1+)").mM
    assert.ok(na > 20 && na < 40, `${na}`)
})

test("every offered template gives complete rows that pass the loader's check", () => {
    for (const t of offered()) {
        const mid = t.usable_pH ? (t.usable_pH[0] + t.usable_pH[1]) / 2 : undefined
        const out = computeTemplate({ id: t.id, mM: 20, pH: mid, restI_mM: 100 })
        assert.ok(out.rows.length > 0, t.id)
        for (const r of out.rows) {
            assert.ok(r.mM > 0 && Number.isFinite(r.mM), `${t.id} ${r.name} ${r.mM}`)
            assert.ok(r.sigmaMM >= 0 && Number.isFinite(r.sigmaMM), `${t.id} ${r.name}`)
            const solute: Solute = { kind: "nonbiological", ...r }
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
// 4. Any pH: the engine never throws, never gives NaN or a negative amount
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
            for (const restI_mM of [0, 500]) {
                let previous = Number.POSITIVE_INFINITY
                for (const pH of SWEEP) {
                    const what = `${t.id} ${mM} mM, rest ${restI_mM}, pH ${pH}`
                    const out = computeTemplate({ id: t.id, mM, pH, restI_mM })
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
