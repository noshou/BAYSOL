// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import {
    isDict,
    isFile,
    quarantine,
    readJson,
    writeAtomic,
    writeJson,
} from "../core/files.js"

/**
 * The theme the user last left the program in, kept as one global preference so the
 * next start opens in it. The file is `theme.json` in the BAYSOL folder:
 * `{ "theme": "graphite" }`, the name of the theme. The store knows no themes (the app
 * passes the names that exist), and it is only a preference: a missing or unusable
 * file means the default, and nothing about it may ever stop the program.
 */

/** The name of the file, defined here once. */
const themeFileName = "theme.json"

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
 * Reads the saved theme name.
 *
 * @param dir - the BAYSOL folder.
 * @param known - the names of the themes that exist.
 * @param fallback - the name to give when nothing usable is saved (the default theme).
 * @returns the saved name; `fallback` when there is no file, it cannot be read, or it
 *     names a theme that is not in `known` (one removed since).
 */
export function readThemeName(
    dir: string,
    known: readonly string[],
    fallback: string,
): string {
    const file = themeFile(dir)
    if (!isFile(file)) return fallback
    const saved = readJson<undefined>(file, undefined)
    const name = isDict(saved) ? saved.theme : undefined
    return typeof name === "string" && known.includes(name) ? name : fallback
}

/**
 * Saves the theme name. A file that exists but cannot be used is kept as
 * `theme.json.corrupt` first, so it is never written over.
 *
 * @param dir - the BAYSOL folder.
 * @param name - the name of the theme to remember.
 * @returns `true` if it was saved; `false` if the folder cannot be written (a
 *     preference that cannot be kept is not an error worth stopping for).
 */
export function writeThemeName(dir: string, name: string): boolean {
    const file = themeFile(dir)
    try {
        if (isFile(file) && !isDict(readJson<undefined>(file, undefined))) quarantine(file)
        writeAtomic(file, writeJson({ theme: name }))
        return true
    } catch {
        return false
    }
}
