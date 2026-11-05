// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import { Box, Text } from "ink"
import { type ReactNode, useMemo, useState } from "react"
import { quarantine } from "../core/files.js"
import { appDir } from "../core/paths.js"
import { truncateStart } from "../core/text.js"
import { customFile, readSolutes } from "../store/custom-store.js"
import { readRecipes, recipesFile } from "../store/recipe-store.js"
import { Frame } from "../ui/frame.js"
import { keys } from "../ui/keys.js"
import { useBodyColumns } from "../ui/layout.js"
import { legendBack, legendEnter, legendMove, legendQuit } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { useTheme } from "../ui/theme.js"
import { useConfirm } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"
import { useListCursor } from "../ui/use-list-cursor.js"
import { CustomSolutesTable } from "./custom-solutes-table.js"
import { type FileCount, fileStatus, landingOptions } from "./custom-text.js"
import { RecipesTable } from "./recipes-table.js"

/** The two options, in order: which file each one is about. */
const OPTIONS = ["recipes", "solutes"] as const

/** The key that offers to reset a file that cannot be used. */
const RESET_KEY = "r"

/**
 * How many rows a file holds.
 *
 * @param read - reads the file's rows.
 * @returns their number, `"unusable"` if the file cannot be used.
 */
function count(read: () => readonly unknown[]): FileCount {
    try {
        return read().length
    } catch {
        return "unusable"
    }
}

/**
 * The landing of the user's library, opened by Ctrl-E in the global settings menu: the
 * two options `recipes (N)` and `solutes (N)` open the table of the saved recipes and
 * the table of the custom solutes, and a line says what each file holds. A file that
 * cannot be used shows `?` and `unusable!`, still opens (its table says so and edits
 * nothing), and `r` on it offers to reset it to empty, the old file kept beside it as
 * `<name>.corrupt`.
 *
 * Keys: up and down move, Enter opens, Ctrl-X goes back, Esc quits.
 *
 * @returns the screen.
 */
export function CustomLanding(): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    const cursor = useListCursor(OPTIONS.length, OPTIONS.length)
    const confirm = useConfirm()
    const [message, setMessage] = useState<string | undefined>(undefined)
    // the counts are read again whenever a table closes or a file is reset
    const [resets, setResets] = useState(0)
    const root = appDir()
    const files = [recipesFile(root), customFile(root)] as const
    const names = files.map((f) => basename(f))

    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const counts = useMemo(
        () => [
            count(() => readRecipes(root)),
            count(() => readSolutes(root)),
        ],
        [root, nav.depth, resets],
    )
    const [recipes, solutes] = counts as [FileCount, FileCount]
    const labels = landingOptions(recipes, solutes)
    const status = [
        fileStatus(names[0] as string, recipes, "recipe"),
        fileStatus(names[1] as string, solutes, "solute"),
    ].join("  ")

    const on = cursor.index
    const unusable = counts[on] === "unusable"
    const file = files[on] as string
    const fileName = names[on] as string

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        setMessage(undefined)
        if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.escape)) nav.quit()
        else if (press.is(keys.enter)) {
            nav.push(on === 0 ? <RecipesTable /> : <CustomSolutesTable />)
        } else if (unusable && press.key_ === RESET_KEY && !press.ctrl) {
            confirm.ask(
                `reset ${fileName} to empty?  the old file is kept as ${fileName}.corrupt` +
                    "  enter: reset  esc: keep",
                () => {
                    try {
                        quarantine(file)
                        setResets((n) => n + 1)
                        setMessage(`${fileName} reset, kept as ${fileName}.corrupt`)
                    } catch {
                        setMessage("could not reset!")
                    }
                },
            )
        }
    })

    // for a file that cannot be used: where it is and what can be done
    const hint = unusable
        ? `${truncateStart(file, Math.max(10, columns - 24))}  ${RESET_KEY}: reset`
        : undefined
    return (
        <Frame
            title="custom solutes and recipes"
            legend={[legendMove, legendEnter, legendBack, legendQuit]}
            note={confirm.question ?? message}
        >
            <Box flexDirection="column">
                {labels.map((label, i) => (
                    <Text
                        key={label}
                        color={i === on ? theme.fg : theme.mt}
                        bold={i === on}
                    >
                        {`${i === on ? ">" : " "} ${label}`}
                    </Text>
                ))}
            </Box>
            <Box flexDirection="column" marginTop={1}>
                <Text color={theme.mt}>{status}</Text>
                {hint ? <Text color={theme.er}>{hint}</Text> : null}
            </Box>
        </Frame>
    )
}
