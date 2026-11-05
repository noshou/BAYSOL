// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync, writeFileSync } from "node:fs"
import { withFileLock } from "../../src/core/files.js"

/**
 * A child process of test/concurrency.test.ts: adds 1 to the number in a counter file,
 * `cycles` times, each time as one locked read-modify-write. Without a working lock the
 * copies running together lose updates and the final count is short.
 *
 * Arguments: the counter file, the number of cycles.
 */
const [file, cycles] = process.argv.slice(2)
for (let i = 0; i < Number(cycles); i++) {
    withFileLock(file as string, () => {
        const n = Number(readFileSync(file as string, "utf-8"))
        writeFileSync(file as string, String(n + 1))
    })
}
