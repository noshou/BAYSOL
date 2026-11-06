// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { appDir } from "../core/paths.js"
import { type Row, rowValue } from "../store/draft.js"
import {
    kindsSummary,
    MAX_NAME,
    type Recipe,
    readRecipes,
    recipesFile,
    removeRecipe,
    renameProblem,
    writeRecipes,
} from "../store/recipe-store.js"
import { type Column, DataTable } from "../ui/data-table.js"
import { Frame } from "../ui/frame.js"
import { keys } from "../ui/keys.js"
import { type LegendItem, legendFor } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { Prompt } from "../ui/prompt.js"
import { scrollWindow } from "../ui/scroll-window.js"
import { useKeys } from "../ui/use-keys.js"
import { unusable } from "./buffer-text.js"
import { SolutesTable } from "./solutes-table.js"
import { useTableScreen } from "./use-table-screen.js"

/** What the empty table says. */
const EMPTY_HINT = `none: ${keys.addNonbio.label} adds`

/** The rows the name prompt takes under the table: the field and its error. */
const PROMPT_ROWS = 3

/** The subtitle of the table of one recipe's solutes. */
const RECIPE_SUBTITLE = "recipe"

/**
 * Loads the recipes of the BAYSOL folder once.
 *
 * @param root - the BAYSOL data folder.
 * @returns the recipes, or none and a `locked` message for a file that cannot be used.
 */
function load(root: string): { items: Recipe[]; locked?: string } {
    try {
        return { items: readRecipes(root, { track: true }) }
    } catch {
        return { items: [], locked: unusable(basename(recipesFile(root))) }
    }
}

/**
 * The columns of the table: name, how many solutes, and what kinds.
 *
 * @returns the columns.
 */
function columns(): Column<Row<Recipe>>[] {
    const recipe = (r: Row<Recipe>) => rowValue(r) as Recipe
    return [
        { title: "name", grow: 3, text: (r) => recipe(r).name },
        {
            title: "solutes",
            grow: 1,
            align: "right",
            text: (r) => String(recipe(r).solutes.length),
        },
        { title: "kinds", grow: 4, text: (r) => kindsSummary(recipe(r).solutes) },
    ]
}

/** What the name prompt is for: the row it renames, `undefined` for a new recipe. */
type Naming = { index: number | undefined; initial: string }

/**
 * The saved recipes of the user: one row for each recipe of the recipes file, with the
 * columns name, solutes (how many) and kinds (`3 solute 1 polymer 2 custom 4 seq`). A
 * row that is new or changed shows `*`; nothing of that is written before `^w`.
 *
 * Keys: up and down move; Enter asks the recipe's name (prefilled) and then opens its
 * solutes in a [[SolutesTable]]; `^n` does the same for a new, empty recipe (never past
 * 999); `^r` on a saved row asks `delete recipe NAME? ...` and Enter deletes it from the
 * file at once (the projects that loaded it keep their own buffer; a row never saved just
 * goes); `^u` undoes its last edit; `^w` saves the list; `^x` goes back,
 * asking first when something is unsaved. A name is not blank, at most 40
 * characters, without control characters and unique among the other recipes (case does
 * not matter, a recipe may change only its case); a clash says `name in use`. A file that
 * cannot be used is told and left alone. The mechanics are `useTableScreen`.
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
    const loaded = useMemo(() => load(root), [root])
    const t = useTableScreen<Recipe>({
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
    const [naming, setNaming] = useState<Naming | undefined>(undefined)
    const [problem, setProblem] = useState<string | undefined>(undefined)
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
                save={(rows) => t.replaceAt(index, { ...recipe, solutes: rows })}
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

    // only the keys that work now; the name prompt has its own keys while it is open
    const legend = naming
        ? nameKeys
        : t.legend([legendFor("new recipe", keys.addNonbio)])

    // the prompt takes the rows under the table, so the window shrinks to keep the cursor
    const pageSize = naming ? Math.max(3, t.pageSize - PROMPT_ROWS) : t.pageSize
    const offset = scrollWindow(t.cursor.index, t.cursor.offset, pageSize, t.rows.length)
    const changes = t.drafts.count
    return (
        <Frame
            title="recipes"
            subtitle={changes > 0 ? `${changes} unsaved` : basename(recipesFile(root))}
            legend={legend}
            note={naming ? undefined : t.frameNote}
            noteIsError={t.frameNoteIsError}
        >
            <DataTable
                columns={columns()}
                rows={t.rows}
                cursor={t.cursor.index}
                offset={offset}
                pageSize={pageSize}
                mark={t.mark}
                empty={t.locked ? "" : EMPTY_HINT}
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
