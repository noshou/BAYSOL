// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync } from "node:fs"
import { assetPath }    from "../core/assets.js"
import { KeyInput }     from "./keys.js"

/**
 * Every menu option and its hotkey. Its keys are the allowed option names
 * ([[MenuOptions]]), and each name must have a `<name>.txt` in
 * `assets/menu-options/`.
 */
const menuOptions = {
    buffer:   { hotkey: new KeyInput("b") },
    data:     { hotkey: new KeyInput("d") },
    help:     { hotkey: new KeyInput("h") },
    load:     { hotkey: new KeyInput("l") },
    logs:     { hotkey: new KeyInput("g") },
    models:   { hotkey: new KeyInput("m") },
    new:      { hotkey: new KeyInput("n") },
    open:     { hotkey: new KeyInput("o") },
    output:   { hotkey: new KeyInput("u") },
    plots:    { hotkey: new KeyInput("p") },
    quit:     { hotkey: new KeyInput("q") },
    run:      { hotkey: new KeyInput("r") },
    sampler:  { hotkey: new KeyInput("a") },
    settings: { hotkey: new KeyInput("s") },
} as const satisfies Record<string, { hotkey: KeyInput }>

/** The name of a menu option: one of the keys of `menuOptions`. */
export type MenuOptions = keyof typeof menuOptions

/** An art piece: its text and its size in terminal cells. */
export type Art = {
    text:   string
    width:  number
    height: number
}

/**
 * One loaded menu option: its art piece (`text`, `width`, `height`) and the
 * hotkey that selects it. The selected state is drawn with the theme's colours,
 * not with a second piece of art.
 *
 * @property hotkey - the key that selects the option.
 */
export type MenuOption = Art & {
    hotkey: KeyInput
}

/**
 * Reads an art piece from a file below `assets/` and measures it.
 *
 * @param path - the folders and the file name below `assets/`, one string each,
 *     e.g. `"logo", "logo-large.txt"`.
 * @returns the text, and its size in terminal cells (`width` is the longest line,
 *     `height` the number of lines).
 * @throws if the file does not exist or cannot be read.
 */
function loadArt(...path: string[]): Art {
    const text = readFileSync(assetPath(...path), "utf-8")
    const lines = text.split("\n")
    return {
        text,
        width: Math.max(...lines.map((line) => line.length)),
        height: lines.length,
    }
}

/**
 * Loads menu options, each with its art piece, from
 * `assets/menu-options/<name>.txt`.
 *
 * Call it once, at module level: it reads the files from disk each time.
 *
 * @param names - the options to load.
 * @returns a record with exactly the given names as keys, each mapping to its
 *     [[MenuOption]]: its art with its size, and its hotkey. A name that was not
 *     passed is a type error to look up, and a passed one is never `undefined`.
 * @throws if a file cannot be read.
 */
export function loadOpts<N extends MenuOptions>(
    names: readonly N[]
): Record<N, MenuOption> {
    // starts empty and is filled below, so the cast says "complete by the return"
    const result = {} as Record<N, MenuOption>
    for (const name of names) {
        result[name] = {
            ...loadArt("menu-options", `${name}.txt`),
            hotkey: menuOptions[name].hotkey,
        }
    }
    return result
}

/**
 * The grid shapes that have move hints, and how many positions each has.
 * Each shape needs `assets/menu-arrows/(<shape>)-pos1.txt` to `-pos<n>.txt`.
 */
const arrowLayouts = { "2x2": 4, "2x3": 6 } as const

/** A grid shape with move hints: `"2x2"` or `"2x3"`. */
export type ArrowLayout = keyof typeof arrowLayouts

/**
 * Loads the move hints of a grid shape, one art piece per position of the grid.
 *
 * The pieces show which arrows are possible from a position, e.g. the first
 * position of a 2x3 grid has a right and a down arrow. Positions count from the
 * top-left, one row at a time, so `pos1` is the first element of the array.
 *
 * Call it once, at module level: it reads the files from disk each time.
 *
 * @param layout - the grid shape, `"2x2"` or `"2x3"`.
 * @returns the pieces in order, `pos1` first: 4 for `"2x2"`, 6 for `"2x3"`.
 * @throws if a file `assets/menu-arrows/(<layout>)-pos<n>.txt` cannot be read.
 */
export function menuArrows(layout: ArrowLayout): Art[] {
    return Array.from({ length: arrowLayouts[layout] }, (_, i) =>
        loadArt("menu-arrows", `(${layout})-pos${i + 1}.txt`)
    )
}

/**
 * Loads the cursor drawn beside the selected menu item.
 *
 * @returns the cursor art with its size in terminal cells.
 * @throws if `assets/menu-options/cursor.txt` cannot be read.
 */
export function menuCursor(): Art { return loadArt("menu-options", "cursor.txt") }

/**
 * Loads the logo shown at the top of the menu.
 *
 * @returns the logo art with its size in terminal cells.
 * @throws if `assets/logo/logo-large.txt` cannot be read.
 */
export function menuLogo(): Art { return loadArt("logo", "logo-large.txt") }

/**
 * The small BAYSOL logos that sit at the bottom left of the screens below the menus:
 * `blocky` (square corners) on the screens drawn with double lines, the tables, forms
 * and settings sheets; `smooth` (rounded corners) on the rounded landing pages.
 */
export type SmallLogo = "blocky" | "smooth"

/**
 * Loads a small logo.
 *
 * @param kind - `"blocky"` or `"smooth"`.
 * @returns the logo art with its size in terminal cells.
 * @throws if `assets/logo/logo-<kind>.txt` cannot be read.
 */
export function smallLogo(kind: SmallLogo): Art { return loadArt("logo", `logo-${kind}.txt`) }
