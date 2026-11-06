// SPDX-License-Identifier: LGPL-3.0-or-later

import { type NumberRules, parseNumber, wrapText } from "../core/text.js"
import type {
    Limits,
    ListKind,
    PartKind,
    SettingDef,
    SettingValue,
} from "../store/settings-defs.js"
import { sameValue } from "../store/settings-store.js"
import { validateValue } from "../store/settings-validate.js"
import { type KeyInput, keys } from "../ui/keys.js"
import { scrollTo, stepIndex } from "../ui/scroll-window.js"
import { TextBuffer } from "../ui/text-buffer.js"

/**
 * The logic of a settings sheet and of its value editors, with no terminal in it: an
 * editor is a state and a function `step(state, press)` that gives the next state and,
 * when the edit is over, how it ended. The components of `setting-editors.tsx` only
 * hold the state and draw it, so every rule here is testable on its own.
 */

// --- how an edit ends

/**
 * How an edit ended: with a value, abandoned, or by Ctrl-X (leave the whole sheet).
 *
 * @typeParam V - the kind of value the editor gives.
 */
export type EditEnd<V> = { kind: "done"; value: V } | { kind: "cancel" } | { kind: "back" }

/**
 * What a key does to an editor.
 *
 * @typeParam S - the state of the editor.
 * @typeParam V - the kind of value the editor gives.
 * @property state - the state after the key.
 * @property end - set when the key ended the edit.
 */
export type EditStep<S, V> = { state: S; end?: EditEnd<V> }

/** The edit was abandoned. */
const cancelled = <S, V>(state: S): EditStep<S, V> => ({ state, end: { kind: "cancel" } })

/** Ctrl-X was pressed. */
const wentBack = <S, V>(state: S): EditStep<S, V> => ({ state, end: { kind: "back" } })

// --- the text editing keys

/**
 * Applies a key to a text buffer when it is an editing key: a typed character,
 * backspace, delete, left, right, home or end.
 *
 * @param buffer - the text and its cursor.
 * @param press - the key.
 * @returns the new buffer, or `undefined` if the key is not an editing key.
 */
function editBuffer(buffer: TextBuffer, press: KeyInput): TextBuffer | undefined {
    if (press.typed) return buffer.insert(press.text)
    if (press.is(keys.backspace)) return buffer.backspace()
    if (press.is(keys.delete)) return buffer.delete()
    if (press.is(keys.left)) return buffer.left()
    if (press.is(keys.right)) return buffer.right()
    if (press.is(keys.home)) return buffer.home()
    if (press.is(keys.end)) return buffer.end()
    return undefined
}

/** Whether a typed press is only blank (a space): a number never has one. */
const isBlank = (press: KeyInput): boolean => press.typed && press.text.trim() === ""

// --- numbers

/** The longest text typed into a number: what the field can show beside its cursor. */
export const maxNumberText = 16

/**
 * The most digits of a whole number that are taken: no integer setting has an upper
 * limit of its own, so a value is held to what a 64 bit number says exactly.
 */
const maxIntDigits = 15

/** What the editor says when a character past [[maxNumberText]] is refused. */
export const capNote = `${maxNumberText} digits at most`

/**
 * What a setting of each number kind accepts as text, for `parseNumber`. Limits are not
 * looked at here: a setting is checked by `validateValue`, a part of a tuple by the
 * rules over the whole tuple.
 */
export const numberRules: Record<"int" | "float", NumberRules> = {
    int: {
        whole:         true,
        signed:        true,
        maxDigits:     maxIntDigits,
        digitsMessage: `${maxIntDigits} digits at most`,
    },
    float: {},
}

/**
 * The state of a number being typed.
 *
 * @property def - the setting (an `int` or a `float`).
 * @property buffer - the text so far.
 * @property error - what was wrong with the last attempt.
 */
export type NumberEdit = { def: SettingDef; buffer: TextBuffer; error?: string }

/**
 * Opens a number for editing, starting from its current value.
 *
 * @param def - the setting.
 * @param current - its value now.
 * @returns the edit, the cursor at the end of the text.
 */
