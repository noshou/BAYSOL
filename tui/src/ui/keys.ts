// SPDX-License-Identifier: LGPL-3.0-or-later

import type { Key as InkKey } from "ink"

/**
 * One key press: the name of the key, whether Ctrl was held, and the text it typed.
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
 */
export class KeyInput {
    constructor(
        readonly key_:  string,
        readonly ctrl:  boolean = false,
        readonly text:  string  = ""
    ) {}

    /**
     * Compares this press with another.
     *
     * @param key - the press (or hotkey) to compare with.
     * @returns `true` when both have the same name and the same Ctrl state.
     */
    is (key: KeyInput) {
        return key.key_  === this.key_  && key.ctrl  === this.ctrl
    }

    /** `true` when the press typed text (a letter, a digit, a space, a paste). */
    get typed(): boolean {
        return this.text !== "" && !this.ctrl
    }
}

/**
 * Every key the program gives a meaning, in one place so a screen never spells a key
 * itself. Ctrl-M, Ctrl-I, Ctrl-J, Ctrl-B, Ctrl-S, Ctrl-Q, Ctrl-D, Ctrl-C, Ctrl-Z and
 * Ctrl-Y are not usable: terminals send them as Enter, Tab, flow control, or take them.
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

    /** Back one screen, from any mode; never quits. */
    back:   new KeyInput("x", true),
    
    /** Save every change on the screen. */
    save:   new KeyInput("w", true),
    
    /** Undo: a removal mark, else the draft. */
    undo:   new KeyInput("u", true),
    
    /** Remove a table row, or reset a group of settings. */
    remove: new KeyInput("r", true),
    
    /** Switch between the light and the dark theme. */
    theme:  new KeyInput("t", true),

    /** Add a non-biological solute. */
    addNonbio:     new KeyInput("n", true),
    
    /** Add a polymer. */
    addPolymer:    new KeyInput("p", true),
    
    /** Add a protein from a sequence file. */
    addProtein:    new KeyInput("f", true),
    
    /** Add a nucleotide (DNA or RNA) from a sequence file; also the custom landing. */
    addNucleotide: new KeyInput("e", true),
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
    ["pageUp",    "pageup"],
    ["pageDown",  "pagedown"],
    ["home",      "home"],
    ["end",       "end"],
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

    // alpha-numeric key presses
    if (key.ctrl) return new KeyInput(input.toLowerCase(), true)
    return new KeyInput(input.toLowerCase(), false, input)
}
