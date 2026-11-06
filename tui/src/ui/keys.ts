// SPDX-License-Identifier: LGPL-3.0-or-later

import type { Key as InkKey } from "ink"

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
        if (this.key_ in namedLabels) return namedLabels[this.key_]
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

    /** The taskbar of the project menu: open the results of a finished run (Shift+Y). */
    resultsKey: shiftKey("y"),

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

    /** Pick files with the desktop file picker (an empty field). */
    pickFiles: plainKey("o"),

    /** Open the list of models (an empty field). */
    openList:  plainKey("m"),

    /** Reset an unusable file (a landing page). */
    reset:     plainKey("r"),
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
        if (key[flag]) return new KeyInput(name)
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
    run:     { label: "run",     key: keys.runKey },
    results: { label: "results", key: keys.resultsKey },
} as const
