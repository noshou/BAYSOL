// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useState } from "react"
import { truncate } from "../core/text.js"
import {
    colourHex,
    type ListKind,
    type SettingDef,
    type SettingValue,
} from "../store/settings-defs.js"
import { ChoiceTabs } from "../ui/choice-tabs.js"
import { Entry } from "../ui/entry.js"
import { keys } from "../ui/keys.js"
import { useBodyColumns } from "../ui/layout.js"
import { type LegendItem, legendFor } from "../ui/legend.js"
import { positionStatus, type Suggestion, SuggestionList } from "../ui/suggestion-list.js"
import { TextBuffer } from "../ui/text-buffer.js"
import { TextField } from "../ui/text-field.js"
import { useTheme } from "../ui/theme.js"
import {
    type EditEnd,
    indexOfPick,
    maxNameText,
    narrow,
    noteLines,
    openNumber,
    openTabs,
    openTuple,
    pasteNumber,
    pickValue,
    stepNumber,
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
const pickerLines = 6

/** What an editor is told. */
type SettingEditorProps = {
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
    const cancel = legendFor("cancel", keys.escape)
    const take = legendFor("take", keys.enter)
    switch (def.kind) {
        case "colour":
        case "font":
            return [
                legendFor("pick", [keys.up, keys.down]),
                legendFor("complete", keys.tab),
                take,
                cancel,
            ]
        case "set":
            return [
                legendFor("move", [keys.left, keys.right], keys.tab),
                legendFor("toggle", keys.enter),
                legendFor("done", keys.escape),
            ]
        case "tuple":
            return [
                legendFor("part", [keys.left, keys.right]),
                ...(def.partKinds.includes("colour")
                    ? [legendFor("pick colour", [keys.up, keys.down], keys.tab)]
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

/**
 * A number typed into the value cell of the sheet's table: the field, and under it the
 * error, wrapped to two lines at most. The cell's own box paints the background.
 *
 * @param props.def - the setting (an `int` or a `float`).
 * @param props.current - its value now.
 * @param props.width - the cells the field and the error may use.
 * @param props.onEnd - called once, when the edit is over.
 * @returns the cell's content: a space, the field, the error lines.
 */
export function InlineNumber(props: Omit<SettingEditorProps, "names"> & {
    width: number
}): ReactNode {
    const { def, current, width, onEnd } = props
    const theme = useTheme()
    const edit = useEditor(openNumber(def, current), stepNumber, onEnd, pasteNumber)
    const error = edit.error === undefined ? [] : noteLines(edit.error, width)
    return (
        <Box flexDirection="column">
            <Box>
                <Text> </Text>
                <TextField buffer={edit.buffer} width={width} />
            </Box>
            {error.map((line) => (
                <Text key={line} color={theme.er}>{` ${line}`}</Text>
            ))}
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
 * The names as suggestions, each colour with its swatch.
 *
 * @param names - the names to list.
 * @param colours - whether the names are colours, to give them swatches.
 * @returns the suggestions, in the order of `names`.
 */
function nameSuggestions(names: readonly string[], colours: boolean): Suggestion[] {
    return names.map((label) => ({
        label,
        swatch: colours ? colourHex(label) : undefined,
    }))
}

/**
 * The status line under the colours of a tuple's colour part.
 *
 * @param index - the highlighted colour.
 * @param count - how many colours match.
 * @returns `no match` or the place of the highlight.
 */
function tupleStatus(index: number, count: number): string {
    return count === 0 ? "no match" : positionStatus(index, count)
}

/** A colour or a font picked from a list: the shared [[Entry]], narrowing as one types. */
function PickerEditor(
    props: Omit<SettingEditorProps, "current"> & { kind: ListKind; current: string },
): ReactNode {
    const { def, kind, current, names, onEnd } = props
    const [error, setError] = useState<string | undefined>(undefined)
    const suggest = useCallback(
        (text: string) => nameSuggestions(narrow(names, text), kind === "colour"),
        [names, kind],
    )
    // stable: the entry calls it again whenever it changes
    const clearError = useCallback(() => setError(undefined), [])
    return (
        <Box flexDirection="column">
            <Heading def={def} />
            <Entry
                label={`${kind}:`}
                maxLength={maxNameText}
                placeholder="type to narrow"
                suggest={suggest}
                initialIndex={indexOfPick(names, current)}
                wrap
                counter
                noMatch="no match"
                lines={pickerLines}
                error={error}
                onChange={clearError}
                onSubmit={(text, chosen) => {
                    const picked = pickValue(kind, names, text, chosen?.label)
                    if ("error" in picked) setError(picked.error)
                    else onEnd({ kind: "done", value: picked.value })
                }}
                onCancel={() => onEnd({ kind: "cancel" })}
                onBack={() => onEnd({ kind: "back" })}
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
    const matches = tupleMatches(edit)
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
                    <SuggestionList
                        items={nameSuggestions(matches, true)}
                        highlight={edit.index}
                        lines={pickerLines}
                        width={columns}
                        status={tupleStatus(edit.index, matches.length)}
                    />
                ) : (
                    <Box height={pickerLines + 1} />
                )
            ) : null}
        </Box>
    )
}
