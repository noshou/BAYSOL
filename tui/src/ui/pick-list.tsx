// SPDX-License-Identifier: LGPL-3.0-or-later

import { type ReactNode, useEffect, useMemo, useState } from "react"
import { type Choice, Dropdown, filterChoices } from "./dropdown.js"
import { keys } from "./keys.js"
import { type LegendItem, legendFor } from "./legend.js"
import { type Question, questionLegend, useConfirm } from "./use-confirm.js"
import { useKeys } from "./use-keys.js"

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
}

/**
 * What [[usePickList]] gives the screen.
 *
 * @property list - the dropdown, to draw while the list is open.
 * @property note - the open question as the note line shows it, `undefined` for none.
 * @property legend - the keys that work now: the answers of the open question, else the
 *     dropdown's own with `delete ^r` while it lists an entry.
 */
type PickList = { list: ReactNode; note: string | undefined; legend: LegendItem[] }

/**
 * A pick list with delete, written once for the project list, the recipe list and the
 * model list: a [[Dropdown]] whose highlighted entry `^r` (or Delete) asks about with
 * [[Question]] `question(value)`; Enter then calls `onDelete`, Esc keeps it. While the
 * question is open the dropdown keeps its text but listens to nothing. The list closes
 * (`onEmpty`) when the last entry is gone.
 *
 * @param props - see [[PickListProps]].
 * @returns the [[PickList]].
 */
export function usePickList<T>(props: PickListProps<T>): PickList {
    const { open, label, entries, onPick, onCancel, onBack, take, cancel } = props
    const { onDelete, onFail, onEmpty, question } = props
    const confirm = useConfirm()
    const [highlighted, setHighlighted] = useState<T>()
    const [shown, setShown] = useState<LegendItem[]>([])
    const search = useMemo(() => filterChoices(entries), [entries])

    useKeys((press) => {
        if (confirm.handleKey(press)) return
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
            extras={[deleteLegend]}
            onHighlight={setHighlighted}
            onLegend={setShown}
        />
    )
    const asked = confirm.question
    return {
        list,
        note: confirm.note,
        legend: asked ? questionLegend(asked) : shown,
    }
}
