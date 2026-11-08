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
import { compareNoCase, fold } from "../core/terminal.js"

// ========================================================================================
// 1. Sequences: strict FASTA and FASTQ reader
// ========================================================================================

/**
 * A strict reader of FASTA and FASTQ text for the DNA, RNA and protein rows of the
 * buffer. [[parseText]] and [[parseFile]] give every record as a [[Sequence]], or an
 * error whose message is at most 22 characters (it is shown in a 24-character border
 * note). One record makes one buffer row.
 *
 * The alphabets are the ones the Julia code accepts (`src/BulkElectronDensity`,
 * Nucleotide and Protein): DNA `A C G T` plus the IUPAC ambiguity codes
 * `R Y S W K M B D H V N`; RNA the same with `U` for `T` (`T` in RNA and `U` in DNA are
 * errors); protein the twenty residues `A C D E F G H I K L M N P Q R S T V W Y`,
 * selenocysteine `U`, pyrrolysine `O` and the ambiguity codes `B J Z`. `*` (any kind)
 * and `X` (protein) are placeholders Julia skips, so they are accepted and kept in the
 * sequence, but they are no residue and a record of nothing else is empty. THE LINT
 * ([[parseText]], one function for typed text, pasted text and files): a FASTA header
 * line is dropped, letters are upper-cased, white space, line breaks and the numbering
 * digits of a GenBank-style listing are dropped, and NOTHING else is repaired: a gap `-`,
 * a stray symbol, a `T` in RNA or a `U` in DNA is an error that names the character and
 * its place in the cleaned sequence (`invalid residue 'J' at 12`). A text with no header
 * is one sequence. Julia has no length cap, so there is none here.
 *
 * FASTA: a `>` header line, then the sequence on one or more lines. FASTQ: strict four
 * line records `@id`, the sequence on one line, `+` (with or without a repeat of the id)
 * and a quality line of the same length; only the sequence is kept, and an `@` at the
 * start of a quality line is not a header. The id is the header up to the first white
 * space. Blank lines are allowed in FASTA anywhere and in FASTQ before the first and
 * after the last record only; CRLF line ends are fine.
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

    /**
     * The number of residues: the letters without the placeholders `*` and `X`.
     *
     * @returns the count.
     */
    get residueCount(): number {
        return [...this.letters].filter((c) => !anyPlaceholder.has(c)).length
    }

    /**
     * The compact text of the sequence for the params cell: `ACG…GCA (24 nt)` for DNA
     * and RNA, `MKT…QLS (317 aa)` for a protein. The count suffix is always kept; the
     * head and the tail of the sequence shrink (the head gets the odd letter) to make
     * the whole at most `width` characters, and the sequence is shown whole when it
     * fits.
     *
     * @param kind - the kind of sequence.
     * @param width - the most characters.
     * @returns the text.
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
 * Whether a file name (or path) has one of the [[sequenceExtensions]].
 *
 * @param fileName - the name or path.
 * @returns the answer (case does not matter).
 */
