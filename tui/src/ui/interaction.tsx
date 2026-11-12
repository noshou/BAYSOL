// SPDX-License-Identifier: LGPL-3.0-or-later

// Interaction: how a screen listens and keeps its place: the navigation stack, the keys,
// the layout rules and the lists with a cursor.
//
// Contents:
//   1. Navigation: the screen stack and which screen listens
//   2. Key values: `KeyInput`, `keys`, `ctrlKey`/`plainKey`/`shiftKey`, matching, labels
//   3. `useKeys`: the one handler hook, gated by the nav stack
//   4. Layout: the terminal size and the room the screens get
//   5. Scroll window: which rows of a long list are drawn (pure)
//   6. `useListCursor`: the cursor and offset of a list as state
//   7. `CursorList` and `ListText`: a list drawn with a `>` cursor
//   8. `Swatch`: the colour cell pair of a list row
//   9. `ChoiceTabs`: a one-line row of on/off tabs

import {
    Box,
    type Key as InkKey,
    Text,
    useApp,
    useInput,
    useWindowSize,
} from "ink"
import {
    createContext,
    type ReactElement,
    type ReactNode,
    useCallback,
    useContext,
    useMemo,
    useState,
} from "react"
import { clampIndex } from "../core/terminal.js"
import { useTheme } from "./theme.js"

// ========================================================================================
// 1. Navigation: the screen stack and which screen listens
// ========================================================================================

/**
 * What a screen can ask of the navigation: open another screen on top of it, go back
 * to the one below, or quit the program.
 *
 * @property push - opens `screen` on top of the current one.
 * @property pop - closes the current screen; the one below is shown again, as it was.
 * @property quit - ends the program.
 * @property depth - how many screens are open (1 for the first).
 */
export type Nav = {
    push:  (screen: ReactElement) => void
    pop:   () => void
    quit:  () => void
    depth: number
}

const NavContext = createContext<Nav | null>(null)


/**
 * Whether the screen that reads this is the one on top. Every screen stays mounted
 * while another is open on it (so it comes back as it was), and only the top one
 * takes keys.
 */
const ActiveContext = createContext<boolean>(true)

/**
 * The navigation of the program; only callable within a screen.
 *
 * @returns the [[Nav]] that opens and closes screens.
 * @throws if there is no [[NavProvider]] above the caller.
 */
export function useNav(): Nav {
    const nav = useContext(NavContext)
    if (nav === null) throw new Error("useNav needs a NavProvider above it")
    return nav
}

/** @returns `true` when the calling screen is the one on top and may take keys. */
export function useScreenActive(): boolean {
    return useContext(ActiveContext)
}

/**
 * Keeps the stack of open screens and draws all of them, the top one visible.
 * Lower screens keep their state because they are hidden, not unmounted.
 *
 * @param root - the first screen.
 * @param suspended - `true` while nothing may take keys (the terminal is too small to
 *     show a screen): the screens stay mounted, so the user comes back to the one
 *     they were on, with its state, when the terminal is big enough again.
 * @returns the provider; put it around the whole program.
 */
export function NavProvider(
    { root, suspended = false }: { root: ReactElement; suspended?: boolean }
): ReactNode {
    const { exit } = useApp()
    // ONE resize listener for every screen: each `useWindowSize` of Ink adds its own, and
    // the screens of the stack stay mounted (more than ten hit Node's leak warning)
    const { columns, rows } = useWindowSize()
    const size = useMemo(() => ({ columns, rows }), [columns, rows])
    const [stack, setStack] = useState<ReactElement[]>([root])

    const push = useCallback((screen: ReactElement) => setStack((s) => [...s, screen]), [])
    // the first screen is never popped: going back from it would leave nothing to show
    const pop = useCallback(
        () => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s)),
        []
    )
    const nav = useMemo(
        () => ({ push, pop, quit: exit, depth: stack.length }),
        [push, pop, exit, stack.length]
    )

    return (
        <SizeContext.Provider value={size}>
        <NavContext.Provider value={nav}>
            {stack.map((screen, i) => (
                <ActiveContext.Provider
                    // biome-ignore lint/suspicious/noArrayIndexKey: position is the id
                    key={i}
                    value={!suspended && i === stack.length - 1}
                >
                    <Box
                        display={i === stack.length - 1 ? "flex" : "none"}
                        flexGrow={1}
                        flexDirection="column"
                    >
                        {screen}
                    </Box>
                </ActiveContext.Provider>
            ))}
        </NavContext.Provider>
        </SizeContext.Provider>
    )
}

