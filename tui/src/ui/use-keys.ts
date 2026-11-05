// SPDX-License-Identifier: LGPL-3.0-or-later

import { useInput } from "ink"
import { type KeyInput, keyPress } from "./keys.js"
import { useScreenActive } from "./nav.js"

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
