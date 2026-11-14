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
import {
    type NumberRules,
    parseNumber,
    truncate,
    truncateStart,
    wrapText,
} from "../core/terminal.js"
import {
    colourWords,
    listedName,
    looksLikeCode,
    parseColourCode,
    splitTopLevel,
} from "../store/colours.js"
import { Drafts, MAX_ROWS, type Row, rowMark } from "../store/lists.js"
import { type Note, notesProblem } from "../store/notes.js"
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
    type NoteLine,
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
import { TextBuffer } from "../ui/text-input.js"
import { FIND_ROWS, type TableFind, useTableFind } from "./table-find.js"

// ========================================================================================
// 1. Tables and forms
// ========================================================================================

// Legends as pure functions of what a screen is doing: each lists only the keys that work
// now. `tableLegend` serves tables of editable rows, `formLegend` form pages; an open
// prompt or question supplies its own (`entryLegend`, `questionLegend`).

/**
 * What a table's legend depends on: `rows`, `cursor` (meaningless for no rows), whether
 * Enter `canEdit`, an add key `canAdd`, `^r` `canRemove` and `^u` `canUndo`, the file is
 * `locked`, there are `dirty` changes; `removeLabel` names `^r` (`remove` marks, `delete`
 * erases the saved entry at once).
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
 * Legend of a table with nothing open over it: `back`, `save` if unsaved, `edit`, the
 * arrows, `remove`/`undo` where they act, the find and sort keys, then the add keys when
 * there is room.
 *
 * @param facts - what the table allows now.
 * @param adds - the add keys of this table (`add solute ^n`, ...); shown only when
 *     `facts.canAdd`.
 * @param editLabel - what Enter does on a row, `"edit"` when left out.
 * @param more - items after `remove`: the find and sort keys of a table of named rows.
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
        facts.canRemove &&
            !locked && legendFor(facts.removeLabel ?? "remove", keys.remove),
        facts.canUndo && !locked && legendFor("undo", keys.undo),
        ...more,
        ...(facts.canAdd ? adds : []),
    ])
}

/**
 * What a form legend depends on: a cell `editing`, which arrows `moves` the cursor,
 * `canRestore` (`^u` on a changed cell), `complete` (`^w` would accept), `acceptLabel`.
 */
export type FormFacts = {
    editing: boolean
    moves: Moves
    canRestore: boolean
    complete: boolean
    acceptLabel: string
}

/**
 * Legend of a form page: the prompt's keys while a cell is open, else `cancel`, `accept`
 * (complete forms only), `edit`, the arrows and `restore` (changed cells only).
 *
 * @param facts - what the form is doing.
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

// Shared mechanics of the tables of editable rows: drafts, cursor, note, unsaved-changes
// guard and the keys that do not depend on the row. A screen calls `useTableScreen`,
// draws a `DataTable` in a `Frame`, and handles its own keys (Enter, the adds) when
// `handleKey` returns false. A form hands an item back through `t.replaceAt(i, item)` or
// `t.append(item)`; nothing is saved before `^w`.

/**
 * The rows a `DataTable` takes besides the rows themselves: its header, its rule and
 * its `n / total` counter.
 */
const TABLE_CHROME_ROWS = 3

/** The lines of keys `useBodyRows` already allows for (`frameRows` in ui/layout.ts). */
const FRAME_LEGEND_LINES = 3

/**
 * What a table screen is set up with. `items` is the file's content, read once; `added`
 * are extra unsaved rows after it (the cursor stays at the top). `save` writes the items
 * (throws on failure: note `could not save!`); `check` gives the first unsavable row as
 * `[index, message]`, asked at `^w`. `extraRows` and `extraChanges` count rows and unsaved
 * changes kept outside the table (a status line, a buffer's pH). `adds` and `rowKeys`
 * list every key the legend can show, so the fullest legend (the footer height) is known.
 * `locked`: file unusable, table empty, every changing key refused. `erase`: `^r` on a
 * saved row asks `destructiveQuestion(what name)` and Enter calls `remove`, which deletes
 * that entry from disk at once (throws on failure: `saveErrorNote`); an unsaved row is
 * dropped without asking; left out, `^r` only marks the row and `^w` removes it.
 * `removeLabel` names a marking `^r`. `label` enables find (`/`) and sort (`z`) by name;
 * `sorted` sorts on open (needs `label`).
 *
 * @typeParam V - the item of a row.
 */