export function openNumber(def: SettingDef, current: SettingValue): NumberEdit {
    const empty = new TextBuffer("", undefined, maxNumberText)
    return { def, buffer: empty.replace(String(current)) }
}

/**
 * One key while a number is typed: Enter takes it if it is a number within the limits
 * of the setting, Esc drops it, typing past the cap says so.
 *
 * @param edit - the state.
 * @param press - the key.
 * @returns the next state, and the number when Enter took it.
 */
export function stepNumber(
    edit: NumberEdit,
    press: KeyInput,
): EditStep<NumberEdit, number> {
    if (press.is(keys.escape)) return cancelled(edit)
    if (press.is(keys.back)) return wentBack(edit)
    if (press.is(keys.enter)) {
        const kind = edit.def.kind === "int" ? "int" : "float"
        const parsed = parseNumber(edit.buffer.text, numberRules[kind])
        if ("error" in parsed) return { state: { ...edit, error: parsed.error } }
        const checked = validateValue(edit.def, parsed.value)
        if (!checked.ok) return { state: { ...edit, error: checked.error } }
        return { state: edit, end: { kind: "done", value: checked.value as number } }
    }
    if (isBlank(press)) return { state: edit }
    if (press.typed && edit.buffer.full) return { state: { ...edit, error: capNote } }
    const buffer = editBuffer(edit.buffer, press)
    return { state: buffer === undefined ? edit : { ...edit, buffer, error: undefined } }
}

/**
 * Pasted text into a number: inserted, the blanks dropped.
 *
 * @param edit - the state.
 * @param text - what was pasted.
 * @returns the next state.
 */
export function pasteNumber(edit: NumberEdit, text: string): NumberEdit {
    const digits = text.replace(/\s+/g, "")
    return { ...edit, buffer: edit.buffer.insert(digits), error: undefined }
}

// --- colours and fonts: a name picked from a list

/** The longest name typed to narrow a list of colours or fonts. */
export const maxNameText = 40

/** What a `#rrggbb` colour looks like as typed. */
const hexText = /^#[0-9a-fA-F]{6}$/

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

/**
 * What Enter takes in a colour or font picker: the highlighted name, else a colour typed
 * as `#rrggbb`, else (on a machine with no list of fonts) the text as it is.
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
    if (kind === "colour" && hexText.test(text)) return { value: text.toLowerCase() }
    if (highlighted !== undefined) return { value: highlighted }
    if (kind === "font" && names.length === 0 && text !== "") return { value: text }
    return { error: kind === "colour" ? "not a known colour" : "not a known font" }
}

// --- a choice of a few options: tabs

/**
 * The state of a set of choices being turned on and off.
 *
 * @property options - every choice, in order.
 * @property selected - the ones that are on.
 * @property focus - the index of the tab in focus.
 * @property error - what was wrong with the last attempt.
 */
export type TabsEdit = {
    options: readonly string[]
    selected: ReadonlySet<string>
    focus: number
    error?: string
}

/**
 * Opens a set of choices.
 *
 * @param def - the setting (a `set`).
 * @param current - the choices that are on.
 * @returns the edit with the first tab in focus.
 */
export function openTabs(def: SettingDef, current: readonly string[]): TabsEdit {
    return { options: def.choices, selected: new Set(current), focus: 0 }
}

/** What Esc says when no choice is on: a set needs at least one. */
export const pickOneNote = "pick one or more"

/**
 * One key on the tabs: left and right move (stopping at the ends), Tab goes round,
 * Enter turns the tab in focus on or off, Esc is done, which needs one choice on.
 *
 * @param edit - the state.
 * @param press - the key.
 * @returns the next state, and the choices that are on, in order, when Esc ended it.
 */
