// SPDX-License-Identifier: LGPL-3.0-or-later

// A stand-in for 7-Zip that needs no compiler and works the same on every OS: the tests
// run `node` itself as the archive tool with `NODE_OPTIONS=--require <this file>`. Node
// loads this before it looks at its arguments (`a`, `x`, ... are the 7-Zip command), and
// this file exits, so the "script" it was given is never read.
//
// BAYSOL_STUB_REAL: the real 7-Zip it passes the call on to.
// BAYSOL_STUB_FAIL: a command letter that fails (exit 2, a message on stderr).
// BAYSOL_STUB_LOG: a file that gets a line for every `x`.
const { spawnSync } = require("node:child_process")
const { appendFileSync } = require("node:fs")
const { basename } = require("node:path")

// node made argv[1] an absolute path: the command letter is its last part
const command = basename(process.argv[1] ?? "")
const rest = process.argv.slice(2)
const fail = process.env.BAYSOL_STUB_FAIL
const log = process.env.BAYSOL_STUB_LOG
if (fail && command === fail) {
    process.stderr.write("ERROR: simulated failure\n")
    process.exit(2)
}
if (log && command === "x") appendFileSync(log, "x\n")
const env = { ...process.env }
delete env.NODE_OPTIONS
const r = spawnSync(process.env.BAYSOL_STUB_REAL, [command, ...rest], { stdio: "inherit", env })
process.exit(r.status ?? 1)
