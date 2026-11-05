// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useMemo, useState } from "react"
import {
    blankUnit,
    compactUnits,
    defaultLabel,
    type EntryUnit,
    entryProblem,
    formatNumber,
    getField,
    labelShown,
    MAX_UNITS,
    type ParseField,
    type PolymerEntry,
    parseCell,
    polymerPreview,
    takeEndsFormula,
    takeFormula,
    type UnitKey,
    unitSigmaShown,
    usedRows,
    withField,
} from "../store/custom.js"
import { isBuiltinName } from "../store/solute-index.js"
import { FieldForm, type FormCell, type FormRow } from "../ui/field-form.js"
import { type CellPos, placeAt } from "../ui/form-layout.js"
import { Frame } from "../ui/frame.js"
import type { LegendItem } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { useTheme } from "../ui/theme.js"
import { useFormScreen } from "../ui/use-form-screen.js"

/** The cells of a unit row, in column order: the field of each. */
const UNIT_KEYS: readonly UnitKey[] = ["label", "formula", "z", "slope", "sigma"]

/** The titles of those columns, above the first unit row. */
const UNIT_HEADING = ["unit", "formula", "Z / unit", "PMV / unit", "± / unit"]

/**
 * The cells of the end groups, in column order (column 0 has none): the formula that
 * only gives the Z, then the fields of the polymer.
 */
const ENDS_KEYS = [undefined, "formula", "z-ends", "pmv-ends", "sigma-ends"] as const

/** The rows of the form: the name, one for each unit, the end groups. */
const UNIT_ROWS = MAX_UNITS
const ENDS_ROW = UNIT_ROWS + 1

/** The columns that have a cell, for each row. */
const VALID: number[][] = [
    [0],
    ...Array.from({ length: UNIT_ROWS }, () => UNIT_KEYS.map((_, c) => c)),
    [1, 2, 3, 4],
]

/** The keys of the form page. */
const LEGEND: LegendItem[] = [
    { label: "move", keys: "↑↓←→" },
    { label: "edit", keys: "⏎" },
    { label: "restore", keys: "^u" },
    { label: "accept", keys: "^w" },
    { label: "cancel", keys: "esc" },
]

/**
 * What the form page of a custom polymer is told.
 *
 * @property entry - the entry to start from (a blank one for a new polymer).
 * @property others - the names of the other entries, for the check of the name.
 * @property onAccept - called with the polymer (its used unit rows only) when the form is
 *     accepted; the form then closes. A form left with Esc calls nothing.
 */
export type CustomPolymerFormProps = {
    entry:    PolymerEntry
    others:   readonly string[]
    onAccept: (entry: PolymerEntry) => void
}

/** What a cell of the form is: the name, a cell of a unit, or one of the end groups. */
type Target =
    | { kind: "name" }
    | { kind: "unit"; unit: number; key: UnitKey }
    | { kind: "ends"; key: "formula" | "z-ends" | "pmv-ends" | "sigma-ends" }

/**
 * What a position of the cursor is.
 *
 * @param pos - the cell.
 * @returns the target.
 */
function targetAt(pos: CellPos): Target {
    if (pos.row === 0) return { kind: "name" }
    if (pos.row === ENDS_ROW)
        return { kind: "ends", key: ENDS_KEYS[pos.col] as "formula" | "z-ends" }
    return { kind: "unit", unit: pos.row - 1, key: UNIT_KEYS[pos.col] as UnitKey }
}

/** The key of `parseCell` for a target (the formula of the end groups is a formula). */
function parseKey(t: Target): ParseField {
    if (t.kind === "name") return "name"
    return t.key === "formula" ? "formula" : (t.key as ParseField)
}

/** The unit rows of an entry padded with blank ones to the rows of the form. */
function padUnits(units: readonly EntryUnit[]): EntryUnit[] {
    return [...units, ...Array.from({ length: UNIT_ROWS }, blankUnit)].slice(0, UNIT_ROWS)
}

/** The text a number cell starts from: plain decimal text, blank for none. */
function numberText(v: unknown): string {
    return typeof v === "number" ? formatNumber(v) : ""
}

/**
 * The form page of a custom polymer, a generic additive chain, PMV = pmv-ends + the sum
 * of slope times count and Z likewise, of one to four kinds of repeat unit: the name, a
 * table of four unit rows (unit label, formula, Z, PMV slope and ± each), the end groups
 * on the same columns, and under them the chain in words with the user's labels
 * (`PMV = 9 + 36.9·nA + 53.1·nB`) and, once everything is given, its values for 10 and
 * for 100 of each unit.
 *
 * A unit row is used when it has anything in it (the first always); an all-blank row is
 * ignored, a half-filled one is a problem, so clearing a row removes a unit. A used row
 * with no label shows the one offered for its place, `(A)`, and takes it when accepted.
 * Z of a unit comes from its formula, to keep or type over; its ± is absolute and blank
 * shows `(2%)`. The end groups have no default: Z (or a formula that gives it) and PMV
 * are required, a blank ± is none; the formula of the end groups is not kept.
 *
 * Keys: the arrows move over the cells, Enter edits one (Esc drops what was typed), `^u`
 * puts the cell back to what it was when the form opened, `^w` accepts only if nothing
 * is missing (the problem is told, with its cell) and Esc cancels.
 *
 * @param props - see [[CustomPolymerFormProps]].
 * @returns the screen.
 */
