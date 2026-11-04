// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync }  from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { KeyInput }      from "./keys.js"

const assets: string = join(dirname(fileURLToPath(import.meta.url)), "..", "assets")

// define menuOptions to be the strict constants below
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

// define allowed names as the keys of menu_options
export type MenuOptionNames = keyof typeof menuOptions

export type MenuOption = {
    name:   MenuOptionNames
    hotkey: KeyInput
    text:   string
    width:  number
    height: number
}

/**
 * Loads one menu option, the art piece of an item of a menu, from
 * `assets/menu-options/<name>-<type>.txt`.
 *
 * @param type - `"reg"` for the regular piece, `"bold"` for the selected one.
 * @param name - the option, one of the keys of `menu_options`.
 * @returns the option with its hotkey, its text, and its size in terminal cells
 *     (`width` is the longest line, `height` the number of lines).
 * @throws if the file `<name>-<type>.txt` does not exist or cannot be read.
 */
export function loadOpts(type: "reg" | "bold", name: MenuOptionNames): MenuOption {
    // load the text of the option
    const file = `${name}-${type}.txt`
    const text = readFileSync(join(assets, "menu-options", file), "utf-8")

    // the size of the piece in terminal cells
    const lines = text.split("\n")
    return {
        name,
        hotkey: menuOptions[name].hotkey,
        text,
        width: Math.max(...lines.map((line) => line.length)),
        height: lines.length,
    }
}

/** returns the menuCursor (width=3, height=3) */
export function menuCursor(): string {
    return readFileSync(join(assets, "menu-options", "cursor.txt"), "utf-8")
}

/** returns the menu logo (width=47, height=3)*/
export function menuLogo(): string {
    return readFileSync(join(assets, "logo", "logo-large.txt"), "utf-8")
}
