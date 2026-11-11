// SPDX-License-Identifier: LGPL-3.0-or-later

// The models screen: the models of a project.

import { basename, } from "node:path"
import { Text } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { readSystem, } from "../core/environment.js"
import { pick } from "../core/file-system.js"
import { truncate } from "../core/terminal.js"
import { MAX_PATH_TYPED, pathSuggestions } from "../store/lists.js"
import {
    type AddResult,
    accepted,
    addModel,
    addModels,
    copyFailed,
    deleteModel,
    listModels,
    modelPathProblem,
    type ProjectRef,
} from "../store/projects.js"
import { modelOverrides, modelScope, modelStem } from "../store/settings-store.js"
import { Frame } from "../ui/frame.js"
import { type LegendItem, legendFor, legendOf } from "../ui/grid.js"
import { type Choice, destructiveQuestion, PathPrompt, usePickList } from "../ui/input.js"
import {
    type KeyInput,
    keys,
    useBodyColumns,
    useKeys,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { useTheme } from "../ui/theme.js"
import { ModelReferenceScreen } from "./model-reference.js"
import { SettingsMenu } from "./settings-screens.js"


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
type ModelsMode = "prompt" | "list" | "picking"

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
    const theme = useTheme()
    const active = useScreenActive()
    const columns = useBodyColumns()
    const [mode, setMode] = useState<ModelsMode>("prompt")
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
    // the settings each model has of its own, read again when a sheet closes
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const own = useMemo(
        () => modelOverrides(project.dir),
        [project.dir, version, nav.depth, active],
    )

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
        () =>
            names.map((name) => ({
                label: own.has(modelStem(name)) ? `${name} *` : name,
                value: name,
            })),
        [names, own],
    )
    /** `^o`: the settings sheets of the highlighted model (its own overrides). */
    const openSettings = useCallback(
        (name: string) =>
            nav.push(<SettingsMenu scope={modelScope(project, modelStem(name))} />),
        [nav, project],
    )
    /** `^f`: the reference fit of the highlighted model. */
    const openReference = useCallback(
        (name: string) =>
            nav.push(
                <ModelReferenceScreen
                    project={project}
                    file={name}
                    stem={modelStem(name)}
                />,
            ),
        [nav, project],
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
        question: (name) => destructiveQuestion(`model ${modelStem(name)}`),
        action: [
            { label: "settings", key: keys.modelSettings, run: openSettings },
            { label: "reference", key: keys.modelReference, run: openReference },
        ],
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

    // a model with settings of its own says which, when nothing else is to be said
    const overrides = own.get(modelStem(String(pickList.highlighted ?? "")))
    const hint =
        overrides === undefined
            ? undefined
            : truncate(`overrides: ${overrides.join(", ")}`, columns - 4)
    const frameNote =
        mode === "list"
            ? (pickList.note ?? hint)
            : mode === "picking"
                ? pickingNote
                : note
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
                    <PathPrompt
                        key={fieldKey}
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
                    {names.length === 0 ? (
                        <Text color={theme.er}>no models yet!</Text>
                    ) : null}
                </>
            ) : null}
            {mode === "list" ? pickList.list : null}
        </Frame>
    )
}
