// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/plots.ts (move and compile plots: the plot folder, its layout, the
// compiler that is looked for or set) and of the two settings that go with them.
//
// Contents:
//   1. The plot folder and its layout
//   2. Move plots, from a packed run and from a plain one
//   3. The compiler: which one, and never a guess
//   4. Compile plots, with a fake compiler
//   5. The settings, and the plots of a packed run in the viewer

import assert from "node:assert/strict"
import {
    chmodSync,
    existsSync,
    mkdirSync,
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
    findCompiler,
    movePlots,
    type PlotUnit,
    plotRoot,
    plotUnit,
    unitFolder,
} from "../src/store/plots.js"
import { readRunText } from "../src/store/run-archive.js"
import { listOpenRuns } from "../src/store/run-logs.js"
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
    readdirSync(tmpdir()).filter((n) => /^baysol-(plots|compile)-/.test(n))

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

test("the layout is <plot dir>/<project>/<run stamp>/<model>; odd names refused", () => {
    const unit = (over: Partial<PlotUnit>): PlotUnit => ({
        project: "demo",
        run: "23-35-29-123_EST_-0500_2026-11-07",
        runDir: "/x",
        name: "crambin",
        tex: [],
        ...over,
    })
    assert.equal(
        unitFolder("/p", unit({})),
        join("/p", "demo", "23-35-29-123_EST_-0500_2026-11-07", "crambin"),
    )
    const compare = unitFolder("/p", unit({ name: "comparison" }))
    assert.equal(compare.endsWith("comparison"), true)
    for (const bad of [{ name: ".." }, { project: "a/b" }, { run: "" }, { name: "x\\y" }])
        assert.throws(() => unitFolder("/p", unit(bad)), /not a folder name/)
    // the project name is its folder's name
    assert.equal(
        plotUnit("/data/projects/demo", { id: "r", dir: "/d" }, { name: "m", tex: [] })
            .project,
        "demo",
    )
})

// ========================================================================================
// 2. Move plots
// ========================================================================================

test("move plots: from the archive or the folder, same files and layout", async () => {
    const before = temps()
    const root = tempDir()
    for (const pack of [undefined, async () => 0]) {
        const p = project()
        const { dir, id } = await makeRun(p, pack)
        const { model, compare } = unitsOf(p, dir)
        const note = await movePlots([model], root)
        const proj = p.split("/").pop() as string
        const folder = join(root, proj, id, "m")
        assert.equal(note, `moved 2 plots to ${folder}`)
        assert.deepEqual(readdirSync(folder).sort(), ["m.tex", "m_residuals.tex"])
        for (const name of ["m.tex", "m_residuals.tex"])
            assert.equal(
                readFileSync(join(folder, name), "utf-8"),
                readRunText(dir, `m/output/plots/${name}`),
                "same bytes",
            )
        // the comparison goes to its own folder; several units name the project folder
        const both = await movePlots([model, compare], root)
        assert.equal(both.startsWith("moved 3 plots to"), true)
        const compared = readdirSync(join(root, proj, id, "comparison"))
        assert.deepEqual(compared, ["res_compare.tex"])
    }
    // a file that is there is replaced; no staging file is left; the temp folders are gone
    const p = project()
    const { dir, id } = await makeRun(p)
    const { model } = unitsOf(p, dir)
    const folder = join(root, p.split("/").pop() as string, id, "m")
    mkdirSync(folder, { recursive: true })
    writeFileSync(join(folder, "m.tex"), "old")
    await movePlots([model], root)
    assert.notEqual(readFileSync(join(folder, "m.tex"), "utf-8"), "old")
    assert.deepEqual(readdirSync(folder).sort(), ["m.tex", "m_residuals.tex"])
    assert.deepEqual(temps(), before)
})

test("move plots: a plain run keeps its figures; none to move is told", async () => {
    const p = project()
    const { dir } = await makeRun(p, async () => 0)
    const { model } = unitsOf(p, dir)
    await movePlots([model], tempDir())
    assert.ok(existsSync(join(dir, "m", "output", "plots", "m.tex")), "the original stays")
    await assert.rejects(
        movePlots([{ ...model, tex: [] }], tempDir()),
        /no plots \(\.tex\) to move/,
    )
    await assert.rejects(movePlots([], tempDir()), /no plots/)
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
    assert.ok("problem" in missing && /not an executable: .*xelatex/.test(missing.problem))
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

test("compile plots: PDFs land in the layout (compiled in a temp folder)", async () => {
    if (windows) return
    const before = temps()
    const p = project()
    const { dir, id } = await makeRun(p)
    const { model, compare } = unitsOf(p, dir)
    const root = tempDir()
    const log = join(tempDir(), "cwd.log")
    writeFileSync(log, "")
    const bin = scriptIn("lualatex", FAKE_OK)
    process.env.FAKE_LOG = log
    try {
        const note = await compilePlots([model, compare], root, join(bin, "lualatex"))
        assert.match(note, /^compiled 3 plots to /)
    } finally {
        delete process.env.FAKE_LOG
    }
    const name = p.split("/").pop() as string
    const made = readdirSync(join(root, name, id, "m")).sort()
    assert.deepEqual(made, ["m.pdf", "m_residuals.pdf"])
    assert.deepEqual(readdirSync(join(root, name, id, "comparison")), ["res_compare.pdf"])
    const pdf = readFileSync(join(root, name, id, "m", "m.pdf"), "utf-8")
    assert.match(pdf, /%PDF of m\.tex/)
    // it ran in temporary folders (not in the run, not in the plot folder), all removed
    const cwds = readFileSync(log, "utf-8").trim().split("\n")
    assert.equal(cwds.length, 3)
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
    const { dir, id } = await makeRun(p, async () => 0)
    const { model } = unitsOf(p, dir)
    const root = tempDir()
    const bin = scriptIn("xelatex", FAKE_FAILS)
    const note = await compilePlots([model], root, join(bin, "xelatex"))
    const why = /1 failed: m\/m_residuals\.tex: ! Undefined control sequence\.$/
    assert.match(note, why)
    assert.match(note, /^compiled 1 plot, 1 failed: /)
    assert.deepEqual(readdirSync(join(root, p.split("/").pop() as string, id, "m")), [
        "m.pdf",
    ])
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
    const { dir, id } = await makeRun(p)
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
    assert.equal(readdirSync(join(root, p.split("/").pop() as string, id, "m")).length, 2)
})

// ========================================================================================
// 5. The settings, and the plots of a packed run in the viewer
// ========================================================================================

test("the plot dir and the compiler path are path settings, empty by default", () => {
    const catalog = defaultCatalog()
    for (const name of ["FIGURES_DIR", "FIGURES_COMPILER"]) {
        const def = catalog.require(name)
        assert.equal(def.kind, "path")
        assert.equal(def.default, "")
        assert.equal(def.sheet, "output")
        assert.equal(def.group, "figures")
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
        const path = join(run.dir, "m", "output", "plots_100x14.txt")
        assert.equal(existsSync(path), run === plain)
        const plots = readPlots(path, run.dir)
        assert.equal(plots.length, 2)
        assert.deepEqual(readPlots(path, run.dir), plots)
    }
    const out = join(packed.dir, "m", "output")
    assert.equal(readPlots(join(out, "nope.txt"), packed.dir).length, 0)
    assert.equal(readPlots(join(out, "plots.txt"), undefined).length, 0)
    assert.deepEqual(temps(), before)
})
