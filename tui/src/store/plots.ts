// SPDX-License-Identifier: LGPL-3.0-or-later

// The plots actions of `open runs`: "move plots" (the `.tex` figures of a model or of the
// comparison, out of the run's archive or folder, into the plot folder) and "compile
// plots" (LaTeX on them, the PDFs into the plot folder).
//
// Contents:
//   1. Where plots go: the plot folder and its layout
//   2. Getting the figures out of a run
//   3. Move and compile

import { spawn } from "node:child_process"
import {
    accessSync,
    constants,
    copyFileSync,
    readFileSync,
    renameSync,
    statSync,
} from "node:fs"
import { basename, isAbsolute, join } from "node:path"
import { extractEntries, isSafeEntryName, withTempFolder } from "../core/archive.js"
import {
    appDir,
    ensureDir,
    findExecutable,
    PLOTS_FLOW,
    readSystem,
    type System,
} from "../core/environment.js"
import { isFile } from "../core/file-system.js"
import { displayWidth, truncate, truncateStart } from "../core/terminal.js"
import { archivePath } from "./run-archive.js"

// ========================================================================================
// 1. Where plots go
// ========================================================================================

/**
 * One model of a run (or its comparison) whose figures an action takes.
 *
 * @property project - the project's folder name.
 * @property run - the run's name (its stamp).
 * @property runDir - the run folder.
 * @property name - the model's name, or `comparison`.
 * @property tex - its `.tex` figures, paths relative to the run folder.
 */
export type PlotUnit = {
    project: string
    run: string
    runDir: string
    name: string
    tex: readonly string[]
}

/** The [[PlotUnit]] of a model (or the comparison) of a run of a project. */
export const plotUnit = (
    projectDir: string,
    run: { id: string; dir: string },
    model: { name: string; tex: readonly string[] },
): PlotUnit => ({
    project: basename(projectDir),
    run: run.id,
    runDir: run.dir,
    name: model.name,
    tex: model.tex,
})

/**
 * The plot folder: the setting "plot dir" (`FIGURES_DIR`), or, when it is empty, the
 * `plots` folder of the BAYSOL data folder. ONE folder for all the projects.
 *
 * @param setting - the value of the setting.
 * @param dataFolder - the BAYSOL data folder, the program's own when left out.
 * @returns the folder's path (it is not made here).
 */
export function plotRoot(setting: unknown, dataFolder: () => string = appDir): string {
    return typeof setting === "string" && setting.trim() !== ""
        ? setting.trim()
        : join(dataFolder(), PLOTS_FLOW.folder)
}

/**
 * The folder one model's plots go to: `<plot dir>/<project>/<run stamp>/<model>/`
 * (`comparison` for the comparison), the layout `run_project` uses when it copies
 * the figures itself.
 *
 * @throws Error when a part is not a plain folder name (nothing is built from it).
 */
export function unitFolder(root: string, unit: PlotUnit): string {
    for (const part of [unit.project, unit.run, unit.name])
        if (!isSafeEntryName(part) || part.includes("/"))
            throw new Error(`not a folder name: ${part}`)
    return join(root, unit.project, unit.run, unit.name)
}

// ========================================================================================
// 2. Getting the figures out of a run
// ========================================================================================

/**
 * Puts a unit's figures into `folder`, flat (`<name>.tex`), from the plain files of its run
 * where they are and from the run's archive otherwise (extracted to a temporary folder
 * that is always removed).
 *
 * @param folder - the folder to fill (made if missing).
 * @param pick - which figures (`undefined`: all of the unit's).
 * @returns the file names put there.
 * @throws [[ArchiveError]] when the archive cannot be read, Error when a file cannot be
 *     written.
 */
