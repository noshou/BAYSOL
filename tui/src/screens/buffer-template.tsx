// SPDX-License-Identifier: LGPL-3.0-or-later

// The buffer template flow of the solutes table, drawn: `store/template-flow.ts` knows what
// is asked and in what order; this hook draws the step (a dropdown or a prompt under the
// table, or a page of its own for the rows to confirm) and hands the result to the table.

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useEffect, useRef, useState } from "react"
import { truncate } from "../core/terminal.js"
import type { Conditions } from "../store/buffer.js"
import type { Drafts } from "../store/lists.js"
import { type ConcUnit, formatConc, type Solute, sameSoluteKey } from "../store/solutes.js"
import { type Definition, rowsFor } from "../store/template-defs.js"
import { type ConfirmStep, TemplateFlow } from "../store/template-flow.js"
import { soluteFromSpec } from "../store/template-link.js"
import { linkFor } from "../store/template-recipes.js"
import {
    changedGroups,
    detach,
    recompute,
    seedOfRows,
    signatures,
} from "../store/template-sync.js"
import { type LegendItem, legendFor } from "../ui/grid.js"
import {
    DROPDOWN_CHROME,
    Dropdown,
    filterChoices,
    PROMPT_ROWS,
    Prompt,
    questionLegend,
    suggestionLines,
} from "../ui/input.js"
import { keys, useBodyColumns, useBodyRows, useKeys } from "../ui/interaction.js"
import { type Column, DataTable, useTheme } from "../ui/theme.js"
import type { TableScreen } from "./screen-rules.js"
import { useTemplateWizard } from "./template-wizard.js"

/** What the note says when a group stops following the pH. */
const EDITED_NOTE = "edited by hand: no longer follows the pH"

/** The labels of the dropdown steps. */
const DROPDOWN_LABELS = {
    pick: "buffer template:",
    ion: "titrant:",
    setat: "pH set at:",
} as const

/** The choices the `pH set at` dropdown lists. */
const SETAT_LINES = 3

/** What the dropdown of the templates says while nothing is typed. */
const PICK_PLACEHOLDER = "type to find"

/** The most choices the titrant dropdown lists. */
const ION_LINES = 2

/** The rows the confirm page keeps for the table's header, rule and counter. */
const TABLE_CHROME = 3

/**
 * What the screen takes from the hook.
 *
 * @property open - a template flow is open (the screen's own keys are off).
 * @property page - the page that takes the place of the tables (the rows to confirm),
 *     `null` while there is none.
 * @property entry - the prompt or dropdown to draw under the table, `null` for none.
 * @property reserved - the rows `entry` takes, which the table gives up.
 * @property legend - the keys of the open step.
 * @property note - what the bottom line says, `undefined` for nothing.
 * @property noteIsError - the note is a problem.
 * @property start - opens the flow of a shipped buffer (`shift+b`).
 * @property startNew - opens the wizard of a template of any kind (`shift+t`): its rows are
 *     added with a link and follow the pH and temperature.
 * @property convert - turns the rows of the table into a table template (`shift+v`): the
 *     rows are the first point, at the table's pH, the wizard asks the other points, and
 *     the rows come back with their link in place of the typed ones.
 */
export type BufferTemplate = {
    open: boolean
    page: ReactNode
    entry: ReactNode
    reserved: number
    legend: LegendItem[]
    note: string | undefined
    noteIsError: boolean
    start: () => void
    startNew: () => void
    convert: () => void
}

/** A row of the confirm page. */
type ConfirmRow = { name: string; mM: number; sigmaMM: number }

/**
 * The columns of the rows of the confirm page.
 *
 * @param unit - the unit the concentrations are shown in.
 * @returns the columns.
 */
function confirmColumns(unit: ConcUnit): Column<ConfirmRow>[] {
    /** The width a number may take. */
    const cells = 14
    return [
        { title: "solute", grow: 3, text: (r) => r.name },
        {
            title: `[${unit}]`,
            grow: 1,
            align: "right",
            text: (r) => formatConc(r.mM, unit, cells),
        },
        {
            title: `±[${unit}]`,
            grow: 1,
            align: "right",
            text: (r) => formatConc(r.sigmaMM, unit, cells),
        },
    ]
}

/**
 * The page of the rows a template comes to: the rows, the pH line, the working and the
 * warnings, as many lines as the body has.
 *
 * @param props - the step.
 * @returns the page.
 */
function ConfirmPage(props: { step: ConfirmStep }): ReactNode {
    const { step } = props
    const theme = useTheme()
    const width = useBodyColumns()
    const budget = useBodyRows(0)
    const { outcome } = step
    const warnings = outcome.warnings.map((w) => `! ${w}`)
    const extra = step.phLine ? [step.phLine] : []
    // the rows come first, then the warnings, the pH line and as much working as fits
    const rows = outcome.rows
    const fixed = TABLE_CHROME + rows.length + warnings.length + extra.length
    const room = Math.max(0, budget - fixed)
    const explain = outcome.explain.slice(0, room)
    const lines = (list: string[], colour: string) =>
        list.map((text) => (
            <Text key={text} color={colour}>
                {truncate(text, width)}
            </Text>
        ))
    return (
        <Box flexDirection="column">
            <Text color={theme.fg} bold>
                {truncate(`add: ${step.title}`, width)}
            </Text>
            <DataTable
                border="double"
                columns={confirmColumns(step.unit)}
                rows={rows}
                cursor={-1}
                offset={0}
                pageSize={Math.max(rows.length, 1)}
                width={width}
            />
            {lines(extra, theme.fg)}
            {lines(warnings, theme.er)}
            {lines(explain, theme.mt)}
        </Box>
    )
}

