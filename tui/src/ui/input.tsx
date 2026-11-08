// SPDX-License-Identifier: LGPL-3.0-or-later

// Input: how a screen asks the user for something, and the theme picker that every
// screen can open.
//
// Contents:
//   1. Suggestions: the list drawn under an input (`SuggestionList`, `Suggestion`)
//   2. `Entry`: the text/pick input with its legend
//   3. `Prompt`: a text `Entry` that takes what was typed
//   4. `Dropdown`: a pick `Entry` over a list of choices
//   5. Confirmation: `Question`, `useConfirm`, `useDiscardGuard`
//   6. `usePickList`: dropdown + delete + question wiring
//   7. `ThemePicker`: the list of themes, opened with Ctrl-T

import { Box, Text, useWindowSize } from "ink"
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react"
import { padWidth, truncate } from "../core/terminal.js"
import { entryLegend, type LegendItem, legendFor } from "./grid.js"
import {
    CursorList,
    centredWindow,
    type KeyInput,
    keys,
    ListText,
    Swatch,
    stepIndex,
    swatchCells,
    TextField,
    useBodyColumns,
    useKeys,
    useListCursor,
    useTextBuffer,
} from "./interaction.js"
import { Logo, logoCells, Panel, type Theme, themes, useTheme } from "./theme.js"

// ========================================================================================
// 1. Suggestions
// ========================================================================================

/**
 * One line of a list of suggestions.
 *
 * @property label - the text shown.
 * @property completion - what Tab puts into the input, `label` when left out (a path
 *     hint shows the file name but completes the whole path).
 * @property tag - a short kind shown muted after it (`solute`, `polymer`, `custom`).
 * @property swatch - a colour (`#rrggbb`) drawn as a swatch before the label. A list
 *     where any item has one keeps the column for all, so the labels stay aligned.
 */
export type Suggestion = {
    label: string
    completion?: string
    tag?: string
    swatch?: string
}

/**
 * The position of the highlight in a list, for the status line under it.
 *
 * @param index - the highlighted item.
 * @param count - how many items there are (at least 1).
 * @returns `3 of 12`.
 */
export function positionStatus(index: number, count: number): string {
    return `${index + 1} of ${count}`
}

/**
 * A list of suggestions under an input, the highlighted one marked with `>`: a
 * [[CursorList]] over a window centred on the highlight.
 *
 * @param items - the suggestions, best first.
 * @param highlight - the index of the highlighted one.
 * @param lines - the most items shown; the list scrolls to keep the highlight in view.
 * @param width - the cells each line may use.
 * @param status - a line below the items (`no match`, `3 more`), omitted when empty.
 * @returns the list.
 */
function SuggestionList(props: {
    items:     Suggestion[]
    highlight: number
    lines:     number
    width:     number
    status?:   string
}): ReactNode {
    const { items, highlight, lines, width, status } = props
    const theme = useTheme()
    const swatches = items.some((item) => item.swatch !== undefined)
    // the marker and its gap, then the swatch and its gap
    const taken = 2 + (swatches ? swatchCells + 1 : 0)
    return (
        <Box flexDirection="column">
            <CursorList
                items={items}
                index={highlight}
                offset={centredWindow(items.length, highlight, lines)}
                lines={lines}
                row={(item, on) => {
                    const tag = item.tag ? ` ${item.tag}` : ""
                    const room = Math.max(1, width - taken - tag.length)
                    return (
                        <ListText on={on}>
                            {swatches ? <Swatch colour={item.swatch} /> : null}
                            {swatches ? " " : null}
                            {padWidth(truncate(item.label, room), room)}
                            <Text color={theme.mt}>{tag}</Text>
                        </ListText>
                    )
                }}
            />
            {status ? <Text color={theme.mt}>{truncate(status, width)}</Text> : null}
        </Box>
    )
}

// ========================================================================================
// 2. Entry
// ========================================================================================

/** The most suggestions a list shows, status line not counted. */
export const suggestionLines = 7

