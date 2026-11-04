// SPDX-License-Identifier: LGPL-3.0-or-later

import type {Key as InkKey } from "ink"

/**
 * One key press: the name of the key, and whether Ctrl was held.
 *
 * The name is the typed character in lower case (`"n"`), or one of `"escape"`,
 * `"return"`, `"up"`, `"down"`, `"left"`, `"right"`. Menu hotkeys are
 * `KeyInput`s too, so a press is matched against a hotkey with `is`.
 *
 * @param key_ - the name of the key.
 * @param ctrl - whether Ctrl was held, `false` when left out.
 */
export class KeyInput {
    constructor(
        readonly key_:  string,
        readonly ctrl:  boolean = false
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
}

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
    if (key.escape    ) return new KeyInput("escape")
    if (key.return    ) return new KeyInput("return")
    if (key.upArrow   ) return new KeyInput("up")
    if (key.downArrow ) return new KeyInput("down")
    if (key.leftArrow ) return new KeyInput("left")
    if (key.rightArrow) return new KeyInput("right")

    // alpha-numeric key presses
    if (key.ctrl) return new KeyInput(input, true)
    return new KeyInput(input.toLocaleLowerCase())
}