async function bring(
    unit: PlotUnit,
    folder: string,
    pick?: (name: string) => boolean,
): Promise<string[]> {
    const wanted = unit.tex.filter((rel) => pick === undefined || pick(basename(rel)))
    ensureDir(folder)
    const archived = wanted.filter((rel) => !isFile(join(unit.runDir, ...rel.split("/"))))
    const put = (from: string, rel: string): string => {
        const name = basename(rel)
        const staged = join(folder, `${name}.tmp.${process.pid}`)
        copyFileSync(from, staged)
        renameSync(staged, join(folder, name))
        return name
    }
    const names = wanted
        .filter((rel) => !archived.includes(rel))
        .map((rel) => put(join(unit.runDir, ...rel.split("/")), rel))
    if (archived.length > 0)
        await withTempFolder("baysol-plots", async (tmp) => {
            await extractEntries(archivePath(unit.runDir), archived, tmp)
            for (const rel of archived) names.push(put(join(tmp, ...rel.split("/")), rel))
        })
    return names.sort()
}

// ========================================================================================
// 3. Move and compile
// ========================================================================================

/** Where a note says plots went: the unit's folder, or the project's for several. */
function placeOf(units: readonly PlotUnit[], root: string): string {
    const [first] = units
    if (first === undefined) return root
    return units.length === 1 ? unitFolder(root, first) : join(root, first.project)
}

/** The cells left in a note row of `room` cells after `head` (at least 12). */
const restOf = (room: number, head: string): number =>
    Math.max(12, room - displayWidth(head))

/** The text of a count: `1 plot`, `3 plots`. */
const plots = (n: number): string => `${n} plot${n === 1 ? "" : "s"}`

/**
 * Move plots: copies the `.tex` figures of the units into the plot folder
 * (`<plot dir>/<project>/<run stamp>/<model>/`). The originals stay (they are in the run's
 * archive); a file of the same name there is replaced.
 *
 * @param units - the models (and comparison) to take.
 * @param root - the plot folder ([[plotRoot]]).
 * @param room - the cells of the note row; only the folder in the note is cut to fit it.
 * @returns what to tell the user.
 * @throws Error naming what is wrong: nothing to move, an unreadable archive, a folder that
 *     cannot be written.
 */
export async function movePlots(
    units: readonly PlotUnit[],
    root: string,
    room = Number.POSITIVE_INFINITY,
): Promise<string> {
    const withPlots = units.filter((u) => u.tex.length > 0)
    if (withPlots.length === 0) throw new Error("no plots (.tex) to move")
    let count = 0
    for (const unit of withPlots)
        count += (await bring(unit, unitFolder(root, unit))).length
    const head = `moved ${plots(count)} to `
    // only the folder (data) is cut, from its start: the end names the model
    return head + truncateStart(placeOf(withPlots, root), restOf(room, head))
}

/**
 * Which LaTeX compiler to run, never guessing a different one. A path that is set must be
 * an executable file (or a program name on the `PATH`) named `lualatex`, `xelatex` or
 * `pdflatex`; an empty setting looks for `lualatex`, then `xelatex`, on the `PATH`
 * (`pdflatex` cannot load the fonts of the figures, so it is never picked by itself).
 *
 * @param setting - the value of the setting "latex compiler path".
 * @param system - the machine whose `PATH` is searched.
 * @returns the path, or `problem`: the sentence that says what to do.
 */
export function findCompiler(
    setting: unknown,
    system: System = readSystem(),
): { path: string } | { problem: string } {
    const set = typeof setting === "string" ? setting.trim() : ""
    if (set !== "") {
        const found = isAbsolute(set) ? executable(set) : findExecutable(system, set)
        const engines = PLOTS_FLOW.accepted.join(", ")
        const stem = basename(set)
            .replace(/\.(exe|cmd|bat)$/i, "")
            .toLowerCase()
        if (found === undefined)
            return { problem: "the latex compiler path is not an executable" }
        if (!PLOTS_FLOW.accepted.includes(stem))
            return { problem: `latex compiler must be ${engines}` }
        return { path: found }
    }
    for (const name of PLOTS_FLOW.searched) {
        const found = findExecutable(system, name)
        if (found !== undefined) return { path: found }
    }
    return { problem: 'no LaTeX compiler found: set "latex compiler path"' }
}

/** The path itself when it is an executable file. */
function executable(file: string): string | undefined {
    try {
        accessSync(file, constants.X_OK)
        return statSync(file).isFile() ? file : undefined
    } catch {
        return undefined
    }
}

