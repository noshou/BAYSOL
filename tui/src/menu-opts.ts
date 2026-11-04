// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const assets: string = join(dirname(fileURLToPath(import.meta.url)), "..", "assets");

// define option_names to be the strict constants below
const menu_options = {
    buffer:   { hotkey: "b" },
    data:     { hotkey: "d" },
    help:     { hotkey: "h" },
    load:     { hotkey: "l" },
    logs:     { hotkey: "g" },
    models:   { hotkey: "m" },
    new:      { hotkey: "n" },
    open:     { hotkey: "o" },
    output:   { hotkey: "u" },
    plots:    { hotkey: "p" },
    quit:     { hotkey: "escape" },
    run:      { hotkey: "r" },
    sampler:  { hotkey: "a" },
    settings: { hotkey: "s" },
} as const;

// define allowed names as the keys of menu_options
export type OptionNames = keyof typeof menu_options;

export type MenuOption = {
    name: OptionNames;
    hotkey: string;
    text: string;
    width: number;
    height: number;
};

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
export function load_opts(type: "reg" | "bold", name: OptionNames): MenuOption {
    // load the text of the option
    const file = `${name}-${type}.txt`;
    const text = readFileSync(join(assets, "menu-options", file), "utf-8");

    // the size of the piece in terminal cells
    const lines = text.split("\n");
    return {
        name,
        hotkey: menu_options[name].hotkey,
        text,
        width: Math.max(...lines.map((line) => line.length)),
        height: lines.length,
    };
}
