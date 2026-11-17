// SPDX-License-Identifier: LGPL-3.0-or-later

// The model screen of a project, modelled on the data screen: the facts of the current
// model, then the options (load a model, change a model, its settings). The reference fit
// is the project's ONE (the data screen edits it), so the model has no reference rows. The
// path prompt, the picker and the delete of the models list stay in `models.tsx`, which
// "load a model" opens.

import { Box, Text } from "ink"
import { type ReactNode, useMemo, useState } from "react"
import { truncate } from "../core/terminal.js"
import { listModels, type ProjectRef } from "../store/projects.js"
import { modelOverrides, modelScope, modelStem } from "../store/settings-store.js"
import { Frame } from "../ui/frame.js"
import {
    cursorMoves,
    type LegendItem,
    legendBack,
    legendEnter,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import { useNote } from "../ui/input.js"
import {
    CursorList,
    type KeyInput,
    keys,
    ListText,
    useBodyColumns,
    useKeys,
    useListCursor,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { ErrorText, Panel, useTheme } from "../ui/theme.js"
import { ModelsScreen } from "./models.js"
import { SettingsMenu } from "./settings-menu.js"

/** The options of the screen, in order. */
const modelOptions = [
    { id: "load", label: "load a model" },
    { id: "change", label: "change a model" },
    { id: "settings", label: "settings" },
] as const

/** The options that work without a model. */
const alwaysOn: ReadonlySet<string> = new Set(["load"])

/** The width of the name column of the facts. */
const LINE_NAME_WIDTH = 10

/** What is said when an option needs a model. */
const LOAD_FIRST = "load a model first"

/**
 * The facts of a model.
 *
 * @param count - how many models the project has.
 * @param file - the current model's file, `undefined` for none.
 * @param overrides - the names of the settings the model overrides.
 * @param width - the cells a value may use.
 * @returns `name  value` pairs: empty without a model.
 */
export function modelFacts(
    count: number,
    file: string | undefined,
    overrides: readonly string[] | undefined,
    width: number,
): [string, string][] {
    if (file === undefined) return []
    return [
        ["models", String(count)],
        ["model", truncate(file, width)],
        [
            "settings",
            overrides === undefined ? "project's" : truncate(overrides.join(", "), width),
        ],
    ]
}

/**
 * The model of a project: the facts of the current model and what can be done with it.
 * `load a model` opens the models screen (path, picker, list, delete); `change the
 * model` picks another of the project's models; `settings` opens the model's own
 * settings. The reference fit is the project's one and is edited on the data screen.
 * After a load the newly added model becomes the current one.
 *
 * @param props.project - the project.
 * @returns the screen.
 */
export function ModelScreen({ project }: { project: ProjectRef }): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const active = useScreenActive()
    const columns = useBodyColumns()
    const { note, say, clear } = useNote()
    const [picking, setPicking] = useState(false)
    const [current, setCurrent] = useState<string | undefined>()
    // read again when this screen is shown again (a load, a delete, a settings sheet)
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const names = useMemo(() => listModels(project.dir), [project.dir, nav.depth, active])
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const own = useMemo(
        () => modelOverrides(project.dir),
        [project.dir, nav.depth, active],
    )
    // the current model: the chosen one while it exists, else the first
    const file = current !== undefined && names.includes(current) ? current : names[0]
    const cursor = useListCursor(modelOptions.length, modelOptions.length)
    const chooser = useListCursor(names.length, Math.max(1, names.length))
    const facts = modelFacts(
        names.length,
        file,
        file === undefined ? undefined : own.get(modelStem(file)),
        columns - 22,
    )

    const choose = (id: (typeof modelOptions)[number]["id"]) => {
        if (id === "load") {
            const before = names
            return nav.push(
                <ModelsScreen
                    project={project}
                    onLeave={(after) => {
                        const added = after.find((n) => !before.includes(n))
                        if (added !== undefined) setCurrent(added)
                    }}
                />,
            )
        }
        if (file === undefined) return say(LOAD_FIRST, true)
        if (id === "change") {
            chooser.set(Math.max(0, names.indexOf(file)))
            return setPicking(true)
        }
        if (id === "settings")
            return nav.push(<SettingsMenu scope={modelScope(project, modelStem(file))} />)
    }

    useKeys((press: KeyInput) => {
        clear()
        if (picking) {
            if (press.is(keys.up)) chooser.move(-1)
            else if (press.is(keys.down)) chooser.move(1)
            else if (press.is(keys.back)) setPicking(false)
            else if (press.is(keys.enter)) {
                setCurrent(names[chooser.index])
                setPicking(false)
            }
            return
        }
        if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.enter)) {
            const option = modelOptions[cursor.index]
            if (option) choose(option.id)
        }
    })

    const legend: LegendItem[] = picking
        ? legendOf([
            legendBack,
            legendEnter,
            moveLegend(cursorMoves(chooser.index, names.length)),
        ])
        : legendOf([
            legendBack,
            legendEnter,
            moveLegend(cursorMoves(cursor.index, modelOptions.length)),
        ])

    return (
        <Frame
            title="model"
            subtitle={project.id}
            legend={legend}
            note={note?.text ?? (picking ? "enter takes the highlighted model" : undefined)}
            noteIsError={note?.error}
        >
            <Panel paddingX={1} flexDirection="column">
                {facts.length > 0 ? (
                    facts.map(([name, value]) => (
                        <Box key={name} columnGap={1}>
                            <Text color={theme.mt}>{name.padEnd(LINE_NAME_WIDTH)}</Text>
                            <Text color={theme.fg} wrap="truncate-end">
                                {value}
                            </Text>
                        </Box>
                    ))
                ) : (
                    <ErrorText>no models yet!</ErrorText>
                )}
            </Panel>
            <Box marginTop={1}>
                {picking ? (
                    <CursorList
                        items={names}
                        index={chooser.index}
                        offset={chooser.offset}
                        lines={Math.max(1, names.length)}
                        active
                        row={(n, on) => <ListText on={on}>{n}</ListText>}
                    />
                ) : (
                    <CursorList
                        items={modelOptions}
                        index={cursor.index}
                        offset={cursor.offset}
                        lines={modelOptions.length}
                        active
                        row={(o, on) => (
                            <ListText on={on && (file !== undefined || alwaysOn.has(o.id))}>
                                {o.label}
                            </ListText>
                        )}
                    />
                )}
            </Box>
        </Frame>
    )
}
