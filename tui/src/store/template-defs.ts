// SPDX-License-Identifier: LGPL-3.0-or-later

// Definitions of a template: what a recipe that depends on the pH and the temperature
// carries inside it (`notes/templates-spec.md`, section B). Three kinds, all plain JSON:
//   builtin  a shipped buffer (`assets/data/buffer_templates.json`) at a concentration;
//   custom   the user's own buffer: 1 to 3 pKa steps, a titrant, run by the same engine;
//   table    amounts of each row at a few pHs, interpolated linearly in the pH.
// Pure: no screen, no file but the constants asset (through `buffer-templates.ts`).
// Nothing here throws: a validator returns a list of problems (empty when the definition
// is good), `rowsFor` returns `{ error }`, `normalizeDefinition` returns `undefined`.
//
// Contents:
//   1. Types and the limits
//   2. Reading unknown input: `normalizeDefinition`
//   3. Validators: `checkCustomDefinition`, `checkTableDefinition`, `checkDefinition`
//   4. The rows: `customToTemplate`, `tableRowsAt`, `rowsFor`

import {
    type CustomSnapshot,
    computeTemplate,
    computeWith,
    type Outcome,
    offered,
    type RowSpec,
    SET_TEMPERATURE_C,
    type Template,
    templateById,
} from "./buffer-templates.js"
import { resolveBuiltin } from "./solutes.js"

// ========================================================================================
// 1. Types and the limits
// ========================================================================================

/** What titrates a buffer: an acid (its anion) or a base (its cation). */
type TitrantDef = { kind: "acid" | "base"; ion: string }

/**
 * One acid-base step `A(zAcid) = H+ + B(zAcid - 1)`.
 *
 * @property pKa25 - the pK at 25 °C (thermodynamic, as the shipped constants are).
 * @property dpKaDT - d(pK)/dT per K; 0 when left out.
 * @property zAcid - the charge of the acid form of the step.
 */
type StepDef = { pKa25: number; dpKaDT?: number; zAcid: number }

/** A shipped buffer or mixture at a concentration. */
export type BuiltinDefinition = {
    kind: "builtin"
    id: string
    mM?: number
    sigmaMM?: number
    ion?: string
    pHSetAt?: number
    restMM?: number
}

/**
 * The user's own buffer.
 *
 * @property name - shown, 1 to 40 characters.
 * @property solute - a name of the bundled solute tables or of a custom solute.
 * @property soluteData - the snapshot of the custom solute (`solute` is not a bundled
 *     name then); left out for a bundled one.
 * @property steps - 1 to 3 steps, most protonated first.
 * @property titrant - what the pH was set with.
 * @property mM - the total concentration, mM.
 * @property sigmaMM - its uncertainty, mM.
 * @property pHSetAt - the temperature the pH was set at, °C (the buffer's when left out).
 * @property restMM - the ionic strength of the rest of the recipe, mM (0 when left out).
 */
export type CustomDefinition = {
    kind: "custom"
    name: string
    solute: string
    soluteData?: CustomSnapshot
    steps: StepDef[]
    titrant: TitrantDef
    mM: number
    sigmaMM: number
    pHSetAt?: number
    restMM?: number
}

/** A row of a table point; `custom` is a custom solute's snapshot (`arg` its name). */
type TableRowDef = {
    name: string
    arg: string
    mM: number
    sigmaMM: number
    custom?: CustomSnapshot
}

/** The amounts of every row at one pH. */
type TablePoint = { pH: number; rows: TableRowDef[] }

/** Amounts at a few pHs. */
export type TableDefinition = { kind: "table"; points: TablePoint[] }

/** Any definition. */
export type Definition = BuiltinDefinition | CustomDefinition | TableDefinition

/**
 * The conditions a definition is worked out at.
 *
 * @property pH - the buffer's pH.
 * @property sigmaPH - σ of the pH.
 * @property temperatureC - the buffer's temperature, °C.
 */
export type Conditions = { pH: number; sigmaPH: number; temperatureC: number }

/** What `rowsFor` gives: the engine's `Outcome` where the kind has one. */
type Extras = Partial<
    Pick<Outcome, "pH" | "sigmaPH" | "I" | "converged" | "fractions" | "charges">
