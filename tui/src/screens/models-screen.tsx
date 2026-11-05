// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import { Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { readSystem } from "../core/system.js"
import { truncate } from "../core/text.js"
import {
    type AddResult,
    addModel,
    addModels,
    complete,
    copyFailed,
    deleteModel,
    hints,
    listModels,
    pathProblem,
} from "../store/models.js"
import type { ProjectRef } from "../store/scope.js"
import { pick } from "../system/file-picker.js"
import { Dropdown, filterChoices } from "../ui/dropdown.js"
import { Frame } from "../ui/frame.js"
import { KeyInput, keys } from "../ui/keys.js"
import { type LegendItem, legendBack, legendQuit } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { Prompt } from "../ui/prompt.js"
import { useConfirm } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"

/** The most characters a path may be typed with. */
export const maxTypedPath = 300

/** The longest model name the deletion question shows whole, so its keys stay in view. */
const questionNameWidth = 24

/**
 * The question asked before a model is deleted, short so that the keys at its end are
 * never cut off by the note line.
 *
 * @param modelName - the model.
 * @returns the text for the note line.
 */
export function deleteQuestion(modelName: string): string {
    const name = truncate(modelName, questionNameWidth)
    return `remove ${name}? destructive, keep a backup!  enter: delete  esc: keep`
}

/**
 * The note to tell about the result of adding picked files: how many were copied and,
 * if any were skipped, how many and why (the first reason).
 *
 * @param result - what [[addModels]] returned.
 * @returns the text.
 */
export function pickNote(result: AddResult): string {
    const { copied, skipped } = result
    const copiedText =
        copied.length === 1 ? `copied ${copied[0]}` : `copied ${copied.length} files`
    if (copied.length === 0 && skipped.length === 0) return "nothing was picked"
    if (skipped.length === 0) return copiedText
    const first = skipped[0]?.[1] ?? ""
    const lead = copied.length > 0 ? `${copiedText}, ` : ""
    return `${lead}skipped ${skipped.length}: ${first}`
}

/**
 * The suggestions of the path prompt: the folder's names that fit what is typed. Each
 * is shown by its name; Tab puts the whole completed path into the field. A folder
 * that cannot be listed gives none.
 *
 * @param text - the path typed.
 * @returns the suggestions, folders first.
 */
export function pathSuggestions(text: string): { label: string; completion: string }[] {
    try {
        return hints(text).map((hint) => ({
            label: hint,
            completion: complete(text, hint),
        }))
    } catch {
        return []
    }
}

/** The hotkeys of the empty field: pick files with the desktop picker, open the list. */
const hotkeyPick = new KeyInput("o")
const hotkeyModels = new KeyInput("m")

/** The note while the picker window is open. */
const pickingNote = "choose files in the picker window..."

/** The legend entry that opens the list, with how many models there are. */
const modelsLegend = (count: number): LegendItem => ({
    label: `models (${count})`,
    keys: "m",
})

/** What the screen does: asks for a path, lists the models, or waits for the picker. */
type Mode = "prompt" | "list" | "picking"

/**
 * The models of a project: a prompt for the full absolute path of a `.cif` or `.pdb`
 * file, which is COPIED into the project's `models/` folder (the original is never
 * touched) and the prompt stays for the next one. With nothing typed `o` opens the
 * desktop's file picker and `m` the list of the models, where `^r` asks and then
 * deletes one.
 *
 * @param project - the project whose models these are.
 * @returns the screen.
 */
