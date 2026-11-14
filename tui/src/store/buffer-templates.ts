// SPDX-License-Identifier: LGPL-3.0-or-later

// Buffer templates: from a standard buffer (Tris, HEPES, phosphate, PBS ...), its
// concentration and the pH, the rows of the solutes table, the way the fitting
// scripts work them out by hand (`test/fitting_tests/SASDRJ8`, `SASDAX2`, `SASDMJ9`;
// the scripts of SASDEM7, SASDBA8 and SASDV82, removed on 2026-11-12, are kept as
// numbers in the tests). Pure: no screen, no file but the constants asset. The
// constants, their sources and what was checked are in `notes/buffer-templates.md`.
//
// The method: the pK of each group is moved from 25 °C to the temperature the pH was set
// at (Clarke and Glew, from `dH` and `dCp`); the species at the pH come from the ladder of
// the steps, `[B]/[A] = 10^(pH - pK) γ(zA) / γ(zB)`, with the Davies activity
// coefficients `log γ = -A z² (√I / (1 + √I) - 0.3 I)` at the ionic strength of the whole
// recipe, solved self-consistently; the charge of the buffer is balanced by the counter-ion
// (chloride for a positive net charge, sodium or potassium for a negative one). σ is the
// central-difference combination, in quadrature, of σ(pH), ±3 °C, ±0.02 pK, ±30 % of the
// Davies shift and the uncertainty of the concentration.
//
// Contents:
//   1. The asset and the list of templates offered
//   2. The numerics: pK(T), Davies, the species, the self-consistent ionic strength
//   3. `computeTemplate`: rows, explanation, warnings
//   4. The ionic strength of rows already in the table

import { lazyAsset } from "../core/environment.js"
import { resolveBuiltin } from "./solutes.js"

// ========================================================================================
// 1. The asset and the list of templates offered
// ========================================================================================

/** One acid-base step of a buffer: `A(zAcid) = H+ + B(zBase)`. */
type Group = {
    pKa25: number
    pKaSigma: number
    dpKaDtPerK: number | null
    dHKjMol: number | null
    dCpJKMol: number | null
    zAcid: number
    zBase: number
    verified: boolean
}

/** What a template says of the titrant: an acid (its anion) or a base (its cation). */
type Titrant = { kind: "acid" | "base"; ion: string }

/** A row of a mixture, as listed in the recipe. */
type Component = { solute: string; mM: number; sigmaMm: number }

/** A buffer inside a mixture (TBS, HBS, SSC): another template at a concentration. */
type BufferComponent = { template: string; mM: number; titrant?: Titrant }

/** A template of `assets/data/buffer_templates.json`; only the keys used here are typed. */
export type Template = {
    id: string
    label: string
    kind: "buffer" | "mixture"
    available?: boolean
    verified: boolean
    notes?: string
    // a buffer
    groups?: Group[]
    usablePh?: [number, number]
    defaultTitrant?: Titrant
    solute?: string | null
    speciesRows?: string[]
    saltRows?: Record<string, (string | null)[]>
    // a mixture
    components?: Component[]
    bufferComponents?: BufferComponent[]
    pH?: number
    pHAdjust?: { titrant: string; modelAmountMm: number; note: string }
}

/** The templates of the asset, read on first use. */
const allTemplates = lazyAsset<Template[]>("data", "buffer_templates.json")

/**
 * The templates the table offers: those with a bundled solute row (`available` is not
 * `false`), in the order of the asset.
 *
 * @returns the templates.
 */
export function offered(): Template[] {
    return allTemplates().filter((t) => t.available !== false)
}

/**
 * A template by its id.
 *
 * @param id - `tris`, `pbs`, ...
 * @returns the template, `undefined` for an id that is not in the asset.
 */
export function templateById(id: string): Template | undefined {
    return allTemplates().find((t) => t.id === id)
}

/** What the label of an unverified template says. */
const UNVERIFIED_LABEL = "(constants not cross-checked)"

/**
 * A template as one line of the dropdown: the name (the label up to its first comma or
 * bracket), its usable pH range or `mixture`, and the unverified mark.
 *
 * @param t - the template.
 * @returns the text, e.g. `Tris, pH 7.1-9.1`.
 */
export function templateLine(t: Template): string {
    const name = shortName(t)
    const where = t.kind === "mixture" ? "mixture" : `pH ${rangeText(t.usablePh)}`
    return `${name}, ${where}${t.verified ? "" : ` ${UNVERIFIED_LABEL}`}`
}

