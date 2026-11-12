// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The flows built on a text prompt that more than one screen has: the path prompt with
 * the desktop's file picker (`usePathField`, `usePathPick`) and the name prompt under a
 * table (`useNamePrompt`). They live apart from `input.tsx` to keep that file in size;
 * the screens keep what is theirs: how a file is loaded and what a name does.
 */

import type { ReactNode } from "react"
import { useCallback, useState } from "react"
import { readSystem } from "../core/environment.js"
import { pick } from "../core/file-system.js"
import type { LegendItem } from "./grid.js"
import { PROMPT_ROWS, Prompt } from "./input.js"

/** The note while the picker window is open. */
export const PICKING_NOTE = "choose a file in the picker window..."

/**
 * The state of a [[PathPrompt]]: the text typed, the problem under it, the keys it
 * shows, and the key that remounts it to empty its field.
 *
 * @property typed - the text in the field.
 * @property problem - what is wrong with the text, `undefined` for nothing.
 * @property setProblem - sets (or clears) the problem.
 * @property fieldKey - the `key` of the prompt; [[resetField]] changes it.
 * @property promptKeys - the legend items the open prompt reports (`onLegend`).
 * @property setPromptKeys - takes them.
 * @property resetField - empties the field (remounts the prompt).
 * @property onChange - the prompt's `onChange`: keeps the text, drops the problem and
 *     calls `onEdit`.
 */
export type PathField = {
    typed: string
    problem: string | undefined
    setProblem: (problem: string | undefined) => void
    fieldKey: number
    promptKeys: LegendItem[]
    setPromptKeys: (keys: LegendItem[]) => void
    resetField: () => void
    onChange: (text: string) => void
}

/**
 * Keeps the state of a path prompt (see [[PathField]]).
 *
 * @param onEdit - what else a typed character does (clear the note of the screen); it
 *     should keep its identity.
 * @returns the [[PathField]].
 */
export function usePathField(onEdit?: () => void): PathField {
    const [typed, setTyped] = useState("")
    const [problem, setProblem] = useState<string | undefined>()
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
    // the prompt is remounted (a new key) to empty its field
    const [fieldKey, setFieldKey] = useState(0)
    const resetField = useCallback(() => {
        setTyped("")
        setFieldKey((k) => k + 1)
    }, [])
    const onChange = useCallback(
        (text: string) => {
            setTyped(text)
            setProblem(undefined)
            onEdit?.()
        },
        [onEdit],
    )
    return {
        typed,
        problem,
        setProblem,
        fieldKey,
        promptKeys,
        setPromptKeys,
        resetField,
        onChange,
    }
}

/**
 * What [[usePathPick]] needs of its screen.
 *
 * @property field - the state of the screen's path prompt.
 * @property load - reads the file at a path and says what is wrong with it
 *     (`undefined` on success).
 * @property say - puts a note up.
 * @property setMode - the screen's mode, for `picking` (the picker window is open, the
 *     screen's keys are off) and back to `path`.
 * @property leave - what the screen does after a successful load (back to its table).
 */
export type PathPickSpec = {
    field: PathField
    load: (path: string) => string | undefined
    say: (text: string, error?: boolean) => void
    setMode: (mode: "path" | "picking") => void
    leave: () => void
}

/**
 * The two ways a path prompt takes a file: Enter on the typed path and the desktop's
 * file picker. A path that cannot be loaded stays in the field with its problem; a file
 * that was picked and cannot be loaded is the note and the prompt opens again.
 *
 * @param spec - see [[PathPickSpec]].
 * @returns `submitPath` (the prompt's `onSubmit`) and `pickFile` (the hotkey's action).
 */
export function usePathPick(spec: PathPickSpec): {
    submitPath: (text: string) => void
    pickFile: () => Promise<void>
} {
    const { field, load, say, setMode, leave } = spec
    const submitPath = (text: string): void => {
        const bad = load(text.trim()) // a typed or pasted path may end in blanks
        if (bad !== undefined) {
            field.setProblem(bad)
            return
        }
        field.resetField()
        leave()
    }
    const pickFile = async (): Promise<void> => {
        setMode("picking")
        const result = await pick(readSystem(), readSystem().home, "data")
        if ("problem" in result) say(result.problem, true)
        else if (result.files[0] !== undefined) {
            const bad = load(result.files[0])
            if (bad !== undefined) say(bad, true)
            else {
                field.resetField()
                return leave()
            }
        } else say("nothing was picked")
        field.resetField()
        setMode("path")
    }
    return { submitPath, pickFile }
}

// ========================================================================================
// The name prompt under a table
// ========================================================================================

/** What the name prompt is for: the row it renames, `undefined` for a new entry. */
export type Naming = { index: number | undefined; initial: string }

/**
 * What [[useNamePrompt]] needs of its screen.
 *
 * @property label - the label of the prompt (`note title:`).
 * @property maxLength - the most characters a name may be typed with.
 * @property check - what is wrong with a (trimmed) name for that target, `undefined`
 *     when it is fine.
 * @property accept - what an accepted name does; the prompt is closed already.
 */
export type NamePromptSpec = {
    label: string
    maxLength: number
    check: (name: string, target: Naming) => string | undefined
    accept: (name: string, target: Naming) => void
}

/**
 * What [[useNamePrompt]] gives the screen.
 *
 * @property naming - the open prompt's target, `undefined` while it is closed (the
 *     screen's own keys act only then).
 * @property open - opens the prompt on a row (or a new entry) with a starting text.
 * @property legend - the keys of the open prompt.
 * @property pageSize - the rows the table may take: fewer while the prompt is open.
 * @property prompt - the prompt to draw under the table (`null` while closed).
 */
export type NamePrompt = {
    naming: Naming | undefined
    open: (index: number | undefined, initial: string) => void
    legend: LegendItem[]
    pageSize: (rows: number) => number
    prompt: ReactNode
}

/**
 * The name prompt under a table: opened on `^n` or a rename, it keeps its problem under
 * the field (dropped at the next typed character), reports its own keys as the legend and
 * takes the rows it needs from the table.
 *
 * @param spec - see [[NamePromptSpec]].
 * @returns the [[NamePrompt]].
 */
export function useNamePrompt(spec: NamePromptSpec): NamePrompt {
    const [naming, setNaming] = useState<Naming>()
    const [problem, setProblem] = useState<string>()
    // the keys of the open prompt
    const [legend, setLegend] = useState<LegendItem[]>([])
    // stable: a prompt reports its text again whenever this handler changes
    const clearProblem = useCallback(() => setProblem(undefined), [])
    const open = (index: number | undefined, initial: string): void => {
        setProblem(undefined)
        setNaming({ index, initial })
    }
    const submit = (text: string, target: Naming): void => {
        const name = text.trim()
        const bad = spec.check(name, target)
        if (bad !== undefined) {
            setProblem(bad)
            return
        }
        setNaming(undefined)
        spec.accept(name, target)
    }
    const prompt = naming ? (
        <Prompt
            label={spec.label}
            initial={naming.initial}
            maxLength={spec.maxLength}
            error={problem}
            onChange={clearProblem}
            onLegend={setLegend}
            onSubmit={(text) => submit(text, naming)}
            onCancel={() => setNaming(undefined)}
        />
    ) : null
    return {
        naming,
        open,
        legend,
        pageSize: (rows) => (naming ? Math.max(3, rows - PROMPT_ROWS) : rows),
        prompt,
    }
}