/**
 * What an entry (the one engine behind [[Prompt]] and [[Dropdown]]) is told.
 *
 * @property label - what is asked, shown before the field.
 * @property initial - the starting text.
 * @property maxLength - the most characters taken; a field that is full says so.
 * @property placeholder - muted text while nothing is typed.
 * @property suggest - the suggestions for the typed text, best first; called on every
 *     change, so it must be fast. None given means a plain text input.
 * @property pick - `true` for a dropdown: Enter takes the highlighted suggestion, and
 *     nothing if there is none. `false`: Enter takes the typed text.
 * @property noMatch - the status line when there is no suggestion for the typed text
 *     (also for blank text when `counter` is set).
 * @property initialIndex - the suggestion highlighted at first, the best one when left out.
 * @property wrap - whether up and down go round at the ends of the list, `false` when
 *     left out (they stop).
 * @property lines - the most suggestions shown, [[suggestionLines]] when left out.
 * @property counter - show the place of the highlight (`3 of 12`) as the status line.
 * @property error - a message about the last attempt, shown under the field in the
 *     error colour; the screen clears it by changing it.
 * @property onSubmit - called with the typed text and the highlighted suggestion.
 * @property onCancel - called for Esc, and for Ctrl-X when `onBack` is not given.
 * @property onBack - called for Ctrl-X (back one screen), when it differs from Esc.
 * @property onHighlight - called with the highlighted suggestion whenever it changes
 *     (a screen that acts on the highlighted item, e.g. to remove it).
 * @property take - what Enter is called in the legend (`"take"` when left out; `null`
 *     for an entry whose Enter does nothing).
 * @property canTake - a prompt's Enter has something to take, `true` when left out.
 * @property extras - keys of this entry that work always (`file picker o`), for the legend.
 * @property listedExtras - keys that work only while the list holds something
 *     (`delete ^r`), for the legend.
 * @property cancel - what Esc is called in the legend, `"cancel"` when left out; `null`
 *     for an entry that is the screen itself, where Esc does nothing and is not shown.
 * @property onLegend - called with the keys that work now (`entryLegend` of what the
 *     entry knows: how many suggestions it lists, whether it picks, whether it has an
 *     `onBack`, plus the five props above) whenever they change, so the screen shows
 *     them without keeping any of that itself.
 * @property active - whether the entry listens to keys, `true` when left out; a screen
 *     passes `false` while a question of its own (a confirm) is open over the entry, so
 *     the entry keeps its text and comes back as it was.
 * @property onChange - called with the typed text after every edit, so a screen can
 *     clear its error or check the text as it is typed.
 * @property onPaste - sees a pasted text first, with the room the field has left;
 *     `true` means the screen took it (the field is left alone).
 */
export type EntryProps<S extends Suggestion> = {
    label:        string
    initial?:     string
    maxLength?:   number
    placeholder?: string
    suggest?:     (text: string) => S[]
    pick?:        boolean
    noMatch?:     string
    initialIndex?: number
    onPaste?:     (text: string, room: number) => boolean
    wrap?:        boolean
    lines?:       number
    counter?:     boolean
    error?:       string
    onSubmit:     (text: string, suggestion: S | undefined) => void
    onCancel:     () => void
    onBack?:      () => void
    active?:      boolean
    onHighlight?: (suggestion: S | undefined) => void
    take?:        string | null
    canTake?:     boolean
    extras?:      LegendItem[]
    listedExtras?: LegendItem[]
    cancel?:      string | null
    onLegend?:    (items: LegendItem[]) => void
    onChange?:    (text: string) => void
}

/**
 * A one-line input with an optional list of suggestions under it. Keys: typing,
 * backspace, delete, left, right, home, end edit; up and down move the highlight;
 * Tab puts the highlighted suggestion into the input; Enter submits; Esc and Ctrl-X
 * cancel. While an entry is open it is the only thing on its screen that takes keys,
 * so the screen passes `active = false` to its own `useKeys`.
 *
 * @param props - see [[EntryProps]].
 * @returns the label, the field, the error and the suggestions.
 */
