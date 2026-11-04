// SPDX-License-Identifier: LGPL-3.0-or-later

import {readFileSync}    from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import {parse}           from "smol-toml"

// parse project toml
const toml = parse(
    readFileSync(
        join(
            dirname(fileURLToPath(import.meta.url)),
            "..",
            "..",
            "Project.toml"
        ),
        "utf8"
    )
)

// semvar + version name = release version
const semVar = `v${String(toml.version ?? "X.X.X")}`
const vrName = String(toml.release_name  ?? "ERROR")
export const version = `${semVar} ${vrName}`
