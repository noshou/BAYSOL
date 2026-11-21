// SPDX-License-Identifier: LGPL-3.0-or-later

// The settings sheet: one group of settings, edited in place.

import { Box, Text } from "ink"
import { type ReactNode, useReducer, useState } from "react"
import { cacheDir, readSystem } from "../core/environment.js"
import { listFonts } from "../core/fonts.js"
import { wrapText } from "../core/terminal.js"
import { colourHex } from "../store/colours.js"
import { listModels } from "../store/projects.js"
import {
    type FontLists,
    modelSheets,
    type SettingDef,
    type SettingValue,
    visibleSheets,
} from "../store/settings.js"
import { loadScope, type Scope, sameValue, scopeTitle } from "../store/settings-store.js"
import { Frame, footerExtraLines } from "../ui/frame.js"
import {
    cursorMoves,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    moveLegend,
} from "../ui/grid.js"
import { useDiscardGuard } from "../ui/input.js"
import {
    keys,
    Swatch,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useListCursor,
    useNav,
} from "../ui/interaction.js"
import { fieldCells, TextField } from "../ui/text-input.js"
import { type Column, columnWidths, DataTable, useTheme } from "../ui/theme.js"
import {
    type EditEnd,
    MEMORY_SETTING,
    memoryHint,
    NUMBER_NOTE_ROWS,
    type NumberEdit,
    noteLines,
    openNumber,
    pasteNumber,
    plural,
    stepNumber,
    swatchColour,
    valueText,
    withDraft,
    withModelDraft,
} from "./screen-rules.js"
import {
    editorRows,
    isPicked,
    LadderEditor,
    numberKeys,
    PickerEditor,
    TabsEditor,
    TextEditor,
    TupleEditor,
    useEditState,
} from "./settings-editors.js"

/** What the sheet is told: whose settings, and which sheet (`output`, `model`, ...). */
type SettingsSheetProps = { scope: Scope; sheetId: string }

/** The lines the description of the highlighted setting may take (always reserved). */
const descriptionLines = 3

/** The cells of the memory column: `50 % = 15.3 GiB of 15.3 GiB` and a little more. */
const MEMORY_HINT_WIDTH = 28

/** The rows the table spends besides its settings: header, rule and the position line. */
const tableRows = 3

/** The lines of keys the frame's row count holds without growing. */
const SHEET_LEGEND_LINES = 3

/** What `^r` is called: a model's settings go back to the project's. */
const resetLabel = (scope: Scope): string =>
    scope.kind === "model" ? "inherit group" : "reset group"

/** The keys the sheet can show at most, for the footer to reserve their height. */
const sheetFullFor = (scope: Scope): LegendItem[] => [
    legendBack,
    legendFor("save", keys.save),
    legendFor("edit", keys.enter),
    legendFor("next group", keys.right),
    legendFor("prev group", keys.left),
    moveLegend({ up: true, down: true }) as LegendItem,
    legendFor("undo", keys.undo),
    legendFor(resetLabel(scope), keys.remove),
]

/** The index of the value column of the table. */
const VALUE_COLUMN = 1

/** What the source column of a model's sheet says of a setting. */
const OVERRIDDEN = "overridden"
const INHERITED = "inherited"

/** Copy of a map without some keys. */
function without<V>(map: ReadonlyMap<string, V>, ...gone: string[]): Map<string, V> {
    const next = new Map(map)
    for (const name of gone) next.delete(name)
    return next
}

/**
 * A settings sheet: one group of settings at a time as names and values, the description
 * of the highlighted one under it. Up and down move, left and right switch group, Enter
 * edits. An edit becomes a draft, marked `*`, kept until saved (^w) or undone (^u one
 * setting, ^r the group). Saving checks all drafts together; on any error nothing is
 * saved and each setting at fault is marked `!`. Leaving with drafts asks first.
 */
