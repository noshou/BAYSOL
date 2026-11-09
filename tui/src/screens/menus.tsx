// SPDX-License-Identifier: LGPL-3.0-or-later

// The menus: the models, the buffer landing, the project menu and the main menu.
//
// Contents:
//   1. The models screen: the models of a project
//   2. The buffer landing
//   3. The project menu
//   4. The main menu

import { basename, join } from "node:path"
import { Box, Text, useApp } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { appDir, projectsDir, RUN_FLOW, readSystem, version } from "../core/environment.js"
import {
    copyOver,
    entryNames,
    isFolder,
    openFileManager,
    openFolder,
    pick,
    quarantine,
    saveErrorNote,
    UnusableFileError,
} from "../core/file-system.js"
import { formatNumber, truncate } from "../core/terminal.js"
import {
    type BufferRow,
    bufferFile,
    bufferFileName,
    type Conditions,
    indexOfRecipe,
    MAX_NAME,
    type Recipe,
    readConcUnit,
    readConditions,
    readRecipes,
    readSolutes,
    recipeConditions,
    recipeNameProblem,
    recipesFileName,
    removeRecipe,
    resetBuffer,
    saveRecipe,
    writeConcUnit,
    writeSolutes,
} from "../store/buffer.js"
import { customFile, readCustomSolutes } from "../store/custom.js"
import { MAX_PATH_TYPED, MAX_ROWS, pathSuggestions } from "../store/lists.js"
import {
    type AddResult,
    accepted,
    addModel,
    addModels,
    brokenNames,
    copyFailed,
    createProject,
    defaultTemperature,
    deleteModel,
    deleteProject,
    hasRuns,
    InvalidNameError,
    listModels,
    listProjects,
    liveRun,
    modelPathProblem,
    type ProjectRef,
    projectNameProblem,
} from "../store/projects.js"
import {
    parseTemperature,
    projectReadiness,
    RunSession,
    TEMPERATURE_LABEL,
    temperatureStart,
} from "../store/run.js"
import {
    globalScope,
    loadGlobal,
    loadScope,
    modelOverrides,
    modelScope,
    modelStem,
    projectScope,
    settingsFile,
} from "../store/settings-store.js"
import { setConcUnit } from "../store/solutes.js"
import { Frame } from "../ui/frame.js"
import {
    GridMenu,
    type LegendItem,
    legendBack,
    legendEnter,
    legendFor,
    legendOf,
    MenuHeader,
    MenuSpec,
    moveLegend,
    type TaskbarItem,
} from "../ui/grid.js"
import {
    type Choice,
    Dropdown,
    destructiveQuestion,
    filterChoices,
    Prompt,
    questionLegend,
    useConfirm,
    usePickList,
} from "../ui/input.js"
import {
    CursorList,
    type KeyInput,
    keys,
    ListText,
    taskbarKeys,
    useBodyColumns,
    useKeys,
    useListCursor,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { useTheme } from "../ui/theme.js"
import { CustomSolutesTable } from "./custom-solutes.js"
import { DataScreen } from "./data-screen.js"
import { LogsRuns } from "./logs-menu.js"
import { OpenRuns } from "./open-runs.js"
import { RunScreen } from "./run-screens.js"
import {
    bufferLandingOptions,
    type LandingId,
    NO_RECIPES,
    NOT_SAVED,
    NOTHING_REPLACED_HINT,
    REPLACES_HINT,
    recipeChoice,
    replaceRecipeQuestion,
    savedAs,
    TOO_MANY_RECIPES,
    unusable as unusable_,
} from "./screen-rules.js"
import {
    count,
    type FileCount,
    fileStatus,
    SettingsMenu,
    unusableHint,
    useResetFile,
} from "./settings-screens.js"
import { SolutesTable } from "./solutes.js"

// ========================================================================================
// 1. The models screen: the models of a project
// ========================================================================================

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
        action: { label: "settings", key: keys.modelSettings, run: openSettings },
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
                    {names.length === 0 ? (
                        <Text color={theme.er}>no models yet!</Text>
                    ) : null}
                </>
            ) : null}
            {mode === "list" ? pickList.list : null}
        </Frame>
    )
}

// ========================================================================================
// 2. The buffer landing
// ========================================================================================