>
export type RowsResult =
    | (Pick<Outcome, "rows" | "explain" | "warnings"> & Extras)
    | { error: string }

/** The limits of a definition (the wizard asks within the same ones). */
export const LIMITS = {
    pKaMin: -2,
    pKaMax: 16,
    chargeMin: -4,
    chargeMax: 4,
    maxSteps: 3,
    nameMax: 40,
    minPoints: 2,
    maxPoints: 12,
    maxRows: 60,
    pHMin: 0,
    pHMax: 14,
    tempMin: 0,
    tempMax: 100,
    /** the uncertainty of a pK the user typed: unsourced, so the spread is generous */
    customPKSigma: 0.05,
} as const

/** The text of the warning of a custom buffer. */
const UNSOURCED = "constants not sourced"

/** The digits kept of an interpolated amount. */
const INTERP_DIGITS = 10

// ========================================================================================
// 2. Reading unknown input
// ========================================================================================

/** A finite number. */
/** Whether a value is a finite number (the one test of the template files). */
export const isNum = (x: unknown): x is number =>
    typeof x === "number" && Number.isFinite(x)

/** A plain object. */
const isObj = (x: unknown): x is Record<string, unknown> =>
    typeof x === "object" && x !== null && !Array.isArray(x)

/** A string, trimmed; `undefined` for anything else. */
const text = (x: unknown): string | undefined =>
    typeof x === "string" ? x.trim() : undefined

/** `{ key: value }` when the value is a finite number, else nothing (for a spread). */
function num<K extends string>(key: K, x: unknown): { [P in K]?: number } {
    return isNum(x) ? ({ [key]: x } as { [P in K]: number }) : {}
}

/**
 * A step as it is stored: unknown keys dropped, `dpKaDT` only when it is a number.
 *
 * @param x - the raw step.
 * @returns the step, `undefined` when `pKa25` or `zAcid` is not a number.
 */
function normalizeStep(x: unknown): StepDef | undefined {
    if (!isObj(x) || !isNum(x.pKa25) || !isNum(x.zAcid)) return undefined
    return { pKa25: x.pKa25, ...num("dpKaDT", x.dpKaDT), zAcid: x.zAcid }
}

/**
 * A table row as it is stored (`name` defaults to `arg`).
 *
 * @param x - the raw row.
 * @returns the row, `undefined` when it is not an object with an `arg` and numbers.
 */
function normalizeRow(x: unknown): TableRowDef | undefined {
    if (!isObj(x)) return undefined
    const arg = text(x.arg)
    if (arg === undefined || !isNum(x.mM) || !isNum(x.sigmaMM)) return undefined
    const custom = normalizeSnapshot(x.custom)
    const row = { name: text(x.name) || arg, arg, mM: x.mM, sigmaMM: x.sigmaMM }
    return custom ? { ...row, custom } : row
}

/**
 * The snapshot of a custom solute as it is stored: only its three keys.
 *
 * @param x - the raw value.
 * @returns the snapshot, `undefined` for nothing or what is not one (`z` and `pmv`
 *     numbers; `sigma-pmv` a number, else `null`).
 */
function normalizeSnapshot(x: unknown): CustomSnapshot | undefined {
    if (!isObj(x) || !isNum(x.z) || !isNum(x.pmv)) return undefined
    const sigma = x["sigma-pmv"]
    return { z: x.z, pmv: x.pmv, "sigma-pmv": isNum(sigma) ? sigma : null }
}

/**
 * The problems of the snapshot of a custom solute: the loader's rules for a
 * `custom-nonbio` row (a whole `z` above 0; any volume, an ion's may be negative; an
 * uncertainty of 0 or more or `null`).
 *
 * @param s - the snapshot, `undefined` when there is none.
 * @param label - where it is, for the message.
 * @returns the problems.
 */
function snapshotProblems(s: CustomSnapshot | undefined, label: string): string[] {
    if (s === undefined) return [`${label} is not in the solute tables`]
    const out: string[] = []
    if (!Number.isInteger(s.z) || s.z <= 0) {
        out.push(`${label}: z must be a whole number above 0`)
    }
    const sigma = s["sigma-pmv"]
    if (sigma !== null && sigma < 0) {
        out.push(`${label}: the volume uncertainty is below 0`)
    }
    return out
}

