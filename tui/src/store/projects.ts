// SPDX-License-Identifier: LGPL-3.0-or-later

import { mkdirSync, rmSync } from "node:fs"
import { basename, join } from "node:path"
import {
    entryNames,
    isDict,
    isFile,
    isFolder,
    readJson,
    sortNoCase,
    writeAtomic,
    writeJson,
} from "../core/files.js"
import { ensureDir, projectsRoot } from "../core/paths.js"
import { tooLong } from "../core/text.js"

// Re-exported: the path the screens import the folder helpers by.
export { entryNames, isFile, isFolder, sortNoCase, tooLong }

/**
 * The projects: one folder for each in the `projects` folder of the BAYSOL folder, named
 * by its id (the name the user typed). A folder is a project when it has a `project.json`
 * that says so (`{"id": "name", "created": "<time>"}` with the id of the folder's own
 * name); any other folder or file there is not one and is left alone, but its name is
 * taken.
 *
 * A new project gets an exact copy of the global `settings.json` as its own, which is its
 * starting point; what it changes after that is the project's alone. The copy is the
 * business of the settings module, so [[createProject]] takes it as a hook.
 *
 * A name must be new in the folder, without regard to case (a file system that does not
 * tell `Run` from `run` would not keep two apart), and a name that every system accepts:
 * letters, digits, `.`, `_` and `-`, starting with a letter or a digit, not ending in
 * `.`, at most 40 characters, and not a name a Windows device has (`con`, `nul`,
 * `com1`, ...).
 */

/** The most characters a project name may have. */
export const maxName = 40

/** The name of the file that makes a folder a project. */
export const projectFileName = "project.json"

/** Names a Windows file system keeps for devices, whatever the extension. */
const reserved: ReadonlySet<string> = new Set([
    "con",
    "prn",
    "aux",
    "nul",
    ...[1, 2, 3, 4, 5, 6, 7, 8, 9].flatMap((n) => [`com${n}`, `lpt${n}`]),
])

/** What a name may be made of: the characters every file system takes. */
const nameCharacters = /^[A-Za-z0-9._-]+$/

/** What a name must start with. */
const nameStart = /^[A-Za-z0-9]/

/** The message of a name that is taken by a project or by anything else in the folder. */
const takenMessage = "that project already exists!"

/** The message of a name that is taken by a folder with a `project.json` of no use. */
const brokenMessage = "that name is taken by a broken project folder!"

/**
 * What is wrong with `id` as the name of a new project, as a short message (the main
 * menu has room for 29 characters; the one for a broken folder is longer and the menu
 * makes room). The checks run in this order: empty, too long, characters, the first
 * character, a trailing dot, a reserved name, a name taken by a broken project folder,
 * a name taken.
 *
 * @param id - the name typed.
 * @param existing - every name already in the projects folder, projects or not.
 * @param broken - the names of the folders that have a `project.json` that cannot be
 *     used ([[brokenNames]]): they are neither listed nor free.
 * @returns the message, or `undefined` if the name is fine.
 */
export function nameProblem(
    id: string,
    existing: readonly string[],
    broken: readonly string[] = [],
): string | undefined {
    const lower = id.toLowerCase()
    const same = (names: readonly string[]) => names.some((n) => n.toLowerCase() === lower)
    if (id.trim() === "") return "type a name first!"
    if (id.length > maxName) return tooLong("name", maxName)
    if (!nameCharacters.test(id)) return "use only a-z 0-9 . _ -"
    if (!nameStart.test(id)) return "start with a letter or digit"
    if (id.endsWith(".")) return "must not end with a dot"
    if (reserved.has(lower.split(".")[0] ?? "")) return "reserved name, pick another"
    if (same(broken)) return brokenMessage
    if (same(existing)) return takenMessage
    return undefined
}

/**
 * What a `project.json` holds.
 *
 * @property id - the project's name, the same as its folder's.
 * @property created - the time it was made (ISO 8601, UTC), if the file says.
 */
export type ProjectInfo = {
    id: string
    created?: string
}

/**
 * The `project.json` of a project folder.
 *
 * @param dir - the folder.
 * @returns what it holds, or `undefined` if the folder is not a project: no such file,
 *     text that is not JSON, not an object, or an `id` that is not the folder's name.
 */
export function readProject(dir: string): ProjectInfo | undefined {
    const file = join(dir, projectFileName)
    if (!isFile(file)) return undefined
    const info = readJson<undefined>(file, undefined)
    if (!isDict(info)) return undefined
    if (info.id !== basename(dir)) return undefined
    const created = info.created
    return typeof created === "string" ? { id: info.id, created } : { id: info.id }
}

/**
 * The names of the folders of a projects folder that have a `project.json` that cannot
 * be used ([[readProject]]): [[listProjects]] hides them, but their names are taken.
 *
 * @param root - the projects folder.
 * @returns the names; empty if there is no such folder.
 */
export function brokenNames(root: string): string[] {
    return entryNames(root).filter((name) => {
        const dir = join(root, name)
        return isFolder(dir) && isFile(join(dir, projectFileName)) && !readProject(dir)
    })
}

/**
 * The ids of the projects in a projects folder.
 *
 * @param root - the projects folder.
 * @returns the ids, sorted without regard to case; empty if there is none.
 */
export function listProjects(root: string): string[] {
    const projects = entryNames(root).filter((name) => {
        const dir = join(root, name)
        return isFolder(dir) && readProject(dir) !== undefined
    })
    return sortNoCase(projects)
}

/**
 * The error of a name that is not valid or is taken.
 *
 * @param reason - what [[nameProblem]] says, short enough for the main menu.
 * @param id - the name.
 */
export class InvalidNameError extends Error {
    constructor(
        readonly reason: string,
        readonly id: string,
    ) {
        super(reason)
        this.name = "InvalidNameError"
    }
}

/**
 * What [[createProject]] leaves to the settings module.
 *
 * @property prepareGlobal - makes and checks the global `settings.json` before anything
 *     is made (it may throw: then no project is made).
 * @property copySettings - copies the global `settings.json` into the folder it is given
 *     as the project's own (it may throw: the half-made project is removed).
 */
export type CreateHooks = {
    prepareGlobal: () => void
    copySettings: (projectDir: string) => void
}

/**
 * Makes a project: its folder, its `project.json` and, through the hook, an exact copy
 * of the global settings.
 *
 * @param appRoot - the BAYSOL folder.
 * @param id - the name of the project.
 * @param hooks - what the settings module does ([[CreateHooks]]).
 * @param now - the time to write as `created`.
 * @returns the project's folder.
 * @throws [[InvalidNameError]] if the name is not valid or is taken, and anything the
 *     hooks throw. A project that was half made is removed again (only the folder this
 *     call made).
 */
export function createProject(
    appRoot: string,
    id: string,
    hooks: CreateHooks,
    now: Date = new Date(),
): string {
    const root = ensureDir(projectsRoot(appRoot))
    const problem = nameProblem(id, entryNames(root), brokenNames(root))
    if (problem !== undefined) throw new InvalidNameError(problem, id)
    const dir = join(root, id)
    hooks.prepareGlobal()
    try {
        mkdirSync(dir)
    } catch {
        throw new InvalidNameError(takenMessage, id)
    }
    try {
        writeAtomic(
            join(dir, projectFileName),
            writeJson({ id, created: now.toISOString() }),
        )
        hooks.copySettings(dir)
        return dir
    } catch (error) {
        rmSync(dir, { recursive: true, force: true })
        throw error
    }
}
