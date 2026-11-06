// SPDX-License-Identifier: LGPL-3.0-or-later

import { render } from "ink"
import { App } from "./app.js"
import { readSystem } from "./core/system.js"
import {
    hasTerminal,
    programCommand,
    relaunchInTerminal,
    startAction,
} from "./core/terminal.js"

/**
 * The entry point. In a terminal the program runs here; with no terminal (started
 * from a launcher) it opens a terminal emulator that runs the program again; the copy
 * that was already opened for that never opens a second one.
 */
const system = readSystem()
const action = startAction(hasTerminal(), system)

if (action === "run") {
    // the alternate screen (like vim): a frame as tall as the terminal would otherwise
    // make it scroll a line on every redraw, and the shell is restored on exit
    // Ctrl-C is a key like any other for Ink (`App` handles it with Ctrl-D), so the
    // run screen can take the abort over later
    render(<App />, { alternateScreen: true, exitOnCtrlC: false })
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