export function Entry<S extends Suggestion>(props: EntryProps<S>): ReactNode {
    const { label, initial, maxLength, placeholder, suggest, pick, noMatch, error } = props
    const { onSubmit, onCancel, onBack, onHighlight, onChange, onLegend } = props
    const { active = true } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const input = useTextBuffer(initial ?? "", maxLength, active, props.onPaste)
    const { wrap = false, lines = suggestionLines, counter = false } = props
    const [highlight, setHighlight] = useState(props.initialIndex ?? 0)

    const text = input.buffer.text
    const items = useMemo(() => (suggest ? suggest(text) : []), [suggest, text])
    const marked = Math.min(highlight, Math.max(0, items.length - 1))

    useKeys((press) => {
        if (press.is(keys.escape)) return onCancel()
        if (press.is(keys.back)) return (onBack ?? onCancel)()
        if (press.is(keys.enter)) {
            // a dropdown takes what is highlighted; a prompt takes what is typed
            if (pick && items.length === 0) return
            return onSubmit(text, items[marked])
        }
        if (press.is(keys.down) || press.is(keys.up))
            return setHighlight(stepIndex(marked, items.length, press.is(keys.down), wrap))
        if (press.is(keys.tab)) {
            if (items[marked]) {
                input.set(
                    input.buffer.replace(items[marked].completion ?? items[marked].label),
                )
                // the completed text narrows the list again: its best match first
                setHighlight(0)
            }
            return
        }
        if (input.edit(press)) setHighlight(0)
    }, active)

    // tell the screen about every change of the text, but not about the first text. The
    // text is compared, not `onChange`: a screen passes a new function on every render,
    // and that must not count as an edit (it cleared the screen's error the moment the
    // error was set).
    const last = useRef(text)
    useEffect(() => {
        if (last.current === text) return
        last.current = text
        onChange?.(text)
    }, [text, onChange])

    // tell the screen which suggestion is highlighted, whenever that changes
    const current = items[marked]
    useEffect(() => onHighlight?.(current), [current, onHighlight])

    // and the keys that work now, whenever they change (compared by value: the screen's
    // extras are new arrays on every render)
    const legend = entryLegend({
        count: items.length,
        pick,
        canTake: props.canTake,
        take: props.take,
        extras: props.extras,
        listedExtras: props.listedExtras,
        cancel: props.cancel,
        back: onBack !== undefined,
    })
    const legendKey = JSON.stringify(legend)
    // biome-ignore lint/correctness/useExhaustiveDependencies: legendKey = value of legend
    useEffect(() => onLegend?.(legend), [legendKey, onLegend])

    const none = items.length === 0 && (text !== "" || counter)
    const status = none
        ? noMatch
        : counter && items.length > 0
            ? positionStatus(marked, items.length)
            : undefined
    return (
        <Box flexDirection="column">
            <Box columnGap={1}>
                <Text color={theme.fg}>{label}</Text>
                <TextField
                    buffer={input.buffer}
                    width={Math.max(10, columns - label.length - 2)}
                    placeholder={placeholder}
                />
            </Box>
            {input.buffer.full && maxLength !== undefined ? (
                <Text color={theme.er}>{maxLength} characters at most</Text>
            ) : null}
            {error ? <Text color={theme.er}>{error}</Text> : null}
            {suggest ? (
                <SuggestionList
                    items={items}
                    highlight={marked}
                    lines={lines}
                    width={columns}
                    status={status}
                />
            ) : null}
        </Box>
    )
}

// ========================================================================================
// 3. Prompt
// ========================================================================================

/**
 * A text prompt: type, Enter takes the text, Esc gives up. With `suggest` it hints
 * names under the field (up and down move, Tab completes) but still takes what was
 * typed, which is what a path prompt wants.
 *
 * @param props - the props of an [[Entry]] without `pick`.
 * @returns the prompt.
 */
