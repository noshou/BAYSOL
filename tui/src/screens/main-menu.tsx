// SPDX-License-Identifier: LGPL-3.0-or-later

import { useApp } from "ink"
import { join } from "node:path"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { appDir, projectsDir } from "../core/paths.js"
import { readSystem } from "../core/system.js"
import { copyOver } from "../core/files.js"
import { brokenNames, createProject, entryNames, InvalidNameError, listProjects, nameProblem } from "../store/projects.js"
import { loadGlobal, settingsFile } from "../store/settings-store.js"
import { openFolder } from "../system/open-folder.js"
import { version } from "../core/version.js"
import { type Choice, Dropdown, filterChoices } from "../ui/dropdown.js"
import { GridMenu, MenuSpec } from "../ui/grid-menu.js"
import { MenuHeader } from "../ui/menu-header.js"
import { useNav } from "../ui/nav.js"
import { Prompt } from "../ui/prompt.js"
import { ProjectMenu } from "./project-menu.js"
import { SettingsMenu } from "./settings-menu.js"
import { globalScope } from "../store/scope.js"

const menu = new MenuSpec(["new", "load", "open", "settings", "help", "quit"], "2x3")

/** The most characters a project name takes while typing; `nameProblem` tells a long one. */
const nameTyped = 60

/** What the menu shows under the grid in place of its hint. */
type Overlay = "new" | "load" | null

/**
 * The main menu: make a project, load one, open the projects folder, the global
 * settings, help (not built) and quit. A name prompt or the project list opens right
 * under the grid.
 *
 * @returns the screen.
 */
export function MainMenu(): ReactNode {
    const nav = useNav()
    const { suspendTerminal } = useApp()
    const [overlay, setOverlay] = useState<Overlay>(null)
    const [error, setError] = useState<string>()
    const [notice, setNotice] = useState<string>()

    const choose = useCallback((name: (typeof menu.names)[number]) => {
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
        const problem = nameProblem(id, entryNames(root), brokenNames(root))
        if (problem !== undefined) return setError(problem)
        try {
            const dir = createProject(appDir(), id, {
                prepareGlobal: () => { loadGlobal(appDir()) },
                copySettings: (to) => { copyOver(settingsFile(appDir()), settingsFile(to)) },
            })
            setOverlay(null)
            nav.push(<ProjectMenu project={{ id, dir }} />)
        } catch (e) {
            setError(e instanceof InvalidNameError ? e.message : `could not make it: ${(e as Error).message}`)
        }
    }, [nav])

    const projects = useMemo<Choice<string>[]>(
        () => (overlay === "load" ? listProjects(projectsDir()).map((id) => ({ label: id, value: id })) : []),
        [overlay]
    )

    let shown: ReactNode
    if (overlay === "new")
        shown = (
            <Prompt
                label="new project:"
                maxLength={nameTyped}
                error={error}
                onChange={() => setError(undefined)}
                onSubmit={create}
                onCancel={() => setOverlay(null)}
            />
        )
    else if (overlay === "load")
        shown = (
            <Dropdown<string>
                label="load project:"
                search={filterChoices(projects)}
                noMatch="no match"
                onPick={(id) => {
                    setOverlay(null)
                    nav.push(<ProjectMenu project={{ id, dir: join(projectsDir(), id) }} />)
                }}
                onCancel={() => setOverlay(null)}
            />
        )

    return (
        <GridMenu
            spec={menu}
            header={<MenuHeader caption={version} />}
            onChoose={choose}
            escape="ignore"
            notice={notice}
            overlay={shown}
        />
    )
}
