// SPDX-License-Identifier: LGPL-3.0-or-later

import { useCallback, useState } from "react"
import { truncate } from "../core/text.js"
import { type KeyInput, keys } from "./keys.js"
import { type LegendItem, legendFor } from "./legend.js"

/** The most cells of the name of what is deleted that the question shows. */
const maxWhatCells = 24

/**
 * A question: what is asked and what its two answers do. The note line shows only the
 * text ([[questionNote]]); the answers are in the legend as `yes: ⏎` and `no: esc`, both
 * from these fields, so the keys are written once and never repeated in the note.
 *
 * @property text - what is asked, e.g. `delete project demo? this cannot be undone!`.
 * @property yes - what Enter does, e.g. `delete`.
 * @property no - what Esc does, e.g. `keep`.
 */
export type Question = { text: string; yes: string; no: string }

/**
 * The note line of a question: the text and the keys that answer it.
 *
 * @param question - the question.
 * @returns the text of the question, without the keys that answer it.
 */
export function questionNote(question: Question): string {
    return question.text
}

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
 * @property note - the question as the note line shows it ([[questionNote]]).
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
    return { question, note: question && questionNote(question), ask, handleKey }
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
 * saved recipe, a custom solute, a model). Every such removal asks exactly this, and
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