/** The mapped items of an array, `undefined` when it is no array or an item fails. */
function allOf<T>(x: unknown, one: (item: unknown) => T | undefined): T[] | undefined {
    if (!Array.isArray(x)) return undefined
    const out: T[] = []
    for (const item of x) {
        const v = one(item)
        if (v === undefined) return undefined
        out.push(v)
    }
    return out
}

/**
 * Reads any value as a definition: only the known keys are kept, strings are trimmed, an
 * optional number of the wrong type is dropped. Values out of range are kept (the
 * validators name them); a wrong type where a value is required gives `undefined`.
 *
 * @param x - the raw value (a parsed JSON file, say).
 * @returns a clean definition, `undefined` when it is not one. Never throws.
 */
export function normalizeDefinition(x: unknown): Definition | undefined {
    if (!isObj(x)) return undefined
    if (x.kind === "builtin") {
        const id = text(x.id)
        if (!id) return undefined
        const ion = text(x.ion)
        return {
            kind: "builtin",
            id,
            ...num("mM", x.mM),
            ...num("sigmaMM", x.sigmaMM),
            ...(ion ? { ion } : {}),
            ...num("pHSetAt", x.pHSetAt),
            ...num("restMM", x.restMM),
        }
    }
    if (x.kind === "custom") {
        const steps = allOf(x.steps, normalizeStep)
        const t = x.titrant
        const kind = isObj(t) ? t.kind : undefined
        const ion = isObj(t) ? text(t.ion) : undefined
        const name = text(x.name)
        const solute = text(x.solute)
        const soluteData = normalizeSnapshot(x.soluteData)
        if (!steps || name === undefined || solute === undefined) return undefined
        if ((kind !== "acid" && kind !== "base") || ion === undefined) return undefined
        if (!isNum(x.mM) || !isNum(x.sigmaMM)) return undefined
        return {
            kind: "custom",
            name,
            solute,
            ...(soluteData ? { soluteData } : {}),
            steps,
            titrant: { kind, ion },
            mM: x.mM,
            sigmaMM: x.sigmaMM,
            ...num("pHSetAt", x.pHSetAt),
            ...num("restMM", x.restMM),
        }
    }
    if (x.kind === "table") {
        const points = allOf(x.points, (p): TablePoint | undefined => {
            if (!isObj(p) || !isNum(p.pH)) return undefined
            const rows = allOf(p.rows, normalizeRow)
            return rows ? { pH: p.pH, rows } : undefined
        })
        return points ? { kind: "table", points } : undefined
    }
    return undefined
}

// ========================================================================================
// 3. Validators
// ========================================================================================

/**
 * The ions a titrant may bring: the counter-ions the shipped buffers know.
 *
 * @returns `{ acid, base }`: the anions and the cations.
 */
export function titrantIons(): { acid: string[]; base: string[] } {
    const acid = new Set<string>()
    const base = new Set<string>()
    for (const t of offered()) {
        const rows = (t as { counter_ion_rows?: { cation?: string[]; anion?: string[] } })
            .counter_ion_rows
        for (const a of rows?.anion ?? []) acid.add(a)
        for (const c of rows?.cation ?? []) base.add(c)
    }
    return { acid: [...acid], base: [...base] }
}

/** The name of the key a row has in a table: the resolved bundled name, lower case. */
const rowKey = (arg: string): string =>
    (resolveBuiltin(arg)?.target ?? arg).trim().toLowerCase()

/**
 * The problems of an optional number: wrong type, or outside `[lo, hi]`.
 *
 * @param label - the field.
 * @param v - the value (`undefined` is fine).
 * @param lo - the least.
 * @param hi - the most (`Infinity` for none).
 * @returns the problems.
 */
function optionalRange(label: string, v: unknown, lo: number, hi: number): string[] {
    if (v === undefined) return []
    if (!isNum(v)) return [`${label} is not a number`]
    return v < lo || v > hi ? [`${label} ${v} is outside ${lo} to ${hi}`] : []
}

/**
 * The problems of the amount fields shared by builtin and custom definitions.
 *
 * @param d - the definition (any shape).
 * @param concentrationNeeded - `mM` must be there and above 0.
 * @returns the problems.
 */
