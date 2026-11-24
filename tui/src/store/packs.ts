// SPDX-License-Identifier: LGPL-3.0-or-later

// Packs: the files of a project that are kept in ONE `.7z` archive, flat (the entry is the
// file name): the models (`models.7z`, the `.cif` and `.pdb` files) and the reference fit
// (`reference-fit.7z`). Both keep the folder they replaced readable: a project without the
// archive is read from its plain folder, the first add or remove writes the archive (the
// plain files plus the change) and from then on the archive is the list. The plain folder
// is never touched here: only its owner deletes it.
//
// None of these functions locks: the callers wrap the writes in `lockedIn` (projects.ts
// imports this file, so it cannot import that one); the asynchronous writes get that
// wrapper as an argument ([[Locked]]). The details are in notes/models-7z.md.
//
// Contents:
//   1. What a pack is and how it reads
//   2. Reading the files
//   3. Writing
//   4. Writing without blocking

import {
    copyFileSync,
    mkdirSync,
    readFileSync,
    rmSync,
    writeFileSync,
} from "node:fs"
import { rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import {
    ArchiveError,
    extractNamesSync,
    type Locked,
    listEntries,
    readEntry,
    rewriteArchiveAsync,
    rewriteArchiveSync,
} from "../core/archive.js"
import {
    entryNames,
    isFile,
    messageOf,
    quarantine,
    sortNoCase,
} from "../core/file-system.js"
import { scratchTemp } from "../core/scratch.js"

// ========================================================================================
// 1. What a pack is and how it reads
// ========================================================================================

/**
 * One kind of packed files.
 *
 * @property archive - the archive's file name in the project folder (`models.7z`).
 * @property folder - the plain folder that held the files before (`models`).
 * @property accepts - whether a file name belongs in the pack (checked in any case).
 */
export type Pack = {
    archive: string
    folder: string
    accepts: (name: string) => boolean
}

/** A name that is taken, in a pack (case does not matter). */
export class PackNameTaken extends Error {}

/** @returns the archive of a pack in a project (it may not exist). */
export const packFile = (projectDir: string, pack: Pack): string =>
    join(projectDir, pack.archive)

/**
 * Where a pack's files are now.
 *
 * - `plain`: no archive, the plain folder is the list (the old layout, or nothing yet);
 * - `packed`: the archive is the list (the plain folder, if any, is ignored);
 * - `unusable`: an archive that 7-Zip cannot read, the plain folder is read meanwhile and
 *   `problem` says why (a write renames the archive to `.corrupt` first, unless 7-Zip
 *   itself is missing or cannot run, `noTool`: then the archive may be fine and a write is
 *   refused instead).
 *
 * `names` are the files, sorted without regard to case. A packed archive may hold more
 * than the pack accepts (the generated files of the models, `store/projects.ts`): its
 * `entries` are all of them, and a rewrite carries every one over.
 */
export type PackState =
    | { kind: "plain"; names: string[] }
    | { kind: "packed"; names: string[]; entries: string[] }
    | { kind: "unusable"; names: string[]; problem: string; noTool?: true }

/** The accepted files of the plain folder, sorted. */
function plainNames(projectDir: string, pack: Pack): string[] {
    const dir = join(projectDir, pack.folder)
    const found = entryNames(dir).filter((n) => pack.accepts(n) && isFile(join(dir, n)))
    return sortNoCase(found)
}

/**
 * The state of a pack: one listing of the archive (cached while the file stays), nothing
 * extracted. Never throws.
 */
export function packState(projectDir: string, pack: Pack): PackState {
    const archive = packFile(projectDir, pack)
    if (!isFile(archive)) return { kind: "plain", names: plainNames(projectDir, pack) }
    try {
        const entries = listEntries(archive).map((e) => e.name)
        return {
            kind: "packed",
            names: sortNoCase(entries.filter(pack.accepts)),
            entries,
        }
    } catch (error) {
        const why = messageOf(error, "cannot be read")
        const noTool = /^(no 7-Zip found|7-Zip could not run)/.test(why)
        return {
            kind: "unusable",
            names: plainNames(projectDir, pack),
            problem: `${pack.archive} is unusable: ${why}`,
            ...(noTool ? { noTool: true as const } : {}),
        }
    }
}

/** @returns the names of a pack's files, sorted without regard to case. */
export const packNames = (projectDir: string, pack: Pack): string[] =>
    packState(projectDir, pack).names

/** @returns why the pack's archive cannot be read, `undefined` when it can (or is none). */
export function packProblem(projectDir: string, pack: Pack): string | undefined {
    const state = packState(projectDir, pack)
    return state.kind === "unusable" ? state.problem : undefined
}

// ========================================================================================
// 2. Reading the files
// ========================================================================================

/**
 * The bytes of one file of a pack, from the archive (decoded once for all of its entries
 * while it stays the same) or the plain folder.
 *
 * @throws [[ArchiveError]] for a file the pack does not hold or an archive that cannot be
 *     read; the system's error for a plain file that cannot be read.
 */
export function readPackFile(projectDir: string, pack: Pack, name: string): Buffer {
    const state = packState(projectDir, pack)
    if (!state.names.includes(name))
        throw new ArchiveError(`${pack.archive} holds no ${name}`)
    if (state.kind === "packed") return readEntry(packFile(projectDir, pack), name)
    return readFileSync(join(projectDir, pack.folder, name))
}

/**
 * Puts files of a pack into a folder (made if need be) under their names: extracted from
 * the archive in one 7-Zip run, or copied from the plain folder.
 *
 * @throws [[ArchiveError]] for a name the pack does not hold, or a 7-Zip that fails; the
 *     system's error for a copy that fails.
 */
export function extractPack(
    projectDir: string,
    pack: Pack,
    names: readonly string[],
    into: string,
): void {
    const state = packState(projectDir, pack)
    const lacking = names.find((n) => !state.names.includes(n))
    if (lacking !== undefined) throw new ArchiveError(`${pack.archive} holds no ${lacking}`)
    mkdirSync(into, { recursive: true })
    if (state.kind === "packed")
        extractNamesSync(packFile(projectDir, pack), names, into)
    else
        for (const n of names) copyFileSync(join(projectDir, pack.folder, n), join(into, n))
}

// ========================================================================================
// 3. Writing
// ========================================================================================

/**
 * Rewrites the pack with `change` applied to its list: the archive is built beside the old
 * one and renamed over it ([[rewriteArchiveSync]]). From a plain folder the files are
 * packed as they are (the folder stays); an unusable archive is renamed to `.corrupt`
 * first and never overwritten.
 */
function rewrite(
    projectDir: string,
    pack: Pack,
    state: PackState,
    drop: readonly string[],
    add: [name: string, source: string] | undefined,
): void {
    const archive = packFile(projectDir, pack)
    assertWritable(state)
    const { keep, added } = carryOver(projectDir, pack, state, drop)
    if (state.kind === "unusable") quarantine(archive)
    if (add !== undefined) added.set(add[0], add[1])
    rewriteArchiveSync(archive, keep, added)
}

/**
 * Refuses a write when the archive could not be read only because 7-Zip is missing: it
 * must not be renamed to `.corrupt` for that.
 *
 * @throws [[ArchiveError]] with the state's problem.
 */
function assertWritable(state: PackState): void {
    if (state.kind === "unusable" && state.noTool) throw new ArchiveError(state.problem)
}

/**
 * What a rewrite keeps of the pack as it is: the archive's entries (all of them, the
 * generated files too) or, from a plain folder, its files as paths to pack, less `drop`.
 */
function carryOver(
    projectDir: string,
    pack: Pack,
    state: PackState,
    drop: readonly string[],
): { keep: string[]; added: Map<string, string> } {
    const added = new Map<string, string>()
    if (state.kind === "packed")
        return { keep: state.entries.filter((n) => !drop.includes(n)), added }
    for (const n of state.names)
        if (!drop.includes(n)) added.set(n, join(projectDir, pack.folder, n))
    return { keep: [], added }
}

/**
 * Adds a file to the pack, the file at `source` under `name`. The caller holds the lock.
 *
 * @throws [[PackNameTaken]] when a file of that name (any case) is there,
 *     [[ArchiveError]] for an unsafe name or a 7-Zip that is missing or fails (the old
 *     archive is then as it was), the system's error for a source that cannot be read.
 */
export function packAdd(
    projectDir: string,
    pack: Pack,
    name: string,
    source: string,
): void {
    const state = packState(projectDir, pack)
    const lower = name.toLowerCase()
    if (state.names.some((n) => n.toLowerCase() === lower))
        throw new PackNameTaken(`a file named ${name} is in ${pack.archive}`)
    rewrite(projectDir, pack, state, [], [name, source])
}

/** [[packAdd]] for text that is not a file yet (it goes through a temporary file). */
export function packAddText(
    projectDir: string,
    pack: Pack,
    name: string,
    text: string,
): void {
    const folder = scratchTemp("add")
    try {
        const source = join(folder, "source")
        writeFileSync(source, text)
        packAdd(projectDir, pack, name, source)
    } finally {
        rmSync(folder, { recursive: true, force: true })
    }
}

/**
 * Removes one file from the pack, by its exact name (the archive is rewritten without it;
 * a plain folder is packed without it and stays as it is), and `alsoDrop` with it (entries
 * that are no file of the pack, e.g. generated ones). The caller holds the lock.
 *
 * @returns whether the file was there.
 * @throws [[ArchiveError]] for a 7-Zip that is missing or fails.
 */
export function packRemove(
    projectDir: string,
    pack: Pack,
    name: string,
    alsoDrop: readonly string[] = [],
): boolean {
    const state = packState(projectDir, pack)
    if (!state.names.includes(name)) return false
    rewrite(projectDir, pack, state, [name, ...alsoDrop], undefined)
    return true
}

// ========================================================================================
// 4. Writing without blocking
// ========================================================================================

/** The tail of each archive's queue of writes of this process, by archive path. */
const queues = new Map<string, Promise<unknown>>()

/** The writes of this process that have not finished. */
const pendingWrites = new Set<Promise<unknown>>()

/**
 * Runs `job` after every write queued before it on the same archive, so two writes of this
 * process never interleave (the failure of one does not stop the next).
 */
function queued<T>(key: string, job: () => Promise<T>): Promise<T> {
    const run = (queues.get(key) ?? Promise.resolve()).then(job)
    const tail = run.then(
        () => undefined,
        () => undefined,
    )
    queues.set(key, tail)
    pendingWrites.add(tail)
    void tail.then(() => {
        pendingWrites.delete(tail)
        if (queues.get(key) === tail) queues.delete(key)
    })
    return run
}

/** Waits until every write queued so far has finished (the quit paths call it). */
export async function settleWrites(): Promise<void> {
    while (pendingWrites.size > 0) await Promise.all([...pendingWrites])
}

/**
 * What a change of a pack is: the entries to drop, the files to add (name to the path of
 * the source) and the texts to add (name to its content; written to a temporary file).
 */
export type PackPlan = {
    drop?: readonly string[]
    add?: ReadonlyMap<string, string>
    texts?: ReadonlyMap<string, string>
}

/**
 * Changes the pack without blocking: `plan` is called when the write's turn comes (after
 * the writes queued before it) with the state of the pack then, and says what to do, or
 * `undefined` for nothing; the archive is built in the background ([[rewriteArchiveAsync]])
 * and renamed over under `locked`. From a plain folder the files are packed as they are
 * (the folder stays); an unusable archive is renamed to `.corrupt` first.
 *
 * @param plan - may throw (e.g. [[PackNameTaken]]): nothing is written then.
 * @param locked - holds the archive's lock for the final rename (`lockedIn` of the caller).
 * @returns whether the archive was rewritten.
 * @throws what `plan` throws, [[ArchiveError]] for an unsafe name, a 7-Zip that is missing
 *     or fails, or an archive another copy changed meanwhile (the old one is then as it
 *     was), the system's error for a source that cannot be read.
 */
export function packChangeAsync(
    projectDir: string,
    pack: Pack,
    plan: (state: PackState) => PackPlan | undefined,
    locked: Locked,
): Promise<boolean> {
    const archive = packFile(projectDir, pack)
    return queued(archive, async () => {
        const state = packState(projectDir, pack)
        const wanted = plan(state)
        if (wanted === undefined) return false
        assertWritable(state)
        const { keep, added } = carryOver(projectDir, pack, state, wanted.drop ?? [])
        for (const [name, source] of wanted.add ?? []) added.set(name, source)
        let folder: string | undefined
        try {
            if (wanted.texts !== undefined && wanted.texts.size > 0) {
                folder = scratchTemp("add")
                for (const [name, text] of wanted.texts) {
                    const source = join(folder, `${added.size}-text`)
                    await writeFile(source, text)
                    added.set(name, source)
                }
            }
            if (state.kind === "unusable") locked(() => quarantine(archive))
            await rewriteArchiveAsync(archive, keep, added, locked)
        } finally {
            if (folder !== undefined) await rm(folder, { recursive: true, force: true })
        }
        return true
    })
}

/**
 * Adds files to the pack without blocking, all in ONE rewrite ([[packChangeAsync]]).
 *
 * @param files - name to the path of the file.
 * @throws [[PackNameTaken]] when a name (any case) is there, plus what
 *     [[packChangeAsync]] throws.
 */
export async function packAddAsync(
    projectDir: string,
    pack: Pack,
    files: ReadonlyMap<string, string>,
    locked: Locked,
): Promise<void> {
    await packChangeAsync(
        projectDir,
        pack,
        (state) => {
            const taken = new Set(state.names.map((n) => n.toLowerCase()))
            for (const name of files.keys())
                if (taken.has(name.toLowerCase()))
                    throw new PackNameTaken(`a file named ${name} is in ${pack.archive}`)
            return { add: files }
        },
        locked,
    )
}
