// SPDX-License-Identifier: LGPL-3.0-or-later

import { render } from "ink"
import { App } from "./app.js"
import { appDir, projectsDir, readSystem } from "./core/environment.js"
import {
    hasTerminal,
    programCommand,
    relaunchInTerminal,
    startAction,
} from "./core/terminal.js"
import { killAllNow, markAllStaleRuns, quitAll } from "./store/run.js"

// The entry point: in a terminal the program runs here; with no terminal (started from a
// launcher) it opens a terminal emulator that runs the program again, and the copy that was
// opened for that never opens a second one.
const system = readSystem()
// `--view FILE`: open a workbook or table in the viewer instead of the main menu
const viewAt = process.argv.indexOf("--view")
const viewFile = viewAt < 0 ? undefined : process.argv[viewAt + 1]
if (viewAt >= 0 && viewFile === undefined) {
    console.error("BAYSOL: --view needs a file")
    process.exit(1)
}
const action = startAction(hasTerminal(), system)

if (action === "run") {
    // the alternate screen (like vim): a frame as tall as the terminal would otherwise
    // make it scroll a line on every redraw, and the shell is restored on exit
    // Ctrl-C is a key like any other for Ink (`App` handles it with Ctrl-D), so the
    // run screen can take the abort over later
    // a `running` run that nobody runs any more (a killed Julia, a reboot) is `interrupted`
    try {
        appDir()
        markAllStaleRuns(projectsDir())
    } catch {
        // an unreadable data folder is told by the screens; the sweep is only housekeeping
    }
    const app = render(<App viewFile={viewFile} />, {
        alternateScreen: true,
        exitOnCtrlC: false,
    })
    // SIGHUP (the terminal went away) and SIGTERM do what Ctrl-C does: stop the run that
    // is going, restore the terminal, leave. Whatever else ends the
    // process, the last gasp kills the Julia child's group, so none is left over.
    for (const [signal, code] of [["SIGHUP", 129], ["SIGTERM", 143]] as const) {
        process.on(signal, () => {
            void quitAll(signal)
                .catch(() => {})
                .finally(() => {
                    app.unmount()
                    process.exit(code)
                })
        })
    }
    process.on("exit", killAllNow)
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
