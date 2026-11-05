// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { padWidth, truncate } from "../core/text.js"
import type { SettingDef, SettingValue } from "../store/settings-defs.js"
import { swatch } from "../store/solutes.js"
import { ChoiceTabs } from "../ui/choice-tabs.js"
import { useBodyColumns } from "../ui/layout.js"
import type { LegendItem } from "../ui/legend.js"
import { listWindowStart } from "../ui/suggestion-list.js"
import { TextBuffer } from "../ui/text-buffer.js"
import { TextField } from "../ui/text-field.js"
import { useTheme } from "../ui/theme.js"
import {
    type EditEnd,
    hexOf,
    openNumber,
    openPicker,
    openTabs,
    openTuple,
    type PickerKind,
    pasteNumber,
    pastePicker,
    pickerMatches,
    stepNumber,
    stepPicker,
    stepTabs,
    stepTuple,
    tupleMatches,
} from "./setting-edit.js"
import { useEditor } from "./use-editor.js"

/**
 * The value editors of the settings sheet: a number typed in, a colour or a font picked
 * from a list, some of a few choices turned on and off as tabs, a tuple typed part by
 * part. A yes/no setting needs no editor, the sheet turns it over. Each editor is drawn
 * in the detail area under the list of settings, so it has the whole width and its
 * dropdown never covers the settings. The rules are in `setting-edit.ts`.
 */

/** The most names a list of colours or fonts shows at once. */
export const pickerLines = 6

/** The cells a swatch takes: two blocks and a gap. */
const swatchCells = 3

/** What an editor is told. */
export type SettingEditorProps = {
    /** The setting being edited (not a yes/no one). */
    def: SettingDef
    /** Its value now (draft or saved). */
    current: SettingValue
    /** The names to pick from: colours, or fonts (empty when the setting has no list). */
    names: readonly string[]
    /** Called once, when the edit is over. */
    onEnd: (end: EditEnd<SettingValue>) => void
}

/**
 * Whether an editor needs a list of names (colours or fonts).
 *
 * @param def - the setting.
 * @returns true for a colour, a font, and a tuple with a colour part.
 */
export function needsNames(def: SettingDef): boolean {
    return (
        def.kind === "colour" ||
        def.kind === "font" ||
        (def.kind === "tuple" && def.partKinds.includes("colour"))
    )
}

/**
 * The rows an editor takes, so the sheet can leave room for it under its list: a
 * heading, the field or parts, a line for an error and a list of names if there is one.
 *
 * @param def - the setting.
 * @returns the number of rows.
 */
export function editorRows(def: SettingDef): number {
    const list = pickerLines + 1
    switch (def.kind) {
        case "colour":
        case "font":
            return 3 + list
        case "tuple":
            return 2 + def.partNames.length + (def.partKinds.includes("colour") ? list : 0)
        default:
            return 3
    }
}

/**
 * The keys an editor answers to, for the legend of the screen.
 *
 * @param def - the setting.
 * @returns the legend items.
 */
export function editorLegend(def: SettingDef): LegendItem[] {
    const cancel = { label: "cancel", keys: "esc" }
    const take = { label: "take", keys: "⏎" }
    switch (def.kind) {
        case "colour":
        case "font":
            return [
                { label: "pick", keys: "↑↓" },
                { label: "complete", keys: "tab" },
                take,
                cancel,
            ]
        case "set":
            return [
                { label: "move", keys: "←→ tab" },
                { label: "toggle", keys: "⏎" },
                { label: "done", keys: "esc" },
            ]
        case "tuple":
            return [
                { label: "part", keys: "←→" },
                ...(def.partKinds.includes("colour")
                    ? [{ label: "pick colour", keys: "↑↓ tab" }]
                    : []),
                take,
                cancel,
            ]
        default:
            return [take, cancel]
    }
}

/**
 * The editor of a setting, by its kind.
 *
 * @param props - see [[SettingEditorProps]].
 * @returns the editor, or nothing for a yes/no setting.
 */
export function SettingEditor(props: SettingEditorProps): ReactNode {
    const { def, current, names, onEnd } = props
    switch (def.kind) {
        case "int":
        case "float":
            return <NumberEditor def={def} current={current} onEnd={onEnd} />
        case "colour":
        case "font":
            return (
                <PickerEditor
                    def={def}
                    kind={def.kind}
                    current={current as string}
                    names={names}
                    onEnd={onEnd}
                />
            )
        case "set":
            return <TabsEditor def={def} current={current as string[]} onEnd={onEnd} />
        case "tuple":
            return <TupleEditor def={def} current={current} names={names} onEnd={onEnd} />
        default:
            return null
    }
}

/** The line that names the setting being edited. */
function Heading({ def }: { def: SettingDef }): ReactNode {
    const theme = useTheme()
    return (
        <Text bold color={theme.fg}>
            {def.name}
        </Text>
    )
}

