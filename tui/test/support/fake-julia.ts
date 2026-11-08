// SPDX-License-Identifier: LGPL-3.0-or-later

import { spawn } from "node:child_process"
import { appendFileSync, mkdirSync, renameSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { join } from "node:path"

/**
 * A stand-in for Julia in the tests of the run flow: it takes the three arguments the
 * real child takes (project, temperature, run folder) and writes a `run.json` and a
 * `logs/run.LOG` the way `BAYSOL.run_project` does, then behaves as `FAKE_MODE` says:
 *
 * - `done`: prints a few lines (one with a carriage-return progress bar), finishes `done`.
 * - `failed`: finishes `failed` with an ERRORS section.
 * - `hang`: starts a grandchild (`sleep`) in the same process group, then waits; on SIGTERM
 *   it finishes `aborted` and exits 130, as Julia does.
 * - `stubborn`: like `hang` but ignores SIGTERM (only SIGKILL stops it).
 * - `crash`: writes `running`, one line, and exits 3 without finishing.
 * - `silent`: exits 1 at once, writing nothing.
 * - `eof`: like `hang` but finishes `aborted` when its standard input ends.
 *
 * `FAKE_PIDFILE`, when set, receives the pids of the child and its grandchild.
 */
const [, , project, temperature, runDir] = process.argv
const mode = process.env.FAKE_MODE ?? "done"
const iso = (): string => `${new Date().toISOString().slice(0, 19)}Z`
const started = iso()

/** Writes `run.json` atomically. */
function runJson(status: string): void {
    const file = join(runDir as string, "run.json")
    const body = {
        schema: 1,
        status,
        pid: process.pid,
        host: hostname(),
        ui: "tui",
        project,
        started,
        heartbeat: iso(),
        ended: status === "running" ? null : iso(),
        models: [],
    }
    writeFileSync(`${file}.tmp`, JSON.stringify(body, null, 2))
    renameSync(`${file}.tmp`, file)
}

/** Appends to the LOG. */
const log = (text: string): void =>
    appendFileSync(join(runDir as string, "logs", "run.LOG"), text)

/** Finishes the run the way Julia does and exits. */
function finish(status: string, code: number): never {
    log(`\n--- result ---\nstatus\t${status}\n`)
    if (status !== "done") log("\n=== ERRORS ===\nfake: it did not go well\n")
    runJson(status)
    process.exit(code)
}

if (mode === "silent") process.exit(1)

mkdirSync(join(runDir as string, "logs"), { recursive: true })
runJson("running")
writeFileSync(
    join(runDir as string, "logs", "run.LOG"),
    `datetime\tnow\nproject\t${project}\ntemperature_c\t${temperature}\n\n--- output ---\n`,
)
process.stdout.write("fake julia started\n")

if (mode === "done" || mode === "failed") {
    process.stdout.write("progress 10%\rprogress 50%\rprogress 100%\n")
    process.stderr.write("\x1b[32mcolour on stderr\x1b[0m\n")
    setTimeout(() => finish(mode, 0), 200)
} else if (mode === "crash") {
    process.stdout.write("about to crash\n")
    setTimeout(() => process.exit(3), 100)
} else {
    // hang, stubborn, eof: a grandchild in the same group, then wait
    const grandchild = spawn("sleep", ["300"], { stdio: "ignore" })
    if (process.env.FAKE_PIDFILE)
        writeFileSync(process.env.FAKE_PIDFILE, `${process.pid} ${grandchild.pid}\n`)
    process.stdout.write("ready\n")
    setInterval(() => runJson("running"), 500)
    if (mode === "stubborn") process.on("SIGTERM", () => {})
    else process.on("SIGTERM", () => finish("aborted", 130))
    if (mode === "eof") {
        process.stdin.resume()
        process.stdin.on("end", () => finish("aborted", 130))
    }
}