export function isFastaFile(fileName: string): boolean {
    const low = fileName.toLowerCase()
    return sequenceExtensions.some((e) => low.endsWith(e))
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
 * Lints sequence text and checks it against the alphabet of its kind: the one rule of
 * every sequence the program takes (see the header of this section).
 *
 * @param kind - the kind.
 * @param raw - the sequence as typed, pasted or read (no header line).
 * @param digits - drop numbering digits too (`true` for text and FASTA, not for FASTQ).
 * @returns the clean letters (placeholders kept), or the error: `empty sequence`,
 *     `U is RNA, not DNA (at 5)`, `T is DNA, not RNA (at 5)` or
 *     `invalid residue 'J' at 12` (places count the clean letters, from 1).
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
 * @returns the id.
 */
function recordId(header: string, fallback: string): string {
    const id = header.slice(1).trim().split(/\s+/)[0] ?? ""
    return id === "" ? fallback : id
}

/** A record before its sequence is cleaned and checked. */
type RawRecord = { id: string; raw: string }

/**
 * The result for the raw records of a kind: each sequence cleaned and checked, the
 * first error returned.
 *
 * @param kind - the kind.
 * @param raws - the records.
 * @returns the records, or the first error.
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
 * The records of FASTA lines.
 *
 * @param lines - the lines; the first is a header.
 * @returns the raw records.
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
 * The result for FASTQ lines.
 *
 * @param kind - the kind.
 * @param lines - the lines, blank ones at both ends already dropped.
 * @returns the records, or the first error.
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
 * Parses FASTA or FASTQ text, or bare sequence text, as sequences ([[parseText]]).
 *
 * @param text - the text: FASTA, FASTQ, or one sequence with no header on any number of
 *     lines.
 * @param kind - `dna`, `rna` or `protein`.
 * @returns the records (a bare sequence is one record, `seq1`), or an error for: no
 *     records, an empty sequence, a FASTQ record that has a missing line or a quality
 *     line of another length, a letter outside the alphabet of `kind` (named, with its
 *     place).
 * @throws Error for another `kind`.
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
 * What a pasted text needs: whether it is not a field's text (it has a line break, or is
 * longer than the field holds), so it is taken as a sequence text at once.
 *
 * @param text - the text pasted.
 * @param room - the characters the field has room for.
 * @returns `true` when the paste goes to [[parseText]] instead of into the field.
 */
export function isSequencePaste(text: string, room: number): boolean {
    const t = text.trim()
    return /[\r\n]/.test(t) || t.length > room
}

/**
 * The residues of records (placeholders `*` and `X` not counted).
 *
 * @param records - the records.
 * @returns the total.
 */
export function residuesOf(records: SequenceRecords): number {
    return records.reduce((n, r) => n + r.residueCount, 0)
}

/**
 * Parses a file like [[parseText]].
 *
 * @param path - the file.
 * @param kind - `dna`, `rna` or `protein`.
 * @returns the records, or an error; `cannot read file` when it cannot be read as text.
 * @throws Error for another `kind`.
 */
export function parseFile(path: string, kind: SequenceKind): SequenceResult {
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
 * @returns the text.
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
// prompt (`projects.ts`) and the sequence prompt of the add flow (`add-flow.ts`) differ
// only in what files they want and in how many characters a message may have, so each
// hands its own message budget and file filter to the functions here.

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

// ========================================================================================
// 3. Limit
// ========================================================================================

/**
 * The most rows any list of the user holds: the solutes of a buffer, the custom
 * solutes. The counters of the tables have room
 * for three digits. Adding stops there, and a file that holds more is unusable.
 */
export const MAX_ROWS = 999

// ========================================================================================
// 4. List file
// ========================================================================================

/** What the message of a name used twice says (also the one of a rename onto a name). */
const NAME_IN_USE = "name in use"

/**
 * What a [[ListFile]] needs to know about its file.
 *
 * @property fileName - the name of the file in its folder, e.g. `buffer.json`.
 * @property key - the key of the JSON object under which the list is kept, e.g. `solutes`.
 * @property kind - the kind carried by the errors, so a screen can tell the files apart.
 * @property plural - what the entries are called in messages (`solutes`).
 * @property noun - what one entry is called in the message of a refused entry (`buffer
 *     row`, `custom solute`).
 * @property problem - what is wrong with one entry (a value of the file or of a save), or
 *     `undefined` when it is fine. Applied to every entry on read and on write.
 * @property nameOf - the name an entry is known by, left out for a list whose entries have
 *     none. With it, names must differ without regard to case (and to the spaces at the
 *     ends), and [[ListFile.remove]] and [[ListFile.indexOf]] work.
 * @property mapProblem - what is wrong with the other keys of the file's map (the buffer's
 *     pH and σ), or `undefined` when they are fine. Applied on read and on write, so a
 *     file with a bad value there is unusable and never written over.
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
    mapProblem?: (map: Record<string, unknown>) => string | undefined
    createParents?: boolean
}

/**
 * A JSON file that holds a list of entries under one key of a JSON object, the one
 * mechanism of the buffer of a project and the custom solutes:
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

    /**
     * The whole map of the file, checked.
     *
     * @throws UnusableFileError (the spec's kind) if the file cannot be used.
     */
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
     * The other keys of the file's map (everything but the list), checked like the rest.
     *
     * @param options - `track: true` starts an editing session, as for [[ListFile.read]].
     * @throws UnusableFileError if the file cannot be used.
     */
    readOther(dir: string, options: ReadOptions = {}): Record<string, unknown> {
        if (options.track) noteRead(this.file(dir))
        const { [this.spec.key]: _list, ...others } = this.readMap(dir)
        return others
    }

    /**
     * The entries of the file in a folder.
     *
     * @param options - `track: true` when the entries are read to be edited and saved: the
     *     version read is then the one [[ListFile.write]] checks against. A plain read
     *     changes nothing about that.
     * @throws UnusableFileError if the file cannot be used.
     */
    read(dir: string, options: ReadOptions = {}): T[] {
        if (options.track) noteRead(this.file(dir))
        const list = this.readMap(dir)[this.spec.key]
        return Array.isArray(list) ? (list as T[]) : []
    }

    /**
     * Whether a list and the keys written with it may be written: the same rules the read
     * applies.
     *
     * @throws UnusableFileError (the spec's kind) with the reason, before anything is
     *     touched.
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
     * Writes the entries as the list of the folder, the other keys of the file kept,
     * through a temporary file that replaces it in one step. The file is made if there is
     * none; one that cannot be used is not touched.
     *
     * @param extras - other keys to set in the map in the same write (they replace the
     *     file's own values of those keys); they must keep `mapProblem`.
     * @throws ChangedOnDiskError if another copy of the program saved the file after this
     *     one read it (nothing is written); UnusableFileError (the spec's kind) for
     *     entries that break the rules (nothing is written) or a file that cannot be used.
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
     * Reads, changes and writes in one step under the lock, so a change never loses
     * another copy's changes to the other entries.
     *
     * @param change - given the entries as they are on disk now; returns the new list, or
     *     `undefined` to leave the file alone.
     * @param options - `guarded: true` for a caller that shows the file as it read it for
     *     editing: the change then refuses when another copy saved the file since;
     *     `extras`: other keys to set in the same write, as for [[ListFile.write]].
     * @throws ChangedOnDiskError when `guarded` and the file changed since this process
     *     read it; UnusableFileError like [[ListFile.write]].
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
     * The position of the entry with a name.
     *
     * @param name - the name, compared without regard to case and to the spaces at the
     *     ends.
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
     * @returns the path of the kept file, or `undefined` if there was no file.
     * @throws if it cannot be renamed.
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
