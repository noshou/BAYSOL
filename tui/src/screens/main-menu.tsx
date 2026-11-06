// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import { useApp } from "ink"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { copyOver, entryNames } from "../core/files.js"
import { openFolder } from "../core/open-folder.js"
import { appDir, projectsDir } from "../core/paths.js"
import { readSystem } from "../core/system.js"
import { version } from "../core/version.js"
import {
    brokenNames,
    createProject,
    deleteProject,
    InvalidNameError,
    listProjects,
    projectNameProblem,
} from "../store/projects.js"
import { globalScope } from "../store/scope.js"
import { loadGlobal, settingsFile } from "../store/settings-store.js"
import type { Choice } from "../ui/dropdown.js"
import { GridMenu, MenuSpec } from "../ui/grid-menu.js"
import type { LegendItem } from "../ui/legend.js"
import { MenuHeader } from "../ui/menu-header.js"
import { useNav } from "../ui/nav.js"
import { usePickList } from "../ui/pick-list.js"
import { Prompt } from "../ui/prompt.js"
import { destructiveQuestion } from "../ui/use-confirm.js"
import { ProjectMenu } from "./project-menu.js"
import { SettingsMenu } from "./settings-menu.js"

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
 * project and Enter then deletes it, as in the lists of recipes and models.
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
                const problem = await openFolder(readSystem(), projectsDir(), setNotice)
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
