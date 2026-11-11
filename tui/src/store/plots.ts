// SPDX-License-Identifier: LGPL-3.0-or-later

// The files actions of `open runs`: "move tex" (the `.tex` figures of a model or of the
// comparison, out of the run's archive or folder, into the plot folder), "move data" (the
// workbooks and the comparison table, into the data folder) and "compile plots" (LaTeX on
// the figures, the PDFs into the plot folder). They act on the whole run or on one row of
// it; the destination folders are flat, named for the model, and never take the place of
// a file that is there.
//
// Contents:
//   1. Where files go: the folders and the names
//   2. Getting the files out of a run
//   3. Move and compile

import { spawn } from "node:child_process"
import {
    accessSync,
    constants,
    copyFileSync,
    existsSync,
    readFileSync,
    rmSync,
    statSync,
} from "node:fs"
import { basename, extname, isAbsolute, join, relative, sep } from "node:path"
import { extractEntries, withTempFolder } from "../core/archive.js"
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
import { archiveHolding } from "./run-archive.js"

// ========================================================================================
// 1. Where files go
// ========================================================================================

/** The name the comparison goes by in a unit (as in the run list). */
const COMPARISON = "comparison"

/**
 * One model of a run (or its comparison) whose files an action takes.
 *
 * @property project - the project's folder name.
 * @property run - the run's name (its stamp).
 * @property runDir - the run's path (its folder, which may be packed away).
 * @property name - the model's name, or `comparison`.
 * @property tex - its `.tex` figures, paths relative to the run folder.
 * @property data - its data files (the workbook, or the comparison table), paths relative
 *     to the run folder.
 */
export type PlotUnit = {
    project: string
    run: string
    runDir: string
    name: string
    tex: readonly string[]
    data: readonly string[]
}