/**
 * Runs the compiler on one `.tex` file in `cwd`.
 *
 * @returns `undefined` when it produced the PDF, else why not (the first error line of the
 *     LaTeX log, else what the compiler printed).
 */
function compileOne(
    compiler: string,
    cwd: string,
    tex: string,
): Promise<string | undefined> {
    return new Promise((resolve) => {
        const args = [...PLOTS_FLOW.engineArguments, tex]
        let said = ""
        const child = spawn(compiler, args, { cwd, stdio: ["ignore", "pipe", "pipe"] })
        const limit = PLOTS_FLOW.compileSeconds * 1000
        const timer = setTimeout(() => child.kill("SIGKILL"), limit)
        const collect = (chunk: Buffer): void => {
            said = (said + chunk.toString("utf-8")).slice(-4096)
        }
        child.stdout.on("data", collect)
        child.stderr.on("data", collect)
        child.once("error", (error) => {
            clearTimeout(timer)
            resolve(`could not run ${compiler}: ${error.message}`)
        })
        child.once("close", (code) => {
            clearTimeout(timer)
            const pdf = join(cwd, `${basename(tex, ".tex")}.pdf`)
            if (code === 0 && isFile(pdf)) return resolve(undefined)
            let log = ""
            try {
                log = readFileSync(join(cwd, `${basename(tex, ".tex")}.log`), "utf-8")
            } catch {
                // no LaTeX log: the compiler's own words
            }
            const line = /^!.*$/m.exec(log)?.[0] ?? said.trim().split("\n").pop()
            resolve(line || `${basename(compiler)} ended with code ${code}`)
        })
    })
}

/**
 * Compile plots: extracts (or copies) the units' `.tex` figures into a temporary folder
 * (always removed), runs the compiler on each there, and puts the PDFs into the plot folder
 * (`<plot dir>/<project>/<run stamp>/<model>/`). Figures that fail are named in the result;
 * the others are still made.
 *
 * @param units - the models (and comparison) to take.
 * @param root - the plot folder ([[plotRoot]]).
 * @param compilerSetting - the "latex compiler path" setting ([[findCompiler]]).
 * @param room - the cells of the note row; only the folder or the compiler's first
 *     complaint (data) is cut to fit it.
 * @returns what to tell the user.
 * @throws Error naming what is wrong: nothing to compile, no compiler (the message says
 *     to set the path), an unreadable archive, or every figure failed.
 */
export async function compilePlots(
    units: readonly PlotUnit[],
    root: string,
    compilerSetting: unknown,
    room = Number.POSITIVE_INFINITY,
): Promise<string> {
    const withPlots = units.filter((u) => u.tex.length > 0)
    if (withPlots.length === 0) throw new Error("no plots (.tex) to compile")
    const compiler = findCompiler(compilerSetting)
    if ("problem" in compiler) throw new Error(compiler.problem)
    let made = 0
    const failed: string[] = []
    for (const unit of withPlots) {
        const dest = unitFolder(root, unit)
        await withTempFolder("baysol-compile", async (tmp) => {
            for (const name of await bring(unit, tmp)) {
                const why = await compileOne(compiler.path, tmp, name)
                if (why !== undefined) {
                    failed.push(`${unit.name}/${name}: ${why}`)
                    continue
                }
                ensureDir(dest)
                const pdf = `${basename(name, ".tex")}.pdf`
                const staged = join(dest, `${pdf}.tmp.${process.pid}`)
                copyFileSync(join(tmp, pdf), staged)
                renameSync(staged, join(dest, pdf))
                made++
            }
        })
    }
    if (made === 0) {
        const head = "no plot compiled: "
        throw new Error(head + truncate(failed[0] ?? "", restOf(room, head)))
    }
    if (failed.length > 0) {
        // the failures matter more than the folder: name the first one
        const head = `compiled ${plots(made)}, ${failed.length} failed: `
        return head + truncate(failed[0] ?? "", restOf(room, head))
    }
    const head = `compiled ${plots(made)} to `
    return head + truncateStart(placeOf(withPlots, root), restOf(room, head))
}