/** What the landing is doing: waiting for a choice, picking a recipe, asking a name. */
type LandingMode = "menu" | "load" | "save"

/**
 * The landing of the buffer of a project. The options, each only when it applies:
 *
 * - `buffer (N solutes)`: the table of its solutes and pH.
 * - `custom solutes (N)`: the user's table of non-biological solutes.
 * - `load a recipe`: a dropdown of the saved recipes with their solute counts (`^r`
 *   deletes the highlighted one), then the buffer's table with the recipe's rows as
 *   unsaved ones and the recipe's pH and σ, when it has them, as an unsaved change (a
 *   recipe without leaves the buffer's own); at the first `^w` a buffer that has solutes
 *   asks `replace N solutes with recipe "NAME"?`. `no saved recipes!` for none.
 * - `new recipe`: the table, empty; nothing is replaced before `^w`.
 * - `save current recipe globally`, when the buffer has solutes: asks a name (`replace
 *   "NAME"?` if a recipe has it) and saves the buffer as it is on disk, with its pH and σ,
 *   as a recipe.
 *
 * A line says what each file holds. A file that cannot be used is told and never written
 * over; `r` on its option offers to move it to `<name>.corrupt` and start empty (the
 * table of an unusable file says so and edits nothing).
 *
 * Keys: up and down move, Enter opens, `^x` goes back.
 */
