// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { UnusableFileError } from "../core/files.js"
import { appDir } from "../core/paths.js"
import { truncateStart } from "../core/text.js"
import {
    type BufferRow,
    bufferFile,
    bufferFileName,
    readSolutes,
    resetBuffer,
    writeSolutes,
} from "../store/buffer.js"
import { MAX_ROWS } from "../store/limits.js"
import {
    indexOfName,
    MAX_NAME,
    nameProblem,
    type Recipe,
    readRecipes,
    recipesFileName,
    saveRecipe,
} from "../store/recipe-store.js"
import type { ProjectRef } from "../store/scope.js"
import { type Choice, Dropdown, filterChoices } from "../ui/dropdown.js"
import { Frame } from "../ui/frame.js"
import { keys } from "../ui/keys.js"
import { useBodyColumns } from "../ui/layout.js"
import {
    type LegendItem,
    legendBack,
    legendEnter,
    legendMove,
    legendQuit,
} from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { Prompt } from "../ui/prompt.js"
import { useTheme } from "../ui/theme.js"
import { useConfirm } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"
import { useListCursor } from "../ui/use-list-cursor.js"
import {
    bufferStatus,
    COULD_NOT_SAVE,
    landingOptions,
    NO_RECIPES,
    NOT_SAVED,
    NOTHING_REPLACED_HINT,
    REPLACES_HINT,
    recipeChoice,
    replaceRecipeQuestion,
    savedAs,
    TOO_MANY_RECIPES,
    unusable,
} from "./buffer-text.js"
import type { FileCount } from "./custom-text.js"
import { SolutesTable } from "./solutes-table.js"

/** The key that offers to reset a buffer file that cannot be used. */
const RESET_KEY = "r"

/** What the landing is doing: waiting for a choice, picking a recipe, asking a name. */
type Mode = "menu" | "load" | "save"

/** The title of the project's solutes table. */
const BUFFER_TITLE = "buffer"

/**
 * How many solutes the buffer holds.
 *
 * @param dir - the project's folder.
 * @returns their number, `"unusable"` if the file cannot be used.
 */
function countSolutes(dir: string): FileCount {
    try {
        return readSolutes(dir).length
    } catch {
        return "unusable"
    }
}

/**
 * What a failed save was about, for the message.
 *
 * @param error - what was thrown.
 * @returns `buffer.json unusable!`, `recipes.json unusable!` or `could not save!`.
 */
function saveFailure(error: unknown): string {
    if (error instanceof UnusableFileError) {
        if (error.kind === "buffer") return unusable(bufferFileName)
        if (error.kind === "recipes") return unusable(recipesFileName)
    }
    return COULD_NOT_SAVE
}

/**
 * The landing of the buffer of a project: what to do with the project's recipe, which is
 * its buffer file, before the table of its solutes opens. The options, each only when it
 * applies:
 *
 * - `edit current recipe (N solutes)`, when the buffer has solutes: its table.
 * - `load a recipe`: a dropdown of the saved recipes with their solute counts, then the
 *   table with the recipe's rows as unsaved ones; at the first `^w` a buffer that has
 *   solutes asks `replace N solutes with recipe "NAME"?`. `no saved recipes!` for none.
 * - `new recipe`: the table, empty; nothing is replaced before `^w`.
 * - `save current recipe globally`, when the buffer has solutes: asks a name (`replace
 *   "NAME"?` if a recipe has it) and saves the buffer as it is on disk as a recipe.
 *
 * A line says what the file holds (`buffer.json: 12 solutes`, `none yet`, `unusable!`).
 * A file that cannot be used is told and never written over; `r` on it offers to move it
 * to `<name>.corrupt` and start empty.
 *
 * Keys: up and down move, Enter does it, `^x` goes back, Esc quits.
 *
 * @param props - the project.
 * @returns the screen.
 */
