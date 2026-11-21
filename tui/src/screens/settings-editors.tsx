// SPDX-License-Identifier: LGPL-3.0-or-later

// The editors of the settings sheet: a number inside its row, a tuple part by part, one
// text line, or a colour or font picked from a list.

import { Box, Text, usePaste } from "ink"
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react"
import { truncate, wrapText } from "../core/terminal.js"
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
import {
    type FontLists,
    type LadderMap,
    type LadderRung,
    MAX_LIST_TYPING,
    MAX_PATH_TYPING,
    type SettingDef,
    type SettingValue,
    settingNames,
    validateValue,
} from "../store/settings.js"
import { type LegendItem, legendBack, legendFor, legendOf } from "../ui/grid.js"
import {
    DROPDOWN_CHROME,
    Dropdown,
    Entry,
    filterChoices,
    Prompt,
    positionStatus,
    type Suggestion,
    suggestionLines,
} from "../ui/input.js"
import {
    ChoiceTabs,
    CursorList,
    type KeyInput,
    keys,
    ListText,
    NarrowWidth,
    Swatch,
    useBodyColumns,
    useKeys,
    useListCursor,
    useScreenActive,
} from "../ui/interaction.js"
import { TextBuffer, TextField } from "../ui/text-input.js"
import { Bright, ErrorText, Panel, useTheme } from "../ui/theme.js"
import {
    addableOverrides,
    conditionLabel,
    dropOverride,
    dropRung,
    type EditEnd,
    hasColourPart,
    indexOfPick,
    LADDER_RERUNS,
    type ListKind,
    ladderRungs,
    MAX_RUNG_NAME,
    maxNameText,
    maxSettingText,
    moveOverride,
    moveRung,
    narrow,
    openTabs,
    openTuple,
    overrideDef,
    overrideDescription,
    overrideValueText,
    parseSetting,
    pasteTuple,
    pickValue,
    putRung,
    type RungRef,
    recondition,
    renameRung,
    rungOf,
    rungPlace,
    rungRowText,
    setOverride,
    stepTabs,
    stepTuple,
    type TupleEdit,
    takeColour,
    valueText,
} from "./screen-rules.js"

/** The most colours or fonts the picker shows at once. */
const pickerLines = 5

/** Whether a setting is picked from a list (a colour or a font). */
export const isPicked = (def: SettingDef): boolean =>
    def.kind === "colour" || def.kind === "font"

/**
 * The rows an editor takes under the table: its label, an error, and the list. A number
 * has none (it is typed inside its row of the table); a tuple has a row for each part
 * and the error, and room for the picker of a colour part.
 */
