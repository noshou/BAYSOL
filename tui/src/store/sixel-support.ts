// SPDX-License-Identifier: LGPL-3.0-or-later

// What the terminal can draw, kept for the whole program: `main.tsx` asks the terminal once
// (`detectSixel`, before Ink takes the keyboard) and stores the verdict here; the viewer
// reads it. Until something is stored the verdict is "unsupported", so Unicode plots are
// the default of everything that has not asked (tests, `--view` without a terminal, ...).

import type { SixelSupport } from "./sixel-types.js"

/** The verdict before the terminal was asked. */
const UNASKED: SixelSupport = { supported: false, reason: "not asked" }

let verdict: SixelSupport = UNASKED

/**
 * Stores the terminal's verdict (called once at start-up).
 *
 * @param support - what `detectSixel` answered.
 */
export function setSixelSupport(support: SixelSupport): void {
    verdict = support
}

/** @returns the stored verdict: unsupported until [[setSixelSupport]] was called. */
export function getSixelSupport(): SixelSupport {
    return verdict
}
