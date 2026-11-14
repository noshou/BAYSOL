// SPDX-License-Identifier: LGPL-3.0-or-later

// The flow of a buffer template on the solutes table: which template, then the questions
// it needs (concentration, uncertainty, titrant, pH, the rest of the recipe), then the
// rows it comes to for confirming. Pure, like `add-flow.ts`: a screen draws the step and
// forwards what the user does. Nothing is changed before the confirmation: the result
// is the new drafts of the table (and the pH row), which the screen adopts.
//
// The rows are ordinary rows of the table. There is no link left between them and the
// template; picking the template again adds rows again, and where rows of the same
// names are there the flow asks whether they are replaced.

import { formatNumber, type NumberRules, parseNumber } from "../core/terminal.js"
import { type Conditions, conditionLimits } from "./buffer.js"
import {
    asksPH,
    computeTemplate,
    DEFAULT_RELATIVE_SIGMA,
    needsConcentration,
    type Outcome,
    offered,
    restIonicStrength,
    SET_TEMPERATURE_C,
    type Template,
    templateLine,
    titrantChoices,
} from "./buffer-templates.js"
import { type Drafts, MAX_ROWS } from "./lists.js"
import { parseTemperature } from "./run.js"
import {
    type ConcUnit,
    concUnit,
    formatConc,
    fromShown,
    type Solute,
    sameSoluteKey,
} from "./solutes.js"
import type { TemplateLink } from "./template-link.js"
import { setAtTemperature } from "./template-sync.js"

/** One choice of a dropdown step: what is shown. */
type TemplateChoice = { text: string; tag?: string }

/** The rows to confirm: the heading, what they come to and what the pH row does. */
export type ConfirmStep = {
    type: "confirm"
    title: string
    outcome: Outcome
    unit: ConcUnit
    phLine?: string
    problem?: string
}

/**
 * What the screen draws.
 *
 * - `pick`: the dropdown of the templates (type to find).
 * - `ion`: the dropdown of the titrants.
 * - `setat`: the dropdown of `pH set at` (buffer temperature, room, other).
 * - `prompt`: a one-line prompt, `label`, the text it starts with and a problem to show.
 * - `confirm`: the rows, the working and the warnings; Enter adds, Esc cancels.
 * - `replace`: the question whether rows of the same names are replaced.
 */
export type TemplateStep =
    | { type: "pick"; items: TemplateChoice[] }
    | { type: "ion"; items: TemplateChoice[] }
    | { type: "setat"; items: TemplateChoice[] }
    | { type: "prompt"; label: string; initial: string; problem?: string }
    | ConfirmStep
    | { type: "replace"; names: string[]; confirm: ConfirmStep }

/**
 * What the flow ended with.
 *
 * @property cancelled - nothing was changed.
 * @property drafts - the new drafts of the table.
 * @property conditions - the pH row to set, `undefined` for no change.
 * @property added - how many rows were added or replaced.
 */
export type TemplateDone = {
    cancelled: boolean
    drafts: Drafts<Solute>
    conditions?: Conditions
    added: number
}

/** What the flow starts from. */
export type TemplateStart = {
    drafts: Drafts<Solute>
    conditions: Conditions | undefined
    unit?: ConcUnit
}

/** The questions of a template, in order. */
type Ask = "conc" | "sigma" | "ion" | "pH" | "setat" | "setat-other" | "rest" | "confirm"

/** The outcome of a template that has no rows to show (a problem is shown instead). */
const NO_ROWS: Outcome = {
    rows: [],
    pH: 0,
    sigmaPH: 0,
    I: 0,
    converged: true,
    explain: [],
    warnings: [],
}

/** The conditions with the temperature of `held`, when it has one. */
function withTemperature(c: Conditions, held: Conditions | undefined): Conditions {
    return held?.temperature === undefined ? c : { ...c, temperature: held.temperature }
}

/** The room temperature (°C) of the `22 C (room)` choice: what the scripts assume. */
const ROOM_C = SET_TEMPERATURE_C

