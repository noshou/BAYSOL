// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useMemo, useReducer, useRef, useState } from "react"
import { cacheDir } from "../core/paths.js"
import { readSystem } from "../core/system.js"
import { padWidth, truncate } from "../core/text.js"
import { loadScope, type Scope, scopeTitle } from "../store/scope.js"
import type { SettingDef, SettingValue } from "../store/settings-defs.js"
import type { Settings } from "../store/settings-store.js"
import { names as namesOf, swatch } from "../store/solutes.js"
import { listFonts } from "../system/fonts.js"
import { Frame } from "../ui/frame.js"
import { keys } from "../ui/keys.js"
import { useBodyColumns, useBodyRows } from "../ui/layout.js"
import { type LegendItem, legendBack, legendQuit } from "../ui/legend.js"
import { useNav } from "../ui/nav.js"
import { useTheme } from "../ui/theme.js"
import { useDiscardGuard } from "../ui/use-confirm.js"
import { useKeys } from "../ui/use-keys.js"
import { type ListCursor, useListCursor } from "../ui/use-list-cursor.js"
import {
    descriptionLines,
    type EditEnd,
    groupJump,
    groupSettings,
    hexOf,
    nextSetting,
    settingFacts,
    sheetRows,
    swatchColour,
    valueText,
    windowStart,
    withDraft,
} from "./setting-edit.js"
import { editorLegend, editorRows, needsNames, SettingEditor } from "./setting-editors.js"

/**
 * What the sheet is told.
 *
 * @property scope - whose settings: the global ones or a project's.
 * @property sheetId - which sheet: `output`, `model`, `sampler` or `plots`.
 */
export type SettingsSheetProps = { scope: Scope; sheetId: string }

/** The cells of the cursor mark at the start of a row (`> `). */
const markCells = 2

/** The cells the value of a setting may take in its column. */
const valueCells = 21

/** The cells of the `*` that marks a draft, and the gap after it. */
const draftCells = 2

/** The keys of the sheet when nothing is being edited. */
const sheetLegend: LegendItem[] = [
    { label: "move", keys: "↑↓" },
    { label: "group", keys: "←→" },
    { label: "edit", keys: "⏎" },
    { label: "save", keys: "^w" },
    { label: "undo", keys: "^u" },
    { label: "reset group", keys: "^r" },
    legendBack,
    legendQuit,
]

/**
 * A settings sheet: the settings of one sheet of the catalog, grouped as the catalog
 * groups them, in a list that scrolls, with the description of the setting under the
 * cursor below it. Enter edits the setting (an editor opens under the list); an edit
 * becomes a draft, marked `*`, which stays until it is saved with Ctrl-W or undone
 * (Ctrl-U for one setting, Ctrl-R for a group). Saving checks all the drafts together,
 * so a rule that ties two settings is judged on the values they would have; if
 * anything is wrong nothing is saved and each setting at fault says why. Leaving with
 * drafts asks first.
 *
 * @param props - see [[SettingsSheetProps]].
 * @returns the screen.
 */
export function SettingsSheet({ scope, sheetId }: SettingsSheetProps): ReactNode {
    const nav = useNav()
    // the settings are read once per opening of the sheet, wiped values noticed
    const [settings] = useState(() => loadScope(scope).settings)
    const sheet = settings.catalog.sheet(sheetId)
    if (sheet === undefined) throw new Error(`there is no settings sheet ${sheetId}`)
    return <Sheet scope={scope} settings={settings} sheetId={sheetId} nav={nav} />
}

/** What the inner sheet gets: the same, with the settings loaded and the nav. */
type SheetProps = SettingsSheetProps & {
    settings: Settings
    nav: ReturnType<typeof useNav>
}

