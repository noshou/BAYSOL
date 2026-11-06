// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import { Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { pick } from "../core/file-picker.js"
import { readSystem } from "../core/system.js"
import {
    type AddResult,
    accepted,
    addModel,
    addModels,
    copyFailed,
    deleteModel,
    listModels,
    modelPathProblem,
} from "../store/models.js"
import { MAX_PATH_TYPED, pathSuggestions } from "../store/path-input.js"
import type { ProjectRef } from "../store/scope.js"
import type { Choice } from "../ui/dropdown.js"
import { Frame } from "../ui/frame.js"
import { type KeyInput, keys } from "../ui/keys.js"
import { type LegendItem, legendFor, legendOf } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { usePickList } from "../ui/pick-list.js"
import { Prompt } from "../ui/prompt.js"
import { destructiveQuestion } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"

/** What Esc does at the path prompt: nothing (the prompt is the screen; `^x` goes back). */
const nothing = (): void => {}

/** The most characters a path may be typed with. */

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

/** The suggestions of the path prompt: folders and structure files. */
const suggestModelPaths = (text: string) => pathSuggestions(text, accepted)

/** The note while the picker window is open. */
const pickingNote = "choose files in the picker window..."

/** The legend entry that opens the list, with how many models there are. */
const modelsLegend = (count: number): LegendItem =>
    legendFor(`models (${count})`, keys.openList)

/** What the screen does: asks for a path, lists the models, or waits for the picker. */
type Mode = "prompt" | "list" | "picking"

/**
 * The models of a project: a prompt for the full absolute path of a `.cif` or `.pdb`
 * file, which is COPIED into the project's `models/` folder (the original is never
 * touched) and the prompt stays for the next one. With nothing typed `o` opens the
 * desktop's file picker and `m` the list of the models, where `^r` asks and then
 * deletes the highlighted one at once; `^r` on the empty field opens the list with that
 * question already asked about the first model.
 *
 * @param project - the project whose models these are.
 * @returns the screen.
 */
export function ModelsScreen({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const [mode, setMode] = useState<Mode>("prompt")
    const [typed, setTyped] = useState("")
    const [problem, setProblem] = useState<string | undefined>()
    const [note, setNote] = useState<string | undefined>()
    // the keys of the open path prompt, which knows how many names it hints
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
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
        if (press.is(keys.pickFiles)) void pickFiles()
        else if (
            (press.is(keys.openList) || press.is(keys.remove)) &&
            names.length > 0
        ) {
            // `^r` opens the list too (to choose what to delete there), like `m`
            resetField()
            setNote(undefined)
            setMode("list")
        }
    }, mode === "prompt")

    // every model matching the typed text, all of them for a blank text; ^r asks about
    // the highlighted one and Enter deletes it, the last one closes the list
    const entries = useMemo<Choice<string>[]>(
        () => names.map((name) => ({ label: name, value: name })),
        [names],
    )
    const closeList = useCallback(() => setMode("prompt"), [])
    const pickList = usePickList<string>({
        open: mode === "list",
        label: "find:",
        entries,
        take: null, // a model that is picked is not used for anything
        cancel: "close",
        onPick: () => {},
        onCancel: closeList,
        onBack: nav.pop,
        question: (name) => destructiveQuestion(`model ${name}`),
        onDelete: (name) => {
            deleteModel(project.dir, name)
            setVersion((v) => v + 1)
        },
        onFail: (e) => setNote((e as Error).message),
        onEmpty: closeList,
    })

    const submit = useCallback((text: string) => {
        const path = text.trim() // a typed or pasted path may end in blanks or a newline
        const bad = modelPathProblem(path, names)
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

    // only the keys that work now. The list shows its own (remove only with a model
    // highlighted, move only for several, tab only with one highlighted) or the answers
    // to the delete question; the prompt shows tab only while it hints a name, copy only
    // once something is typed, and the hotkeys only while the field is empty.
    const editLegend = legendOf([
        typed === "" && legendFor("pick files", keys.pickFiles),
        typed === "" && names.length > 0 && modelsLegend(names.length),
        typed === "" && names.length > 0 && legendFor("delete", keys.remove),
        ...promptKeys,
    ])
    const legend: LegendItem[] =
        mode === "list" ? pickList.legend : mode === "picking" ? [] : editLegend

    const frameNote =
        mode === "list" ? pickList.note : mode === "picking" ? pickingNote : note
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
                        maxLength={MAX_PATH_TYPED}
                        placeholder="full absolute path of a .cif or .pdb file"
                        suggest={suggestModelPaths}
                        error={problem}
                        onSubmit={submit}
                        onCancel={nothing}
                        onBack={nav.pop}
                        onChange={onChange}
                        take="copy"
                        canTake={typed !== ""}
                        cancel={null}
                        onLegend={setPromptKeys}
                    />
                    {names.length === 0 ? <Text dimColor>no models yet!</Text> : null}
                </>
            ) : null}
            {mode === "list" ? pickList.list : null}
        </Frame>
    )
}
