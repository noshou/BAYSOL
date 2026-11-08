// SPDX-License-Identifier: LGPL-3.0-or-later

import { existsSync } from "node:fs"
import { claimRun } from "../../src/store/run.js"

/**
 * A child process of test/concurrency.test.ts: waits for the gate file to appear (so
 * several copies start together), claims a run in the project and says what happened on
 * one line (`won <id>` or `refused <message>`); a winner then stays alive until it is
 * killed, as a real starter does while its Julia loads.
 *
 * Arguments: the project folder, the gate file.
 */
const [project, gate] = process.argv.slice(2)
while (!existsSync(gate as string)) await new Promise((r) => setTimeout(r, 5))
try {
    const run = claimRun(project as string)
    process.stdout.write(`won ${run.id}\n`)
    setInterval(() => {}, 1000)
} catch (error) {
    process.stdout.write(`refused ${(error as Error).message}\n`)
    process.exit(0)
}
