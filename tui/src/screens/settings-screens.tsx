// SPDX-License-Identifier: LGPL-3.0-or-later

// The settings screens: the sheet and its editors, the menu, and what the landings share.
//
// Contents:
//   1. The editors: a number inside its row, a tuple part by part, one text line, or a
//      colour or font picked from a list
//   2. `SettingsSheet`: one group of settings
//   3. `SettingsMenu`: the groups
//   4. Shared

import { basename } from "node:path"
import { Box, Text, usePaste } from "ink"
import {
    type ReactNode,
    useCallback,
    useEffect,
    useMemo,
    useReducer,
    useRef,
    useState,
} from "react"
import { appDir, cacheDir, readSystem } from "../core/environment.js"
import { quarantine } from "../core/file-system.js"
import { listFonts } from "../core/fonts.js"
import { truncate, truncateStart, wrapText } from "../core/terminal.js"
import { readRecipes, recipesFile } from "../store/buffer.js"
import {
    colourFamily,
    colourHex,
    colourInfo,
    type FamilyFilter,
    namesOfCode,
    narrowInFamily,
    nextFamily,
    parseColourCode,
} from "../store/colours.js"
import { customFile, readCustomSolutes } from "../store/custom.js"
import {
    type FontLists,
    modelSheets,
    type SettingDef,
    type SettingValue,
    settingNames,
} from "../store/settings.js"
import {
    loadScope,
    type Scope,
    sameValue,
    scopeTitle,
} from "../store/settings-store.js"
import { Frame, footerExtraLines } from "../ui/frame.js"
import {
    cursorMoves,
    GridMenu,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    MenuHeader,
    MenuSpec,
    moveLegend,
} from "../ui/grid.js"
import {
    type Confirm,
    Entry,
    Prompt,
    type Suggestion,
    useConfirm,
    useDiscardGuard,
} from "../ui/input.js"
import {
    ChoiceTabs,
    type KeyInput,
    keys,
    NarrowWidth,
    Swatch,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useListCursor,
    useNav,
    useScreenActive,
} from "../ui/interaction.js"
import { fieldCells, TextBuffer, TextField } from "../ui/text-input.js"
import {
    Bright,
    type Column,
    columnWidths,
    DataTable,
    Panel,
    useTheme,
} from "../ui/theme.js"
import { CustomSolutesTable, RecipesTable } from "./custom-solutes.js"
import {
    type EditEnd,
    hasColourPart,
    indexOfPick,
    type ListKind,
    maxNameText,
    maxSettingText,
    NUMBER_NOTE_ROWS,
    type NumberEdit,
    narrow,
    noteLines,
    openNumber,
    openTabs,
    openTuple,
    parseSetting,
    pasteNumber,
    pasteTuple,
    pickValue,
    plural,
    stepNumber,
    stepTabs,
    stepTuple,
    swatchColour,
    type TupleEdit,
    takeColour,
    valueText,
    withDraft,
    withModelDraft,
} from "./screen-rules.js"

// ========================================================================================
// 1. The editors
// ========================================================================================

/** The most colours or fonts the picker shows at once. */
const pickerLines = 5

/** Whether a setting is picked from a list (a colour or a font). */
const isPicked = (def: SettingDef): boolean => def.kind === "colour" || def.kind === "font"

/**
 * The rows an editor takes under the table: its label, an error, and the list. A number
 * has none (it is typed inside its row of the table); a tuple has a row for each part
 * and the error, and room for the picker of a colour part.
 */
const editorRows = (def: SettingDef): number => {
    if (def.kind === "tuple")
        return Math.max(def.partNames.length + 1, hasColourPart(def) ? pickerLines + 5 : 0)
    return def.kind === "colour"
        ? pickerLines + 5
        : isPicked(def)
            ? pickerLines + 3
            : def.kind === "int" || def.kind === "float"
                ? 0
                : 3
}

/** The kinds typed as a list, which need a longer line (the default colours are 70). */
const listKinds: ReadonlySet<string> = new Set(["colours", "markers", "sizes"])

/** The most characters a list line takes. */
const maxListText = 200

/** The most characters a path line takes. */
const maxPathText = 1000