// ========================================================================================
// 2. Key values, matching and labels
// ========================================================================================

/** What a legend shows for the keys that are not a letter, by key name. */
const namedLabels: Record<string, string> = {
    escape:    "esc",
    return:    "⏎",
    tab:       "tab",
    backspace: "⌫",
    delete:    "del",
    up:        "↑",
    down:      "↓",
    left:      "←",
    right:     "→",
    pageup:    "pgup",
    pagedown:  "pgdn",
    home:      "home",
    end:       "end",
    " ":       "␣",
    "+":       "shift++",
}

/**
 * One key press: the name of the key, whether Ctrl and Shift were held, and the text it
 * typed.
 *
 * The name is the typed character in lower case (`"n"`), or one of `"escape"`,
 * `"return"`, `"tab"`, `"backspace"`, `"delete"`, `"up"`, `"down"`, `"left"`,
 * `"right"`, `"pageup"`, `"pagedown"`, `"home"`, `"end"`. Menu hotkeys are
 * `KeyInput`s too, so a press is matched against a hotkey with `is`. Text entry
 * reads `text`, which keeps the capitals of what was typed (or pasted).
 *
 * @param key_ - the name of the key.
 * @param ctrl - whether Ctrl was held, `false` when left out.
 * @param text - what the key typed, `""` for a key that types nothing.
 * @param shift - whether the key is a capital letter (Shift, or Caps Lock), `false`
 *     when left out. In a hotkey it means "the capital only" (see `is`).
 */
export class KeyInput {
    constructor(
        readonly key_:  string,
        readonly ctrl:  boolean = false,
        readonly text:  string  = "",
        readonly shift: boolean = false
    ) {}

    /**
     * Compares a press (this) with a wanted key, normally a hotkey from `keys`.
     *
     * The names and the Ctrl state must be equal. Shift is asymmetric on purpose: a
     * wanted key that demands Shift (`shiftKey("d")`) matches only a capital press,
     * while a wanted key that does not demand it matches either case. So every plain
     * hotkey keeps working with Caps Lock or a capital typed by mistake, as it always
     * did, and a screen can still give `D` a meaning of its own. A screen that has both
     * `d` and `D` must test the Shift key first, because a capital press matches both.
     *
     * @param key - the wanted key (a hotkey).
     * @returns `true` when this press is that key.
     */
    is (key: KeyInput) {
        return key.key_  === this.key_  && key.ctrl  === this.ctrl
            && (!key.shift || this.shift)
    }

    /**
     * What a legend shows for this key: `⏎`, `esc`, `tab`, `↑`, a letter, `^` and the
     * letter for a Ctrl key, `shift+` and the letter for a Shift key.
     */
    get label(): string {
        if (this.key_ in namedLabels)
            return `${this.shift ? "shift+" : ""}${namedLabels[this.key_]}`
        if (this.ctrl) return `^${this.key_}`
        return this.shift ? `shift+${this.key_}` : this.key_
    }

    /**
     * The key spelled in words, for a note line: `enter` for Return, else the label
     * (`esc`, `tab`, `^w`).
     */
    get name(): string {
        return this.key_ === "return" ? "enter" : this.label
    }

    /** `true` when the press typed text (a letter, a digit, a space, a paste). */
    get typed(): boolean {
        return this.text !== "" && !this.ctrl
    }
}

/**
 * A Ctrl hotkey.
 *
 * @param letter - the letter, lower case.
 * @returns the key, which a legend shows as `^letter`.
 */
export const ctrlKey = (letter: string): KeyInput => new KeyInput(letter, true)

/**
 * A plain letter hotkey; it matches the letter in either case (see `KeyInput.is`).
 *
 * @param letter - the letter, lower case.
 * @returns the key, which a legend shows as the letter.
 */
export const plainKey = (letter: string): KeyInput => new KeyInput(letter)

/**
 * A Shift hotkey: only the capital letter matches it.
 *
 * @param letter - the letter, lower case.
 * @returns the key, which a legend shows as `shift+letter`.
 */
export const shiftKey = (letter: string): KeyInput =>
    new KeyInput(letter, false, "", true)