function amountProblems(
    d: Record<string, unknown>,
    concentrationNeeded: boolean,
): string[] {
    const out: string[] = []
    if (d.mM === undefined && !concentrationNeeded) {
        // a mixture has no concentration
    } else if (!isNum(d.mM)) {
        out.push("concentration is not a number")
    } else if (!(d.mM > 0)) {
        out.push("concentration must be above 0")
    }
    if (d.sigmaMM === undefined && !concentrationNeeded) {
        // nothing
    } else if (!isNum(d.sigmaMM)) {
        out.push("sigma is not a number")
    } else if (d.sigmaMM < 0) {
        out.push("sigma must not be negative")
    }
    out.push(...optionalRange("pH set at", d.pHSetAt, LIMITS.tempMin, LIMITS.tempMax))
    out.push(...optionalRange("rest of the recipe", d.restMM, 0, Number.POSITIVE_INFINITY))
    return out
}

/**
 * The problems of the steps of a custom buffer.
 *
 * @param steps - the raw steps.
 * @returns the problems.
 */
function stepProblems(steps: unknown): string[] {
    if (!Array.isArray(steps) || steps.length < 1) return ["at least one step is needed"]
    const out: string[] = []
    if (steps.length > LIMITS.maxSteps) out.push(`at most ${LIMITS.maxSteps} steps`)
    const zs: number[] = []
    steps.forEach((s, i) => {
        const n = i + 1
        if (!isObj(s)) {
            out.push(`step ${n} is not a step`)
            return
        }
        if (!isNum(s.pKa25)) {
            out.push(`step ${n}: pKa is not a number`)
        } else if (s.pKa25 < LIMITS.pKaMin || s.pKa25 > LIMITS.pKaMax) {
            const range = `${LIMITS.pKaMin} to ${LIMITS.pKaMax}`
            out.push(`step ${n}: pKa ${s.pKa25} is outside ${range}`)
        }
        if (s.dpKaDT !== undefined && !isNum(s.dpKaDT)) {
            out.push(`step ${n}: dpKa/dT is not a number`)
        }
        const z = s.zAcid
        if (!isNum(z) || !Number.isInteger(z)) {
            out.push(`step ${n}: charge is not an integer`)
        } else if (z < LIMITS.chargeMin || z > LIMITS.chargeMax) {
            const range = `${LIMITS.chargeMin} to ${LIMITS.chargeMax}`
            out.push(`step ${n}: charge ${z} is outside ${range}`)
        } else {
            if (i > 0 && zs[i - 1] !== undefined && z !== zs[i - 1] - 1) {
                const want = zs[i - 1] - 1
                out.push(`step ${n}: charge ${z} must be ${want} (a step loses a proton)`)
            }
            if (z - 1 < LIMITS.chargeMin) {
                out.push(`step ${n}: the base form would have charge ${z - 1}`)
            }
        }
        zs[i] = isNum(z) ? z : Number.NaN
    })
    return out
}

/**
 * The problems of a custom buffer definition.
 *
 * @param def - the definition (any value).
 * @returns the problems, empty when the definition can be run. Never throws.
 */
export function checkCustomDefinition(def: unknown): string[] {
    if (!isObj(def) || def.kind !== "custom") return ["not a custom definition"]
    const out: string[] = []
    const name = text(def.name)
    if (name === undefined || name.length < 1 || name.length > LIMITS.nameMax) {
        out.push(`name must be 1 to ${LIMITS.nameMax} characters`)
    }
    const solute = text(def.solute)
    if (!solute) {
        out.push("a solute is needed")
    } else {
        // a name the bundled tables do not know is a custom solute: its snapshot is stored
        if (!resolveBuiltin(solute)) {
            const data = normalizeSnapshot(def.soluteData)
            out.push(...snapshotProblems(data, `solute ${solute}`))
        }
    }
    const stepsBad = stepProblems(def.steps)
    out.push(...stepsBad)
    out.push(...titrantProblems(def.titrant, def.steps, stepsBad.length === 0))
    out.push(...amountProblems(def, true))
    if (out.length === 0) out.push(...extremeProblems(def as unknown as CustomDefinition))
    return out
}

/**
 * The problems of the titrant: a known ion, and one the charges of the species can use
 * (the electroneutrality test of the extreme pHs: an acid is only used where the buffer
 * is positive, a base where it is negative).
 *
 * @param t - the raw titrant.
 * @param steps - the raw steps.
 * @param stepsGood - the steps are valid, so their charges can be read.
 * @returns the problems.
 */
