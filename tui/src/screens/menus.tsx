// SPDX-License-Identifier: LGPL-3.0-or-later

// The menus: the buffer landing, the project menu and the main menu (the models screen
// is in `models.tsx`).
//
// Contents:
//   1. The buffer landing
//   2. The project menu
//   3. The main menu

import { basename, join } from "node:path"
import { Box, Text, useApp } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { appDir, projectsDir, readSystem, version } from "../core/environment.js"
import {
    copyOver,
    entryNames,
    isFolder,
    messageOf,
    openFileManager,
    openFolder,
    quarantine,
    saveErrorNote,
    UnusableFileError,
} from "../core/file-system.js"
import { formatNumber } from "../core/terminal.js"
import {
    type BufferRow,
    bufferFile,
    bufferFileName,
    type Conditions,
    indexOfRecipe,
    MAX_NAME,
    type Recipe,
    readBufferNotes,
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
    writeBufferNotes,
    writeConcUnit,
    writeSolutes,
} from "../store/buffer.js"
import { customFile, readCustomSolutes } from "../store/custom.js"
import { MAX_ROWS } from "../store/lists.js"
import type { Note } from "../store/notes.js"
import {
    brokenNames,
    createProject,
    deleteProject,
    hasRuns,
    InvalidNameError,
    listProjects,
    liveRun,
    type ProjectRef,
    projectNameProblem,
    readProjectNotes,
    writeProjectNotes,
} from "../store/projects.js"
import {
    missingComponents,
    projectReadiness,
    RunSession,
} from "../store/run.js"
import {
    globalScope,
    loadGlobal,
    loadScope,
    projectScope,
    settingsFile,
} from "../store/settings-store.js"
import { setConcUnit } from "../store/solutes.js"
import {
    kindOf,
    offersTemplate,
    recipeLoad,
    recipeSave,
} from "../store/template-recipes.js"
import { Frame } from "../ui/frame.js"
import {
    cursorMoves,
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
import { ModelsScreen } from "./models.js"
import { NotesList } from "./notes-list.js"
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
    saveAsTemplateQuestion,
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
// 1. The buffer landing
// ========================================================================================

/** What a recipe shown in the table changes from the plain rows. */
type OpenExtra = { conditions?: Conditions; hint?: string; template?: boolean }

/** The word a recipe's list line carries when it is a template, `undefined` otherwise. */
function templateKind(recipe: Recipe): string | undefined {
    const kind = kindOf(recipe)
    return kind === "recipe" ? undefined : kind
}

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
 *   A template recipe (`store/template-recipes.ts`) comes in as its fixed rows and the rows
 *   of its definition at the recipe's pH and temperature (else the buffer's; with no pH
 *   at all it asks to set one first), linked so that they follow the table's pH and
 *   temperature; the question says `with template "NAME"?`. A definition that cannot be
 *   used loads its fixed rows only, with the problem as the hint.
 * - `new recipe`: the table, empty; nothing is replaced before `^w`.
 * - `save current recipe globally`, when the buffer has solutes: asks a name (`replace
 *   "NAME"?` if a recipe has it; `save "NAME" as a template?` when the rows of one
 *   template are linked: Enter saves the template, `n` the rows as a plain recipe, Esc
 *   saves nothing) and saves the buffer as it is on disk, with its pH and σ, as a recipe.
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
        draftNotes?: readonly Note[]
        hint?: string
        replace?: { count: number; recipe: string; notes?: boolean; template?: boolean }
    }) => {
        setConcUnit(readConcUnit(dir))
        nav.push(
            <SolutesTable
                subtitle={project.id}
                items={extra.items ?? []}
                draftRows={extra.draftRows}
                conditions={readConditionsOrNone(dir)}
                draftConditions={extra.draftConditions}
                notes={readNotesOrNone(dir)}
                draftNotes={extra.draftNotes}
                onNotes={(notes) => writeBufferNotes(dir, notes)}
                hint={extra.hint}
                replace={extra.replace}
                save={(rows, c, unit, notes) =>
                    void writeSolutes(dir, rows, c, unit, notes)
                }
                onUnit={(unit) => writeConcUnit(dir, unit)}
            />,
        )
    }

    /** Opens the table with the rows of a recipe as unsaved ones. */
    const showRecipe = (recipe: Recipe, rows: readonly BufferRow[], extra: OpenExtra) => {
        const notes = recipe.notes !== undefined
        const template = extra.template
        setMode("menu")
        trackBuffer()
        openTable({
            draftRows: rows,
            draftConditions: extra.conditions ?? recipeConditions(recipe),
            draftNotes: recipe.notes,
            hint: extra.hint ?? (solutes > 0 ? REPLACES_HINT : undefined),
            replace:
                solutes > 0
                    ? { count: solutes, recipe: recipe.name, notes, template }
                    : undefined,
        })
    }

    const pickRecipe = (recipe: Recipe) => {
        const loaded = recipeLoad(recipe, readConditionsOrNone(dir))
        if ("message" in loaded) {
            setMode("menu")
            return setMessage(loaded.message)
        }
        showRecipe(recipe, loaded.rows, {
            conditions: loaded.conditions,
            template: loaded.template || undefined,
            hint: loaded.hint,
        })
    }

    /**
     * Writes the buffer as it is on disk, with its pH and σ, as the recipe `name`; as a
     * template (its one group of linked rows becomes the definition, the other rows stay
     * fixed) when `asTemplate`.
     */
    const doSave = (name: string, asTemplate = false) => {
        try {
            const notes = readBufferNotes(dir)
            const { solutes: rows, definition } = recipeSave(readSolutes(dir), asTemplate)
            saveRecipe(root, name, rows, readConditions(dir), notes, definition)
            setMessage(savedAs(name, room))
        } catch (error) {
            setMessage(saveFailure(error))
        }
    }

    /** Saves; rows that follow one template first ask template, plain recipe or cancel. */
    const saveChecked = (name: string) => {
        let offer = false
        try {
            offer = offersTemplate(readSolutes(dir))
        } catch {
            return doSave(name)
        }
        if (!offer) return doSave(name)
        // Enter: the template; n: the plain recipe; Esc: nothing is saved
        confirm.ask(
            saveAsTemplateQuestion(name, room),
            () => doSave(name, true),
            undefined,
            () => doSave(name),
        )
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
            confirm.ask(replaceRecipeQuestion(name, room), () => saveChecked(name))
        else if (saved.length >= MAX_ROWS) setMessage(TOO_MANY_RECIPES)
        else saveChecked(name)
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
                label: recipeChoice(r.name, r.solutes.length, templateKind(r)),
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
        moveLegend(cursorMoves(cursor.index, options.length)),
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
                            : `pH ${formatNumber(conditions.pH)}  σ ${sigmaText}  ${
                                  conditions.temperature === undefined
                                      ? "temperature not set"
                                      : `${formatNumber(conditions.temperature)} °C`
                              }`}
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

