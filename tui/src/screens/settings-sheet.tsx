// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useReducer, useRef, useState } from "react"
import { listFonts } from "../core/fonts.js"
import { cacheDir } from "../core/paths.js"
import { readSystem } from "../core/system.js"
import { padWidth, wrapText } from "../core/text.js"
import { loadScope, type Scope, scopeTitle } from "../store/scope.js"
import type { SettingDef, SettingValue } from "../store/settings-defs.js"
import { colourHex, settingNames } from "../store/settings-defs.js"
import { type Settings, sameValue } from "../store/settings-store.js"
import { Frame } from "../ui/frame.js"
import { keys } from "../ui/keys.js"
import { useBodyColumns, useBodyRows } from "../ui/layout.js"
import { legendBack, legendFor, legendOf, moveLegend } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { Swatch, swatchCells } from "../ui/swatch.js"
import type { RulePart } from "../ui/table-lines.js"
import { Bar, BarColumn, Rule } from "../ui/table-segments.js"
import { useTheme } from "../ui/theme.js"
import { useDiscardGuard } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"
import {
    blocksFitting,
    descriptionLines,
    type EditEnd,
    noteLines,
    scrollTop,
    swatchColour,
    type TableWidths,
    tableWidths,
    valueText,
    withDraft,
} from "./setting-edit.js"
import {
    editorLegend,
    editorRows,
    InlineNumber,
    needsNames,
    SettingEditor,
} from "./setting-editors.js"

/**
 * What the sheet is told.
 *
 * @property scope - whose settings: the global ones or a project's.
 * @property sheetId - which sheet: `output`, `model`, `sampler` or `plots`.
 */
type SettingsSheetProps = { scope: Scope; sheetId: string }

/** The lines the table spends besides its blocks: top rule, header, rule, bottom rule. */
const tableOverhead = 4

/** The lines a block has while a number is typed in its value cell: field and error. */
const editingLines = 3

/** What is wrong with a value at a save: a sentence, and a short one for a row. */
type Fault = { message: string; short: string }

/** `1 setting`, `3 settings`. */
function plural(n: number): string {
    return `${n} setting${n === 1 ? "" : "s"}`
}

/** Copy of a map without some keys. */
function without<V>(map: ReadonlyMap<string, V>, ...gone: string[]): Map<string, V> {
    const next = new Map(map)
    for (const name of gone) next.delete(name)
    return next
}

/**
 * A settings sheet in the shape of the old pre-rendered pages, made to fit any size:
 * one group of settings at a time in a table of three columns (name, description,
 * value) in double lines. The description of a setting wraps to its column, so a
 * setting is as many lines high as it needs. Up and down move among the settings of
 * the group (the table scrolls when the group is taller than the room), left and right
 * switch group, Enter edits. An edit becomes a draft, marked `*`, kept until it is
 * saved (^w) or undone (^u for one setting, ^r for the group). Saving checks all the
 * drafts together, so a rule that ties two settings is judged on the values they would
 * have; if anything is wrong nothing is saved and each setting at fault says why.
 * Leaving with drafts asks first.
 *
 * @param props - see [[SettingsSheetProps]].
 * @returns the screen.
 */
export function SettingsSheet({ scope, sheetId }: SettingsSheetProps): ReactNode {
    // the settings are read once per opening of the sheet, wiped values noticed
    const [settings] = useState(() => loadScope(scope).settings)
    if (settings.catalog.sheet(sheetId) === undefined)
        throw new Error(`there is no settings sheet ${sheetId}`)
    return <Sheet scope={scope} settings={settings} sheetId={sheetId} />
}

