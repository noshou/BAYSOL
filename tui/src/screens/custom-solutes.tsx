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
import { type ReactNode, useMemo, useRef, useState } from "react"
import { appDir } from "../core/environment.js"
import { saveErrorNote } from "../core/file-system.js"
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
    renameRecipe,
    saveRecipe,
    updateRecipe,
    withConditions,
    withNotes,
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
import { Drafts, type Row, rowValue } from "../store/lists.js"
import { notesCell } from "../store/notes.js"
import {
    blankPolymer,
    formatRounded,
    POLYMER_UNKNOWN_REL_UNC,
    type PolymerEntry,
} from "../store/polymers.js"
import { defaultCatalog } from "../store/settings.js"
import { globalScope, loadScope } from "../store/settings-store.js"
import { isBuiltinName } from "../store/solutes.js"
import { type Definition, normalizeDefinition } from "../store/template-defs.js"
import { kindOf, templateOf, withTemplate } from "../store/template-recipes.js"
import { type FormRow, Frame, placeAt, useFormScreen } from "../ui/frame.js"
import { legendFor } from "../ui/grid.js"
import { destructiveQuestion, questionLegend, useConfirm } from "../ui/input.js"
import { keys, scrollWindow, useKeys, useNav } from "../ui/interaction.js"
import { type Naming, useNamePrompt } from "../ui/prompt-flows.js"
import { type Column, DataTable } from "../ui/theme.js"
import { NotesList } from "./notes-list.js"
import { CustomPolymerForm, FormPage } from "./polymers.js"
import { plural, unusable, useTableScreen } from "./screen-rules.js"
import { SolutesTable } from "./solutes.js"
import { useTemplateWizard } from "./template-wizard.js"

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
        <FormPage
            form={form}
            title={orig.name === "" ? "new custom solute" : "custom solute"}
            subtitle={orig.name === "" ? "non-biological" : `${orig.name} · non-biological`}
            isNew={orig.name === ""}
            rows={rows}
            preview={preview}
        />
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
const CUSTOM_EMPTY_HINT = "none"

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
        label: (entry) => entry.name,
        sorted: true,
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
            {t.finder}
        </Frame>
    )
}

// ========================================================================================
// 3. The recipes table
// ========================================================================================

/** What the empty table says. */
const RECIPES_EMPTY_HINT = "none"

/** The add key of the legend (also what the footer reserves). */
const RECIPE_ADDS = [
    legendFor("new recipe", keys.addNonbio),
    legendFor("new template", keys.newTemplate),
]

/** The keys of the legend that act on the row, shown while a row can be opened. */
const RECIPE_ROW_KEYS = [
    legendFor("notes", keys.notesList),
    legendFor("edit template", keys.editTemplate),
]

/** The subtitle of the table of one recipe's solutes. */
const RECIPE_SUBTITLE = "recipe"

/** The widths of the narrow columns: their titles, which the cells fit under. */
const SOLUTES_WIDTH = 7
const PH_WIDTH = 6
const RECIPE_SIGMA_WIDTH = 8
const RECIPE_TEMPERATURE_WIDTH = 6
const RECIPE_TEMPLATE_WIDTH = 8

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

/**
 * The saved recipes of the user: one row for each recipe of the recipes file, with the
 * columns name, solutes (how many), kinds (`3 solute 1 polymer 2 custom 4 seq`), pH, σ
 * (blank for a recipe without) and notes (their titles, blank for none).
 *
 * There is no unsaved state: every edit writes the file at once and the rows are read
 * again from it. A template recipe (a `template` key: a shipped buffer, the user's own
 * buffer or a table of amounts, `store/template-recipes.ts`) adds a `template` column
 * (`builtin`, `custom`, `table`; `invalid` for a definition that cannot be used: the recipe
 * is read-only, Enter tells the problem and only deleting works); `shift+t` makes one (a
 * name, then the questions of `store/template-wizard.ts`, saved at once; its `solutes` are
 * the fixed rows). Keys: up and down move; Enter asks the recipe's name (prefilled: the
 * rename, written) and opens its solutes in a [[SolutesTable]] (its `^w` writes the
 * recipe, pH row `^g` and notes `shift+n` included); `^n` does the same for a new, empty
 * recipe (never past 999); `shift+n` opens the recipe's notes list ([[NotesList]], saved at
 * once); `^r` marks the recipe (`-`), `^u` unmarks, and `^w`, shown only while a mark
 * exists, asks `delete N recipes? this cannot be undone!` and removes the marked ones
 * from the file (the projects that loaded one keep their own buffer); `^x` goes back,
 * asking first while marks are pending. A name is not blank, at most 40 characters,
 * without control characters and unique among the other recipes (case does not matter,
 * a recipe may change only its case); a clash says `name in use`. A file that cannot be
 * used is told and left alone. A failed write is the note. The mechanics are
 * `useTableScreen`.
 *
 * @returns the screen.
 */