/** The notes of the buffer as they are on disk, none for a file that cannot be used. */
function readNotesOrNone(dir: string): Note[] {
    try {
        return readBufferNotes(dir)
    } catch {
        return []
    }
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
// 2. The project menu
// ========================================================================================

/** The options of the project menu; exported so a test can check their hotkeys. */
export const projectMenuSpec = new MenuSpec(
    ["models", "data", "buffer", "logs", "settings", "open"], 2
)

/** What the menu says while the project cannot run (the taskbar has `notes` anyway). */
const missingNotice = (missing: readonly string[]): string =>
    `missing: ${missing.join(", ")}`

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
        return messageOf(error, "could not open the project")
    }
    if (!reset) return undefined
    const file = basename(settingsFile(project.dir))
    return `${file} unreadable: global used, old in .corrupt`
}

/**
 * The menu of a project: models, data, buffer, logs, settings and open (the project's
 * folder in the file manager, or with a run its runs). `logs` opens the list of the runs
 * (reading and restoring a run's inputs and logs). The taskbar offers `run: shift+r` when
 * the project can run (it starts the run at once with the buffer's temperature and opens
 * its screen; the project is not ready until the buffer has a temperature).
 *
 * @param project - the project.
 * @returns the screen.
 */
export function ProjectMenu({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const [notice, setNotice] = useState<string | undefined>(() => settingsNotice(project))
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

    /** `run: shift+r`: refuse a live run, else start at once (buffer's temperature). */
    const startRun = useCallback(() => {
        const live = liveRun(project.dir)
        if (live !== undefined) return setNotice(`a run is in progress (pid ${live.pid})`)
        setNotice(undefined)
        try {
            const temperature = readConditions(project.dir)?.temperature
            if (temperature === undefined) return setNotice(missingNotice(["temperature"]))
            nav.push(<RunScreen session={RunSession.begin(project.dir, temperature)} />)
        } catch (error) {
            setNotice(messageOf(error, "could not start the run"))
        }
    }, [project.dir, nav])

    /** `notes: shift+n`: the project's notes list; `^w` there writes `project.json`. */
    const openNotes = useCallback(() => {
        setNotice(undefined)
        try {
            const items = readProjectNotes(project.dir)
            nav.push(
                <NotesList
                    owner={project.id}
                    items={items}
                    onSave={(notes) => writeProjectNotes(project.dir, notes)}
                />,
            )
        } catch (error) {
            setNotice(messageOf(error, "could not open the notes"))
        }
    }, [nav, project])

    // read again when this menu comes back to the top (the screen that was open over it
    // may have changed the models or the buffer) and after every notice
    // biome-ignore lint/correctness/useExhaustiveDependencies: active, notice = re-read
    const taskbar = useMemo<TaskbarItem[]>(
        () => [
            ...(projectReadiness(project).run
                ? [{ ...taskbarKeys.run, onPress: startRun }]
                : []),
            { ...taskbarKeys.notes, onPress: openNotes },
        ],
        [project, active, notice, startRun, openNotes],
    )

    // while the project cannot run, a box names what is missing (shift+r replaces it)
    // biome-ignore lint/correctness/useExhaustiveDependencies: active, notice = re-read
    const missing = useMemo(() => missingComponents(project), [project, active, notice])

    return (
        <GridMenu
            spec={projectMenuSpec}
            header={<MenuHeader caption={`project: ${project.id}`} />}
            onChoose={choose}
            notice={notice ?? (missing.length > 0 ? missingNotice(missing) : undefined)}
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
                ) : undefined
            }
            overlayLegend={openKeys}
        />
    )
}

// ========================================================================================
// 3. The main menu
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
