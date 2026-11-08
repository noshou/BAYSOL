// SPDX-License-Identifier: LGPL-3.0-or-later

import { render } from "ink"
import { App } from "./app.js"
import { appDir, projectsDir } from "./core/environment.js"
import { hasTerminal } from "./core/terminal.js"
import { killAllNow, markAllStaleRuns, quitAll } from "./store/run.js"

// The entry point: runs in a terminal, else says it needs one.
if (hasTerminal()) {
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
    const app = render(<App />, { alternateScreen: true, exitOnCtrlC: false })
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
} else {
    console.error("BAYSOL: this program needs a terminal")
    process.exitCode = 1
}
