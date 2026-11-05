// SPDX-License-Identifier: LGPL-3.0-or-later

import { basename } from "node:path"
import { type ReactNode, useCallback, useMemo, useState } from "react"
import { runIds } from "../store/runs.js"
import { type ProjectRef, projectScope } from "../store/scope.js"
import { loadScope } from "../store/scope.js"
import { settingsFile } from "../store/settings-store.js"
import { type Choice, Dropdown, filterChoices } from "../ui/dropdown.js"
import { GridMenu, MenuSpec } from "../ui/grid-menu.js"
import { MenuHeader } from "../ui/menu-header.js"
import { useNav } from "../ui/nav.js"
import { BufferLanding } from "./buffer-landing.js"
import { ModelsScreen } from "./models-screen.js"
import { SettingsMenu } from "./settings-menu.js"

const menu = new MenuSpec(["models", "data", "buffer", "logs", "settings", "run"], "2x3")

/** Which folder of runs a dropdown lists: the options `data` and `logs` of the menu. */
type RunsKind = "data" | "logs"

/**
 * Opens the project's settings once, which checks them: the notice says so if the
 * file could not be read and the global settings were put in its place.
 *
 * @param project - the project.
 * @returns the notice for the user, or `undefined` if the settings were fine.
 */
function settingsNotice(project: ProjectRef): string | undefined {
    const { reset } = loadScope(projectScope(project))
    if (!reset) return undefined
    const file = basename(settingsFile(project.dir))
    return `${file} was unreadable: global settings used, old file kept as ${file}.corrupt`
}

/**
 * The menu of a project: models, data, buffer, logs, settings and run (run does
 * nothing yet). `data` and `logs` list the runs the project has.
 *
 * @param project - the project.
 * @returns the screen.
 */
export function ProjectMenu({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const [runs, setRuns] = useState<RunsKind | null>(null)
    const [notice, setNotice] = useState<string | undefined>(() => settingsNotice(project))

    const choose = useCallback((name: (typeof menu.names)[number]) => {
        setNotice(undefined)
        if (name === "models") nav.push(<ModelsScreen project={project} />)
        else if (name === "buffer") nav.push(<BufferLanding project={project} />)
        else if (name === "settings") nav.push(<SettingsMenu scope={projectScope(project)} />)
        else if (name === "run") setNotice("running a fit from here is not built yet")
        else if (runIds(project.dir, name).length === 0) setNotice("no runs exist!")
        else setRuns(name)
    }, [nav, project])

    const choices = useMemo<Choice<string>[]>(
        () => (runs === null ? [] : runIds(project.dir, runs).map((id) => ({ label: id, value: id }))),
        [runs, project.dir]
    )

    return (
        <GridMenu
            spec={menu}
            header={<MenuHeader caption={`project: ${project.id}`} />}
            onChoose={choose}
            notice={notice}
            overlay={
                runs === null ? undefined : (
                    <Dropdown<string>
                        label={`${runs}:`}
                        search={filterChoices(choices)}
                        onPick={() => setRuns(null)}
                        onCancel={() => setRuns(null)}
                    />
                )
            }
        />
    )
}