/** A key only the capital letter matches; a legend shows the capital (`N`). */
class CapitalKey extends KeyInput {
    override get label(): string {
        return this.key_.toUpperCase()
    }
}

/**
 * A capital-letter hotkey: only the capital matches it, and the legend shows `N`, not
 * `shift+n` (shorter, so a legend with many keys keeps its width).
 *
 * @param letter - the letter, lower case.
 * @returns the key.
 */
const capitalKey = (letter: string): KeyInput =>
    new CapitalKey(letter, false, "", true)

/**
 * What a legend shows for one or more keys, so a legend never spells a key itself.
 *
 * @param parts - the keys, shown in order. A key is separated from the next by a
 *     space (`tab` after `⏎`); an array is a run written together, `[up, down]`
 *     being `↑↓`.
 * @returns the labels, e.g. `"←→ tab"`.
 */
export function keyLabels(...parts: (KeyInput | KeyInput[])[]): string {
    return parts
        .map((p) => (Array.isArray(p) ? p.map((k) => k.label).join("") : p.label))
        .join(" ")
}

/**
 * Every key the program gives a meaning, in one place so a screen never spells a key
 * itself. Ctrl-M, Ctrl-I, Ctrl-J, Ctrl-B, Ctrl-S, Ctrl-Q, Ctrl-Z and Ctrl-Y are not
 * usable: terminals send them as Enter, Tab, flow control, or take them. Ctrl-C and
 * Ctrl-D reach the program (Ink runs with `exitOnCtrlC: false`) and are reserved for
 * leaving it: `interrupt` and `eof`.
 */
