// SPDX-License-Identifier: LGPL-3.0-or-later

// The questions that make a template definition (`store/template-wizard.ts`), drawn: a
// dropdown or a prompt under a table, one step at a time. The recipes table and the
// solutes table both use it; each hands over what to do with the definition.

import { type ReactNode, useCallback, useRef, useState } from "react"
import { appDir } from "../core/environment.js"
import { type NonbioEntry, readCustomSolutes } from "../store/custom.js"
import type { Definition } from "../store/template-defs.js"
import { TemplateWizard, type WizardOptions } from "../store/template-wizard.js"
import type { LegendItem } from "../ui/grid.js"
import {
    DROPDOWN_CHROME,
    Dropdown,
    filterChoices,
    PROMPT_ROWS,
    Prompt,
    suggestionLines,
} from "../ui/input.js"

/**
 * What a step machine (`TemplateFlow`, `TemplateWizard`) needs to be driven by a screen:
 * the machine in a ref, a redraw after every answer, the legend of the step on show and
 * the end of the machine handed over once.
 *
 * @property current - the machine while it runs, `undefined` when none does.
 * @property legend - the keys of the open step, as the step's input reports them.
 * @property setLegend - what the step's input calls with them.
 * @property begin - runs a machine.
 * @property forward - gives the machine an answer (`act`); if that ends it, `onSettle`
 *     gets it and it is let go; the screen is redrawn.
 */
export type Stepper<M> = {
    current: M | undefined
    legend: LegendItem[]
    setLegend: (legend: LegendItem[]) => void
    begin: (machine: M) => void
    forward: (act: (machine: M) => void) => void
}

/**
 * The state both step screens share.
 *
 * @param onSettle - given a machine whose `done` is set, once, as it is let go.
 * @param initial - a machine that runs already (for drawing a step in a test).
 * @returns see [[Stepper]].
 */
export function useStepper<M extends { done: unknown }>(
    onSettle: (machine: M) => void,
    initial?: M,
): Stepper<M> {
    const run = useRef<M | undefined>(initial)
    const [, setVersion] = useState(0)
    const [legend, setLegend] = useState<LegendItem[]>([])
    const redraw = useCallback(() => setVersion((v) => v + 1), [])

    const forward = useCallback(
        (act: (machine: M) => void) => {
            const machine = run.current
            if (!machine) return
            act(machine)
            if (machine.done) {
                run.current = undefined
                onSettle(machine)
            }
            redraw()
        },
        [onSettle, redraw],
    )

    const begin = useCallback(
        (machine: M) => {
            run.current = machine
            redraw()
        },
        [redraw],
    )

    return { current: run.current, legend, setLegend, begin, forward }
}

/** The most characters a prompt takes. */
const PROMPT_LENGTH = 60

/**
 * What the screen takes from the hook.
 *
 * @property open - the wizard is asking (the screen's own keys are off).
 * @property entry - the dropdown or prompt to draw under the table, `null` while closed.
 * @property reserved - the rows `entry` takes, which the table gives up.
 * @property legend - the keys of the open step.
 * @property start - opens the wizard for a template of that name; `options` start it from
 *     a definition (edit) or from the first point of a table (convert).
 */
export type WizardUi = {
    open: boolean
    entry: ReactNode
    reserved: number
    legend: LegendItem[]
    start: (name: string, options?: Omit<WizardOptions, "customs">) => void
}

/** The user's custom non-biological solutes; none when their file cannot be read. */
function customSolutes(): NonbioEntry[] {
    try {
        const all = readCustomSolutes(appDir())
        return all.filter((e): e is NonbioEntry => e.kind === "nonbiological")
    } catch {
        return []
    }
}

/**
 * The wizard of a template definition under a table.
 *
 * @param onDefinition - given the definition when the wizard ends well.
 * @param onProblem - given the text when it ends with a definition that cannot be used;
 *     a cancel is silent.
 * @returns what to draw and how to start, see [[WizardUi]].
 */
export function useTemplateWizard(
    onDefinition: (definition: Definition) => void,
    onProblem: (text: string) => void,
): WizardUi {
    const settle = useCallback(
        (w: TemplateWizard) => {
            const done = w.done
            if (done && "definition" in done) onDefinition(done.definition)
            else if (w.problem !== undefined) onProblem(w.problem)
        },
        [onDefinition, onProblem],
    )
    const { current, legend, setLegend, begin, forward } = useStepper(settle)

    const start = useCallback(
        (name: string, options: Omit<WizardOptions, "customs"> = {}) => {
            begin(new TemplateWizard(name, { ...options, customs: customSolutes() }))
        },
        [begin],
    )

    const step = current?.step
    if (!step) return { open: false, entry: null, reserved: 0, legend: [], start }
    if (step.type === "prompt") {
        const entry = (
            <Prompt
                key={step.label}
                label={step.label}
                initial={step.initial}
                maxLength={PROMPT_LENGTH}
                error={step.problem}
                onSubmit={(text) => forward((w) => w.submit(text))}
                onCancel={() => forward((w) => w.cancel())}
                onLegend={setLegend}
            />
        )
        return { open: true, entry, reserved: PROMPT_ROWS, legend, start }
    }
    const choices = step.items.map((label, value) => ({ label, value }))
    const lines = Math.min(step.items.length, suggestionLines)
    const entry = (
        <Dropdown<number>
            key={step.label}
            label={step.label}
            search={filterChoices(choices)}
            initial={step.initial}
            lines={lines}
            onPick={(index) => forward((w) => w.pick(index))}
            onCancel={() => forward((w) => w.cancel())}
            onLegend={setLegend}
        />
    )
    return { open: true, entry, reserved: lines + DROPDOWN_CHROME, legend, start }
}