export function CustomPolymerForm(props: CustomPolymerFormProps): ReactNode {
    const { others, onAccept } = props
    const nav = useNav()
    const theme = useTheme()
    const [orig] = useState<PolymerEntry>(() => ({
        ...props.entry,
        units: padUnits(props.entry.units),
    }))
    const [entry, setEntry] = useState(orig)
    // the formula of the end groups only gives their Z and is not part of the entry
    const [endsFormula, setEndsFormula] = useState("")

    /** The value of the cell of a target. */
    const cellValue = (t: Target): unknown => {
        if (t.kind === "name") return entry.name
        if (t.kind === "unit") return getField(entry, { unit: t.unit, key: t.key })
        return t.key === "formula" ? endsFormula : entry[t.key]
    }
    /** The entry with a cell set (not the formula of the end groups). */
    const withValue = (t: Target, v: unknown): PolymerEntry => {
        if (t.kind === "name") return withField(entry, "name", v) as PolymerEntry
        if (t.kind === "unit")
            return withField(entry, { unit: t.unit, key: t.key }, v) as PolymerEntry
        return withField(entry, t.key as "z-ends", v) as PolymerEntry
    }

    // the polymer the form stands for: the used rows, a blank label as the offered one
    const compact: PolymerEntry = useMemo(
        () => ({ ...entry, units: compactUnits(entry.units) }),
        [entry],
    )
    const used = useMemo(() => usedRows(entry.units), [entry.units])

    /** The value a cell had when the form opened. */
    const originalOf = (t: Target): unknown => {
        if (t.kind === "name") return orig.name
        if (t.kind === "unit") return getField(orig, { unit: t.unit, key: t.key })
        return orig[t.key as "z-ends"]
    }

    const form = useFormScreen({
        valid: VALID,
        editLabel: (pos) => {
            const t = targetAt(pos)
            if (t.kind === "name") return "name:"
            const column = UNIT_HEADING[UNIT_KEYS.indexOf(t.key as UnitKey)] ?? ""
            return t.kind === "ends"
                ? `end groups ${t.key === "formula" ? "formula" : t.key}:`
                : `unit ${t.unit + 1} ${column}:`
        },
        editText: (pos) => {
            const v = cellValue(targetAt(pos))
            return typeof v === "number" ? numberText(v) : String(v ?? "")
        },
        take: (pos, text) => {
            const t = targetAt(pos)
            const parsed = parseCell(parseKey(t), text)
            if ("error" in parsed) return { error: parsed.error }
            if (t.kind === "ends" && t.key === "formula") {
                const r = takeEndsFormula(entry, endsFormula, text)
                setEntry(r.entry)
                setEndsFormula(r.endsFormula)
                return { note: r.note }
            }
            if (t.kind === "unit" && t.key === "formula") {
                const unit = entry.units[t.unit] as EntryUnit
                const r = takeFormula(unit, text, true, defaultLabel(t.unit))
                const units = entry.units.map((u, i) => (i === t.unit ? r.value : u))
                setEntry({ ...entry, units })
                return { note: r.note }
            }
            setEntry(withValue(t, parsed.value))
            return {}
        },
        restore: (pos) => {
            const t = targetAt(pos)
            if (t.kind === "ends" && t.key === "formula") return setEndsFormula("")
            if (t.kind === "unit" && t.key === "formula") {
                // the formula comes back with the Z that comes from it
                const o = orig.units[t.unit] as EntryUnit
                const units = entry.units.map((u, i) =>
                    i === t.unit ? { ...u, formula: o.formula, z: o.z } : u,
                )
                return setEntry({ ...entry, units })
            }
            setEntry(withValue(t, originalOf(t)))
        },
        check: () => {
            const found = entryProblem(compact, isBuiltinName, others)
            if (!found) return undefined
            const f = found.field
            if (typeof f === "object") {
                // a unit of the compact entry is the row that is used, not its index
                const row = 1 + (usedRows(entry.units)[f.unit] as number)
                const pos = placeAt(row, UNIT_KEYS.indexOf(f.key))
                return { pos, message: found.message }
            }
            const col = ENDS_KEYS.indexOf(f as "z-ends")
            const pos = col > 0 ? placeAt(ENDS_ROW, col) : placeAt(0, 0)
            return { pos, message: found.message }
        },
        accept: () => {
            onAccept(compact)
            nav.pop()
        },
        cancel: nav.pop,
    })

    const unitRows: FormRow[] = entry.units.map((u, i) => {
        const on = used.includes(i)
        const label = labelShown(u.label, i, on)
        const sigma = unitSigmaShown(u.sigma, on)
        const cells: FormCell[] = [
            { text: label, muted: u.label.trim() === "" },
            { text: u.formula },
            { text: numberText(u.z) },
            { text: numberText(u.slope) },
            { text: sigma, muted: u.sigma === null },
        ]
        return {
            label: `unit ${i + 1}`,
            cells,
            heading: i === 0 ? UNIT_HEADING : undefined,
        }
    })
    const rows: FormRow[] = [
        { label: "name", cells: [{ text: entry.name, wide: true }] },
        ...unitRows,
        {
            label: "end groups",
            cells: [
                undefined,
                { text: endsFormula },
                { text: numberText(entry["z-ends"]) },
                { text: numberText(entry["pmv-ends"]) },
                { text: numberText(entry["sigma-ends"]) },
            ],
        },
    ]
    const preview = useMemo(() => polymerPreview(entry), [entry])

    return (
        <Frame logo="blocky"
            title={orig.name === "" ? "new custom polymer" : "custom polymer"}
            subtitle={orig.name === "" ? undefined : orig.name}
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
