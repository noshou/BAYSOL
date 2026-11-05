// SPDX-License-Identifier: LGPL-3.0-or-later

import {
    type Dirent,
    existsSync,
    lstatSync,
    mkdirSync,
    readdirSync,
    realpathSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { isAbsolute, join, parse, resolve } from "node:path"
import { isMac, isWindows, readSystem, type System } from "./system.js"

/**
 * Where BAYSOL keeps things. What must last (the BAYSOL-wide settings, the projects)
 * lies in the data folder each operating system has for a program; what can be rebuilt
 * (the font list, downloaded and generated structures) goes in the operating system's
 * cache folder instead, so it never piles up among the data of the user. A folder is
 * made the first time it is asked for ([[appDir]], [[projectsDir]], [[cacheDir]]).
 */

/** The environment variable that names the BAYSOL folder instead of the default one. */
const homeVar = "BAYSOL_HOME"

/** The environment variable that names the cache folder; the Julia side reads it too. */
const cacheVar = "BAYSOL_CACHE"

/** The marker file of a cache folder (backup tools skip a folder that has it). */
const cacheTag = "CACHEDIR.TAG"

/** The text of the marker: the signature the freedesktop specification asks for. */
const cacheTagText =
    "Signature: 8a477f597d28d172789f06886806bc55\n" +
    "# This file is a cache directory tag created by BAYSOL.\n" +
    "# It is safe to delete everything in this folder.\n"

/**
 * The folder an environment variable names, if it is usable.
 *
 * @param system - the machine.
 * @param name - the variable.
 * @returns the folder, or `undefined` if the variable is missing, blank or not an
 *     absolute path (the XDG specification says to ignore a relative one).
 */
export function envDir(system: System, name: string): string | undefined {
    const value = (system.env[name] ?? "").trim()
    return value !== "" && isAbsolute(value) ? value : undefined
}

/**
 * The folder in which the operating system keeps the data of a program: Windows
 * `%LOCALAPPDATA%` (else `<home>\AppData\Local`), macOS `<home>/Library/Application
 * Support`, everything else `$XDG_DATA_HOME` (else `~/.local/share`).
 *
 * @param system - the machine.
 * @returns the folder; it need not exist.
 */
export function dataHome(system: System): string {
    if (isWindows(system))
        return envDir(system, "LOCALAPPDATA") ?? join(system.home, "AppData", "Local")
    if (isMac(system)) return join(system.home, "Library", "Application Support")
    return envDir(system, "XDG_DATA_HOME") ?? join(system.home, ".local", "share")
}

/**
 * The folder in which the operating system keeps the caches of a program: Windows
 * `%LOCALAPPDATA%` (else `<home>\AppData\Local`), macOS `<home>/Library/Caches`,
 * everything else `$XDG_CACHE_HOME` (else `~/.cache`).
 *
 * @param system - the machine.
 * @returns the folder; it need not exist.
 */
export function cacheHome(system: System): string {
    if (isWindows(system))
        return envDir(system, "LOCALAPPDATA") ?? join(system.home, "AppData", "Local")
    if (isMac(system)) return join(system.home, "Library", "Caches")
    return envDir(system, "XDG_CACHE_HOME") ?? join(system.home, ".cache")
}

/**
 * The BAYSOL folder: `$BAYSOL_HOME` if that is an absolute path, else `baysol` inside
 * the data folder of the system.
 *
 * @param system - the machine.
 * @returns the folder; it need not exist.
 */
export function appRoot(system: System): string {
    return envDir(system, homeVar) ?? join(dataHome(system), "baysol")
}

/**
 * The cache folder: `$BAYSOL_CACHE` if that is an absolute path, else `baysol/_cache`
 * inside the cache home of the system.
 *
 * @param system - the machine.
 * @returns the folder; it need not exist.
 */
export function cacheRoot(system: System): string {
    return envDir(system, cacheVar) ?? join(cacheHome(system), "baysol", "_cache")
}

/**
 * The projects folder inside a BAYSOL folder.
 *
 * @param root - the BAYSOL folder.
 * @returns `<root>/projects`.
 */
export function projectsRoot(root: string): string {
    return join(root, "projects")
}

/**
 * Makes a folder and any parent it lacks.
 *
 * @param dir - the folder.
 * @returns `dir`.
 * @throws if the folder cannot be made; the message names it.
 */
export function ensureDir(dir: string): string {
    try {
        mkdirSync(dir, { recursive: true })
    } catch (error) {
        throw new Error(`could not make the folder ${dir}: ${(error as Error).message}`)
    }
    if (!statSync(dir).isDirectory()) throw new Error(`${dir} is not a folder`)
    return dir
}

/**
 * Makes a value the first time it is asked for and gives the same one afterwards,
 * so a folder is only made when something needs it.
 *
 * @param make - makes the value.
 * @returns a function that returns the value.
 */
function lazy<T>(make: () => T): () => T {
    let made: { value: T } | undefined
    return () => {
        made ??= { value: make() }
        return made.value
    }
}

/** The BAYSOL folder, made on first use. */
export const appDir: () => string = lazy(() => ensureDir(appRoot(readSystem())))

/** The projects folder, made on first use (the BAYSOL folder first). */
export const projectsDir: () => string = lazy(() => ensureDir(projectsRoot(appDir())))

/**
 * Whether a folder is the default cache folder of a machine, ignoring `BAYSOL_CACHE`.
 *
 * @param system - the machine.
 * @param dir - the folder to test.
 * @returns `true` if `dir` is `baysol/_cache` in the cache home of `system`.
 */
function isDefaultCache(system: System, dir: string): boolean {
    const stock = cacheRoot({ ...system, env: { ...system.env, [cacheVar]: "" } })
    try {
        return realpathSync(stock) === realpathSync(dir)
    } catch {
        return resolve(stock) === resolve(dir)
    }
}

/**
 * Marks a cache folder as BAYSOL's, if it is not marked yet and is either the default
 * cache folder or empty. A folder named by `BAYSOL_CACHE` that already holds other
 * things is never marked, so [[clearCache]] will not empty it.
 *
 * @param system - the machine.
 * @param dir - the cache folder, which must exist.
 * @returns `dir`.
 */
export function tagCache(system: System, dir: string): string {
    const tag = join(dir, cacheTag)
    const empty = readdirSync(dir).length === 0
    if (!existsSync(tag) && (isDefaultCache(system, dir) || empty))
        writeFileSync(tag, cacheTagText, "utf-8")
    return dir
}

/** The cache folder, made (and marked) on first use. */
export const cacheDir: () => string = lazy(() => {
    const system = readSystem()
    return tagCache(system, ensureDir(cacheRoot(system)))
})

/**
 * The bytes the files below a folder take. Symbolic links count as themselves, never
 * as what they point at.
 *
 * @param dir - the folder.
 * @returns the size in bytes; 0 if the folder does not exist.
 */
export function cacheSize(dir: string): number {
    if (!existsSync(dir)) return 0
    let total = 0
    let entries: Dirent[]
    try {
        entries = readdirSync(dir, { withFileTypes: true })
    } catch {
        return 0 // the folder vanished meanwhile
    }
    for (const entry of entries) {
        const path = join(dir, entry.name)
        try {
            total += entry.isDirectory() ? cacheSize(path) : lstatSync(path).size
        } catch {
            // the file vanished between the listing and the stat: it is gone
        }
    }
    return total
}

/**
 * Why a folder must never be emptied as a cache.
 *
 * @param system - the machine.
 * @param dir - the folder.
 * @returns the reason (a filesystem root, the home folder), or `undefined`.
 */
function refusal(system: System, dir: string): string | undefined {
    const path = realpathSync(dir)
    if (parse(path).root === path) return "it is a filesystem root"
    if (path === realpathSync(system.home)) return "it is the home folder"
    return undefined
}

/**
 * Deletes everything inside a cache folder and keeps the folder and its marker.
 * Symbolic links are removed, never followed. Nothing is deleted when the folder is a
 * filesystem root or the home folder, or when it is none of: marked as a cache
 * (`CACHEDIR.TAG`), the default cache folder, empty.
 *
 * @param system - the machine, `readSystem()` when left out.
 * @param dir - the cache folder, [[cacheDir]] when left out.
 * @returns the bytes freed (the marker is not counted); 0 for a missing folder.
 * @throws if the folder is refused, with the reason in the message.
 */
export function clearCache(system: System = readSystem(), dir: string = cacheDir()): number {
    if (!existsSync(dir)) return 0
    const why = refusal(system, dir)
    if (why !== undefined) throw new Error(`refusing to clear the cache folder: ${why}`)
    const marked = existsSync(join(dir, cacheTag))
    if (!marked && readdirSync(dir).length > 0 && !isDefaultCache(system, dir))
        throw new Error(`refusing to clear ${dir}: it is not marked as a BAYSOL cache`)
    const before = cacheSize(dir)
    for (const entry of readdirSync(dir)) {
        if (entry !== cacheTag) rmSync(join(dir, entry), { recursive: true, force: true })
    }
    return before - cacheSize(dir)
}
