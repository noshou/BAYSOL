// SPDX-License-Identifier: LGPL-3.0-or-later

// Typing a path: the one place that checks a typed path and completes it. The model
// prompt (`models.ts`) and the sequence prompt of the add flow (`add-flow.ts`) differ
// only in what files they want and in how many characters a message may have, so each
// hands its own message budget and file filter to the functions here.

import { existsSync } from "node:fs"
import { basename, isAbsolute, join, sep } from "node:path"
import { entryNames, isFolder, isReadable } from "../core/files.js"
import { compareNoCase } from "../core/text.js"

/** The most hints [[hintsFor]] gives. */
const maxHints = 50

/** The most characters of a path typed in any path prompt. */
export const MAX_PATH_TYPED = 300

/**
 * How many characters the message of a prompt may have: the model prompt has room for
 * 42, the sequence prompt of the add flow for 22. The wording of each is below.
 */
export type PathBudget = 22 | 42

/** What is said of a path the prompt refuses, for each budget. */
const WORDING: Record<
    PathBudget,
    { empty: string; relative: string; missing: string; folder: string; unreadable: string }
> = {
    42: {
        empty:      "type the full path of a model file first!",
        relative:   "use a full absolute path",
        missing:    "no such file",
        folder:     "that is a folder, not a file",
        unreadable: "cannot read that file",
    },
    22: {
        empty:      "type a path first!",
        relative:   "use a full path",
        missing:    "no such file",
        folder:     "that is a folder",
        unreadable: "cannot read the file",
    },
}

/**
 * What is wrong with a path as the file to read.
 *
 * The checks run in this order: empty, not absolute, not there, a folder, the wrong
 * kind of file, not readable.
 *
 * @param path - the path typed.
 * @param budget - the characters the message may have; picks the wording.
 * @param wrongKind - when the prompt takes only some files: the test on the file's name
 *     and the message (within `budget`) for one that fails it; checked before
 *     readability. Omit it when any file will do.
 * @returns the message, `undefined` if the path is fine.
 */
export function checkPath(
    path: string,
    budget: PathBudget,
    wrongKind?: { accept: (fileName: string) => boolean; message: string },
): string | undefined {
    const say = WORDING[budget]
    if (path.trim() === "") return say.empty
    if (!isAbsolute(path)) return say.relative
    if (!existsSync(path)) return say.missing
    if (isFolder(path)) return say.folder
    if (wrongKind && !wrongKind.accept(basename(path))) return wrongKind.message
    if (!isReadable(path)) return say.unreadable
    return undefined
}

/**
 * The part of a typed path up to and with its last separator.
 *
 * @param text - the path typed.
 * @returns the part up to `/` (or the system's own separator); `""` when there is none.
 */
function dirPart(text: string): string {
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
 * A typed path with its last part replaced by a hint.
 *
 * @param text - the path typed.
 * @param hint - one of [[hintsFor]].
 * @returns the completed path.
 */
export function complete(text: string, hint: string): string {
    return dirPart(text) + hint
}

/**
 * The suggestions of a path prompt: the folder's names that fit what is typed. Each is
 * shown by its name; Tab puts the whole completed path into the field.
 *
 * @param text - the path typed.
 * @param accept - says whether a file name is wanted.
 * @returns the suggestions, folders first; none for a folder that cannot be listed.
 */
export function pathSuggestions(
    text: string,
    accept: (fileName: string) => boolean,
): { label: string; completion: string }[] {
    try {
        return hintsFor(text, accept).map((hint) => ({
            label: hint,
            completion: complete(text, hint),
        }))
    } catch {
        return []
    }
}
