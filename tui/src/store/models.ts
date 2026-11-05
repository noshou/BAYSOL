// SPDX-License-Identifier: LGPL-3.0-or-later

import { constants, copyFileSync, existsSync, mkdirSync, unlinkSync } from "node:fs"
import { basename, isAbsolute, join, sep } from "node:path"
import {
    entryNames,
    isFile,
    isFolder,
    isReadable,
    sortNoCase,
} from "../core/files.js"
import { compareNoCase } from "../core/text.js"

/**
 * The models of a project: the structure files (`.cif` or `.pdb`) in its `models/`
 * folder. A model is always a COPY of the file the user named, never the file itself, so
 * adding one cannot lose anything; the only way a model leaves the folder is
 * [[deleteModel]], which the screen asks twice for. A project with no `models/` folder,
 * or an empty one, or one whose files were all deleted, has no models: nothing here
 * tells these apart ([[listModels]] is empty for all three, and the folder is never
 * removed).
 *
 * [[hints]] and [[complete]] are the autocompletion of a typed path.
 */

/** The file extensions a model may have, lower case, without the dot. */
export const extensions: ReadonlySet<string> = new Set(["cif", "pdb"])

/** The most hints [[hintsFor]] gives. */
const maxHints = 50

/** The message for a copy that failed for a reason the checks could not see. */
export const copyFailed = "could not copy the file!"

/**
 * The `models/` folder of a project.
 *
 * @param projectDir - the project's folder.
 * @returns `<project>/models`; it may not exist yet.
 */
export function modelsDir(projectDir: string): string {
    return join(projectDir, "models")
}

/**
 * Whether a file name has an extension a model may have.
 *
 * @param fileName - the name.
 * @returns the answer (case does not matter).
 */
export function accepted(fileName: string): boolean {
    const dot = fileName.lastIndexOf(".")
    return dot >= 0 && extensions.has(fileName.slice(dot + 1).toLowerCase())
}

/**
 * The names of the models of a project.
 *
 * @param projectDir - the project's folder.
 * @returns the `.cif` and `.pdb` files in its `models/` folder, sorted without regard
 *     to case; empty when there are none, whether the folder is missing, empty or
 *     emptied.
 */
export function listModels(projectDir: string): string[] {
    const dir = modelsDir(projectDir)
    const files = entryNames(dir).filter(
        (name) => accepted(name) && isFile(join(dir, name)),
    )
    return sortNoCase(files)
}

/**
 * What is wrong with a path as the file to add as a model.
 *
 * The checks run in this order: empty, not absolute, not there, a folder, the wrong
 * kind of file, not readable, name taken.
 *
 * @param path - the path typed.
 * @param existing - the names of the models there are.
 * @returns a short message (42 characters at most), or `undefined` if it is fine.
 */
export function pathProblem(path: string, existing: readonly string[]): string | undefined {
    const name = basename(path)
    const lower = name.toLowerCase()
    if (path.trim() === "") return "type a path first!"
    if (!isAbsolute(path)) return "use a full absolute path"
    if (!existsSync(path)) return "no such file"
    if (isFolder(path)) return "that is a folder, not a file"
    if (!accepted(name)) return "only .cif and .pdb files"
    if (!isReadable(path)) return "cannot read that file"
    if (existing.some((n) => n.toLowerCase() === lower))
        return "a model with that name exists"
    return undefined
}

/**
 * Copies a file into the `models/` folder of a project, made if need be, under the same
 * name. The original is not touched, and a model that is there is never overwritten.
 *
 * @param projectDir - the project's folder.
 * @param path - the file to copy.
 * @returns the copy.
 * @throws if the copy cannot be made, a model of that name being there included;
 *     nothing is deleted then.
 */
export function addModel(projectDir: string, path: string): string {
    const dir = modelsDir(projectDir)
    const target = join(dir, basename(path))
    mkdirSync(dir, { recursive: true })
    copyFileSync(path, target, constants.COPYFILE_EXCL)
    return target
}