export function ModelsScreen({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const confirm = useConfirm()
    const [mode, setMode] = useState<Mode>("prompt")
    const [typed, setTyped] = useState("")
    const [problem, setProblem] = useState<string | undefined>()
    const [note, setNote] = useState<string | undefined>()
    // the model the list highlights, which ^r asks about
    const [highlighted, setHighlighted] = useState<string | undefined>()
    // the prompt is remounted (a new key) to empty its field: the keys `o` and `m` are
    // typed into it by the time the screen has seen them, and a copied path is cleared
    const [fieldKey, setFieldKey] = useState(0)
    // bumped when the folder changes, so the lists below are read again
    const [version, setVersion] = useState(0)
    // biome-ignore lint/correctness/useExhaustiveDependencies: version = folder changed
    const names = useMemo(() => listModels(project.dir), [project.dir, version])

    const resetField = useCallback(() => {
        setTyped("")
        setFieldKey((k) => k + 1)
    }, [])
    const onChange = useCallback((text: string) => {
        setTyped(text)
        setProblem(undefined)
        setNote(undefined)
    }, [])

    const pickFiles = useCallback(async () => {
        setMode("picking")
        const result = await pick(readSystem(), readSystem().home)
        if ("problem" in result) setNote(result.problem)
        else setNote(pickNote(addModels(project.dir, result.files)))
        setVersion((v) => v + 1)
        resetField()
        setMode("prompt")
    }, [project.dir, resetField])

    // the hotkeys act only while the field is empty (an absolute path starts with a
    // slash, so they cannot be part of one); the prompt's own handler does the rest
    useKeys((press: KeyInput) => {
        if (typed !== "") return
        if (press.is(hotkeyPick)) void pickFiles()
        else if (press.is(hotkeyModels) && names.length > 0) {
            resetField()
            setNote(undefined)
            setMode("list")
        }
    }, mode === "prompt")

    const remove = useCallback((name: string) => {
        confirm.ask(deleteQuestion(name), () => {
            deleteModel(project.dir, name)
            const left = listModels(project.dir)
            setVersion((v) => v + 1)
            if (left.length === 0) setMode("prompt") // the last one closes the list
        })
    }, [confirm.ask, project.dir])

    // the list is not drawn while a deletion is asked (it would take Esc as well), so
    // the question is answered here; ^r in the list opens it
    useKeys((press) => {
        if (confirm.handleKey(press)) return
        if (press.is(keys.remove) && highlighted !== undefined) remove(highlighted)
    }, mode === "list")

    const submit = useCallback((text: string) => {
        const path = text.trim() // a typed or pasted path may end in blanks or a newline
        const bad = pathProblem(path, names)
        if (bad !== undefined) return setProblem(bad)
        try {
            addModel(project.dir, path)
        } catch {
            return setProblem(copyFailed)
        }
        setVersion((v) => v + 1)
        setNote(`copied ${basename(path)}`)
        resetField()
    }, [names, project.dir, resetField])

    // every model matching the typed text, all of them for a blank text
    const search = useMemo(
        () => filterChoices(names.map((name) => ({ label: name, value: name }))),
        [names],
    )

    const legend: LegendItem[] =
        mode === "list" && confirm.question !== undefined
            ? [{ label: "delete", keys: "⏎" }, { label: "keep it", keys: "esc" }]
            : mode === "list"
              ? [
                    { label: "remove", keys: "^r" },
                    { label: "move", keys: "↑↓" },
                    { label: "close", keys: "esc" },
                    legendBack,
                ]
            : mode === "picking"
              ? []
              : typed === ""
                ? [
                      { label: "pick files", keys: "o" },
                      ...(names.length > 0 ? [modelsLegend(names.length)] : []),
                      { label: "copy", keys: "⏎" },
                      legendQuit,
                      legendBack,
                  ]
                : [
                      { label: "complete", keys: "tab" },
                      { label: "copy", keys: "⏎" },
                      legendQuit,
                      legendBack,
                  ]

    const frameNote =
        mode === "list" ? confirm.question : mode === "picking" ? pickingNote : note
    return (
        <Frame
            title="models"
            subtitle={project.id}
            legend={legend}
            note={frameNote}
            noteIsError={false}
        >
            {mode === "prompt" ? (
                <>
                    <Prompt
                        key={fieldKey}
                        label="path:"
                        maxLength={maxTypedPath}
                        placeholder="full absolute path of a .cif or .pdb file"
                        suggest={pathSuggestions}
                        error={problem}
                        onSubmit={submit}
                        onCancel={nav.quit}
                        onBack={nav.pop}
                        onChange={onChange}
                    />
                    {names.length === 0 ? <Text dimColor>no models yet!</Text> : null}
                </>
            ) : null}
            {mode === "list" && confirm.question === undefined ? (
                <Dropdown<string>
                    label="find:"
                    search={search}
                    noMatch="no match"
                    onPick={() => {}} // a model that is picked is not used for anything
                    onCancel={() => setMode("prompt")}
                    onBack={nav.pop}
                    onHighlight={setHighlighted}
                />
            ) : null}
            {mode === "list" && confirm.question !== undefined ? (
                <Text>{highlighted}</Text>
            ) : null}
        </Frame>
    )
}