export const keys = {

    enter:     new KeyInput("return"),
    escape:    new KeyInput("escape"),
    tab:       new KeyInput("tab"),
    backspace: new KeyInput("backspace"),
    delete:    new KeyInput("delete"),
    up:        new KeyInput("up"),
    down:      new KeyInput("down"),
    left:      new KeyInput("left"),
    right:     new KeyInput("right"),
    pageUp:    new KeyInput("pageup"),
    pageDown:  new KeyInput("pagedown"),
    home:      new KeyInput("home"),
    end:       new KeyInput("end"),

    /** Leave the program at once (the only exits are `q` in the main menu and this). */
    interrupt: ctrlKey("c"),

    /** Leave the program at once, like `interrupt` (end of input). */
    eof:       ctrlKey("d"),

    /** The taskbar of the project menu: start a run (Shift+R). */
    runKey:     shiftKey("r"),

    /** Back one screen, from any mode; never quits. */
    back:   ctrlKey("x"),

    /** Save every change on the screen. */
    save:   ctrlKey("w"),

    /** Undo: a removal mark, else the draft. */
    undo:   ctrlKey("u"),

    /** Remove a table row, or reset a group of settings. */
    remove: ctrlKey("r"),

    /** Switch between the light and the dark theme. */
    theme:  ctrlKey("t"),

    /** Add a non-biological solute. */
    addNonbio:     ctrlKey("n"),

    /** Add a polymer. */
    addPolymer:    ctrlKey("p"),

    /** Add a protein from a sequence file. */
    addProtein:    ctrlKey("f"),

    /** Add a nucleotide (DNA or RNA) from a sequence file; also the custom landing. */
    addNucleotide: ctrlKey("e"),

    /** Rename the highlighted note (the notes list; on the buffer's solutes table the
     * same key adds a nucleotide: a different screen). */
    notes:         ctrlKey("e"),

    /** Open the notes list of the project (project menu), of the highlighted recipe
     * (recipes table), of the buffer or of one recipe (their solutes table). */
    notesList:     shiftKey("n"),

    /** Add the rows of a standard buffer (Tris, HEPES, PBS ...) on the solutes table. */
    bufferTemplate: shiftKey("b"),

    /** Make a template: a recipe (recipes table) or rows (solutes table) that follow the
     * pH and the temperature, from a shipped buffer, a custom one or a table. */
    newTemplate:   shiftKey("t"),

    /** Turn the rows of the solutes table into a template: a table of amounts that starts
     * from them at the pH of the table. */
    convertTemplate: shiftKey("v"),

    /** Edit the definition of the template recipe under the cursor (recipes table). */
    editTemplate:  shiftKey("e"),

    /** The third answer of a question that has one besides Enter and Esc (`save as a
     * template?`: the plain recipe). */
    otherAnswer:   plainKey("n"),

    /** Edit the pH of a buffer (and its σ) on the solutes table. */
    editPh:        ctrlKey("g"),

    /** Change the family the colour picker narrows to (all, red, orange, ...). */
    family:        ctrlKey("g"),

    /** Turn the unit of the concentrations of the buffer table (mM, M, µM). */
    units:         ctrlKey("k"),

    /** Add a reference curve (the references list of the data screen). */
    addReference:  ctrlKey("n"),

    /** Open the settings of the highlighted model (the models list). */
    modelSettings: ctrlKey("o"),

    /** Open the reference fit of the highlighted model (the models list). */
    modelReference: ctrlKey("f"),

    /** Pick files with the desktop file picker (an empty field). */
    pickFiles: plainKey("o"),

    /** Open the list of models (an empty field). */
    openList:  plainKey("m"),

    /** Reset an unusable file (a landing page). */
    reset:     plainKey("r"),

    // The file viewer (`screens/viewer.tsx`).

    /** The pager's page down (with Enter and PgDn). */
    space:      new KeyInput(" "),

    /** Show the plots of a run instead of the sheets, and back (the same key on the
     * polymer form is a different screen). */
    plots:      ctrlKey("p"),

    /** The previous and the next sheet (tab). */
    shiftTab:   shiftKey("tab"),
    zoomIn:     plainKey("+"),
    zoomInAlt:  plainKey("="),
    zoomOut:    plainKey("-"),
    prevSheet:  plainKey("["),
    nextSheet:  plainKey("]"),

    /** Search (`/`), the next and previous match, jump to a cell, copy, formulas. In a
     * table of named rows `/` finds a row and `s` puts the rows in alphabetical order. */
    find:       plainKey("/"),
    sort:       plainKey("s"),
    nextMatch:  plainKey("n"),
    prevMatch:  capitalKey("n"),
    jump:       plainKey("g"),
    copy:       plainKey("c"),
    copyRow:    plainKey("r"),
    copyColumn: plainKey("l"),
    formulas:   plainKey("f"),

    /** Read the `run.LOG` of a run (`open runs`). */
    showLog:    ctrlKey("l"),

    /** Move (copy) the `.tex` plots of a run to the plot folder (`open runs`): a dropdown
     * asks for the whole run or one model. */
    moveTex:         shiftKey("t"),

    /** Move (copy) the data of a run, the workbooks and the comparison table, to the data
     * folder: the same dropdown. */
    moveData:        shiftKey("d"),

    /** Compile the plots of the highlighted model or comparison with LaTeX into the
     * plot folder. */
    compilePlots:    shiftKey("c"),

    // The `run.LOG` pager also takes `enter`, `space`, `pageDown`, `pageUp`, the arrows
    // and `home`/`end`.

    /** A page up (the other page-up key is `pageUp`). */
    pageBack:   plainKey("b"),
} as const

/** The names of Ink's flags for the keys that type nothing, and the name given each. */
const namedKeys: [keyof InkKey, string][] = [
    ["escape",    "escape"],
    ["return",    "return"],
    ["tab",       "tab"],
    ["backspace", "backspace"],
    ["delete",    "delete"],
    ["upArrow",   "up"],
    ["downArrow", "down"],
    ["leftArrow", "left"],
    ["rightArrow","right"],
    ["pageUp",    keys.pageUp.key_],
    ["pageDown",  keys.pageDown.key_],
    ["home",      keys.home.key_],
    ["end",       keys.end.key_],
]

/**
 * Turns what Ink's `useInput` reports into a `KeyInput`.
 *
 * Special keys are tested first, because Ink gives an empty `input` for them.
 * A Ctrl combination arrives as one event, the letter in `input` and
 * `key.ctrl` true, so it becomes `KeyInput(letter, true)`.
 *
 * @param input - the first argument of the `useInput` callback, the typed text.
 * @param key - the second argument of the `useInput` callback, Ink's flags.
 * @returns the press as a `KeyInput`.
 */
export function keyPress(input: string, key: InkKey): KeyInput {

    // non alpha-numeric key presses
    for (const [flag, name] of namedKeys) {
        if (key[flag]) return new KeyInput(name, false, "", key.shift === true)
    }

    // alpha-numeric key presses; a capital letter is a Shift press
    if (key.ctrl) return new KeyInput(input.toLowerCase(), true)
    return new KeyInput(input.toLowerCase(), false, input, input !== input.toLowerCase())
}

