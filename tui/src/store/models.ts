// SPDX-License-Identifier: LGPL-3.0-or-later

import { constants, copyFileSync, mkdirSync, unlinkSync } from "node:fs"
import { basename, join } from "node:path"
import { entryNames, isFile, sortNoCase } from "../core/files.js"
import { checkPath } from "./path-input.js"
import { inProject } from "./projects.js"

/**
 * The models of a project: the structure files (`.cif` or `.pdb`) in its `models/`
 * folder. A model is always a COPY of the file the user named, never the file itself, so
 * adding one cannot lose anything; the only way a model leaves the folder is
 * [[deleteModel]], which the screen asks twice for. A project with no `models/` folder,
 * or an empty one, or one whose files were all deleted, has no models: nothing here
 * tells these apart ([[listModels]] is empty for all three, and the folder is never
 * removed).
 */

/** The file modelExtensions a model may have, lower case, without the dot. */
const modelExtensions: ReadonlySet<string> = new Set(["cif", "pdb"])

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
    return dot >= 0 && modelExtensions.has(fileName.slice(dot + 1).toLowerCase())
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

/** The model prompt takes only structure files. */
const ONLY_STRUCTURES = { accept: accepted, message: "only .cif and .pdb files" }

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
export function modelPathProblem(
    path: string,
    existing: readonly string[],
): string | undefined {
    const problem = checkPath(path, 42, ONLY_STRUCTURES)
    if (problem !== undefined) return problem
    const lower = basename(path).toLowerCase()
    return existing.some((n) => n.toLowerCase() === lower)
        ? "a model with that name exists"
        : undefined
}

/**
 * Copies a file into the `models/` folder of a project, made if need be, under the same
 * name. The original is not touched, and a model that is there is never overwritten.
 *
 * @param projectDir - the project's folder.
 * @param path - the file to copy.
 * @returns the copy.
 * @throws ProjectGoneError if the project's folder does not exist (it is not made);
 *     an error if the copy cannot be made, a model of that name being there included;
 *     nothing is deleted then.
 */
export function addModel(projectDir: string, path: string): string {
    const dir = modelsDir(projectDir)
    const target = join(dir, basename(path))
    return inProject(projectDir, () => {
        try {
            mkdirSync(dir) // not recursive: the project's folder must be there
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error
        }
        copyFileSync(path, target, constants.COPYFILE_EXCL)
        return target
    })
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
 * Adds each of the files as [[addModel]] does; the ones that fail [[modelPathProblem]] (or
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
        let reason = modelPathProblem(path, existing)
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
