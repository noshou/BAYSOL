// SPDX-License-Identifier: LGPL-3.0-or-later

// The questions that make a template definition (`template-defs.ts`): the kind (a shipped
// buffer, the user's own buffer, a table of amounts), then what that kind needs. Pure,
// like `template-flow.ts`: a screen draws the step and forwards the answer. The questions
// are written once as a generator (`script`): each answer is checked where it is asked
// and a bad one asks again with the problem; the definition is checked as a whole at the
// end. Concentrations are in mM, as the files hold them. A solute may be a bundled one or
// one of the user's custom solutes (its snapshot goes into the definition); the questions
// can start from a definition (the edit of a template: every prompt is prefilled) or from
// the first point of a table (the conversion of the rows of a buffer).

import { fold, formatNumber } from "../core/terminal.js"
import {
    type CustomSnapshot,
    DEFAULT_RELATIVE_SIGMA,
    needsConcentration,
    offered,
    type Template,
    templateById,
    templateLine,
    titrantChoices,
} from "./buffer-templates.js"
import type { NonbioEntry } from "./custom.js"
import { resolveBuiltin } from "./solutes.js"
import {
    type BuiltinDefinition,
    type CustomDefinition,
    checkDefinition,
    type Definition,
    LIMITS,
    rowsFor,
    type TableDefinition,
    titrantIons,
} from "./template-defs.js"

/**
 * What the screen draws: a dropdown of `items` (answered by [[TemplateWizard.pick]]) or a
 * one-line prompt (answered by [[TemplateWizard.submit]]), with the problem of the last
 * answer, if any. A dropdown's `initial` is the text typed in it (the choice to start on).
 */
export type WizardStep =
    | { type: "choice"; label: string; items: string[]; initial?: string; problem?: string }
    | { type: "prompt"; label: string; initial: string; problem?: string }

/** How the wizard ended: the definition, or nothing for a cancel. */
export type WizardDone = { definition: Definition } | { cancelled: true }

/** An answer: the index of a choice or the text of a prompt. */
type Answer = number | string

/** The kinds the first question offers, in order. */
const KINDS = [
    ["builtin", "ready-made buffer (Tris, HEPES, PBS ...): amounts computed from the pH"],
    [
        "custom",
        "my own buffer (I give pKa values and a titrant): amounts computed from the pH",
    ],
    ["table", "my own amounts (mM of each solute at a few pH): in between is interpolated"],
] as const

/** The pH a custom or table definition is tried at before it is accepted: mid range. */
const TRY_PH = 7

/** The temperature it is tried at, °C. */
const TRY_TEMPERATURE = 25

/** What a parse gives. */
type Parse<T> = { value: T } | { error: string }

/** A finite number from text, within limits. */
function number(
    text: string,
    what: string,
    min = Number.NEGATIVE_INFINITY,
    max = Number.POSITIVE_INFINITY,
): Parse<number> {
    const t = text.trim()
    const x = t === "" ? Number.NaN : Number(t)
    if (!Number.isFinite(x)) return { error: `${what}: type a number` }
    if (x < min || x > max) {
        const open = max === Number.POSITIVE_INFINITY
        const range = open ? `${min} or more` : `${min} to ${max}`
        return { error: `${what}: ${range}` }
    }
    return { value: x }
}

/** A whole number from text, within limits. */
function whole(text: string, what: string, min: number, max: number): Parse<number> {
    const n = number(text, what, min, max)
    return "value" in n && !Number.isInteger(n.value)
        ? { error: `${what}: a whole number` }
        : n
}

/** Asks a prompt until `parse` accepts the text. */
function* promptFor<T>(
    label: string,
    initial: string,
    parse: (text: string) => Parse<T>,
): Generator<WizardStep, T, Answer> {
    let problem: string | undefined
    for (;;) {
        const text = (yield { type: "prompt", label, initial, problem }) as string
        const parsed = parse(text)
        if ("value" in parsed) return parsed.value
        problem = parsed.error
    }
}