/** The [[PlotUnit]] of a model (or the comparison) of a run of a project. */
export const plotUnit = (
    projectDir: string,
    run: { id: string; dir: string },
    model: { name: string; tex: readonly string[]; workbook?: string | undefined },
): PlotUnit => ({
    project: basename(projectDir),
    run: run.id,
    runDir: run.dir,
    name: model.name,
    tex: model.tex,
    data:
        model.workbook === undefined
            ? []
            : [relative(run.dir, model.workbook).split(sep).join("/")],
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
 * The data folder: the setting "data dir" (`TABLE_DIR`), or, when it is empty, the `data`
 * folder of the BAYSOL data folder. ONE folder for all the projects.
 *
 * @param setting - the value of the setting.
 * @param dataFolder - the BAYSOL data folder, the program's own when left out.
 * @returns the folder's path (it is not made here).
 */
export function dataRoot(setting: unknown, dataFolder: () => string = appDir): string {
    return typeof setting === "string" && setting.trim() !== ""
        ? setting.trim()
        : join(dataFolder(), PLOTS_FLOW.dataFolder)
}

/**
 * The name a unit's file has in the destination folder, keyed off the model: the file's
 * own name (`<model>.tex`, `<model>_hist_c1.tex`, `<model>.xlsx`); the comparison's
 * (`compare.tsv`, or `<run>_compare.xlsx` in an older run) becomes `<project>-compare.*`.
 */
export function destinationName(unit: PlotUnit, rel: string): string {
    const base = basename(rel)
    if (unit.name !== COMPARISON) return base
    return `${unit.project}-compare${base.replace(/^(?:.*_)?compare/, "")}`
}

/** A name with `-<k>` before its extension (`a.tex` is `a-2.tex`). */
const numbered = (name: string, k: number): string => {
    const ext = extname(name)
    return `${name.slice(0, name.length - ext.length)}-${k}${ext}`
}

/**
 * The names the files of one unit are put under in a folder without taking the place of a
 * file there: their own, or, when one of them is taken, all of them with `-2`, `-3`, ...
 * before the extension (the first number that frees every name), so the files of one unit
 * stay together.
 *
 * @param folder - the destination.
 * @param names - the names the files would have.
 * @returns the names to use, in the order of `names`.
 */
export function freeNames(folder: string, names: readonly string[]): string[] {
    for (let k = 1; ; k++) {
        const out = names.map((n) => (k === 1 ? n : numbered(n, k)))
        if (!out.some((n) => existsSync(join(folder, n)))) return out
    }
}

// ========================================================================================
// 2. Getting the files out of a run
// ========================================================================================

/**
 * Puts files of a unit into the temporary folder `tmp`, flat, under their own names: from
 * the plain files of its run where they are and from the run's archive otherwise.
 *
 * @param rels - the files, paths relative to the run folder.
 * @returns each file's name in `tmp`, in the order of `rels`.
 * @throws [[ArchiveError]] when the archive cannot be read, Error when a file is not
 *     there.
 */
async function bring(
    unit: PlotUnit,
    rels: readonly string[],
    tmp: string,
): Promise<string[]> {
    const byArchive = new Map<string, string[]>()
    for (const rel of rels) {
        const plain = join(unit.runDir, ...rel.split("/"))
        if (isFile(plain)) {
            copyFileSync(plain, join(tmp, basename(rel)))
            continue
        }
        const archive = archiveHolding(unit.runDir, rel)
        if (archive === undefined) throw new Error(`no ${basename(rel)} in the run`)
        byArchive.set(archive, [...(byArchive.get(archive) ?? []), rel])
    }
    for (const [archive, names] of byArchive) {
        await withTempFolder("baysol-extract", async (from) => {
            await extractEntries(archive, names, from)
            for (const rel of names)
                copyFileSync(join(from, ...rel.split("/")), join(tmp, basename(rel)))
        })
    }
    return rels.map((rel) => basename(rel))
}

/**
 * Copies files from `tmp` into `folder` under names that are free, never replacing a file.
 * A name taken between the check and the copy (another copy of the program) makes the
 * whole set go again under the next number; what this call copied before is removed then.
 *
 * @param copies - `[name in tmp, name wanted in folder]` for each file.
 * @returns how many files were put.
 */
function putFiles(
    tmp: string,
    folder: string,
    copies: readonly (readonly [string, string])[],
): number {
    ensureDir(folder)
    for (;;) {
        const names = freeNames(
            folder,
            copies.map(([, wanted]) => wanted),
        )
        const made: string[] = []
        try {
            copies.forEach(([from], i) => {
                const to = join(folder, names[i] as string)
                copyFileSync(join(tmp, from), to, constants.COPYFILE_EXCL)
                made.push(to)
            })
            return made.length
        } catch (error) {
            for (const file of made) rmSync(file, { force: true })
            if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error
        }
    }
}

// ========================================================================================
// 3. Move and compile
// ========================================================================================

/** The cells left in a note row of `room` cells after `head` (at least 12). */
const restOf = (room: number, head: string): number =>
    Math.max(12, room - displayWidth(head))

/** The text of a count: `1 plot`, `3 plots`. */
const plots = (n: number): string => `${n} plot${n === 1 ? "" : "s"}`

/** What a move takes: the `.tex` figures or the data files. */
export type MoveKind = "tex" | "data"

/**
 * Move tex / move data: copies the `.tex` figures (to the plot folder) or the data files,
 * the workbooks and the comparison table (to the data folder), of the units into the
 * folder, flat. The originals stay (they are in the run's archive); a file of the same
 * name there is never replaced: the unit's files take `-2`, `-3`, ... ([[freeNames]]).
 *
 * @param kind - which files.
 * @param units - the models (and comparison) to take.
 * @param root - the destination folder ([[plotRoot]] or [[dataRoot]]).
 * @param room - the cells of the note row; only the folder in the note is cut to fit it.
 * @returns what to tell the user.
 * @throws Error naming what is wrong: nothing to move, an unreadable archive, a folder
 *     that cannot be written.
 */
export async function moveFiles(
    kind: MoveKind,
    units: readonly PlotUnit[],
    root: string,
    room = Number.POSITIVE_INFINITY,
): Promise<string> {
    const filesOf = (u: PlotUnit): readonly string[] => (kind === "tex" ? u.tex : u.data)
    const taking = units.filter((u) => filesOf(u).length > 0)
    if (taking.length === 0)
        throw new Error(kind === "tex" ? "no plots (.tex) to move" : "no data to move")
    let count = 0
    for (const unit of taking) {
        const rels = filesOf(unit)
        await withTempFolder("baysol-move", async (tmp) => {
            const names = await bring(unit, rels, tmp)
            count += putFiles(
                tmp,
                root,
                names.map((n, i) => [n, destinationName(unit, rels[i] as string)]),
            )
        })
    }
    const files = `${count} data file${count === 1 ? "" : "s"}`
    const what = kind === "tex" ? plots(count) : files
    const head = `moved ${what} to `
    // only the folder (data) is cut, from its start: the end names it
    return head + truncateStart(root, restOf(room, head))
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
 * (always removed), runs the compiler on each there, and puts the PDFs into the plot
 * folder, flat, named for the model, never replacing a file ([[freeNames]]). Figures that
 * fail are named in the result; the others are still made.
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
        await withTempFolder("baysol-compile", async (tmp) => {
            const names = await bring(unit, unit.tex, tmp)
            const done: [string, string][] = []
            for (const [i, name] of names.entries()) {
                const why = await compileOne(compiler.path, tmp, name)
                if (why !== undefined) {
                    failed.push(`${unit.name}/${name}: ${why}`)
                    continue
                }
                const wanted = destinationName(unit, unit.tex[i] as string)
                done.push([
                    `${basename(name, ".tex")}.pdf`,
                    `${basename(wanted, ".tex")}.pdf`,
                ])
            }
            made += putFiles(tmp, root, done)
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
    return head + truncateStart(root, restOf(room, head))
}