export function RecipesTable(): ReactNode {
    const nav = useNav()
    const root = appDir()
    const loaded = useMemo(() => loadRecipes(root), [root])
    const t = useTableScreen<Recipe>({
        adds: RECIPE_ADDS,
        rowKeys: RECIPE_ROW_KEYS,
        items: loaded.items,
        locked: loaded.locked,
        removeLabel: "delete",
        // every edit is written at once; `^w` only applies the marked removals (below)
        save: () => undefined,
        check: () => undefined,
        label: (recipe) => recipe.name,
        sorted: true,
    })
    const recipeOf = (r: Row<Recipe>) => rowValue(r) as Recipe
    const confirm = useConfirm()
    const marked = t.drafts.rows.filter((r) => r.removed)

    /**
     * Runs a write of the recipes file, then re-reads the file into the rows (a fresh
     * baseline for the next write; the marks pending stay on their recipes). A failure is
     * the screen's note.
     *
     * @returns whether it worked.
     */
    const written = (write: () => unknown): boolean => {
        try {
            write()
            const names = new Set(marked.map((r) => recipeOf(r).name))
            let next = Drafts.of(readRecipes(root, { track: true })).sorted((r) => r.name)
            next.rows.forEach((r, i) => {
                if (names.has(recipeOf(r).name)) next = next.remove(i)
            })
            t.adopt(next, false)
            return true
        } catch (error) {
            t.setNote(saveErrorNote(error))
            return false
        }
    }

    /** Opens the solutes of a recipe on top of this table; its `^w` writes the recipe. */
    const openSolutes = (recipe: Recipe) => {
        nav.push(
            <SolutesTable
                title={recipe.name}
                subtitle={RECIPE_SUBTITLE}
                items={recipe.solutes}
                conditions={recipeConditions(recipe)}
                notes={recipe.notes}
                onNotes={(notes) => {
                    const change = (r: Recipe) => withNotes(r, notes)
                    if (!written(() => updateRecipe(root, recipe.name, change)))
                        throw new Error("could not save the recipe")
                }}
                save={(rows, c) => {
                    // the notes are the recipe's own on disk: rows and conditions only
                    const change = (r: Recipe) => withConditions({ ...r, solutes: rows }, c)
                    if (!written(() => updateRecipe(root, recipe.name, change)))
                        throw new Error("could not save the recipe")
                }}
                idleNote={`${RECIPE_SUBTITLE}: ${recipe.name}`}
            />,
        )
    }

    /** Opens the notes list of a recipe; saving there writes the recipe at once. */
    const openNotes = (recipe: Recipe) => {
        nav.push(
            <NotesList
                owner={recipe.name}
                items={recipe.notes ?? []}
                onSave={(notes) => {
                    const change = (r: Recipe) => withNotes(r, notes)
                    if (!written(() => updateRecipe(root, recipe.name, change)))
                        throw new Error("could not save the recipe")
                }}
            />,
        )
    }

    /** The name was accepted: a new recipe, or the rename, written, then its solutes. */
    const accept = (name: string, target: Naming) => {
        const { index } = target
        const current = index === undefined ? undefined : (t.drafts.value(index) as Recipe)
        const write = () => {
            if (current === undefined) return saveRecipe(root, name, [])
            if (name === current.name) return undefined
            const bad = renameRecipe(root, current.name, name)
            if (bad !== undefined) throw new Error(bad)
            return undefined
        }
        if (!written(write)) return
        openSolutes({ ...(current ?? { solutes: [] }), name })
    }

    // `new template` asks the name like `new recipe`, then the wizard asks the rest;
    // `edit template` starts the wizard from the definition of the recipe under the cursor
    const making = useRef<string | undefined>(undefined)
    const editing = useRef<string | undefined>(undefined)
    const wizard = useTemplateWizard(
        (definition: Definition) => {
            const edit = editing.current
            editing.current = undefined
            if (edit !== undefined) {
                const change = (r: Recipe) => withTemplate(r, definition)
                if (written(() => updateRecipe(root, edit, change)))
                    t.setNote(`template "${edit}" changed`, false)
                return
            }
            const name = making.current as string
            making.current = undefined
            if (written(() => saveRecipe(root, name, [], undefined, undefined, definition)))
                t.setNote(`saved template "${name}"`, false)
        },
        (problem) => {
            const edit = editing.current
            making.current = undefined
            editing.current = undefined
            const what = edit === undefined ? "saved" : "changed"
            t.setNote(`template not ${what}: ${problem}`, true)
        },
    )
    /** Opens the wizard on the definition of a recipe (a bad one starts from nothing). */
    const editTemplate = (recipe: Recipe) => {
        if (recipe.template === undefined) {
            return t.setNote(`${recipe.name} is not a template (shift+t makes one)`, true)
        }
        editing.current = recipe.name
        making.current = undefined
        wizard.start(recipe.name, { initial: normalizeDefinition(recipe.template) })
    }
    const accepted = (name: string, target: Naming) => {
        if (making.current === "") {
            making.current = name
            wizard.start(name)
        } else accept(name, target)
    }

    const naming = useNamePrompt({
        label: "recipe name:",
        maxLength: MAX_NAME,
        check: (name, target) => {
            const others = t.drafts.rows.map((r) => ({ name: recipeOf(r).name }))
            return renameProblem(others, name, target.index)
        },
        accept: accepted,
    })

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        if (press.is(keys.save) && marked.length > 0 && !t.locked) {
            const names = marked.map((r) => recipeOf(r).name)
            const drop = () => {
                for (const n of names) if (!written(() => removeRecipe(root, n))) return
            }
            const question = destructiveQuestion(plural(names.length, "recipe"))
            return confirm.ask(question, drop)
        }
        if (t.handleKey(press)) return
        if (press.is(keys.enter) && t.canEdit && t.current) {
            const bad = templateOf(t.current)
            if (bad && "problem" in bad)
                // a template that cannot be used stays as it is: read-only, delete only
                t.setNote(`${t.current.name}: ${bad.problem}`, true)
            else naming.open(t.cursor.index, t.current.name)
        } else if (press.is(keys.addNonbio) && t.canAdd) {
            making.current = undefined
            naming.open(undefined, "")
        } else if (press.is(keys.newTemplate) && t.canAdd) {
            making.current = ""
            naming.open(undefined, "")
        } else if (press.is(keys.notesList) && t.canEdit && t.current) {
            openNotes(t.current)
        } else if (press.is(keys.editTemplate) && t.canEdit && t.current) {
            editTemplate(t.current)
        }
    }, naming.naming === undefined && !wizard.open)

    // the template column is there only while a
    // template recipe is: the rest keep their width
    const kindText = (r: Row<Recipe>) => {
        const kind = kindOf(recipeOf(r))
        return kind === "recipe" ? "" : kind
    }
    const kindColumn: Column<Row<Recipe>> = {
        title: "template",
        width: RECIPE_TEMPLATE_WIDTH,
        text: kindText,
    }
    const templateColumn = t.rows.some((r) => kindText(r) !== "") ? [kindColumn] : []
    const columns: Column<Row<Recipe>>[] = [
        { title: "name", grow: 3, text: (r) => recipeOf(r).name },
        {
            title: "solutes",
            width: SOLUTES_WIDTH,
            align: "right",
            text: (r) => String(recipeOf(r).solutes.length),
        },
        { title: "kinds", grow: 2, text: (r) => kindsSummary(recipeOf(r).solutes) },
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
        {
            title: "°C",
            width: RECIPE_TEMPERATURE_WIDTH,
            align: "right",
            text: (r) => {
                const temperature = recipeConditions(recipeOf(r))?.temperature
                return temperature === undefined ? "" : formatNumber(temperature)
            },
        },
        ...templateColumn,
        { title: "notes", grow: 3, text: (r) => notesCell(recipeOf(r).notes) },
    ]

    // only the keys that work now; the name prompt has its own keys while it is open
    const asked = confirm.question ? questionLegend(confirm.question) : undefined
    const typing = naming.naming ? naming.legend : (asked ?? t.legend(RECIPE_ADDS))
    const legend = wizard.open ? wizard.legend : typing
    // the prompt takes the rows under the table, so the window shrinks to keep the cursor
    const pageSize = wizard.open
        ? Math.max(3, t.pageSize - wizard.reserved)
        : naming.pageSize(t.pageSize)
    const offset = scrollWindow(t.cursor.index, t.cursor.offset, pageSize, t.rows.length)
    return (
        <Frame
            design="blocky"
            title="recipes"
            subtitle={marked.length > 0 ? `${marked.length} marked` : recipesFileName}
            legend={legend}
            legendFull={t.legendFull}
            note={naming.naming || wizard.open ? undefined : (confirm.note ?? t.frameNote)}
            noteIsError={confirm.question === undefined && t.frameNoteIsError}
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
            {t.finder}
            {naming.prompt}
            {wizard.entry}
        </Frame>
    )
}