/** What an editor is told: the setting, its value now and what to call when it is over. */
type EditorProps = {
    def: SettingDef
    current: SettingValue
    /** The installed fonts, for a font setting (listed when its editor is opened). */
    fonts?: FontLists
    onEnd: (end: EditEnd<SettingValue>) => void
    onLegend: (keys: LegendItem[]) => void
}

/** What a setting's text line asks for (a number or a tuple has an editor of its own). */
function textHint(def: SettingDef): { label: string; placeholder?: string } {
    switch (def.kind) {
        case "set":
            return { label: "some of:", placeholder: def.choices.join(" ") }
        case "ranges":
            return { label: "q ranges:", placeholder: "0.1-0.2, 0.5-0.6 (empty: none)" }
        case "strings":
            return { label: "chains:", placeholder: "A B (empty: all chains)" }
        case "colours":
            return { label: "colours:", placeholder: "#D55E00, #0072B2, red" }
        case "markers":
            return { label: "markers:", placeholder: "o, square, triangle" }
        case "sizes":
            return { label: "sizes:", placeholder: "76x5, 100x9 (growing)" }
        case "path":
            return { label: "path:", placeholder: "empty: the default" }
        case "optionalInt":
        case "optionalFloat":
            return { label: "number:", placeholder: `empty: ${valueText(def, null)}` }
        default:
            return { label: "number:" }
    }
}

/**
 * What a key does to an editor state: the next state, and how the edit ended if the key
 * ended it.
 */
type EditorStep<S, V> = { state: S; end?: EditEnd<V> }

/**
 * Holds the state of a pure editor (`stepNumber`, `stepTuple`) and feeds it the keys and
 * pastes of the screen. The state is also kept in a ref, so two keys that arrive before a
 * redraw (a fast typist, a held key) each see the result of the one before.
 *
 * @param step - the editor's step function.
 * @param onEnd - called once the edit is over, with how it ended and the last state.
 * @param paste - how pasted text changes the state; without it pastes are ignored.
 * @param active - whether the editor takes keys (false while a picker is open over it).
 * @param initial - the state to start from; `open` gives one later.
 * @returns the state (`undefined` while no edit is open), `open` and `apply`, which
 *     takes a step as if a key had made it.
 */
function useEditState<S, V>(
    step: (state: S, press: KeyInput) => EditorStep<S, V>,
    onEnd: (end: EditEnd<V>, state: S) => void,
    paste: ((state: S, text: string) => S) | undefined,
    active: boolean,
    initial?: S,
): {
    state: S | undefined
    open: (state: S) => void
    apply: (next: EditorStep<S, V>) => void
} {
    const [state, setState] = useState<S | undefined>(initial)
    const latest = useRef<S | undefined>(initial)
    const onTop = useScreenActive()
    const keep = (next: S | undefined): void => {
        latest.current = next
        setState(next)
    }
    const apply = (next: EditorStep<S, V>): void => {
        keep(next.end === undefined ? next.state : undefined)
        if (next.end !== undefined) onEnd(next.end, next.state)
    }
    const open = (opened: S): void => keep(opened)
    useKeys((press) => {
        if (latest.current !== undefined) apply(step(latest.current, press))
    }, state !== undefined && active)
    usePaste(
        (text) => {
            if (latest.current !== undefined && paste !== undefined)
                keep(paste(latest.current, text))
        },
        { isActive: onTop && state !== undefined && active && paste !== undefined },
    )
    return { state, open, apply }
}

/** The keys of a number typed into its row. */
const numberKeys: LegendItem[] = legendOf([
    legendFor("take", keys.enter),
    legendFor("cancel", keys.escape),
    legendBack,
])

/**
 * A list, a path or an optional number, typed as one line into the shared [[Prompt]]
 * and read by `parseSetting`. A wrong text stays as an error under the line until the
 * next key.
 */
function TextEditor({ def, current, onEnd, onLegend }: EditorProps): ReactNode {
    const [error, setError] = useState<string>()
    const clearError = useCallback(() => setError(undefined), [])
    const { label, placeholder } = textHint(def)
    return (
        <Prompt
            label={label}
            initial={def.kind === "path" ? (current as string) : valueText(def, current)}
            maxLength={
                def.kind === "path"
                    ? maxPathText
                    : listKinds.has(def.kind)
                        ? maxListText
                        : maxSettingText
            }
            placeholder={placeholder}
            error={error}
            onChange={clearError}
            onSubmit={(text) => {
                const parsed = parseSetting(def, text)
                if ("error" in parsed) setError(parsed.error)
                else onEnd({ kind: "done", value: parsed.value })
            }}
            onCancel={() => onEnd({ kind: "cancel" })}
            onBack={() => onEnd({ kind: "back" })}
            onLegend={onLegend}
        />
    )
}