/** Asks a dropdown; the answer is the index. `initial` is the text typed in it. */
function* choiceFor(
    label: string,
    items: string[],
    initial?: string,
): Generator<WizardStep, number, Answer> {
    return (yield { type: "choice", label, items, initial }) as number
}

/** A prompt for a number. */
function numberPrompt(
    label: string,
    initial: string,
    min?: number,
    max?: number,
): Generator<WizardStep, number, Answer> {
    return promptFor(label, initial, (text) => number(text, label, min, max))
}

/** The prompt of an optional number: blank is `undefined`. */
function optionalPrompt(
    label: string,
    min: number,
    max?: number,
    initial = "",
): Generator<WizardStep, number | undefined, Answer> {
    return promptFor<number | undefined>(label, initial, (text) =>
        text.trim() === "" ? { value: undefined } : number(text, label, min, max),
    )
}

/** A number as the text of a prompt, `""` for none. */
const shown = (x: number | undefined): string => (x === undefined ? "" : formatNumber(x))

/** The label of the `pH set at` question. */
const SET_AT_LABEL = "pH set at, °C (blank: the buffer's):"

/** A solute the user named: the bundled name, or a custom solute with its snapshot. */
type Resolved = { name: string; arg: string; custom?: CustomSnapshot }

/** The custom solutes the wizard may name, by folded name. */
type Pool = Map<string, Resolved>

/**
 * The solute a text names.
 *
 * @param text - what was typed.
 * @param pool - the custom solutes the wizard knows.
 * @returns the bundled solute of that name, else the custom solute, else an error.
 */
function resolveSolute(text: string, pool: Pool): Parse<Resolved> {
    const typed = text.trim()
    const found = resolveBuiltin(typed)
    if (found) return { value: { name: found.name, arg: found.name } }
    const custom = pool.get(fold(typed))
    return custom ? { value: custom } : { error: `${typed}: not a solute` }
}

/**
 * The custom solutes of a wizard: the complete non-biological entries of the user's
 * file, and (as a fallback, so a solute deleted since stays usable) the snapshots a
 * definition being edited already holds.
 *
 * @param customs - the entries of the custom solutes file.
 * @param initial - the definition being edited, if any.
 * @returns the pool.
 */
function poolOf(customs: readonly NonbioEntry[], initial?: Definition): Pool {
    const pool: Pool = new Map()
    const keep = (name: string, custom: CustomSnapshot | undefined) => {
        if (custom) pool.set(fold(name), { name, arg: name, custom })
    }
    if (initial?.kind === "custom") keep(initial.solute, initial.soluteData)
    if (initial?.kind === "table") {
        for (const point of initial.points) {
            for (const r of point.rows) keep(r.arg, r.custom)
        }
    }
    for (const e of customs) {
        const { z, pmv } = e
        if (z === null || pmv === null) continue
        keep(e.name, { z, pmv, "sigma-pmv": e.sigma })
    }
    return pool
}

/** The last two questions of a buffer definition: where its pH is set, the rest. */
function* conditionsTail(
    def: BuiltinDefinition | CustomDefinition,
    prev?: BuiltinDefinition | CustomDefinition,
): Generator<WizardStep, void, Answer> {
    const initial = shown(prev?.pHSetAt)
    const at = yield* optionalPrompt(SET_AT_LABEL, LIMITS.tempMin, LIMITS.tempMax, initial)
    if (at !== undefined) def.pHSetAt = at
    const label = "rest of the recipe, ionic strength [mM]:"
    const rest = yield* optionalPrompt(label, 0, undefined, shown(prev?.restMM))
    if (rest !== undefined) def.restMM = rest
}