/**
 * The outcome of [[addModels]].
 *
 * @property copied - the names of the models added.
 * @property skipped - the paths left out, each with its reason.
 */
export type AddResult = {
    copied: string[]
    skipped: [path: string, reason: string][]
}

/**
 * Adds each of the files as [[addModel]] does; the ones that fail [[pathProblem]] (or
 * whose copy fails) are left out. A name that comes twice is added once (the first
 * wins). Nothing here throws.
 *
 * @param projectDir - the project's folder.
 * @param paths - the files.
 * @returns what was copied and what was skipped.
 */
export function addModels(projectDir: string, paths: readonly string[]): AddResult {
    const result: AddResult = { copied: [], skipped: [] }
    for (const path of paths) {
        const existing = [...listModels(projectDir), ...result.copied]
        let reason = pathProblem(path, existing)
        if (reason === undefined) {
            try {
                addModel(projectDir, path)
            } catch {
                reason = copyFailed
            }
        }
        if (reason === undefined) result.copied.push(basename(path))
        else result.skipped.push([path, reason])
    }
    return result
}

/**
 * Deletes a model from the `models/` folder of a project. This is destructive and there
 * is no way back, so only a file that [[listModels]] lists is deleted, by its plain name
 * (a name with a path in it is refused).
 *
 * @param projectDir - the project's folder.
 * @param modelName - the model's name.
 * @returns `true` if the file was deleted.
 */
export function deleteModel(projectDir: string, modelName: string): boolean {
    if (!listModels(projectDir).includes(modelName)) return false
    try {
        unlinkSync(join(modelsDir(projectDir), modelName))
        return true
    } catch {
        return false
    }
}

// --- autocompletion of a typed path

/**
 * The part of a typed path up to and with its last separator.
 *
 * @param text - the path typed.
 * @returns the part up to `/` (or the system's own separator); `""` when there is none.
 */
export function dirPart(text: string): string {
    const cut = Math.max(text.lastIndexOf("/"), text.lastIndexOf(sep))
    return cut < 0 ? "" : text.slice(0, cut + 1)
}

/**
 * The names a typed path can go on with, for the folder it is in: folders (with a `/`
 * at the end) first, then the files whose name `accept` takes, those that start with
 * what is typed after the last separator (case does not matter). A name that starts
 * with a dot is given only when a dot is typed.
 *
 * @param text - the path typed.
 * @param accept - says whether a file name is wanted.
 * @returns at most 50 names; empty when `text` is not an absolute path in a folder
 *     that exists.
 */
export function hintsFor(text: string, accept: (fileName: string) => boolean): string[] {
    const dir = dirPart(text)
    const prefix = text.slice(dir.length).toLowerCase()
    if (dir.trim() === "" || !isAbsolute(dir) || !isFolder(dir)) return []
    const found: { folder: boolean; name: string }[] = []
    for (const name of entryNames(dir)) {
        const folder = isFolder(join(dir, name))
        const typed = name.toLowerCase().startsWith(prefix)
        const shown = prefix.startsWith(".") || !name.startsWith(".")
        if (typed && shown && (folder || accept(name))) found.push({ folder, name })
    }
    found.sort((a, b) =>
        a.folder !== b.folder ? (a.folder ? -1 : 1) : compareNoCase(a.name, b.name),
    )
    return found.slice(0, maxHints).map((f) => (f.folder ? `${f.name}/` : f.name))
}

/**
 * The hints of [[hintsFor]] for `.cif` and `.pdb` files.
 *
 * @param text - the path typed.
 * @returns the hints.
 */
export function hints(text: string): string[] {
    return hintsFor(text, accepted)
}

/**
 * A typed path with its last part replaced by a hint.
 *
 * @param text - the path typed.
 * @param hint - one of [[hints]].
 * @returns the completed path.
 */
export function complete(text: string, hint: string): string {
    return dirPart(text) + hint
}
