// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import {
    assertUnchanged,
    isDict,
    noteWritten,
    readMap,
    UnusableFileError,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/files.js"
import { fold } from "../core/text.js"
import { type CustomEntry, MAX_UNITS } from "./custom.js"
import { MAX_ROWS } from "./limits.js"

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

/** The kind carried by the errors of this file. */
const KIND = "custom-solutes"

/** The name of the file in the BAYSOL folder. */
export const customSolutesFileName = "custom-solutes.json"

type Dict = Record<string, unknown>

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
 * Whether a value is a map and, if it is a polymer, has an array of 1 to [[MAX_UNITS]]
 * unit maps.
 *
 * @param e - a value of the file or of a save.
 * @returns true if it can be kept.
 */
function usableEntry(e: unknown): boolean {
    if (!isDict(e)) return false
    if (e.kind !== "polymer") return true
    const u = e.units
    return Array.isArray(u) && u.length >= 1 && u.length <= MAX_UNITS && u.every(isDict)
}

/**
 * Reads the map in the file.
 *
 * @param root - the BAYSOL data folder.
 * @returns the map; `{}` for no file or no content.
 * @throws UnusableFileError (kind `custom-solutes`) if the file is not one JSON object of
 *     the kind described above.
 */
function readFileMap(root: string): Dict {
    return readMap(customFile(root), {
        kind: KIND,
        name: customSolutesFileName,
        expected: `a map of up to ${MAX_ROWS} solutes`,
        valid: (map) => {
            const solutes = "solutes" in map ? map.solutes : []
            return (
                Array.isArray(solutes) &&
                solutes.length <= MAX_ROWS &&
                solutes.every(usableEntry)
            )
        },
    })
}

/**
 * The custom solutes of the folder.
 *
 * @param root - the BAYSOL data folder.
 * @returns the entries (empty for none).
 * @throws UnusableFileError (kind `custom-solutes`) if the file cannot be used.
 */
export function readSolutes(root: string): CustomEntry[] {
    const solutes = readFileMap(root).solutes
    return Array.isArray(solutes) ? (solutes as CustomEntry[]) : []
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
 *     many entries, a polymer
 *     without 1 to [[MAX_UNITS]] units, a name used twice, or a file that cannot be used.
 */
export function writeSolutes(root: string, solutes: readonly CustomEntry[]): string {
    if (solutes.length > MAX_ROWS) throw new UnusableFileError("too many solutes", KIND)
    if (!solutes.every(usableEntry))
        throw new UnusableFileError("a polymer needs 1-4 units", KIND)
    const names = solutes.map((e) => fold(e.name))
    if (new Set(names).size !== names.length)
        throw new UnusableFileError("name in use", KIND)
    const file = customFile(root)
    return withFileLock(file, () => {
        assertUnchanged(file)
        const { solutes: _old, ...others } = readFileMap(root)
        writeAtomic(file, writeJson({ solutes, ...others }))
        noteWritten(file)
        return file
    })
}