/** The questions of a shipped buffer. */
function* builtin(
    prev?: BuiltinDefinition,
): Generator<WizardStep, BuiltinDefinition, Answer> {
    const list: Template[] = offered()
    const before = prev && templateById(prev.id)
    const lines = list.map(templateLine)
    const start = before ? templateLine(before) : undefined
    const t = list[yield* choiceFor("buffer template:", lines, start)] as Template
    const same = prev?.id === t.id ? prev : undefined
    const def: BuiltinDefinition = { kind: "builtin", id: t.id }
    if (needsConcentration(t)) {
        def.mM = yield* numberPrompt("concentration [mM]:", shown(same?.mM), 0)
        const sigma = same?.sigmaMM ?? def.mM * DEFAULT_RELATIVE_SIGMA
        def.sigmaMM = yield* numberPrompt("uncertainty [mM]:", formatNumber(sigma), 0)
    }
    const ions = titrantChoices(t)
    if (ions.length > 1) {
        const labels = ions.map(([, text]) => text)
        const start = ions.find(([ion]) => ion === same?.ion)?.[1]
        const [ion] = ions[yield* choiceFor("titrant:", labels, start)] as [string, string]
        def.ion = ion
    }
    yield* conditionsTail(def, same)
    return def
}

/** The two kinds of titrant as the dropdown words them. */
const TITRANT_KINDS = ["an acid (anion)", "a base (cation)"] as const

/** The questions of the user's own buffer. */
function* custom(
    name: string,
    pool: Pool,
    prev?: CustomDefinition,
): Generator<WizardStep, CustomDefinition, Answer> {
    const solute = yield* promptFor<Resolved>(
        "solute (name in the tables):",
        prev?.solute ?? "",
        (text) => resolveSolute(text, pool),
    )
    const count = yield* promptFor(
        `pKa steps (1 to ${LIMITS.maxSteps}):`,
        String(prev?.steps.length ?? 1),
        (text) => whole(text, "steps", 1, LIMITS.maxSteps),
    )
    const steps: { pKa25: number; dpKaDT?: number; zAcid: number }[] = []
    for (let i = 1; i <= count; i++) {
        const old = prev?.steps[i - 1]
        const pKa25 = yield* numberPrompt(
            `step ${i}: pKa at 25 °C:`,
            shown(old?.pKa25),
            LIMITS.pKaMin,
            LIMITS.pKaMax,
        )
        const slope = yield* optionalPrompt(
            `step ${i}: dpKa/dT per K (blank: 0):`,
            -1,
            1,
            shown(old?.dpKaDT),
        )
        const previous = steps[steps.length - 1]
        const guess = previous === undefined ? "" : String(previous.zAcid - 1)
        const zAcid = yield* promptFor(
            `step ${i}: charge of the acid form:`,
            old === undefined ? guess : String(old.zAcid),
            (text) => whole(text, "charge", LIMITS.chargeMin, LIMITS.chargeMax),
        )
        steps.push({ pKa25, ...(slope === undefined ? {} : { dpKaDT: slope }), zAcid })
    }
    const start = prev && TITRANT_KINDS[prev.titrant.kind === "acid" ? 0 : 1]
    const kind = yield* choiceFor("titrated with:", [...TITRANT_KINDS], start)
    const which = kind === 0 ? "acid" : "base"
    const ions = titrantIons()[which]
    const sameKind = prev?.titrant.kind === which
    const ion = ions[
        yield* choiceFor("titrant ion:", ions, sameKind ? prev?.titrant.ion : undefined)
    ] as string
    const mM = yield* numberPrompt("concentration [mM]:", shown(prev?.mM), 0)
    const sigmaMM = yield* numberPrompt(
        "uncertainty [mM]:",
        formatNumber(prev?.sigmaMM ?? mM * DEFAULT_RELATIVE_SIGMA),
        0,
    )
    const def: CustomDefinition = {
        kind: "custom",
        name,
        solute: solute.name,
        ...(solute.custom ? { soluteData: solute.custom } : {}),
        steps,
        titrant: { kind: which, ion },
        mM,
        sigmaMM,
    }
    yield* conditionsTail(def, prev)
    return def
}

