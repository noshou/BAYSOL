// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/plots.ts (move tex, move data and compile plots: the folders, the names
// and their collisions, the compiler that is looked for or set) and of the settings that
// go with them.
//
// Contents:
//   1. The folders and the names
//   2. Move tex and move data, from a packed run and from a plain one
//   3. The compiler: which one, and never a guess
//   4. Compile plots, with a fake compiler
//   5. The settings, and the plots of a packed run in the viewer

import assert from "node:assert/strict"
import {
    chmodSync,
    existsSync,
    readdirSync,
    readFileSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { delimiter, join } from "node:path"
import { test } from "node:test"
import { readSystem } from "../src/core/environment.js"
import { parseSetting, valueText } from "../src/screens/screen-rules.js"
import { readPlots } from "../src/screens/viewer.js"
import {
    compilePlots,
    dataRoot,
    destinationName,
    findCompiler,
    freeNames,
    moveFiles,
    type PlotUnit,
    plotRoot,
    plotUnit,
} from "../src/store/plots.js"
import { readRunText } from "../src/store/run-archive.js"
import { listOpenRuns, runModels } from "../src/store/run-logs.js"
import { defaultCatalog, validateValue } from "../src/store/settings.js"
import { makeRun } from "./support/fake-run.js"
import { tempDir } from "./support/fixtures.js"

const windows = process.platform === "win32"

/** A project folder with the inputs of a run. */
function project(): string {
    const dir = tempDir()
    writeFileSync(join(dir, "buffer.json"), '{"solutes": []}\n')
    writeFileSync(join(dir, "data.tsv"), "0.1\t5\t0.1\n")
    writeFileSync(join(dir, "data.json"), '{"units": "A-1", "energy": 8000}\n')
    return dir
}

/** The units of a run (its model and its comparison), as `open runs` takes them. */
function unitsOf(projectDir: string, dir: string): { model: PlotUnit; compare: PlotUnit } {
    const run = listOpenRuns(projectDir).find((r) => r.dir === dir)
    assert.ok(run?.compare, "the run lists its comparison")
    const [m] = run.models
    assert.ok(m)
    return {
        model: plotUnit(projectDir, run, m),
        compare: plotUnit(projectDir, run, run.compare),
    }
}

/** The names of the `baysol-` temporary folders now in the system's temp folder. */
const temps = (): string[] =>
    readdirSync(tmpdir()).filter((n) => /^baysol-(plots|compile|move|extract)-/.test(n))

/** A folder with an executable script `name` in it; returns the folder. */
function scriptIn(name: string, body: string, dir: string = tempDir()): string {
    const file = join(dir, name)
    writeFileSync(file, `#!/bin/sh\n${body}\n`)
    chmodSync(file, 0o755)
    return dir
}

/** A fake LaTeX: it writes `<stem>.pdf` (what it was run on), and notes where it ran. */
const FAKE_OK = `for last; do :; done
stem="\${last%.tex}"
pwd >> "$FAKE_LOG"
echo "%PDF of $last" > "$stem.pdf"`

/** A fake LaTeX that fails on figures with `residuals` in them, with a LaTeX log. */
const FAKE_FAILS = `for last; do :; done
stem="\${last%.tex}"
if grep -q residuals "$last"; then
  echo "! Undefined control sequence." > "$stem.log"; exit 1
fi
echo "%PDF of $last" > "$stem.pdf"`

/** Runs `fn` with a `PATH` of just `bin`, and restores it. */
async function withPath<T>(bin: string, fn: () => Promise<T>): Promise<T> {
    const was = process.env.PATH
    process.env.PATH = bin
    try {
        return await fn()
    } finally {
        process.env.PATH = was
    }
}

// ========================================================================================
// 1. The plot folder and its layout
// ========================================================================================

test("the plot folder is the setting, else `plots` in the BAYSOL data folder", () => {
    const data = join(tempDir(), "baysol")
    assert.equal(plotRoot("", () => data), join(data, "plots"))
    assert.equal(plotRoot("   ", () => data), join(data, "plots"))
    assert.equal(plotRoot(undefined, () => data), join(data, "plots"))
    assert.equal(plotRoot("  /my/plots ", () => data), "/my/plots")
    // the data folder is not asked for when the setting is given (nothing is made)
    assert.equal(
        plotRoot("/x", () => {
            throw new Error("asked")
        }),
        "/x",
    )
})

test("the data folder is the setting, else `data` in the BAYSOL data folder", () => {
    const data = join(tempDir(), "baysol")
    assert.equal(dataRoot("", () => data), join(data, "data"))
    assert.equal(dataRoot(undefined, () => data), join(data, "data"))
    assert.equal(dataRoot(" /my/data ", () => data), "/my/data")
})

test("names are keyed off the model; the comparison's are named for the project", () => {
    const unit = (over: Partial<PlotUnit>): PlotUnit => ({
        project: "demo",
        run: "r",
        runDir: "/x",
        name: "crambin",
        tex: [],
        data: [],
        ...over,
    })
    assert.equal(destinationName(unit({}), "crambin_hist_c1.tex"), "crambin_hist_c1.tex")
    assert.equal(destinationName(unit({}), "m/output/plots/crambin.tex"), "crambin.tex")
    const compare = unit({ name: "comparison" })
    assert.equal(destinationName(compare, "compare.tsv"), "demo-compare.tsv")
    assert.equal(destinationName(compare, "compare.tex"), "demo-compare.tex")
    // an older run's names
    const stamp = "23-35-29-123_EST_-0500_2026-11-07"
    assert.equal(
        destinationName(compare, `compare/plots/${stamp}_compare.tex`),
        "demo-compare.tex",
    )
    // the project name is its folder's name; the data file is the workbook, relative
    const model = { name: "m", tex: [], workbook: join("/d", "m.xlsx") }
    const made = plotUnit("/data/projects/demo", { id: "r", dir: "/d" }, model)
    assert.equal(made.project, "demo")
    assert.deepEqual(made.data, ["m.xlsx"])
    assert.deepEqual(
        plotUnit("/p/demo", { id: "r", dir: "/d" }, { name: "m", tex: [] }).data,
        [],
    )
})

test("a taken name numbers the whole set with -2, -3 before the extension", () => {
    const folder = tempDir()
    assert.deepEqual(freeNames(folder, ["a.tex", "a_b.tex"]), ["a.tex", "a_b.tex"])
    writeFileSync(join(folder, "a.tex"), "x")
    assert.deepEqual(freeNames(folder, ["a.tex", "a_b.tex"]), ["a-2.tex", "a_b-2.tex"])
    writeFileSync(join(folder, "a_b-2.tex"), "x")
    assert.deepEqual(freeNames(folder, ["a.tex", "a_b.tex"]), ["a-3.tex", "a_b-3.tex"])
    assert.deepEqual(freeNames(folder, []), [])
})

// ========================================================================================
// 2. Move tex and move data
// ========================================================================================

test("move tex: from the archive or the folder, flat, named for the model", async () => {
    const before = temps()
    const root = tempDir()
    const seen: string[][] = []
    for (const pack of [undefined, async () => 0]) {
        const p = project()
        const { dir } = await makeRun(p, pack)
        const { model, compare } = unitsOf(p, dir)
        const target = join(root, pack === undefined ? "packed" : "plain")
        const note = await moveFiles("tex", [model], target)
        assert.equal(note, `moved 2 plots to ${target}`)
        assert.deepEqual(readdirSync(target).sort(), ["m.tex", "m_residuals.tex"])
        for (const name of ["m.tex", "m_residuals.tex"])
            assert.equal(
                readFileSync(join(target, name), "utf-8"),
                readRunText(dir, name),
                "same bytes",
            )
        // the whole run: the comparison comes as <project>-compare.tex
        const all = await moveFiles("tex", [model, compare], target)
        assert.equal(all.startsWith("moved 3 plots to"), true)
        const project_ = p.split("/").pop() as string
        seen.push(readdirSync(target).sort())
        assert.ok(readdirSync(target).includes(`${project_}-compare.tex`))
    }
    // the second move of the same unit did not take the place of the first
    assert.deepEqual(seen[0], [
        `${seen[0]?.find((n) => n.endsWith("-compare.tex"))}`,
        "m-2.tex",
        "m.tex",
        "m_residuals-2.tex",
        "m_residuals.tex",
    ].sort())
    assert.deepEqual(temps(), before)
})

test("move tex never replaces a file and keeps no staging file", async () => {
    const p = project()
    const { dir } = await makeRun(p)
    const { model } = unitsOf(p, dir)
    const root = tempDir()
    writeFileSync(join(root, "m.tex"), "old")
    await moveFiles("tex", [model], root)
    assert.equal(readFileSync(join(root, "m.tex"), "utf-8"), "old")
    assert.deepEqual(readdirSync(root).sort(), [
        "m-2.tex",
        "m.tex",
        "m_residuals-2.tex",
    ])
    // a third and a fourth take the next numbers
    await moveFiles("tex", [model], root)
    assert.ok(existsSync(join(root, "m-3.tex")))
    assert.ok(existsSync(join(root, "m_residuals-3.tex")))
    assert.equal(readFileSync(join(root, "m.tex"), "utf-8"), "old", "still the old file")
    assert.ok(!readdirSync(root).some((n) => n.includes(".tmp")))
})

test("move data: the workbook and the comparison table, into the data folder", async () => {
    for (const pack of [undefined, async () => 0]) {
        const p = project()
        const { dir } = await makeRun(p, pack)
        const run = listOpenRuns(p).find((r) => r.dir === dir)
        assert.ok(run)
        const units = runModels(run).map((m) => plotUnit(p, run, m))
        const root = join(tempDir(), "data")
        const note = await moveFiles("data", units, root)
        assert.equal(note, `moved 2 data files to ${root}`)
        const project_ = p.split("/").pop() as string
        assert.deepEqual(
            readdirSync(root).sort(),
            ["m.xlsx", `${project_}-compare.tsv`].sort(),
        )
        assert.equal(readFileSync(join(root, "m.xlsx"), "utf-8"), "PK workbook")
        // a second move keeps both sets
        await moveFiles("data", units, root)
        assert.deepEqual(
            readdirSync(root).sort(),
            [
                "m-2.xlsx",
                "m.xlsx",
                `${project_}-compare-2.tsv`,
                `${project_}-compare.tsv`,
            ].sort(),
        )
    }
})

test("move: a plain run keeps its files; none to move is told", async () => {
    const p = project()
    const { dir } = await makeRun(p, async () => 0)
    const { model } = unitsOf(p, dir)
    await moveFiles("tex", [model], tempDir())
    assert.ok(existsSync(join(dir, "m.tex")), "the original stays")
    await assert.rejects(
        moveFiles("tex", [{ ...model, tex: [] }], tempDir()),
        /no plots \(\.tex\) to move/,
    )
    await assert.rejects(
        moveFiles("data", [{ ...model, data: [] }], tempDir()),
        /no data to move/,
    )
    await assert.rejects(moveFiles("tex", [], tempDir()), /no plots/)
})

// ========================================================================================
// 3. The compiler
// ========================================================================================

test("an empty setting looks for lualatex, then xelatex, on the PATH only", () => {
    if (windows) return
    const both = tempDir()
    scriptIn("xelatex", "exit 0", both)
    scriptIn("pdflatex", "exit 0", both)
    const system = (path: string) => ({ ...readSystem(), env: { PATH: path } })
    // xelatex is the fallback; pdflatex is never picked on its own
    assert.deepEqual(findCompiler("", system(both)), { path: join(both, "xelatex") })
    scriptIn("lualatex", "exit 0", both)
    assert.deepEqual(findCompiler("  ", system(both)), { path: join(both, "lualatex") })
    const onlyPdf = scriptIn("pdflatex", "exit 0")
    const none = findCompiler("", system(onlyPdf))
    assert.ok("problem" in none)
    assert.match(none.problem, /no LaTeX compiler found: set "latex compiler path"/)
})

test("a compiler path that is set is the only one tried, and must be an engine", () => {
    if (windows) return
    const bin = tempDir()
    scriptIn("lualatex", "exit 0", bin)
    scriptIn("pdflatex", "exit 0", bin)
    scriptIn("latex", "exit 0", bin)
    const system = { ...readSystem(), env: { PATH: bin } }
    // an absolute path, a name on the PATH, and pdflatex when the user chose it
    const pdf = join(bin, "pdflatex")
    assert.deepEqual(findCompiler(pdf, system), { path: pdf })
    assert.deepEqual(findCompiler("lualatex", system), { path: join(bin, "lualatex") })
    // not there: told, even though lualatex is on the PATH (no silent other compiler)
    const missing = findCompiler(join(bin, "xelatex"), system)
    assert.ok("problem" in missing && /not an executable/.test(missing.problem))
    // not an engine
    const wrong = findCompiler(join(bin, "latex"), system)
    assert.ok("problem" in wrong)
    assert.match(wrong.problem, /latex compiler must be lualatex, xelatex, pdflatex/)
    // Windows spellings are accepted as the engine's own name
    scriptIn("XeLaTeX.exe", "exit 0", bin)
    assert.deepEqual(findCompiler(join(bin, "XeLaTeX.exe"), system), {
        path: join(bin, "XeLaTeX.exe"),
    })
})

// ========================================================================================
// 4. Compile plots
// ========================================================================================

test("compile plots: PDFs land flat in the plot folder, built in a temp dir", async () => {
    if (windows) return
    const before = temps()
    const p = project()
    const { dir } = await makeRun(p)
    const { model, compare } = unitsOf(p, dir)
    const root = tempDir()
    const log = join(tempDir(), "cwd.log")
    writeFileSync(log, "")
    const bin = scriptIn("lualatex", FAKE_OK)
    process.env.FAKE_LOG = log
    try {
        const note = await compilePlots([model, compare], root, join(bin, "lualatex"))
        assert.match(note, /^compiled 3 plots to /)
        // a second compile never replaces the first one's PDFs
        await compilePlots([model], root, join(bin, "lualatex"))
    } finally {
        delete process.env.FAKE_LOG
    }
    const name = p.split("/").pop() as string
    assert.deepEqual(readdirSync(root).sort(), [
        `${name}-compare.pdf`,
        "m-2.pdf",
        "m.pdf",
        "m_residuals-2.pdf",
        "m_residuals.pdf",
    ])
    const pdf = readFileSync(join(root, "m.pdf"), "utf-8")
    assert.match(pdf, /%PDF of m\.tex/)
    // it ran in temporary folders (not in the run, not in the plot folder), all removed
    const cwds = readFileSync(log, "utf-8").trim().split("\n")
    assert.equal(cwds.length, 5)
    for (const c of cwds)
        assert.ok(/baysol-compile-/.test(c) && !c.startsWith(dir) && !existsSync(c), c)
    assert.deepEqual(temps(), before)
    // the run itself is untouched: its archive still holds the figures
    assert.deepEqual(
        listOpenRuns(p).find((r) => r.dir === dir)?.models[0]?.tex.length,
        2,
    )
})

test("compile plots: a figure that fails is named, the others are still made", async () => {
    if (windows) return
    const p = project()
    const { dir } = await makeRun(p, async () => 0)
    const { model } = unitsOf(p, dir)
    const root = tempDir()
    const bin = scriptIn("xelatex", FAKE_FAILS)
    const note = await compilePlots([model], root, join(bin, "xelatex"))
    const why = /1 failed: m\/m_residuals\.tex: ! Undefined control sequence\.$/
    assert.match(note, why)
    assert.match(note, /^compiled 1 plot, 1 failed: /)
    assert.deepEqual(readdirSync(root), ["m.pdf"])
    // when every figure fails, it is an error that says why
    const only = { ...model, tex: model.tex.filter((t) => t.includes("residuals")) }
    await assert.rejects(
        compilePlots([only], root, join(bin, "xelatex")),
        /no plot compiled: m\/m_residuals\.tex: ! Undefined control sequence/,
    )
})

test("compile plots: no compiler is told, with where to set it; nothing made", async () => {
    const p = project()
    const { dir } = await makeRun(p)
    const { model } = unitsOf(p, dir)
    const root = tempDir()
    const empty = tempDir()
    await withPath(empty, async () => {
        await assert.rejects(
            compilePlots([model], root, ""),
            /no LaTeX compiler found: set "latex compiler path"/,
        )
    })
    await assert.rejects(
        compilePlots([model], root, join(empty, "lualatex")),
        /the latex compiler path is not an executable/,
    )
    await assert.rejects(
        compilePlots([{ ...model, tex: [] }], root, ""),
        /no plots \(\.tex\) to compile/,
    )
    assert.deepEqual(readdirSync(root), [], "nothing was made")
})

test("compile plots: an empty setting uses the PATH's lualatex", async () => {
    if (windows) return
    const p = project()
    const { dir } = await makeRun(p)
    const { model } = unitsOf(p, dir)
    const root = tempDir()
    const log = join(tempDir(), "cwd.log")
    writeFileSync(log, "")
    const bin = scriptIn("lualatex", FAKE_OK)
    process.env.FAKE_LOG = log
    try {
        await withPath(`${bin}${delimiter}${process.env.PATH ?? ""}`, async () => {
            assert.match(await compilePlots([model], root, ""), /^compiled 2 plots/)
        })
    } finally {
        delete process.env.FAKE_LOG
    }
    assert.equal(readdirSync(root).length, 2)
})

// ========================================================================================
// 5. The settings, and the plots of a packed run in the viewer
// ========================================================================================

test("the plot dir and the compiler path are path settings, empty by default", () => {
    const catalog = defaultCatalog()
    for (const name of ["FIGURES_DIR", "FIGURES_COMPILER", "TABLE_DIR"]) {
        const def = catalog.require(name)
        assert.equal(def.kind, "path")
        assert.equal(def.default, "")
        assert.equal(def.sheet, "output")
        assert.equal(def.group, name === "TABLE_DIR" ? "tables" : "figures")
        assert.ok(def.description.length > 0)
        assert.deepEqual(validateValue(def, ""), { ok: true, value: "" })
        assert.deepEqual(validateValue(def, " /a/b "), { ok: true, value: "/a/b" })
        for (const bad of [5, null, "a\nb", "a\u0001b", "x".repeat(4097)])
            assert.deepEqual(validateValue(def, bad), {
                ok: false,
                error: "must be a path (text without control characters, or empty)",
            })
        assert.deepEqual(parseSetting(def, "  C:\\TeX live\\lualatex.exe "), {
            value: "C:\\TeX live\\lualatex.exe",
        })
        assert.deepEqual(parseSetting(def, ""), { value: "" })
        assert.equal(valueText(def, ""), "(default)")
        assert.equal(valueText(def, "/a/b"), "/a/b")
    }
})

test("the viewer reads a packed run's plots straight from the archive", async () => {
    const before = temps()
    const p = project()
    const packed = await makeRun(p)
    const plain = await makeRun(p, async () => 0)
    for (const run of [packed, plain]) {
        const path = join(run.dir, "m-100x14.txt")
        assert.equal(existsSync(path), run === plain)
        const plots = readPlots(path, run.dir)
        assert.equal(plots.length, 2)
        assert.deepEqual(readPlots(path, run.dir), plots)
    }
    assert.equal(readPlots(join(packed.dir, "nope.txt"), packed.dir).length, 0)
    assert.equal(readPlots(join(packed.dir, "m-plots.txt"), undefined).length, 0)
    assert.deepEqual(temps(), before)
})