function titrantProblems(t: unknown, steps: unknown, stepsGood: boolean): string[] {
    if (!isObj(t) || (t.kind !== "acid" && t.kind !== "base")) {
        return ["titrant must be an acid or a base"]
    }
    const ions = titrantIons()[t.kind]
    if (typeof t.ion !== "string" || !ions.includes(t.ion)) {
        return [`titrant ion must be one of ${ions.join(", ")}`]
    }
    if (!stepsGood) return []
    const list = steps as StepDef[]
    const top = list[0].zAcid
    const bottom = list[list.length - 1].zAcid - 1
    if (t.kind === "acid" && top <= 0) {
        return [`an acid titrant needs a positive acid form: charge ${top} at low pH`]
    }
    if (t.kind === "base" && bottom >= 0) {
        return [`a base titrant needs a negative base form: charge ${bottom} at high pH`]
    }
    return []
}

/**
 * The species of a custom buffer at pH 0 and 14 must come out finite and not negative.
 *
 * @param def - a definition that passed the other checks.
 * @returns the problems.
 */
function extremeProblems(def: CustomDefinition): string[] {
    const out: string[] = []
    for (const pH of [LIMITS.pHMin, LIMITS.pHMax]) {
        const r = runCustom(def, { pH, sigmaPH: 0.1, temperatureC: SET_TEMPERATURE_C })
        if ("error" in r) {
            out.push(`at pH ${pH}: ${r.error}`)
        } else if (!r.rows.every((x) => finite(x.mM) && finite(x.sigmaMM))) {
            out.push(`the amounts at pH ${pH} are not finite`)
        }
    }
    return out
}

/** A finite number that is not negative. */
const finite = (x: number): boolean => Number.isFinite(x) && x >= 0

/**
 * The problems of a table definition.
 *
 * @param def - the definition (any value).
 * @returns the problems, empty when it can be used. Never throws.
 */
export function checkTableDefinition(def: unknown): string[] {
    if (!isObj(def) || def.kind !== "table") return ["not a table definition"]
    const points = def.points
    if (!Array.isArray(points)) return ["points are missing"]
    const out: string[] = []
    if (points.length < LIMITS.minPoints) out.push(`at least ${LIMITS.minPoints} points`)
    if (points.length > LIMITS.maxPoints) out.push(`at most ${LIMITS.maxPoints} points`)
    let first: string[] | undefined
    let last = Number.NEGATIVE_INFINITY
    points.forEach((p, i) => {
        const n = i + 1
        if (!isObj(p)) {
            out.push(`point ${n} is not a point`)
            return
        }
        if (!isNum(p.pH)) {
            out.push(`point ${n}: pH is not a number`)
        } else if (p.pH < LIMITS.pHMin || p.pH > LIMITS.pHMax) {
            out.push(`point ${n}: pH ${p.pH} is outside ${LIMITS.pHMin} to ${LIMITS.pHMax}`)
        } else {
            if (p.pH <= last) out.push(`point ${n}: pH ${p.pH} must be above ${last}`)
            last = p.pH
        }
        const keys = rowsProblems(p.rows, n, out)
        if (keys === undefined) return
        if (first === undefined) {
            first = keys
        } else if (!sameSet(first, keys)) {
            out.push(`point ${n}: lists other rows than point 1`)
        }
    })
    return out
}

/**
 * The problems of the rows of one point; the keys of the rows when they can be compared.
 *
 * @param rows - the raw rows.
 * @param n - the point's number, for the messages.
 * @param out - the list the problems are added to.
 * @returns the resolved names of the rows, `undefined` when the rows are unusable.
 */