export function Prompt(props: Omit<EntryProps<Suggestion>, "pick" | "noMatch">): ReactNode {
    return <Entry {...props} pick={false} />
}

// ========================================================================================
// 4. Dropdown
// ========================================================================================

/**
 * One choice of a dropdown: what is shown and what picking it gives.
 *
 * @typeParam T - the value picked.
 * @property value - what `onPick` receives.
 */
export type Choice<T> = Suggestion & { value: T }

/**
 * What a dropdown is told.
 *
 * @property label - what is asked.
 * @property search - the choices for the typed text, best first. A dropdown of a few
 *     fixed choices returns all of them for any text, filtered by the text; a
 *     searched index returns nothing for a blank text.
 * @property noMatch - the status line when nothing matches the typed text.
 * @property initial - the starting text.
 * @property onPick - called with the value of the picked choice.
 * @property onCancel - called for Esc, and for Ctrl-X when `onBack` is not given.
 * @property onBack - called for Ctrl-X, when it differs from Esc.
 * @property active - whether the dropdown listens to keys, `true` when left out.
 * @property onHighlight - called with the value of the highlighted choice whenever it
 *     changes (`undefined` when none).
 * @property take - what Enter is called in the legend (`null` when picking does nothing).
 * @property extras - keys of this dropdown that work only while it lists something
 *     (`delete ^r`), for the legend.
 * @property cancel - what Esc is called in the legend.
 * @property onLegend - called with the keys that work now whenever they change.
 */
type DropdownProps<T> = {
    label:      string
    search:     (text: string) => Choice<T>[]
    noMatch?:   string
    initial?:   string
    onPick:     (value: T) => void
    onCancel:   () => void
    onBack?:    () => void
    active?:    boolean
    onHighlight?: (value: T | undefined) => void
    take?:      string | null
    extras?:    LegendItem[]
    cancel?:    string | null
    onLegend?:  (items: LegendItem[]) => void
}

/**
 * A dropdown: type to narrow the list, up and down move, Tab completes the name,
 * Enter picks the highlighted choice (and nothing if none matches), Esc leaves.
 *
 * @param props - see [[DropdownProps]].
 * @returns the dropdown.
 */
export function Dropdown<T>(props: DropdownProps<T>): ReactNode {
    const { search, noMatch, onPick, onHighlight, extras, ...rest } = props
    return (
        <Entry<Choice<T>>
            {...rest}
            suggest={search}
            pick
            noMatch={noMatch ?? "no match"}
            onSubmit={(_, choice) => choice && onPick(choice.value)}
            listedExtras={extras}
            onHighlight={onHighlight && ((choice) => onHighlight(choice?.value))}
        />
    )
}

/**
 * A search function for a short fixed list: every choice whose label contains the
 * typed text (case does not matter), in the order given; all of them for a blank text.
 *
 * @param choices - the whole list.
 * @returns a `search` for [[Dropdown]].
 */
export function filterChoices<T>(choices: Choice<T>[]): (text: string) => Choice<T>[] {
    return (text) => {
        const needle = text.trim().toLowerCase()
        return choices.filter((c) => c.label.toLowerCase().includes(needle))
    }
}

// ========================================================================================
// 5. Confirmation
// ========================================================================================

/** The most cells of the name of what is deleted that the question shows. */
const maxWhatCells = 24

/**
 * A question: what is asked and what its two answers do. The note line shows only the
 * text; the answers are in the legend as `yes: ⏎` and `no: esc`, both
 * from these fields, so the keys are written once and never repeated in the note.
 *
 * @property text - what is asked, e.g. `delete project demo? this cannot be undone!`.
 * @property yes - what Enter does, e.g. `delete`.
 * @property no - what Esc does, e.g. `keep`.
 */
export type Question = { text: string; yes: string; no: string }

