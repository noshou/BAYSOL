// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { isFolder } from "../core/files.js"
import { openFileManager } from "../core/open-folder.js"
import { readSystem } from "../core/system.js"
import { projectReadiness } from "../store/readiness.js"
import { hasFinishedRun, hasRuns } from "../store/runs.js"
import { loadScope, type ProjectRef, projectScope } from "../store/scope.js"
import { settingsFile } from "../store/settings-store.js"
import { GridMenu, MenuSpec, type TaskbarItem } from "../ui/grid-menu.js"
import { taskbarKeys } from "../ui/keys.js"
import { MenuHeader } from "../ui/menu-header.js"
import { useNav, useScreenActive } from "../ui/nav.js"
import { BufferLanding } from "./buffer-landing.js"
import { DataScreen } from "./data-screen.js"
import { ModelsScreen } from "./models-screen.js"
import { SettingsMenu } from "./settings-menu.js"

/** The options of the project menu; exported so a test can check their hotkeys. */
export const projectMenuSpec = new MenuSpec(
    ["models", "data", "buffer", "logs", "settings", "open"], 2
)

/** The notice of the `logs` option when the project has no run folder. */
const NO_RUNS_NOTICE = "no runs yet"

/**
 * The notice of a taskbar item or of `logs` until its feature exists.
 *
 * @param label - the item, e.g. `"run"`.
 * @returns `run: coming in a later step`.
 */
const laterNotice = (label: string): string => `${label}: coming in a later step`

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
    return `${file} was unreadable: global settings used, old file kept as ${file}.corrupt`
}

/**
 * The taskbar of a project: `run` when the project can run a fit, `results` when a run
 * finished. Only the items that apply are returned.
 *
 * @param project - the project.
 * @param press - what each item does, by its name (`run`, `results`).
 * @returns the items, in that order.
 */
function taskbarOf(
    project: ProjectRef, press: (name: keyof typeof taskbarKeys) => void
): TaskbarItem[] {
    const item = (name: keyof typeof taskbarKeys): TaskbarItem => ({
        ...taskbarKeys[name],
        onPress: () => press(name),
    })
    return [
        projectReadiness(project).run ? item("run") : undefined,
        hasFinishedRun(project.dir) ? item("results") : undefined,
    ].filter((i): i is TaskbarItem => i !== undefined)
}

/**
 * The menu of a project: models, data, buffer, logs, settings and open (the
 * project's folder in the file manager). The taskbar offers run and results when
 * they apply; they are placeholders until their steps are built.
 *
 * @param project - the project.
 * @returns the screen.
 */
export function ProjectMenu({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const [notice, setNotice] = useState<string | undefined>(() => settingsNotice(project))
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
        else if (name === "logs")
            setNotice(hasRuns(project.dir) ? laterNotice("logs") : NO_RUNS_NOTICE)
        else {
            // the file manager runs on its own: the terminal is not given up
            void openFileManager(readSystem(), project.dir).then((problem) => {
                if (problem !== undefined)
                    setNotice(`could not open the file manager: ${problem}`)
            })
        }
    }, [nav, project])

    // read again when this menu comes back to the top (the screen that was open over it
    // may have changed the models or the buffer) and after every notice
    // biome-ignore lint/correctness/useExhaustiveDependencies: active, notice = re-read
    const taskbar = useMemo(
        () => taskbarOf(project, (name) => setNotice(laterNotice(name))),
        [project, active, notice]
    )

    return (
        <GridMenu
            spec={projectMenuSpec}
            header={<MenuHeader caption={`project: ${project.id}`} />}
            onChoose={choose}
            notice={notice}
            taskbar={taskbar}
        />
    )
}