/** The name of a template without its explanation: the label up to a comma or bracket. */
const shortName = (t: Template): string => t.label.replace(/\s*[(,].*$/, "")

/** A pH range as `7.1-9.1`. */
function rangeText(range: [number, number] | undefined): string {
    return range ? `${range[0]}-${range[1]}` : "?"
}

/**
 * Whether a template needs a concentration (a buffer does, a mixture is a recipe).
 *
 * @param t - the template.
 * @returns `true` for a buffer.
 */
export const needsConcentration = (t: Template): boolean => t.kind === "buffer"

/**
 * Whether the pH is the user's to give: a buffer's is, a mixture's is its own except
 * where a buffer inside it (TBS, HBS, SSC) is worked out at it; PBS is fixed at 7.4.
 *
 * @param t - the template.
 * @returns `true` when the pH is asked.
 */
export const asksPH = (t: Template): boolean =>
    t.kind === "buffer" || (t.bufferComponents?.length ?? 0) > 0

/** The cations a base titrant may be: `[name, what]`, the default first. */
const CATIONS: readonly [string, string][] = [
    ["sodium(1+)", "NaOH (sodium)"],
    ["potassium(1+)", "KOH (potassium)"],
]

/**
 * The titrants a template offers as a choice: the cations when it is titrated with a base
 * (the default first); nothing when its only counter-ion is chloride, or for a mixture.
 *
 * @param t - the template.
 * @returns `[ion, label]` pairs, empty when there is no choice.
 */
export function titrantChoices(t: Template): readonly [string, string][] {
    if (t.kind !== "buffer" || t.defaultTitrant?.kind !== "base") return []
    const first = t.defaultTitrant.ion === "potassium" ? 1 : 0
    return [CATIONS[first], CATIONS[1 - first]]
}

// ========================================================================================
// 2. The numerics
// ========================================================================================

/** The Davies constant at 25 °C, as the repo's scripts use it. */
const DAVIES_A = 0.509

/** The temperature (°C) the pH is taken as set at: room temperature, as the scripts do. */
export const SET_TEMPERATURE_C = 22

/** The ionic strength (M) above which Davies is not reliable. */
const DAVIES_LIMIT_M = 0.5

/** σ of the pH meter (pH), as `PH_METER_SIGMA` of the fitting scripts. */
const PH_SIGMA = 0.1

/** The ±temperature (°C) of the σ: the room temperature of the scripts, ±3 °C. */
const TEMPERATURE_SPREAD_C = 3

/** The ±pK of the σ, at least (the pK of a group graded worse is its own σ). */
const PK_SPREAD = 0.02

/** The Davies shift of the σ: its constant is scaled by ±30 %. */
const DAVIES_SPREAD = 0.3

/** The default relative uncertainty of a concentration. */
export const DEFAULT_RELATIVE_SIGMA = 0.02

/** The reference temperature of the constants, K. */
const T_REF = 298.15

/** The gas constant, J / (mol K). */
const R_GAS = 8.314462618

/** The offset between °C and K. */
const KELVIN = 273.15

/** The pK of a group with no temperature data changes by this much per K in the σ only. */
const AMINE_SLOPE = -0.03

/** The species below this share of the total are left out of the rows. */
const NEGLIGIBLE = 1e-3

/** The largest number of rounds of the self-consistent ionic strength. */
const MAX_ROUNDS = 1000

/** The pH the meter and the file allow. */
const PH_MIN = 0
const PH_MAX = 14

/** The ionic strength is solved to this (M). */
const I_TOLERANCE = 1e-13

/**
 * What a run of the numerics varies: the shifts of the central differences.
 *
 * @property dPH - added to the pH.
 * @property dT - added to the temperature of the pH, °C.
 * @property dPK - added to every pK.
 * @property aScale - the factor of the Davies constant.
 * @property cScale - the factor of the total concentration.
 */
type Shifts = { dPH: number; dT: number; dPK: number; aScale: number; cScale: number }

/** No shift. */
const CENTRE: Shifts = { dPH: 0, dT: 0, dPK: 0, aScale: 1, cScale: 1 }

/**
 * The pK of a group at a temperature: Clarke and Glew from `dH` and `dCp` (Goldberg,
 * Kishore and Lennen 2002, eq. 12), else the linear coefficient, else the 25 °C value.
 *
 * @param g - the group.
 * @param tempC - the temperature of the pH, °C.
 * @param dT - the shift of the temperature (the σ's), °C.
 * @returns the pK.
 */
function pKAt(g: Group, tempC: number, dT = 0): number {
    const T = tempC + dT + KELVIN
    if (g.dHKjMol !== null) {
        const dH = g.dHKjMol * 1000
        const dCp = g.dCpJKMol ?? 0
        const lnRatio =
            (dH * (1 / T_REF - 1 / T) + dCp * (T_REF / T - 1 + Math.log(T / T_REF))) /
            R_GAS
        return g.pKa25 - lnRatio / Math.LN10
    }
    if (g.dpKaDtPerK !== null) return g.pKa25 + g.dpKaDtPerK * (T - T_REF)
    // no data: the value stays, and the σ allows a typical amine's slope
    return g.pKa25 + AMINE_SLOPE * dT
}

/**
 * `log10` of the Davies activity coefficient of an ion.
 *
 * @param z - the charge.
 * @param I - the ionic strength, M.
 * @param A - the Davies constant.
 * @returns `log10 γ`.
 */
function logGamma(z: number, I: number, A: number): number {
    const s = Math.sqrt(I)
    return -A * z * z * (s / (1 + s) - 0.3 * I)
}

/**
 * What the numerics return for one set of shifts.
 *
 * @property amounts - the concentration of each species of the ladder, M.
 * @property charges - the charge of each species.
 * @property counter - the net charge of the buffer, M: the counter-ion balances it
 *     (positive: an anion, negative: a cation).
 * @property I - the ionic strength, M.
 * @property converged - the ionic strength was solved to its tolerance.
 */
type Speciation = {
    amounts: number[]
    charges: number[]
    counter: number
    // biome-ignore lint/style/useNamingConvention: ionic strength symbol
    I: number
    converged: boolean
}

/**
 * The species of a buffer at a pH and the ionic strength of the whole recipe, solved
 * self-consistently with what the buffer and its counter-ion add to it.
 *
 * @param groups - the steps, most protonated first.
 * @param C - the total concentration, M.
 * @param pH - the pH as the meter reads it.
 * @param restI - the ionic strength of the rest of the recipe, M.
 * @param tempC - the temperature of the pH, °C.
 * @param shifts - the shifts of the central differences.
 * @returns the species, the counter-ion and I.
 */
function speciate(
    groups: Group[],
    C: number,
    pH: number,
    restI: number,
    tempC: number,
    shifts: Shifts,
): Speciation {
    const A = DAVIES_A * shifts.aScale
    const total = C * shifts.cScale
    const pKs = groups.map((g) => pKAt(g, tempC, shifts.dT) + shifts.dPK)
    const charges = [groups[0].zAcid, ...groups.map((g) => g.zBase)]
    let I = restI
    let last: Speciation | undefined
    for (let round = 0; round < MAX_ROUNDS; round++) {
        // the ladder in log10, relative to the most protonated species: nothing overflows
        const logs = [0]
        groups.forEach((g, k) => {
            const step =
                pH + shifts.dPH - pKs[k] +
                logGamma(g.zAcid, I, A) - logGamma(g.zBase, I, A)
            logs.push(logs[k] + step)
        })
        const top = Math.max(...logs)
        const weights = logs.map((l) => 10 ** (l - top))
        const sum = weights.reduce((a, b) => a + b, 0)
        const amounts = weights.map((w) => (total * w) / sum)
        const Q = amounts.reduce((q, c, i) => q + charges[i] * c, 0)
        const next =
            restI +
            0.5 * amounts.reduce((s, c, i) => s + charges[i] ** 2 * c, 0) +
            0.5 * Math.abs(Q)
        last = { amounts, charges, counter: Q, I: next, converged: false }
        if (Math.abs(next - I) < I_TOLERANCE) {
            last.converged = true
            return last
        }
        I = 0.5 * (I + next)
    }
    // the last value stands, and the outcome says so
    return last as Speciation

}

/** The shifts of the σ, one at a time, each as `[low, high]`. */
function sigmaShifts(sigmaPH: number, relC: number, pKSpread: number): Shifts[][] {
    const s = (x: Partial<Shifts>): Shifts => ({ ...CENTRE, ...x })
    return [
        [s({ dPH: -sigmaPH }), s({ dPH: sigmaPH })],
        [s({ dT: -TEMPERATURE_SPREAD_C }), s({ dT: TEMPERATURE_SPREAD_C })],
        [s({ dPK: -pKSpread }), s({ dPK: pKSpread })],
        [s({ aScale: 1 - DAVIES_SPREAD }), s({ aScale: 1 + DAVIES_SPREAD })],
        [s({ cScale: 1 - relC }), s({ cScale: 1 + relC })],
    ]
}

// ========================================================================================
// 3. The rows of a template
// ========================================================================================

/**
 * What a template is worked out for.
 *
 * @property id - the template (`tris`, `pbs`, ...).
 * @property mM - the total concentration of a buffer, mM (a mixture has none).
 * @property sigmaMM - its uncertainty, mM (2 % when left out).
 * @property pH - the pH of the buffer; a mixture's own is used when left out.
 * @property sigmaPH - σ of the pH (0.1 when left out).
 * @property restIonicMM - the ionic strength of the rest of the recipe, mM (0 if left
 *     out).
 * @property cation - the cation of a base titrant (`sodium(1+)` when left out).
 * @property tempC - the temperature the pH was set at, °C (22 when left out).
 */
export type Recipe = {
    id: string
    mM?: number
    sigmaMM?: number
    pH?: number
    sigmaPH?: number
    restIonicMM?: number
    cation?: string
    tempC?: number
}

/**
 * A row to add to the solutes table.
 *
 * @property name - the name shown.
 * @property arg - the name in the bundled tables.
 * @property mM - the amount, mM.
 * @property sigmaMM - its uncertainty, mM.
 * @property custom - the snapshot of a custom solute: `arg` is then its name, not a name
 *     of the bundled tables.
 */
export type RowSpec = {
    name: string
    arg: string
    mM: number
    sigmaMM: number
    custom?: CustomSnapshot
}

/**
 * What a row stores of a custom non-biological solute (the snapshot a `custom-nonbio` row
 * of the buffer file holds), so that a template of such a solute is self-contained.
 *
 * @property z - its electrons.
 * @property pmv - its partial molar volume.
 * @property sigmaPmv - its uncertainty, `null` for the fallback.
 */
export type CustomSnapshot = { z: number; pmv: number; "sigmaPmv": number | null }

/**
 * What a template comes to.
 *
 * @property rows - the rows to add.
 * @property pH - the pH to set (the mixture's, or the one given).
 * @property sigmaPH - σ of that pH.
 * @property I - the ionic strength of the recipe, M.
 * @property converged - the ionic strength was solved (else the last value is used).
 * @property fractions - the share of each species of a buffer, most protonated first.
 * @property charges - their charges.
 * @property explain - the working in a few lines.
 * @property warnings - what to be careful of.
 */
export type Outcome = {
    rows: RowSpec[]
    pH: number
    sigmaPH: number
    // biome-ignore lint/style/useNamingConvention: ionic strength symbol
    I: number
    converged: boolean
    fractions?: number[]
    charges?: number[]
    explain: string[]
    warnings: string[]
}

/** The significant digits of a computed amount: more than the model knows. */
const DIGITS = 4

/** A computed amount with its digits cut to what is meaningful. */
const cut = (x: number): number => Number(x.toPrecision(DIGITS))

/**
 * A row with the arg of the bundled tables.
 *
 * @param name - the name of the solute.
 * @param mM - the amount, mM.
 * @param sigmaMM - its uncertainty, mM.
 * @param computed - the amounts come out of the numerics, so their digits are cut.
 * @returns the row.
 */
function rowOf(name: string, mM: number, sigmaMM: number, computed = false): RowSpec {
    const known = resolveBuiltin(name)
    const [m, s] = computed ? [cut(mM), cut(sigmaMM)] : [mM, sigmaMM]
    return { name: known?.name ?? name, arg: known?.target ?? name, mM: m, sigmaMM: s }
}

/** The base that brings a cation. */
const BASES: Readonly<Record<string, string>> = {
    "sodium(1+)": "NaOH (sodium)",
    "potassium(1+)": "KOH (potassium)",
}

/** A charge as `+1`, `0`, `-2`. */
const chargeText = (z: number): string => (z > 0 ? `+${z}` : `${z}`)

/**
 * The salt rows of a titrated polyprotic buffer: the species as the salts of the cation,
 * when the template has a name for every species that is present.
 *
 * @param t - the template.
 * @param cation - the cation of the counter-ion.
 * @param present - the indices of the species that are present.
 * @returns the names by species index, `undefined` when some species has no salt row.
 */
function saltNames(t: Template, cation: string, present: number[]): string[] | undefined {
    const key = cation.replace(/\(1\+\)$/, "")
    const names = t.saltRows?.[key]
    if (!names) return undefined
    return present.every((i) => names[i]) ? (names as string[]) : undefined
}

/**
 * The rows, and the amounts behind them, of one buffer.
 *
 * @param t - the buffer.
 * @param r - what it is worked out for (`mM`, `pH` and the rest are given).
 * @returns the rows, the ionic strength, the explanation and the warnings.
 */
function bufferOutcome(
    t: Template,
    r: { mM: number; sigmaMM: number; pH: number; sigmaPH: number; restI: number;
        cation: string; tempC: number },
): Omit<Outcome, "pH" | "sigmaPH"> {
    const groups = t.groups as Group[]
    const C = r.mM / 1000
    const relC = Math.min(r.sigmaMM / r.mM, 0.99)
    const spread = Math.max(PK_SPREAD, ...groups.map((g) => g.pKaSigma))
    const run = (s: Shifts) => speciate(groups, C, r.pH, r.restI, r.tempC, s)
    const centre = run(CENTRE)
    const shifted = sigmaShifts(r.sigmaPH, relC, spread).map(([lo, hi]) => [
        run(lo),
        run(hi),
    ])
    /** σ of a quantity of a run, mM: the half-differences in quadrature. */
    const sigma = (of: (s: Speciation) => number): number =>
        1000 *
        Math.sqrt(
            shifted.reduce((q, [lo, hi]) => q + ((of(hi) - of(lo)) / 2) ** 2, 0),
        )

    const present = centre.amounts
        .map((c, i) => [c, i] as const)
        .filter(([c]) => c > NEGLIGIBLE * C)
        .map(([, i]) => i)
    const rows: RowSpec[] = []
    const Q = centre.counter
    const anion = Q > 0
    const counterName = anion ? "chloride" : r.cation
    const counterMM = Math.abs(Q) * 1000
    const salts = !anion && t.speciesRows ? saltNames(t, r.cation, present) : undefined
    if (t.speciesRows) {
        const names = salts ?? t.speciesRows
        for (const i of present) {
            const amount = centre.amounts[i] * 1000
            rows.push(rowOf(names[i], amount, sigma((s) => s.amounts[i]), true))
        }
    } else {
        rows.push(rowOf(t.solute as string, r.mM, r.sigmaMM))
    }
    if (!salts && counterMM > NEGLIGIBLE * r.mM) {
        const counterSigma = sigma((s) => Math.abs(s.counter))
        rows.push(rowOf(counterName, counterMM, counterSigma, true))
    }

    const where = (g: Group) => pKAt(g, r.tempC)
    const names =
        t.speciesRows ?? centre.charges.map((z) => `${t.solute}(${chargeText(z)})`)
    const shares = present
        .map((i) => `${names[i]} ${((centre.amounts[i] / C) * 100).toFixed(1)} %`)
        .join(", ")
    const explain = [
        `${shortName(t)} ${r.mM} mM, pH ${r.pH} set at ${r.tempC} °C` +
            `, I = ${centre.I.toFixed(4)} M (Davies, A = ${DAVIES_A})`,
        `pK at ${r.tempC} °C: ${groups.map((g) => where(g).toFixed(3)).join(", ")}`,
        `species: ${shares}`,
        salts
            ? `counter-ion ${counterName}: in the salt rows (${counterMM.toFixed(3)} mM)`
            : `titrant: ${anion ? "HCl (chloride)" : BASES[r.cation] ?? r.cation}`,
    ]
    const warnings = bufferWarnings(t, r, groups, centre.I)
    if (!centre.converged) {
        warnings.push("the ionic strength did not converge: last value used")
    }
    return {
        rows,
        I: centre.I,
        converged: centre.converged,
        fractions: centre.amounts.map((c) => (C > 0 ? c / C : 0)),
        charges: centre.charges,
        explain,
        warnings,
    }
}

/**
 * What to be careful of for a buffer at a pH.
 *
 * @param t - the buffer.
 * @param r - the recipe (`pH`, `tempC`).
 * @param groups - the steps.
 * @param I - the ionic strength, M.
 * @returns the warnings, in short sentences.
 */
function bufferWarnings(
    t: Template,
    r: { pH: number; tempC: number },
    groups: Group[],
    I: number,
): string[] {
    const out: string[] = []
    const range = t.usablePh
    if (range && (r.pH < range[0] || r.pH > range[1])) {
        out.push(`pH ${r.pH} is outside the usable range ${rangeText(range)}`)
    }
    if (I > DAVIES_LIMIT_M) {
        out.push(`I = ${I.toFixed(2)} M is above ${DAVIES_LIMIT_M} M: Davies is unreliable`)
    }
    if (!t.verified) out.push(`${shortName(t)} ${UNVERIFIED_LABEL}`)
    if (groups.length > 1) {
        const pKs = groups.map((g) => pKAt(g, r.tempC))
        const gap = (i: number) => Math.abs(pKs[i] - r.pH)
        const near = pKs.reduce((b, _, i) => (gap(i) < gap(b) ? i : b), 0)
        // the main step is the one the template's own check is about
        const main = Math.max(0, groups.findIndex((g) => g.verified))
        if (near !== main) {
            const pK = pKs[near].toFixed(2)
            const step = `step ${near + 1} (pK ${pK})`
            out.push(`pH is nearest ${step}, not the main step ${main + 1}`)
        }
    }
    const noSlope = groups.findIndex(
        (g) => g.dHKjMol === null && g.dpKaDtPerK === null,
    )
    if (noSlope >= 0) out.push(`step ${noSlope + 1} has no temperature coefficient`)
    const loose = groups.find((g) => g.pKaSigma >= 0.1)
    if (loose) out.push(`pK uncertain by ±${loose.pKaSigma} (one study)`)
    return out
}

/**
 * The rows of a mixture: its components as listed, the buffers inside it worked out at
 * its pH, and the adjusting acid of PBS as chloride.
 *
 * @param t - the mixture.
 * @param r - the recipe (`pH`, `sigmaPH`, `restI`, `cation`, `tempC`).
 * @returns the rows, the ionic strength, the explanation and the warnings.
 */
function mixtureOutcome(
    t: Template,
    r: { pH: number; sigmaPH: number; restI: number; cation: string; tempC: number },
): Omit<Outcome, "pH" | "sigmaPH"> {
    const rows: RowSpec[] = (t.components ?? []).map((c) =>
        rowOf(c.solute, c.mM, c.sigmaMm),
    )
    const own = rows.reduce((s, c) => s + c.mM * ionicPerMM(c.arg), 0) / 1000
    const explain = [`${shortName(t)}: the recipe as listed, pH ${r.pH}`]
    const warnings: string[] = []
    let I = own + r.restI
    let converged = true
    for (const b of t.bufferComponents ?? []) {
        const buffer = templateById(b.template) as Template
        const inner = bufferOutcome(buffer, {
            mM: b.mM,
            sigmaMM: b.mM * DEFAULT_RELATIVE_SIGMA,
            pH: r.pH,
            sigmaPH: r.sigmaPH,
            restI: I,
            cation: r.cation,
            tempC: r.tempC,
        })
        rows.push(...inner.rows)
        explain.push(...inner.explain.slice(0, 1), ...inner.explain.slice(2))
        warnings.push(...inner.warnings)
        converged = converged && inner.converged
        I = inner.I
    }
    if (t.pHAdjust) {
        const m = t.pHAdjust.modelAmountMm
        rows.push(rowOf("chloride", m, m))
        const acid = t.pHAdjust.titrant
        explain.push(`adjusting to pH ${r.pH} with ${acid}: chloride ${m} mM`)
        warnings.push("the chloride of the pH adjustment is a model value (sigma 100 %)")
    }
    if (!t.verified) warnings.push(`${shortName(t)} ${UNVERIFIED_LABEL}`)
    return { rows, I, converged, explain, warnings }
}

/**
 * A template worked out for a pH and a concentration.
 *
 * @param recipe - see [[Recipe]].
 * @returns the rows to add, the pH to set, the ionic strength, the working and what to
 *     be careful of.
 * @throws RangeError for a template that is not in the asset or not offered, a buffer
 *     without a concentration, or a concentration that is not above 0.
 */
export function computeTemplate(recipe: Recipe): Outcome {
    const t = templateById(recipe.id)
    if (!t) throw new RangeError(`no buffer template ${recipe.id}`)
    if (t.available === false) throw new RangeError(`${t.id} is not available`)
    return computeWith(t, recipe)
}

/**
 * A template object (not necessarily one of the asset: `template-defs.ts` builds the
 * custom ones) worked out for a pH and a concentration; `computeTemplate` without the
 * lookup by id.
 *
 * @param t - the template.
 * @param recipe - see [[Recipe]] (`id` is not read).
 * @returns as `computeTemplate`.
 * @throws RangeError as `computeTemplate`, except for the lookup.
 */
export function computeWith(t: Template, recipe: Recipe): Outcome {
    const sigmaPH = recipe.sigmaPH ?? PH_SIGMA
    const common = {
        sigmaPH,
        restI: Math.max(0, recipe.restIonicMM ?? 0) / 1000,
        cation: recipe.cation ?? "sodium(1+)",
        tempC: recipe.tempC ?? SET_TEMPERATURE_C,
    }
    const wanted = recipe.pH ?? (t.kind === "mixture" ? (t.pH as number) : Number.NaN)
    if (!Number.isFinite(wanted)) throw new RangeError("a pH is needed")
    const pH = Math.min(PH_MAX, Math.max(PH_MIN, wanted))
    const clamped = pH === wanted ? [] : [`pH ${wanted} is outside 0 to 14: ${pH} used`]
    if (t.kind === "mixture") {
        const inner = mixtureOutcome(t, { ...common, pH })
        return { pH, sigmaPH, ...inner, warnings: [...clamped, ...inner.warnings] }
    }
    const mM = recipe.mM
    if (!(typeof mM === "number" && mM >= 0 && Number.isFinite(mM))) {
        throw new RangeError("a concentration is needed")
    }
    if (mM === 0) {
        const warnings = [...clamped, "concentration 0: nothing to add"]
        const I = common.restI
        return { rows: [], pH, sigmaPH, I, converged: true, explain: [], warnings }
    }
    const sigmaMM = recipe.sigmaMM ?? mM * DEFAULT_RELATIVE_SIGMA
    const inner = bufferOutcome(t, { ...common, mM, sigmaMM, pH })
    return { pH, sigmaPH, ...inner, warnings: [...clamped, ...inner.warnings] }
}

// ========================================================================================
// 4. The ionic strength of rows already in the table
// ========================================================================================

/** The ionic strength (M) of 1 M of simple salts and ions, by name in the table. */
const IONIC_PER_M: Readonly<Record<string, number>> = {
    "sodium chloride": 1,
    "potassium chloride": 1,
    "lithium chloride": 1,
    "caesium chloride": 1,
    "azanium chloride": 1,
    "sodium bromide": 1,
    "potassium bromide": 1,
    "sodium nitrate": 1,
    "sodium fluoride": 1,
    "sodium acetate": 1,
    "potassium acetate": 1,
    "sodium dihydrogen phosphate": 1,
    "potassium dihydrogen phosphate": 1,
    "magnesium dichloride": 3,
    "calcium dichloride": 3,
    "zinc dichloride": 3,
    "disodium sulfate": 3,
    "dipotassium sulfate": 3,
    "magnesium sulfate": 4,
    "disodium hydrogen phosphate": 3,
    "dipotassium hydrogen phosphate": 3,
    "bis(azanium) sulfate": 3,
    "sodium(1+)": 0.5,
    "potassium(1+)": 0.5,
    chloride: 0.5,
}

/**
 * The ionic strength a solute adds per mM, for the salts and ions the table can name
 * safely (a 1:1 salt 1, a 2:1 salt 3, a lone ion a half); 0 for anything else.
 *
 * @param arg - the name in the bundled tables.
 * @returns M per M of the solute, so mM per mM.
 */
export function ionicPerMM(arg: string): number {
    return IONIC_PER_M[arg.toLowerCase()] ?? 0
}

/**
 * The ionic strength of rows already in the table, for the prompt of the rest of the
 * recipe.
 *
 * @param rows - the rows (`arg`, `mM`).
 * @returns the sum, mM.
 */
export function restIonicStrength(
    rows: readonly { arg: string; mM: number | null }[],
): number {
    const sum = rows.reduce((s, r) => s + (r.mM ?? 0) * ionicPerMM(r.arg), 0)
    return Number(sum.toPrecision(6))
}
