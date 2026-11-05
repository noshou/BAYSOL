// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react"
import { keys } from "./keys.js"
import { useTheme } from "./theme.js"
import { useBodyColumns } from "./layout.js"
import { SuggestionList, type Suggestion } from "./suggestion-list.js"
import { TextField } from "./text-field.js"
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
 * @property noMatch - the status line when a dropdown has no suggestion for the text.
 * @property error - a message about the last attempt, shown under the field in the
 *     error colour; the screen clears it by changing it.
 * @property onSubmit - called with the typed text and the highlighted suggestion.
 * @property onCancel - called for Esc, and for Ctrl-X when `onBack` is not given.
 * @property onBack - called for Ctrl-X (back one screen), when it differs from Esc.
 * @property onHighlight - called with the highlighted suggestion whenever it changes
 *     (a screen that acts on the highlighted item, e.g. to remove it).
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
    error?:       string
    onSubmit:     (text: string, suggestion: S | undefined) => void
    onCancel:     () => void
    onBack?:      () => void
    active?:      boolean
    onHighlight?: (suggestion: S | undefined) => void
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
    const { onSubmit, onCancel, onBack, onHighlight, onChange, active = true } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const input = useTextBuffer(initial ?? "", maxLength, active)
    const [highlight, setHighlight] = useState(0)

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
        if (press.is(keys.down)) return setHighlight(Math.min(marked + 1, items.length - 1))
        if (press.is(keys.up)) return setHighlight(Math.max(marked - 1, 0))
        if (press.is(keys.tab)) {
            if (items[marked]) {
                input.set(input.buffer.replace(items[marked].completion ?? items[marked].label))
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

    const status = pick && items.length === 0 && text !== "" ? noMatch : undefined
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
                    lines={suggestionLines}
                    width={columns}
                    status={status}
                />
            ) : null}
        </Box>
    )
}
