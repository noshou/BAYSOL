// SPDX-License-Identifier: LGPL-3.0-or-later

import { render } from "ink"
import { App } from "./app.js"
import { readSystem } from "./core/system.js"
import { hasTerminal, programCommand, relaunchInTerminal, startAction } from "./system/terminal.js"

/**
 * The entry point. In a terminal the program runs here; with no terminal (started
 * from a launcher) it opens a terminal emulator that runs the program again; the copy
 * that was already opened for that never opens a second one.
 */
const system = readSystem()
const action = startAction(hasTerminal(), system)

if (action === "run") {
    render(<App />)
} else if (action === "relaunch") {
    const command = programCommand(process.execPath, process.execArgv, process.argv)
    const problem = await relaunchInTerminal(system, command)
    if (problem !== undefined) {
        console.error(`BAYSOL: ${problem}`)
        process.exitCode = 1
    }
} else {
    console.error("BAYSOL: this program needs a terminal")
    process.exitCode = 1
}
