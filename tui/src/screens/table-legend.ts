// SPDX-License-Identifier: LGPL-3.0-or-later

// The key legends of the screens, as pure functions of what the screen is doing right
// now: a legend lists ONLY the keys that work at this moment (like the move hint of the
// menus), so a key that would do nothing is not shown. Two shapes cover the screens:
//
//   - `tableLegend`: a table of editable rows (the solutes, the custom solutes, the
//     recipes), from where the cursor is and what the rows allow;
//   - `formLegend`: a form page, from where the cursor is and what the form allows.
//
// A prompt or dropdown that is open gives its own legend (`entryLegend` in
// `ui/legend.tsx`, reported by `Entry`'s `onLegend`), a question its answers
// (`questionLegend` in `ui/use-confirm.ts`). The screens only gather the facts
// (`TableFacts`, ...) and call these, so the rules are in one place and tested without a
// terminal.

import { keys } from "../ui/keys.js"
import {
    entryLegend,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    type Moves,
    moveLegend,
} from "../ui/legend.js"

/**
 * What a table's legend depends on.
 *
 * @property rows - how many rows the table has.
 * @property cursor - the row the cursor is on (meaningless for no rows).
 * @property canEdit - Enter may open the row under the cursor.
 * @property canAdd - an add key may add a row (room and no lock).
 * @property locked - the file cannot be used: nothing that changes something works.
 * @property canRemove - `^r` has something to mark: a row that is not marked yet.
 * @property canUndo - `^u` has something to undo on the row under the cursor.
 * @property removeLabel - what `^r` is called: `remove` when left out (a mark), `delete`
 *     for a table whose `^r` deletes the saved entry at once.
 * @property dirty - there are unsaved changes.
 */
export type TableFacts = {
    rows: number
    cursor: number
    canEdit: boolean
    canAdd: boolean
    locked: boolean
    canRemove: boolean
    canUndo: boolean
    removeLabel?: string
    dirty: boolean
}

/**
 * The legend of a table with nothing open over it: `back` always, `save` when
 * something is unsaved, `edit` when a row can be opened, the arrows that move from the
 * cursor's row, the add keys when there is room, `remove` and `undo` when they have a
 * row to act on.
 *
 * @param facts - what the table allows now.
 * @param adds - the add keys of this table (`add solute ^n`, ...); shown only when
 *     `facts.canAdd`.
 * @param editLabel - what Enter does on a row, `"edit"` when left out.
 * @returns the items, in order.
 */
export function tableLegend(
    facts: TableFacts,
    adds: LegendItem[],
    editLabel = "edit",
): LegendItem[] {
    const { rows, cursor, locked } = facts
    return legendOf([
        legendBack,
        facts.dirty && !locked && legendFor("save", keys.save),
        facts.canEdit && legendFor(editLabel, keys.enter),
        moveLegend({ up: rows > 0 && cursor > 0, down: rows > 0 && cursor < rows - 1 }),
        ...(facts.canAdd ? adds : []),
        facts.canRemove &&
            !locked && legendFor(facts.removeLabel ?? "remove", keys.remove),
        facts.canUndo && !locked && legendFor("undo", keys.undo),
    ])
}

/**
 * What the legend of a form page depends on.
 *
 * @property editing - a cell's prompt is open.
 * @property moves - which arrows move the cursor to a neighbouring cell.
 * @property canRestore - `^u` has something to put back on this cell.
 * @property complete - nothing is missing, so `^w` would accept the form.
 * @property acceptLabel - what `^w` is called (`add to table`, `accept`).
 */
export type FormFacts = {
    editing: boolean
    moves: Moves
    canRestore: boolean
    complete: boolean
    acceptLabel: string
}

/**
 * The legend of a form page: the prompt's keys while a cell is open, else `cancel`,
 * `accept` only when the form is complete, `edit`, the arrows that reach a neighbouring
 * cell and `restore` only on a cell that was changed.
 *
 * @param facts - what the form is doing.
 * @returns the items, in order.
 */
export function formLegend(facts: FormFacts): LegendItem[] {
    if (facts.editing) return entryLegend({ count: 0 })
    return legendOf([
        legendFor("cancel", keys.escape),
        facts.complete && legendFor(facts.acceptLabel, keys.save),
        legendFor("edit", keys.enter),
        moveLegend(facts.moves),
        facts.canRestore && legendFor("undo", keys.undo),
    ])
}
