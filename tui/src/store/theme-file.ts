// SPDX-License-Identifier: LGPL-3.0-or-later

// Theme preference: the one theme name kept in `theme.json` in the BAYSOL folder.

import { join } from "node:path"
import {
    isDict,
    isFile,
    quarantine,
    readJson,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"

// The theme the user last left the program in is `{ "theme": "graphite" }`. The store
// knows no themes (the app passes the names that exist); a missing or unusable file means
// the default and never stops the program.

/** The name of the file, defined here once. */
const themeFileName = "theme.json"

/** The path of the theme file. */
export function themeFile(dir: string): string {
    return join(dir, themeFileName)
}

/**
 * Reads the saved theme name.
 *
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
 * @returns `true` if it was saved; `false` if the folder cannot be written (not worth
 *     stopping for).
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