/** A number of 0 or more. */
const NOT_BELOW_ZERO: NumberRules = { atLeast: { limit: 0, message: "not below 0" } }

/** A positive number. */
const POSITIVE = (what: string): NumberRules => ({
    above: { limit: 0, message: `${what} must be > 0` },
})

/**
 * The flow. Create it with the table's drafts and pH, read `step`, and forward the
 * user's answers; `done` is set when it has ended.
 */
export class TemplateFlow {
    /** Set when the flow has ended (the screen adopts it). */
    done: TemplateDone | undefined

    private readonly start: TemplateStart
    private readonly unit: ConcUnit
    private template: Template | undefined
    private ask: Ask = "conc"
    private mM: number | undefined
    private sigmaMM: number | undefined
    private cation: string | undefined
    private pH: number | undefined
    private setAt: "buffer" | number = "buffer"
    private restI: number | undefined
    private problem: string | undefined
    private replacing = false

    /**
     * @param start - the table's drafts and pH row.
     */
    constructor(start: TemplateStart) {
        this.start = start
        this.unit = start.unit ?? concUnit()
    }

    /** @returns what to draw now. */
    get step(): TemplateStep {
        const t = this.template
        if (!t) {
            return {
                type: "pick",
                items: offered().map((x) => ({ text: templateLine(x) })),
            }
        }
        const problem = this.problem
        switch (this.ask) {
            case "conc": {
                const label = `concentration [${this.unit}]:`
                return { type: "prompt", label, initial: "", problem }
            }
            case "sigma": {
                const label = `uncertainty [${this.unit}]:`
                const sigma = (this.mM as number) * DEFAULT_RELATIVE_SIGMA
                const initial = formatConc(sigma, this.unit)
                return { type: "prompt", label, initial, problem }
            }
            case "ion":
                return {
                    type: "ion",
                    items: titrantChoices(t).map(([, text]) => ({ text })),
                }
            case "pH": {
                const given = this.start.conditions?.pH
                const initial = formatNumber(given ?? t.pH)
                return {
                    type: "prompt",
                    label: "pH:",
                    initial,
                    problem,
                }
            }
            case "setat": {
                const held = this.start.conditions?.temperature
                const buffer =
                    held === undefined
                        ? `buffer temperature (not set: ${SET_TEMPERATURE_C} °C)`
                        : `buffer temperature (${formatNumber(held)} °C)`
                return {
                    type: "setat",
                    items: [
                        { text: buffer },
                        { text: `${ROOM_C} °C (room)` },
                        { text: "other" },
                    ],
                }
            }
            case "setat-other":
                return {
                    type: "prompt",
                    label: "pH set at, temperature °C:",
                    initial: "",
                    problem,
                }
            case "rest": {
                const sum = restIonicStrength(this.live())
                return {
                    type: "prompt",
                    label: "rest of the recipe, ionic strength [mM]:",
                    initial: sum > 0 ? formatNumber(sum) : "",
                    problem,
                }
            }
            default:
                return this.replacing ? this.replaceStep() : this.confirmStep(t)
        }
    }

    /** The rows of the table that stay, as `arg` and `mM`. */
    private live(): { arg: string; mM: number | null }[] {
        return this.start.drafts.rows
            .filter((r) => !r.removed)
            .map((r) => {
                const s = (r.draft ?? r.saved) as Solute
                return { arg: s.arg, mM: s.mM }
            })
    }

    /** The outcome of the template for what was answered. */
    private outcome(t: Template): Outcome | string {
        try {
            return computeTemplate({
                id: t.id,
                mM: this.mM,
                sigmaMM: this.sigmaMM,
                pH: this.pH,
                sigmaPH: this.start.conditions?.sigmaPh,
                restIonicMM: this.restI,
                cation: this.cation,
                tempC: setAtTemperature(
                    { id: t.id, "setAt": this.setAt },
                    this.start.conditions?.temperature,
                ),
            })
        } catch (error) {
            return error instanceof Error ? error.message : String(error)
        }
    }