export function BufferLanding({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    const confirm = useConfirm()
    const [mode, setMode] = useState<Mode>("menu")
    const [message, setMessage] = useState<string | undefined>(undefined)
    const [problem, setProblem] = useState<string | undefined>(undefined)
    const [recipes, setRecipes] = useState<Recipe[]>([])
    // the count is read again whenever a table closes or the file is reset
    const [resets, setResets] = useState(0)
    const root = appDir()
    const dir = project.dir
    const file = bufferFileName

    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const count = useMemo(() => countSolutes(dir), [dir, nav.depth, resets])
    const options = landingOptions(count)
    const cursor = useListCursor(options.length, options.length)
    const solutes = typeof count === "number" ? count : 0
    const room = columns - 4

    /** Opens the table of the buffer: its rows, or a recipe's as unsaved ones. */
    const openTable = (extra: {
        items?: readonly BufferRow[]
        drafts?: readonly BufferRow[]
        hint?: string
        replace?: { count: number; recipe: string }
    }) => {
        nav.push(
            <SolutesTable
                title={BUFFER_TITLE}
                subtitle={project.id}
                items={extra.items ?? []}
                drafts={extra.drafts}
                hint={extra.hint}
                replace={extra.replace}
                save={(rows) => void writeSolutes(dir, rows)}
            />,
        )
    }

    const pickRecipe = (recipe: Recipe) => {
        setMode("menu")
        openTable({
            drafts: recipe.solutes,
            hint: solutes > 0 ? REPLACES_HINT : undefined,
            replace: solutes > 0 ? { count: solutes, recipe: recipe.name } : undefined,
        })
    }

    /** Writes the buffer as it is on disk as the recipe `name`. */
    const doSave = (name: string) => {
        try {
            saveRecipe(root, name, readSolutes(dir))
            setMessage(savedAs(name, room))
        } catch (error) {
            setMessage(saveFailure(error))
        }
    }

    const submitName = (text: string) => {
        const name = text.trim()
        const bad = nameProblem(name)
        if (bad !== undefined) return setProblem(bad)
        let saved: Recipe[]
        try {
            saved = readRecipes(root)
        } catch {
            setMode("menu")
            return setMessage(unusable(recipesFileName))
        }
        setMode("menu")
        if (indexOfName(saved, name) !== undefined) {
            confirm.ask(replaceRecipeQuestion(name, room), () => doSave(name))
        } else if (saved.length >= MAX_ROWS) setMessage(TOO_MANY_RECIPES)
        else doSave(name)
    }

    const choose = (id: ReturnType<typeof landingOptions>[number]["id"]) => {
        if (id === "edit") {
            try {
                openTable({ items: readSolutes(dir) })
            } catch {
                setMessage(unusable(file))
            }
        } else if (id === "new") {
            if (count === "unusable") return setMessage(unusable(file))
            openTable({ hint: solutes > 0 ? NOTHING_REPLACED_HINT : undefined })
        } else if (id === "load") {
            if (count === "unusable") return setMessage(unusable(file))
            try {
                const saved = readRecipes(root)
                if (saved.length === 0) return setMessage(NO_RECIPES)
                setRecipes(saved)
                setMode("load")
            } catch {
                setMessage(unusable(recipesFileName))
            }
        } else {
            setProblem(undefined)
            setMode("save")
        }
    }

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        setMessage(undefined)
        if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.escape)) nav.quit()
        else if (press.is(keys.enter)) {
            const option = options[cursor.index]
            if (option) choose(option.id)
        } else if (count === "unusable" && press.key_ === RESET_KEY && !press.ctrl) {
            confirm.ask(
                `reset ${file} to empty?  the old file is kept as ${file}.corrupt` +
                    "  enter: reset  esc: keep",
                () => {
                    try {
                        resetBuffer(dir)
                        setResets((n) => n + 1)
                        setMessage(`${file} reset, kept as ${file}.corrupt`)
                    } catch {
                        setMessage("could not reset!")
                    }
                },
            )
        }
    }, mode === "menu")

    // the dropdown lists every recipe with its solute count; the choice is the recipe
    const choices = useMemo<Choice<Recipe>[]>(
        () =>
            recipes.map((r) => ({
                label: recipeChoice(r.name, r.solutes.length),
                value: r,
            })),
        [recipes],
    )
    const search = useMemo(() => filterChoices(choices), [choices])
    const onClear = useCallback(() => setProblem(undefined), [])

    // for a file that cannot be used: where it is and what can be done
    const hint =
        count === "unusable"
            ? `${truncateStart(bufferFile(dir), Math.max(10, columns - 24))}  ` +
              `${RESET_KEY}: reset`
            : undefined
    const legend: LegendItem[] =
        mode === "menu"
            ? [legendMove, legendEnter, legendBack, legendQuit]
            : [
                  { label: "take", keys: "⏎" },
                  { label: "cancel", keys: "esc" },
              ]
    return (
        <Frame
            title="buffer"
            subtitle={project.id}
            legend={legend}
            note={confirm.question ?? message}
        >
            <Box flexDirection="column">
                {options.map((o, i) => (
                    <Text
                        key={o.id}
                        color={i === cursor.index && mode === "menu" ? theme.fg : theme.mt}
                        bold={i === cursor.index && mode === "menu"}
                    >
                        {`${i === cursor.index ? ">" : " "} ${o.label}`}
                    </Text>
                ))}
            </Box>
            <Box flexDirection="column" marginTop={1}>
                <Text color={theme.mt}>{bufferStatus(file, count)}</Text>
                {hint ? <Text color={theme.er}>{hint}</Text> : null}
            </Box>
            {mode === "load" ? (
                <Box marginTop={1}>
                    <Dropdown<Recipe>
                        label="load a recipe:"
                        search={search}
                        noMatch="no match"
                        onPick={pickRecipe}
                        onCancel={() => setMode("menu")}
                    />
                </Box>
            ) : null}
            {mode === "save" ? (
                <Box marginTop={1}>
                    <Prompt
                        label="save as:"
                        maxLength={MAX_NAME}
                        error={problem}
                        onChange={onClear}
                        onSubmit={submitName}
                        onCancel={() => {
                            setMode("menu")
                            setMessage(NOT_SAVED)
                        }}
                    />
                </Box>
            ) : null}
        </Frame>
    )
}