/** Some of a few choices as tabs (a `set` setting, the figure formats). */
function TabsEditor({ def, current, onEnd, onLegend }: EditorProps): ReactNode {
    const theme = useTheme()
    const [edit, setEdit] = useState(() => openTabs(def.choices, current as string[]))
    useEffect(() => {
        onLegend([
            legendFor("move", [keys.left, keys.right], keys.tab),
            legendFor("toggle", keys.enter, keys.space),
            legendFor("done", keys.escape),
        ])
    }, [onLegend])
    useKeys((press) => {
        const step = stepTabs(edit, press)
        setEdit(step.state)
        if (step.end) onEnd(step.end)
    })
    return (
        <Box flexDirection="column">
            <Text bold color={theme.fg}>
                {def.name}
            </Text>
            <ChoiceTabs
                options={edit.options}
                selected={edit.selected}
                focus={edit.focus}
            />
            <Text color={theme.er}>{edit.error ?? " "}</Text>
        </Box>
    )
}

/** The width of the panel that shows a colour in each notation (the longest line is 33). */
const notationWidth = 33

/** The cells between the widest name shown and the notations. */
const notationGap = 3

/** The narrowest the list may be, for a code being typed. */
const listMinWidth = 24

/** A colour in each notation, one per line, with its swatch on the first. */
function NotationPanel({ colour }: { colour: string | undefined }): ReactNode {
    const theme = useTheme()
    const info = colour === undefined ? undefined : colourInfo(colour)
    const family = colour === undefined ? undefined : colourFamily(colour)
    const rows =
        info === undefined
            ? []
            : [
                info.hex,
                info.rgb,
                info.hsl,
                info.cmyk,
                ...(family === undefined ? [] : [`family: ${family}`]),
            ]
    return (
        <Box flexDirection="column" width={notationWidth} flexShrink={0}>
            {rows.map((row) => (
                <Text key={row} color={theme.fg}>
                    {row}
                </Text>
            ))}
        </Box>
    )
}

/** What a picker is told: what it picks, for which setting, and what ends it. */
type PickerProps = {
    /** The setting the list belongs to (a font setting lists its own kind of fonts). */
    settingName: string
    kind: ListKind
    /** The name highlighted first. */
    current: string
    /** What the field is called (`colour:` if not given). */
    label?: string
    fonts?: FontLists
    onEnd: (end: EditEnd<string>) => void
    onLegend: (keys: LegendItem[]) => void
}

/**
 * A colour or a font picked from the list of names, narrowing as one types. A colour may
 * also be typed as a code (`#rgb`, `#rrggbb`, `rgb(r, g, b)`, `hsl(h, s%, l%)`,
 * `cmyk(c%, m%, y%, k%)`): the list then shows every named colour with exactly that
 * 8-bit colour, and a panel beside it writes the highlighted colour in each notation.
 * The math font setting lists the fonts with a MATH table, the text font setting the
 * other fonts; a name not in the list is refused (on a machine with no fonts found the
 * text is taken as typed).
 */