    /** The confirm step: the rows, or what is wrong with them. */
    private confirmStep(t: Template): ConfirmStep {
        const outcome = this.outcome(t)
        if (typeof outcome === "string") {
            return {
                type: "confirm",
                title: t.label,
                outcome: NO_ROWS,
                unit: this.unit,
                problem: outcome,
            }
        }
        const held = this.start.conditions?.pH
        const phLine =
            held === outcome.pH
                ? undefined
                : held === undefined
                    ? `sets the pH to ${outcome.pH}`
                    : `changes the pH ${held} to ${outcome.pH}`
        const clash = this.clash(outcome)
        const room = this.room(outcome)
        return {
            type: "confirm",
            title: this.title(t),
            outcome,
            unit: this.unit,
            phLine,
            problem: clash ?? (room ? undefined : `too many rows (${MAX_ROWS} at most)`),
        }
    }

    /** The heading of the confirm step: the template and what was typed. */
    private title(t: Template): string {
        if (this.mM === undefined) return t.id
        return `${t.id} ${formatConc(this.mM, this.unit)} ${this.unit}`
    }

    /** Whether the rows fit: new rows are added, same-named ones replace. */
    private room(outcome: Outcome): boolean {
        const fresh = outcome.rows.filter((r) => this.find(r) === undefined).length
        return this.start.drafts.length + fresh <= MAX_ROWS
    }

    /**
     * The index of the row of the table the row of the template replaces: a row that
     * was made by a template (it has a link) and is the same solute.
     */
    private find(row: { name: string; arg: string }): number | undefined {
        const i = this.same(row, true)
        return i < 0 ? undefined : i
    }

    /** The index of a row that stays and is the same solute, with or without a link. */
    private same(row: { name: string; arg: string }, linked: boolean): number {
        const key = sameSoluteKey({ ...row, kind: "nonbiological" } as Solute)
        return this.start.drafts.rows.findIndex((r) => {
            if (r.removed) return false
            const s = (r.draft ?? r.saved) as Solute
            const made = s.template !== undefined
            return made === linked && sameSoluteKey(s) === key
        })
    }

    /** The message when a row of a typed (unlinked) solute is the same solute. */
    private clash(outcome: Outcome): string | undefined {
        const row = outcome.rows.find((r) => this.same(r, false) >= 0)
        return row && `${row.name} already in the buffer: remove or edit it first`
    }

    /** The replace question. */
    private replaceStep(): TemplateStep {
        const confirm = this.confirmStep(this.template as Template)
        const names = confirm.outcome.rows
            .filter((r) => this.find(r) !== undefined)
            .map((r) => r.name)
        return { type: "replace", names, confirm }
    }

    /** The questions the template needs, in order, then the confirmation. */
    private sequence(t: Template): Ask[] {
        const out: Ask[] = []
        if (needsConcentration(t)) out.push("conc", "sigma")
        if (titrantChoices(t).length > 0) out.push("ion")
        if (asksPH(t)) out.push("pH", "setat")
        const inside = (t.bufferComponents?.length ?? 0) > 0
        if (needsConcentration(t) || inside) out.push("rest")
        out.push("confirm")
        return out
    }

    /** Keeps the question and says what is wrong with the answer. */
    private fail(problem: string): void {
        this.problem = problem
    }

    /** Moves to the next question. */
    private next(): void {
        const t = this.template as Template
        const order = this.sequence(t)
        const at = this.ask === "setat-other" ? "setat" : this.ask
        this.ask = order[order.indexOf(at) + 1] ?? "confirm"
        this.problem = undefined
    }

    /**
     * The user picked a template or a titrant.
     *
     * @param index - the index in the choices of the step shown.
     */
    pick(index: number): void {
        const t = this.template
        if (!t) {
            const chosen = offered()[index]
            if (!chosen) return
            this.template = chosen
            this.ask = this.sequence(chosen)[0]
            return
        }
        if (this.ask === "setat") {
            if (index === 2) {
                this.ask = "setat-other"
                this.problem = undefined
                return
            }
            this.setAt = index === 1 ? ROOM_C : "buffer"
            this.next()
            return
        }
        if (this.ask !== "ion") return
        this.cation = titrantChoices(t)[index]?.[0]
        this.next()
    }

