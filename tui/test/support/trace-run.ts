// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * A real run of a project folder through the code of the interface: `RunSession.begin`
 * with the real launcher starts Julia exactly as the run screen does, and waits for the
 * run to end. The packaging build (`bysl pkg`, stage `trace`) runs it with
 * `BAYSOL_TRACE_COMPILE` set, so the Julia child writes a `--trace-compile` file of what
 * a fit started by the interface makes it compile.
 *
 * Usage: `node --import tsx test/support/trace-run.ts PROJECT TEMPERATURE`
 *
 * Exit status: 0 when the run is `done`, 1 otherwise, 2 for a wrong command line.
 */

import { RunSession } from "../../src/store/run.js"

const [projectDir, temperatureText] = process.argv.slice(2)
const temperature = Number(temperatureText)
if (!projectDir || !Number.isFinite(temperature)) {
    process.stderr.write("usage: trace-run.ts PROJECT TEMPERATURE\n")
    process.exit(2)
}

const session = RunSession.begin(projectDir, temperature)
const phase = await session.done
process.stdout.write(`trace-run: ${projectDir} ended ${phase}\n`)
process.exit(phase === "done" ? 0 : 1)