/**
 * The taskbar items of the project menu: what each is called and the key that does it.
 * A screen passes an item to the menu only when it applies (see `GridMenu`), so the
 * label and the key are written here once.
 */
export const taskbarKeys = {
    run: { label: "run", key: keys.runKey },
    notes: { label: "notes", key: keys.notesList },
} as const

// ========================================================================================
// 3. The key hook
// ========================================================================================

/**
 * Handles the key presses of a screen or of a part of one (a prompt, a dropdown).
 *
 * Ink calls every mounted `useInput`, so a handler must say when it is not the one
 * to listen: a screen below another one never listens, and a screen with a prompt
 * open passes `active = false` for its own handler while the prompt's is on.
 *
 * @param handler - called with each press as a [[KeyInput]].
 * @param active - whether this handler is the one that listens, `true` when left out.
 */
export function useKeys(handler: (press: KeyInput) => void, active: boolean = true): void {
    const onTop = useScreenActive()
    useInput((input, key) => handler(keyPress(input, key)), { isActive: active && onTop })
}

// ========================================================================================
// 4. Layout: the terminal size and the room the screens get
// ========================================================================================

/**
 * The layout adapts to the terminal: nothing has a fixed width or height, text wraps
 * and lists scroll. Only a minimum is asked for, below which a screen says so instead
 * of drawing itself badly.
 */

/** The narrowest terminal the screens are laid out for, in columns. */
export const minColumns = 80

/** The shortest terminal the screens are laid out for, in rows. */
export const minRows = 24

/** The terminal's size, read once by [[NavProvider]] and shared by every screen. */
const SizeContext = createContext<{ columns: number; rows: number }>({
    columns: minColumns,
    rows: minRows,
})

/**
 * The terminal's columns and rows (one shared listener, see [[NavProvider]]).
 *
 * @returns the size; the smallest supported one outside a provider.
 */
export function useTerminalSize(): { columns: number; rows: number } {
    return useContext(SizeContext)
}

/**
 * The rows that every screen keeps for itself: its title, the keys at the bottom
 * (the logo's three lines and a note line) and the theme line, with a little to spare.
 */
const frameRows = 10

/**
 * The rows a list or table body may use on the current terminal.
 *
 * @param extra - rows the screen uses besides the frame (a table header, a status line).
 * @returns the rows left, at least 3 so a list never vanishes.
 */
export function useBodyRows(extra: number = 0): number {
    const { rows } = useTerminalSize()
    return Math.max(3, rows - frameRows - extra)
}

/**
 * The columns a screen's body may use.
 *
 * @returns the width of the terminal less the frame's side padding, at least
 *     `minColumns - 2`.
 */
export function useBodyColumns(): number {
    const { columns } = useTerminalSize()
    const narrowed = useContext(NarrowWidth)
    return narrowed ?? Math.max(minColumns, columns) - 2
}

/**
 * The width a box inside the body really has, when it is narrower than the body (the
 * panel of an open dropdown is half as wide): [[useBodyColumns]] answers with it, so a
 * list pads and truncates its rows to the panel and never wraps them.
 */
export const NarrowWidth = createContext<number | undefined>(undefined)

/** The rows the app keeps under every screen for the theme line (`theme (^t): ...`). */
export const themeLineRows = 1

// ========================================================================================
// 5. Scroll window
// ========================================================================================

// The one place that decides which rows of a long list are drawn: the cursor of a table,
// the suggestions under an input, the blocks of a settings sheet and the picker all ask
// here, so they scroll the same way.

/**
 * Keeps a window of `size` rows inside a list of `count` rows.
 *
 * @param first - the wanted first row.
 * @param size - how many rows fit, at least 1.
 * @param count - how many rows the list has.
 * @returns `first` moved to between 0 and `count - size` (0 for a short list).
 */
export function clampWindow(first: number, size: number, count: number): number {
    return Math.min(Math.max(first, 0), Math.max(0, count - size))
}