export function SettingsSheet({ scope, sheetId }: SettingsSheetProps): ReactNode {
    // the settings are read once per opening of the sheet, wiped values noticed
    const [loaded] = useState(() => loadScope(scope))
    const { settings } = loaded
    const model = scope.kind === "model"
    const nav = useNav()
    const theme = useTheme()
    const columns = useBodyColumns()
    // a model's sheets leave out the settings of the whole run (see `modelSheets`)
    // and the colours of the models of the comparison appear only for a project with
    // more than one model (the global settings have no project: they are left out)
    const [several] = useState(
        () => scope.kind === "project" && listModels(scope.project.dir).length > 1,
    )
    const sheet = (
        model
            ? modelSheets(settings.catalog)
            : visibleSheets(settings.catalog.sheets, several)
    ).find((s) => s.id === sheetId)
    if (sheet === undefined) throw new Error(`there is no settings sheet ${sheetId}`)
    const groups = sheet.groups

    const [group, setGroup] = useState(0)
    const [drafts, setDrafts] = useState<ReadonlyMap<string, SettingValue>>(new Map())
    const [errors, setErrors] = useState<ReadonlyMap<string, string>>(new Map())
    // notices of wiped settings that an edit has dealt with
    const [dismissed, setDismissed] = useState<ReadonlySet<string>>(new Set())
    const [editing, setEditing] = useState<string>()
    // the installed fonts, listed (and cached on disk) the first time a font is edited
    const [fonts, setFonts] = useState<FontLists>()
    const [promptKeys, setPromptKeys] = useState<LegendItem[]>([])
    const [status, setStatus] = useState<{ text: string; error: boolean } | undefined>(
        () =>
            model && loaded.reset
                ? { text: "unusable file: kept .corrupt", error: true }
                : undefined,
    )
    const [, redraw] = useReducer((n: number) => n + 1, 0)
    const guard = useDiscardGuard(drafts.size)
    // an int or a float is typed into the value cell of its row, not under the table
    const numberEdit = useEditState<NumberEdit, number>(
        stepNumber,
        (end, last) => endNumber(end, last.def),
        pasteNumber,
        true,
    )
    const inline = numberEdit.state

    const defs = groups[group]?.settings ?? []
    const editedDef = editing === undefined ? undefined : settings.catalog.get(editing)
    // the footer's box (blocky) and any key lines beyond the three the frame holds
    const sheetFull = sheetFullFor(scope)
    const footerExtra = footerExtraLines(sheetFull, columns, SHEET_LEGEND_LINES, "blocky")
    const pageSize = useBodyRows(
        tableRows +
            footerExtra +
            (inline
                ? descriptionLines + NUMBER_NOTE_ROWS
                : editedDef
                    ? editorRows(editedDef)
                    : descriptionLines),
    )
    // the ladder editor takes the whole body: its rungs and overrides scroll there
    const ladderRows = useBodyRows(footerExtra)
    const cursor = useListCursor(defs.length, pageSize)
    const here = defs[cursor.index] as SettingDef

    const noticeOf = (name: string): string | undefined =>
        dismissed.has(name) ? undefined : settings.notices.get(name)
    const valueFor = (d: SettingDef): SettingValue =>
        drafts.has(d.name) ? (drafts.get(d.name) as SettingValue) : settings.get(d.name)
    // a model's value is its own (overridden) when it differs from the project's: a draft
    // is judged by its value, a saved one by its being saved
    const overridden = (d: SettingDef): boolean =>
        drafts.has(d.name)
            ? !sameValue(valueFor(d), settings.resetValue(d.name))
            : settings.isSaved(d.name)
    const resettable = defs.some((d) =>
        model ? overridden(d) : !sameValue(valueFor(d), settings.resetValue(d.name)),
    )
    const hasPrev = group > 0
    const hasNext = group < groups.length - 1

    // --- what the keys do
    const draft = (d: SettingDef, value: SettingValue): void => {
        setDrafts((was) =>
            model
                ? withModelDraft(was, d.name, settings, value)
                : withDraft(was, d.name, settings.get(d.name), value),
        )
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
                if (model && !overridden(d)) continue
                const reset = settings.resetValue(d.name)
                next = model
                    ? withModelDraft(next, d.name, settings, reset)
                    : withDraft(next, d.name, settings.get(d.name), reset)
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
            const count = plural(ev.errors.size, "setting")
            setStatus({
                text: `${count} cannot be saved: see the rows marked !`,
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
        setStatus({ text: `saved ${plural(drafts.size, "setting")}`, error: false })
        setDrafts(new Map())
        setErrors(new Map())
        redraw()
    }
    const edit = (d: SettingDef): void => {
        if (d.kind === "bool") draft(d, !(valueFor(d) as boolean))
        else if (d.kind === "int" || d.kind === "float")
            numberEdit.open(openNumber(d, valueFor(d)))
        else {
            if (d.kind === "font")
                setFonts((was) => was ?? listFonts(readSystem(), cacheDir()))
            setEditing(d.name)
        }
    }
    const endEdit = (end: EditEnd<SettingValue>): void => {
        setEditing(undefined)
        if (end.kind === "back") guard.leave(nav.pop)
        else if (end.kind === "done" && editedDef !== undefined) {
            draft(editedDef, end.value)
            setDismissed((was) => new Set([...was, editedDef.name]))
        }
    }
    function endNumber(end: EditEnd<number>, def: SettingDef): void {
        if (end.kind === "back") guard.leave(nav.pop)
        else if (end.kind === "done") {
            draft(def, end.value)
            setDismissed((was) => new Set([...was, def.name]))
        }
    }
    const goto = (g: number): void => {
        setGroup(g)
        cursor.set(0)
    }

    useKeys((press) => {
        if (guard.handleKey(press)) return
        setStatus(undefined)
        if (press.is(keys.back)) guard.leave(nav.pop)
        else if (press.is(keys.save) && drafts.size > 0) save()
        else if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.left) && hasPrev) goto(group - 1)
        else if (press.is(keys.right) && hasNext) goto(group + 1)
        else if (press.is(keys.enter)) edit(here)
        else if (press.is(keys.undo)) undo(here)
        else if (press.is(keys.remove) && resettable) resetGroup()
    }, editing === undefined && inline === undefined)

    // --- drawing
    const fault = errors.get(here.name)
    const notice = noticeOf(here.name)
    const note =
        guard.note ??
        status?.text ??
        (fault && `${here.name} ${fault}`) ??
        (notice && `${here.name}: ${notice}`)
    const noteIsError = guard.question === undefined && (status?.error === true || !status)
    const legend = inline
        ? numberKeys
        : editedDef !== undefined
            ? promptKeys
            : legendOf([
                legendBack,
                drafts.size > 0 && legendFor("save", keys.save),
                legendFor("edit", keys.enter),
                hasNext && legendFor("next group", keys.right),
                hasPrev && legendFor("prev group", keys.left),
                moveLegend(cursorMoves(cursor.index, defs.length)),
                drafts.has(here.name) && legendFor("undo", keys.undo),
                resettable && legendFor(resetLabel(scope), keys.remove),
            ])
    const longest = Math.max(1, ...defs.map((d) => d.name.length))
    const shade = swatchColour(here, valueFor(here))
    const description = wrapText(here.description, columns).slice(0, descriptionLines)
    // the memory headroom says what its percent is on this machine, live while typed,
    // in a column of its own to the right of the value
    const memoryOf = (d: SettingDef): string =>
        d.name !== MEMORY_SETTING
            ? ""
            : (memoryHint(
                    inline && d === here ? inline.buffer.text : valueText(d, valueFor(d)),
                ) ?? "")
    const hasMemory = defs.some((d) => d.name === MEMORY_SETTING)
    const tableColumns: Column<SettingDef>[] = [
        { title: "name", width: longest, text: (d: SettingDef) => d.name },
        { title: "value", text: (d: SettingDef) => valueText(d, valueFor(d)) },
        ...(hasMemory
            ? [{ title: "on this machine", text: memoryOf, width: MEMORY_HINT_WIDTH }]
            : []),
        ...(model
            ? [
                {
                    title: "here",
                    width: OVERRIDDEN.length,
                    text: (d: SettingDef) => (overridden(d) ? OVERRIDDEN : INHERITED),
                },
            ]
            : []),
    ]
    // the number being typed sits in the value cell of its row, its error under it
    const valueWidth = columnWidths(tableColumns, columns)[VALUE_COLUMN] as number

    return (
        <Frame
            design="blocky"
            title={`${sheet.title} settings`}
            subtitle={
                scope.kind === "model"
                    ? `model: ${scope.model} · ${scope.project.id}`
                    : scope.kind === "project"
                        ? `${scopeTitle(scope)} · ${scope.project.id}`
                        : scopeTitle(scope)
            }
            counter={`${groups[group]?.title ?? ""} [${group + 1} / ${groups.length}]`}
            legend={legend}
            legendFull={sheetFull}
            note={note || undefined}
            noteIsError={noteIsError}
        >
            {editedDef?.kind === "ladder" ? (
                <LadderEditor
                    key={editedDef.name}
                    def={editedDef}
                    current={valueFor(editedDef)}
                    rows={ladderRows}
                    onEnd={endEdit}
                    onLegend={setPromptKeys}
                />
            ) : (
                <>
            <DataTable
                border="double"
                columns={tableColumns}
                inline={
                    inline && {
                        row: cursor.index,
                        column: VALUE_COLUMN,
                        node: <TextField buffer={inline.buffer} width={valueWidth} />,
                        cells: fieldCells(inline.buffer, valueWidth),
                    }
                }
                note={
                    inline?.error === undefined
                        ? undefined
                        : {
                            row: cursor.index,
                            column: VALUE_COLUMN,
                            lines: noteLines(inline.error, valueWidth),
                            error: true,
                        }
                }
                emphasis={model ? overridden : undefined}
                rows={defs}
                cursor={cursor.index}
                offset={cursor.offset}
                pageSize={pageSize}
                mark={(d) =>
                    errors.has(d.name) || noticeOf(d.name) !== undefined
                        ? "!"
                        : drafts.has(d.name)
                            ? "*"
                            : " "
                }
                width={columns}
            />
            <Box flexDirection="column" marginTop={1}>
                {editedDef ? (
                    <Box flexDirection="column" height={editorRows(editedDef)}>
                        {isPicked(editedDef) ? (
                            <PickerEditor
                                key={editedDef.name}
                                def={editedDef}
                                current={valueFor(editedDef)}
                                fonts={fonts}
                                onEnd={endEdit}
                                onLegend={setPromptKeys}
                            />
                        ) : editedDef.kind === "set" ? (
                            <TabsEditor
                                key={editedDef.name}
                                def={editedDef}
                                current={valueFor(editedDef)}
                                onEnd={endEdit}
                                onLegend={setPromptKeys}
                            />
                        ) : editedDef.kind === "tuple" ? (
                            <TupleEditor
                                key={editedDef.name}
                                def={editedDef}
                                current={valueFor(editedDef)}
                                onEnd={endEdit}
                                onLegend={setPromptKeys}
                            />
                        ) : (
                            <TextEditor
                                key={editedDef.name}
                                def={editedDef}
                                current={valueFor(editedDef)}
                                onEnd={endEdit}
                                onLegend={setPromptKeys}
                            />
                        )}
                    </Box>
                ) : (
                    <Box flexDirection="column" height={descriptionLines}>
                        {description.map((line, i) => (
                            <Text key={line} color={theme.mt}>
                                {i === 0 && shade !== undefined ? (
                                    <>
                                        <Swatch colour={colourHex(shade)} />{" "}
                                    </>
                                ) : null}
                                {line}
                            </Text>
                        ))}
                    </Box>
                )}
            </Box>
                </>
            )}
        </Frame>
    )
}
