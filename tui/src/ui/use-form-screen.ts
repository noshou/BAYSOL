// SPDX-License-Identifier: LGPL-3.0-or-later

import { useCallback, useState } from "react"
import type { FieldFormEdit } from "./field-form.js"
import { type CellPos, moveCell, placeAt } from "./form-layout.js"
import { keys } from "./keys.js"
import type { Moves } from "./legend.js"
import { useKeys } from "./use-keys.js"

/**
 * What a form screen knows about its own cells; the hook asks for it when a key needs
 * it. Every function sees the current state of the screen (a new spec is made on every
 * render), so none of them keeps anything.
 *
 * @property valid - for each row of the form, the columns that have a cell.
 * @property editLabel - the label of the prompt for a cell, e.g. `"formula:"`.
 * @property editText - the text the prompt starts from.
 * @property take - takes the text typed for a cell into the screen's state; returns an
 *     `error` (the cell then stays open, the error under the field) or, when the text
 *     was taken, a `note` for the frame (the reason a formula was not understood).
 * @property restore - puts a cell back to what it was when the form opened.
 * @property check - the first thing wrong with the form: where and what; `undefined`
 *     when it can be accepted.
 * @property canRestore - whether `^u` has anything to put back on a cell (the cell differs
 *     from what it was when the form opened); `true` for every cell when left out.
 * @property accept - the form is complete: hand it back and leave.
 * @property cancel - leave and change nothing.
 */
export type FormScreenSpec = {
    valid:     readonly (readonly number[])[]
    editLabel: (pos: CellPos) => string
    editText:  (pos: CellPos) => string
    take:      (pos: CellPos, text: string) => { error?: string; note?: string }
    restore:   (pos: CellPos) => void
    canRestore?: (pos: CellPos) => boolean
    check:     () => { pos: CellPos; message: string } | undefined
    accept:    () => void
    cancel:    () => void
}

/**
 * What the hook gives the screen to draw.
 *
 * @property pos - the cell the cursor is on.
 * @property edit - the prompt, while a cell is being typed into (for `FieldForm`).
 * @property problem - the row to flag after `^w` found a problem (for `FieldForm`).
 * @property note - the line for the `Frame`: what `^w` found, or what taking a cell said.
 * @property noteIsError - draw the note in the error colour (always true now).
 * @property moves - which arrows move the cursor from `pos` (a neighbouring cell exists
 *     in that direction), for the legend.
 * @property canRestore - `^u` has something to put back on the cell under the cursor.
 * @property complete - `spec.check` finds nothing: `^w` would accept the form.
 */
export type FormScreen = {
    pos:         CellPos
    edit:        FieldFormEdit | undefined
    problem:     { row: number; message: string } | undefined
    note:        string | undefined
    noteIsError: boolean
    moves:       Moves
    canRestore:  boolean
    complete:    boolean
}

/**
 * The keys and state every form page has: up, down, left and right move the cursor over
 * the cells, Enter opens a prompt on the cell and takes what is typed (a mistake keeps it
 * open with a message), `^u` restores the cell, `^w` accepts the form only if
 * `spec.check` finds nothing (else the problem is the note, flagged on its row, and the
 * cursor goes there) and Esc or Ctrl-X cancel. While the prompt is open it takes the
 * keys, Esc closing just the prompt. The form page decides what the cells mean (the
 * spec) and draws them (`FieldForm`, `Frame`).
 *
 * @param spec - what the screen knows about its cells.
 * @returns what to draw.
 */
export function useFormScreen(spec: FormScreenSpec): FormScreen {
    const [pos, setPos] = useState<CellPos>(() => placeAt(0, spec.valid[0]?.[0] ?? 0))
    const [editing, setEditing] = useState(false)
    const [editError, setEditError] = useState<string | undefined>(undefined)
    const [note, setNote] = useState<string | undefined>(undefined)
    const [problem, setProblem] = useState<FormScreen["problem"]>(undefined)

    // stable, so that the prompt's own effect does not clear a fresh error at once
    const onChange = useCallback(() => setEditError(undefined), [])
    const closePrompt = useCallback(() => {
        setEditing(false)
        setEditError(undefined)
    }, [])

    useKeys((press) => {
        setNote(undefined)
        setProblem(undefined)
        const arrows = [
            [keys.up, -1, 0],
            [keys.down, 1, 0],
            [keys.left, 0, -1],
            [keys.right, 0, 1],
        ] as const
        const move = arrows.find(([key]) => press.is(key))
        if (move) setPos(moveCell(spec.valid, pos, move[1], move[2]))
        else if (press.is(keys.enter)) setEditing(true)
        else if (press.is(keys.undo)) spec.restore(pos)
        else if (press.is(keys.save)) {
            const found = spec.check()
            if (!found) return spec.accept()
            setPos(placeAt(found.pos.row, found.pos.col))
            setProblem({ row: found.pos.row, message: found.message })
            setNote(found.message)
        } else if (press.is(keys.escape) || press.is(keys.back)) spec.cancel()
    }, !editing)

    const editOf = (): FieldFormEdit => ({
        label: spec.editLabel(pos),
        initial: spec.editText(pos),
        error: editError,
        onChange,
        onCancel: closePrompt,
        onSubmit: (text) => {
            const result = spec.take(pos, text)
            if (result.error) return setEditError(result.error)
            closePrompt()
            setNote(result.note)
        },
    })
    const edit: FieldFormEdit | undefined = editing ? editOf() : undefined
    const moves: Moves = {
        up: moveCell(spec.valid, pos, -1, 0).row !== pos.row,
        down: moveCell(spec.valid, pos, 1, 0).row !== pos.row,
        left: moveCell(spec.valid, pos, 0, -1).col !== pos.col,
        right: moveCell(spec.valid, pos, 0, 1).col !== pos.col,
    }
    return {
        pos,
        edit,
        problem,
        note,
        noteIsError: true,
        moves,
        canRestore: spec.canRestore?.(pos) ?? true,
        complete: spec.check() === undefined,
    }
}
