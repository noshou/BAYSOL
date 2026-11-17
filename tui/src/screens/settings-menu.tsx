// SPDX-License-Identifier: LGPL-3.0-or-later

// The settings menu: the groups of settings and, for the global scope, the library files.

import { basename } from "node:path"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { appDir } from "../core/environment.js"
import { quarantine } from "../core/file-system.js"
import { truncateStart } from "../core/terminal.js"
import { readRecipes, recipesFile } from "../store/buffer.js"
import { customFile, readCustomSolutes } from "../store/custom.js"
import { type Scope, scopeTitle } from "../store/settings-store.js"
import { GridMenu, MenuHeader, MenuSpec } from "../ui/grid.js"
import { type Confirm, useConfirm } from "../ui/input.js"
import { type KeyInput, keys, useNav } from "../ui/interaction.js"
import { CustomSolutesTable, RecipesTable } from "./custom-solutes.js"
import { SettingsSheet } from "./settings-sheet.js"

/**
 * The four groups of settings, as a grid: output, model / sampler, plots. Exported so a
 * test can check the hotkeys.
 */
export const settingsMenuSpec = new MenuSpec(["output", "models", "sampler", "plots"], 2)

/**
 * The global settings menu: the four groups and, below them, the user's library, the
 * `recipes` (hotkey `y`) and the custom `solutes` (hotkey `t`). Exported so a test can
 * check the hotkeys.
 */
export const globalMenuSpec = new MenuSpec(
    ["output", "models", "sampler", "plots", "recipes", "solutes"],
    2,
)

/**
 * The groups of settings of ONE model, as a grid: the sheets of [[modelSheets]] (the
 * `plots` sheet and the run-level groups of `output` have nothing a model can change).
 * Exported so a test can check it against the catalog.
 */
export const modelMenuSpec = new MenuSpec(["output", "models", "sampler"], 2)

/**
 * The id of the sheet each option opens. Every option is the id of its sheet except
 * the model settings, which share the art (and the `m` hotkey) of `models`.
 */
const sheetOf = {
    output:  "output",
    models:  "model",
    sampler: "sampler",
    plots:   "plots",
} as const

/** The options of the global menu that open a file of the library, and its file. */
const libraryFiles = {
    recipes: (root: string) => recipesFile(root),
    solutes: (root: string) => customFile(root),
} as const

/**
 * The settings menu, for the global settings, those of one project or of one model. The
 * global one also has `recipes` and `solutes`, which open the recipes table and the
 * custom solutes table; if their file cannot be used `x` offers to reset it to empty
 * (the old file is kept as `<name>.corrupt`).
 *
 * @param scope - whose settings.
 * @returns the screen.
 */
export function SettingsMenu({ scope }: { scope: Scope }): ReactNode {
    const nav = useNav()
    const confirm = useConfirm()
    const [shownMessage, setShownMessage] = useState<{ text: string; error: boolean }>()
    const message = shownMessage?.text
    const setMessage = useCallback((text?: string, error = true) => {
        setShownMessage(text === undefined ? undefined : { text, error })
    }, [])
    // the files are read again whenever a table closes or a file is reset
    const [resets, setResets] = useState(0)
    const reset = useResetFile(confirm, setMessage, () => setResets((n) => n + 1))
    const root = appDir()
    const global = scope.kind === "global"
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const usable = useMemo(
        () => {
            if (!global) return { recipes: true, solutes: true }
            return {
                recipes: count(() => readRecipes(root)) !== "unusable",
                solutes: count(() => readCustomSolutes(root)) !== "unusable",
            }
        },
        [global, root, nav.depth, resets],
    )

    // the names of the options are the ids of the sheets of the settings catalog
    const choose = useCallback(
        (name: (typeof globalMenuSpec.names)[number]) => {
            if (name === "recipes") nav.push(<RecipesTable />)
            else if (name === "solutes") nav.push(<CustomSolutesTable />)
            else nav.push(<SettingsSheet scope={scope} sheetId={sheetOf[name]} />)
        },
        [nav, scope],
    )
    const onKey = useCallback(
        (press: KeyInput, selected: (typeof globalMenuSpec.names)[number]) => {
            if (selected !== "recipes" && selected !== "solutes") return
            setMessage(undefined)
            if (press.is(keys.reset) && !usable[selected]) {
                const file = libraryFiles[selected](root)
                reset(basename(file), () => quarantine(file))
            }
        },
        [usable, root, reset, setMessage],
    )

    if (scope.kind === "model")
        return (
            <GridMenu
                spec={modelMenuSpec}
                header={<MenuHeader caption={`model: ${scope.model}`} />}
                onChoose={choose}
            />
        )
    if (!global)
        return (
            <GridMenu
                spec={settingsMenuSpec}
                header={<MenuHeader caption={scopeTitle(scope)} />}
                onChoose={choose}
            />
        )
    const question = confirm.question
    const legend = (selected: (typeof globalMenuSpec.names)[number]) => {
        if (question) {
            const { yes, no } = question
            return `${yes}: ${keys.enter.label}  ${no}: ${keys.escape.label}`
        }
        const onLibrary = selected === "recipes" || selected === "solutes"
        if (!onLibrary || usable[selected]) return undefined
        return `reset file: ${keys.reset.label}`
    }
    return (
        <GridMenu
            spec={globalMenuSpec}
            header={<MenuHeader caption={scopeTitle(scope)} />}
            onChoose={choose}
            onKey={onKey}
            intercept={confirm.handleKey}
            notice={confirm.note ?? message}
            noticeIsError={confirm.note === undefined && shownMessage?.error === true}
            legend={legend}
        />
    )
}

// ========================================================================================
// Shared with the landings: the library files
// ========================================================================================

/** How many rows a file holds, or that it cannot be used. */
export type FileCount = number | "unusable"

/** The rows a file holds: their number, `"unusable"` if reading throws. */
export function count(read: () => readonly unknown[]): FileCount {
    try {
        return read().length
    } catch {
        return "unusable"
    }
}

/** What a landing says of a file under a plain label: `buffer: 3 solutes`, `none yet`. */
export function fileStatus(label: string, n: FileCount, word: string): string {
    if (n === "unusable") return `${label}: unusable!`
    return n === 0 ? `${label}: none yet` : `${label}: ${n} ${word}${n === 1 ? "" : "s"}`
}

/**
 * The reset of a file that cannot be used: `ask(file, reset)` asks, and on Enter runs
 * `reset` (the old file is kept as `<name>.corrupt`), then re-reads the counts.
 */
export function useResetFile(
    confirm: Confirm,
    setMessage: (text: string, error: boolean) => void,
    reread: () => void,
): (name: string, reset: () => void) => void {
    return (name, reset) =>
        confirm.ask(
            {
                text: `reset ${name}? the old one is kept as .corrupt`,
                yes: "reset",
                no: "keep",
            },
            () => {
                try {
                    reset()
                    reread()
                    setMessage(`${name} reset; old one kept as .corrupt`, false)
                } catch {
                    setMessage("could not reset!", true)
                }
            },
        )
}

/** For a file that cannot be used: where it is and what can be done. */
export const unusableHint = (file: string, columns: number): string =>
    `${truncateStart(file, Math.max(10, columns - 24))}  ${keys.reset.label}: reset`