/**
 * The first row of a window that has to show `selected`, moving as little as possible
 * from where the window was; rows may differ in height, so how many rows fit from a
 * first row is a function.
 *
 * @param top - the first row shown now.
 * @param selected - the row that must be in view.
 * @param fitting - how many rows fit when the window starts at the given row.
 * @returns the old `top` if it already shows `selected`, else the smallest top that does.
 */
export function scrollTo(
    top: number,
    selected: number,
    fitting: (first: number) => number,
): number {
    let first = Math.min(top, selected)
    while (first < selected && first + fitting(first) <= selected) first++
    return first
}

/**
 * The first row of a window of equal rows that shows `cursor`, moving as little as
 * possible from where the window was (a list the cursor walks along).
 *
 * @param cursor - the row that must be in view.
 * @param offset - the first row shown now.
 * @param size - how many rows fit, at least 1 (a smaller size is taken as 1).
 * @param count - how many rows there are.
 * @returns the new first row, between 0 and `count - size`.
 */
export function scrollWindow(
    cursor: number,
    offset: number,
    size: number,
    count: number,
): number {
    const room = Math.max(1, size)
    return Math.max(0, scrollTo(clampWindow(offset, room, count), cursor, () => room))
}

/**
 * The first row of a window that has `highlight` in its middle (a list that is
 * redrawn around the highlight, with no memory of where it was).
 *
 * @param count - how many items there are.
 * @param highlight - the index of the highlighted item.
 * @param lines - how many items fit.
 * @returns the index of the first item to show.
 */
export function centredWindow(count: number, highlight: number, lines: number): number {
    return clampWindow(highlight - Math.floor(lines / 2), lines, count)
}

/**
 * The highlight of a list one step up or down.
 *
 * @param index - the highlighted item now.
 * @param count - how many items there are; 0 keeps the highlight on 0.
 * @param down - `true` for down, `false` for up.
 * @param wrap - whether a step past an end goes round to the other end; else it stops.
 * @returns the new index, between 0 and `count - 1`.
 */
export function stepIndex(
    index: number,
    count: number,
    down: boolean,
    wrap: boolean = false,
): number {
    if (count <= 0) return 0
    if (wrap) return (index + (down ? 1 : count - 1)) % count
    return clampIndex(index + (down ? 1 : -1), count)
}

// ========================================================================================
// 6. useListCursor
// ========================================================================================

/**
 * The cursor of a list that scrolls: which row it is on and which row is the first
 * one shown.
 *
 * @property index - the row the cursor is on.
 * @property offset - the first row shown, so `index` is always in view.
 * @property move - moves the cursor by some rows (negative is up), stopping at the ends.
 * @property set - puts the cursor on a row.
 */
export type ListCursor = {
    index:  number
    offset: number
    move:   (delta: number) => void
    set:    (index: number) => void
}

/**
 * Keeps a cursor on a list of `count` rows of which `pageSize` fit. When the list
 * shrinks (a row was removed) or the terminal does, the cursor and the window are
 * kept inside it, so nothing is ever drawn from beyond the end.
 *
 * @param count - how many rows the list has.
 * @param pageSize - how many rows fit on the screen, at least 1.
 * @param initial - the row the cursor starts on, the first when left out.
 * @returns the [[ListCursor]].
 */
export function useListCursor(
    count: number,
    pageSize: number,
    initial: number = 0,
): ListCursor {
    const [state, setState] = useState({ index: initial, offset: 0 })

    // clamp on read: the list may have shrunk since the state was set
    const index = Math.min(state.index, Math.max(0, count - 1))
    const offset = scrollWindow(index, state.offset, pageSize, count)

    const set = useCallback((i: number) => {
        setState((s) => ({ ...s, index: clampWindow(i, 1, count), offset }))
    }, [count, offset])

    const move = useCallback((delta: number) => set(index + delta), [set, index])

    return { index, offset, move, set }
}

// ========================================================================================
// 7. CursorList
// ========================================================================================

/**
 * The text of one row of a [[CursorList]]: the foreground colour and bold on the row the
 * cursor is on, muted otherwise. A row that mixes cells (a logo, a swatch) uses it for
 * the part that is text.
 *
 * @param props.on - whether the cursor is on the row.
 * @param props.children - the text.
 * @returns the text.
 */
export function ListText(
    { on, children }: { on: boolean; children?: ReactNode },
): ReactNode {
    const theme = useTheme()
    return (
        <Text color={on ? theme.fg : theme.mt} bold={on}>
            {children}
        </Text>
    )
}

