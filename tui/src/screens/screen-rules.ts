// SPDX-License-Identifier: LGPL-3.0-or-later

// Screen rules: the logic of the table screens and the settings editors, without JSX.
//
// Contents:
//   1. Table and form legends: `tableLegend`, `formLegend`
//   2. The table screen: cursor, rows, marks and saving
//   3. Setting edit: the rules of the settings editors
//   4. Landing words: the options and questions of the recipes and the landings

import { useCallback, useEffect, useRef, useState } from "react"
import { saveErrorNote } from "../core/file-system.js"
import { type NumberRules, parseNumber, truncate } from "../core/terminal.js"
import {
    colourWords,
    listedName,
    looksLikeCode,
    parseColourCode,
    splitTopLevel,
} from "../store/colours.js"
import { Drafts, MAX_ROWS, type Row, rowMark } from "../store/lists.js"
import {
    type PartKind,
    type SettingDef,
    type SettingValue,
    validateValue,
} from "../store/settings.js"
import { sameValue } from "../store/settings-store.js"
import { footerExtraLines } from "../ui/frame.js"
import {
    entryLegend,
    type LegendItem,
    legendBack,
    legendFor,
    legendOf,
    type Moves,
    moveLegend,
} from "../ui/grid.js"
import {
    destructiveQuestion,
    type Question,
    questionLegend,
    useConfirm,
    useDiscardGuard,
} from "../ui/input.js"
import {
    type KeyInput,
    keys,
    type ListCursor,
    useBodyColumns,
    useBodyRows,
    useListCursor,
    useNav,
} from "../ui/interaction.js"
import { FIND_ROWS, type TableFind, useTableFind } from "./table-find.js"

// ========================================================================================
// 1. Tables and forms
// ========================================================================================

// The key legends of the screens, as pure functions of what the screen is doing right
// now: a legend lists ONLY the keys that work at this moment (like the move hint of the
// menus), so a key that would do nothing is not shown. Two shapes cover the screens:
//
//   - `tableLegend`: a table of editable rows (the solutes, the custom solutes), from
//     where the cursor is and what the rows allow;
//   - `formLegend`: a form page, from where the cursor is and what the form allows.
//
// A prompt or dropdown that is open gives its own legend (`entryLegend` in
// `ui/legend.tsx`, reported by `Entry`'s `onLegend`), a question its answers
// (`questionLegend` in `ui/input.tsx`). The screens only gather the facts
// (`TableFacts`, ...) and call these, so the rules are in one place and tested without a
// terminal.

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
 * @param more - items that go last: the find and sort keys of a table of named rows.
 * @returns the items, in order.
 */
