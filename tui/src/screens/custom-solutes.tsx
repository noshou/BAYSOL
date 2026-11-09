// SPDX-License-Identifier: LGPL-3.0-or-later

// The tables of the user's library: the custom solutes (both kinds in one table: the
// non-biological solutes, with the form that makes and changes them (a formula gives Z,
// with a live preview), and the polymers, whose form is in `./polymers.tsx`) and the
// saved recipes.
//
// Contents:
//   1. The non-biological form
//   2. `CustomSolutesTable`: the custom solutes
//   3. `RecipesTable`: the saved recipes

import { basename } from "node:path"
import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { appDir } from "../core/environment.js"
import { formatNumber } from "../core/terminal.js"
import {
    kindsSummary,
    MAX_NAME,
    type Recipe,
    readRecipes,
    recipeConditions,
    recipesFile,
    recipesFileName,
    removeRecipe,
    renameProblem,
    withConditions,
    writeRecipes,
} from "../store/buffer.js"
import {
    blankNonbio,
    type CustomEntry,
    customFile,
    entryProblem,
    getField,
    type NonbioEntry,
    nonbioPreview,
    parseCell,
    problems,
    readCustomSolutes,
    removeCustomSolute,
    withField,
    writeCustomSolutes,
} from "../store/custom.js"
import { breakdown, takeFormula } from "../store/formula.js"
import { type Row, rowValue } from "../store/lists.js"
import {
    blankPolymer,
    formatRounded,
    POLYMER_UNKNOWN_REL_UNC,
    type PolymerEntry,
} from "../store/polymers.js"
import { defaultCatalog } from "../store/settings.js"
import { globalScope, loadScope } from "../store/settings-store.js"
import { isBuiltinName } from "../store/solutes.js"
import { FieldForm, type FormRow, Frame, placeAt, useFormScreen } from "../ui/frame.js"
import { type LegendItem, legendFor } from "../ui/grid.js"
import { Prompt } from "../ui/input.js"
import { keyLabels, keys, scrollWindow, useKeys, useNav } from "../ui/interaction.js"
import { type Column, DataTable, useTheme } from "../ui/theme.js"
import { CustomPolymerForm } from "./polymers.js"
import { formLegend, unusable, useTableScreen } from "./screen-rules.js"
import { SolutesTable } from "./solutes.js"

// ========================================================================================
// 1. The non-biological form
// ========================================================================================

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
const NONBIO_VALID = FIELDS.map(() => [0])

/**
 * What the form page of a custom non-biological solute is told.
 *
 * @property entry - the entry to start from (a blank one for a new solute).
 * @property others - the names of the other entries, for the check of the name.
 * @property fallback - the setting `PMV_FALLBACK_UNCERT`, which a blank ± stands for.
 * @property onAccept - called with the entry when the form is accepted; the form then
 *     closes. A form left with Esc calls nothing.
 */
