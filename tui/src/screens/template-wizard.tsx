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
    const wizard = useRef<TemplateWizard | undefined>(undefined)
    const [, setVersion] = useState(0)
    const [legend, setLegend] = useState<LegendItem[]>([])
    const redraw = useCallback(() => setVersion((v) => v + 1), [])

    const settle = useCallback(() => {
        const w = wizard.current
        const done = w?.done
        if (w && done) {
            wizard.current = undefined
            if ("definition" in done) onDefinition(done.definition)
            else if (w.problem !== undefined) onProblem(w.problem)
        }
        redraw()
    }, [onDefinition, onProblem, redraw])

    const forward = useCallback(
        (act: (w: TemplateWizard) => void) => {
            if (!wizard.current) return
            act(wizard.current)
            settle()
        },
        [settle],
    )

    const start = useCallback(
        (name: string, options: Omit<WizardOptions, "customs"> = {}) => {
            const customs = customSolutes()
            wizard.current = new TemplateWizard(name, { ...options, customs })
            redraw()
        },
        [redraw],
    )

    const step = wizard.current?.step
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
