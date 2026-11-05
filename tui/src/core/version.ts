// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync } from "node:fs"
import { join } from "node:path"
import { parse } from "smol-toml"
import { repoRoot } from "./repo.js"

/**
 * The release name, `v<version> <release_name>`, as the `Project.toml` of BAYSOL
 * spells it (the one place the version is written). A packaged program has no
 * `Project.toml` beside it (it will ask the Julia command instead), so when none is
 * found, or it cannot be read, the name is `unknown` and nothing else is affected.
 *
 * @returns the name.
 */
function readVersion(): string {
    const root = repoRoot()
    if (root === undefined) return "unknown"
    try {
        const toml = parse(readFileSync(join(root, "Project.toml"), "utf8"))
        return `v${String(toml.version ?? "X.X.X")} ${String(toml.release_name ?? "ERROR")}`
    } catch {
        return "unknown"
    }
}

/** The release name shown on the main menu. */
export const version = readVersion()