/** The line for an error, kept (blank) when there is none so the editor never jumps. */
function ErrorLine({ error }: { error?: string }): ReactNode {
    const theme = useTheme()
    const columns = useBodyColumns()
    const text = error === undefined ? " " : truncate(error, columns)
    return <Text color={theme.er}>{text}</Text>
}

/** A number typed in. */
function NumberEditor(props: Omit<SettingEditorProps, "names">): ReactNode {
    const { def, current, onEnd } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const edit = useEditor(openNumber(def, current), stepNumber, onEnd, pasteNumber)
    const label = def.kind === "int" ? "whole number:" : "number:"
    return (
        <Box flexDirection="column">
            <Heading def={def} />
            <Box columnGap={1}>
                <Text color={theme.mt}>{label}</Text>
                <TextField buffer={edit.buffer} width={columns - 16} />
            </Box>
            <ErrorLine error={edit.error} />
        </Box>
    )
}

/** Some of a few choices, as tabs. */
function TabsEditor(props: Omit<SettingEditorProps, "names" | "current"> & {
    current: string[]
}): ReactNode {
    const { def, current, onEnd } = props
    const edit = useEditor(openTabs(def, current), stepTabs, onEnd)
    return (
        <Box flexDirection="column">
            <Heading def={def} />
            <ChoiceTabs
                options={edit.options}
                selected={edit.selected}
                focus={edit.focus}
            />
            <ErrorLine error={edit.error} />
        </Box>
    )
}

/**
 * A list of names with the highlighted one marked, each colour with its swatch.
 *
 * @param props.matches - the names to list.
 * @param props.index - the highlighted one.
 * @param props.colours - whether the names are colours, to draw their swatches.
 * @returns the list, `pickerLines` long at most, with a status line under it.
 */
function NameList(props: {
    matches: readonly string[]
    index: number
    colours: boolean
}): ReactNode {
    const { matches, index, colours } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const start = listWindowStart(matches.length, index, pickerLines)
    const room = Math.max(1, columns - 2 - (colours ? swatchCells : 0))
    const status = matches.length === 0 ? "no match" : `${index + 1} of ${matches.length}`
    return (
        <Box flexDirection="column">
            {matches.slice(start, start + pickerLines).map((name, i) => {
                const on = start + i === index
                const rgb = colours ? swatch(name) : undefined
                return (
                    <Text key={name} bold={on} color={on ? theme.fg : theme.mt}>
                        {on ? "> " : "  "}
                        {colours ? (
                            rgb === undefined ? (
                                "   "
                            ) : (
                                <Text color={hexOf(rgb)}>{"██ "}</Text>
                            )
                        ) : null}
                        {padWidth(name, room)}
                    </Text>
                )
            })}
            <Text color={theme.mt}>{status}</Text>
        </Box>
    )
}

/** A colour or a font picked from a list. */
function PickerEditor(
    props: Omit<SettingEditorProps, "current"> & { kind: PickerKind; current: string },
): ReactNode {
    const { def, kind, current, names, onEnd } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const edit = useEditor(openPicker(kind, names, current), stepPicker, onEnd, pastePicker)
    return (
        <Box flexDirection="column">
            <Heading def={def} />
            <Box columnGap={1}>
                <Text color={theme.mt}>{kind}:</Text>
                <TextField
                    buffer={edit.buffer}
                    width={columns - 10}
                    placeholder="type to narrow"
                />
            </Box>
            <ErrorLine error={edit.error} />
            <NameList
                matches={pickerMatches(edit)}
                index={edit.index}
                colours={kind === "colour"}
            />
        </Box>
    )
}

/** A tuple typed part by part, with a list of colours under a colour part. */
function TupleEditor(props: SettingEditorProps): ReactNode {
    const { def, current, names, onEnd } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const edit = useEditor(openTuple(def, current, names), stepTuple, onEnd)
    const label = Math.max(...def.partNames.map((n) => n.length))
    const colour = def.partKinds[edit.focus] === "colour"
    return (
        <Box flexDirection="column">
            <Heading def={def} />
            {def.partNames.map((part, i) => {
                const focused = i === edit.focus
                const text = edit.buffers[i] as string
                const room = Math.max(5, columns - label - 6)
                return (
                    <Box key={part} columnGap={1}>
                        <Text color={focused ? theme.fg : theme.mt} bold={focused}>
                            {focused ? ">" : " "} {part.padEnd(label)}:
                        </Text>
                        {focused && !edit.fresh.has(i) ? (
                            <TextField buffer={new TextBuffer(text)} width={room} />
                        ) : (
                            <Text color={focused ? theme.fg : theme.mt} inverse={focused}>
                                {truncate(text, room)}
                            </Text>
                        )}
                    </Box>
                )
            })}
            <ErrorLine error={edit.error} />
            {edit.names.length > 0 ? (
                colour ? (
                    <NameList matches={tupleMatches(edit)} index={edit.index} colours />
                ) : (
                    <Box height={pickerLines + 1} />
                )
            ) : null}
        </Box>
    )
}
