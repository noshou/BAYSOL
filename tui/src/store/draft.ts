// SPDX-License-Identifier: LGPL-3.0-or-later

// The rows of a table being edited, with what has not been saved: the state the tables
// of the solutes, of the custom solutes and of the recipes share, whatever a row holds.
// A row is `{ saved, draft, removed }`:
//
//   saved    what the file has (`undefined` for a row added since the last save)
//   draft    what the row was edited to (`undefined` when it stands at what was saved)
//   removed  the row is to go at the next save (shown with `-`); until then `undo`
//            brings it back
//
// A row shows `*` while it is new or has a draft, `-` while it is to be removed.
// `Drafts` is immutable: every change returns a new `Drafts`, which suits a screen that
// keeps its state in a React hook.

import { isDeepStrictEqual } from "node:util"

// Re-exported: the screens know the cap by this path.
export { MAX_ROWS } from "./limits.js"

import { MAX_ROWS } from "./limits.js"

/** The mark of a row: `-` to be removed, `*` new or edited. */
export type Mark = "-" | "*"

/** One row of a table. */
export interface Row<V> {
    readonly saved: V | undefined
    readonly draft: V | undefined
    readonly removed: boolean
}

/**
 * The item of a row as it stands now.
 *
 * @param row - a row.
 * @returns its draft, else what was saved.
 */
export function rowValue<V>(row: Row<V>): V | undefined {
    return row.draft ?? row.saved
}

/**
 * The mark of a row.
 *
 * @param row - a row.
 * @returns `"-"` if it is to be removed, `"*"` if it is new or edited, else `undefined`.
 */
export function rowMark<V>(row: Row<V>): Mark | undefined {
    if (row.removed) return "-"
    if (row.saved === undefined || row.draft !== undefined) return "*"
    return undefined
}

/** The rows of a table being edited, and the changes not yet saved. */
export class Drafts<V> {
    /** The rows, in table order. */
    readonly rows: readonly Row<V>[]

    /**
     * @param rows - the rows; use `Drafts.of` to start from the saved items.
     */
    constructor(rows: readonly Row<V>[] = []) {
        this.rows = rows
    }

    /**
     * The state of the saved items, nothing edited.
     *
     * @param items - what the file has.
     * @returns a clean state.
     */
    static of<V>(items: readonly V[]): Drafts<V> {
        const rows = items.map((saved) => ({ saved, draft: undefined, removed: false }))
        return new Drafts(rows)
    }

    /** How many rows there are. */
    get length(): number {
        return this.rows.length
    }

    /**
     * The item of row `i` as it stands now.
     *
     * @param i - the row.
     * @returns the item, or `undefined` for a row that is not there.
     */
    value(i: number): V | undefined {
        const row = this.rows[i]
        return row && rowValue(row)
    }

    /**
     * The mark of row `i`.
     *
     * @param i - the row.
     * @returns `"-"`, `"*"` or `undefined`.
     */
    mark(i: number): Mark | undefined {
        const row = this.rows[i]
        return row && rowMark(row)
    }

    /** Whether anything is not saved. */
    get dirty(): boolean {
        return this.rows.some((row) => rowMark(row) !== undefined)
    }

    /** How many rows are not saved: new, edited or marked to be removed. */
    get count(): number {
        return this.rows.filter((row) => rowMark(row) !== undefined).length
    }

    /** Whether there is room for another row (fewer than `MAX_ROWS`). */
    get hasRoom(): boolean {
        return this.rows.length < MAX_ROWS
    }

    /**
     * The state without row `i`.
     *
     * @param i - the row.
     * @returns the new state.
     * @throws RangeError for a row that is not there.
     */
    drop(i: number): Drafts<V> {
        this.check(i)
        return new Drafts(this.rows.filter((_, j) => j !== i))
    }

    /**
     * The state without the rows of `indices` that were never saved (the cancelled rows
     * of an add); a row that was saved is left alone.
     *
     * @param indices - the rows to drop when new.
     * @returns the new state.
     */
    dropNew(indices: Iterable<number>): Drafts<V> {
        const gone = new Set([...indices].filter((i) => this.rows[i]?.saved === undefined))
        return new Drafts(this.rows.filter((_, i) => !gone.has(i)))
    }

    /**
     * The state with new rows, each a draft of an item, at the end.
     *
     * @param items - the items.
     * @returns the new state.
     */
    add(...items: V[]): Drafts<V> {
        const added = items.map((draft) => ({ saved: undefined, draft, removed: false }))
        return new Drafts([...this.rows, ...added])
    }

    /**
     * The state with the item of row `i` set as a whole. A row set back to what was
     * saved has no draft.
     *
     * @param i - the row.
     * @param item - the new item.
     * @returns the new state.
     * @throws RangeError for a row that is not there.
     */
    set(i: number, item: V): Drafts<V> {
        const row = this.check(i)
        const same = isDeepStrictEqual(item, row.saved)
        return this.replace(i, { ...row, draft: same ? undefined : item })
    }

    /**
     * The state with row `i` marked to be removed at the next save; a row that was never
     * saved has nothing to confirm and goes at once.
     *
     * @param i - the row.
     * @returns the new state.
     * @throws RangeError for a row that is not there.
     */
    remove(i: number): Drafts<V> {
        const row = this.check(i)
        if (row.saved === undefined) return this.drop(i)
        return this.replace(i, { ...row, removed: true })
    }

    /**
     * The state with the last change of row `i` undone: a removal first, then the draft;
     * a row that was never saved goes.
     *
     * @param i - the row.
     * @returns the new state.
     * @throws RangeError for a row that is not there.
     */
    undo(i: number): Drafts<V> {
        const row = this.check(i)
        if (row.removed) return this.replace(i, { ...row, removed: false })
        if (row.saved === undefined) return this.drop(i)
        return this.replace(i, { ...row, draft: undefined })
    }

    /**
     * The items the file gets at the next save: the rows not marked to go.
     *
     * @returns the items, in order.
     */
    toSave(): V[] {
        return this.rows.filter((row) => !row.removed).map((row) => rowValue(row) as V)
    }

    /**
     * The state after a save: the removed rows gone, every other row standing at what it
     * is.
     *
     * @returns a clean state.
     */
    commit(): Drafts<V> {
        return Drafts.of(this.toSave())
    }

    /** The row `i`, or a RangeError (the Clojure threw IndexOutOfBounds). */
    private check(i: number): Row<V> {
        const row = this.rows[i]
        if (!row) throw new RangeError(`no row ${i}`)
        return row
    }

    /** The state with row `i` replaced. */
    private replace(i: number, row: Row<V>): Drafts<V> {
        return new Drafts(this.rows.map((r, j) => (j === i ? row : r)))
    }
}
