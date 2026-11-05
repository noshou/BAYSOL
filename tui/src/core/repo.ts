// SPDX-License-Identifier: LGPL-3.0-or-later

import { existsSync, readFileSync } from "node:fs"
import { dirname, join, parse } from "node:path"
import { fileURLToPath } from "node:url"

/**
 * Where the BAYSOL package (the folder with its `Project.toml`) is, when the program
 * runs from a checkout. A packaged program has no such folder, so every lookup here
 * can say "not found", and nothing may depend on it being found.
 */

/** The environment variable that names the BAYSOL package folder, for a layout we did not foresee. */
export const repoVar = "BAYSOL_ROOT"

/**
 * Whether a folder holds the `Project.toml` of the package BAYSOL.
 *
 * @param dir - the folder.
 * @returns `true` if `<dir>/Project.toml` exists and names the package `BAYSOL`.
 */
function isRepo(dir: string): boolean {
    const file = join(dir, "Project.toml")
    if (!existsSync(file)) return false
    return /^name\s*=\s*"BAYSOL"/m.test(readFileSync(file, "utf-8"))
}

/**
 * The folders to look in, best first: the one `BAYSOL_ROOT` names, then the parents of
 * this source file (the checkout the program runs from), then the working directory and
 * each of its parents.
 *
 * @param env - the environment variables.
 * @param cwd - the working directory.
 * @returns the candidates, without repeats.
 */
export function repoCandidates(env: Record<string, string | undefined>, cwd: string): string[] {
    const found: string[] = []
    const add = (dir: string | undefined) => {
        if (dir && !found.includes(dir)) found.push(dir)
    }
    add(env[repoVar])
    const source = dirname(fileURLToPath(import.meta.url))
    for (let d = source; ; d = dirname(d)) {
        add(d)
        if (parse(d).root === d) break
    }
    for (let d = cwd; ; d = dirname(d)) {
        add(d)
        if (parse(d).root === d) break
    }
    return found
}

/**
 * The BAYSOL package folder.
 *
 * @param env - the environment variables, `process.env` when left out.
 * @param cwd - the working directory, `process.cwd()` when left out.
 * @returns the first candidate that holds the package's `Project.toml`, or `undefined`
 *     (a packaged program).
 */
export function repoRoot(
    env: Record<string, string | undefined> = process.env,
    cwd: string = process.cwd()
): string | undefined {
    return repoCandidates(env, cwd).find(isRepo)
}