/**
 * The one list with a cursor of the program: a `>` before the row the cursor is on, the
 * rows from `offset` on, `lines` of them, each drawn by `row`. The suggestions under an
 * input, the theme picker, the settings pickers and the options of the landing pages are
 * all this list; they differ in what a row looks like and in who owns the cursor (a
 * [[useListCursor]], or a highlight that scrolls with a centred window).
 *
 * @typeParam T - what a row is made from.
 * @param props.items - every row of the list.
 * @param props.index - the row the cursor is on.
 * @param props.offset - the first row shown (see the scroll window section above).
 * @param props.lines - the most rows shown.
 * @param props.row - draws one row after its marker; `on` is whether the cursor is on it
 *     and the list is active.
 * @param props.heading - the text of a row that is only a heading (`-- light themes --`:
 *     muted, no marker, never `on`; the owner of the cursor must skip it), `undefined`
 *     for a row `row` draws.
 * @param props.active - `false` while the list is shown but not driving (a dropdown is
 *     open under it): the marker stays on its row, but every row is muted. `true` when
 *     left out.
 * @returns the rows.
 */
export function CursorList<T>(props: {
    items:    readonly T[]
    index:    number
    offset:   number
    lines:    number
    row:      (item: T, on: boolean) => ReactNode
    heading?: (item: T) => string | undefined
    active?:  boolean
}): ReactNode {
    const { items, index, offset, lines, row, heading, active = true } = props
    const theme = useTheme()
    return (
        <Box flexDirection="column">
            {items.slice(offset, offset + lines).map((item, i) => {
                const at = offset + i
                const title = heading?.(item)
                if (title !== undefined)
                    return <Text key={at} color={theme.mt}>{title}</Text>
                const here = at === index
                const on = here && active
                return (
                    <Box key={at} columnGap={1}>
                        <Text color={on ? theme.fg : theme.mt} bold={on}>
                            {here ? ">" : " "}
                        </Text>
                        {row(item, on)}
                    </Box>
                )
            })}
        </Box>
    )
}

// ========================================================================================
// 8. Swatch
// ========================================================================================

/** The cells a [[Swatch]] takes; a caller that wants a gap after it adds its own. */
export const swatchCells = 2

/**
 * A colour swatch: two cells filled with a colour, so a row shows what a colour (or a
 * theme) looks like. It is a `Text`, so it can stand in a row of its own or inside a
 * longer `Text`.
 *
 * @param props.colour - the colour as `#rrggbb`; blank cells of the same width when
 *     `undefined`, so a column of swatches stays aligned.
 * @returns the swatch.
 */
export function Swatch({ colour }: { colour?: string }): ReactNode {
    return <Text backgroundColor={colour}>{" ".repeat(swatchCells)}</Text>
}

// ========================================================================================
// 9. `ChoiceTabs`: a one-line row of on/off tabs
// ========================================================================================

/**
 * One tab of a [[ChoiceTabs]] row as text: `[pdf]` when the choice is on, `(pdf)` when
 * it is off, the tab in focus in capitals.
 *
 * @param option - the choice.
 * @param on - whether it is on.
 * @param focused - whether it is the tab in focus.
 * @returns the text.
 */
export function tabLabel(option: string, on: boolean, focused: boolean): string {
    const label = focused ? option.toUpperCase() : option
    return on ? `[${label}]` : `(${label})`
}

/**
 * A one-line row of tabs for a choice of a few options, each on or off. It only draws:
 * the screen moves the focus and toggles (the figure formats of the output sheet, the
 * units of q on the data screen).
 *
 * @param props.options - every choice, in order.
 * @param props.selected - the choices that are on.
 * @param props.focus - the index of the tab in focus; none when left out.
 * @returns the row, the tab in focus bold, the ones that are off muted.
 */
export function ChoiceTabs(props: {
    options: readonly string[]
    selected: ReadonlySet<string>
    focus?: number
}): ReactNode {
    const { options, selected, focus } = props
    const theme = useTheme()
    return (
        <Box columnGap={1}>
            {options.map((option, i) => {
                const on = selected.has(option)
                return (
                    <Text key={option} bold={i === focus} color={on ? theme.fg : theme.mt}>
                        {tabLabel(option, on, i === focus)}
                    </Text>
                )
            })}
        </Box>
    )
}
