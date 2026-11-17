// SPDX-License-Identifier: LGPL-3.0-or-later

// The models screen: the models of a project.

import { basename, } from "node:path"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { readSystem, } from "../core/environment.js"
import { pick } from "../core/file-system.js"
import { truncate } from "../core/terminal.js"
import { MAX_PATH_TYPED, pathSuggestions } from "../store/lists.js"
import {
    type AddResult,
    accepted,
    addModelsAsync,
    deleteModelAsync,
    listModels,
    modelPathProblem,
    modelsProblem,
    type ProjectRef,
} from "../store/projects.js"
import { modelOverrides, modelScope, modelStem } from "../store/settings-store.js"
import { Frame } from "../ui/frame.js"
import { type LegendItem, legendFor, legendOf } from "../ui/grid.js"
import {
    type Choice,
    destructiveQuestion,
    PathPrompt,
    usePickList,
} from "../ui/input.js"
import {
    type KeyInput,
    keys,
    useBodyColumns,
    useKeys,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { usePathField } from "../ui/prompt-flows.js"
import { ErrorText } from "../ui/theme.js"
import { SettingsMenu } from "./settings-menu.js"


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

/**
 * The note for the outcome of a background add: the archive's own message when the write
 * failed, else [[pickNote]].
 */
function addNote(result: AddResult & { problem?: string }): string {
    return result.problem === undefined ? pickNote(result) : result.problem
}

/** The note while the picker window is open. */
const pickingNote = "choose files in the picker window..."

/** The legend entry that opens the list, with how many models there are. */
const modelsLegend = (count: number): LegendItem =>
    legendFor(`models (${count})`, keys.openList)

/** What the screen does: asks for a path, lists the models, or waits for the picker. */
type ModelsMode = "prompt" | "list" | "picking"

/**
 * The models of a project: a prompt for the full absolute path of a `.cif` or `.pdb`
 * file, which is COPIED into the project's `models.7z` (the original is never
 * touched) and the prompt stays for the next one. With nothing typed `^v` opens the
 * desktop's file picker and `shift+h` the list of the models, where `^r` asks and then
 * deletes the highlighted one at once; `^r` on the empty field opens the list with that
 * question already asked about the first model.
 *
 * @param project - the project whose models these are.
 * @param onLeave - told the models of the project when the screen is left.
 * @returns the screen.
 */
export function ModelsScreen({
    project,
    onLeave,
}: {
    project: ProjectRef
    onLeave?: (names: string[]) => void
}): ReactNode {
    const nav = useNav()
    const active = useScreenActive()
    const columns = useBodyColumns()
    const [mode, setMode] = useState<ModelsMode>("prompt")
    const [note, setNote] = useState<string | undefined>(() =>
        modelsProblem(project.dir),
    )
    // the prompt is remounted to empty its field: `shift+h` is typed into it by the time
    // the screen has seen it, and a copied path is cleared
    const clearNote = useCallback(() => setNote(undefined), [])
    const field = usePathField(clearNote)
    const { typed, problem, setProblem, promptKeys, setPromptKeys, fieldKey, resetField } =
        field
    // bumped when the folder changes, so the lists below are read again
    const [version, setVersion] = useState(0)
    // the writes of `models.7z` run in the background: the names being added and removed
    const [adding, setAdding] = useState<string[]>([])
    const [removing, setRemoving] = useState<ReadonlySet<string>>(new Set())
    // biome-ignore lint/correctness/useExhaustiveDependencies: version = folder changed
    const names = useMemo(() => listModels(project.dir), [project.dir, version])
    // the settings each model has of its own, read again when a sheet closes
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const own = useMemo(
        () => modelOverrides(project.dir),
        [project.dir, version, nav.depth, active],
    )

    /** Adds files in the background: the note says so now, the outcome when it ends. */
    const addFiles = useCallback(
        async (paths: readonly string[]) => {
            const mine = paths.map((p) => basename(p))
            setAdding((now) => [...now, ...mine])
            setNote(`adding ${mine.length === 1 ? mine[0] : `${mine.length} files`}...`)
            const result = await addModelsAsync(project.dir, paths)
            setAdding((now) => now.filter((n) => !mine.includes(n)))
            setVersion((v) => v + 1)
            setNote(addNote(result))
        },
        [project.dir],
    )

    const pickFiles = useCallback(async () => {
        setMode("picking")
        const result = await pick(readSystem(), readSystem().home)
        if ("problem" in result) setNote(result.problem)
        else void addFiles(result.files)
        resetField()
        setMode("prompt")
    }, [addFiles, resetField])

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
                label:
                    (own.has(modelStem(name)) ? `${name} *` : name) +
                    (removing.has(name) ? " (removing...)" : ""),
                value: name,
            })),
        [names, own, removing],
    )
    /** `^o`: the settings sheets of the highlighted model (its own overrides). */
    const openSettings = useCallback(
        (name: string) =>
            nav.push(<SettingsMenu scope={modelScope(project, modelStem(name))} />),
        [nav, project],
    )
    // leaving (back) tells the caller which models there are now
    const leave = useCallback(() => {
        onLeave?.(listModels(project.dir))
        nav.pop()
    }, [onLeave, project.dir, nav])
    const closeList = useCallback(() => setMode("prompt"), [])
    const pickList = usePickList<string>({
        open: mode === "list",
        label: "find:",
        entries,
        take: null, // a model that is picked is not used for anything
        cancel: "close",
        onPick: () => {},
        onCancel: closeList,
        onBack: leave,
        question: (name) => destructiveQuestion(`model ${modelStem(name)}`),
        action: [
            { label: "settings", key: keys.modelSettings, run: openSettings },
        ],
        onDelete: (name) => {
            if (removing.has(name)) throw new Error("already being removed")
            setRemoving((now) => new Set(now).add(name))
            void deleteModelAsync(project.dir, name).then((deleted) => {
                setRemoving((now) => {
                    const left = new Set(now)
                    left.delete(name)
                    return left
                })
                setVersion((v) => v + 1)
                if (!deleted) setNote(`could not remove ${name}`)
            })
        },
        onFail: (e) => setNote((e as Error).message),
        onEmpty: closeList,
    })

    const submit = useCallback(
        (text: string) => {
            const path = text.trim() // a typed or pasted path may end in blanks
            const bad = modelPathProblem(path, [...names, ...adding])
            if (bad !== undefined) return setProblem(bad)
            void addFiles([path])
            resetField()
        },
        [names, adding, addFiles, resetField, setProblem],
    )

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
                        onBack={leave}
                        onChange={field.onChange}
                        take="copy"
                        canTake={typed !== ""}
                        cancel={null}
                        onLegend={setPromptKeys}
                    />
                    {names.length === 0 ? (
                        <ErrorText>no models yet!</ErrorText>
                    ) : null}
                </>
            ) : null}
            {mode === "list" ? pickList.list : null}
        </Frame>
    )
}
