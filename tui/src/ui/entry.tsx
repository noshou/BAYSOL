// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react"
import { keys } from "./keys.js"
import { useBodyColumns } from "./layout.js"
import { entryLegend, type LegendItem } from "./legend.js"
import { stepIndex } from "./scroll-window.js"
import { positionStatus, type Suggestion, SuggestionList } from "./suggestion-list.js"
import { TextField } from "./text-field.js"
import { useTheme } from "./theme.js"
import { useKeys } from "./use-keys.js"
import { useTextBuffer } from "./use-text-buffer.js"

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
    const input = useTextBuffer(initial ?? "", maxLength, active)
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

    // tell the screen about every change of the text, but not about the first text
    const first = useRef(true)
    useEffect(() => {
        if (first.current) first.current = false
        else onChange?.(text)
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