/**
 * The legend of a question: what Enter does and what Esc does, from its own fields.
 *
 * @param question - the question.
 * @returns `yes: ⏎` and `no: esc`.
 */
export function questionLegend(question: Question): LegendItem[] {
    return [
        legendFor(question.yes, keys.enter),
        legendFor(question.no, keys.escape),
    ]
}

/**
 * A question that Enter confirms and Esc (or Ctrl-X) declines, kept as state so a
 * screen can show it as its note and route keys to it first.
 *
 * @property question - the open question, `undefined` while nothing is asked.
 * @property note - the text of the open question, for the note line.
 * @property ask - asks `question`; `action` runs if Enter answers it.
 * @property handleKey - gives a key press to the open question: returns `true` when
 *     a question was open (the press was its answer, or ignored), so the screen
 *     stops there; `false` when nothing is asked and the screen handles the key.
 */
export type Confirm = {
    question: Question | undefined
    note:     string | undefined
    ask:      (question: Question, action: () => void) => void
    handleKey: (press: KeyInput) => boolean
}

/**
 * Keeps one pending question. Used for every "are you sure": a warning before
 * something the user created is removed, and the unsaved-changes guard
 * ([[useDiscardGuard]]).
 *
 * @returns the [[Confirm]].
 */
export function useConfirm(): Confirm {
    const [pending, setPending] =
        useState<{ question: Question; action: () => void } | null>(null)

    const ask = useCallback(
        (question: Question, action: () => void) => setPending({ question, action }),
        []
    )

    const handleKey = useCallback((press: KeyInput): boolean => {
        if (pending === null) return false
        if (press.is(keys.enter)) {
            setPending(null)
            pending.action()
        } else if (press.is(keys.escape) || press.is(keys.back)) {
            setPending(null)
        }
        return true
    }, [pending])

    const question = pending?.question
    return { question, note: question?.text, ask, handleKey }
}

/**
 * The unsaved-changes guard of a table or sheet: leaving with changes first asks
 * `discard N changes?`, and leaving with none just leaves.
 *
 * @param changes - how many unsaved changes the screen holds.
 * @returns the [[Confirm]] to route keys to, and `leave`, which a screen calls with
 *     what it would do (`nav.pop`) when Ctrl-X asks to leave.
 */
export function useDiscardGuard(
    changes: number,
): Confirm & { leave: (action: () => void) => void } {
    const confirm = useConfirm()
    const leave = useCallback((action: () => void) => {
        if (changes === 0) action()
        else
            confirm.ask(
                {
                    text: `discard ${changes} change${changes === 1 ? "" : "s"}?`,
                    yes: "discard",
                    no: "keep",
                },
                action
            )
    }, [changes, confirm.ask])
    return { ...confirm, leave }
}

/**
 * The question asked before anything the user made is removed for good (a project, a
 * custom solute, a model). Every such removal asks exactly this, and
 * nothing is removed without it, so the wording is in one place.
 *
 * @param what - what is about to go, e.g. `project demo`; cut at 24 cells (with `…`) so
 *     the warning behind it is never the part that does not fit.
 * @returns the question, for [[Confirm.ask]]; the note is just its text, the keys that
 *     answer it are in the legend.
 */
export function destructiveQuestion(what: string): Question {
    const text = `delete ${truncate(what, maxWhatCells)}? this cannot be undone!`
    return { text, yes: "delete", no: "keep" }
}

// ========================================================================================
// 6. Pick list with delete
// ========================================================================================

/** The legend item of the delete key, shown while the list holds an entry. */
const deleteLegend: LegendItem = legendFor("delete", keys.remove)

