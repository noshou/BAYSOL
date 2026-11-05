// SPDX-License-Identifier: LGPL-3.0-or-later

// The mechanics every table of editable rows shares (the custom solutes, the solutes of
// a buffer, the recipes): the rows being edited (`Drafts`), the cursor, the note, the
// unsaved-changes guard and the keys that do not depend on what a row is. A screen calls
// `useTableScreen` once, draws a `DataTable` and a `Frame` from what it returns, and
// handles the keys of its own (Enter, the adds) after `handleKey` has had its turn:
//
//     const t = useTableScreen<MyItem>({ items, save, check })
//     useKeys((press) => {
//         if (t.handleKey(press)) return
//         if (press.is(keys.enter) && t.canEdit) openForm(t.cursor.index, t.current)
//         else if (press.is(keys.addNonbio) && t.canAdd) openForm(undefined, blank)
//     })
//     return (
//         <Frame title="..." note={t.frameNote} noteIsError={t.frameNoteIsError}
//             legend={[...]}>
//             <DataTable columns={...} rows={t.rows} cursor={t.cursor.index}
//                 offset={t.cursor.offset} pageSize={t.pageSize} mark={t.mark}
//                 width={t.width} />
//         </Frame>
//     )
//
// A form page that makes or changes an item hands it back through `t.replaceAt(i, item)`
// or `t.append(item)`; both only change the draft, nothing is saved before `^w`.

import { useCallback, useEffect, useState } from "react"
import { Drafts, type Row, rowMark } from "../store/draft.js"
import { type KeyInput, keys } from "../ui/keys.js"
import { useBodyColumns, useBodyRows } from "../ui/layout.js"
import { useNav } from "../ui/nav.js"
import { useDiscardGuard } from "../ui/use-confirm.js"
import { type ListCursor, useListCursor } from "../ui/use-list-cursor.js"

/**
 * The rows a `DataTable` takes besides the rows themselves: its header, its rule and
 * its `n / total` counter.
 */
export const TABLE_CHROME_ROWS = 3

/**
 * What a table screen is set up with.
 *
 * @typeParam V - the item of a row.
 * @property items - what the file has now, read once when the screen opens.
 * @property save - writes the items the file is to have (`Drafts.toSave`); it throws if
 *     it cannot (the note is then `could not save!`).
 * @property check - the first row that cannot be saved, as `[row index, message]`;
 *     `undefined` when all can. It is asked at `^w` before anything is written.
 * @property extraRows - rows the screen uses besides the frame and the table, taken off
 *     the page size (a status line); 0 when left out.
 * @property locked - set when the file cannot be used: the table is empty, shows this
 *     as its note, and every key that changes something refuses (the file is never
 *     written over).
 */
export type TableScreenOptions<V> = {
    items:      readonly V[]
    save:       (items: V[]) => void
    check:      (drafts: Drafts<V>) => [number, string] | undefined
    extraRows?: number
    locked?:    string
}

/**
 * What a table screen gets back.
 *
 * @typeParam V - the item of a row.
 * @property drafts - the rows with their drafts and marks.
 * @property rows - the same rows as an array, for `DataTable`; its cells come from
 *     `rowValue(row)`.
 * @property cursor - the list cursor over the rows.
 * @property pageSize - the rows of the table that fit.
 * @property width - the width of the body, for `DataTable`.
 * @property current - the item under the cursor as it stands now (`undefined` for none).
 * @property canEdit - Enter may open the row: there is one, it is not marked to go, the
 *     file is not locked.
 * @property canAdd - an add key may add a row: there is room (999) and no lock.
 * @property locked - the file cannot be used.
 * @property frameNote - the line for `Frame`: the discard question, else the note.
 * @property frameNoteIsError - draw `frameNote` in the error colour.
 * @property setNote - puts a note up (cleared by the next key); the screen uses it for
 *     what only it knows.
 * @property mark - the mark column of `DataTable`: `*`, `-` or a space.
 * @property replaceAt - makes an item the draft of a row.
 * @property append - adds an item as a new row at the end and puts the cursor on it.
 * @property handleKey - routes a key press; returns `true` when it was handled, so the
 *     screen stops there.
 */