function rowsProblems(rows: unknown, n: number, out: string[]): string[] | undefined {
    if (!Array.isArray(rows)) {
        out.push(`point ${n}: rows are missing`)
        return undefined
    }
    if (rows.length < 1) out.push(`point ${n}: no rows`)
    if (rows.length > LIMITS.maxRows) out.push(`point ${n}: at most ${LIMITS.maxRows} rows`)
    const keys: string[] = []
    let usable = true
    rows.forEach((r, j) => {
        const at = `point ${n}, row ${j + 1}`
        if (!isObj(r)) {
            usable = false
            out.push(`${at} is not a row`)
            return
        }
        const arg = text(r.arg)
        if (!arg) {
            usable = false
            out.push(`${at}: a solute name is needed`)
        } else {
            const key = rowKey(arg)
            if (keys.includes(key)) out.push(`${at}: ${arg} is listed twice`)
            keys.push(key)
            if (!resolveBuiltin(arg)) {
                out.push(...snapshotProblems(normalizeSnapshot(r.custom), `${at}: ${arg}`))
            }
        }
        if (!isNum(r.mM)) out.push(`${at}: mM is not a number`)
        else if (r.mM < 0) out.push(`${at}: mM must not be negative`)
        if (!isNum(r.sigmaMM)) out.push(`${at}: sigma is not a number`)
        else if (r.sigmaMM < 0) out.push(`${at}: sigma must not be negative`)
    })
    return usable ? keys : undefined
}

/** The two lists hold the same elements. */
const sameSet = (a: readonly string[], b: readonly string[]): boolean =>
    a.length === b.length && a.every((x) => b.includes(x))

/**
 * The problems of a definition of any kind.
 *
 * @param def - the definition (any value).
 * @returns the problems, empty when it can be worked out. Never throws.
 */
export function checkDefinition(def: unknown): string[] {
    if (!isObj(def)) return ["not a definition"]
    if (def.kind === "custom") return checkCustomDefinition(def)
    if (def.kind === "table") return checkTableDefinition(def)
    if (def.kind !== "builtin") return ["unknown kind of definition"]
    const id = text(def.id)
    const t = id ? templateById(id) : undefined
    if (!t || t.available === false) return [`no buffer template ${String(def.id)}`]
    const out = amountProblems(def, t.kind === "buffer")
    if (def.ion !== undefined) {
        const cations = titrantIons().base
        if (typeof def.ion !== "string" || !cations.includes(def.ion)) {
            out.push(`ion must be one of ${cations.join(", ")}`)
        }
    }
    return out
}

// ========================================================================================
// 4. The rows
// ========================================================================================

/**
 * A custom definition as the engine's template: the same shape as a shipped buffer, not
 * verified, with the pK of each step linear in the temperature (`dpKaDT`).
 *
 * @param def - a valid definition (see [[checkCustomDefinition]]).
 * @returns the template; `computeWith` runs it.
 */
export function customToTemplate(def: CustomDefinition): Template {
    const pKs = def.steps.map((s) => s.pKa25)
    return {
        id: `custom:${def.name}`,
        label: def.name,
        kind: "buffer",
        verified: false,
        notes: UNSOURCED,
        groups: def.steps.map((s) => ({
            pKa25: s.pKa25,
            pKa_sigma: LIMITS.customPKSigma,
            dpKa_dT_per_K: s.dpKaDT ?? 0,
            dH_kJ_mol: null,
            dCp_J_K_mol: null,
            z_acid: s.zAcid,
            z_base: s.zAcid - 1,
            verified: false,
        })),
        usable_pH: [Math.min(...pKs) - 1, Math.max(...pKs) + 1],
        default_titrant: { kind: def.titrant.kind, ion: def.titrant.ion },
        solute: resolveBuiltin(def.solute)?.name ?? def.solute,
    }
}

/**
 * The amounts of a table at a pH: the linear interpolation of mM and σ between the two
 * points that bracket it, exact at a point.
 *
 * @param def - the definition (checked here).
 * @param pH - the pH.
 * @returns the rows, or `{ error }` for an invalid definition, a pH that is not a number
 *     or lies outside the first and the last point (nothing is extrapolated). Never throws.
 */
