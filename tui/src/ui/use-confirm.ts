// SPDX-License-Identifier: LGPL-3.0-or-later

import { useCallback, useState } from "react"
import { type KeyInput, keys } from "./keys.js"

/**
 * A question that Enter confirms and Esc (or Ctrl-X) declines, kept as state so a
 * screen can show it as its note and route keys to it first.
 *
 * @property question - the text to show, `undefined` while nothing is asked.
 * @property ask - asks `question`; `action` runs if Enter answers it.
 * @property handleKey - gives a key press to the open question: returns `true` when
 *     a question was open (the press was its answer, or ignored), so the screen
 *     stops there; `false` when nothing is asked and the screen handles the key.
 */
export type Confirm = {
    question: string | undefined
    ask:      (question: string, action: () => void) => void
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
    const [pending, setPending] = useState<{ question: string; action: () => void } | null>(null)

    const ask = useCallback(
        (question: string, action: () => void) => setPending({ question, action }),
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

    return { question: pending?.question, ask, handleKey }
}

/**
 * The unsaved-changes guard of a table or sheet: leaving with changes first asks
 * `discard N changes?`, and leaving with none just leaves.
 *
 * @param changes - how many unsaved changes the screen holds.
 * @returns the [[Confirm]] to route keys to, and `leave`, which a screen calls with
 *     what it would do (`nav.pop`, `nav.quit`) when Esc or Ctrl-X asks to leave.
 */
export function useDiscardGuard(changes: number): Confirm & { leave: (action: () => void) => void } {
    const confirm = useConfirm()
    const leave = useCallback((action: () => void) => {
        if (changes === 0) action()
        else
            confirm.ask(
                `discard ${changes} change${changes === 1 ? "" : "s"}?  enter: discard  esc: keep`,
                action
            )
    }, [changes, confirm.ask])
    return { ...confirm, leave }
}