export type TableScreen<V> = {
    drafts:           Drafts<V>
    rows:             Row<V>[]
    cursor:           ListCursor
    pageSize:         number
    width:            number
    current:          V | undefined
    canEdit:          boolean
    canAdd:           boolean
    locked:           boolean
    frameNote:        string | undefined
    frameNoteIsError: boolean
    setNote:          (text: string | undefined, isError?: boolean) => void
    mark:             (row: Row<V>) => string
    replaceAt:        (i: number, item: V) => void
    append:           (item: V) => void
    handleKey:        (press: KeyInput) => boolean
}

/**
 * The state and keys of a table of editable rows.
 *
 * Keys handled (`handleKey` returns `true`): up and down move the cursor; `^r` marks the
 * row under it to be removed (a row never saved goes at once); `^u` undoes its last
 * change; `^w` checks every row (`check`: the problem is the note, `row N: ...`, and the
 * cursor goes there) and else saves, the note `saved` or `could not save!`; `^x` leaves
 * through `nav.pop` and Esc through `nav.quit`, each asking `discard N changes?` first
 * when something is unsaved; while that question is up it takes every key. Any other key
 * clears the note and returns `false`, and the screen handles it (Enter, the adds).
 *
 * @typeParam V - the item of a row.
 * @param options - see [[TableScreenOptions]].
 * @returns the state to draw and the key router, see [[TableScreen]].
 */
export function useTableScreen<V>(options: TableScreenOptions<V>): TableScreen<V> {
    const { items, save, check, extraRows = 0, locked } = options
    const nav = useNav()
    const [drafts, setDrafts] = useState<Drafts<V>>(() => Drafts.of(items))
    const [note, setNoteState] = useState<{ text: string; isError: boolean } | undefined>(
        locked ? { text: locked, isError: true } : undefined,
    )
    const [focusLast, setFocusLast] = useState(false)
    const pageSize = useBodyRows(TABLE_CHROME_ROWS + extraRows)
    const width = useBodyColumns()
    const cursor = useListCursor(drafts.length, pageSize)
    const guard = useDiscardGuard(drafts.count)

    // a row added to the end is under the cursor once the render that has it is done
    useEffect(() => {
        if (!focusLast) return
        cursor.set(drafts.length - 1)
        setFocusLast(false)
    }, [focusLast, cursor.set, drafts.length])

    const setNote = useCallback((text: string | undefined, isError = true) => {
        setNoteState(text === undefined ? undefined : { text, isError })
    }, [])
    const replaceAt = useCallback((i: number, item: V) => {
        setDrafts((d) => d.set(i, item))
    }, [])
    const append = useCallback((item: V) => {
        setDrafts((d) => d.add(item))
        setFocusLast(true)
    }, [])

    /** `^w`: tell the first problem, else write the file and stand at what was saved. */
    const saveAll = () => {
        const found = check(drafts)
        if (found) {
            setNote(`row ${found[0] + 1}: ${found[1]}`)
            return cursor.set(found[0])
        }
        try {
            save(drafts.toSave())
        } catch {
            return setNote("could not save!")
        }
        setDrafts(drafts.commit())
        setNote("saved", false)
    }

    const handleKey = (press: KeyInput): boolean => {
        if (guard.handleKey(press)) return true
        setNote(undefined)
        if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) guard.leave(nav.pop)
        else if (press.is(keys.escape)) guard.leave(nav.quit)
        else if (press.is(keys.remove) || press.is(keys.undo) || press.is(keys.save)) {
            if (locked) setNote(locked)
            else if (press.is(keys.save)) saveAll()
            else if (drafts.length > 0) {
                const i = cursor.index
                setDrafts(press.is(keys.remove) ? drafts.remove(i) : drafts.undo(i))
            }
        } else return false
        return true
    }

    const current = drafts.value(cursor.index)
    const removed = drafts.rows[cursor.index]?.removed ?? false
    return {
        drafts,
        rows: [...drafts.rows],
        cursor,
        pageSize,
        width,
        current,
        canEdit: current !== undefined && !removed && !locked,
        canAdd: drafts.hasRoom && !locked,
        locked: locked !== undefined,
        frameNote: guard.question ?? note?.text,
        frameNoteIsError: guard.question === undefined && (note?.isError ?? false),
        setNote,
        mark: (row) => rowMark(row) ?? " ",
        replaceAt,
        append,
        handleKey,
    }
}