export function BufferLanding({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    const confirm = useConfirm()
    const [mode, setMode] = useState<LandingMode>("menu")
    const [message, setMessage] = useState<string>()
    const [problem, setProblem] = useState<string>()
    const [recipes, setRecipes] = useState<Recipe[]>([])
    // the keys of the open name prompt
    const [saveKeys, setSaveKeys] = useState<LegendItem[]>([])
    // the counts are read again whenever a table closes or a file is reset
    const [resets, setResets] = useState(0)
    const reset = useResetFile(confirm, setMessage, () => setResets((n) => n + 1))
    const root = appDir()
    const dir = project.dir
    const room = columns - 4

    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const [n, custom] = useMemo(
        () => [count(() => readSolutes(dir)), count(() => readCustomSolutes(root))],
        [dir, root, nav.depth, resets],
    ) as [FileCount, FileCount]
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const conditions = useMemo(() => readConditionsOrNone(dir), [dir, nav.depth, resets])
    const sigmaText = conditions ? formatNumber(conditions["sigma-pH"]) : ""
    const options = bufferLandingOptions(n, custom)
    const cursor = useListCursor(options.length, options.length)
    const solutes = typeof n === "number" ? n : 0
    const on = options[cursor.index]?.id
    const file = on === "custom" ? customFile(root) : bufferFile(dir)
    const unusable = (on === "custom" ? custom : n) === "unusable" && on !== undefined
    const bufferUnusable = n === "unusable"

    /** Notes the version of the buffer file as it is, so that a table that replaces it
     * refuses to save over a buffer another copy changed meanwhile. */
    const trackBuffer = () => {
        try {
            readSolutes(dir, { track: true })
        } catch {
            // an unusable buffer is told by the table itself
        }
    }

    /** Opens the table of the buffer: its rows, or a recipe's as unsaved ones. */
    const openTable = (extra: {
        items?: readonly BufferRow[]
        draftRows?: readonly BufferRow[]
        draftConditions?: Conditions
        hint?: string
        replace?: { count: number; recipe: string }
    }) => {
        setConcUnit(readConcUnit(dir))
        nav.push(
            <SolutesTable
                subtitle={project.id}
                items={extra.items ?? []}
                draftRows={extra.draftRows}
                conditions={readConditionsOrNone(dir)}
                draftConditions={extra.draftConditions}
                hint={extra.hint}
                replace={extra.replace}
                save={(rows, c, unit) => void writeSolutes(dir, rows, c, unit)}
                onUnit={(unit) => writeConcUnit(dir, unit)}
            />,
        )
    }

    const pickRecipe = (recipe: Recipe) => {
        setMode("menu")
        trackBuffer()
        openTable({
            draftRows: recipe.solutes,
            draftConditions: recipeConditions(recipe),
            hint: solutes > 0 ? REPLACES_HINT : undefined,
            replace: solutes > 0 ? { count: solutes, recipe: recipe.name } : undefined,
        })
    }

    /** Writes the buffer as it is on disk, with its pH and σ, as the recipe `name`. */
    const doSave = (name: string) => {
        try {
            saveRecipe(root, name, readSolutes(dir), readConditions(dir))
            setMessage(savedAs(name, room))
        } catch (error) {
            setMessage(saveFailure(error))
        }
    }

    const submitName = (text: string) => {
        const name = text.trim()
        const bad = recipeNameProblem(name)
        if (bad !== undefined) return setProblem(bad)
        let saved: Recipe[]
        try {
            saved = readRecipes(root)
        } catch {
            setMode("menu")
            return setMessage(unusable_(recipesFileName))
        }
        setMode("menu")
        if (indexOfRecipe(saved, name) !== undefined)
            confirm.ask(replaceRecipeQuestion(name, room), () => doSave(name))
        else if (saved.length >= MAX_ROWS) setMessage(TOO_MANY_RECIPES)
        else doSave(name)
    }

    const choose = (id: LandingId) => {
        if (id === "custom") return nav.push(<CustomSolutesTable />)
        if (bufferUnusable) return setMessage(unusable_(bufferFileName))
        if (id === "buffer") {
            try {
                openTable({ items: readSolutes(dir, { track: true }) })
            } catch {
                setMessage(unusable_(bufferFileName))
            }
        } else if (id === "new") {
            trackBuffer()
            openTable({ hint: solutes > 0 ? NOTHING_REPLACED_HINT : undefined })
        } else if (id === "load") {
            try {
                const saved = readRecipes(root)
                if (saved.length === 0) return setMessage(NO_RECIPES)
                setRecipes(saved)
                setMode("load")
            } catch {
                setMessage(unusable_(recipesFileName))
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
        else if (press.is(keys.enter)) {
            if (on !== undefined) choose(on)
        } else if (unusable && press.is(keys.reset))
            reset(basename(file), () =>
                on === "custom" ? quarantine(file) : resetBuffer(dir),
            )
    }, mode === "menu")

    // the dropdown lists every recipe with its solute count; the choice is the recipe.
    // ^r and Delete ask about the highlighted one, Enter deletes it, the list stays open
    const choices = useMemo<Choice<Recipe>[]>(
        () =>
            recipes.map((r) => ({
                label: recipeChoice(r.name, r.solutes.length),
                value: r,
            })),
        [recipes],
    )
    const closeRecipes = useCallback(() => {
        setMode("menu")
        setMessage(NO_RECIPES)
    }, [])
    const pickList = usePickList<Recipe>({
        open: mode === "load",
        label: "load a recipe:",
        entries: choices,
        onPick: pickRecipe,
        onCancel: () => setMode("menu"),
        question: (recipe) => destructiveQuestion(`recipe ${recipe.name}`),
        onDelete: (recipe) => {
            removeRecipe(root, recipe.name)
            setRecipes(readRecipes(root))
        },
        onFail: (error) => setMessage(saveFailure(error)),
        onEmpty: closeRecipes,
    })
    const clearProblem = useCallback(() => setProblem(undefined), [])

    // only the keys that work now: the arrows from the cursor's row, reset for a file
    // that cannot be used; an open dropdown or prompt shows its own keys, a question its
    // answers
    const listLegend = legendOf([
        legendBack,
        legendEnter,
        moveLegend({ up: cursor.index > 0, down: cursor.index < options.length - 1 }),
        unusable && legendFor("reset file", keys.reset),
    ])
    const modeLegend = { menu: listLegend, load: pickList.legend, save: saveKeys }[mode]
    const legend = confirm.question ? questionLegend(confirm.question) : modeLegend
    return (
        <Frame
            title="buffer"
            subtitle={project.id}
            legend={legend}
            note={confirm.note ?? pickList.note ?? message}
        >
            <CursorList
                items={options}
                index={cursor.index}
                offset={cursor.offset}
                lines={options.length}
                active={mode === "menu"}
                row={(o, isOn) => <ListText on={isOn}>{o.label}</ListText>}
            />
            <Box flexDirection="column" marginTop={1}>
                <Text color={theme.mt}>{fileStatus("buffer", n, "solute")}</Text>
                {n === "unusable" ? null : (
                    <Text color={theme.mt}>
                        {conditions === undefined
                            ? "pH not set"
                            : `pH ${formatNumber(conditions.pH)}  σ ${sigmaText}`}
                    </Text>
                )}
                <Text color={theme.mt}>
                    {fileStatus("custom solutes", custom, "solute")}
                </Text>
                {unusable ? (
                    <Text color={theme.er}>{unusableHint(file, columns)}</Text>
                ) : null}
            </Box>
            {mode === "load" ? <Box marginTop={1}>{pickList.list}</Box> : null}
            {mode === "save" ? (
                <Box marginTop={1}>
                    <Prompt
                        label="save as:"
                        maxLength={MAX_NAME}
                        error={problem}
                        onChange={clearProblem}
                        onLegend={setSaveKeys}
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

/**
 * What a failed save was about, for the message.
 *
 * @returns `buffer.json unusable!`, `recipes.json unusable!` or `could not save!`.
 */
function saveFailure(error: unknown): string {
    if (error instanceof UnusableFileError) {
        if (error.kind === "buffer") return unusable_(bufferFileName)
        if (error.kind === "recipes") return unusable_(recipesFileName)
    }
    return saveErrorNote(error)
}

/** The pH and σ of the buffer file, `undefined` for none yet or a file that is unusable. */
function readConditionsOrNone(dir: string): Conditions | undefined {
    try {
        return readConditions(dir)
    } catch {
        return undefined
    }
}

// ========================================================================================
// 3. The project menu
// ========================================================================================

/** The options of the project menu; exported so a test can check their hotkeys. */
export const projectMenuSpec = new MenuSpec(
    ["models", "data", "buffer", "logs", "settings", "open"], 2
)

/** The notice of the `logs` option when the project has no run yet. */
const NO_RUNS_NOTICE = "no runs yet"

/** What the `open` dropdown can do: the folder (file manager and a shell) or the runs. */
type OpenWhat = "folder" | "runs"

/** The entries of the `open` dropdown, in order (the look and keys of `load project:`). */
const openEntries: Choice<OpenWhat>[] = [
    { label: "open project folder", value: "folder" },
    { label: "open runs", value: "runs" },
]

/**
 * Opens the project's settings once, which checks them: the notice says so if the
 * file could not be read and the global settings were put in its place.
 *
 * @param project - the project.
 * @returns the notice for the user, or `undefined` if the settings were fine.
 */
function settingsNotice(project: ProjectRef): string | undefined {
    let reset: boolean
    try {
        reset = loadScope(projectScope(project)).reset
    } catch (error) {
        // a project that another copy deleted meanwhile: say so, do not crash
        return error instanceof Error ? error.message : "could not open the project"
    }
    if (!reset) return undefined
    const file = basename(settingsFile(project.dir))
    return `${file} unreadable: global used, old in .corrupt`
}

/**
 * The menu of a project: models, data, buffer, logs, settings and open (the project's
 * folder in the file manager, or with a run its runs). `logs` opens the list of the runs
 * (reading and restoring a run's inputs and logs). The taskbar offers `run: shift+r` when
 * the project can run (it asks the temperature in a small prompt over the right half of
 * the grid, then starts the run and opens its screen).
 *
 * @param project - the project.
 * @returns the screen.
 */
export function ProjectMenu({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const [notice, setNotice] = useState<string | undefined>(() => settingsNotice(project))
    // the temperature prompt of a run: the text it starts with, its error, its keys
    const [asking, setAsking] = useState<string | undefined>()
    const [problem, setProblem] = useState<string | undefined>()
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
    // the `open` dropdown (only with a run in the project) and its keys
    const { suspendTerminal } = useApp()
    const [choosing, setChoosing] = useState(false)
    const [openKeys, setOpenKeys] = useState<LegendItem[]>([])
    const openSearch = useMemo(() => filterChoices(openEntries), [])
    // flips when a screen opens over this one and when it closes again
    const active = useScreenActive()

    const choose = useCallback((name: (typeof projectMenuSpec.names)[number]) => {
        setNotice(undefined)
        // another copy may have deleted the project while this menu was open
        if (!isFolder(project.dir))
            return setNotice(`project ${project.id} no longer exists`)
        if (name === "models") nav.push(<ModelsScreen project={project} />)
        else if (name === "buffer") nav.push(<BufferLanding project={project} />)
        else if (name === "settings") {
            nav.push(<SettingsMenu scope={projectScope(project)} />)
        } else if (name === "data") nav.push(<DataScreen project={project} />)
        else if (name === "logs") {
            if (hasRuns(project.dir)) nav.push(<LogsRuns project={project} />)
            else setNotice(NO_RUNS_NOTICE)
        } else if (hasRuns(project.dir)) setChoosing(true)
        else {
            // the file manager runs on its own: the terminal is not given up
            void openFileManager(readSystem(), project.dir).then((problem) => {
                if (problem !== undefined)
                    setNotice(`could not open the file manager: ${problem}`)
            })
        }
    }, [nav, project])

    /** The dropdown's pick: the folder as the main menu's `open` does it, or the runs. */
    const openWhat = useCallback(
        (what: OpenWhat) => {
            setChoosing(false)
            if (what === "runs") return nav.push(<OpenRuns project={project} />)
            // the shell takes the terminal until the user leaves it
            void suspendTerminal(async () => {
                const problem = await openFolder(readSystem(), project.dir, setNotice)
                if (problem !== undefined) setNotice(problem)
            })
        },
        [nav, project, suspendTerminal],
    )

    /** `run: shift+r`: refuse a live run, else ask the temperature. */
    const askTemperature = useCallback(() => {
        const live = liveRun(project.dir)
        if (live !== undefined) return setNotice(`a run is in progress (pid ${live.pid})`)
        setNotice(undefined)
        setProblem(undefined)
        setAsking(temperatureStart(defaultTemperature(project.dir)))
    }, [project.dir])

    /** Enter at the prompt: check the number, claim the folder and start the child. */
    const startRun = useCallback(
        (text: string) => {
            const parsed = parseTemperature(text)
            if ("error" in parsed) return setProblem(parsed.error)
            try {
                const session = RunSession.begin(project.dir, parsed.value)
                setAsking(undefined)
                nav.push(<RunScreen session={session} />)
            } catch (error) {
                setAsking(undefined)
                setNotice(
                    error instanceof Error ? error.message : "could not start the run",
                )
            }
        },
        [project.dir, nav],
    )

    // read again when this menu comes back to the top (the screen that was open over it
    // may have changed the models or the buffer) and after every notice
    // biome-ignore lint/correctness/useExhaustiveDependencies: active, notice = re-read
    const taskbar = useMemo<TaskbarItem[]>(
        () =>
            projectReadiness(project).run
                ? [{ ...taskbarKeys.run, onPress: askTemperature }]
                : [],
        [project, active, notice, askTemperature],
    )

    return (
        <GridMenu
            spec={projectMenuSpec}
            header={<MenuHeader caption={`project: ${project.id}`} />}
            onChoose={choose}
            notice={notice}
            taskbar={taskbar}
            overlay={
                choosing ? (
                    <Dropdown<OpenWhat>
                        label="open:"
                        search={openSearch}
                        take="open"
                        onPick={openWhat}
                        onCancel={() => setChoosing(false)}
                        onLegend={setOpenKeys}
                    />
                ) : asking === undefined ? undefined : (
                    <Prompt
                        label={TEMPERATURE_LABEL}
                        initial={asking}
                        maxLength={RUN_FLOW.temperature.maxLength}
                        take="run"
                        error={problem}
                        onChange={() => setProblem(undefined)}
                        onLegend={setPromptKeys}
                        onSubmit={startRun}
                        onCancel={() => setAsking(undefined)}
                    />
                )
            }
            overlayLegend={choosing ? openKeys : promptKeys}
        />
    )
}

// ========================================================================================
// 4. The main menu
// ========================================================================================

/** The options of the main menu; exported so a test can check their hotkeys. */
export const mainMenuSpec = new MenuSpec(
    ["new", "load", "open", "settings", "help", "quit"], 2
)

/**
 * The most characters a project name takes while typing; `projectNameProblem` tells a
 * long one.
 */
const nameTyped = 60

/** What the menu shows under the grid in place of its hint. */
type Overlay = "new" | "load" | null

/**
 * The main menu: make a project, load one, open the projects folder, the global
 * settings, help (not built) and quit. A name prompt or the project list opens right
 * under the grid. Deleting a project is not a menu option: while the `load` list is
 * open (so at least one project exists), `^r` (or Delete) asks about the highlighted
 * project and Enter then deletes it, as in the list of models.
 *
 * @returns the screen.
 */
export function MainMenu(): ReactNode {
    const nav = useNav()
    const { suspendTerminal } = useApp()
    const [overlay, setOverlay] = useState<Overlay>(null)
    const [error, setError] = useState<string>()
    const [notice, setNotice] = useState<string>()
    const [newLegend, setNewLegend] = useState<LegendItem[]>([])
    // bumped when a project is deleted, so the list is read again
    const [listed, setListed] = useState(0)

    const closeOverlay = useCallback(() => setOverlay(null), [])

    const choose = useCallback((name: (typeof mainMenuSpec.names)[number]) => {
        setNotice(undefined)
        setError(undefined)
        if (name === "quit") nav.quit()
        else if (name === "new") setOverlay("new")
        else if (name === "load") {
            if (listProjects(projectsDir()).length === 0) setNotice("no projects to load!")
            else setOverlay("load")
        } else if (name === "settings") nav.push(<SettingsMenu scope={globalScope} />)
        else if (name === "help") setNotice("help is not built yet")
        else if (name === "open") {
            // the shell takes the terminal until the user leaves it
            void suspendTerminal(async () => {
                const problem = await openFolder(readSystem(), appDir(), setNotice)
                if (problem !== undefined) setNotice(problem)
            })
        }
    }, [nav, suspendTerminal])

    const create = useCallback((typed: string) => {
        const root = projectsDir()
        const id = typed.trim()
        const problem = projectNameProblem(id, entryNames(root), brokenNames(root))
        if (problem !== undefined) return setError(problem)
        try {
            const dir = createProject(appDir(), id, {
                prepareGlobal: () => { loadGlobal(appDir()) },
                copySettings: (to) => {
                    copyOver(settingsFile(appDir()), settingsFile(to))
                },
            })
            setOverlay(null)
            nav.push(<ProjectMenu project={{ id, dir }} />)
        } catch (e) {
            setError(
                e instanceof InvalidNameError
                    ? e.message
                    : `could not make it: ${(e as Error).message}`,
            )
        }
    }, [nav])

    // biome-ignore lint/correctness/useExhaustiveDependencies: listed = a project went
    const projects = useMemo<Choice<string>[]>(
        () =>
            overlay === "load"
                ? listProjects(projectsDir()).map((id) => ({ label: id, value: id }))
                : [],
        [overlay, listed],
    )

    // the project list: ^r (or Delete) asks about the highlighted project, Enter deletes
    // it and the list stays for the next one
    const pickList = usePickList<string>({
        open: overlay === "load",
        label: "load project:",
        entries: projects,
        take: "open",
        onPick: (id) => {
            setOverlay(null)
            nav.push(<ProjectMenu project={{ id, dir: join(projectsDir(), id) }} />)
        },
        onCancel: () => setOverlay(null),
        question: (id) => destructiveQuestion(`project ${id}`),
        onDelete: (id) => {
            deleteProject(appDir(), id)
            setNotice(`deleted ${id}`)
            setListed((v) => v + 1)
        },
        onFail: (e) => {
            setNotice((e as Error).message)
            setListed((v) => v + 1)
        },
        onEmpty: closeOverlay,
    })

    let shown: ReactNode
    if (overlay === "new")
        shown = (
            <Prompt
                label="new project:"
                maxLength={nameTyped}
                error={error}
                take="create"
                onChange={() => setError(undefined)}
                onSubmit={create}
                onCancel={closeOverlay}
                onLegend={setNewLegend}
            />
        )
    else if (overlay === "load") shown = pickList.list

    // the keys of the open overlay, shown in place of the menu's move hint
    const overlayLegend = overlay === "new" ? newLegend : pickList.legend

    return (
        <GridMenu
            spec={mainMenuSpec}
            header={<MenuHeader caption={version} />}
            onChoose={choose}
            notice={pickList.note ?? notice}
            overlay={shown}
            overlayLegend={overlay ? overlayLegend : undefined}
        />
    )
}