/** The sheet proper, once its settings are loaded and its id is known to be good. */
function Sheet(
    { scope, settings, sheetId }: SettingsSheetProps & { settings: Settings },
): ReactNode {
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    const sheet = settings.catalog.sheet(sheetId)
    const groups = sheet?.groups ?? []

    const [group, setGroup] = useState(0)
    const [selected, setSelected] = useState(0)
    const top = useRef(0)
    const [drafts, setDrafts] = useState<ReadonlyMap<string, SettingValue>>(new Map())
    const [errors, setErrors] = useState<ReadonlyMap<string, Fault>>(new Map())
    // notices of wiped settings that an edit has dealt with
    const [dismissed, setDismissed] = useState<ReadonlySet<string>>(new Set())
    const [editing, setEditing] = useState<string>()
    const [status, setStatus] = useState<{ text: string; error: boolean }>()
    const [, redraw] = useReducer((n: number) => n + 1, 0)
    const fonts = useRef<ReturnType<typeof listFonts>>(undefined)
    const guard = useDiscardGuard(drafts.size)

    const defs = groups[group]?.settings ?? []
    const here = defs[Math.min(selected, defs.length - 1)] as SettingDef
    const at = defs.indexOf(here)
    const editedDef = editing === undefined ? undefined : settings.catalog.get(editing)
    const inline = editedDef?.kind === "int" || editedDef?.kind === "float"
    const below = editedDef !== undefined && !inline

    const noticeOf = (name: string): string | undefined =>
        dismissed.has(name) ? undefined : settings.notices.get(name)
    const valueFor = (d: SettingDef): SettingValue =>
        drafts.get(d.name) ?? settings.get(d.name)

    // --- the layout
    const longest = Math.max(
        1,
        ...groups.flatMap((g) => g.settings.map((d) => d.name.length)),
    )
    const widths = tableWidths(columns, longest)
    const noteOf = (d: SettingDef): string | undefined =>
        errors.get(d.name)?.short ?? noticeOf(d.name)
    const heights = defs.map((d) => {
        const note = noteOf(d)
        const own = note === undefined ? 1 : 1 + noteLines(note, widths.value - 2).length
        const min = d.name === editing && inline ? editingLines : own
        return Math.max(descriptionLines(d, widths.desc - 2).length, min)
    })
    const bodyRows = useBodyRows(below ? editorRows(editedDef) : 0)
    const budget = Math.max(1, bodyRows - tableOverhead)
    const first = scrollTop(heights, top.current, at, budget)
    top.current = first
    const count = blocksFitting(heights, first, budget)

    const resettable = defs.some(
        (d) => !sameValue(valueFor(d), settings.resetValue(d.name)),
    )
    const hasPrev = group > 0
    const hasNext = group < groups.length - 1

    // --- what the keys do
    const draft = (d: SettingDef, value: SettingValue): void => {
        setDrafts((was) => withDraft(was, d.name, settings.get(d.name), value))
        setErrors((was) => without(was, d.name))
    }
    const undo = (d: SettingDef): void => {
        setDrafts((was) => without(was, d.name))
        setErrors((was) => without(was, d.name))
    }
    const resetGroup = (): void => {
        setDrafts((was) => {
            let next = was
            for (const d of defs) {
                const reset = settings.resetValue(d.name)
                next = withDraft(next, d.name, settings.get(d.name), reset)
            }
            return next
        })
        setErrors((was) => without(was, ...defs.map((d) => d.name)))
        setDismissed((was) => new Set([...was, ...defs.map((d) => d.name)]))
    }
    const save = (): void => {
        const changes = Object.fromEntries(drafts)
        const ev = settings.evaluate(changes)
        if (!ev.ok) {
            setErrors(ev.errors)
            setStatus({
                text: `${plural(ev.errors.size)} cannot be saved: see the marked rows`,
                error: true,
            })
            return
        }
        try {
            settings.set(changes)
            settings.save()
        } catch (e) {
            setStatus({ text: `could not save: ${(e as Error).message}`, error: true })
            return
        }
        setStatus({ text: `saved ${plural(drafts.size)}`, error: false })
        setDrafts(new Map())
        setErrors(new Map())
        redraw()
    }
    const edit = (d: SettingDef): void => {
        if (d.kind === "bool") {
            draft(d, !(valueFor(d) as boolean))
            return
        }
        if (d.kind === "font") fonts.current ??= listFonts(readSystem(), cacheDir())
        setEditing(d.name)
    }
    const endEdit = (end: EditEnd<SettingValue>): void => {
        setEditing(undefined)
        if (end.kind === "back") guard.leave(nav.pop)
        else if (end.kind === "done" && editedDef !== undefined) {
            draft(editedDef, end.value)
            setDismissed((was) => new Set([...was, editedDef.name]))
        }
    }
    const goto = (g: number): void => {
        setGroup(g)
        setSelected(0)
        top.current = 0
    }

    useKeys((press) => {
        if (guard.handleKey(press)) return
        setStatus(undefined)
        if (press.is(keys.back)) guard.leave(nav.pop)
        else if (press.is(keys.save) && drafts.size > 0) save()
        else if (press.is(keys.up)) setSelected(Math.max(0, at - 1))
        else if (press.is(keys.down)) setSelected(Math.min(defs.length - 1, at + 1))
        else if (press.is(keys.left) && hasPrev) goto(group - 1)
        else if (press.is(keys.right) && hasNext) goto(group + 1)
        else if (press.is(keys.enter)) edit(here)
        else if (press.is(keys.undo)) undo(here)
        else if (press.is(keys.remove) && resettable) resetGroup()
    }, editing === undefined)

    // --- drawing
    const fault = errors.get(here.name)?.message
    const note = guard.note ?? status?.text ?? (fault && `${here.name} ${fault}`)
    const noteIsError = guard.question === undefined && (status?.error === true || !status)
    const legend =
        editedDef !== undefined
            ? editorLegend(editedDef)
            : legendOf([
                legendBack,
                drafts.size > 0 && legendFor("save", keys.save),
                legendFor("edit", keys.enter),
                hasNext && legendFor("next group", keys.right),
                hasPrev && legendFor("prev group", keys.left),
                moveLegend({ up: at > 0, down: at < defs.length - 1 }),
                drafts.has(here.name) && legendFor("undo", keys.undo),
                resettable && legendFor("reset group", keys.remove),
            ])
    const bar = (part: RulePart): ReactNode => (
        <Rule
            style="double"
            part={part}
            widths={[widths.name, widths.desc, widths.value]}
            indent={3}
            background={theme.bg}
        />
    )

    return (
        <Frame
            logo="blocky"
            title={`${sheet?.title ?? sheetId} settings`}
            subtitle={
                scope.kind === "project"
                    ? `${scopeTitle(scope)} · ${scope.project.id}`
                    : scopeTitle(scope)
            }
            counter={`${groups[group]?.title ?? ""} [${group + 1} / ${groups.length}]`}
            legend={legend}
            note={note || undefined}
            noteIsError={noteIsError}
        >
            <Box flexDirection="column" flexGrow={1}>
                {bar("top")}
                <Header widths={widths} />
                {defs.slice(first, first + count).map((d, i) => {
                    const index = first + i
                    return (
                        <Box key={d.name} flexDirection="column">
                            {bar("mid")}
                            <Block
                                def={d}
                                widths={widths}
                                height={heights[index] as number}
                                on={index === at}
                                value={valueFor(d)}
                                draft={drafts.has(d.name)}
                                note={noteOf(d)}
                                isError={errors.has(d.name)}
                                inline={inline && d.name === editing}
                                onEnd={endEdit}
                            />
                        </Box>
                    )
                })}
                {bar("bottom")}
                {below ? (
                    <SettingEditor
                        key={editedDef.name}
                        def={editedDef}
                        current={valueFor(editedDef)}
                        names={editNames(editedDef, fonts.current)}
                        onEnd={endEdit}
                    />
                ) : null}
            </Box>
        </Frame>
    )
}

