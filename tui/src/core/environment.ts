// SPDX-License-Identifier: LGPL-3.0-or-later

// Environment: the system, the checkout, the version, the data folders, the assets.
//
// Contents:
//   1. System: the operating system and the programs found on it
//   2. Repository: where the BAYSOL checkout is
//   3. Version: read from the project file
//   4. Paths: the data folders and the cache
//   5. Assets: the bundled JSON files and the run-flow tunables

import {
    accessSync,
    constants,
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    realpathSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { homedir, tmpdir } from "node:os"
import { delimiter, dirname, isAbsolute, join, parse, resolve, sep } from "node:path"
import { getAsset, isSea } from "node:sea"
import { fileURLToPath } from "node:url"

// ========================================================================================
// 1. System: the operating system and the programs found on it
// ========================================================================================

/**
 * The facts about this machine and this run, read once. Every function of the
 * program that needs to know about the machine takes one of these, so it stays pure
 * and a test can pass a hand-made one.
 *
 * @property os - the platform (`"linux"`, `"darwin"`, `"win32"`, ...).
 * @property env - the environment variables.
 * @property home - the home folder of the user.
 * @property cwd - the working directory.
 */
export type System = {
    os:   NodeJS.Platform
    env:  Record<string, string | undefined>
    home: string
    cwd:  string
}

/** Reads the facts about this machine. */
export function readSystem(): System {
    return { os: process.platform, env: process.env, home: homedir(), cwd: process.cwd() }
}

/** @returns `true` if `system` is a Windows. */
export const isWindows = (system: System): boolean => system.os === "win32"

/** @returns `true` if `system` is a Mac. */
export const isMac = (system: System): boolean => system.os === "darwin"

/** @returns `true` if `system` is a Linux. */
export const isLinux = (system: System): boolean => system.os === "linux"

/** @returns the file name of the executable `name` on `system` (`name.exe` on Windows). */
export const exeName = (system: System, name: string): string =>
    isWindows(system) ? `${name}.exe` : name

/**
 * Finds a program the way a shell would.
 *
 * @param system - the machine; its `PATH` is searched (on Windows the extensions
 *     `.exe`, `.cmd` and `.bat` are tried too).
 * @param program - a name looked up on the `PATH`, or a path (anything with a `/`; on
 *     Windows a `\` too).
 * @returns the absolute path of the executable file, or `undefined` if there is none.
 */
export function findExecutable(system: System, program: string): string | undefined {
    // Windows: a bare name finds `name.exe` before the extensionless `name` (a shell script
    // such as the `npm` beside `npm.cmd`, which cannot be started); a name that already has
    // an extension is tried as it is first
    const extensions = !isWindows(system)
        ? [""]
        : /\.[^./\\]+$/.test(program)
          ? ["", ".exe", ".cmd", ".bat"]
          : [".exe", ".cmd", ".bat", ""]
    const isPath = program.includes("/") || (isWindows(system) && program.includes("\\"))
    const dirs = isPath
        ? [""]
        : (system.env.PATH ?? "").split(delimiter).filter((d) => d !== "")
    for (const dir of dirs) {
        for (const extension of extensions) {
            const file = join(dir, program + extension)
            try {
                accessSync(file, constants.X_OK)
                if (statSync(file).isFile()) return file
            } catch {
                // not here; try the next candidate
            }
        }
    }
    return undefined
}

// ========================================================================================
// 2. Repository: where the BAYSOL checkout is
// ========================================================================================

/** The folder with the `Project.toml` of BAYSOL (a checkout); a lookup may find nothing. */

/** The environment variable that names the BAYSOL package folder. */
const repoVar = "BAYSOL_ROOT"

/** @returns whether `dir/Project.toml` names the package `BAYSOL`. */
function isRepo(dir: string): boolean {
    const file = join(dir, "Project.toml")
    return existsSync(file) && /^name\s*=\s*"BAYSOL"/m.test(readFileSync(file, "utf-8"))
}

/**
 * The BAYSOL package folder.
 *
 * @returns the folder `BAYSOL_ROOT` names, else the nearest parent of this file that holds
 *     the package, or `undefined`.
 */
export function repoRoot(
    env: Record<string, string | undefined> = process.env,
): string | undefined {
    const named = env[repoVar]
    if (named && isRepo(named)) return named
    for (let d = dirname(fileURLToPath(import.meta.url)); ; d = dirname(d)) {
        if (isRepo(d)) return d
        if (parse(d).root === d) return undefined
    }
}

// ========================================================================================
// 3. Version: the program's version, read from the project file
// ========================================================================================

/**
 * `v<version> <release_name>`: the `Project.toml` of the checkout, or the `VERSION` asset of a
 * packaged app; else `unknown`.
 */
function readVersion(): string {
    const root = repoRoot()
    if (root === undefined) {
        // a packaged app has no checkout: `bysl pkg` puts the version in the executable
        try {
            return isSea() ? readAssetText("VERSION").trim() : "unknown"
        } catch {
            return "unknown"
        }
    }
    try {
        const toml = readFileSync(join(root, "Project.toml"), "utf8")
        const field = (key: string) =>
            new RegExp(`^${key}\\s*=\\s*"([^"]*)"`, "m").exec(toml)?.[1]
        return `v${field("version") ?? "X.X.X"} ${field("release_name") ?? "ERROR"}`
    } catch {
        return "unknown"
    }
}

/** The release name shown on the main menu. */
export const version = readVersion()

// ========================================================================================
// 4. Paths: the data folders, the cache and where they live
// ========================================================================================

/**
 * Where BAYSOL keeps things. What must last (the BAYSOL-wide settings, the projects)
 * lies in the data folder each operating system has for a program; what can be rebuilt
 * (the font list, downloaded and generated structures) goes in the operating system's
 * cache folder instead, so it never piles up among the data of the user. A folder is
 * made the first time it is asked for ([[appDir]], [[projectsDir]], [[cacheDir]]).
 */

/** The environment variable that names the BAYSOL folder instead of the default one. */
const homeVar = "BAYSOL_HOME"

/** The environment variable that names the cache folder; the Julia side reads it too. */
const cacheVar = "BAYSOL_CACHE"

/** The marker file of a cache folder (backup tools skip a folder that has it). */
const cacheTag = "CACHEDIR.TAG"

/** The text of the marker: the signature the freedesktop specification asks for. */
const cacheTagText =
    "Signature: 8a477f597d28d172789f06886806bc55\n" +
    "# This file is a cache directory tag created by BAYSOL.\n" +
    "# It is safe to delete everything in this folder.\n"

/**
 * The folder an environment variable names, if it is usable.
 *
 * @returns the folder, or `undefined` if the variable is missing, blank or not an
 *     absolute path (the XDG specification says to ignore a relative one).
 */
function envDir(system: System, name: string): string | undefined {
    const value = (system.env[name] ?? "").trim()
    return value !== "" && isAbsolute(value) ? value : undefined
}

/**
 * The folder in which the operating system keeps the data of a program: Windows
 * `%LOCALAPPDATA%` (else `<home>\AppData\Local`), macOS `<home>/Library/Application
 * Support`, everything else `$XDG_DATA_HOME` (else `~/.local/share`).
 */
function dataHome(system: System): string {
    if (isWindows(system))
        return envDir(system, "LOCALAPPDATA") ?? join(system.home, "AppData", "Local")
    if (isMac(system)) return join(system.home, "Library", "Application Support")
    return envDir(system, "XDG_DATA_HOME") ?? join(system.home, ".local", "share")
}

/**
 * The folder in which the operating system keeps the caches of a program: Windows
 * `%LOCALAPPDATA%` (else `<home>\AppData\Local`), macOS `<home>/Library/Caches`,
 * everything else `$XDG_CACHE_HOME` (else `~/.cache`).
 */
function cacheHome(system: System): string {
    if (isWindows(system))
        return envDir(system, "LOCALAPPDATA") ?? join(system.home, "AppData", "Local")
    if (isMac(system)) return join(system.home, "Library", "Caches")
    return envDir(system, "XDG_CACHE_HOME") ?? join(system.home, ".cache")
}

/**
 * The BAYSOL folder: `$BAYSOL_HOME` if that is an absolute path, else `baysol` inside
 * the data folder of the system.
 */
function appRoot(system: System): string {
    return envDir(system, homeVar) ?? join(dataHome(system), "baysol")
}

/**
 * THE folder that holds BAYSOL's caches (`_cache`, `_structures`): `baysol` in the cache
 * home of the system. Where the system has one folder for data and caches (Windows) that
 * would lie inside the projects folder (`<data home>/baysol`), so the caches go to the
 * sibling `<data home>/baysol-cache`. Mirrors `Platform.cache_dir` in `platform.jl`; both
 * tests pin the same paths, so the two cannot drift.
 */
export function cacheFolder(system: System): string {
    const caches = join(cacheHome(system), "baysol")
    const projects = join(dataHome(system), "baysol")
    return isWithin(caches, projects) ? `${projects}-cache` : caches
}

/** Whether `path` is `dir` or inside it (any case when this program runs on Windows). */
function isWithin(path: string, dir: string): boolean {
    const fold = (p: string): string => {
        const n = resolve(p).replace(/[/]+$/, "")
        return process.platform === "win32" ? n.toLowerCase() : n
    }
    const p = fold(path)
    const d = fold(dir)
    return p === d || p.startsWith(d + sep)
}

/**
 * The general cache, `_cache` in [[cacheFolder]] (`Platform.default_cache`; fixtures live in
 * it).
 */
export const defaultCache = (system: System): string => join(cacheFolder(system), "_cache")

/**
 * The default structure cache, `_structures` in [[cacheFolder]]
 * (`Platform.default_structure_cache`).
 */
export const defaultStructureCache = (system: System): string =>
    join(cacheFolder(system), "_structures")

/**
 * The folder the fit reads as `BAYSOL_CACHE` and this program uses as its cache:
 * `$BAYSOL_CACHE` if that is an absolute path, else [[defaultStructureCache]]
 * (`Platform.structure_cache`).
 */
export function structureCache(system: System): string {
    return envDir(system, cacheVar) ?? defaultStructureCache(system)
}

/**
 * THE folder of every temporary file BAYSOL makes: `baysol` in the temporary folder of the
 * system (`Platform.tmp_dir` in `platform.jl`; both tests pin the same names). One folder
 * per process lies below it ([[tmpProcessFolder]]); nothing in it matters after the program
 * ends, and the program sweeps the folders of dead processes at start.
 *
 * @param base - the system's temporary folder (`os.tmpdir()`).
 */
export const tmpFolder = (base: string = tmpdir()): string => join(base, "baysol")

/** The folder of one process below [[tmpFolder]] (`Platform.tmp_process_dir`). */
export const tmpProcessFolder = (pid: number, base: string = tmpdir()): string =>
    join(tmpFolder(base), String(pid))

/** The projects folder inside a BAYSOL folder. */
export function projectsRoot(root: string): string {
    return join(root, "projects")
}

/**
 * Makes a folder and any parent it lacks.
 *
 * @throws if the folder cannot be made; the message names it.
 */
export function ensureDir(dir: string): string {
    try {
        mkdirSync(dir, { recursive: true })
    } catch (error) {
        throw new Error(`could not make the folder ${dir}: ${(error as Error).message}`)
    }
    if (!statSync(dir).isDirectory()) throw new Error(`${dir} is not a folder`)
    return dir
}

/**
 * Makes a value the first time it is asked for and gives the same one afterwards,
 * so a folder is only made when something needs it.
 */
export function lazy<T>(make: () => T): () => T {
    let made: { value: T } | undefined
    return () => {
        made ??= { value: make() }
        return made.value
    }
}

/** The BAYSOL folder, made on first use. */
export const appDir: () => string = lazy(() => ensureDir(appRoot(readSystem())))

/** The projects folder, made on first use (the BAYSOL folder first). */
export const projectsDir: () => string = lazy(() => ensureDir(projectsRoot(appDir())))

/**
 * Whether a folder is the default cache folder of a machine, ignoring `BAYSOL_CACHE`.
 *
 * @returns `true` if `dir` is the default structure cache of `system`.
 */
function isDefaultCache(system: System, dir: string): boolean {
    const stock = structureCache({ ...system, env: { ...system.env, [cacheVar]: "" } })
    try {
        return realpathSync(stock) === realpathSync(dir)
    } catch {
        return resolve(stock) === resolve(dir)
    }
}

/**
 * Marks a cache folder as BAYSOL's, if it is not marked yet and is either the default
 * cache folder or empty. A folder named by `BAYSOL_CACHE` that already holds other
 * things is never marked.
 */
function tagCache(system: System, dir: string): string {
    const tag = join(dir, cacheTag)
    const empty = readdirSync(dir).length === 0
    if (!existsSync(tag) && (isDefaultCache(system, dir) || empty))
        writeFileSync(tag, cacheTagText, "utf-8")
    return dir
}

/** The cache folder, made (and marked) on first use. */
export const cacheDir: () => string = lazy(() => {
    const system = readSystem()
    return tagCache(system, ensureDir(structureCache(system)))
})

// ========================================================================================
// 5. Assets: the bundled JSON files and the flows they hold
// ========================================================================================

/**
 * The `assets/` folder of the checkout. A packaged app has none: its assets are inside
 * the executable (Node single-executable assets, keyed by their path below `assets/`).
 */
const ASSETS_ROOT = join(fileURLToPath(new URL("../..", import.meta.url)), "assets")

/**
 * @returns the absolute path of a file below the checkout's `assets/` (not in a packaged app).
 */
export function assetPath(...path: string[]): string {
    return join(ASSETS_ROOT, ...path)
}

/**
 * Reads a text file below `assets/`: from the executable when this is a packaged app,
 * else from the checkout.
 *
 * @param path - the folders and the file name below `assets/`, one string each.
 * @throws if the asset does not exist.
 */
export function readAssetText(...path: string[]): string {
    return isSea()
        ? getAsset(path.join("/"), "utf8")
        : readFileSync(assetPath(...path), "utf-8")
}

/** Reads a JSON file below `assets/` (harvested or hand-written, never written here). */
export function readAssetJson<T>(...path: string[]): T {
    return JSON.parse(readAssetText(...path)) as T
}

/** A JSON asset read on first use: the function returns the same value each time. */
export function lazyAsset<T>(...path: string[]): () => T {
    return lazy(() => readAssetJson<T>(...path))
}

/** The shape of `assets/data/run_flow.json`. */
export type RunFlow = {
    temperature: { default: number; min: number; max: number; maxLength: number }
    liveness: { staleSeconds: number; claimRefreshSeconds: number }
    claim: { maxStampTries: number }
    abort: { graceSeconds: number; killWaitSeconds: number }
    screen: { tailLines: number; refreshSeconds: number }
    julia: { threads: string }
    log: { maxBytes: number }
    archive: {
        extension: string
        level: number
        wordSize: number
        solid: boolean
        maxEntryBytes: number
        maxExtractBytes: number
        maxViewCacheBytes: number
    }
}

/**
 * The tunables of the run flow: the temperature prompt (°C), how stale a heartbeat may
 * be (Julia's `RUN_STALE_S`), how a run folder is claimed, how long an abort waits, the
 * output lines the run screen keeps, `screen.refreshSeconds` (the idle seconds before
 * the last frame is painted again in place, 0 = off; `ui/screen-refresh.ts`), the Julia
 * `--threads` and the size cap of a `run.LOG` shown in the pager. Read from
 * `assets/data/run_flow.json`, where the 7z archive of a finished run
 * (`core/archive.ts`, `store/run-archive.ts`) is the `archive` group: the extension of
 * `runs/<stamp>.7z`, the name of the archive inside a run folder of the older layout,
 * the compression level, the largest single entry read into memory and the most bytes
 * one extraction may write, and `maxViewCacheBytes`, the most the temporary copies of
 * archived workbooks that the viewers open may hold in all (`store/view-cache.ts`; the
 * oldest copies are removed first).
 */
export const RUN_FLOW: RunFlow = readAssetJson<RunFlow>("data", "run_flow.json")

/** The shape of `assets/data/plots_flow.json`. */
export type PlotsFlow = {
    compileSeconds: number
    engineArguments: string[]
    searched: string[]
    accepted: string[]
    folder: string
    dataFolder: string
}

/**
 * The tunables of the plots actions of `open runs` (`store/plots.ts`): how long one LaTeX
 * run may take, the arguments every engine gets, the compilers looked for on the `PATH`
 * (in this order; a path that is set may also name `pdflatex`) and the names of the
 * plot folder and the data folder inside the BAYSOL data folder. Read from
 * `assets/data/plots_flow.json`.
 */
export const PLOTS_FLOW: PlotsFlow = readAssetJson<PlotsFlow>("data", "plots_flow.json")

/** The shape of `assets/data/logs.json`. */
export type LogsFlow = {
    pager: { overlap: number; sideStep: number; tabWidth: number }
    list: { stampWidth: number; statusWidth: number; sizeWidth: number }
    options: { fileWidth: number; sizeWidth: number }
    watch: { pollSeconds: number; closeSeconds: number }
    corner: { separator: string; minCells: number }
}

/**
 * The tunables of the logs menu and `open runs`: pager steps, columns, refresh, corner
 * (`assets/data/logs.json`).
 */
export const LOGS_FLOW: LogsFlow = readAssetJson<LogsFlow>("data", "logs.json")
