// SPDX-License-Identifier: LGPL-3.0-or-later

import { join } from "node:path"
import {
    assertUnchanged,
    isDict,
    noteRead,
    noteWritten,
    quarantine,
    type ReadOptions,
    readMap,
    UnusableFileError,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/files.js"
import { fold } from "../core/text.js"
import { MAX_ROWS } from "./limits.js"

/** What the message of a name used twice says (also the one of a rename onto a name). */
const NAME_IN_USE = "name in use"

/**
 * What a [[ListFile]] needs to know about its file.
 *
 * @property fileName - the name of the file in its folder, e.g. `recipes.json`.
 * @property key - the key of the JSON object under which the list is kept, e.g. `recipes`.
 * @property kind - the kind carried by the errors, so a screen can tell the files apart.
 * @property plural - what the entries are called in messages (`solutes`, `recipes`).
 * @property noun - what one entry is called in the message of a refused entry (`buffer
 *     row`, `recipe`).
 * @property problem - what is wrong with one entry (a value of the file or of a save), or
 *     `undefined` when it is fine. Applied to every entry on read and on write.
 * @property nameOf - the name an entry is known by, left out for a list whose entries have
 *     none. With it, names must differ without regard to case (and to the spaces at the
 *     ends), and [[ListFile.remove]] and [[ListFile.indexOf]] work.
 * @property createParents - `false` for a file that lives in a project's folder: a folder
 *     that is gone is not made again. Default `true`.
 */
export type ListSpec<T> = {
    fileName: string
    key: string
    kind: string
    plural: string
    noun: string
    problem: (entry: unknown) => string | undefined
    nameOf?: (entry: T) => string
    createParents?: boolean
}

/**
 * A JSON file that holds a list of entries under one key of a JSON object, the one
 * mechanism of the buffer of a project, the recipes and the custom solutes:
 *
 *     {"<key>": [entry, entry, ...], ...other keys kept as they are...}
 *
 * It owns what those files have in common:
 *
 * - the read, plain or `{track: true}` (the version read is the base that the next write
 *   checks, so a save after another copy of the program saved the file is refused);
 * - the write, under the file's lock, through a temporary file, with the other keys of
 *   the map kept and the version noted afterwards;
 * - the rule that a file that cannot be used (not JSON, not a map, an entry that
 *   `problem` refuses, a name twice, more than [[MAX_ROWS]] entries) is told
 *   ([[UnusableFileError]]) and never written over; [[ListFile.reset]] moves it aside;
 * - the same rules for what a save is given, so a file the program writes is one it reads;
 * - removing one entry by name, and the read-change-write of one step
 *   ([[ListFile.update]]).
 *
 * A missing or empty file is an empty list. One instance serves every folder: each method
 * takes the folder the file is in.
 *
 * @typeParam T - the entry.
 */
export class ListFile<T> {
    /**
     * @param spec - what the file is, see [[ListSpec]].
     */
    constructor(private readonly spec: ListSpec<T>) {}

    /**
     * The file in a folder.
     *
     * @param dir - the folder (the BAYSOL data folder, or a project's).
     * @returns the path.
     */
    file(dir: string): string {
        return join(dir, this.spec.fileName)
    }

    /** What is wrong with a whole list, or `undefined`: the cap, each entry, the names. */
    private listProblem(list: unknown): string | undefined {
        const { plural, noun, problem, nameOf } = this.spec
        if (!Array.isArray(list)) return `${plural} is not an array`
        if (list.length > MAX_ROWS) return `too many ${plural} (${MAX_ROWS} at most)`
        for (const entry of list) {
            const why = isDict(entry) ? problem(entry) : "an entry is not a map"
            if (why !== undefined) return `not a valid ${noun}: ${why}`
        }
        if (nameOf !== undefined) {
            const names = (list as T[]).map((e) => fold(nameOf(e)))
            if (new Set(names).size !== names.length) return NAME_IN_USE
        }
        return undefined
    }

    /**
     * The whole map of the file, checked.
     *
     * @param dir - the folder.
     * @returns the map; `{}` for no file or no content.
     * @throws UnusableFileError (the spec's kind) if the file cannot be used.
     */
    private readMap(dir: string): Record<string, unknown> {
        const { fileName, kind, plural, key } = this.spec
        return readMap(this.file(dir), {
            kind,
            name: fileName,
            expected: `a map of valid ${plural}`,
            valid: (map) => this.listProblem(key in map ? map[key] : []) === undefined,
        })
    }

    /**
     * The entries of the file in a folder.
     *
     * @param dir - the folder.
     * @param options - `track: true` when the entries are read to be edited and saved: the
     *     version read is then the one [[ListFile.write]] checks against. A plain read
     *     changes nothing about that.
     * @returns the entries, in file order (empty for none).
     * @throws UnusableFileError if the file cannot be used.
     */
    read(dir: string, options: ReadOptions = {}): T[] {
        if (options.track) noteRead(this.file(dir))
        const list = this.readMap(dir)[this.spec.key]
        return Array.isArray(list) ? (list as T[]) : []
    }

    /**
     * Whether a list may be written: the same rules the read applies.
     *
     * @param list - the entries.
     * @throws UnusableFileError (the spec's kind) with the reason, before anything is
     *     touched.
     */
    private assertWritable(list: readonly T[]): void {
        const why = this.listProblem(list)
        if (why !== undefined) throw new UnusableFileError(why, this.spec.kind)
    }

    /** The write itself, for a caller that holds the lock and has checked what is there. */
    private writeLocked(dir: string, list: readonly T[]): string {
        const file = this.file(dir)
        this.assertWritable(list)
        const { [this.spec.key]: _old, ...others } = this.readMap(dir)
        writeAtomic(file, writeJson({ [this.spec.key]: list, ...others }), this.folder())
        noteWritten(file)
        return file
    }

    private folder(): { createParents: boolean } {
        return { createParents: this.spec.createParents ?? true }
    }

    /**
     * Writes the entries as the list of the folder, the other keys of the file kept,
     * through a temporary file that replaces it in one step. The file is made if there is
     * none; one that cannot be used is not touched.
     *
     * @param dir - the folder.
     * @param list - the entries; they must keep the rules of the spec.
     * @returns the file.
     * @throws ChangedOnDiskError if another copy of the program saved the file after this
     *     one read it (nothing is written); UnusableFileError (the spec's kind) for
     *     entries that break the rules (nothing is written) or a file that cannot be used.
     */
    write(dir: string, list: readonly T[]): string {
        this.assertWritable(list)
        const file = this.file(dir)
        return withFileLock(
            file,
            () => {
                assertUnchanged(file)
                return this.writeLocked(dir, list)
            },
            this.folder(),
        )
    }

    /**
     * Reads, changes and writes in one step under the lock, so a change never loses
     * another copy's changes to the other entries.
     *
     * @param dir - the folder.
     * @param change - given the entries as they are on disk now; returns the new list, or
     *     `undefined` to leave the file alone.
     * @param options - `guarded: true` for a caller that shows the file as it read it for
     *     editing: the change then refuses when another copy saved the file since.
     * @returns whether a list was written.
     * @throws ChangedOnDiskError when `guarded` and the file changed since this process
     *     read it; UnusableFileError like [[ListFile.write]].
     */
    update(
        dir: string,
        change: (list: T[]) => readonly T[] | undefined,
        options: { guarded?: boolean } = {},
    ): boolean {
        const file = this.file(dir)
        return withFileLock(
            file,
            () => {
                if (options.guarded) assertUnchanged(file)
                const next = change(this.read(dir))
                if (next === undefined) return false
                this.writeLocked(dir, next)
                return true
            },
            this.folder(),
        )
    }

    /**
     * The position of the entry with a name.
     *
     * @param list - the entries.
     * @param name - the name, compared without regard to case and to the spaces at the
     *     ends.
     * @returns the index, or `undefined`.
     * @throws Error for a list without `nameOf`.
     */
    indexOf(list: readonly T[], name: string): number | undefined {
        const { nameOf } = this.spec
        if (nameOf === undefined) throw new Error(`${this.spec.fileName} has no names`)
        const t = fold(name)
        const i = list.findIndex((e) => fold(nameOf(e)) === t)
        return i < 0 ? undefined : i
    }

    /**
     * Removes ONE entry by name, at once: the file is read again under the lock and only
     * that entry is dropped.
     *
     * @param dir - the folder.
     * @param name - the entry's name, without regard to case.
     * @param options - `guarded`, as for [[ListFile.update]].
     * @returns whether there was such an entry (nothing is written when there was not).
     * @throws like [[ListFile.update]].
     */
    remove(dir: string, name: string, options: { guarded?: boolean } = {}): boolean {
        return this.update(
            dir,
            (list) => {
                const i = this.indexOf(list, name)
                return i === undefined ? undefined : list.filter((_, j) => j !== i)
            },
            options,
        )
    }

    /**
     * Starts the list over after the file was found unusable: the file is renamed to
     * `<name>.corrupt` (replacing an older one), so nothing is lost and a new one can be
     * written.
     *
     * @param dir - the folder.
     * @returns the path of the kept file, or `undefined` if there was no file.
     * @throws if it cannot be renamed.
     */
    reset(dir: string): string | undefined {
        return quarantine(this.file(dir))
    }
}