function Picker({
    settingName,
    kind,
    current,
    label,
    fonts,
    onEnd,
    onLegend,
}: PickerProps): ReactNode {
    const columns = useBodyColumns()
    const theme = useTheme()
    const names = useMemo(
        () => settingNames(settingName, kind, fonts),
        [settingName, kind, fonts],
    )
    const [error, setError] = useState<string>()
    // the family the colour list is narrowed to (a font list has none)
    const [family, setFamily] = useState<FamilyFilter>("all")
    useKeys((press) => {
        if (press.is(keys.family)) setFamily(nextFamily)
    }, kind === "colour")
    const suggest = useCallback(
        (text: string): Suggestion[] => {
            if (kind === "font") return narrow(names, text).map((label) => ({ label }))
            // a colour code typed out comes first, then every name with that colour
            const code = parseColourCode(text)
            if (code !== undefined)
                return [
                    { label: text.trim(), swatch: code },
                    ...(namesOfCode(text) ?? []).map((label) => ({ label, swatch: code })),
                ]
            return narrowInFamily(names, text, family).map((label) => ({
                label,
                swatch: colourHex(label),
            }))
        },
        [names, kind, family],
    )
    const clearError = useCallback(() => setError(undefined), [])
    const side = useMemo(
        () => ({
            width: notationWidth,
            gap: notationGap,
            min: listMinWidth,
            render: (item: Suggestion | undefined) => (
                <NotationPanel colour={item?.label} />
            ),
        }),
        [],
    )
    const entry = (
        <Entry
            label={label ?? `${kind}:`}
            maxLength={maxNameText}
            placeholder={kind === "colour" ? "name or code" : "type to narrow"}
            suggest={suggest}
            initialIndex={indexOfPick(names, current)}
            wrap
            counter
            noMatch="no match"
            lines={pickerLines}
            error={error}
            onChange={clearError}
            side={kind === "colour" ? side : undefined}
            extras={kind === "colour" ? [legendFor("family", keys.family)] : undefined}
            onSubmit={(text, chosen) => {
                const picked = pickValue(kind, names, text, chosen?.label)
                if ("error" in picked) setError(picked.error)
                else onEnd({ kind: "done", value: picked.value })
            }}
            onCancel={() => onEnd({ kind: "cancel" })}
            onBack={() => onEnd({ kind: "back" })}
            onLegend={onLegend}
        />
    )
    if (kind === "font") return entry
    // the box takes four cells (border and padding); the notations follow the widest name
    return (
        <Bright>
            <Panel paddingX={1} width={columns}>
                <NarrowWidth.Provider value={columns - 4}>
                    <Box flexDirection="column">
                        <Text color={theme.fg}>{`family: ${family}`}</Text>
                        {entry}
                    </Box>
                </NarrowWidth.Provider>
            </Panel>
        </Bright>
    )
}

/** A colour or a font setting: the picker, for the setting's own list. */
function PickerEditor({ def, current, fonts, onEnd, onLegend }: EditorProps): ReactNode {
    return (
        <Picker
            settingName={def.name}
            kind={def.kind === "font" ? "font" : "colour"}
            current={current as string}
            fonts={fonts}
            onEnd={onEnd as (end: EditEnd<string>) => void}
            onLegend={onLegend}
        />
    )
}

/** What the field of one part of a tuple is called: the name of the part (`opacity:`). */
const partLabel = (def: SettingDef, index: number): string => `${def.partNames[index]}:`

/**
 * A tuple edited part by part, a field for each part: left, right and Tab move the focus
 * (the first key typed into a number part replaces it), Enter on a number part takes the
 * whole tuple (a wrong one stays as an error under the fields, the part at fault in
 * focus), Esc drops the edit. Enter on a colour part opens the same picker as a colour
 * setting for that part and goes on to the next one; Esc in the picker comes back to the
 * fields. A colour is kept as the picker gives it: a name Julia reads, or else `#rrggbb`
 * (see `colourOf`).
 */
function TupleEditor({ def, current, onEnd, onLegend }: EditorProps): ReactNode {
    const theme = useTheme()
    const columns = useBodyColumns()
    const [picking, setPicking] = useState(false)
    const editor = useEditState<TupleEdit, SettingValue>(
        (edit, press) => {
            const next = stepTuple(edit, press)
            if (next.pick) setPicking(true)
            return next
        },
        (end) => onEnd(end),
        pasteTuple,
        !picking,
        openTuple(def, current),
    )
    const edit = editor.state
    const onColour = edit !== undefined && def.partKinds[edit.focus] === "colour"
    useEffect(() => {
        if (picking) return
        onLegend([
            legendFor("part", [keys.left, keys.right], keys.tab),
            legendFor(onColour ? "pick colour" : "take", keys.enter),
            legendFor("cancel", keys.escape),
            legendBack,
        ])
    }, [picking, onColour, onLegend])
    if (edit === undefined) return null
    if (picking)
        return (
            <Picker
                key={edit.focus}
                settingName={def.name}
                kind="colour"
                current={edit.texts[edit.focus] as string}
                label={partLabel(def, edit.focus)}
                onEnd={(end) => {
                    if (end.kind === "done") {
                        setPicking(false)
                        editor.apply(takeColour(edit, end.value))
                    } else if (end.kind === "cancel") setPicking(false)
                    else onEnd(end)
                }}
                onLegend={onLegend}
            />
        )
    const label = Math.max(...def.partNames.map((n) => n.length))
    const room = Math.max(5, columns - label - 6)
    return (
        <Box flexDirection="column">
            {def.partNames.map((name, i) => {
                const focused = i === edit.focus
                const text = edit.texts[i] as string
                const ink = focused ? theme.fg : theme.mt
                return (
                    <Box key={name} columnGap={1}>
                        <Text color={ink} bold={focused}>
                            {focused ? ">" : " "} {name.padEnd(label)}:
                        </Text>
                        {def.partKinds[i] === "colour" ? (
                            <>
                                <Swatch colour={colourHex(text)} />
                                <Text color={ink} inverse={focused}>
                                    {truncate(text, room)}
                                </Text>
                            </>
                        ) : focused && !edit.fresh.has(i) ? (
                            <TextField buffer={new TextBuffer(text)} width={room} />
                        ) : (
                            <Text color={ink} inverse={focused}>
                                {truncate(text, room)}
                            </Text>
                        )}
                    </Box>
                )
            })}
            <Text color={theme.er}>{truncate(edit.error ?? " ", columns)}</Text>
        </Box>
    )
}