/** The cells of a column's text: a space, the text cut to fit, padded to the width. */
const cell = (text: string, width: number): string => ` ${padWidth(text, width - 1)}`

/** The row of column titles. */
function Header({ widths }: { widths: TableWidths }): ReactNode {
    const theme = useTheme()
    const title = (text: string, width: number): string =>
        padWidth(text.padStart(Math.floor((width + text.length) / 2)), width)
    const bar = <Bar style="double" />
    return (
        <Text backgroundColor={theme.bg}>
            {"   "}
            {bar}
            <Text color={theme.mt}>{title("name", widths.name)}</Text>
            {bar}
            <Text color={theme.mt}>{title("description", widths.desc)}</Text>
            {bar}
            <Text color={theme.mt}>{title("value", widths.value)}</Text>
            {bar}
        </Text>
    )
}

/**
 * One setting of the table: a block of `height` lines in three columns. The selected
 * one is in full colour with the cursor `>` in the margin; the others are muted.
 *
 * @param props.def - the setting.
 * @param props.widths - the columns.
 * @param props.height - the lines of the block.
 * @param props.on - whether it is the selected one.
 * @param props.value - its value (the draft, else the saved one).
 * @param props.draft - whether the value is an unsaved draft (marked `*`).
 * @param props.note - the short error or notice for the cell under the value.
 * @param props.isError - whether the note is an error (else a notice, also drawn red).
 * @param props.inline - whether a number is being typed in the value cell.
 * @param props.onEnd - called when that edit is over.
 * @returns the block.
 */