/** A row of a table point: the solute, its amount and uncertainty. */
export type PointRow = Resolved & { mM: number; sigmaMM: number }

/** The first point of a table made from rows that exist (see [[WizardOptions]]). */
export type TableSeed = { pH: number; rows: PointRow[] }

/** The amounts `MM σ` of a table row: the two numbers, in mM. */
function amounts(text: string): Parse<{ mM: number; sigmaMM: number }> {
    const words = text.trim().split(/\s+/)
    if (words.length !== 2) return { error: "type: amount [mM], uncertainty [mM]" }
    const sigma = number(words[1] as string, "uncertainty", 0)
    const mM = number(words[0] as string, "amount", 0)
    if ("error" in sigma) return sigma
    if ("error" in mM) return mM
    return { value: { mM: mM.value, sigmaMM: sigma.value } }
}

/** The text `SOLUTE mM σ` of a table row: the last two words are the numbers. */
function tableRow(text: string, pool: Pool): Parse<PointRow> {
    const words = text.trim().split(/\s+/)
    if (words.length < 3) return { error: "type: solute, amount [mM], uncertainty [mM]" }
    const numbers = amounts(words.splice(-2).join(" "))
    if ("error" in numbers) return numbers
    const solute = resolveSolute(words.join(" "), pool)
    if ("error" in solute) return solute
    return { value: { ...solute.value, ...numbers.value } }
}

/** The amounts of a row as the text of its prompt. */
const amountsText = (r: { mM: number; sigmaMM: number }): string =>
    `${formatNumber(r.mM)} ${formatNumber(r.sigmaMM)}`

/** A table row as the text of its prompt. */
const rowText = (r: { arg: string; mM: number; sigmaMM: number }): string =>
    `${r.arg} ${amountsText(r)}`

/** The questions of a table: points of pH, each with the same rows. */
function* table(
    pool: Pool,
    prev?: TableDefinition,
    seed?: TableSeed,
): Generator<WizardStep, Definition, Answer> {
    const points: { pH: number; rows: PointRow[] }[] = seed ? [seed] : []
    while (points.length < LIMITS.maxPoints) {
        const n = points.length + 1
        const last = points[points.length - 1]
        const old = prev?.points[n - 1]
        const pH = yield* promptFor<number | undefined>(
            `pH of point ${n}${n > 2 ? " (blank: done)" : ""}:`,
            shown(old?.pH),
            (text) => {
                if (text.trim() === "" && n > 2) return { value: undefined }
                const x = number(text, "pH", LIMITS.pHMin, LIMITS.pHMax)
                if ("value" in x && last !== undefined && x.value <= last.pH) {
                    return { error: `pH must be above ${last.pH}` }
                }
                return x
            },
        )
        if (pH === undefined) break
        const rows: PointRow[] = []
        if (last === undefined) {
            // the first point names the rows; blank ends them
            for (;;) {
                const before = old?.rows[rows.length]
                const row = yield* promptFor<PointRow | undefined>(
                    `point 1, row ${rows.length + 1}: solute mM σ (blank: done)`,
                    before ? rowText(before) : "",
                    (t) => {
                        if (t.trim() === "" && rows.length > 0) return { value: undefined }
                        return tableRow(t, pool)
                    },
                )
                if (row === undefined) break
                rows.push(row)
            }
        } else {
            // every later point has the same rows
            for (const first of points[0]?.rows ?? []) {
                const label = `point ${n}: ${first.arg}: mM σ`
                const same = old?.rows.find((r) => fold(r.arg) === fold(first.arg))
                const initial = same ? amountsText(same) : ""
                const got = yield* promptFor(label, initial, amounts)
                rows.push({ ...first, ...got })
            }
        }
        points.push({ pH, rows })
    }
    return {
        kind: "table",
        points: points.map((p) => ({
            pH: p.pH,
            rows: p.rows.map((r) => ({
                name: r.name,
                arg: r.arg,
                mM: r.mM,
                sigmaMM: r.sigmaMM,
                ...(r.custom ? { custom: r.custom } : {}),
            })),
        })),
    }
}

