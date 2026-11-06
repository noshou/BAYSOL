// SPDX-License-Identifier: LGPL-3.0-or-later

import type { ReactNode } from "react"
import { Entry } from "./entry.js"
import type { LegendItem } from "./legend.js"
import type { Suggestion } from "./suggestion-list.js"

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
    const {
        label,
        search,
        noMatch,
        initial,
        onPick,
        onCancel,
        onBack,
        onHighlight,
        take,
        extras,
        cancel,
        onLegend,
        active,
    } = props
    return (
        <Entry<Choice<T>>
            label={label}
            initial={initial}
            suggest={search}
            pick
            noMatch={noMatch ?? "no match"}
            onSubmit={(_, choice) => choice && onPick(choice.value)}
            onCancel={onCancel}
            onBack={onBack}
            active={active}
            take={take}
            listedExtras={extras}
            cancel={cancel}
            onLegend={onLegend}
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
