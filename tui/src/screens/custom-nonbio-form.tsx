// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useMemo, useState } from "react"
import {
    entryProblem,
    formatNumber,
    formatRounded,
    getField,
    type NonbioEntry,
    nonbioPreview,
    parseCell,
    takeFormula,
    withField,
} from "../store/custom.js"
import { breakdown } from "../store/formula.js"
import { isBuiltinName } from "../store/solute-index.js"
import { FieldForm, type FormRow } from "../ui/field-form.js"
import { placeAt } from "../ui/form-layout.js"
import { Frame } from "../ui/frame.js"
import type { LegendItem } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { useTheme } from "../ui/theme.js"
import { useFormScreen } from "../ui/use-form-screen.js"

/** The fields of the form, in the order of its rows, with the label of each. */
const FIELDS = [
    { key: "name", label: "name" },
    { key: "formula", label: "formula" },
    { key: "z", label: "Z" },
    { key: "pmv", label: "PMV @ 25 °C (cm³/mol)" },
    { key: "sigma", label: "± (cm³/mol)" },
] as const

/** The key of a field of the form. */
type FieldKey = (typeof FIELDS)[number]["key"]

/** Each row has one cell, in column 0. */
const VALID = FIELDS.map(() => [0])

/** The keys of the form page. */
const LEGEND: LegendItem[] = [
    { label: "move", keys: "↑↓" },
    { label: "edit", keys: "⏎" },
    { label: "restore", keys: "^u" },
    { label: "accept", keys: "^w" },
    { label: "cancel", keys: "esc" },
]

/**
 * What the form page of a custom non-biological solute is told.
 *
 * @property entry - the entry to start from (a blank one for a new solute).
 * @property others - the names of the other entries, for the check of the name.
 * @property fallback - the setting `PMV_FALLBACK_UNCERT`, which a blank ± stands for.
 * @property onAccept - called with the entry when the form is accepted; the form then
 *     closes. A form left with Esc calls nothing.
 */
export type CustomNonbioFormProps = {
    entry:    NonbioEntry
    others:   readonly string[]
    fallback: number
    onAccept: (entry: NonbioEntry) => void
}

/**
 * The text a prompt starts from for a field: a Z as digits, a number as plain decimal
 * text (blank for none), the text fields as they are.
 */
function startText(entry: NonbioEntry, key: FieldKey): string {
    const v = getField(entry, key)
    return typeof v === "number" ? formatNumber(v) : String(v ?? "")
}

/**
 * The form page of a custom non-biological solute: name, formula, Z, PMV and ±, and under
 * them what BAYSOL will use. Z is computed from the formula as soon as the formula is
 * taken, to keep or to type over (a formula that does not change keeps the Z typed); a
 * formula that is not understood says why and leaves Z to be typed. A blank ± shows the
 * setting `PMV_FALLBACK_UNCERT` in parentheses; the entry keeps it blank.
 *
 * Keys: up and down move over the fields, Enter edits one (Esc drops what was typed),
 * `^u` puts the field back to what it was when the form opened, `^w` accepts only if
 * nothing is missing (the problem is told, with its field) and Esc cancels.
 *
 * @param props - see [[CustomNonbioFormProps]].
 * @returns the screen.
 */
export function CustomNonbioForm(props: CustomNonbioFormProps): ReactNode {
    const { others, fallback, onAccept } = props
    const nav = useNav()
    const theme = useTheme()
    const [orig] = useState(props.entry)
    const [entry, setEntry] = useState(props.entry)

    const form = useFormScreen({
        valid: VALID,
        editLabel: (pos) => `${FIELDS[pos.row]?.label}:`,
        editText: (pos) => startText(entry, FIELDS[pos.row]?.key as FieldKey),
        take: (pos, text) => {
            const key = (FIELDS[pos.row] as (typeof FIELDS)[number]).key
            const parsed = parseCell(key, text)
            if ("error" in parsed) return { error: parsed.error }
            if (key !== "formula") {
                setEntry(withField(entry, key, parsed.value) as NonbioEntry)
                return {}
            }
            const taken = takeFormula(entry, text, false)
            setEntry(taken.value)
            return { note: taken.note }
        },
        restore: (pos) => {
            const key = (FIELDS[pos.row] as (typeof FIELDS)[number]).key
            // the formula comes back with the Z that comes from it
            const back = withField(entry, key, getField(orig, key)) as NonbioEntry
            setEntry(key === "formula" ? { ...back, z: orig.z } : back)
        },
        check: () => {
            const found = entryProblem(entry, isBuiltinName, others)
            if (!found) return undefined
            const row = FIELDS.findIndex((f) => f.key === found.field)
            const pos = placeAt(Math.max(0, row), 0)
            return { pos, message: found.message }
        },
        accept: () => {
            onAccept(entry)
            nav.pop()
        },
        cancel: nav.pop,
    })

    const rows: FormRow[] = FIELDS.map(({ key, label }) => {
        const blankSigma = key === "sigma" && entry.sigma === null
        const text = blankSigma ? `(${formatRounded(fallback)})` : startText(entry, key)
        return { label, cells: [{ text, muted: blankSigma, wide: key === "name" }] }
    })
    const preview = useMemo(
        () => nonbioPreview(entry, fallback, breakdown(entry.formula)),
        [entry, fallback],
    )
    return (
        <Frame logo="blocky"
            title={orig.name === "" ? "new custom solute" : "custom solute"}
            subtitle={orig.name === "" ? "non-biological" : `${orig.name} · non-biological`}
            legend={LEGEND}
            note={form.note}
            noteIsError={form.noteIsError}
        >
            <FieldForm rows={rows} pos={form.pos} problem={form.problem} edit={form.edit} />
            <Box flexDirection="column" marginTop={form.edit ? 0 : 1}>
                {preview.map((p) => (
                    <Text key={p} color={theme.fg}>
                        {p}
                    </Text>
                ))}
            </Box>
        </Frame>
    )
}