/** What the wizard may start from. */
export type WizardOptions = {
    /** The user's custom solutes (the entries of their file). */
    customs?: readonly NonbioEntry[]
    /** A definition to edit: every question starts from its values. */
    initial?: Definition
    /** The first point of a table made from rows that exist: the kind is not asked. */
    seed?: TableSeed
}

/** Everything asked, as one script that ends with the definition. */
function* script(
    name: string,
    options: WizardOptions,
): Generator<WizardStep, Definition, Answer> {
    const { initial, seed } = options
    const pool = poolOf(options.customs ?? [], initial)
    if (seed) return yield* table(pool, undefined, seed)
    const texts = KINDS.map(([, text]) => text)
    const start = initial && KINDS.find(([which]) => which === initial.kind)?.[1]
    const kind = KINDS[yield* choiceFor("how do the rows follow the pH?", texts, start)]
    const [which] = kind as readonly [string, string]
    const same = (k: Definition["kind"]) => (initial?.kind === k ? initial : undefined)
    if (which === "builtin") return yield* builtin(same("builtin") as BuiltinDefinition)
    if (which === "custom") {
        return yield* custom(name, pool, same("custom") as CustomDefinition | undefined)
    }
    return yield* table(pool, same("table") as TableDefinition | undefined)
}

/**
 * The first problem of a definition made by the wizard, or `undefined`: the validators of
 * `template-defs.ts`, and a trial of the rows at a middle pH (a table at the first of its
 * points), so that what cannot be worked out is told before it is saved.
 *
 * @param def - the definition.
 * @returns the problem text.
 */
function wizardProblem(def: Definition): string | undefined {
    const problems = checkDefinition(def)
    if (problems.length > 0) return problems[0]
    const pH = def.kind === "table" ? (def.points[0]?.pH ?? TRY_PH) : TRY_PH
    const made = rowsFor(def, { pH, sigmaPH: 0.1, temperatureC: TRY_TEMPERATURE })
    return "error" in made ? made.error : undefined
}

/**
 * The wizard that makes a definition. It asks, one step at a time; the screen shows
 * [[step]] and calls [[pick]], [[submit]] or [[cancel]] until [[done]] is set.
 */
export class TemplateWizard {
    /** Set when the wizard has ended. */
    done: WizardDone | undefined

    /** The problem of the whole definition, shown at the last step it came from. */
    problem: string | undefined

    private readonly name: string
    private readonly generator: Generator<WizardStep, Definition, Answer>
    private current: WizardStep

    /**
     * @param name - the name of the template (a custom buffer carries it).
     * @param options - what to start from, see [[WizardOptions]].
     */
    constructor(name: string, options: WizardOptions = {}) {
        this.name = name.trim().slice(0, 40)
        this.generator = script(this.name, options)
        this.current = this.generator.next().value as WizardStep
    }

    /** @returns what to draw now. */
    get step(): WizardStep {
        return this.current
    }

    /** Takes the answer of a dropdown. */
    pick(index: number): void {
        this.answer(index)
    }

    /** Takes the answer of a prompt. */
    submit(text: string): void {
        this.answer(text)
    }

    /** Gives the wizard up. */
    cancel(): void {
        this.generator.return({ kind: "table", points: [] })
        this.done = { cancelled: true }
    }

    private answer(value: Answer): void {
        const next = this.generator.next(value)
        if (next.done) {
            const problem = wizardProblem(next.value)
            if (problem !== undefined) {
                this.problem = problem
                this.done = { cancelled: true }
            } else this.done = { definition: next.value }
            return
        }
        this.current = next.value
    }
}
