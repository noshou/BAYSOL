// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import { isDict, isFile, quarantine, readJson, writeAtomic, writeJson } from "../core/files.js"

/**
 * The theme the user last left the program in, kept as one global preference so the
 * next start opens in it. The file is `theme.json` in the BAYSOL folder:
 * `{ "mode": "dark" }`. It is only a preference: a missing or unusable file means the
 * default, and nothing about it may ever stop the program.
 */

/** The two themes. */
export type ThemeMode = "light" | "dark"

/** The theme of a first start. */
export const defaultThemeMode: ThemeMode = "dark"

/** The name of the file, defined here once. */
export const themeFileName = "theme.json"

/**
 * The path of the theme file.
 *
 * @param dir - the BAYSOL folder.
 * @returns `<dir>/theme.json`.
 */
export function themeFile(dir: string): string {
    return join(dir, themeFileName)
}

/**
 * Reads the saved theme.
 *
 * @param dir - the BAYSOL folder.
 * @returns the saved mode; [[defaultThemeMode]] when there is no file, it cannot be
 *     read, or it does not say `"light"` or `"dark"`.
 */
export function readThemeMode(dir: string): ThemeMode {
    const file = themeFile(dir)
    if (!isFile(file)) return defaultThemeMode
    const saved = readJson<undefined>(file, undefined)
    const mode = isDict(saved) ? saved.mode : undefined
    return mode === "light" || mode === "dark" ? mode : defaultThemeMode
}

/**
 * Saves the theme. A file that exists but cannot be used is kept as
 * `theme.json.corrupt` first, so it is never written over.
 *
 * @param dir - the BAYSOL folder.
 * @param mode - the theme to remember.
 * @returns `true` if it was saved; `false` if the folder cannot be written (a
 *     preference that cannot be kept is not an error worth stopping for).
 */
export function writeThemeMode(dir: string, mode: ThemeMode): boolean {
    const file = themeFile(dir)
    try {
        if (isFile(file) && !isDict(readJson<undefined>(file, undefined))) quarantine(file)
        writeAtomic(file, writeJson({ mode }))
        return true
    } catch {
        return false
    }
}