/**
 * The buffer template flow of a solutes table.
 *
 * @param t - the table screen, which takes the new drafts.
 * @param conditions - the pH and σ the table shows now.
 * @param setConditions - sets the pH row (an unsaved change).
 * @param initial - a flow that is open already (for drawing a step in a test).
 * @returns what to draw and how to start the flow, see [[BufferTemplate]].
 */
export function useBufferTemplate(
    t: TableScreen<Solute>,
    conditions: Conditions | undefined,
    setConditions: (next: Conditions) => void,
    initial?: TemplateFlow,
): BufferTemplate {
    const run = useRef<TemplateFlow | undefined>(initial)
    const [, setVersion] = useState(0)
    const [stepKeys, setStepKeys] = useState<LegendItem[]>([])
    const tRef = useRef(t)
    tRef.current = t
    const redraw = useCallback(() => setVersion((v) => v + 1), [])

    // Rows that follow the pH. `own` holds the signatures of the table this hook made
    // itself (a flow that ended, the rows worked out again), so that the guard below does
    // not take that for an edit by hand. It is compared with the table's contents, not a
    // flag: if the adopt does not redraw, a later edit by hand still differs and is seen.
    const own = useRef<string | undefined>(undefined)
    const mark = useCallback((drafts: Drafts<Solute>) => {
        own.current = JSON.stringify([...signatures(drafts)])
    }, [])
    const seen = useRef(signatures(t.drafts))
    const lastPH = useRef(conditions?.pH)
    useEffect(() => {
        const now = signatures(t.drafts)
        const before = seen.current
        seen.current = now
        const mine = own.current
        own.current = undefined
        if (mine !== undefined && mine === JSON.stringify([...now])) return
        // a row of a group was edited or removed: the group stops following the pH
        const stale = changedGroups(before, now)
        if (stale.length === 0) return
        t.adopt(detach(t.drafts, stale), false)
        t.setNote(EDITED_NOTE, false)
    }, [t])
    const pH = conditions?.pH
    const temperature = conditions?.temperature
    const lastTemperature = useRef(temperature)
    useEffect(() => {
        const phMoved = pH !== lastPH.current
        const temperatureMoved = temperature !== lastTemperature.current
        lastPH.current = pH
        lastTemperature.current = temperature
        if (pH === undefined || !(phMoved || temperatureMoved)) return
        const sigma = conditions?.["sigma-pH"] ?? 0.1
        const next = recompute(t.drafts, pH, sigma, temperature)
        const skipped = next.skipped.map((arg) => `${arg} already in the buffer`)
        const skippedNote = `${skipped.join(", ")}: not added by the template`
        if (next.errors.length > 0) {
            // a template that cannot be worked out here (a table outside its points)
            mark(next.drafts)
            if (next.changed) t.adopt(next.drafts, false)
            t.setNote(`not updated: ${next.errors.join("; ")}`, true)
            return
        }
        if (!next.changed) {
            if (skipped.length > 0) t.setNote(skippedNote, true)
            return
        }
        mark(next.drafts)
        t.adopt(next.drafts, false)
        const what = [
            phMoved ? `pH ${pH}` : undefined,
            temperatureMoved && temperature !== undefined
                ? `temperature ${temperature} C`
                : undefined,
        ]
        t.setNote(
            skipped.length > 0
                ? skippedNote
                : `buffer template rows updated for ${what.filter(Boolean).join(" and ")}`,
            skipped.length > 0,
        )
    }, [pH, temperature, conditions, t, mark])

    const settle = useCallback(() => {
        const flow = run.current
        const done = flow?.done
        if (done) {
            run.current = undefined
            if (!done.cancelled) {
                mark(done.drafts)
                tRef.current.adopt(done.drafts, true)
                if (done.conditions) setConditions(done.conditions)
            }
        }
        redraw()
    }, [redraw, setConditions, mark])

    const forward = useCallback(
        (act: (flow: TemplateFlow) => void) => {
            if (!run.current) return
            act(run.current)
            settle()
        },
        [settle],
    )

    const start = useCallback(() => {
        run.current = new TemplateFlow({ drafts: tRef.current.drafts, conditions })
        redraw()
    }, [conditions, redraw])

    // `shift+t`: the wizard makes a definition, its rows come in with their link;
    // `shift+v`: the same for the rows that are there (replaced by the linked ones)
    const conditionsRef = useRef(conditions)
    conditionsRef.current = conditions
    const replacing = useRef<number[]>([])
    const addDefinition = useCallback(
        (definition: Definition) => {
            const table = tRef.current
            const c = conditionsRef.current
            const replaced = replacing.current
            replacing.current = []
            if (c === undefined || c.temperature === undefined) {
                return table.setNote("set the pH and temperature first (^g)", true)
            }
            const made = rowsFor(definition, {
                pH: c.pH,
                sigmaPH: c["sigma-pH"],
                temperatureC: c.temperature,
            })
            if ("error" in made) return table.setNote(made.error, true)
            const link = linkFor(definition)
            let next = table.drafts
            // the rows a conversion replaces go first, highest index first
            for (const i of [...replaced].sort((a, b) => b - a)) next = next.remove(i)
            for (const r of made.rows) {
                const row = soluteFromSpec(r, link)
                const key = sameSoluteKey(row)
                const twin = next.rows.some(
                    (x, i) => !x.removed && sameSoluteKey(next.value(i) as Solute) === key,
                )
                if (twin) return table.setNote(`${r.arg} is already in the buffer`, true)
                if (!next.hasRoom) return table.setNote("too many solutes", true)
                next = next.add(row)
            }
            mark(next)
            table.adopt(next, true)
            const warn = made.warnings.length > 0 ? `: ${made.warnings.join("; ")}` : ""
            table.setNote(`added ${made.rows.length} rows${warn}`, false)
        },
        [mark],
    )
    const wizard = useTemplateWizard(addDefinition, (text) => {
        replacing.current = []
        tRef.current.setNote(`template not added: ${text}`, true)
    })
    const startNew = useCallback(() => {
        replacing.current = []
        wizard.start("custom buffer")
    }, [wizard.start])
    const convert = useCallback(() => {
        const table = tRef.current
        const c = conditionsRef.current
        if (c === undefined || c.temperature === undefined) {
            return table.setNote("set the pH and temperature first (^g)", true)
        }
        const made = seedOfRows(table.drafts, c.pH)
        if ("problem" in made) return table.setNote(made.problem, true)
        replacing.current = made.indices
        wizard.start("converted rows", { seed: made.seed })
    }, [wizard.start])
    const flow = run.current
    const step = flow?.step
    const onConfirm = step?.type === "confirm" || step?.type === "replace"
    const stuck = step?.type === "confirm" && step.problem !== undefined
    // Enter adds, Esc gives up; a page with a problem can only be left
    useKeys((press) => {
        if (press.is(keys.enter) && !stuck) forward((f) => f.accept())
        else if (press.is(keys.escape) || press.is(keys.back)) forward((f) => f.cancel())
    }, onConfirm)

    const closed: BufferTemplate = {
        open: false,
        page: null,
        entry: null,
        reserved: 0,
        legend: [],
        note: undefined,
        noteIsError: false,
        start,
        startNew,
        convert,
    }
    if (wizard.open) {
        return {
            ...closed,
            open: true,
            entry: wizard.entry,
            reserved: wizard.reserved,
            legend: wizard.legend,
        }
    }
    if (!flow || !step) return closed

    const label = (text: string) => `${step.type}:${text}`
    let entry: ReactNode = null
    let reserved = 0
    let page: ReactNode = null
    let legend: LegendItem[] = stepKeys
    let note: string | undefined
    let noteIsError = false
    if (step.type === "pick" || step.type === "ion" || step.type === "setat") {
        const choices = step.items.map((item, value) => ({ label: item.text, value }))
        const lines =
            step.type === "pick"
                ? suggestionLines
                : step.type === "setat"
                    ? SETAT_LINES
                    : ION_LINES
        reserved = lines + DROPDOWN_CHROME
        entry = (
            <Dropdown<number>
                key={label(step.type)}
                label={DROPDOWN_LABELS[step.type]}
                placeholder={step.type === "pick" ? PICK_PLACEHOLDER : undefined}
                search={filterChoices(choices)}
                lines={lines}
                onPick={(index) => forward((f) => f.pick(index))}
                onCancel={() => forward((f) => f.cancel())}
                onLegend={setStepKeys}
            />
        )
    } else if (step.type === "prompt") {
        reserved = PROMPT_ROWS
        entry = (
            <Prompt
                key={label(step.label)}
                label={step.label}
                initial={step.initial}
                maxLength={20}
                error={step.problem}
                onSubmit={(text) => forward((f) => f.submit(text))}
                onCancel={() => forward((f) => f.cancel())}
                onLegend={setStepKeys}
            />
        )
    } else if (step.type === "confirm") {
        page = <ConfirmPage step={step} />
        legend = step.problem
            ? [legendFor("cancel", keys.escape)]
            : [legendFor("add rows", keys.enter), legendFor("cancel", keys.escape)]
        note = step.problem
        noteIsError = step.problem !== undefined
    } else {
        const names = step.names.join(", ")
        page = <ConfirmPage step={step.confirm} />
        legend = questionLegend({ text: "", yes: "replace", no: "cancel" })
        note = `replace the existing ${names}?`
    }
    return {
        open: true,
        page,
        entry,
        reserved,
        legend,
        note,
        noteIsError,
        start,
        startNew,
        convert,
    }
}