export function tableRowsAt(
    def: unknown,
    pH: number,
): { rows: RowSpec[]; between: [number, number] } | { error: string } {
    const problems = checkTableDefinition(def)
    if (problems.length > 0) return { error: `invalid table: ${problems[0]}` }
    if (!isNum(pH)) return { error: "the pH is not a number" }
    const points = (def as TableDefinition).points
    const lo = points[0].pH
    const hi = points[points.length - 1].pH
    if (pH < lo || pH > hi) {
        return { error: `pH ${pH} is outside the table's ${lo} to ${hi}` }
    }
    let i = 0
    while (i < points.length - 2 && pH > points[i + 1].pH) i++
    const a = points[i]
    const b = points[i + 1]
    const f = (pH - a.pH) / (b.pH - a.pH)
    const lerp = (x: number, y: number): number =>
        Number((x + (y - x) * f).toPrecision(INTERP_DIGITS))
    const at = (x: number, y: number): number =>
        pH === a.pH ? x : pH === b.pH ? y : lerp(x, y)
    const rows = a.rows.map((r): RowSpec => {
        const other = b.rows.find((o) => rowKey(o.arg) === rowKey(r.arg)) as TableRowDef
        return {
            name: r.name,
            arg: r.arg,
            mM: at(r.mM, other.mM),
            sigmaMM: at(r.sigmaMM, other.sigmaMM),
            ...(r.custom ? { custom: r.custom } : {}),
        }
    })
    return { rows, between: [a.pH, b.pH] }
}

/**
 * A custom definition worked out by the engine.
 *
 * @param def - the definition.
 * @param c - the conditions.
 * @returns the engine's outcome with the unsourced warning, or `{ error }`.
 */
function runCustom(def: CustomDefinition, c: Conditions): RowsResult {
    try {
        const out = computeWith(customToTemplate(def), {
            id: `custom:${def.name}`,
            mM: def.mM,
            sigmaMM: def.sigmaMM,
            pH: c.pH,
            sigmaPH: c.sigmaPH,
            restI_mM: def.restMM ?? 0,
            ...(def.titrant.kind === "base" ? { cation: def.titrant.ion } : {}),
            tempC: def.pHSetAt ?? c.temperatureC,
        })
        // the engine's own "not cross-checked" line says less than this one
        const warnings = out.warnings.filter(
            (w) => !w.endsWith("(constants not cross-checked)"),
        )
        // the row of a custom solute carries its snapshot
        const data = resolveBuiltin(def.solute) ? undefined : def.soluteData
        const mine = (r: RowSpec) => rowKey(r.arg) === rowKey(def.solute)
        const rows = data
            ? out.rows.map((r) => (mine(r) ? { ...r, custom: data } : r))
            : out.rows
        return { ...out, rows, warnings: [UNSOURCED, ...warnings] }
    } catch (e) {
        return { error: e instanceof Error ? e.message : String(e) }
    }
}

/**
 * The rows of a definition at the buffer's conditions.
 *
 * @param definition - a definition of any kind (checked here).
 * @param conditions - the pH, its σ and the temperature.
 * @returns `{ rows, explain, warnings }` (and, where the engine gives them, `pH`, `I`,
 *     `fractions`, `charges`), or `{ error }`. Never throws.
 */
export function rowsFor(definition: unknown, conditions: Conditions): RowsResult {
    const def = normalizeDefinition(definition)
    if (!def) return { error: "not a definition" }
    const problems = checkDefinition(def)
    if (problems.length > 0) return { error: problems[0] }
    const { pH, sigmaPH, temperatureC } = conditions ?? {}
    if (!isNum(pH) || !isNum(sigmaPH) || !isNum(temperatureC)) {
        return { error: "the pH, its sigma and the temperature must be numbers" }
    }
    if (def.kind === "table") {
        const r = tableRowsAt(def, pH)
        if ("error" in r) return r
        const [a, b] = r.between
        const on = pH === a || pH === b
        const how = on ? "the point" : `interpolated between ${a} and ${b}`
        return { rows: r.rows, pH, explain: [`table at pH ${pH}: ${how}`], warnings: [] }
    }
    if (def.kind === "custom") return runCustom(def, conditions)
    try {
        const t = templateById(def.id) as Template
        const asksPH = t.kind === "buffer" || (t.buffer_components?.length ?? 0) > 0
        return computeTemplate({
            id: def.id,
            ...(def.mM === undefined ? {} : { mM: def.mM }),
            ...(def.sigmaMM === undefined ? {} : { sigmaMM: def.sigmaMM }),
            ...(asksPH ? { pH } : {}),
            sigmaPH,
            restI_mM: def.restMM ?? 0,
            ...(def.ion ? { cation: def.ion } : {}),
            tempC: def.pHSetAt ?? temperatureC,
        })
    } catch (e) {
        return { error: e instanceof Error ? e.message : String(e) }
    }
}