/**
 * What a pick list is told.
 *
 * @typeParam T - the value of an entry.
 * @property open - the list is shown (the keys of the hook are off while it is not).
 * @property label - what is asked, e.g. `load project:`.
 * @property entries - what the list holds; keep the array stable between renders (a
 *     `useMemo`), the screen reads it again by changing it.
 * @property onPick - called with the value of the entry Enter takes.
 * @property onCancel - called for Esc, and for Ctrl-X when `onBack` is not given.
 * @property onBack - called for Ctrl-X, when it differs from Esc.
 * @property take - what Enter is called in the legend, `null` when picking does nothing.
 * @property cancel - what Esc is called in the legend.
 * @property onDelete - deletes the entry; it may throw. The screen reads the entries
 *     again (they change), so the list shows what is left.
 * @property onFail - called with what `onDelete` threw.
 * @property onEmpty - called when the last entry is gone, so the screen closes the list.
 * @property question - the question asked before `onDelete`, from the highlighted value.
 * @property action - one more key on the highlighted entry (`settings ^o`): its legend
 *     label, the key and what it does with the value; it works while no question is open.
 */
type PickListProps<T> = {
    open: boolean
    label: string
    entries: Choice<T>[]
    onPick: (value: T) => void
    onCancel: () => void
    onBack?: () => void
    take?: string | null
    cancel?: string | null
    onDelete: (value: T) => void
    onFail: (error: unknown) => void
    onEmpty: () => void
    question: (value: T) => Question
    action?: { label: string; key: KeyInput; run: (value: T) => void }
}

/**
 * What [[usePickList]] gives the screen.
 *
 * @property list - the dropdown, to draw while the list is open.
 * @property note - the open question as the note line shows it, `undefined` for none.
 * @property legend - the keys that work now: the answers of the open question, else the
 *     dropdown's own with `delete ^r` while it lists an entry.
 * @property highlighted - the value of the highlighted entry, `undefined` for none.
 */
type PickList = {
    list: ReactNode
    note: string | undefined
    legend: LegendItem[]
    highlighted: unknown
}

/**
 * A pick list with delete, written once for the project list and the model list: a
 * [[Dropdown]] whose highlighted entry `^r` (or Delete) asks about with [[Question]]
 * `question(value)`; Enter then calls `onDelete`, Esc keeps it. While the
 * question is open the dropdown keeps its text but listens to nothing. The list closes
 * (`onEmpty`) when the last entry is gone.
 *
 * @param props - see [[PickListProps]].
 * @returns the [[PickList]].
 */
export function usePickList<T>(props: PickListProps<T>): PickList {
    const { open, label, entries, onPick, onCancel, onBack, take, cancel } = props
    const { onDelete, onFail, onEmpty, question, action } = props
    const confirm = useConfirm()
    const [highlighted, setHighlighted] = useState<T>()
    const [shown, setShown] = useState<LegendItem[]>([])
    const search = useMemo(() => filterChoices(entries), [entries])

    useKeys((press) => {
        if (confirm.handleKey(press)) return
        if (action !== undefined && press.is(action.key)) {
            if (highlighted !== undefined) action.run(highlighted)
            return
        }
        const wanted = press.is(keys.remove) || press.is(keys.delete)
        if (!wanted || highlighted === undefined) return
        const value = highlighted
        confirm.ask(question(value), () => {
            try {
                onDelete(value)
            } catch (error) {
                onFail(error)
            }
        })
    }, open)

    // the last entry gone: the screen closes the list
    useEffect(() => {
        if (open && entries.length === 0) onEmpty()
    }, [open, entries, onEmpty])

    const list = (
        <Dropdown<T>
            label={label}
            search={search}
            noMatch="no match"
            active={confirm.question === undefined}
            onPick={onPick}
            onCancel={onCancel}
            onBack={onBack}
            take={take}
            cancel={cancel}
            extras={
                action === undefined
                    ? [deleteLegend]
                    : [legendFor(action.label, action.key), deleteLegend]
            }
            onHighlight={setHighlighted}
            onLegend={setShown}
        />
    )
    const asked = confirm.question
    return {
        list,
        note: confirm.note,
        legend: asked ? questionLegend(asked) : shown,
        highlighted,
    }
}

// ========================================================================================
// 7. `ThemePicker`: the list of themes, opened with Ctrl-T
// ========================================================================================

