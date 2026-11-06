// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import { isDict, type ReadOptions } from "../core/files.js"
import { type CustomEntry, MAX_UNITS } from "./custom.js"
import { ListFile } from "./list-file.js"

/**
 * The custom solutes of the user: `custom-solutes.json` in the BAYSOL data folder, next
 * to `settings.json` (so it belongs to the user, not to a project, and a reset of the
 * settings never touches it). A JSON object whose `solutes` is an array of the entries,
 * one object each:
 *
 *     {"kind": "nonbiological", "name": "N-acetylcysteine ethyl ester",
 *      "formula": "C7H13NO3S", "z": 100, "pmv": 118.4, "sigma": 4.0}
 *     {"kind": "polymer", "name": "chain-2",
 *      "units": [{"label": "A", "formula": "C2H4O", "z": 24, "slope": 36.73,
 *                 "sigma": null},
 *                {"label": "B", "formula": "C3H6O", "z": 32, "slope": 53.1,
 *                 "sigma": 0.1}],
 *      "z-ends": 10, "pmv-ends": 19.24, "sigma-ends": null}
 *
 * See `./custom.ts` for what the fields mean; the schema is frozen in
 * `test/fixtures/buffer/custom-solutes.json`. Other keys of the map are kept as they are
 * on write. A missing or empty file is no entries; a file that is not a
 * JSON object, whose `solutes` is not an array of objects, that has more than [[MAX_ROWS]]
 * entries, or has a polymer without 1 to [[MAX_UNITS]] units (an entry of the
 * single-unit shape older than this one has none) is unusable, and is never written over.
 */

/** The name of the file in the BAYSOL folder. */
export const customSolutesFileName = "custom-solutes.json"

/**
 * The custom solutes file of the BAYSOL folder.
 *
 * @param root - the BAYSOL data folder.
 * @returns the path.
 */
export function customFile(root: string): string {
    return join(root, customSolutesFileName)
}

/**
 * What is wrong with an entry: not a map or, if it is a polymer, without an array of
 * 1 to [[MAX_UNITS]] unit maps.
 *
 * @param e - a value of the file or of a save.
 * @returns the message, or `undefined` when it can be kept.
 */
function entryProblem(e: unknown): string | undefined {
    if (!isDict(e)) return "an entry is not a map"
    if (e.kind !== "polymer") return undefined
    const u = e.units
    const ok = Array.isArray(u) && u.length >= 1 && u.length <= MAX_UNITS && u.every(isDict)
    return ok ? undefined : `a polymer needs 1-${MAX_UNITS} units`
}

/** The list file of the custom solutes; names differ without regard to case. */
const list = new ListFile<CustomEntry>({
    fileName: customSolutesFileName,
    key: "solutes",
    kind: "custom-solutes",
    plural: "solutes",
    noun: "custom solute",
    problem: entryProblem,
    nameOf: (e) => e.name,
})

/**
 * The custom solutes of the folder.
 *
 * @param root - the BAYSOL data folder.
 * @param options - `track: true` when the entries are read to be edited and saved (see
 *     `readSolutes` of ./buffer.ts); a plain read leaves the base of the check alone.
 * @returns the entries (empty for none).
 * @throws UnusableFileError (kind `custom-solutes`) if the file cannot be used.
 */
export function readCustomSolutes(root: string, options: ReadOptions = {}): CustomEntry[] {
    return list.read(root, options)
}

/**
 * Removes ONE saved entry from the file at once, leaving every other entry (and key) as
 * the file has it: the delete of the custom solutes table, which writes nothing else.
 * It takes the lock and refuses when another copy saved the file after this one read it.
 *
 * @param root - the BAYSOL data folder.
 * @param name - the name of the saved entry, without regard to case.
 * @returns whether there was such an entry (nothing is written when there was not).
 * @throws ChangedOnDiskError if the file changed since this process read it;
 *     UnusableFileError (kind `custom-solutes`) for a file that cannot be used.
 */
export function removeCustomSolute(root: string, name: string): boolean {
    return list.remove(root, name, { guarded: true })
}

/**
 * Writes the entries as the custom solutes of the folder, the other keys of the file
 * kept, through a temporary file that replaces it in one step. The file is made if there
 * is none; one that cannot be used is not touched. Nothing is written when the entries
 * break the rules above or two of them have the same name (case-insensitively).
 *
 * @param root - the BAYSOL data folder.
 * @param solutes - the entries, at most [[MAX_ROWS]].
 * @returns the file.
 * @throws ChangedOnDiskError if another copy of the program saved the file after this
 *     one read it (nothing is written); UnusableFileError (kind `custom-solutes`) for too
 *     many entries, a polymer without 1 to [[MAX_UNITS]] units, a name used twice, or a
 *     file that cannot be used.
 */
export function writeCustomSolutes(root: string, solutes: readonly CustomEntry[]): string {
    return list.write(root, solutes)
}