// ========================================================================================
// 2. The settings sheet
// ========================================================================================

/** What the sheet is told: whose settings, and which sheet (`output`, `model`, ...). */
type SettingsSheetProps = { scope: Scope; sheetId: string }

/** The lines the description of the highlighted setting may take (always reserved). */
const descriptionLines = 3

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
 * A settings sheet: one group of settings at a time as a list of names and values, the
 * description of the highlighted one under it. Up and down move, left and right switch
 * group, Enter edits. An edit becomes a draft, marked `*`, kept until saved (^w) or
 * undone (^u one setting, ^r the group). Saving checks all the drafts together; if
 * anything is wrong nothing is saved and each setting at fault is marked `!`. Leaving
 * with drafts asks first.
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
    const sheet = (model ? modelSheets(settings.catalog) : settings.catalog.sheets).find(
        (s) => s.id === sheetId,
    )
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
    const tableColumns: Column<SettingDef>[] = [
        { title: "name", width: longest, text: (d: SettingDef) => d.name },
        { title: "value", text: (d: SettingDef) => valueText(d, valueFor(d)) },
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
                            color: theme.er,
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
        </Frame>
    )
}

// ========================================================================================
// 3. The settings menu
// ========================================================================================

/**
 * The four groups of settings, as a grid: output, model / sampler, plots. Exported so a
 * test can check the hotkeys.
 */
export const settingsMenuSpec = new MenuSpec(["output", "models", "sampler", "plots"], 2)

/**
 * The global settings menu: the four groups and, below them, the user's library, the
 * `recipes` (hotkey `y`) and the custom `solutes` (hotkey `t`). Exported so a test can
 * check the hotkeys.
 */
export const globalMenuSpec = new MenuSpec(
    ["output", "models", "sampler", "plots", "recipes", "solutes"],
    2,
)

/**
 * The groups of settings of ONE model, as a grid: the sheets of [[modelSheets]] (the
 * `plots` sheet and the run-level groups of `output` have nothing a model can change).
 * Exported so a test can check it against the catalog.
 */
export const modelMenuSpec = new MenuSpec(["output", "models", "sampler"], 2)

/**
 * The id of the sheet each option opens. Every option is the id of its sheet except
 * the model settings, which share the art (and the `m` hotkey) of `models`.
 */
const sheetOf = {
    output:  "output",
    models:  "model",
    sampler: "sampler",
    plots:   "plots",
} as const

/** The options of the global menu that open a file of the library, and its file. */
const libraryFiles = {
    recipes: (root: string) => recipesFile(root),
    solutes: (root: string) => customFile(root),
} as const

/**
 * The settings menu, for the global settings, those of one project or those of one model.
 * The global one also has the `recipes` and `solutes` options, which open the recipes
 * table and the custom solutes table; on one of them whose file cannot be used `x` offers
 * to reset it to empty (the old file is kept beside it as `<name>.corrupt`).
 *
 * @param scope - whose settings.
 * @returns the screen.
 */