/** The rows of the popup that are not list entries: its border, key row and header row. */
const popupChrome = 4

/** The column titles; each column is at least as wide as its title and one cell apart. */
const titles = { name: "theme", colours: "colours", mode: "mode" }

/** Two extra cells between the colours and the mode column, besides the usual one. */
const modeGap = 2

/** The cells of the colour column: its title or the four swatches (the wider) + the gap. */
const pickerSwatchCells = Math.max(4, titles.colours.length) + modeGap

/** The cells of the mode column: the title or the longest mode (`light`, `dark`). */
const modeCells = Math.max(titles.mode.length, "light".length)

/** The list: every theme in one alphabetical order, one row each, so all show at once. */
const entries: readonly Theme[] = themes

/**
 * The four colours a theme row shows: background, foreground, muted and error.
 *
 * @param theme - the theme.
 * @returns the colours, in that order.
 */
function swatchesOf(theme: Theme): string[] {
    return [theme.bg, theme.fg, theme.mt, theme.er]
}

/**
 * The popup that picks a theme: one row for each theme (its logo, its name and the
 * swatches of its four colours), scrolled with the arrow keys, Enter picks and Esc (or
 * `^t` again) leaves. It is drawn in the colours of the theme in use now; nothing
 * changes until a theme is picked. While it is open it is the only thing that takes keys.
 *
 * @param current - the theme in use; the cursor starts on it.
 * @param onPick - called with the theme that Enter picked.
 * @param onClose - called when the popup is left without picking.
 * @returns the popup box, to be placed over the screen.
 */
export function ThemePicker(
    { current, onPick, onClose }:
        { current: Theme; onPick: (theme: Theme) => void; onClose: () => void }
): ReactNode {
    const theme = useTheme()
    const { rows } = useWindowSize()
    const pageSize = Math.max(3, Math.min(entries.length, rows - popupChrome))
    const start = entries.indexOf(current)
    const cursor = useListCursor(entries.length, pageSize, Math.max(0, start))
    const nameCells = Math.max(titles.name.length, ...entries.map((e) => e.nm.length))

    useKeys((press) => {
        if (press.is(keys.escape) || press.is(keys.theme)) onClose()
        else if (press.is(keys.enter)) onPick(entries[cursor.index])
        else if (press.is(keys.up)) cursor.set(Math.max(0, cursor.index - 1))
        else if (press.is(keys.down))
            cursor.set(Math.min(entries.length - 1, cursor.index + 1))
    })

    return (
        <Panel flexDirection="column" paddingX={1}>
            {/* the keys are centred on a row of their own at the top */}
            <Box justifyContent="center">
                <Text color={theme.mt}>
                    pick: {keys.enter.label}   close: {keys.escape.label}
                </Text>
            </Box>
            {/* the column titles: two cells for the cursor mark, then the same columns as
                the rows below, one cell apart */}
            <Box paddingLeft={2} columnGap={1}>
                <Box width={logoCells} flexShrink={0} />
                <Text bold color={theme.fg}>{padWidth(titles.name, nameCells)}</Text>
                <Text bold color={theme.fg}>
                    {padWidth(titles.colours, pickerSwatchCells)}
                </Text>
                <Text bold color={theme.fg}>{padWidth(titles.mode, modeCells)}</Text>
            </Box>
            <CursorList
                items={entries}
                index={cursor.index}
                offset={cursor.offset}
                lines={pageSize}
                row={(e, on) => (
                    <Box columnGap={1}>
                        <Logo theme={e} />
                        <ListText on={on}>{padWidth(e.nm, nameCells)}</ListText>
                        <Box width={pickerSwatchCells} flexShrink={0}>
                            {swatchesOf(e).map((c) => (
                                <Swatch key={c} colour={c} />
                            ))}
                        </Box>
                        <Text color={theme.mt}>{padWidth(e.md, modeCells)}</Text>
                    </Box>
                )}
            />
        </Panel>
    )
}
