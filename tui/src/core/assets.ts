// SPDX-License-Identifier: LGPL-3.0-or-later

import { existsSync, readFileSync } from "node:fs"
import { dirname, isAbsolute, join } from "node:path"
import { fileURLToPath } from "node:url"

/**
 * Where the program's own files (`assets/`: the art, the harvested data) are. The
 * place depends on how the program is run (a checkout, a bundle, a single executable
 * with its assets beside it), so nothing builds a path to `assets/` itself: it asks
 * here, and this is the one place to change when packaging moves them.
 */

/** The environment variable that names the `assets/` folder, for a layout not foreseen. */
const assetsVar = "BAYSOL_ASSETS"

/**
 * A file every `assets/` folder has; the folder is only accepted when it is there, so
 * a folder that merely has the right name is not mistaken for ours.
 */
const marker = join("data", "default_settings.json")

/**
 * The folders that may be the `assets/` folder, best first: the one `BAYSOL_ASSETS`
 * names; `assets/` beside the running executable (a packaged program); `assets/` of
 * the `tui` folder this source file is in (a checkout); `assets/` in the working
 * directory.
 *
 * @param env - the environment variables.
 * @param execPath - the path of the running executable.
 * @param cwd - the working directory.
 * @returns the candidates, in order, without repeats.
 */
function assetCandidates(
    env: Record<string, string | undefined>,
    execPath: string,
    cwd: string
): string[] {
    const named = (env[assetsVar] ?? "").trim()
    const source = dirname(fileURLToPath(import.meta.url))
    const list = [
        isAbsolute(named) ? named : "",
        join(dirname(execPath), "assets"),
        join(source, "..", "..", "assets"),
        join(cwd, "assets"),
    ]
    return list.filter((dir, i) => dir !== "" && list.indexOf(dir) === i)
}

/** The folder found, kept after the first lookup. */
let found: string | undefined

/**
 * The `assets/` folder.
 *
 * @returns its absolute path (found once, then remembered).
 * @throws if no candidate holds the assets; the message lists where it looked and names
 *     `BAYSOL_ASSETS` as the way out.
 */
function assetsRoot(): string {
    if (found !== undefined) return found
    const tried = assetCandidates(process.env, process.execPath, process.cwd())
    const hit = tried.find((dir) => existsSync(join(dir, marker)))
    if (hit === undefined)
        throw new Error(
            `the assets folder was not found; looked in ${tried.join(", ")}. ` +
            `Set ${assetsVar} to the folder that holds data/default_settings.json.`
        )
    found = hit
    return hit
}

/**
 * The path of a file below `assets/`.
 *
 * @param path - the folders and the file name, one string each.
 * @returns the absolute path.
 * @throws if the assets folder cannot be found ([[assetsRoot]]).
 */
export function assetPath(...path: string[]): string {
    return join(assetsRoot(), ...path)
}

/**
 * Reads a JSON file below `assets/`. The files of `assets/data/` are harvested or
 * hand-written input and are never written by the program.
 *
 * @param path - the folders and the file name, one string each.
 * @returns the parsed value; the caller says what shape it has.
 * @throws if the assets are not found, or the file cannot be read or is not JSON.
 */
export function readAssetJson<T>(...path: string[]): T {
    return JSON.parse(readFileSync(assetPath(...path), "utf-8")) as T
}