/** The sheet proper, once its settings are loaded and its id is known to be good. */
function Sheet({ scope, settings, sheetId, nav }: SheetProps): ReactNode {
    const theme = useTheme()
    const columns = useBodyColumns()
    const sheet = settings.catalog.sheet(sheetId)
    const rows = useMemo(() => (sheet === undefined ? [] : sheetRows(sheet)), [sheet])

    const [drafts, setDrafts] = useState<ReadonlyMap<string, SettingValue>>(new Map())
    const [errors, setErrors] = useState<ReadonlyMap<string, Fault>>(new Map())
    // notices of wiped settings that an edit has dealt with
    const [dismissed, setDismissed] = useState<ReadonlySet<string>>(new Set())
    const [editing, setEditing] = useState<string>()
    const [status, setStatus] = useState<{ text: string; error: boolean }>()
    const [, redraw] = useReducer((n: number) => n + 1, 0)
    const fonts = useRef<ReturnType<typeof listFonts>>(undefined)

    const guard = useDiscardGuard(drafts.size)

    // why a setting was wiped when the file was read, until an edit has dealt with it
    const noticeOf = (name: string): string | undefined =>
        dismissed.has(name) ? undefined : settings.notices.get(name)

    // --- the layout: the list takes what the detail area leaves
    const def = firstDefOf(rows)
    const editedDef = editing === undefined ? undefined : settings.catalog.get(editing)
    const detailWidth = columns
    const idleRows = useMemo(
        () =>
            2 +
            Math.max(
                1,
                ...rows.flatMap((r) =>
                    r.kind === "setting"
                        ? [descriptionLines(r.def, detailWidth).length]
                        : [],
                ),
            ),
        [rows, detailWidth],
    )
    const detailRows = editedDef === undefined ? idleRows : editorRows(editedDef)
    const pageSize = useBodyRows(detailRows + 1)
    const cursor = useListCursor(rows.length, pageSize)
    const cursorRow = cursorRowOf(rows, cursor)
    const current = rows[cursorRow]
    const here = current?.kind === "setting" ? current.def : def

    const valueFor = (d: SettingDef): SettingValue =>
        drafts.get(d.name) ?? settings.get(d.name)

    const draft = (d: SettingDef, value: SettingValue): void => {
        setDrafts((was) => withDraft(was, d.name, settings.get(d.name), value))
        setErrors((was) => without(was, d.name))
    }

    const undo = (d: SettingDef): void => {
        setDrafts((was) => without(was, d.name))
        setErrors((was) => without(was, d.name))
    }

    const resetGroup = (group: number): void => {
        const defs = groupSettings(rows, group)
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
        if (drafts.size === 0) {
            setStatus({ text: "nothing to save", error: false })
            return
        }
        const changes = Object.fromEntries(drafts)
        const ev = settings.evaluate(changes)
        if (!ev.ok) {
            setErrors(ev.errors)
            const n = ev.errors.size
            setStatus({
                text: `${plural(n)} cannot be saved: see the marked rows`,
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

    useKeys((press) => {
        if (guard.handleKey(press)) return
        setStatus(undefined)
        if (press.is(keys.back)) return guard.leave(nav.pop)
        if (press.is(keys.escape)) return guard.leave(nav.quit)
        if (press.is(keys.save)) return save()
        if (press.is(keys.up)) return cursor.set(nextSetting(rows, cursorRow, -1))
        if (press.is(keys.down)) return cursor.set(nextSetting(rows, cursorRow, 1))
        if (press.is(keys.left)) return cursor.set(groupJump(rows, cursorRow, -1))
        if (press.is(keys.right)) return cursor.set(groupJump(rows, cursorRow, 1))
        if (here === undefined) return
        if (press.is(keys.enter)) return edit(here)
        if (press.is(keys.undo)) return undo(here)
        if (press.is(keys.remove)) return resetGroup(current?.group ?? 0)
    }, editing === undefined)

    // --- drawing
    const start = windowStart(rows, cursorRow, cursor.offset)
    const shown = rows.slice(start, start + pageSize)
    const nameCells = Math.max(
        ...rows.map((r) => (r.kind === "setting" ? r.def.name.length : 0)),
    )
    const notes = Math.max(
        0,
        columns - markCells - nameCells - 1 - valueCells - draftCells,
    )
    const total = rows.filter((r) => r.kind === "setting").length
    const position = rows.slice(0, cursorRow + 1).filter((r) => r.kind === "setting").length

    const note = guard.question ?? status?.text
    const noteIsError = guard.question === undefined && status?.error === true
    const subtitle =
        scope.kind === "project"
            ? `${scopeTitle(scope)} · ${scope.project.id} · ${position} / ${total}`
            : `${scopeTitle(scope)} · ${position} / ${total}`

    return (
        <Frame logo="blocky"
            title={sheet?.title ?? sheetId}
            subtitle={subtitle}
            legend={editedDef === undefined ? sheetLegend : editorLegend(editedDef)}
            note={note}
            noteIsError={noteIsError}
        >
            <Box flexDirection="column" flexGrow={1}>
                {shown.map((row, i) => {
                    if (row.kind === "group")
                        return (
                            <Text key={`g${row.group}`} bold color={theme.fg}>
                                {heading(row.title, columns - 1)}
                            </Text>
                        )
                    const d = row.def
                    const on = start + i === cursorRow
                    const value = valueFor(d)
                    const colour = swatchColour(d, value)
                    const rgb = colour === undefined ? undefined : swatch(colour)
                    const error = errors.get(d.name)?.short
                    const notice = noticeOf(d.name)
                    const swatchWidth = rgb === undefined ? 0 : 3
                    return (
                        <Text
                            key={d.name}
                            wrap="truncate-end"
                            color={on ? theme.fg : theme.mt}
                        >
                            <Text bold={on}>{on ? "> " : "  "}</Text>
                            <Text bold={on}>{padWidth(d.name, nameCells + 1)}</Text>
                            {rgb === undefined ? null : (
                                <Text color={hexOf(rgb)}>{"██ "}</Text>
                            )}
                            <Text color={theme.fg} bold={on}>
                                {padWidth(valueText(d, value), valueCells - swatchWidth)}
                            </Text>
                            <Text color={theme.fg}>{drafts.has(d.name) ? "* " : "  "}</Text>
                            {error !== undefined ? (
                                <Text color={theme.er}>{truncate(error, notes)}</Text>
                            ) : notice !== undefined ? (
                                <Text color={theme.er}>{truncate(notice, notes)}</Text>
                            ) : null}
                        </Text>
                    )
                })}
            </Box>
            <Box flexDirection="column" height={detailRows} marginTop={1}>
                {editedDef !== undefined ? (
                    <SettingEditor
                        key={editedDef.name}
                        def={editedDef}
                        current={valueFor(editedDef)}
                        names={editNames(editedDef, fonts.current)}
                        onEnd={endEdit}
                    />
                ) : here !== undefined ? (
                    <Detail
                        def={here}
                        width={detailWidth}
                        error={errors.get(here.name)?.message}
                        notice={noticeOf(here.name)}
                    />
                ) : null}
            </Box>
        </Frame>
    )
}

/**
 * What is under the cursor, described: the setting's name and what it accepts, its
 * description wrapped to the width, and what is wrong with it, if anything.
 *
 * @param props.def - the setting.
 * @param props.width - the cells a line may use.
 * @param props.error - why the last save refused its value.
 * @param props.notice - why the setting was wiped when the file was read.
 * @returns the detail area.
 */
function Detail(props: {
    def: SettingDef
    width: number
    error?: string
    notice?: string
}): ReactNode {
    const { def, width, error, notice } = props
    const theme = useTheme()
    return (
        <Box flexDirection="column">
            <Text wrap="truncate-end">
                <Text bold color={theme.fg}>
                    {def.name}
                </Text>
                <Text color={theme.mt}>{`  ${settingFacts(def)}`}</Text>
            </Text>
            <Text color={theme.fg}>{descriptionLines(def, width).join("\n")}</Text>
            {error !== undefined ? (
                <Text color={theme.er}>{`${def.name} ${error}`}</Text>
            ) : notice !== undefined ? (
                <Text color={theme.er}>{notice}</Text>
            ) : null}
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
    return namesOf(def.name, def.kind === "font" ? "font" : "colour", fonts)
}

/** What is wrong with a value at a save: a sentence, and a short one for a row. */
type Fault = { message: string; short: string }

/** `1 setting`, `3 settings`. */
function plural(n: number): string {
    return `${n} setting${n === 1 ? "" : "s"}`
}

/**
 * The line that heads a group: its title between rules, as wide as given.
 *
 * @param title - the group's title.
 * @param cells - the width.
 * @returns the line.
 */
function heading(title: string, cells: number): string {
    return truncate(`── ${title} `, cells).padEnd(cells, "─")
}

/** Copy of a map without some keys. */
function without<V>(map: ReadonlyMap<string, V>, ...gone: string[]): Map<string, V> {
    const next = new Map(map)
    for (const name of gone) next.delete(name)
    return next
}

/** The cursor, kept on a setting row: a heading under it (before the first move) counts
 * as the setting below. */
function cursorRowOf(
    rows: ReturnType<typeof sheetRows>,
    cursor: ListCursor,
): number {
    const at = rows[cursor.index]
    return at === undefined || at.kind === "setting"
        ? cursor.index
        : nextSetting(rows, cursor.index, 1)
}

/** The first setting of a sheet: what the detail area describes before the cursor moves. */
function firstDefOf(rows: ReturnType<typeof sheetRows>): SettingDef | undefined {
    const first = rows.find((r) => r.kind === "setting")
    return first?.kind === "setting" ? first.def : undefined
}
