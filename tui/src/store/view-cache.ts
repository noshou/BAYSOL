// SPDX-License-Identifier: LGPL-3.0-or-later

// The temporary copies the viewers open (a workbook held as a tree in a run's
// archive is zipped again into a `.xlsx` on disk). They live in the `view`
// folder of the process's scratch folder (`core/scratch.ts`:
// `<tmp>/baysol/<pid>/view/`, removed when the program ends and swept by a later
// start after a crash); this module keeps that folder under a size cap. Every
// function takes the folder as a parameter, so tests never touch the real one.
//
// Contents:
//   1. The size cap

import { existsSync, readdirSync, rmSync, utimesSync } from "node:fs"
import { join } from "node:path"
import { measure } from "../core/scratch.js"

// ========================================================================================
// 1. The size cap
// ========================================================================================

/**
 * Marks a copy as just used, so the cap evicts the least recently used first.
 *
 * @param folder - the copy's folder (one entry of the view folder).
 */
export function touchCopy(folder: string): void {
    try {
        const now = new Date()
        utimesSync(folder, now, now)
    } catch {
        // gone: the next open makes it again
    }
}

/**
 * Keeps the copies under a size cap: while their total is over `capBytes`, the oldest
 * copy (an entry of `folder`, by the latest modification time inside it) is removed,
 * never `keep`. A folder that does not exist has nothing to trim.
 *
 * @param folder - the view folder (each entry is one copy's folder).
 * @param capBytes - the most the copies may hold in all.
 * @param keep - the name of the entry never removed (the one being opened).
 * @returns the names removed, oldest first.
 */
export function trimCopies(folder: string, capBytes: number, keep?: string): string[] {
    if (!existsSync(folder)) return []
    const copies: { name: string; bytes: number; time: number }[] = []
    for (const name of readdirSync(folder)) {
        try {
            copies.push({ name, ...measure(join(folder, name)) })
        } catch {
            // gone since the listing
        }
    }
    copies.sort((a, b) => a.time - b.time)
    let total = copies.reduce((sum, c) => sum + c.bytes, 0)
    const removed: string[] = []
    for (const copy of copies) {
        if (total <= capBytes) break
        if (copy.name === keep) continue
        try {
            rmSync(join(folder, copy.name), { recursive: true, force: true })
            total -= copy.bytes
            removed.push(copy.name)
        } catch {
            // in use: left
        }
    }
    return removed
}
