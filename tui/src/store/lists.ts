// SPDX-License-Identifier: LGPL-3.0-or-later

// Lists: the lists of rows the user keeps, the typed path and the pasted sequence.
//
// Contents:
//   1. Sequences: strict FASTA and FASTQ reader
//   2. Typed paths: check and complete
//   3. Limit: the most rows any list holds
//   4. List file: the JSON file of one list (solutes, custom solutes), its checks
//   5. Drafts: the rows of a table being edited, with what has not been saved

import { existsSync, readFileSync } from "node:fs"
import { basename, isAbsolute, join, sep } from "node:path"
import { isDeepStrictEqual } from "node:util"
import {
    assertUnchanged,
    entryNames,
    isDict,
    isFolder,
    isReadable,
    noteRead,
    noteWritten,
    quarantine,
    type ReadOptions,
    readMap,
    UnusableFileError,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import { compareNoCase, fold, NAME_IN_USE } from "../core/terminal.js"
import { isStructureFile, structureFasta } from "./structure-sequences.js"

// ========================================================================================
// 1. Sequences: strict FASTA and FASTQ reader
// ========================================================================================

/**
 * A strict reader of FASTA and FASTQ text for the DNA, RNA and protein rows of the
 * buffer. [[parseText]] and [[parseFile]] give every record as a [[Sequence]], or an
 * error of at most 22 characters (it is shown in a 24-character border note). One
 * record makes one buffer row.
 *
 * Alphabets are the ones the Julia code accepts: DNA `A C G T` plus the IUPAC codes
 * `R Y S W K M B D H V N`; RNA the same with `U` for `T`; protein the twenty residues,
 * `U`, `O` and the codes `B J Z`. `*` and `X` (protein) are placeholders: kept, but no
 * residue. The lint, one function for typed text, pasted text and files: a FASTA header
 * is dropped, letters are upper-cased, white space and numbering digits are dropped,
 * and nothing else is repaired: a gap, a stray symbol, a `T` in RNA or a `U` in DNA is
 * an error naming the character and its place (`invalid residue 'J' at 12`). A text
 * with no header is one sequence. There is no length cap.
 *
 * FASTA: a `>` header, then the sequence on one or more lines. FASTQ: strict four-line
 * records (`@id`, sequence, `+`, quality of the same length); only the sequence is
 * kept. The id is the header up to the first white space. Blank lines: anywhere in
 * FASTA, only around the records in FASTQ; CRLF is fine.
 */

/** A kind of sequence. */
export type SequenceKind = "dna" | "rna" | "protein"

/** The IUPAC ambiguity codes of nucleotides. */
const ambiguityNucleotide = "RYSWKMBDHVN"

/** The letters each kind accepts as residues. */
const alphabets: Readonly<Record<SequenceKind, ReadonlySet<string>>> = {
    dna: new Set(`ACGT${ambiguityNucleotide}`),
    rna: new Set(`ACGU${ambiguityNucleotide}`),
    protein: new Set("ACDEFGHIKLMNOPQRSTUVWYBJZ"),
}

/** The letters Julia skips, which are no residue. */
const placeholders: Readonly<Record<SequenceKind, ReadonlySet<string>>> = {
    dna: new Set("*"),
    rna: new Set("*"),
    protein: new Set("*X"),
}

/** The file sequenceExtensions (lower case, with the dot) of the sequence files. */
const sequenceExtensions: readonly string[] = [
    ".fasta",
    ".fa",
    ".fna",
    ".faa",
    ".fastq",
    ".fq",
]

/** The letters in a sequence that count as nothing, for every kind. */
const anyPlaceholder: ReadonlySet<string> = new Set("*X")

/**
 * One record of a sequence file.
 *
 * @param id - the header up to the first white space (`seqN` if it is empty).
 * @param letters - the sequence, cleaned and upper-cased, placeholders kept.
 */
class Sequence {
    constructor(
        readonly id: string,
        readonly letters: string,
    ) {}

    /** The number of residues: the letters without the placeholders `*` and `X`. */
    get residueCount(): number {
        return [...this.letters].filter((c) => !anyPlaceholder.has(c)).length
    }

    /**
     * The compact text for the params cell: `ACG…GCA (24 nt)` (DNA, RNA) or
     * `MKT…QLS (317 aa)`. The count is always kept; head and tail shrink (the head gets
     * the odd letter) to fit `width`, and the sequence is whole when it fits.
     *
     * @param kind - the kind of sequence.
     * @param width - the most characters.
     */
    summary(kind: SequenceKind, width: number): string {
        return summary(kind, this.letters, width)
    }
}

/** The records a sequence text or file gave. */
export type SequenceRecords = Sequence[]

/** What the readers give: the records, or the reason there are none. */
export type SequenceResult = { records: SequenceRecords } | { error: string }

/**
 * Whether a file name has a [[sequenceExtensions]] extension or is a PDB or mmCIF file.
 *
 * @param fileName - the name or path.
 */
export function isSequenceFile(fileName: string): boolean {
    const low = fileName.toLowerCase()
    return sequenceExtensions.some((e) => low.endsWith(e)) || isStructureFile(low)
}

/** A failed result. */
function fail(error: string): { error: string } {
    return { error }
}

/** The sequence text without white space (and, when `digits`, numbering), upper-cased. */
function clean(text: string, digits = false): string {
    return text.replace(digits ? /[\s\d]+/g : /\s+/g, "").toUpperCase()
}

/**
 * Lints sequence text and checks it against the alphabet of its kind. Returns the clean
 * letters (placeholders kept), or an error: `empty sequence`, `U is RNA, not DNA (at 5)`,
 * `T is DNA, not RNA (at 5)` or `invalid residue 'J' at 12` (places count clean letters
 * from 1).
 *
 * @param kind - the kind.
 * @param raw - the sequence as typed, pasted or read (no header line).
 * @param digits - drop numbering digits too (`true` for text and FASTA, not for FASTQ).
 */
function checkSequence(
    kind: SequenceKind,
    raw: string,
    digits = true,
): string | { error: string } {
    const letters = clean(raw, digits)
    const at = [...letters].findIndex(
        (c) => !alphabets[kind].has(c) && !placeholders[kind].has(c),
    )
    if (at >= 0) {
        const c = [...letters][at] as string
        const place = at + 1
        if (kind === "dna" && c === "U") return fail(`U is RNA, not DNA (at ${place})`)
        if (kind === "rna" && c === "T") return fail(`T is DNA, not RNA (at ${place})`)
        return fail(`invalid residue '${c}' at ${place}`)
    }
    if ([...letters].every((c) => placeholders[kind].has(c))) return fail("empty sequence")
    return letters
}

/**
 * The id of a header line: up to the first white space.
 *
 * @param header - the line, with its first character (`>` or `@`) still on.
 * @param fallback - the id when that is empty.
 */
function recordId(header: string, fallback: string): string {
    const id = header.slice(1).trim().split(/\s+/)[0] ?? ""
    return id === "" ? fallback : id
}

/** A record before its sequence is cleaned and checked. */
type RawRecord = { id: string; raw: string }

/**
 * Cleans and checks the raw records of a kind; the first error wins.
 *
 * @param kind - the kind.
 * @param raws - the records.
 */
function finish(
    kind: SequenceKind,
    raws: readonly RawRecord[],
    digits = true,
): SequenceResult {
    if (raws.length === 0) return fail("no records")
    const records: Sequence[] = []
    for (const { id, raw } of raws) {
        const checked = checkSequence(kind, raw, digits)
        if (typeof checked !== "string") return checked
        records.push(new Sequence(id, checked))
    }
    return { records }
}

/**
 * The raw records of FASTA lines.
 *
 * @param lines - the lines; the first is a header.
 */
function fastaRaws(lines: readonly string[]): RawRecord[] {
    const rest = lines.filter((l) => l.trim() !== "")
    const acc: RawRecord[] = []
    let i = 0
    while (i < rest.length) {
        const header = rest[i] as string
        let end = i + 1
        while (end < rest.length && !(rest[end] as string).startsWith(">")) end++
        acc.push({
            id: recordId(header, `seq${acc.length + 1}`),
            raw: rest.slice(i + 1, end).join(""),
        })
        i = end
    }
    return acc
}

/** The number of lines in a FASTQ record. */
const fastqLines = 4

/**
 * The records of FASTQ lines, or the first error.
 *
 * @param kind - the kind.
 * @param lines - the lines, blank ones at both ends already dropped.
 */
function fastqParse(kind: SequenceKind, lines: readonly string[]): SequenceResult {
    const acc: RawRecord[] = []
    for (let i = 0; i < lines.length; i += fastqLines) {
        const [head, sq, plus, quality] = lines.slice(i, i + fastqLines)
        if (!(head as string).startsWith("@")) return fail("bad FASTQ record")
        if (sq === undefined || plus === undefined || quality === undefined)
            return fail("missing line")
        if (!plus.startsWith("+")) return fail("bad FASTQ record")
        if (clean(sq).length !== quality.trim().length)
            return fail("quality length differs")
        acc.push({ id: recordId(head as string, `seq${acc.length + 1}`), raw: sq })
    }
    return finish(kind, acc, false)
}

/**
 * Parses FASTA, FASTQ or bare sequence text (one record, `seq1`). The error is for: no
 * records, an empty sequence, a broken FASTQ record, or a letter outside the alphabet.
 * Throws for another `kind`.
 *
 * @param text - the text: FASTA, FASTQ, or one sequence with no header on any number of
 *     lines.
 * @param kind - `dna`, `rna` or `protein`.
 */
export function parseText(text: string, kind: SequenceKind): SequenceResult {
    if (!Object.hasOwn(alphabets, kind)) throw new Error(`unknown sequence kind ${kind}`)
    const all = text.split(/\r?\n/).map((l) => l.replace(/\s+$/, ""))
    let start = 0
    let end = all.length
    while (start < end && (all[start] as string).trim() === "") start++
    while (end > start && (all[end - 1] as string).trim() === "") end--
    const lines = all.slice(start, end)
    const first = lines[0]
    if (first === undefined) return fail("no records")
    if (first.startsWith(">")) return finish(kind, fastaRaws(lines))
    if (first.startsWith("@")) return fastqParse(kind, lines)
    return finish(kind, [{ id: "seq1", raw: lines.join("\n") }])
}

/**
 * Whether a paste is not a field's text (a line break, or longer than `room`): it goes to
 * [[parseText]].
 *
 * @param text - the text pasted.
 * @param room - the characters the field has room for.
 */
export function isSequencePaste(text: string, room: number): boolean {
    const t = text.trim()
    return /[\r\n]/.test(t) || t.length > room
}

/**
 * The residues of records (placeholders not counted).
 *
 * @param records - the records.
 */
export function residuesOf(records: SequenceRecords): number {
    return records.reduce((n, r) => n + r.residueCount, 0)
}

/**
 * Parses a file like [[parseText]]; a PDB or mmCIF file gives its chains of this `kind`.
 * Throws for another `kind`.
 *
 * @param path - the file.
 * @param kind - `dna`, `rna` or `protein`.
 */
export function parseFile(path: string, kind: SequenceKind): SequenceResult {
    if (isStructureFile(path)) {
        const found = structureFasta(path, kind)
        return "error" in found ? found : parseText(found.text, kind)
    }
    let text: string
    try {
        text = readFileSync(path, "utf-8")
    } catch {
        return fail("cannot read file")
    }
    return parseText(text, kind)
}

/** The fewest letters of the head and tail together that are worth showing. */
const minShown = 3

/**
 * The compact text of a sequence (see [[Sequence.summary]]).
 *
 * @param kind - the kind of sequence.
 * @param letters - the sequence.
 * @param width - the most characters.
 */
export function summary(kind: SequenceKind, letters: string, width: number): string {
    const n = new Sequence("", letters).residueCount
    const suffix = ` (${n}${kind === "protein" ? " aa)" : " nt)"}`
    const room = width - suffix.length
    if (letters.length <= room) return letters + suffix
    if (room < minShown) return letters.slice(0, Math.max(room, 0)) + suffix
    const kept = room - 1 // one cell goes to the ellipsis
    const head = Math.floor((kept + 1) / 2)
    const tail = Math.floor(kept / 2)
    return `${letters.slice(0, head)}…${letters.slice(letters.length - tail)}${suffix}`
}

// ========================================================================================
// 2. Typed paths: check and complete
// ========================================================================================

// Typing a path: the one place that checks a typed path and completes it. The model
// prompt and the add flow's sequence prompt differ only in file filter and message
// budget, which each passes in.

/** The most hints [[hintsFor]] gives. */
const maxHints = 50

/** The most characters of a path typed in any path prompt. */
export const MAX_PATH_TYPED = 300

/**
 * How many characters a prompt's message may have: 42 for the model prompt, 22 for the add
 * flow.
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
 * What is wrong with a path as the file to read, or `undefined`. Checked in order:
 * empty, not absolute, not there, a folder, the wrong kind of file, not readable.
 *
 * @param path - the path typed.
 * @param budget - the characters the message may have; picks the wording.
 * @param wrongKind - when the prompt takes only some files: the test on the file's name
 *     and the message (within `budget`) for one that fails it; checked before
 *     readability. Omit it when any file will do.
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
 * The part of a typed path up to and with its last separator; `""` if none.
 *
 * @param text - the path typed.
 */
function dirPart(text: string): string {
    const cut = Math.max(text.lastIndexOf("/"), text.lastIndexOf(sep))
    return cut < 0 ? "" : text.slice(0, cut + 1)
}

/**
 * The names a typed path can go on with: folders (with a trailing `/`) first, then the
 * files `accept` takes, those starting with what follows the last separator (case-blind).
 * Dot names only when a dot is typed. At most 50; none unless `text` is an absolute path
 * in an existing folder.
 *
 * @param text - the path typed.
 * @param accept - says whether a file name is wanted.
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
 */
export function complete(text: string, hint: string): string {
    return dirPart(text) + hint
}

/**
 * The suggestions of a path prompt: shown by name; Tab puts the completed path into the
 * field.
 *
 * @param text - the path typed.
 * @param accept - says whether a file name is wanted.
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

// ========================================================================================
// 3. Limit
// ========================================================================================

/**
 * The most rows any user list holds (buffer solutes, custom solutes): the counters have
 * room for three digits. Adding stops there; a file with more is unusable.
 */
export const MAX_ROWS = 999

// ========================================================================================
// 4. List file
// ========================================================================================

/**
 * What a [[ListFile]] needs to know about its file.
 *
 * @property fileName - the file's name in its folder, e.g. `buffer.json`.
 * @property key - the JSON key of the list, e.g. `solutes`.
 * @property kind - carried by the errors, so a screen can tell files apart.
 * @property plural - what entries are called in messages (`solutes`).
 * @property noun - what one entry is called in a refusal (`buffer row`).
 * @property problem - what is wrong with one entry, or `undefined`; applied on read and
 *     write.
 * @property nameOf - an entry's name, if it has one. Names must then differ (case and end
 *     spaces ignored), and `remove` and `indexOf` work.
 * @property mapProblem - what is wrong with the file's other keys (pH, σ), or `undefined`;
 *     applied on read and write.
 * @property createParents - `false` for a file in a project folder: a gone folder is not
 *     remade. Default `true`.
 */
export type ListSpec<T> = {
    fileName: string
    key: string
    kind: string
    plural: string
    noun: string
    problem: (entry: unknown) => string | undefined
    nameOf?: (entry: T) => string
    mapProblem?: (map: Record<string, unknown>) => string | undefined
    createParents?: boolean
}

/**
 * A JSON file holding a list of entries under one key of an object, the one mechanism
 * of a project's buffer and the custom solutes:
 *
 *     {"<key>": [entry, entry, ...], ...other keys kept as they are...}
 *
 * - read, plain or `{track: true}` (the version read is the base the next write checks,
 *   so a save after another copy saved is refused);
 * - write under the file's lock through a temporary file, other keys kept;
 * - a file that cannot be used (not JSON, not a map, a refused entry, a repeated name,
 *   more than [[MAX_ROWS]]) is reported ([[UnusableFileError]]) and never written
 *   over; [[ListFile.reset]] moves it aside;
 * - the same rules for what a save is given;
 * - removing one entry by name, and one read-change-write step ([[ListFile.update]]).
 *
 * A missing or empty file is an empty list. One instance serves every folder.
 *
 * @typeParam T - the entry.
 */
export class ListFile<T> {
    /**
     * @param spec - what the file is, see [[ListSpec]].
     */
    constructor(private readonly spec: ListSpec<T>) {}

    /** The file in a folder. */
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

    /** The whole map of the file, checked. Throws UnusableFileError if unusable. */
    private readMap(dir: string): Record<string, unknown> {
        const { fileName, kind, plural, key } = this.spec
        return readMap(this.file(dir), {
            kind,
            name: fileName,
            expected: `a map of valid ${plural}`,
            valid: (map) =>
                this.listProblem(key in map ? map[key] : []) === undefined &&
                this.spec.mapProblem?.(map) === undefined,
        })
    }

    /**
     * The file's other keys (all but the list), checked. Throws UnusableFileError.
     *
     * @param options - `track: true` starts an editing session, as for [[ListFile.read]].
     */
    readOther(dir: string, options: ReadOptions = {}): Record<string, unknown> {
        if (options.track) noteRead(this.file(dir))
        const { [this.spec.key]: _list, ...others } = this.readMap(dir)
        return others
    }

    /**
     * The entries of the file in a folder. Throws UnusableFileError.
     *
     * @param options - `track: true` when the entries are read to be edited and saved: the
     *     version read is then the one [[ListFile.write]] checks against. A plain read
     *     changes nothing about that.
     */
    read(dir: string, options: ReadOptions = {}): T[] {
        if (options.track) noteRead(this.file(dir))
        const list = this.readMap(dir)[this.spec.key]
        return Array.isArray(list) ? (list as T[]) : []
    }

    /**
     * Checks a list and its extra keys by the rules the read applies; throws
     * UnusableFileError before anything is touched.
     */
    private assertWritable(list: readonly T[], extras: Record<string, unknown>): void {
        const why = this.listProblem(list) ?? this.spec.mapProblem?.(extras)
        if (why !== undefined) throw new UnusableFileError(why, this.spec.kind)
    }

    /** The write itself, for a caller that holds the lock and has checked what is there. */
    private writeLocked(
        dir: string,
        list: readonly T[],
        extras: Record<string, unknown> = {},
    ): string {
        const file = this.file(dir)
        this.assertWritable(list, extras)
        const { [this.spec.key]: _old, ...others } = this.readMap(dir)
        writeAtomic(
            file,
            writeJson({ [this.spec.key]: list, ...others, ...extras }),
            this.folder(),
        )
        noteWritten(file)
        return file
    }

    private folder(): { createParents: boolean } {
        return { createParents: this.spec.createParents ?? true }
    }

    /**
     * Writes the entries, other keys kept, through a temporary file that replaces it in
     * one step; the file is made if missing. Throws ChangedOnDiskError if another copy
     * saved after this one read (nothing written), UnusableFileError for entries that
     * break the rules or an unusable file.
     *
     * @param extras - other keys to set in the map in the same write (they replace the
     *     file's own values of those keys); they must keep `mapProblem`.
     */
    write(dir: string, list: readonly T[], extras: Record<string, unknown> = {}): string {
        const file = this.file(dir)
        return withFileLock(
            file,
            () => {
                assertUnchanged(file)
                return this.writeLocked(dir, list, extras)
            },
            this.folder(),
        )
    }

    /**
     * Reads, changes and writes in one step under the lock, so no other copy's changes
     * are lost. Throws ChangedOnDiskError when `guarded` and the file changed since this
     * process read it; UnusableFileError like [[ListFile.write]].
     *
     * @param change - given the entries as they are on disk now; returns the new list, or
     *     `undefined` to leave the file alone.
     * @param options - `guarded: true` for a caller that shows the file as it read it for
     *     editing: the change then refuses when another copy saved the file since;
     *     `extras`: other keys to set in the same write, as for [[ListFile.write]].
     */
    update(
        dir: string,
        change: (list: T[]) => readonly T[] | undefined,
        options: { guarded?: boolean; extras?: Record<string, unknown> } = {},
    ): boolean {
        const file = this.file(dir)
        return withFileLock(
            file,
            () => {
                if (options.guarded) assertUnchanged(file)
                const next = change(this.read(dir))
                if (next === undefined) return false
                this.writeLocked(dir, next, options.extras)
                return true
            },
            this.folder(),
        )
    }

    /**
     * The position of the entry with a name. Throws for a list without `nameOf`.
     *
     * @param name - the name, compared without regard to case and to the spaces at the
     *     ends.
     */
    indexOf(list: readonly T[], name: string): number | undefined {
        const { nameOf } = this.spec
        if (nameOf === undefined) throw new Error(`${this.spec.fileName} has no names`)
        const t = fold(name)
        const i = list.findIndex((e) => fold(nameOf(e)) === t)
        return i < 0 ? undefined : i
    }

    /**
     * Removes ONE entry by name: the file is re-read under the lock and only that entry
     * dropped. Returns whether it existed. Throws like [[ListFile.update]].
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
     * Starts over after the file was found unusable: renames it to `<name>.corrupt`
     * (replacing an older one) so nothing is lost. Returns that path, or `undefined` if
     * there was no file. Throws if it cannot be renamed.
     */
    reset(dir: string): string | undefined {
        return quarantine(this.file(dir))
    }
}

// ========================================================================================
// 5. Drafts
// ========================================================================================

// The rows of a table being edited, with what has not been saved: the state the tables
// of the solutes and of the custom solutes share, whatever a row holds.
// A row is `{ saved, draft, removed }`:
//
//   saved    what the file has (`undefined` for a row added since the last save)
//   draft    what the row was edited to (`undefined` when it stands at what was saved)
//   removed  the row is to go at the next save (shown with `-`); until then `undo`
//            brings it back
//
// A row shows `*` while it is new or has a draft, `-` while it is to be removed.
// `Drafts` is immutable: every change returns a new `Drafts`, which suits a screen that
// keeps its state in a React hook.



/** The mark of a row: `-` to be removed, `*` new or edited. */
export type Mark = "-" | "*"

/** One row of a table. */
export interface Row<V> {
    readonly saved: V | undefined
    readonly draft: V | undefined
    readonly removed: boolean
}

/** The item of a row as it stands now. */
export function rowValue<V>(row: Row<V>): V | undefined {
    return row.draft ?? row.saved
}

/**
 * The mark of a row.
 *
 * @returns `"-"` if it is to be removed, `"*"` if it is new or edited, else `undefined`.
 */
export function rowMark<V>(row: Row<V>): Mark | undefined {
    if (row.removed) return "-"
    if (row.saved === undefined || row.draft !== undefined) return "*"
    return undefined
}

/** The rows of a table being edited, and the changes not yet saved. */
export class Drafts<V> {
    /** The rows, in table order. */
    readonly rows: readonly Row<V>[]

    /**
     * @param rows - the rows; use `Drafts.of` to start from the saved items.
     */
    constructor(rows: readonly Row<V>[] = []) {
        this.rows = rows
    }

    /** The state of the saved items, nothing edited. */
    static of<V>(items: readonly V[]): Drafts<V> {
        const rows = items.map((saved) => ({ saved, draft: undefined, removed: false }))
        return new Drafts(rows)
    }

    /** How many rows there are. */
    get length(): number {
        return this.rows.length
    }

    /** The item of row `i` as it stands now. */
    value(i: number): V | undefined {
        const row = this.rows[i]
        return row && rowValue(row)
    }

    /** The mark of row `i`. */
    mark(i: number): Mark | undefined {
        const row = this.rows[i]
        return row && rowMark(row)
    }

    /** Whether anything is not saved. */
    get dirty(): boolean {
        return this.rows.some((row) => rowMark(row) !== undefined)
    }

    /** How many rows are not saved: new, edited or marked to be removed. */
    get count(): number {
        return this.rows.filter((row) => rowMark(row) !== undefined).length
    }

    /** Whether there is room for another row (fewer than `MAX_ROWS`). */
    get hasRoom(): boolean {
        return this.rows.length < MAX_ROWS
    }

    /**
     * The state without row `i`.
     *
     * @throws RangeError for a row that is not there.
     */
    drop(i: number): Drafts<V> {
        this.check(i)
        return new Drafts(this.rows.filter((_, j) => j !== i))
    }

    /**
     * The state without the rows of `indices` that were never saved (the cancelled rows
     * of an add); a row that was saved is left alone.
     */
    dropNew(indices: Iterable<number>): Drafts<V> {
        const gone = new Set([...indices].filter((i) => this.rows[i]?.saved === undefined))
        return new Drafts(this.rows.filter((_, i) => !gone.has(i)))
    }

    /** The state with new rows, each a draft of an item, at the end. */
    add(...items: V[]): Drafts<V> {
        const added = items.map((draft) => ({ saved: undefined, draft, removed: false }))
        return new Drafts([...this.rows, ...added])
    }

    /**
     * The state with the item of row `i` set as a whole. A row set back to what was
     * saved has no draft.
     *
     * @throws RangeError for a row that is not there.
     */
    set(i: number, item: V): Drafts<V> {
        const row = this.check(i)
        const same = isDeepStrictEqual(item, row.saved)
        return this.replace(i, { ...row, draft: same ? undefined : item })
    }

    /**
     * The state with row `i` marked to be removed at the next save; a row that was never
     * saved has nothing to confirm and goes at once.
     *
     * @throws RangeError for a row that is not there.
     */
    remove(i: number): Drafts<V> {
        const row = this.check(i)
        if (row.saved === undefined) return this.drop(i)
        return this.replace(i, { ...row, removed: true })
    }

    /**
     * The state with the last change of row `i` undone: a removal first, then the draft;
     * a row that was never saved goes.
     *
     * @throws RangeError for a row that is not there.
     */
    undo(i: number): Drafts<V> {
        const row = this.check(i)
        if (row.removed) return this.replace(i, { ...row, removed: false })
        if (row.saved === undefined) return this.drop(i)
        return this.replace(i, { ...row, draft: undefined })
    }

    /**
     * The state with the rows in alphabetical order of `label` (case ignored, a stable
     * order for equal names). Marks and drafts stay with their rows.
     */
    sorted(label: (item: V) => string): Drafts<V> {
        const name = (row: Row<V>) => label(rowValue(row) as V)
        return new Drafts([...this.rows].sort((a, b) => compareNoCase(name(a), name(b))))
    }

    /** Whether the rows already stand in the order [[sorted]] gives. */
    isSorted(label: (item: V) => string): boolean {
        return this.sorted(label).rows.every((row, i) => row === this.rows[i])
    }

    /** The items the file gets at the next save: the rows not marked to go. */
    toSave(): V[] {
        return this.rows.filter((row) => !row.removed).map((row) => rowValue(row) as V)
    }

    /**
     * The state after a save: the removed rows gone, every other row standing at what it
     * is.
     */
    commit(): Drafts<V> {
        return Drafts.of(this.toSave())
    }

    /** The row `i`, or a RangeError (the Clojure threw IndexOutOfBounds). */
    private check(i: number): Row<V> {
        const row = this.rows[i]
        if (!row) throw new RangeError(`no row ${i}`)
        return row
    }

    /** The state with row `i` replaced. */
    private replace(i: number, row: Row<V>): Drafts<V> {
        return new Drafts(this.rows.map((r, j) => (j === i ? row : r)))
    }
}