export const editorRows = (def: SettingDef): number => {
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
        case "choice":
            return { label: "one of:", placeholder: `${def.choices.join(" | ")} (A or nm)` }
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
 * pastes of the screen. The state is also kept in a ref, so two keys arriving before a
 * redraw each see the result of the one before.
 *
 * @param step - the editor's step function.
 * @param onEnd - called once the edit is over, with how it ended and the last state.
 * @param paste - how pasted text changes the state; without it pastes are ignored.
 * @param active - whether the editor takes keys (false while a picker is open over it).
 * @param initial - the state to start from; `open` gives one later.
 * @returns the state (`undefined` while no edit is open), `open` and `apply`, which
 *     takes a step as if a key had made it.
 */
export function useEditState<S, V>(
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
export const numberKeys: LegendItem[] = legendOf([
    legendFor("take", keys.enter),
    legendFor("cancel", keys.escape),
    legendBack,
])

/**
 * A list, a path or an optional number, typed as one line into the shared [[Prompt]]
 * and read by `parseSetting`. A wrong text stays as an error under the line until the
 * next key.
 */
export function TextEditor({ def, current, onEnd, onLegend }: EditorProps): ReactNode {
    const [error, setError] = useState<string>()
    const clearError = useCallback(() => setError(undefined), [])
    const { label, placeholder } = textHint(def)
    return (
        <Prompt
            label={label}
            initial={def.kind === "path" ? (current as string) : valueText(def, current)}
            maxLength={
                def.kind === "path"
                    ? MAX_PATH_TYPING
                    : listKinds.has(def.kind)
                        ? MAX_LIST_TYPING
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
export function TabsEditor({ def, current, onEnd, onLegend }: EditorProps): ReactNode {
    const theme = useTheme()
    const [edit, setEdit] = useState(() => openTabs(def.choices, current as string[]))
    useEffect(() => {
        onLegend([
            legendFor("move", [keys.left, keys.right], keys.tab),
            legendFor("toggle", keys.enter, keys.mark),
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
            <ErrorText reserve>{edit.error}</ErrorText>
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
 * `cmyk(c%, m%, y%, k%)`): the list then shows every named colour with exactly that 8-bit
 * colour, and a panel beside it writes the highlighted colour in each notation. The math
 * font setting lists fonts with a MATH table, the text font setting the others; a name
 * not in the list is refused (with no fonts found the text is taken as typed).
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
export function PickerEditor({
    def,
    current,
    fonts,
    onEnd,
    onLegend,
}: EditorProps): ReactNode {
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
 * A tuple edited part by part: left, right and Tab move the focus (the first key typed
 * into a number part replaces it), Enter on a number part takes the whole tuple (a wrong
 * one stays as an error under the fields, the part at fault in focus), Esc drops the
 * edit. Enter on a colour part opens the colour picker for it and goes on to the next
 * part; Esc in the picker returns to the fields. A colour is kept as the picker gives it:
 * a name Julia reads, else `#rrggbb` (see `colourOf`).
 */
export function TupleEditor({ def, current, onEnd, onLegend }: EditorProps): ReactNode {
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
            <ErrorText reserve>{truncate(edit.error ?? "", columns)}</ErrorText>
        </Box>
    )
}

/** The rows the ladder editor spends besides its list: a header, a note and the error. */
const LADDER_CHROME = 3

/** What the ladder editor is showing now. */
type LadderStep =
    /** The rungs, in the order tried. */
    | { at: "list" }
    /** The picker of a condition: for a rung being added, or for `from`'s own. */
    | { at: "condition"; from?: RungSheet }
    /** The prompt of a name: of a new rung of `cls`, or of the rung of `from`. */
    | { at: "name"; cls: string; from?: RungSheet }
    /** The sheet of one rung: its condition, its name and its overrides. */
    | ({ at: "rung" } & RungSheet)
    /** The picker of a setting to override. */
    | ({ at: "setting" } & RungSheet)
    /** The editor of the value of one override (`adding`: it is not in the rung yet). */
    | ({ at: "value"; name: string } & RungSheet)

/** The rung of a sheet, and what it was when the sheet was opened (to revert to). */
type RungSheet = { ref: RungRef; opened: LadderRung }

/** What the ladder editor is told. */
type LadderProps = {
    def: SettingDef
    current: SettingValue
    /** The rows the editor may use in all (the body under the frame's header). */
    rows: number
    onEnd: (end: EditEnd<SettingValue>) => void
    onLegend: (keys: LegendItem[]) => void
}

/** The value editor of an override, by the kind of its setting (the sheets' own). */
function OverrideValueEditor(props: {
    ladder: SettingDef
    name: string
    current: SettingValue
    onEnd: (end: EditEnd<SettingValue>) => void
    onLegend: (keys: LegendItem[]) => void
}): ReactNode {
    const { ladder, name, current, onEnd, onLegend } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const target = overrideDef(ladder, name) as SettingDef
    const editor =
        target.kind === "tuple" ? (
            <TupleEditor def={target} current={current} onEnd={onEnd} onLegend={onLegend} />
        ) : target.kind === "set" ? (
            <TabsEditor def={target} current={current} onEnd={onEnd} onLegend={onLegend} />
        ) : (
            <TextEditor def={target} current={current} onEnd={onEnd} onLegend={onLegend} />
        )
    return (
        <Box flexDirection="column">
            <Text color={theme.fg} bold>
                {truncate(name, columns)}
            </Text>
            <Text color={theme.mt}>{truncate(target.description, columns)}</Text>
            {editor}
        </Box>
    )
}

/**
 * The retry ladder, edited as a scrolling list of rungs in the order tried, each
 * `condition ▸ name ▸ N overrides` (the condition is the failure class, in plain words).
 * It fills the body of the sheet and scrolls like the other lists (`useListCursor`).
 *
 * In the list: up and down move, PgUp and PgDn page, Enter opens the rung, Ctrl+n adds a
 * rung (pick its condition, then give it a name, then its first override), Ctrl+r
 * removes it, Shift+up and Shift+down move it earlier or later among those of its
 * condition, Ctrl+u puts the default ladder back, Esc takes the whole ladder (a wrong
 * one stays as an error), Ctrl+x goes back without it.
 *
 * The sheet of a rung lists its condition and name (Enter changes them) and its
 * overrides, `SETTING  value`: Enter edits the value with the setting's own editor (a
 * bool flips), Ctrl+n adds an override (pick from the settings a rung may override),
 * Ctrl+r removes it, Shift+up and Shift+down move it, Ctrl+u reverts the rung to how it
 * was opened, Esc closes the sheet (a rung left with no override is dropped).
 */
export function LadderEditor({
    def,
    current,
    rows,
    onEnd,
    onLegend,
}: LadderProps): ReactNode {
    const theme = useTheme()
    const columns = useBodyColumns()
    const [map, setMap] = useState<LadderMap>(current as LadderMap)
    const [step, setStep] = useState<LadderStep>({ at: "list" })
    const [error, setError] = useState<string>()
    // what the highlighted setting of the picker does
    const [described, setDescribed] = useState("")
    const rungs = useMemo(() => ladderRungs(map, def.classes), [map, def.classes])
    const lines = Math.max(3, rows - LADDER_CHROME)
    const list = useListCursor(rungs.length, lines)

    // the rung of the sheet (and of the pickers and editors opened from it)
    const sheetOf = step.at === "list" ? undefined : "opened" in step ? step : step.from
    const rung = sheetOf === undefined ? undefined : rungOf(map, sheetOf.ref)
    const names = rung === undefined ? [] : Object.keys(rung.overrides)
    const sheet = useListCursor(2 + names.length, lines)
    const onOverride = sheet.index >= 2

    const conditionWidth = Math.max(0, ...def.classes.map((c) => conditionLabel(c).length))

    // --- the legends of the two views (a picker or an editor gives its own)
    const inRung = step.at === "rung"
    useEffect(() => {
        if (step.at === "list")
            onLegend([
                legendFor("move", [keys.up, keys.down]),
                legendFor("open", keys.enter),
                legendFor("add rung", keys.addNonbio),
                legendFor("remove", keys.remove),
                legendFor("reorder", [keys.pageUpShift, keys.pageDownShift]),
                legendFor("default", keys.undo),
                legendFor("done", keys.escape),
                legendBack,
            ])
        else if (inRung)
            onLegend([
                legendFor("move", [keys.up, keys.down]),
                legendFor("edit", keys.enter),
                legendFor("add override", keys.addNonbio),
                ...(onOverride
                    ? [
                        legendFor("remove", keys.remove),
                        legendFor("reorder", [keys.pageUpShift, keys.pageDownShift]),
                    ]
                    : []),
                legendFor("revert rung", keys.undo),
                legendFor("close", keys.escape),
                legendBack,
            ])
    }, [step.at, inRung, onOverride, onLegend])

    // --- the list
    const openRung = (r: RungRef): void => {
        const one = rungOf(map, r)
        if (one === undefined) return
        sheet.set(0)
        setStep({ at: "rung", ref: r, opened: one })
    }
    useKeys((press) => {
        setError(undefined)
        const at = rungs[list.index]
        if (press.is(keys.pageUpShift) || press.is(keys.pageDownShift)) {
            const by = press.is(keys.pageUpShift) ? -1 : 1
            const next = rungs[list.index + by]
            if (at === undefined || next === undefined || next.cls !== at.cls) return
            setMap(moveRung(map, at.cls, at.index, by))
            list.move(by)
        } else if (press.is(keys.up)) list.move(-1)
        else if (press.is(keys.down)) list.move(1)
        else if (press.is(keys.pageUp)) list.move(-lines)
        else if (press.is(keys.pageDown)) list.move(lines)
        else if (press.is(keys.home)) list.set(0)
        else if (press.is(keys.end)) list.set(rungs.length - 1)
        else if (press.is(keys.enter)) {
            if (at !== undefined) openRung(at)
        } else if (press.is(keys.addNonbio)) setStep({ at: "condition" })
        else if (press.is(keys.remove)) {
            if (at !== undefined) setMap(dropRung(map, at.cls, at.index))
        } else if (press.is(keys.undo)) {
            setMap(def.default as LadderMap)
            list.set(0)
        } else if (press.is(keys.escape)) {
            const checked = validateValue(def, map as SettingValue)
            if (checked.ok) onEnd({ kind: "done", value: checked.value })
            else setError(checked.error)
        } else if (press.is(keys.back)) onEnd({ kind: "back" })
    }, step.at === "list")

    // --- the sheet of a rung
    const closeSheet = (ref: RungRef): void => {
        // a rung with no override runs nothing (and the ladder would be refused)
        const empty = Object.keys(rungOf(map, ref)?.overrides ?? {}).length === 0
        const next = empty ? dropRung(map, ref.cls, ref.index) : map
        setMap(next)
        list.set(Math.max(0, rungPlace(map, def.classes, ref)))
        setStep({ at: "list" })
    }
    const toggle = (ref: RungRef, name: string, now: SettingValue): void =>
        setMap(setOverride(map, ref, name, !now))
    useKeys((press) => {
        if (step.at !== "rung") return
        setError(undefined)
        const { ref, opened } = step
        const name = names[sheet.index - 2]
        const onName = name !== undefined
        if (press.is(keys.pageUpShift) || press.is(keys.pageDownShift)) {
            const by = press.is(keys.pageUpShift) ? -1 : 1
            if (onName && sheet.index + by >= 2 && sheet.index + by < 2 + names.length) {
                setMap(moveOverride(map, ref, name, by))
                sheet.move(by)
            }
        } else if (press.is(keys.up)) sheet.move(-1)
        else if (press.is(keys.down)) sheet.move(1)
        else if (press.is(keys.pageUp)) sheet.move(-lines)
        else if (press.is(keys.pageDown)) sheet.move(lines)
        else if (press.is(keys.enter)) {
            if (sheet.index === 0) setStep({ at: "condition", from: { ref, opened } })
            else if (sheet.index === 1) {
                setStep({ at: "name", cls: ref.cls, from: { ref, opened } })
            }
            else if (onName) {
                const kind = overrideDef(def, name)?.kind
                const value = rung?.overrides[name] as SettingValue
                if (kind === "bool") toggle(ref, name, value)
                else setStep({ at: "value", name, ref, opened })
            }
        } else if (press.is(keys.addNonbio)) {
            if (rung !== undefined && addableOverrides(def, rung).length === 0)
                setError("every setting a rung may override is already set")
            else setStep({ at: "setting", ref, opened })
        } else if (press.is(keys.remove)) {
            if (onName) setMap(dropOverride(map, ref, name))
        } else if (press.is(keys.undo)) setMap(putRung(map, ref.cls, ref.index, opened))
        else if (press.is(keys.escape)) closeSheet(ref)
        else if (press.is(keys.back)) onEnd({ kind: "back" })
    }, step.at === "rung")

    // --- the pickers, the prompt and the value editor
    const choiceLines = Math.max(3, Math.min(suggestionLines, rows - DROPDOWN_CHROME))
    if (step.at === "condition") {
        const from = step.from
        const choices = def.classes.map((cls) => ({
            label: conditionLabel(cls),
            value: cls,
        }))
        return (
            <Dropdown<string>
                label="condition:"
                search={filterChoices(choices)}
                lines={Math.min(choiceLines, choices.length)}
                onPick={(cls) => {
                    if (from === undefined) return setStep({ at: "name", cls })
                    const moved = recondition(map, from.ref, cls)
                    setMap(moved.map)
                    setStep({ at: "rung", ref: moved.ref, opened: from.opened })
                }}
                onCancel={() =>
                    setStep(from === undefined ? { at: "list" } : { at: "rung", ...from })
                }
                onBack={() => onEnd({ kind: "back" })}
                onLegend={onLegend}
            />
        )
    }
    if (step.at === "name") {
        const from = step.from
        const cls = step.cls
        return (
            <Prompt
                label="name:"
                initial={from === undefined ? "" : (rung?.name ?? "")}
                maxLength={MAX_RUNG_NAME}
                placeholder="optional: what the rung is for"
                onSubmit={(text) => {
                    const name = text.trim()
                    if (from !== undefined) {
                        setMap(renameRung(map, from.ref, name))
                        return setStep({ at: "rung", ...from })
                    }
                    // a new rung ends the rungs of its
                    // condition; its first override is next
                    const made: LadderRung = { name, overrides: {} }
                    const ref = { cls, index: (map[cls] ?? []).length }
                    const next = putRung(map, cls, ref.index, made)
                    setMap(next)
                    list.set(Math.max(0, rungPlace(next, def.classes, ref)))
                    sheet.set(0)
                    setStep({ at: "setting", ref, opened: made })
                }}
                onCancel={() =>
                    setStep(from === undefined ? { at: "list" } : { at: "rung", ...from })
                }
                onBack={() => onEnd({ kind: "back" })}
                onLegend={onLegend}
            />
        )
    }
    if (step.at === "setting") {
        const { ref, opened } = step
        const addable = rung === undefined ? [] : addableOverrides(def, rung)
        const choices = addable.map((name) => ({ label: name, value: name }))
        const room = Math.max(3, Math.min(suggestionLines, rows - DROPDOWN_CHROME - 2))
        return (
            <Box flexDirection="column">
                <Dropdown<string>
                    label="setting:"
                    search={filterChoices(choices)}
                    lines={Math.min(room, Math.max(1, choices.length))}
                    noMatch="no such setting a rung may override"
                    onHighlight={(name) =>
                        setDescribed(
                            name === undefined ? "" : overrideDescription(def, name),
                        )
                    }
                    onPick={(name) => {
                        const target = overrideDef(def, name) as SettingDef
                        if (target.kind === "bool") {
                            const flipped = !(target.default as boolean)
                            const next = setOverride(map, ref, name, flipped)
                            setMap(next)
                            const overrides = rungOf(next, ref)?.overrides ?? {}
                            sheet.set(2 + Object.keys(overrides).length - 1)
                            return setStep({ at: "rung", ref, opened })
                        }
                        setStep({ at: "value", name, ref, opened })
                    }}
                    onCancel={() => setStep({ at: "rung", ref, opened })}
                    onBack={() => onEnd({ kind: "back" })}
                    onLegend={onLegend}
                />
                <Text color={theme.mt}>
                    {wrapText(described, columns).slice(0, 2).join("\n")}
                </Text>
            </Box>
        )
    }
    if (step.at === "value") {
        const { ref, opened, name } = step
        const target = overrideDef(def, name) as SettingDef
        return (
            <OverrideValueEditor
                key={name}
                ladder={def}
                name={name}
                current={rung?.overrides[name] ?? target.default}
                onEnd={(end) => {
                    if (end.kind === "back") return onEnd({ kind: "back" })
                    if (end.kind === "done") {
                        const next = setOverride(map, ref, name, end.value)
                        setMap(next)
                        const names = Object.keys(rungOf(next, ref)?.overrides ?? {})
                        const at = names.indexOf(name)
                        sheet.set(2 + at)
                    }
                    setStep({ at: "rung", ref, opened })
                }}
                onLegend={onLegend}
            />
        )
    }

    // --- the drawing of the list and of the sheet
    if (step.at === "rung" && rung !== undefined && sheetOf !== undefined) {
        const place = rungPlace(map, def.classes, sheetOf.ref)
        const labelWidth = Math.max(
            "condition".length,
            ...names.map((n) => n.length),
        )
        const rowsText = [
            `${"condition".padEnd(labelWidth)}  ${conditionLabel(sheetOf.ref.cls)}`,
            `${"name".padEnd(labelWidth)}  ${rung.name === "" ? "(unnamed)" : rung.name}`,
            ...names.map((n) => {
                const value = overrideValueText(def, n, rung.overrides[n] as SettingValue)
                return `${n.padEnd(labelWidth)}  ${value}`
            }),
        ]
        const highlighted = onOverride ? names[sheet.index - 2] : undefined
        return (
            <Box flexDirection="column">
                <Text color={theme.fg} bold>
                    {truncate(
                        `rung ${place + 1} of ${rungs.length} · ` +
                            positionStatus(sheet.index, rowsText.length) +
                            (names.length === 0 ? " · no override yet: add one" : ""),
                        columns,
                    )}
                </Text>
                <CursorList
                    items={rowsText}
                    index={sheet.index}
                    offset={sheet.offset}
                    lines={lines}
                    row={(text, on) => (
                        <ListText on={on}>{truncate(text, columns - 2)}</ListText>
                    )}
                />
                <Box flexGrow={1} />
                <Text color={theme.mt}>
                    {truncate(
                        highlighted === undefined
                            ? ""
                            : overrideDescription(def, highlighted),
                        columns,
                    )}
                </Text>
                <ErrorText reserve>{truncate(error ?? "", columns)}</ErrorText>
            </Box>
        )
    }
    return (
        <Box flexDirection="column">
            <Text color={theme.fg} bold>
                {truncate(
                    rungs.length === 0
                        ? "no rungs: the ladder is off"
                        : `rung ${list.index + 1} of ${rungs.length}`,
                    columns,
                )}
            </Text>
            <CursorList
                items={rungs}
                index={list.index}
                offset={list.offset}
                lines={lines}
                row={(r, on) => (
                    <ListText on={on}>
                        {truncate(
                            rungRowText(
                                rungOf(map, r) as LadderRung,
                                r.cls,
                                conditionWidth,
                            ),
                            columns - 2,
                        )}
                    </ListText>
                )}
            />
            <Box flexGrow={1} />
            <Text color={theme.mt}>
                {truncate(
                    `a fit is rerun ${LADDER_RERUNS} times at most, ` +
                        "whatever the number of rungs",
                    columns,
                )}
            </Text>
            <ErrorText reserve>{truncate(error ?? "", columns)}</ErrorText>
        </Box>
    )
}
