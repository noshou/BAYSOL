// SPDX-License-Identifier: LGPL-3.0-or-later

// Native files inside the single executable. A program or a native Node addon cannot run
// from the executable's own bytes, so the build stores each one as an asset
// (`native/<name>`), and the first use writes it into the cache folder, where it runs from.
// A file already there with the right size is reused, so the cost is paid once per version.

import { chmodSync, existsSync, mkdirSync, renameSync, statSync, writeFileSync } from "node:fs"
import { basename, join } from "node:path"
import { getRawAsset, isSea } from "node:sea"
import { cacheDir, version } from "./environment.js"

/** Whether the program runs from the single executable (the natives are then assets). */
export const inSingleExecutable = (): boolean => isSea()

/**
 * The path of a native asset on disk, written into the cache folder the first time.
 *
 * @param key - the asset key, `native/<file name>`.
 * @returns the absolute path of the extracted file (executable bit set).
 * @throws Error if the program is not the single executable or has no such asset.
 */
export function extractNativeAsset(key: string): string {
    if (!isSea()) throw new Error(`${key}: not running from the single executable`)
    const bytes = new Uint8Array(getRawAsset(key))
    const dir = join(cacheDir(), "native", version.replace(/[^\w.-]+/g, "_"))
    const target = join(dir, basename(key))
    if (existsSync(target) && statSync(target).size === bytes.length) return target
    mkdirSync(dir, { recursive: true })
    const temporary = `${target}.${process.pid}.tmp`
    writeFileSync(temporary, bytes)
    chmodSync(temporary, 0o755)
    renameSync(temporary, target)
    return target
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