    /**
     * The user typed an answer to a prompt and pressed Enter.
     *
     * @param text - what is in the field.
     */
    submit(text: string): void {
        if (!this.template) return
        switch (this.ask) {
            case "conc": {
                const n = parseNumber(text, POSITIVE(this.unit))
                if ("error" in n) {
                    this.fail(n.error)
                    return
                }
                this.mM = fromShown(n.value, this.unit)
                break
            }
            case "sigma": {
                const n = parseNumber(text, NOT_BELOW_ZERO)
                if ("error" in n) {
                    this.fail(n.error)
                    return
                }
                this.sigmaMM = fromShown(n.value, this.unit)
                break
            }
            case "pH": {
                const { pH } = conditionLimits()
                const range = `pH from ${pH.min} to ${pH.max}`
                const n = parseNumber(text, { atLeast: { limit: pH.min, message: range } })
                if ("error" in n || n.value > pH.max) {
                    this.fail("error" in n ? n.error : range)
                    return
                }
                this.pH = n.value
                break
            }
            case "setat-other": {
                const n = parseTemperature(text)
                if ("error" in n) {
                    this.fail(n.error)
                    return
                }
                this.setAt = n.value
                break
            }
            case "rest": {
                const n = parseNumber(text, { ...NOT_BELOW_ZERO, blank: true })
                if ("error" in n) {
                    this.fail(n.error)
                    return
                }
                this.restI = n.value ?? 0
                break
            }
            default:
                return
        }
        this.next()
    }

    /** Enter on the confirm step (and on the replace question): adds the rows. */
    accept(): void {
        const t = this.template
        if (!t || this.ask !== "confirm") return
        const step = this.confirmStep(t)
        if (step.problem) return
        if (!this.replacing && step.outcome.rows.some((r) => this.find(r) !== undefined)) {
            this.replacing = true
            return
        }
        this.finish(step.outcome)
    }

    /** Esc: back out of the flow, nothing changed. */
    cancel(): void {
        this.done = { cancelled: true, drafts: this.start.drafts, added: 0 }
    }

    /**
     * The link the rows get: what the template was made with, so that the rows follow the
     * pH. A mixture whose pH is fixed (PBS) has none.
     */
    private link(t: Template): TemplateLink | undefined {
        const rest = this.restI ?? 0
        if (t.kind === "mixture") {
            return (t.bufferComponents?.length ?? 0) > 0
                ? { id: t.id, "restMm": rest, "setAt": this.setAt }
                : undefined
        }
        const acid = t.defaultTitrant?.kind === "acid"
        const titrant = this.cation ?? (acid ? "chloride" : "sodium(1+)")
        return {
            id: t.id,
            mM: this.mM,
            "sigmaMm": this.sigmaMM,
            titrant,
            "restMm": rest,
            "setAt": this.setAt,
        }
    }

    /** Applies the rows to the drafts and ends. */
    private finish(outcome: Outcome): void {
        let drafts = this.start.drafts
        let added = 0
        const template = this.link(this.template as Template)
        for (const r of outcome.rows) {
            const i = this.find(r)
            const solute: Solute = {
                kind: "nonbiological",
                name: r.name,
                arg: r.arg,
                mM: r.mM,
                sigmaMM: r.sigmaMM,
                ...(template && { template }),
            }
            if (i === undefined) drafts = drafts.add(solute)
            else {
                const { template: _old, ...old } = drafts.value(i) as Solute
                drafts = drafts.set(i, { ...old, ...solute })
            }
            added++
        }
        const held = this.start.conditions
        const sigma = held?.sigmaPh ?? conditionLimits().sigmaPh.default
        const conditions =
            held?.pH === outcome.pH
                ? undefined
                : withTemperature({ pH: outcome.pH, "sigmaPh": sigma }, held)
        this.done = { cancelled: false, drafts, conditions, added }
    }
}
