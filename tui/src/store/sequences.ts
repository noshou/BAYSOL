// SPDX-License-Identifier: LGPL-3.0-or-later

import { readFileSync } from "node:fs"

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
 * sequence, but they are no residue and a record of nothing else is empty. Letters are
 * upper-cased, white space is dropped, nothing else is repaired (a gap `-`, a digit, an
 * `@` in a FASTA body are errors).
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

/** How each kind is called in a message. */
const kindNames: Readonly<Record<SequenceKind, string>> = {
    dna: "DNA",
    rna: "RNA",
    protein: "protein",
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

/** What the readers give: the records, or the reason there are none. */
export type SequenceResult = { records: Sequence[] } | { error: string }

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

/** The sequence text without white space, upper-cased. */
function clean(text: string): string {
    return text.replace(/\s+/g, "").toUpperCase()
}

/**
 * Checks a cleaned sequence against the alphabet of its kind.
 *
 * @param kind - the kind.
 * @param letters - the cleaned text.
 * @returns the text if every letter is allowed and one is a residue, else the error.
 */
function checkSequence(kind: SequenceKind, letters: string): string | { error: string } {
    const bad = [...letters].find(
        (c) => !alphabets[kind].has(c) && !placeholders[kind].has(c),
    )
    if (bad !== undefined) return fail(`bad letter ${bad} (${kindNames[kind]})`)
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
function finish(kind: SequenceKind, raws: readonly RawRecord[]): SequenceResult {
    if (raws.length === 0) return fail("no records")
    const records: Sequence[] = []
    for (const { id, raw } of raws) {
        const checked = checkSequence(kind, clean(raw))
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
    return finish(kind, acc)
}

/**
 * Parses FASTA or FASTQ text as sequences.
 *
 * @param text - the text.
 * @param kind - `dna`, `rna` or `protein`.
 * @returns the records, or an error (at most 22 characters) for: no records, an empty
 *     sequence, a first line that starts with neither `>` nor `@`, a FASTQ record that
 *     has a missing line or a quality line of another length, a letter outside the
 *     alphabet of `kind`.
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
    return fail("wrong format")
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