export function SettingsMenu({ scope }: { scope: Scope }): ReactNode {
    const nav = useNav()
    const confirm = useConfirm()
    const [message, setMessage] = useState<string>()
    // the files are read again whenever a table closes or a file is reset
    const [resets, setResets] = useState(0)
    const reset = useResetFile(confirm, setMessage, () => setResets((n) => n + 1))
    const root = appDir()
    const global = scope.kind === "global"
    // biome-ignore lint/correctness/useExhaustiveDependencies: these only re-read
    const usable = useMemo(
        () => {
            if (!global) return { recipes: true, solutes: true }
            return {
                recipes: count(() => readRecipes(root)) !== "unusable",
                solutes: count(() => readCustomSolutes(root)) !== "unusable",
            }
        },
        [global, root, nav.depth, resets],
    )

    // the names of the options are the ids of the sheets of the settings catalog
    const choose = useCallback(
        (name: (typeof globalMenuSpec.names)[number]) => {
            if (name === "recipes") nav.push(<RecipesTable />)
            else if (name === "solutes") nav.push(<CustomSolutesTable />)
            else nav.push(<SettingsSheet scope={scope} sheetId={sheetOf[name]} />)
        },
        [nav, scope],
    )
    const onKey = useCallback(
        (press: KeyInput, selected: (typeof globalMenuSpec.names)[number]) => {
            if (selected !== "recipes" && selected !== "solutes") return
            setMessage(undefined)
            if (press.is(keys.reset) && !usable[selected]) {
                const file = libraryFiles[selected](root)
                reset(basename(file), () => quarantine(file))
            }
        },
        [usable, root, reset],
    )

    if (scope.kind === "model")
        return (
            <GridMenu
                spec={modelMenuSpec}
                header={<MenuHeader caption={`model: ${scope.model}`} />}
                onChoose={choose}
            />
        )
    if (!global)
        return (
            <GridMenu
                spec={settingsMenuSpec}
                header={<MenuHeader caption={scopeTitle(scope)} />}
                onChoose={choose}
            />
        )
    const question = confirm.question
    const legend = (selected: (typeof globalMenuSpec.names)[number]) => {
        if (question) {
            const { yes, no } = question
            return `${yes}: ${keys.enter.label}  ${no}: ${keys.escape.label}`
        }
        const onLibrary = selected === "recipes" || selected === "solutes"
        if (!onLibrary || usable[selected]) return undefined
        return `reset file: ${keys.reset.label}`
    }
    return (
        <GridMenu
            spec={globalMenuSpec}
            header={<MenuHeader caption={scopeTitle(scope)} />}
            onChoose={choose}
            onKey={onKey}
            intercept={confirm.handleKey}
            notice={confirm.note ?? message}
            legend={legend}
        />
    )
}

// ========================================================================================
// 4. Shared
// ========================================================================================

/** How many rows a file holds, or that it cannot be used. */
export type FileCount = number | "unusable"

/** The rows a file holds: their number, `"unusable"` if reading throws. */
export function count(read: () => readonly unknown[]): FileCount {
    try {
        return read().length
    } catch {
        return "unusable"
    }
}

/** What a landing says of a file under a plain label: `buffer: 3 solutes`, `none yet`. */
export function fileStatus(label: string, n: FileCount, word: string): string {
    if (n === "unusable") return `${label}: unusable!`
    return n === 0 ? `${label}: none yet` : `${label}: ${n} ${word}${n === 1 ? "" : "s"}`
}

/**
 * The reset of a file that cannot be used: `ask(file, reset)` asks, and on Enter runs
 * `reset` (the old file is kept as `<name>.corrupt`), then re-reads the counts.
 */
export function useResetFile(
    confirm: Confirm,
    setMessage: (text: string) => void,
    reread: () => void,
): (name: string, reset: () => void) => void {
    return (name, reset) =>
        confirm.ask(
            {
                text: `reset ${name}? the old one is kept as .corrupt`,
                yes: "reset",
                no: "keep",
            },
            () => {
                try {
                    reset()
                    reread()
                    setMessage(`${name} reset; old one kept as .corrupt`)
                } catch {
                    setMessage("could not reset!")
                }
            },
        )
}

/** For a file that cannot be used: where it is and what can be done. */
export const unusableHint = (file: string, columns: number): string =>
    `${truncateStart(file, Math.max(10, columns - 24))}  ${keys.reset.label}: reset`
