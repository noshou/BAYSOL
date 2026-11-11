// SPDX-License-Identifier: LGPL-3.0-or-later

import { spawn } from "node:child_process"
import { appendFileSync, mkdirSync, renameSync, writeFileSync } from "node:fs"
import { hostname } from "node:os"
import { dirname, join } from "node:path"

/**
 * A stand-in for Julia in the tests of the run flow: it takes the three arguments the
 * real child takes (project, temperature, run folder) and writes a `run.json` and a
 * `run.LOG` the way `BAYSOL.run_project` does (the run folder is flat), then behaves as
 * `FAKE_MODE` says:
 *
 * - `done`: prints a few lines (one with a carriage-return progress bar), finishes `done`.
 * - `plots`: like `done`, and the run has the files a real one leaves: a model `m` with its
 *   `m.LOG`, `m.xlsx`, `m-plots.txt`, the plots at two sizes (`m-76x10.txt`), two `.tex`
 *   figures (`m.tex`, `m_residuals.tex`) and a comparison (`compare.tsv`, `compare.tex`,
 *   `compare-plots.txt`, `compare-<W>x<H>.txt`), all named in `run.json`.
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

/** The sizes of the terminal plots the fake model writes, `[width, rows]`. */
const PLOT_SIZES: [number, number][] = [
    [76, 10],
    [100, 14],
]

/** The standalone figure the fake model writes (a real pgfplots document). */
const figure = (title: string): string =>
    [
        "\\documentclass[border=8pt]{standalone}",
        "\\usepackage{pgfplots}",
        "\\begin{document}",
        "\\begin{tikzpicture}",
        `\\begin{axis}[title={${title}}]`,
        "\\addplot coordinates {(0.02, 3.1) (0.10, 2.4) (0.20, 1.2)};",
        "\\end{axis}",
        "\\end{tikzpicture}",
        "\\end{document}",
        "",
    ].join("\n")

/** One boxed terminal plot: a title line, then a box (UnicodePlots' `:corners`). */
const boxed = (title: string, w: number, h: number): string =>
    [
        `${title}   ${w}x${h}`,
        `┌${"─".repeat(w - 2)}┐`,
        ...Array.from({ length: h }, () => `│${" ".repeat(w - 2)}│`),
        `└${"─".repeat(w - 2)}┘`,
    ].join("\n")

/** The terminal plots at one size: two plots, a blank line between them. */
const terminalPlots = (w: number, h: number): string =>
    `${boxed("fit", w, h)}\n\n${boxed("residuals", w, h)}\n`

/** The files of a finished model and of the comparison (`plots` mode). */
function writeOutputs(): void {
    const dir = runDir as string
    const files: Record<string, string> = {
        "m.LOG": "datetime\tnow\n",
        "m.xlsx": "PK workbook",
        "m-plots.txt": terminalPlots(70, 18),
        "m.tex": figure("fit"),
        "m_residuals.tex": figure("residuals"),
        "compare-plots.txt": terminalPlots(70, 18),
        "compare.tex": figure("comparison"),
        "compare.tsv": "q\tI\n0.1\t2\n",
    }
    for (const [w, h] of PLOT_SIZES) {
        files[`m-${w}x${h}.txt`] = terminalPlots(w, h)
        files[`compare-${w}x${h}.txt`] = terminalPlots(w, h)
    }
    for (const [rel, text] of Object.entries(files)) {
        mkdirSync(dirname(join(dir, rel)), { recursive: true })
        writeFileSync(join(dir, rel), text)
    }
}

/** Writes `run.json` atomically. */
function runJson(status: string): void {
    const sizes = (stem: string): unknown[] =>
        mode !== "plots"
            ? []
            : PLOT_SIZES.map(([w, h]) => ({
                file: `${stem}-${w}x${h}.txt`,
                width: w,
                rows: h,
            }))
    const plots = mode === "plots" && status !== "running"
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
        models: plots
            ? [
                {
                    name: "m",
                    status: "done",
                    files: ["m.xlsx", "m.tex", "m_residuals.tex", "m-plots.txt"],
                    plot_sizes: sizes("m"),
                },
            ]
            : [],
        ...(plots
            ? {
                compare: {
                    status: "done",
                    files: ["compare.tex", "compare.tsv", "compare-plots.txt"],
                    plot_sizes: sizes("compare"),
                },
            }
            : {}),
    }
    writeFileSync(`${file}.tmp`, JSON.stringify(body, null, 2))
    renameSync(`${file}.tmp`, file)
}

/** Appends to the LOG. */
const log = (text: string): void =>
    appendFileSync(join(runDir as string, "run.LOG"), text)

/** Finishes the run the way Julia does and exits. */
function finish(status: string, code: number): never {
    log(`\n--- result ---\nstatus\t${status}\n`)
    if (status !== "done") log("\n=== ERRORS ===\nfake: it did not go well\n")
    runJson(status)
    process.exit(code)
}

if (mode === "silent") process.exit(1)

mkdirSync(runDir as string, { recursive: true })
runJson("running")
writeFileSync(
    join(runDir as string, "run.LOG"),
    `datetime\tnow\nproject\t${project}\ntemperature_c\t${temperature}\n\n--- output ---\n`,
)
process.stdout.write("fake julia started\n")

if (mode === "done" || mode === "failed" || mode === "plots") {
    if (mode === "plots") writeOutputs()
    process.stdout.write("progress 10%\rprogress 50%\rprogress 100%\n")
    process.stderr.write("\x1b[32mcolour on stderr\x1b[0m\n")
    setTimeout(() => finish(mode === "plots" ? "done" : mode, 0), 200)
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