export function stepTabs(edit: TabsEdit, press: KeyInput): EditStep<TabsEdit, string[]> {
    const n = edit.options.length
    const moved = (focus: number): EditStep<TabsEdit, string[]> => ({
        state: { ...edit, focus, error: undefined },
    })
    if (press.is(keys.back)) return wentBack(edit)
    if (press.is(keys.escape)) {
        if (edit.selected.size === 0) return { state: { ...edit, error: pickOneNote } }
        const value = edit.options.filter((o) => edit.selected.has(o))
        return { state: edit, end: { kind: "done", value } }
    }
    if (press.is(keys.enter)) {
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

// --- tuples: one text for each part

/**
 * The state of a tuple being edited: a text for each part, one part in focus.
 *
 * @property def - the setting (a `tuple`).
 * @property buffers - the text of each part.
 * @property focus - the part being typed into.
 * @property fresh - the parts not typed into yet: the first key replaces their text.
 * @property names - the colour names, for a colour part (empty when there is none).
 * @property index - the highlighted colour, when a colour part is in focus.
 * @property error - what was wrong with the last attempt.
 */
export type TupleEdit = {
    def: SettingDef
    buffers: readonly string[]
    focus: number
    fresh: ReadonlySet<number>
    names: readonly string[]
    index: number
    error?: string
}

/** The text of a part of a tuple value as it is typed. */
const partText = (part: number | string): string => String(part)

/**
 * The parts of a tuple value in order.
 *
 * @param def - the tuple setting.
 * @param value - its value (an array, or an object keyed by the names of the parts).
 * @returns the parts.
 */
function tupleParts(def: SettingDef, value: SettingValue): (number | string)[] {
    return def.isRecord
        ? def.partNames.map((n) => (value as Record<string, number>)[n] as number)
        : [...(value as (number | string)[])]
}

/**
 * The colours the colour part in focus narrows to: every colour while it is not typed
 * into, else those that match its text; none when the part in focus is no colour.
 *
 * @param edit - the state.
 * @returns the names.
 */
export function tupleMatches(edit: TupleEdit): string[] {
    if (edit.def.partKinds[edit.focus] !== "colour") return []
    if (edit.fresh.has(edit.focus)) return [...edit.names]
    return narrow(edit.names, edit.buffers[edit.focus] as string)
}

/**
 * The state with the highlighted colour put where the part in focus says: on the
 * colour it names while untouched, else on the first match.
 */
function refocused(edit: TupleEdit): TupleEdit {
    const colour = edit.def.partKinds[edit.focus] === "colour"
    const index =
        colour && edit.fresh.has(edit.focus)
            ? indexOfPick(edit.names, edit.buffers[edit.focus] as string)
            : 0
    return { ...edit, index }
}

/**
 * Opens a tuple with the text of each part as it is now and the first part in focus.
 *
 * @param def - the setting.
 * @param current - its value now.
 * @param colours - the colour names, for a colour part.
 * @returns the edit.
 */
export function openTuple(
    def: SettingDef,
    current: SettingValue,
    colours: readonly string[],
): TupleEdit {
    const kinds = def.partKinds
    return refocused({
        def,
        buffers: tupleParts(def, current).map(partText),
        focus: 0,
        fresh: new Set(kinds.flatMap((k, i) => (k === "colour" ? [i] : []))),
        names: kinds.includes("colour") ? colours : [],
        index: 0,
    })
}

/** What a part of a kind means as typed: a value, or what is wrong. */
function partValue(
    kind: PartKind,
    text: string,
    names: readonly string[],
    highlight: string | undefined,
): { value: number | string } | { error: string } {
    if (kind !== "colour") return parseNumber(text, numberRules[kind])
    const t = text.trim()
    if (hexText.test(t)) return { value: t.toLowerCase() }
    const exact = names.find((n) => n.toLowerCase() === t.toLowerCase())
    if (exact !== undefined) return { value: exact }
    if (highlight !== undefined) return { value: highlight }
    return { error: "not a known colour" }
}

/**
 * Enter on a tuple: every part is read, then the tuple is checked as a whole; the
 * edit stays open, with the part at fault in focus, when something is wrong.
 */
function commitTuple(edit: TupleEdit): EditStep<TupleEdit, SettingValue> {
    const { def } = edit
    const matches = tupleMatches(edit)
    const parsed = def.partKinds.map((kind, i) =>
        partValue(
            kind,
            edit.buffers[i] as string,
            edit.names,
            i === edit.focus ? matches[edit.index] : undefined,
        ),
    )
    const bad = parsed.findIndex((p) => "error" in p)
    if (bad >= 0) {
        const message = (parsed[bad] as { error: string }).error
        return {
            state: refocused({
                ...edit,
                focus: bad,
                error: `${def.partNames[bad]}: ${message}`,
            }),
        }
    }
    const values = parsed.map((p) => (p as { value: number | string }).value)
    const candidate = def.isRecord
        ? Object.fromEntries(def.partNames.map((n, i) => [n, values[i]]))
        : values
    const checked = validateValue(def, candidate)
    if (!checked.ok) return { state: { ...edit, error: checked.error } }
    return { state: edit, end: { kind: "done", value: checked.value } }
}

/**
 * One key while a tuple is edited. Left and right move between the parts, text is typed
 * into the part in focus (the first key replaces what a part had), Enter accepts the
 * tuple, Esc drops it. In a colour part up and down pick among the colours that match
 * and Tab takes the one picked; in any other part up and down also move between parts
 * and Tab moves on round the parts.
 *
 * @param edit - the state.
 * @param press - the key.
 * @returns the next state, and the tuple when Enter took it.
 */
export function stepTuple(
    edit: TupleEdit,
    press: KeyInput,
): EditStep<TupleEdit, SettingValue> {
    const n = edit.def.partNames.length
    const colour = edit.def.partKinds[edit.focus] === "colour"
    const matches = tupleMatches(edit)
    const focusOn = (to: number): EditStep<TupleEdit, SettingValue> => ({
        state: refocused({
            ...edit,
            focus: Math.max(0, Math.min(n - 1, to)),
            error: undefined,
        }),
    })
    const setText = (text: string): EditStep<TupleEdit, SettingValue> => {
        const fresh = new Set(edit.fresh)
        fresh.delete(edit.focus)
        const buffers = edit.buffers.map((b, i) => (i === edit.focus ? text : b))
        return { state: refocused({ ...edit, buffers, fresh, error: undefined }) }
    }
    if (press.is(keys.escape)) return cancelled(edit)
    if (press.is(keys.back)) return wentBack(edit)
    if (press.is(keys.enter)) return commitTuple(edit)
    if (press.is(keys.left)) return focusOn(edit.focus - 1)
    if (press.is(keys.right)) return focusOn(edit.focus + 1)
    const vertical = press.is(keys.down) || press.is(keys.up)
    if (vertical && colour && matches.length > 0)
        return {
            state: {
                ...edit,
                error: undefined,
                index: stepIndex(edit.index, matches.length, press.is(keys.down), true),
            },
        }
    if (press.is(keys.down)) return focusOn(edit.focus + 1)
    if (press.is(keys.up)) return focusOn(edit.focus - 1)
    if (press.is(keys.tab)) {
        if (colour && matches.length > 0) return setText(matches[edit.index] as string)
        const focus = (edit.focus + 1) % n
        return { state: refocused({ ...edit, focus, error: undefined }) }
    }
    const cap = colour ? maxNameText : maxNumberText
    const base = edit.fresh.has(edit.focus) ? "" : (edit.buffers[edit.focus] as string)
    if (press.typed && !isBlank(press))
        return setText(new TextBuffer(base, undefined, cap).insert(press.text).text)
    if (press.is(keys.backspace))
        return setText(new TextBuffer(base, undefined, cap).backspace().text)
    return { state: edit }
}

// --- what a sheet shows

/** The words the value cell uses for the two values of a yes/no setting. */
const yesNo = { true: "yes", false: "no" } as const

/**
 * A value as the value cell of a sheet shows it: yes or no, the choices that are on
 * (`pdf png`), a tuple in parentheses (`(gray40, 0.6)`), anything else as it is.
 *
 * @param def - the setting.
 * @param value - its value.
 * @returns the text, uncut: the caller fits it to its cell.
 */
export function valueText(def: SettingDef, value: SettingValue): string {
    if (typeof value === "boolean") return yesNo[`${value}`]
    if (def.kind === "set") return (value as string[]).join(" ")
    if (def.kind === "tuple") return `(${tupleParts(def, value).join(", ")})`
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

/** The limit keys in the order they are told, with the words for each. */
const limitWords: [keyof Limits, string][] = [
    ["above", "above"],
    ["below", "below"],
    ["at_least", "at least"],
    ["at_most", "at most"],
]

/**
 * What a setting accepts, in a line: its kind, its limits, its default.
 *
 * @param def - the setting.
 * @returns for example `whole number, at least 1 · default 2000`.
 */
export function settingFacts(def: SettingDef): string {
    const kind: Record<SettingDef["kind"], string> = {
        int: "integer",
        float: "number",
        bool: "yes or no",
        colour: "colour",
        font: "font",
        set: `some of ${def.choices.join(", ")}`,
        tuple: `(${def.partNames.join(", ")})`,
    }
    const limits = limitWords.flatMap(([key, words]) =>
        def.limits[key] === undefined ? [] : [`${words} ${def.limits[key]}`],
    )
    const what = [kind[def.kind], ...limits].join(", ")
    return `${what} · default ${valueText(def, def.default)}`
}

/**
 * The lines of a setting's description at a width.
 *
 * @param def - the setting.
 * @param cells - the width.
 * @returns the lines, one at least.
 */
export function descriptionLines(def: SettingDef, cells: number): string[] {
    return wrapText(def.description, cells)
}

// --- the table of a sheet: widths, rules, blocks that scroll

/** The cells left of the table: the margin where the cursor `>` stands. */
const marginCells = 3

/** The cells of the four vertical lines of the table. */
const borderCells = 4

/** The cells of the value column on a narrow terminal (a space, 17 cells, a mark). */
const valueColumnNarrow = 19

/** The cells of the value column from [[wideColumns]] on, room for a swatch and a tuple. */
const valueColumnWide = 25

/** The width of a terminal from which the value column is the wide one. */
const wideColumns = 100

/** The most cells of the name column (a space, a name of up to 22 cells, a space). */
const nameColumnMax = 24

/** The most lines of a message under a value (an error or a notice). */
const noteLinesMax = 2

/**
 * The widths of the columns of the table.
 *
 * @property name - the name column, borders not counted.
 * @property desc - the description column, which takes all that is left.
 * @property value - the value column.
 */
export type TableWidths = { name: number; desc: number; value: number }

/**
 * Works out the columns of the table for a width: the name column as wide as the
 * longest name, the value column a fixed width, the description all the rest.
 *
 * @param columns - the cells the table (with its margin) may use.
 * @param longestName - the cells of the longest setting name of the sheet.
 * @returns the widths.
 */
export function tableWidths(columns: number, longestName: number): TableWidths {
    const name = Math.min(nameColumnMax, longestName + 2)
    const value = columns >= wideColumns ? valueColumnWide : valueColumnNarrow
    const desc = Math.max(8, columns - marginCells - borderCells - name - value)
    return { name, value, desc }
}

/**
 * The lines of a message under a value: wrapped to the column, at most two lines.
 *
 * @param text - the message.
 * @param cells - the room.
 * @returns the lines.
 */
export function noteLines(text: string, cells: number): string[] {
    return wrapText(text, cells).slice(0, noteLinesMax)
}

/**
 * How many lines of a table the first blocks take from `top`, rules between them.
 *
 * @param heights - the lines of every block.
 * @param top - the first block.
 * @param budget - the lines available.
 * @returns the number of blocks that fit whole, at least one.
 */
export function blocksFitting(
    heights: readonly number[],
    top: number,
    budget: number,
): number {
    let used = 0
    let n = 0
    for (let i = top; i < heights.length; i++) {
        used += (heights[i] as number) + (n > 0 ? 1 : 0)
        if (used > budget && n > 0) break
        n++
    }
    return n
}

/**
 * The first block to draw so that the selected one is wholly in view: the old top if
 * that already shows it, else the smallest top that does.
 *
 * @param heights - the lines of every block.
 * @param top - the first block drawn so far.
 * @param selected - the selected block.
 * @param budget - the lines available.
 * @returns the new first block.
 */
export function scrollTop(
    heights: readonly number[],
    top: number,
    selected: number,
    budget: number,
): number {
    return scrollTo(top, selected, (first) => blocksFitting(heights, first, budget))
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
