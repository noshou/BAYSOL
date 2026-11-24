// SPDX-License-Identifier: LGPL-3.0-or-later

// Native files inside the single executable. A program or a native Node addon cannot run
// from the executable's own bytes, so the build stores each one as an asset
// (`native/<name>`), and the first use writes it to disk, where it runs from.
//
// They go in ONE folder of the cache, `<cache>/native/` (not a temporary folder: many Linux
// systems mount `/tmp` noexec), never in a folder per version, so old releases leave
// nothing behind. A stamp file written last (`.version`: the version and the size of each
// file) says which version's files are there. A different version, or a missing or
// unreadable stamp, empties the folder and extracts again, so at most one version's files
// exist. If the folder cannot be emptied or written (Windows refuses to delete a loaded
// `.node`, `.dll` or `.exe`: another copy of the program is running; a read-only cache) the
// cache is left as it is and the file goes to this process's temporary folder instead
// (`<tmp>/baysol/<pid>/native`, removed with the rest at exit).

import {
    chmodSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    renameSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { basename, join } from "node:path"
import { getRawAsset, isSea } from "node:sea"
import { cacheDir, version } from "./environment.js"
import { scratchFolder } from "./scratch.js"

/** Whether the program runs from the single executable (the natives are then assets). */
export const inSingleExecutable = (): boolean => isSea()

/** The name of the stamp file inside the native folder. */
const STAMP = ".version"

/** What the stamp holds: the version and the size of each extracted file. */
type Stamp = { version: string; files: Record<string, number> }

/** Reads the stamp; `undefined` if it is missing or not a stamp. */
function readStamp(dir: string): Stamp | undefined {
    try {
        const stamp = JSON.parse(readFileSync(join(dir, STAMP), "utf-8")) as Stamp
        if (
            typeof stamp.version !== "string" ||
            typeof stamp.files !== "object" ||
            stamp.files === null
        )
            return undefined
        return stamp
    } catch {
        return undefined
    }
}

/** Writes a file through a uniquely named neighbour renamed into place. */
function writeAtomic(target: string, bytes: Uint8Array | string, mode?: number): void {
    const temporary = `${target}.${process.pid}.tmp`
    try {
        writeFileSync(temporary, bytes)
        if (mode !== undefined) chmodSync(temporary, mode)
        renameSync(temporary, target)
    } finally {
        rmSync(temporary, { force: true })
    }
}

/**
 * Puts one native file in the cache's native folder, keeping that folder to one version.
 *
 * @param dir - the native folder (`<cache>/native`).
 * @param name - the file name.
 * @param bytes - the file.
 * @param current - the version of this program.
 * @param remove - removes one entry of the folder (replaceable to simulate a locked file).
 * @returns the path of the file.
 * @throws if the folder cannot be emptied or written.
 */
export function placeInCache(
    dir: string,
    name: string,
    bytes: Uint8Array,
    current: string,
    remove: (path: string) => void = (path) =>
        rmSync(path, { recursive: true, force: true }),
): string {
    const target = join(dir, name)
    let stamp = readStamp(dir)
    if (
        stamp !== undefined &&
        stamp.version === current &&
        stamp.files[name] === bytes.length
    ) {
        try {
            if (statSync(target).size === bytes.length) return target
        } catch {
            // gone: extracted again below
        }
    }
    mkdirSync(dir, { recursive: true })
    if (stamp === undefined || stamp.version !== current) {
        // another version, or no usable stamp: nothing of it stays
        for (const entry of readdirSync(dir)) remove(join(dir, entry))
        stamp = { version: current, files: {} }
    }
    writeAtomic(target, bytes, 0o755)
    stamp.files[name] = bytes.length
    writeAtomic(join(dir, STAMP), JSON.stringify(stamp))
    return target
}

/**
 * Puts one native file in a plain folder (the temporary fallback), replacing a file there.
 */
function placeIn(dir: string, name: string, bytes: Uint8Array): string {
    const target = join(dir, name)
    try {
        if (statSync(target).size === bytes.length) return target
    } catch {
        // not there yet
    }
    mkdirSync(dir, { recursive: true })
    writeAtomic(target, bytes, 0o755)
    return target
}

/**
 * The path of a native asset on disk, written the first time (see the top of this file).
 *
 * @param key - the asset key, `native/<file name>`.
 * @returns the absolute path of the extracted file (executable bit set).
 * @throws Error if the program is not the single executable or has no such asset.
 */
export function extractNativeAsset(key: string): string {
    if (!isSea()) throw new Error(`${key}: not running from the single executable`)
    const bytes = new Uint8Array(getRawAsset(key))
    return placeNative(
        () => join(cacheDir(), "native"),
        () => scratchFolder("native"),
        basename(key),
        bytes,
        version,
    )
}

/**
 * [[placeInCache]], and when that fails, a plain folder of this process's temporary files.
 * The cache is never touched by the fallback, and no second copy goes in it.
 *
 * @param cache - the native folder of the cache (asked for lazily: the cache may be
 *     unusable).
 * @param fallback - the temporary folder (asked for only when needed).
 */
export function placeNative(
    cache: () => string,
    fallback: () => string,
    name: string,
    bytes: Uint8Array,
    current: string,
    remove?: (path: string) => void,
): string {
    try {
        return placeInCache(cache(), name, bytes, current, remove)
    } catch {
        return placeIn(fallback(), name, bytes)
    }
}

/**
 * Loads a native Node addon from a file and returns its exports.
 *
 * @param file - the path of the `.node` file.
 */
export function loadNativeAddon(file: string): Record<string, unknown> {
    const holder: { exports: Record<string, unknown> } = { exports: {} }
    process.dlopen(holder, file)
    return holder.exports
}
