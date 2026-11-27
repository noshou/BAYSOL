// SPDX-License-Identifier: LGPL-3.0-or-later

import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { scratchFolder, startScratch } from "../../src/core/scratch.js"

/**
 * A child process of test/scratch.test.ts: starts the scratch space the way `main.tsx`
 * does, makes a file in it, tells the test where (a line on stdout), then waits (the test
 * ends it) or leaves the way `how` says.
 *
 * Arguments: `how` (`wait`, `exit`, `throw`, `reject`, `sigterm`, `sighup`). The temporary
 * folder is named by the `TMPDIR`, `TEMP` and `TMP` of the environment the test gives.
 */
const how = process.argv[2] ?? "wait"
startScratch()
const folder = scratchFolder("view")
writeFileSync(join(folder, "copy.xlsx"), "x")
process.stdout.write(`${folder}\n`)
// the signals are handled the way main.tsx does: leave through process.exit
for (const [signal, code] of [["SIGHUP", 129], ["SIGTERM", 143]] as const)
    process.on(signal, () => process.exit(code))
const timer = setInterval(() => {}, 1000)
if (how === "exit") process.exit(0)
if (how === "throw") setTimeout(() => { throw new Error("boom") }, 10)
if (how === "reject") setTimeout(() => { void Promise.reject(new Error("boom")) }, 10)
if (how === "wait" || how === "sigterm" || how === "sighup") void timer