function Block(props: {
    def: SettingDef
    widths: TableWidths
    height: number
    on: boolean
    value: SettingValue
    draft: boolean
    note?: string
    isError: boolean
    inline: boolean
    onEnd: (end: EditEnd<SettingValue>) => void
}): ReactNode {
    const { def, widths, height, on, value, draft, note, inline, onEnd } = props
    const theme = useTheme()
    const ink = on ? theme.fg : theme.mt
    const lines = (texts: string[], width: number): string =>
        Array.from({ length: height }, (_, i) => cell(texts[i] ?? "", width)).join("\n")
    const colour = swatchColour(def, value)
    const shade = colour === undefined ? undefined : colourHex(colour)
    const room = widths.value - 2 - (shade === undefined ? 0 : swatchCells + 1)
    const mark = draft ? "*" : " "
    const description = wrapText(def.description, widths.desc - 2)
    return (
        <Box backgroundColor={theme.bg}>
            <Text color={theme.fg} bold>{on ? " > " : "   "}</Text>
            <BarColumn style="double" height={height} />
            <Text color={ink} bold={on}>{lines([def.name], widths.name)}</Text>
            <BarColumn style="double" height={height} />
            <Text color={ink}>{lines(description, widths.desc)}</Text>
            <BarColumn style="double" height={height} />
            <Box width={widths.value} height={height} flexDirection="column">
                {inline ? (
                    <InlineNumber
                        def={def}
                        current={value}
                        width={widths.value - 2}
                        onEnd={onEnd}
                    />
                ) : (
                    <>
                        <Text color={ink}>
                            {" "}
                            {shade === undefined ? null : <Swatch colour={shade} />}
                            {shade === undefined ? null : " "}
                            {padWidth(valueText(def, value), room)}
                            {mark}
                        </Text>
                        {note === undefined
                            ? null
                            : noteLines(note, widths.value - 2).map((line) => (
                                <Text key={line} color={theme.er}>{` ${line}`}</Text>
                            ))}
                    </>
                )}
            </Box>
            <BarColumn style="double" height={height} />
        </Box>
    )
}

/**
 * The names an editor picks from: all the colours, or the fonts of the machine (the
 * math fonts for a setting with `MATH` in its name).
 *
 * @param def - the setting.
 * @param fonts - the fonts of the machine, once they have been listed.
 * @returns the names, none for a setting that picks from no list.
 */
function editNames(
    def: SettingDef,
    fonts: ReturnType<typeof listFonts> | undefined,
): readonly string[] {
    if (!needsNames(def)) return []
    return settingNames(def.name, def.kind === "font" ? "font" : "colour", fonts)
}