type CustomNonbioFormProps = {
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
function CustomNonbioForm(props: CustomNonbioFormProps): ReactNode {
    const { others, fallback, onAccept } = props
    const nav = useNav()
    const theme = useTheme()
    const [orig] = useState(props.entry)
    const [entry, setEntry] = useState(props.entry)

    const form = useFormScreen({
        valid: NONBIO_VALID,
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
        // a cell can be put back when it (or, for the formula, its Z) was changed
        canRestore: (pos) => {
            const key = (FIELDS[pos.row] as (typeof FIELDS)[number]).key
            return (
                getField(entry, key) !== getField(orig, key) ||
                (key === "formula" && entry.z !== orig.z)
            )
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
        <Frame
            design="blocky"
            title={orig.name === "" ? "new custom solute" : "custom solute"}
            subtitle={orig.name === "" ? "non-biological" : `${orig.name} · non-biological`}
            legend={formLegend({
                editing: form.edit !== undefined,
                moves: form.moves,
                canRestore: form.canRestore,
                complete: form.complete,
                acceptLabel: orig.name === "" ? "add to table" : "accept",
            })}
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

// ========================================================================================
// 2. The custom solutes table
// ========================================================================================

/** The setting whose value stands for the blank ± of a solute. */
const FALLBACK_SETTING = "PMV_FALLBACK_UNCERT"

/** The widths of the two narrow columns: their titles, which the cells fit under. */
const PMV_WIDTH = 14
const SIGMA_WIDTH = 10

/** The add keys of the legend (also what the footer reserves). */
const CUSTOM_ADDS = [
    legendFor("add nonbio", keys.addNonbio),
    legendFor("add polymer", keys.addPolymer),
]

/** What the empty table says. */
const CUSTOM_EMPTY_HINT = `none: ${keyLabels(keys.addNonbio, keys.addPolymer)} add`

/**
 * A number as a term of a sum: `+36.9` or `-5.2`, the number as typed.
 */
function signed(x: number): string {
    return (x < 0 ? "-" : "+") + formatNumber(Math.abs(x))
}

/**
 * The terms of a sum as text, `36.9A+53.1B+9`: a term with no number is left out, the
 * first keeps its minus (`-5.2A+3`) and the others carry their sign.
 *
 * @param terms - `[number, suffix]` pairs, the suffix a unit's label or `""`.
 */
function sumText(terms: readonly (readonly [number | null, string])[]): string {
    const shown = terms.filter((t): t is readonly [number, string] => t[0] !== null)
    return shown
        .map(([x, suffix], i) => (i === 0 ? formatNumber(x) : signed(x)) + suffix)
        .join("")
}

/**
 * What the formula cell shows: the formula of a non-biological solute, the units of a
 * polymer as `A:C2H4O B:C3H6O` (a unit with no formula is left out).
 */
export function formulaCell(e: CustomEntry): string {
    if (e.kind !== "polymer") return e.formula
    return e.units
        .filter((u) => u.formula.trim() !== "")
        .map((u) => `${u.label}:${u.formula}`)
        .join(" ")
}

/**
 * What the Z cell shows: the number, or for a polymer the sum `24A+32B+10` of the Z of
 * each unit by its label, then the end groups.
 */
export function zCell(e: CustomEntry): string {
    if (e.kind !== "polymer") return e.z === null ? "" : String(e.z)
    const units = e.units.map((u) => [u.z, u.label] as const)
    return sumText([...units, [e["z-ends"], ""]])
}

/**
 * What the PMV cell shows: the number, or for a polymer the sum `36.9A+53.1B+9` of the
 * slope of each unit by its label, then the end groups.
 */
export function pmvCell(e: CustomEntry): string {
    if (e.kind !== "polymer") return formatNumber(e.pmv)
    const units = e.units.map((u) => [u.slope, u.label] as const)
    return sumText([...units, [e["pmv-ends"], ""]])
}

/**
 * The ± of a polymer as one cell: the ± of its units if they all agree, `…` if they
 * differ (the form page shows them all), `(2%)` when it is blank. The ± of the end
 * groups is not shown.
 */
function polymerSigmaCell(e: PolymerEntry): string {
    const sigmas = [...new Set(e.units.map((u) => u.sigma))]
    if (sigmas.length > 1) return "…"
    const [first] = sigmas
    if (first !== null && first !== undefined) return formatNumber(first)
    return `(${formatNumber(100 * POLYMER_UNKNOWN_REL_UNC)}%)`
}

/**
 * What the ± cell shows: the number; a blank of a non-biological solute as the setting
 * `PMV_FALLBACK_UNCERT` in parentheses; for a polymer see [[polymerSigmaCell]]. Nothing
 * is computed here, the defaults apply at the run.
 */
export function sigmaCell(e: CustomEntry, fallback: number): string {
    if (e.kind === "polymer") return polymerSigmaCell(e)
    return e.sigma === null ? `(${formatRounded(fallback)})` : formatNumber(e.sigma)
}

/**
 * The global setting `PMV_FALLBACK_UNCERT`, which a blank ± stands for.
 *
 * @returns its value, the default of the catalog if the settings cannot be read.
 */
function fallbackUncertainty(): number {
    try {
        const value = loadScope(globalScope).settings.get(FALLBACK_SETTING)
        if (typeof value === "number") return value
    } catch {
        // unreadable settings are the settings screens' business: use the default
    }
    return defaultCatalog().require(FALLBACK_SETTING).default as number
}

/** The names of the entries other than row `except` (`undefined` for a new one). */
function otherNames(
    rows: readonly Row<CustomEntry>[],
    except: number | undefined,
): string[] {
    return rows
        .filter((row, i) => i !== except && !row.removed)
        .map((row) => (rowValue(row) as CustomEntry).name)
}

/**
 * The custom solutes of the user: one row for each entry of the custom solutes file, with
 * the columns name, formula, Z, PMV at 25 °C and ± (cm³/mol). A polymer shows its units
 * by their labels (`A:C2H4O B:C3H6O`, Z `24A+32B+10`, PMV `36.9A+53.1B+9`). A new or
 * edited row shows `*`; nothing of that is written before `^w`.
 *
 * Keys: up and down move; Enter edits the row in its form page; `^n` and `^p` add a
 * non-biological solute and a polymer (their form pages), neither past 999 rows; `^r` on
 * a saved row asks `delete solute NAME? ...` and Enter deletes
 * that entry from the file at once (a row never saved just goes); `^u` undoes the last
 * edit of the row; `^w` saves (a row that is not complete is told and nothing is saved);
 * `^x` goes back, asking first when something is unsaved. A file that cannot be used is
 * told and left alone: the table is empty and nothing can be changed.
 *
 * @returns the screen.
 */
export function CustomSolutesTable(): ReactNode {
    const nav = useNav()
    const root = appDir()
    const loaded = useMemo(() => {
        try {
            return { items: readCustomSolutes(root, { track: true }), locked: undefined }
        } catch {
            return { items: [], locked: `${basename(customFile(root))} unusable!` }
        }
    }, [root])
    const fallback = useMemo(fallbackUncertainty, [])
    const t = useTableScreen<CustomEntry>({
        adds: CUSTOM_ADDS,
        items: loaded.items,
        locked: loaded.locked,
        erase: {
            what: "solute",
            name: (entry) => entry.name,
            remove: (entry) => void removeCustomSolute(root, entry.name),
        },
        save: (items) => void writeCustomSolutes(root, items),
        check: (drafts) => problems(drafts, isBuiltinName),
    })

    const form = (entry: CustomEntry, row: number | undefined) => {
        const others = otherNames(t.drafts.rows, row)
        const done = (e: CustomEntry) =>
            row === undefined ? t.append(e) : t.replaceAt(row, e)
        nav.push(
            entry.kind === "polymer" ? (
                <CustomPolymerForm entry={entry} others={others} onAccept={done} />
            ) : (
                <CustomNonbioForm
                    entry={entry}
                    others={others}
                    fallback={fallback}
                    onAccept={done}
                />
            ),
        )
    }

    useKeys((press) => {
        if (t.handleKey(press)) return
        if (press.is(keys.enter) && t.canEdit && t.current) form(t.current, t.cursor.index)
        else if (press.is(keys.addNonbio) && t.canAdd) form(blankNonbio(), undefined)
        else if (press.is(keys.addPolymer) && t.canAdd) form(blankPolymer(), undefined)
    })

    const entryOf = (r: Row<CustomEntry>) => rowValue(r) as CustomEntry
    const columns: Column<Row<CustomEntry>>[] = [
        { title: "name", grow: 2, text: (r) => entryOf(r).name },
        { title: "formula", grow: 2, text: (r) => formulaCell(entryOf(r)) },
        {
            title: "Z",
            grow: 2,
            align: "right",
            text: (r) => zCell(entryOf(r)),
        },
        {
            title: "PMV @ 25 °C",
            width: PMV_WIDTH,
            align: "right",
            text: (r) => pmvCell(entryOf(r)),
        },
        {
            title: "± cm³/mol",
            width: SIGMA_WIDTH,
            align: "right",
            text: (r) => sigmaCell(entryOf(r), fallback),
        },
    ]

    const changes = t.drafts.count
    return (
        <Frame
            design="blocky"
            title="custom solutes"
            subtitle={changes > 0 ? `${changes} unsaved` : basename(customFile(root))}
            legend={t.legend(CUSTOM_ADDS)}
            legendFull={t.legendFull}
            note={t.frameNote}
            noteIsError={t.frameNoteIsError}
        >
            <DataTable
                border="double"
                columns={columns}
                rows={t.rows}
                cursor={t.cursor.index}
                offset={t.cursor.offset}
                pageSize={t.pageSize}
                mark={t.mark}
                empty={t.locked ? "" : CUSTOM_EMPTY_HINT}
                width={t.width}
            />
        </Frame>
    )
}

// ========================================================================================
// 3. The recipes table
// ========================================================================================

/** What the empty table says. */
const RECIPES_EMPTY_HINT = `none: ${keys.addNonbio.label} adds`

/** The add key of the legend (also what the footer reserves). */
const RECIPE_ADDS = [legendFor("new recipe", keys.addNonbio)]

/** The rows the name prompt takes under the table: the field and its error. */
const PROMPT_ROWS = 3

/** The subtitle of the table of one recipe's solutes. */
const RECIPE_SUBTITLE = "recipe"

/** The widths of the narrow columns: their titles, which the cells fit under. */
const SOLUTES_WIDTH = 7
const PH_WIDTH = 6
const RECIPE_SIGMA_WIDTH = 8

/**
 * Loads the recipes of the BAYSOL folder once.
 *
 * @returns the recipes, or none and a `locked` message for a file that cannot be used.
 */
function loadRecipes(root: string): { items: Recipe[]; locked?: string } {
    try {
        return { items: readRecipes(root, { track: true }) }
    } catch {
        return { items: [], locked: unusable(basename(recipesFile(root))) }
    }
}

/** What the name prompt is for: the row it renames, `undefined` for a new recipe. */
type Naming = { index: number | undefined; initial: string }

/**
 * The saved recipes of the user: one row for each recipe of the recipes file, with the
 * columns name, solutes (how many), kinds (`3 solute 1 polymer 2 custom 4 seq`), pH and
 * σ (blank for a recipe without). A row that is new or changed shows `*`; nothing of
 * that is written before `^w`.
 *
 * Keys: up and down move; Enter asks the recipe's name (prefilled: the rename) and then
 * opens its solutes in a [[SolutesTable]] (with the recipe's pH row, `^g`); `^n` does the
 * same for a new, empty recipe (never past 999); `^r` on a saved row asks `delete recipe
 * NAME? ...` and Enter deletes it from the file at once (the projects that loaded it keep
 * their own buffer; a row never saved just goes); `^u` undoes its last edit; `^w` saves
 * the list; `^x` goes back, asking first when something is unsaved. A name is not blank,
 * at most 40 characters, without control characters and unique among the other recipes
 * (case does not matter, a recipe may change only its case); a clash says `name in use`.
 * A file that cannot be used is told and left alone. The mechanics are `useTableScreen`.
 *
 * The solutes table of a recipe saves into the row here (it is a change of the row, shown
 * with `*`): the file only changes at `^w` of this table, so a rename and an edit of the
 * solutes are saved together.
 *
 * @returns the screen.
 */
export function RecipesTable(): ReactNode {
    const nav = useNav()
    const root = appDir()
    const loaded = useMemo(() => loadRecipes(root), [root])
    const t = useTableScreen<Recipe>({
        adds: RECIPE_ADDS,
        items: loaded.items,
        locked: loaded.locked,
        erase: {
            what: "recipe",
            name: (recipe) => recipe.name,
            remove: (recipe) => void removeRecipe(root, recipe.name, { guarded: true }),
        },
        save: (recipes) => void writeRecipes(root, recipes),
        // names are checked when they are typed, the solutes when they are saved
        check: () => undefined,
    })
    const [naming, setNaming] = useState<Naming>()
    const [problem, setProblem] = useState<string>()
    // the keys of the open name prompt
    const [nameKeys, setNameKeys] = useState<LegendItem[]>([])
    // stable: a prompt reports its text again whenever this handler changes
    const clearProblem = useCallback(() => setProblem(undefined), [])

    /** Opens the solutes of a recipe (row `index`) on top of this table. */
    const openSolutes = (index: number, recipe: Recipe) => {
        nav.push(
            <SolutesTable
                title={recipe.name}
                subtitle={RECIPE_SUBTITLE}
                items={recipe.solutes}
                conditions={recipeConditions(recipe)}
                save={(rows, c) =>
                    t.replaceAt(index, withConditions({ ...recipe, solutes: rows }, c))
                }
                idleNote={`${RECIPE_SUBTITLE}: ${recipe.name}`}
            />,
        )
    }

    /** The name was accepted: a new row, or the rename of the row, then its solutes. */
    const accept = (name: string, target: Naming) => {
        setNaming(undefined)
        const { index } = target
        if (index === undefined) {
            const recipe: Recipe = { name, solutes: [] }
            const at = t.drafts.length
            t.append(recipe)
            return openSolutes(at, recipe)
        }
        const current = t.drafts.value(index) as Recipe
        const recipe = { ...current, name }
        if (name !== current.name) t.replaceAt(index, recipe)
        openSolutes(index, recipe)
    }

    const submit = (text: string, target: Naming) => {
        const name = text.trim()
        const others = t.drafts.rows.map((r) => ({ name: (rowValue(r) as Recipe).name }))
        const bad = renameProblem(others, name, target.index)
        if (bad !== undefined) return setProblem(bad)
        accept(name, target)
    }

    useKeys((press) => {
        if (t.handleKey(press)) return
        if (press.is(keys.enter) && t.canEdit && t.current) {
            setProblem(undefined)
            setNaming({ index: t.cursor.index, initial: t.current.name })
        } else if (press.is(keys.addNonbio) && t.canAdd) {
            setProblem(undefined)
            setNaming({ index: undefined, initial: "" })
        }
    }, naming === undefined)

    const recipeOf = (r: Row<Recipe>) => rowValue(r) as Recipe
    const columns: Column<Row<Recipe>>[] = [
        { title: "name", grow: 3, text: (r) => recipeOf(r).name },
        {
            title: "solutes",
            width: SOLUTES_WIDTH,
            align: "right",
            text: (r) => String(recipeOf(r).solutes.length),
        },
        { title: "kinds", grow: 4, text: (r) => kindsSummary(recipeOf(r).solutes) },
        {
            title: "pH",
            width: PH_WIDTH,
            align: "right",
            text: (r) => {
                const c = recipeConditions(recipeOf(r))
                return c === undefined ? "" : formatNumber(c.pH)
            },
        },
        {
            title: "σ",
            width: RECIPE_SIGMA_WIDTH,
            align: "right",
            text: (r) => {
                const c = recipeConditions(recipeOf(r))
                return c === undefined ? "" : formatNumber(c["sigma-pH"])
            },
        },
    ]

    // only the keys that work now; the name prompt has its own keys while it is open
    const legend = naming ? nameKeys : t.legend(RECIPE_ADDS)
    // the prompt takes the rows under the table, so the window shrinks to keep the cursor
    const pageSize = naming ? Math.max(3, t.pageSize - PROMPT_ROWS) : t.pageSize
    const offset = scrollWindow(t.cursor.index, t.cursor.offset, pageSize, t.rows.length)
    const changes = t.drafts.count
    return (
        <Frame
            design="blocky"
            title="recipes"
            subtitle={changes > 0 ? `${changes} unsaved` : recipesFileName}
            legend={legend}
            legendFull={t.legendFull}
            note={naming ? undefined : t.frameNote}
            noteIsError={t.frameNoteIsError}
        >
            <DataTable
                border="double"
                columns={columns}
                rows={t.rows}
                cursor={t.cursor.index}
                offset={offset}
                pageSize={pageSize}
                mark={t.mark}
                empty={t.locked ? "" : RECIPES_EMPTY_HINT}
                width={t.width}
            />
            {naming ? (
                <Prompt
                    label="recipe name:"
                    initial={naming.initial}
                    maxLength={MAX_NAME}
                    error={problem}
                    onChange={clearProblem}
                    onLegend={setNameKeys}
                    onSubmit={(text) => submit(text, naming)}
                    onCancel={() => setNaming(undefined)}
                />
            ) : null}
        </Frame>
    )
}