export function tableLegend(
    facts: TableFacts,
    adds: LegendItem[],
    editLabel = "edit",
    more: LegendItem[] = [],
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
        ...more,
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

// ========================================================================================
// 2. The table screen: cursor, rows, marks and saving
// ========================================================================================

// The mechanics every table of editable rows shares (the custom solutes, the solutes of
// a buffer): the rows being edited (`Drafts`), the cursor, the note, the
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

/**
 * The rows a `DataTable` takes besides the rows themselves: its header, its rule and
 * its `n / total` counter.
 */
const TABLE_CHROME_ROWS = 3

/** The lines of keys `useBodyRows` already allows for (`frameRows` in ui/layout.ts). */
const FRAME_LEGEND_LINES = 3

/**
 * What a table screen is set up with.
 *
 * @typeParam V - the item of a row.
 * @property items - what the file has now, read once when the screen opens.
 * @property added - items the table starts with as new, unsaved rows after `items` (a
 *     recipe loaded into the buffer): nothing of them is written before `^w`; the cursor
 *     stays at the top.
 * @property save - writes the items the file is to have (`Drafts.toSave`); it throws if
 *     it cannot (the note is then `could not save!`).
 * @property check - the first row that cannot be saved, as `[row index, message]`;
 *     `undefined` when all can. It is asked at `^w` before anything is written.
 * @property extraRows - rows the screen uses besides the frame and the table, taken off
 *     the page size (a status line); 0 when left out.
 * @property adds - every add key the screen can ever show in its legend (the same
 *     items it gives `legend`): with them the table works out its fullest legend
 *     ([[TableScreen.legendFull]]) so the screen's footer keeps one height and the body
 *     gives up the rows a taller one needs.
 * @property extraChanges - unsaved changes the screen keeps outside the rows (the pH of a
 *     buffer): added to the count that `^x` asks about and that makes `^w` offered; 0
 *     when left out.
 * @property locked - set when the file cannot be used: the table is empty, shows this
 *     as its note, and every key that changes something refuses (the file is never
 *     written over).
 * @property erase - set by a table of things the user made and keeps (custom solutes):
 *     `^r` on a row that exists in the file asks `destructiveQuestion(what name)`
 *     (`name` is the saved item's name, `what` e.g. `solute`) and Enter calls `remove`,
 *     which deletes just that entry from disk at once (it throws if it cannot: the note
 *     is then `saveErrorNote`); the row leaves the table and every other row keeps its
 *     drafts, still unsaved. A row never saved is dropped without a question. Left out,
 *     `^r` only marks the row (and `^w` removes it: a buffer's solutes).
 * @property label - the name of an item. With it the table finds a row by name (`/`) and
 *     puts the rows in alphabetical order (`s`); both show in the legend only while they
 *     can do something.
 * @property sorted - the rows are put in alphabetical order when the table opens (the
 *     recipes, the custom solutes); needs `label`.
 */
export type TableScreenOptions<V> = {
    items:      readonly V[]
    added?:     readonly V[]
    save:       (items: V[]) => void
    check:      (drafts: Drafts<V>) => [number, string] | undefined
    extraRows?: number
    adds?: LegendItem[]
    extraChanges?: number
    locked?:    string
    erase?:     {
        what:   string
        name:   (saved: V) => string
        remove: (saved: V) => void
    }
    label?:     (item: V) => string
    sorted?:    boolean
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
 * @property adopt - takes a whole new set of drafts (what an add flow ended with), the
 *     cursor on the last row when `focusLast`.
 * @property legendFull - the fullest legend of the table (every key working at once),
 *     for the frame to reserve the height of (`Frame`'s `legendFull`).
 * @property legend - the keys that work now, for `Frame`: the answers while a question
 *     (discard, delete) is open, else the table's own (`tableLegend`: the arrows from
 *     the cursor's row, edit, remove, undo, save only where they act). Takes the add
 *     keys of the screen and what Enter does (`"edit"`).
 * @property handleKey - routes a key press; returns `true` when it was handled, so the
 *     screen stops there.
 * @property finder - the open finder to draw under the table, `null` while closed (a
 *     table with `label`); the table's page is shorter while it is open.
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
    adopt:            (drafts: Drafts<V>, focusLast: boolean) => void
    legendFull:       LegendItem[]
    legend:           (adds: LegendItem[], editLabel?: string) => LegendItem[]
    handleKey:        (press: KeyInput) => boolean
    finder:           TableFind["element"]
}

/**
 * The state and keys of a table of editable rows.
 *
 * Keys handled (`handleKey` returns `true`): up and down move the cursor; `^r` marks the
 * row under it to be removed (a row never saved goes at once); `^u` undoes its last
 * change; `^w` checks every row (`check`: the problem is the note, `row N: ...`, and the
 * cursor goes there) and else saves, the note `saved` or `could not save!`; `^x` leaves
 * through `nav.pop`, asking `discard N changes?` first when something is unsaved (Esc does
 * nothing); while that question is up it takes every key. Any other key
 * clears the note and returns `false`, and the screen handles it (Enter, the adds).
 * With `erase`, `^r` on a saved row asks and deletes that entry at once, see
 * [[TableScreenOptions]]; the question takes every key until answered.
 *
 * @typeParam V - the item of a row.
 * @param options - see [[TableScreenOptions]].
 * @returns the state to draw and the key router, see [[TableScreen]].
 */
export function useTableScreen<V>(options: TableScreenOptions<V>): TableScreen<V> {
    const { items, save, check, extraRows = 0, extraChanges = 0, locked, erase } = options
    const { added = [], label, sorted } = options
    const findKeys = label
        ? [legendFor("find", keys.find), legendFor("sort", keys.sort)]
        : []
    const width = useBodyColumns()
    // the fullest legend: both arrows, every key that acts on a row, and the adds
    const legendFull = tableLegend(
        {
            rows: 2,
            cursor: 1,
            canEdit: true,
            canAdd: true,
            locked: false,
            canRemove: true,
            canUndo: true,
            removeLabel: erase ? "delete" : undefined,
            dirty: true,
        },
        [...(options.adds ?? []), ...findKeys],
    )
    // rows the footer takes beyond the three lines the frame's own count allows for (the
    // table screens are blocky: their footer's box takes two more)
    const footerExtra = footerExtraLines(legendFull, width, FRAME_LEGEND_LINES, "blocky")
    const nav = useNav()
    const [drafts, setDrafts] = useState<Drafts<V>>(() => {
        const start = Drafts.of(items)
        const first = label && sorted ? start.sorted(label) : start
        return added.reduce((d, item) => d.add(item), first)
    })
    const [note, setNoteState] = useState<{ text: string; isError: boolean } | undefined>(
        locked ? { text: locked, isError: true } : undefined,
    )
    const [focusLast, setFocusLast] = useState(false)
    const bodyRows = useBodyRows(TABLE_CHROME_ROWS + extraRows + footerExtra)
    // the finder (`/`) takes rows under the table while it is open; it moves the cursor
    // through a ref, because the cursor is made from the page size that depends on it
    const goRef = useRef<(i: number) => void>(() => undefined)
    const goTo = useCallback((i: number) => goRef.current(i), [])
    const find = useTableFind(drafts.rows, label, goTo)
    const pageSize = find.open ? Math.max(3, bodyRows - FIND_ROWS) : bodyRows
    const cursor = useListCursor(drafts.length, pageSize)
    goRef.current = cursor.set
    const guard = useDiscardGuard(drafts.count + extraChanges)
    const removal = useConfirm()

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

    /** Writes the file and stands at what was saved. */
    const adopt = useCallback((next: Drafts<V>, focusEnd: boolean) => {
        setDrafts(next)
        if (focusEnd) setFocusLast(true)
    }, [])

    const write = () => {
        try {
            save(drafts.toSave())
        } catch (error) {
            return setNote(saveErrorNote(error))
        }
        setDrafts(drafts.commit())
        setNote("saved", false)
    }

    /** `^w`: tell the first problem, else write the file. */
    const saveAll = () => {
        const found = check(drafts)
        if (found) {
            setNote(`row ${found[0] + 1}: ${found[1]}`)
            return cursor.set(found[0])
        }
        write()
    }

    /**
     * `^r` on row `i` of a table that erases (`erase`): a saved row asks, and Enter
     * deletes that one entry from the file now and drops the row.
     */
    const eraseRow = (i: number, saved: V, how: NonNullable<typeof erase>) => {
        removal.ask(destructiveQuestion(`${how.what} ${how.name(saved)}`), () => {
            try {
                how.remove(saved)
            } catch (error) {
                return setNote(saveErrorNote(error))
            }
            setDrafts((d) => d.drop(i))
            setNote("deleted", false)
        })
    }

    /** `s`: the rows in alphabetical order, the cursor staying on its row. */
    const sortRows = (by: (item: V) => string) => {
        const row = drafts.rows[cursor.index]
        const next = drafts.sorted(by)
        setDrafts(next)
        if (row) cursor.set(next.rows.indexOf(row))
    }

    const handleKey = (press: KeyInput): boolean => {
        if (guard.handleKey(press) || removal.handleKey(press)) return true
        // an open finder takes every key itself
        if (find.open) return true
        setNote(undefined)
        if (label && drafts.length > 1 && press.is(keys.find)) find.start()
        else if (label && drafts.length > 1 && press.is(keys.sort)) sortRows(label)
        else if (press.is(keys.up)) cursor.move(-1)
        else if (press.is(keys.down)) cursor.move(1)
        else if (press.is(keys.back)) guard.leave(nav.pop)
        else if (press.is(keys.remove) || press.is(keys.undo) || press.is(keys.save)) {
            if (locked) setNote(locked)
            else if (press.is(keys.save)) saveAll()
            else if (drafts.length > 0) {
                const i = cursor.index
                const saved = drafts.rows[i]?.saved
                if (press.is(keys.remove) && erase && saved !== undefined)
                    eraseRow(i, saved, erase)
                else setDrafts(press.is(keys.remove) ? drafts.remove(i) : drafts.undo(i))
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
        frameNote: guard.note ?? removal.note ?? note?.text,
        frameNoteIsError:
            guard.question === undefined &&
            removal.question === undefined &&
            (note?.isError ?? false),
        setNote,
        legendFull,
        legend: (adds, editLabel) => {
            const asked = guard.question ?? removal.question
            if (asked !== undefined) return questionLegend(asked)
            if (find.open) return find.legend
            const row = drafts.rows[cursor.index]
            const several = label !== undefined && drafts.length > 1
            const more = legendOf([
                several && legendFor("find", keys.find),
                several && !drafts.isSorted(label) && legendFor("sort", keys.sort),
            ])
            return tableLegend(
                {
                    rows: drafts.length,
                    cursor: cursor.index,
                    canEdit: current !== undefined && !removed && !locked,
                    canAdd: drafts.hasRoom && !locked,
                    locked: locked !== undefined,
                    canRemove: row !== undefined && !removed,
                    removeLabel: erase ? "delete" : undefined,
                    canUndo: row !== undefined && rowMark(row) !== undefined,
                    dirty: drafts.dirty || extraChanges > 0,
                },
                [...adds],
                editLabel,
                more,
            )
        },
        mark: (row) => rowMark(row) ?? " ",
        replaceAt,
        append,
        adopt,
        handleKey,
        finder: find.element,
    }
}

// ========================================================================================
// 3. Settings: typed text to a value, and how a value shows
// ========================================================================================

/** How an edit ended: with a value, abandoned, or by Ctrl-X (leave the whole sheet). */
export type EditEnd<V> = { kind: "done"; value: V } | { kind: "cancel" } | { kind: "back" }

/** The longest text typed into a setting (a tuple is one line). */
export const maxSettingText = 60

/** The most digits of a whole number taken: what a 64 bit number says exactly. */
const maxIntDigits = 15

/** What a number setting accepts as text, for `parseNumber` (not its limits). */
export const numberRules: Record<"int" | "float", NumberRules> = {
    int: {
        whole:         true,
        signed:        true,
        maxDigits:     maxIntDigits,
        digitsMessage: `${maxIntDigits} digits at most`,
    },
    float: {},
}

/** One part of a tuple as typed: a number, or a colour (a name or a code, as typed). */
export function parsePart(
    kind: PartKind,
    text: string,
): { value: number | string } | { error: string } {
    if (kind !== "colour") return parseNumber(text, numberRules[kind])
    return { value: text.trim() }
}

/** The words that stand for "not given" in an optional number: blank, these. */
const nullWords = ["auto", "none"]

/** What an optional number shows when it is not given: `auto` (whole), `none` (float). */
const nullWord = (def: SettingDef): string =>
    def.kind === "optional_int" ? "auto" : "none"

/** A hyphen that is a minus (`lo-hi`), not the sign of an exponent (`1e-3`). */
const rangeHyphen = /(?<![eE])-/

/** The `lo-hi` pairs of a text such as `0.1-0.2, 0.5-0.6` (blank or `none`: no range). */
function parseRanges(text: string): { value: number[][] } | { error: string } {
    const t = text.trim()
    if (t === "" || t.toLowerCase() === "none") return { value: [] }
    const pairs: number[][] = []
    for (const piece of t.split(",")) {
        const ends = piece.split(rangeHyphen)
        if (ends.length !== 2) return { error: "ranges are lo-hi, with commas" }
        const nums: number[] = []
        for (const end of ends) {
            const n = parseNumber(end)
            if ("error" in n) return { error: `${piece.trim()}: ${n.error}` }
            nums.push(n.value)
        }
        pairs.push(nums)
    }
    return { value: pairs }
}

/** The words of a list typed with commas or blanks between them. */
const listWords = (text: string): string[] =>
    text.split(/[\s,]+/).filter((w) => w !== "")

/** One size as typed: `76x5` (also `76 x 5`, `76×5`); the `x` is joined to its numbers. */
const sizeText = /^(\d+)x(\d+)$/

/** The `WIDTHxHEIGHT` sizes of a text such as `76x5, 100x9`. */
function parseSizes(text: string): { value: number[][] } | { error: string } {
    const sizes: number[][] = []
    for (const word of listWords(text.replace(/\s*[x×]\s*/gi, "x"))) {
        const m = sizeText.exec(word)
        if (m === null) return { error: "a size is WIDTHxHEIGHT: 76x5" }
        sizes.push([Number(m[1]), Number(m[2])])
    }
    return { value: sizes }
}

/** A tuple value from its parts: an array, or an object keyed by the names of the parts. */
export function tupleOf(def: SettingDef, parts: (number | string)[]): SettingValue {
    return def.isRecord
        ? Object.fromEntries(def.partNames.map((n, i) => [n, parts[i] as number]))
        : parts
}

/** Whether a setting is a tuple with a colour part (`colour, opacity`). */
export const hasColourPart = (def: SettingDef): boolean =>
    def.kind === "tuple" && def.partKinds.includes("colour")

/**
 * The tuple the parts make, checked as a whole (what `parseSetting` does at the end of a
 * typed line).
 *
 * @param def - the tuple setting.
 * @param parts - one value for each part, in order.
 * @returns the value `validateValue` accepts, or what is wrong.
 */
export function finishTuple(
    def: SettingDef,
    parts: (number | string)[],
): { value: SettingValue } | { error: string } {
    const checked = validateValue(def, tupleOf(def, parts))
    return checked.ok ? { value: checked.value } : { error: checked.error }
}

/**
 * What typed text means for a setting that is typed (a number, an optional number, a
 * `set` of blank-separated choices, a font, a tuple as comma-separated parts, ranges as
 * `lo-hi, lo-hi`, chains as letters, colours and markers as words with commas or blanks
 * between them, sizes as `76x5, 100x9`): the value `validateValue` accepts, or what is
 * wrong. An empty font is the default font.
 */
export function parseSetting(
    def: SettingDef,
    text: string,
): { value: SettingValue } | { error: string } {
    let raw: unknown
    if (def.kind === "ranges") {
        const ranges = parseRanges(text)
        if ("error" in ranges) return ranges
        raw = ranges.value
    } else if (def.kind === "strings") {
        const t = text.trim()
        raw = /^(all)?$/i.test(t) ? [] : [...t.replace(/[\s,]+/g, "")]
    } else if (def.kind === "colours") {
        raw = colourWords(text)
    } else if (def.kind === "markers") raw = listWords(text)
    else if (def.kind === "sizes") {
        const sizes = parseSizes(text)
        if ("error" in sizes) return sizes
        raw = sizes.value
    } else if (def.kind === "set") raw = text.split(/\s+/).filter((w) => w !== "")
    else if (def.kind === "font") raw = text.trim() === "" ? def.default : text.trim()
    else if (def.kind === "path") raw = text.trim()
    else if (def.kind === "tuple") {
        const words = splitTopLevel(text)
        if (words.length !== def.partNames.length)
            return {
                error: `needs ${def.partNames.length} values: ${def.partNames.join(", ")}`,
            }
        const parts: (number | string)[] = []
        for (const [i, word] of words.entries()) {
            const part = parsePart(def.partKinds[i] as PartKind, word)
            if ("error" in part) return { error: `${def.partNames[i]}: ${part.error}` }
            parts.push(part.value)
        }
        raw = tupleOf(def, parts)
    } else if (
        def.kind.startsWith("optional") &&
        (text.trim() === "" || nullWords.includes(text.trim().toLowerCase()))
    ) {
        raw = null
    } else {
        const whole = def.kind === "int" || def.kind === "optional_int"
        const parsed = parseNumber(text, numberRules[whole ? "int" : "float"])
        if ("error" in parsed) return parsed
        raw = parsed.value
    }
    const checked = validateValue(def, raw)
    return checked.ok ? { value: checked.value } : { error: checked.error }
}

// --- colours and fonts: a name picked from a list

/** The longest name typed to narrow a list of colours or fonts. */
export const maxNameText = 40

/**
 * The names a typed text narrows a list to: all of them for no text, else those that
 * start with it, and if none does, those that have it inside (case does not matter).
 *
 * @param names - the whole list.
 * @param typed - the text.
 * @returns the names that match, in the order of the list.
 */
export function narrow(names: readonly string[], typed: string): string[] {
    const t = typed.trim().toLowerCase()
    if (t === "") return [...names]
    const prefix = names.filter((n) => n.toLowerCase().startsWith(t))
    return prefix.length > 0 ? prefix : names.filter((n) => n.toLowerCase().includes(t))
}

/**
 * Where a name is in a list.
 *
 * @param names - the list.
 * @param name - the name (case does not matter).
 * @returns its index, or 0 if it is not there.
 */
export function indexOfPick(names: readonly string[], name: string): number {
    const t = name.toLowerCase()
    const at = names.findIndex((n) => n.toLowerCase() === t)
    return Math.max(at, 0)
}

/** The kinds of setting picked from a list of names. */
export type ListKind = "colour" | "font"

/**
 * What Enter takes in a colour or font picker: a colour code typed out, else the
 * highlighted name, else (a machine with no list of fonts) the font text as it is.
 *
 * @param kind - what is picked.
 * @param names - every name there is (empty for fonts on a machine with no list).
 * @param typed - the text in the field.
 * @param highlighted - the name highlighted in the narrowed list, if any.
 * @returns the value, or what is wrong.
 */
export function pickValue(
    kind: ListKind,
    names: readonly string[],
    typed: string,
    highlighted: string | undefined,
): { value: string } | { error: string } {
    const text = typed.trim()
    if (kind === "colour" && parseColourCode(text) !== undefined) return { value: text }
    if (kind === "colour" && looksLikeCode(text)) return { error: "not a colour code" }
    if (highlighted !== undefined) return { value: highlighted }
    if (kind === "colour" && listedName(text) !== undefined) return { value: text }
    if (kind === "font" && names.length === 0 && text !== "") return { value: text }
    return { error: kind === "colour" ? "not a known colour" : "not a known font" }
}

// --- what a sheet shows

/** The words the value cell uses for the two values of a yes/no setting. */
const yesNo = { true: "yes", false: "no" } as const

/**
 * The parts of a tuple value in order.
 *
 * @param def - the tuple setting.
 * @param value - its value (an array, or an object keyed by the names of the parts).
 * @returns the parts.
 */
export function tupleParts(def: SettingDef, value: SettingValue): (number | string)[] {
    return def.isRecord
        ? def.partNames.map((n) => (value as Record<string, number>)[n] as number)
        : [...(value as (number | string)[])]
}

/**
 * A value as a sheet shows it, and as it is typed again to edit it: yes or no, the
 * choices that are on (`pdf png`), a tuple as its parts (`gray40, 0.6`), anything else
 * as it is.
 *
 * @param def - the setting.
 * @param value - its value.
 * @returns the text, uncut: the caller fits it to its cell.
 */
export function valueText(def: SettingDef, value: SettingValue): string {
    if (typeof value === "boolean") return yesNo[`${value}`]
    if (value === null) return nullWord(def)
    if (def.kind === "ranges")
        return (value as number[][]).length === 0
            ? "none"
            : (value as number[][]).map(([lo, hi]) => `${lo}-${hi}`).join(", ")
    if (def.kind === "strings")
        return (value as string[]).length === 0 ? "all" : (value as string[]).join(", ")
    if (def.kind === "set") return (value as string[]).join(" ")
    if (def.kind === "colours" || def.kind === "markers")
        return (value as string[]).join(", ")
    if (def.kind === "sizes")
        return (value as number[][]).map(([w, h]) => `${w}x${h}`).join(", ")
    if (def.kind === "tuple") return tupleParts(def, value).join(", ")
    if (def.kind === "path" && value === "") return "(default)"
    return String(value)
}

/**
 * The colour a value shows a swatch of: a colour setting's own colour, or the colour
 * part of a tuple that begins with one.
 *
 * @param def - the setting.
 * @param value - its value.
 * @returns the colour's name or `#rrggbb`, or `undefined` if the setting has none.
 */
export function swatchColour(def: SettingDef, value: SettingValue): string | undefined {
    if (def.kind === "colour") return value as string
    if (def.kind === "tuple" && def.partKinds[0] === "colour")
        return tupleParts(def, value)[0] as string
    return undefined
}

/**
 * The drafts after a setting is given a value: no draft if it is the saved value.
 *
 * @param drafts - setting name to its unsaved value.
 * @param name - the setting.
 * @param saved - the saved value of the setting.
 * @param value - the new value.
 * @returns the new drafts.
 */
export function withDraft(
    drafts: ReadonlyMap<string, SettingValue>,
    name: string,
    saved: SettingValue,
    value: SettingValue,
): Map<string, SettingValue> {
    const next = new Map(drafts)
    if (sameValue(saved, value)) next.delete(name)
    else next.set(name, value)
    return next
}

/**
 * [[withDraft]] for a model's settings, where a draft is also the removal of an override
 * that equals the project's value: a value equal to the project's value is a change
 * while the model has an override of that setting, because saving it removes it.
 *
 * @param settings - the model's settings (its value now, whether it is overridden, the
 *     project's value).
 * @returns the new drafts.
 */
export function withModelDraft(
    drafts: ReadonlyMap<string, SettingValue>,
    name: string,
    settings: {
        get: (name: string) => SettingValue
        isSaved: (name: string) => boolean
        resetValue: (name: string) => SettingValue
    },
    value: SettingValue,
): Map<string, SettingValue> {
    const removes = settings.isSaved(name) && sameValue(value, settings.resetValue(name))
    if (removes) return new Map(drafts).set(name, value)
    return withDraft(drafts, name, settings.get(name), value)
}

// ========================================================================================
// 4. Landing words: the options and questions of the recipes and the landings
// ========================================================================================

/** The message when there is no recipe to load. */
export const NO_RECIPES = "no saved recipes!"

/** The message when a name prompt of the landing is left. */
export const NOT_SAVED = "not saved"

/** The message when there is no room for one more recipe. */
export const TOO_MANY_RECIPES = `${MAX_ROWS} recipes at most!`

/** The note of a recipe that was loaded over a buffer that has solutes. */
export const REPLACES_HINT = `replaces the buffer at ${keys.save.label}`

/** The note of a new, empty buffer over one that has solutes. */
export const NOTHING_REPLACED_HINT = `nothing is replaced until ${keys.save.label}`

/** The cells of a name that a question always keeps. */
const MIN_NAME = 8

/** A count with its noun: `1 solute`, `12 solutes`. */
export function plural(n: number, word: string): string {
    return `${n} ${word}${n === 1 ? "" : "s"}`
}

/** What the buffer landing can do besides opening the two tables. */
export type LandingId = "buffer" | "custom" | "load" | "new" | "save"

/** One option of the buffer landing. */
export type LandingOption = { id: LandingId; label: string }

/**
 * The options of the buffer landing, in order: the buffer, the custom solutes, `load a
 * recipe`, `new recipe` and, for a buffer that has solutes, `save current recipe
 * globally` (what does nothing is not offered).
 *
 * @param buffer - the solutes of the buffer, `"unusable"` for a file that cannot be used.
 * @param custom - the custom solutes, `"unusable"` likewise.
 * @returns the options.
 */
export function bufferLandingOptions(
    buffer: number | "unusable",
    custom: number | "unusable",
): LandingOption[] {
    const options: LandingOption[] = [
        {
            id: "buffer",
            label: `buffer (${buffer === "unusable" ? "?" : plural(buffer, "solute")})`,
        },
        { id: "custom", label: `custom solutes (${custom === "unusable" ? "?" : custom})` },
        { id: "load", label: "load a recipe" },
        { id: "new", label: "new recipe" },
    ]
    if (typeof buffer === "number" && buffer > 0)
        options.push({ id: "save", label: "save current recipe globally" })
    return options
}

/**
 * The line of a recipe in the dropdown of the recipes to load.
 *
 * @returns `SEC buffer (3)`.
 */
export function recipeChoice(name: string, solutes: number): string {
    return `${name} (${solutes})`
}

/**
 * A name cut to fit a note so that the whole stays in its room.
 *
 * @param name - the name.
 * @param room - the cells the whole note may take.
 * @param fixed - the cells the rest of the note takes.
 * @returns the name, with an ellipsis if it was cut; at least 8 cells are kept.
 */
export function fitName(name: string, room: number, fixed: number): string {
    return truncate(name, Math.max(MIN_NAME, room - fixed))
}

/** A question that asks to replace something, its name cut to fit the note. */
function replaceQuestion(lead: string, name: string, room: number): Question {
    const end = '"?'
    return {
        text: `${lead}${fitName(name, room, lead.length + end.length)}${end}`,
        yes: "replace",
        no: "keep",
    }
}

/**
 * The question asked at the first `^w` of a recipe loaded over a buffer.
 *
 * @param n - how many solutes the buffer has.
 * @param recipe - the recipe's name.
 * @param room - the cells the note line has.
 * @returns `replace 3 solutes with recipe "NAME"?`, answered by `replace` and `keep`.
 */
export function replaceBufferQuestion(n: number, recipe: string, room: number): Question {
    return replaceQuestion(`replace ${plural(n, "solute")} with recipe "`, recipe, room)
}

/**
 * The question asked when a recipe of the name typed exists.
 *
 * @returns `replace "NAME"?`, answered by `replace` and `keep`.
 */
export function replaceRecipeQuestion(name: string, room: number): Question {
    return replaceQuestion('replace "', name, room)
}

/**
 * The message of a saved recipe.
 *
 * @returns `saved as "NAME"`.
 */
export function savedAs(name: string, room: number): string {
    return `saved as "${fitName(name, room, 'saved as ""'.length)}"`
}

/** The message for a file that cannot be used: `recipes.json unusable!`. */
export function unusable(file: string): string {
    return `${file} unusable!`
}