export type TableScreenOptions<V> = {
    items:      readonly V[]
    added?:     readonly V[]
    save:       (items: V[]) => void
    check:      (drafts: Drafts<V>) => [number, string] | undefined
    extraRows?: number
    adds?: LegendItem[]
    rowKeys?:   LegendItem[]
    extraChanges?: number
    locked?:    string
    removeLabel?: string
    erase?:     {
        what:   string
        name:   (saved: V) => string
        remove: (saved: V) => void
    }
    label?:     (item: V) => string
    sorted?:    boolean
}

/**
 * What a table screen gets back: `drafts`, `rows`, `cursor`, `pageSize` and `width` for
 * `DataTable`; `current` (the item under the cursor), `canEdit`, `canAdd` (room: 999 rows,
 * no lock), `locked`; `frameNote` (the discard question, else the note) and
 * `frameNoteIsError`; `setNote` (cleared by the next key), `mark` (`*`, `-` or a space),
 * `replaceAt`, `append` (cursor on it), `adopt` (a new set of drafts, e.g. after an add
 * flow); `legendFull` (reserves the footer height), `legend` (the answers while a
 * question is open, else `tableLegend`), `handleKey` (true when handled), `finder` (the
 * open finder under the table, else null).
 *
 * @typeParam V - the item of a row.
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
 * State and keys of a table of editable rows. `handleKey` returns true for: up/down; `^r`
 * marks a row for removal (an unsaved row goes at once); `^u` undoes; `^w` checks every
 * row (`row N: ...`, the cursor moves there) and else saves (`saved` / `could not save!`);
 * `^x` leaves through `nav.pop`, asking `discard N changes?` first (Esc does nothing);
 * while a question is open it takes every key. Other keys clear the note and return
 * false. With `erase`, `^r` on a saved row asks and deletes it at once.
 *
 * @typeParam V - the item of a row.
 * @param options - see [[TableScreenOptions]].
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
            removeLabel: erase ? "delete" : options.removeLabel,
            dirty: true,
        },
        [...(options.adds ?? []), ...(options.rowKeys ?? []), ...findKeys],
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
    const [note, setNoteState] = useState<NoteLine | undefined>(
        locked ? { text: locked, error: true } : undefined,
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
        setNoteState(text === undefined ? undefined : { text, error: isError })
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

    /** `z`: the rows in alphabetical order, the cursor staying on its row. */
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
            (note?.error ?? false),
        setNote,
        legendFull,
        legend: (adds, editLabel) => {
            const asked = guard.question ?? removal.question
            if (asked !== undefined) return questionLegend(asked)
            if (find.open) return find.legend
            const row = drafts.rows[cursor.index]
            const several = label !== undefined && drafts.length > 1
            const more = legendOf([
                ...(current !== undefined && !removed && !locked
                    ? (options.rowKeys ?? [])
                    : []),
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
                    removeLabel: erase ? "delete" : options.removeLabel,
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

/**
 * A set of choices being toggled (the `set` settings, shown as tabs): `options`,
 * `selected`, the `focus`ed tab and the last `error`.
 */
export type TabsEdit = {
    options: readonly string[]
    selected: ReadonlySet<string>
    focus: number
    error?: string
}

/** What Esc says when no choice is on: a set needs at least one. */
export const PICK_ONE_NOTE = "pick one or more"

/**
 * Opens a set of choices with the first tab in focus.
 *
 * @param choices - every choice of the setting.
 * @param current - the choices that are on.
 */
export function openTabs(choices: readonly string[], current: readonly string[]): TabsEdit {
    return { options: choices, selected: new Set(current), focus: 0 }
}

/**
 * One key on the tabs: arrows move, Tab cycles, Enter/Space toggle, Esc ends (one must be
 * on). Returns the next state and the end, if Esc or Ctrl-X ended it.
 *
 * @param edit - the state.
 * @param press - the key.
 */
export function stepTabs(
    edit: TabsEdit,
    press: KeyInput,
): { state: TabsEdit; end?: EditEnd<string[]> } {
    const n = edit.options.length
    const moved = (focus: number) => ({ state: { ...edit, focus, error: undefined } })
    if (press.is(keys.back)) return { state: edit, end: { kind: "back" } }
    if (press.is(keys.escape)) {
        if (edit.selected.size === 0) return { state: { ...edit, error: PICK_ONE_NOTE } }
        const value = edit.options.filter((o) => edit.selected.has(o))
        return { state: edit, end: { kind: "done", value } }
    }
    if (press.is(keys.enter) || press.is(keys.space)) {
        const option = edit.options[edit.focus] as string
        const selected = new Set(edit.selected)
        if (!selected.delete(option)) selected.add(option)
        return { state: { ...edit, selected, error: undefined } }
    }
    if (press.is(keys.right)) return moved(Math.min(n - 1, edit.focus + 1))
    if (press.is(keys.left)) return moved(Math.max(0, edit.focus - 1))
    if (press.is(keys.tab)) return moved((edit.focus + 1) % n)
    return { state: edit }
}

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
    def.kind === "optionalInt" ? "auto" : "none"

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
 * The tuple the parts make, checked as a whole: the value `validateValue` accepts, or the
 * error.
 *
 * @param def - the tuple setting.
 * @param parts - one value for each part, in order.
 */
export function finishTuple(
    def: SettingDef,
    parts: (number | string)[],
): { value: SettingValue } | { error: string } {
    const checked = validateValue(def, tupleOf(def, parts))
    return checked.ok ? { value: checked.value } : { error: checked.error }
}

// --- a number typed into the value cell of the sheet

/** The longest text typed into a number: what a cell can show beside its cursor. */
export const maxNumberText = 16

/** What the editor says when a character past [[maxNumberText]] is refused. */
export const CAP_NOTE = `${maxNumberText} characters at most`

/** The lines of a message under a value in the table (an error): two at most. */
const noteLinesMax = 2

/**
 * A message under a value, wrapped to the column in at most two lines.
 *
 * @param text - the message.
 * @param cells - the room.
 */
export function noteLines(text: string, cells: number): string[] {
    return wrapText(text, cells).slice(0, noteLinesMax)
}

/** The rows an inline error may take under the table row (reserved while editing). */
export const NUMBER_NOTE_ROWS = noteLinesMax

/**
 * An `int` or `float` being typed into its row: `def`, the `buffer`, the last `error`
 * (cleared by the next key).
 */
export type NumberEdit = { def: SettingDef; buffer: TextBuffer; error?: string }

/**
 * Opens a number for editing: its value as text, the cursor at the end.
 *
 * @param def - the setting (an `int` or a `float`).
 * @param current - its value now.
 */
export function openNumber(def: SettingDef, current: SettingValue): NumberEdit {
    const empty = new TextBuffer("", undefined, maxNumberText)
    return { def, buffer: empty.replace(String(current)) }
}

/** Whether a press typed only blanks: a number never has one. */
const isBlank = (press: KeyInput): boolean => press.typed && press.text.trim() === ""

/**
 * One key while a number is typed: editing keys change the text (past the cap it says so,
 * blanks are dropped), Enter takes a number within the setting's limits, Esc drops the
 * edit, Ctrl-X leaves the sheet. Returns the next state and the end, if the key ended it.
 *
 * @param edit - the state.
 * @param press - the key.
 */
export function stepNumber(
    edit: NumberEdit,
    press: KeyInput,
): { state: NumberEdit; end?: EditEnd<number> } {
    if (press.is(keys.escape)) return { state: edit, end: { kind: "cancel" } }
    if (press.is(keys.back)) return { state: edit, end: { kind: "back" } }
    if (press.is(keys.enter)) {
        const parsed = parseSetting(edit.def, edit.buffer.text)
        if ("error" in parsed) return { state: { ...edit, error: parsed.error } }
        return { state: edit, end: { kind: "done", value: parsed.value as number } }
    }
    if (isBlank(press)) return { state: edit }
    if (press.typed && edit.buffer.full) return { state: { ...edit, error: CAP_NOTE } }
    let buffer: TextBuffer
    if (press.typed) buffer = edit.buffer.insert(press.text)
    else if (press.is(keys.backspace)) buffer = edit.buffer.backspace()
    else if (press.is(keys.delete)) buffer = edit.buffer.delete()
    else if (press.is(keys.left)) buffer = edit.buffer.left()
    else if (press.is(keys.right)) buffer = edit.buffer.right()
    else if (press.is(keys.home)) buffer = edit.buffer.home()
    else if (press.is(keys.end)) buffer = edit.buffer.end()
    else return { state: edit }
    return { state: { ...edit, buffer, error: undefined } }
}

/**
 * Pasted text into a number: inserted at the cursor, blanks dropped.
 *
 * @param edit - the state.
 * @param text - what was pasted.
 */
export function pasteNumber(edit: NumberEdit, text: string): NumberEdit {
    return {
        ...edit,
        buffer: edit.buffer.insert(text.replace(/\s+/g, "")),
        error: undefined,
    }
}

// --- a tuple edited part by part

/**
 * A tuple being edited: `def`, the `texts` of each part (a colour part holds its name or
 * code), the `focus`ed part, the `fresh` number parts not yet typed into (the first key
 * replaces them) and the last `error` (cleared by the next key).
 */
export type TupleEdit = {
    def: SettingDef
    texts: readonly string[]
    focus: number
    fresh: ReadonlySet<number>
    error?: string
}

/**
 * What a key did to a tuple: the next state, the end if it ended the edit, and `pick`
 * when Enter on a colour part asks for that part's picker.
 */
export type TupleStep = { state: TupleEdit; end?: EditEnd<SettingValue>; pick?: boolean }

/** Whether the part in focus is a colour. */
const colourFocused = (edit: TupleEdit): boolean =>
    edit.def.partKinds[edit.focus] === "colour"

/**
 * Opens a tuple with each part as it is now, the first part in focus.
 *
 * @param def - the setting (a `tuple`).
 * @param current - its value now.
 */
export function openTuple(def: SettingDef, current: SettingValue): TupleEdit {
    return {
        def,
        texts: tupleParts(def, current).map(String),
        focus: 0,
        fresh: new Set(def.partKinds.flatMap((k, i) => (k === "colour" ? [] : [i]))),
    }
}

/**
 * Reads every part with `parsePart`, then checks the tuple (`finishTuple`); a wrong part
 * takes the focus.
 */
function commitTuple(edit: TupleEdit): TupleStep {
    const { def } = edit
    const parts: (number | string)[] = []
    for (const [i, kind] of def.partKinds.entries()) {
        const part = parsePart(kind, edit.texts[i] as string)
        if ("error" in part)
            return {
                state: { ...edit, focus: i, error: `${def.partNames[i]}: ${part.error}` },
            }
        parts.push(part.value)
    }
    const done = finishTuple(def, parts)
    if ("error" in done) return { state: { ...edit, error: done.error } }
    return { state: edit, end: { kind: "done", value: done.value } }
}

/** The text of the part in focus replaced, the part no longer fresh. */
function withText(edit: TupleEdit, text: string): TupleEdit {
    const fresh = new Set(edit.fresh)
    fresh.delete(edit.focus)
    const texts = edit.texts.map((t, i) => (i === edit.focus ? text : t))
    return { ...edit, texts, fresh, error: undefined }
}

/** The text of the part in focus as a buffer to type into (empty while still fresh). */
function bufferOfFocus(edit: TupleEdit): TextBuffer {
    const text = edit.fresh.has(edit.focus) ? "" : (edit.texts[edit.focus] as string)
    return new TextBuffer(text, undefined, maxNumberText)
}

/**
 * One key while a tuple is edited: arrows and Tab move between parts; text goes into a
 * number part (the first key replaces its old text); Enter takes the tuple on a number
 * part and asks for the picker (`pick`) on a colour part; Esc drops, Ctrl-X leaves.
 *
 * @param edit - the state.
 * @param press - the key.
 */
export function stepTuple(edit: TupleEdit, press: KeyInput): TupleStep {
    const n = edit.def.partNames.length
    const focusOn = (to: number): TupleStep => ({
        state: { ...edit, focus: Math.max(0, Math.min(n - 1, to)), error: undefined },
    })
    if (press.is(keys.escape)) return { state: edit, end: { kind: "cancel" } }
    if (press.is(keys.back)) return { state: edit, end: { kind: "back" } }
    if (press.is(keys.enter))
        return colourFocused(edit) ? { state: edit, pick: true } : commitTuple(edit)
    if (press.is(keys.left) || press.is(keys.up)) return focusOn(edit.focus - 1)
    if (press.is(keys.right) || press.is(keys.down)) return focusOn(edit.focus + 1)
    if (press.is(keys.tab)) return focusOn((edit.focus + 1) % n)
    if (colourFocused(edit) || isBlank(press)) return { state: edit }
    const buffer = bufferOfFocus(edit)
    if (press.typed) {
        if (buffer.full) return { state: { ...edit, error: CAP_NOTE } }
        return { state: withText(edit, buffer.insert(press.text).text) }
    }
    if (press.is(keys.backspace)) return { state: withText(edit, buffer.backspace().text) }
    return { state: edit }
}

/**
 * Puts the picker's colour into the focused part, then moves on (from the last part, takes
 * the tuple).
 *
 * @param edit - the state (the colour part in focus).
 * @param colour - the name or code picked.
 */
export function takeColour(edit: TupleEdit, colour: string): TupleStep {
    const next = withText(edit, colour)
    if (edit.focus < edit.def.partNames.length - 1)
        return { state: { ...next, focus: edit.focus + 1 } }
    return commitTuple(next)
}

/**
 * Pasted text into the focused number part: blanks dropped, replacing the old text if
 * fresh (a colour part is unchanged).
 *
 * @param edit - the state.
 * @param text - what was pasted.
 */
export function pasteTuple(edit: TupleEdit, text: string): TupleEdit {
    if (colourFocused(edit)) return edit
    const buffer = bufferOfFocus(edit).insert(text.replace(/\s+/g, ""))
    return withText(edit, buffer.text)
}

/**
 * What typed text means for a typed setting (number, optional number, `set` of
 * blank-separated choices, font, tuple as comma-separated parts, `lo-hi` ranges, chain
 * letters, colour and marker words, sizes like `76x5, 100x9`): the value `validateValue`
 * accepts, or the error. An empty font is the default font.
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
        const whole = def.kind === "int" || def.kind === "optionalInt"
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
 * The names a typed text narrows a list to: all for no text, else prefix matches, else
 * substring matches (case-blind).
 *
 * @param names - the whole list.
 * @param typed - the text.
 */
export function narrow(names: readonly string[], typed: string): string[] {
    const t = typed.trim().toLowerCase()
    if (t === "") return [...names]
    const prefix = names.filter((n) => n.toLowerCase().startsWith(t))
    return prefix.length > 0 ? prefix : names.filter((n) => n.toLowerCase().includes(t))
}

/**
 * The index of a name in a list, 0 if absent.
 *
 * @param names - the list.
 * @param name - the name (case does not matter).
 */
export function indexOfPick(names: readonly string[], name: string): number {
    const t = name.toLowerCase()
    const at = names.findIndex((n) => n.toLowerCase() === t)
    return Math.max(at, 0)
}

/** The kinds of setting picked from a list of names. */
export type ListKind = "colour" | "font"

/**
 * What Enter takes in a colour or font picker: a typed colour code, else the highlighted
 * name, else (no font list) the typed text; or the error.
 *
 * @param kind - what is picked.
 * @param names - every name there is (empty for fonts on a machine with no list).
 * @param typed - the text in the field.
 * @param highlighted - the name highlighted in the narrowed list, if any.
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
 * The parts of a tuple value, in order.
 *
 * @param def - the tuple setting.
 * @param value - its value (an array, or an object keyed by the names of the parts).
 */
export function tupleParts(def: SettingDef, value: SettingValue): (number | string)[] {
    return def.isRecord
        ? def.partNames.map((n) => (value as Record<string, number>)[n] as number)
        : [...(value as (number | string)[])]
}

/**
 * A value as a sheet shows it and as it is typed again to edit it: yes or no, the
 * choices that are on (`pdf png`), a tuple as its parts (`gray40, 0.6`), else as is.
 * Uncut: the caller fits it to its cell.
 *
 * @param def - the setting.
 * @param value - its value.
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
 * The colour a swatch shows: a colour setting's own, or the colour part of a tuple;
 * `undefined` if none.
 *
 * @param def - the setting.
 * @param value - its value.
 */
export function swatchColour(def: SettingDef, value: SettingValue): string | undefined {
    if (def.kind === "colour") return value as string
    if (def.kind === "tuple" && def.partKinds[0] === "colour")
        return tupleParts(def, value)[0] as string
    return undefined
}

/**
 * The drafts after a setting gets a value: none if it is the saved value.
 *
 * @param drafts - setting name to its unsaved value.
 * @param name - the setting.
 * @param saved - the saved value of the setting.
 * @param value - the new value.
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
 * [[withDraft]] for a model's settings: while the model overrides a setting, a value
 * equal to the project's counts as a change, because saving it removes the override.
 *
 * @param settings - the model's settings (its value now, whether it is overridden, the
 *     project's value).
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
 * The buffer landing's options: the buffer, the custom solutes, `load a recipe`, `new
 * recipe` and, for a buffer with solutes, `save current recipe globally`.
 *
 * @param buffer - the solutes of the buffer, `"unusable"` for a file that cannot be used.
 * @param custom - the custom solutes, `"unusable"` likewise.
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
 * A recipe's line in the load dropdown: `SEC buffer (3)`, `Tris pH (1, custom)` for a
 * template.
 *
 * @param template - what a template recipe is (`builtin`, `custom`, `table`, `invalid`).
 */
export function recipeChoice(name: string, solutes: number, template?: string): string {
    const kind = template === undefined ? "" : `, ${template}`
    return `${name} (${solutes}${kind})`
}

/**
 * A name cut with an ellipsis to fit its room (at least 8 cells kept).
 *
 * @param name - the name.
 * @param room - the cells the whole note may take.
 * @param fixed - the cells the rest of the note takes.
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
 * The question at the first `^w` of a recipe loaded over a buffer: `replace 3 solutes
 * with recipe "NAME"?` (`... solutes and notes ...` with notes); `replace` or `keep`.
 *
 * @param n - how many solutes the buffer has.
 * @param recipe - the recipe's name.
 * @param room - the cells the note line has.
 * @param notes - the recipe has notes, which replace the buffer's: `and notes` is said.
 */
export function replaceBufferQuestion(
    n: number,
    recipe: string,
    room: number,
    notes = false,
    template = false,
): Question {
    const what = `${plural(n, "solute")}${notes ? " and notes" : ""}`
    const kind = template ? "template" : "recipe"
    return replaceQuestion(`replace ${what} with ${kind} "`, recipe, room)
}

/**
 * The question when the saved buffer has template-following rows: `save "NAME" as a
 * template? its rows follow pH, T`; `template` (Enter), `plain recipe` (`w`) or `cancel`
 * (Esc, nothing saved).
 */
export function saveAsTemplateQuestion(name: string, room: number): Question {
    const tail = ' as a template? its rows follow pH, T'
    const shown = fitName(name, room, `save ""${tail}`.length)
    const text = `save "${shown}"${tail}`
    return { text, yes: "template", other: "plain recipe", no: "cancel" }
}

/**
 * The question when a recipe of that name exists: `replace "NAME"?`, `replace` or `keep`.
 */
export function replaceRecipeQuestion(name: string, room: number): Question {
    return replaceQuestion('replace "', name, room)
}

/** The message of a saved recipe: `saved as "NAME"`. */
export function savedAs(name: string, room: number): string {
    return `saved as "${fitName(name, room, 'saved as ""'.length)}"`
}

/** The message for a file that cannot be used: `recipes.json unusable!`. */
export function unusable(file: string): string {
    return `${file} unusable!`
}

/**
 * The drafts of a notes list with one note's text replaced (what the editor's `^w` hands
 * to the list's save). Throws the message of [[notesProblem]] when the list is invalid.
 *
 * @param drafts - the list's drafts.
 * @param index - the row of the note.
 * @param text - its new text.
 */
export function withNoteText(
    drafts: Drafts<Note>,
    index: number,
    text: string,
): Drafts<Note> {
    const next = drafts.set(index, { ...(drafts.value(index) as Note), text })
    const why = notesProblem(next.toSave())
    if (why !== undefined) throw new Error(why)
    return next
}

/**
 * The counter under the notes: `line 3/12  col 7  482 characters`.
 *
 * @param line - the line of the cursor, from 1.
 * @param lines - how many lines the text has.
 * @param column - the cell of the cursor in its line, from 1.
 * @param used - the characters of the text.
 */
export function notesCounter(
    line: number,
    lines: number,
    column: number,
    used: number,
): string {
    return `line ${line}/${lines}  col ${column}  ${used} characters`
}

/** The most cells of the owner in the title of the editor (the title keeps its own). */
const OWNER_CELLS = 24

/**
 * The editor title `<owner> / <note title>`, the owner cut from its start so it fits the
 * narrowest terminal.
 *
 * @param owner - the project's id, `buffer` or a recipe's name.
 * @param title - the note's title.
 */
export function noteScreenTitle(owner: string, title: string): string {
    return `${truncateStart(owner, OWNER_CELLS)} / ${title}`
}
