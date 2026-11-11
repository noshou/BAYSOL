// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/lists.ts: the lists, the typed path and the pasted sequence.
//
// Contents:
//   1. Sequences
//   2. List file
//   3. Drafts

import assert from "node:assert/strict"
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import {
    ChangedOnDiskError,
    UnusableFileError,
    writeJson,
} from "../src/core/file-system.js"
import {
    Drafts,
    isFastaFile,
    isSequencePaste,
    ListFile,
    MAX_ROWS,
    parseFile,
    parseText,
    residuesOf,
    type SequenceKind,
    type SequenceResult,
    summary,
} from "../src/store/lists.js"
import { tempDir as dir, seqresLetters, tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. Sequences
// ========================================================================================

/** The `[id, letters]` pairs of a result that has records. */
function pairs(result: SequenceResult): [string, string][] {
    assert.ok("records" in result, JSON.stringify(result))
    return result.records.map((r) => [r.id, r.letters])
}

/** The error of a result, `undefined` if it has records. */
function errorOf(result: SequenceResult): string | undefined {
    return "error" in result ? result.error : undefined
}

test("FASTA records", () => {
    // lines joined, lower case and spaces fixed, id up to the blank
    assert.deepEqual(pairs(parseText(">p1 primer one\nacgt\nTG CA\n", "dna")), [
        ["p1", "ACGTTGCA"],
    ])
    // blank lines between records, CRLF line ends
    assert.deepEqual(
        pairs(parseText(">a\r\nAC\r\nGT\r\n\r\n>b desc\r\nGGCC\r\n\r\n\r\n", "dna")),
        [
            ["a", "ACGT"],
            ["b", "GGCC"],
        ],
    )
    // blank lines before the first record and no final newline
    assert.deepEqual(pairs(parseText("\n\n>a\nAC", "dna")), [["a", "AC"]])
    // a header without an id gets a number
    assert.deepEqual(pairs(parseText(">\nAC\n> \nGT\n", "dna")), [
        ["seq1", "AC"],
        ["seq2", "GT"],
    ])
})

test("alphabets follow Julia", () => {
    assert.ok("records" in parseText(">d\nACGTRYSWKMBDHVN\n", "dna"))
    assert.ok("records" in parseText(">r\nACGURYSWKMBDHVN\n", "rna"))
    assert.equal(errorOf(parseText(">d\nACGU\n", "dna")), "U is RNA, not DNA (at 4)")
    assert.equal(errorOf(parseText(">r\nACGT\n", "rna")), "T is DNA, not RNA (at 4)")
    assert.ok("records" in parseText(">p\nACDEFGHIKLMNPQRSTVWYBJZOUX*\n", "protein"))
    assert.equal(errorOf(parseText(">p\nMK-L\n", "protein")), "invalid residue '-' at 3")
    assert.equal(errorOf(parseText(">p\nMK_L\n", "protein")), "invalid residue '_' at 3")
    // a placeholder is kept, a record of nothing else is empty
    assert.deepEqual(pairs(parseText(">p\nMKT*\n", "protein")), [["p", "MKT*"]])
    assert.equal(errorOf(parseText(">p\n*\n", "protein")), "empty sequence")
    assert.equal(errorOf(parseText(">p\nACX\n", "dna")), "invalid residue 'X' at 3")
    // an unknown kind is a programming error
    assert.throws(() => parseText(">p\nAC\n", "lipid" as SequenceKind))
})

/** Real chains of the repo's PDB fixtures (their SEQRES), by kind. */
const real = {
    protein: seqresLetters("1CRN-TEST.pdb", "A"),
    dna: seqresLetters("1BNA-TEST.pdb", "A"),
    rna: seqresLetters("1RNA-TEST.pdb", "A"),
}

test("the lint reads real chains: header, numbers, case, spaces, line breaks", () => {
    assert.equal(real.protein.length, 46)
    assert.equal(real.dna, "CGCGAATTCGCG")
    assert.equal(real.rna, "UUAUAUAUAUAUAA")
    for (const kind of ["protein", "dna", "rna"] as const) {
        const seq = real[kind]
        const wrapped = (seq.match(/.{1,10}/g) ?? []).join("\n")
        // the bare sequence, lower case with spaces, with GenBank-style numbering
        assert.deepEqual(pairs(parseText(seq, kind)), [["seq1", seq]])
        assert.deepEqual(
            pairs(parseText(` ${seq.toLowerCase()}  \n`, kind)),
            [["seq1", seq]],
        )
        const numbered = (seq.match(/.{1,10}/g) ?? [])
            .map((c, i) => `${String(i * 10 + 1).padStart(4)} ${c}`)
            .join("\n")
        assert.deepEqual(pairs(parseText(numbered, kind)), [["seq1", seq]])
        // a FASTA header line is dropped from the letters and names the record
        assert.deepEqual(pairs(parseText(`>chain A of a fixture\n${wrapped}\n`, kind)), [
            ["chain", seq],
        ])
        assert.equal(
            residuesOf((parseText(seq, kind) as { records: never[] }).records),
            seq.length,
        )
    }
})

test("the lint names the character and its place, and says what the other kind is", () => {
    const crn = real.protein
    for (const [text, kind, why] of [
        [`${crn.slice(0, 11)}#${crn.slice(12)}`, "protein", "invalid residue '#' at 12"],
        ["ACGT-ACGT", "dna", "invalid residue '-' at 5"],
        ["ACGT ACGT\nAC.T", "dna", "invalid residue '.' at 11"],
        ["ACGU", "dna", "U is RNA, not DNA (at 4)"],
        ["UUAT", "rna", "T is DNA, not RNA (at 4)"],
        ["", "dna", "no records"],
        ["  \n  ", "protein", "no records"],
        ["12 34", "dna", "empty sequence"],
        [">only a header\n", "dna", "empty sequence"],
        ["XX**", "protein", "empty sequence"],
    ] as const) {
        const e = errorOf(parseText(text, kind))
        assert.equal(e, why, JSON.stringify(text))
        assert.ok(e.length <= 40)
    }
    // the wrong kind of a real chain is refused as the wrong kind
    assert.equal(errorOf(parseText(real.rna, "dna")), "U is RNA, not DNA (at 1)")
    assert.equal(errorOf(parseText(real.dna, "rna")), "T is DNA, not RNA (at 7)")
    // nothing but case, white space, numbers and the header is repaired: FASTQ is strict
    assert.equal(
        errorOf(parseText("@r\nAC1T\n+\nIIII\n", "dna")),
        "invalid residue '1' at 3",
    )
})

test("a paste goes to the lint with a line break or when longer than the field", () => {
    assert.ok(isSequencePaste(">a\nACGT\n", 300))
    assert.ok(isSequencePaste("ACGT".repeat(100), 300))
    assert.ok(!isSequencePaste("ACGTACGT\n", 300), "one line and a newline is trimmed")
    assert.ok(!isSequencePaste("/home/noso/x.fa", 300))
})

test("FASTA errors", () => {
    assert.equal(errorOf(parseText("", "dna")), "no records")
    assert.equal(errorOf(parseText("\n \n", "dna")), "no records")
    assert.equal(errorOf(parseText(">a\n", "dna")), "empty sequence")
    assert.equal(errorOf(parseText(">a\nAC\n>b\n\n>c\nGT\n", "dna")), "empty sequence")
    assert.equal(errorOf(parseText("#>a\nACGT\n", "dna")), "invalid residue '#' at 1")
    // an @ in a FASTA body is no header
    assert.equal(errorOf(parseText(">a\nAC\n@b\nGT\n", "dna")), "invalid residue '@' at 3")
    // every message fits the footer note
    for (const text of ["", ">a\n", "x", ">a\nMK-\n", "@a\nAC\n+\nA\n"])
        for (const kind of ["dna", "rna", "protein"] as const) {
            const e = errorOf(parseText(text, kind))
            if (e !== undefined) assert.ok(e.length <= 40, e)
        }
})

test("FASTQ records", () => {
    assert.deepEqual(
        pairs(parseText("@r1 first\nACGT\n+\nIIII\n@r2\nGGCC\n+r2\nIIII\n", "dna")),
        [
            ["r1", "ACGT"],
            ["r2", "GGCC"],
        ],
    )
    // an @ at the start of a quality line is no header
    assert.deepEqual(pairs(parseText("@r1\nACGT\n+\n@III\n@r2\nGGCC\n+\n+@@@\n", "dna")), [
        ["r1", "ACGT"],
        ["r2", "GGCC"],
    ])
    // CRLF, lower case, blank lines around
    assert.deepEqual(pairs(parseText("\r\n@r1\r\nacgu\r\n+\r\nIIII\r\n\r\n\r\n", "rna")), [
        ["r1", "ACGU"],
    ])
})

test("FASTQ errors", () => {
    assert.equal(errorOf(parseText("@r\nACGT\n+\nIII\n", "dna")), "quality length differs")
    assert.equal(
        errorOf(parseText("@r\nACGT\n+\nIIIII\n", "dna")),
        "quality length differs",
    )
    assert.equal(errorOf(parseText("@r\nACGT\n+\n", "dna")), "missing line")
    assert.equal(errorOf(parseText("@r\nACGT\n", "dna")), "missing line")
    assert.equal(errorOf(parseText("@r\nACGT\n+\nIIII\n@s\nAC\n", "dna")), "missing line")
    assert.equal(errorOf(parseText("@r\nACGT\nIIII\n+\n", "dna")), "bad FASTQ record")
    assert.equal(
        errorOf(parseText("@r\nAC\n+\nII\n\nGT\n+\nII\n", "dna")),
        "bad FASTQ record",
    )
    assert.equal(errorOf(parseText("@r\n\n+\n\n@s\nAC\n+\nII\n", "dna")), "empty sequence")
    assert.equal(
        errorOf(parseText("@r\nACQT\n+\nIIII\n", "dna")),
        "invalid residue 'Q' at 3",
    )
})

test("files", () => {
    const dir = tempDir()
    const multi = join(dir, "multi.fa")
    writeFileSync(multi, ">p1 one\nMKTAYIAK\nQRQ\n\n>p2\nGSHM*\n")
    const bad = join(dir, "bad.fasta")
    writeFileSync(bad, "ACGT\n")
    assert.deepEqual(pairs(parseFile(multi, "protein")), [
        ["p1", "MKTAYIAKQRQ"],
        ["p2", "GSHM*"],
    ])
    // a file with no header is one bare sequence (what text is)
    assert.deepEqual(pairs(parseFile(bad, "dna")), [["seq1", "ACGT"]])
    assert.deepEqual(parseFile(join(dir, "none.fa"), "dna"), { error: "cannot read file" })
})

test("file extensions", () => {
    for (const n of [
        "a.fasta",
        "a.fa",
        "a.fna",
        "a.faa",
        "a.fastq",
        "a.fq",
        "/x/y/A.FASTA",
        "B.Fq",
    ])
        assert.ok(isFastaFile(n), n)
    for (const n of ["a.pdb", "a.txt", "fasta", "a.fa.gz", "", "a.fq.bak"])
        assert.ok(!isFastaFile(n), n)
})

test("summaries", () => {
    // short sequences are whole, with the count
    assert.equal(summary("dna", "ACG", 22), "ACG (3 nt)")
    assert.equal(summary("protein", "MKT", 22), "MKT (3 aa)")
    // a long one shrinks head and tail and always keeps the count
    const dna = summary("dna", "ACGT".repeat(8), 22)
    assert.equal(dna, "ACGTACG…GTACGT (32 nt)")
    assert.ok(dna.length <= 22)
    const protein = summary("protein", "M".repeat(317), 22)
    assert.equal(protein, "MMMMMM…MMMMMM (317 aa)")
    assert.equal(protein.length, 22)
    const mixed = summary("protein", `MKT${"A".repeat(311)}QLS`, 22)
    assert.ok(mixed.endsWith(" (317 aa)") && mixed.length <= 22)
    // a narrow width keeps the suffix and what fits of the head
    assert.equal(summary("dna", "AC".repeat(12), 10), "AC (24 nt)")
    assert.equal(summary("dna", "AC".repeat(12), 4), " (24 nt)")
    // placeholders are not counted
    assert.equal(summary("protein", "MKT*", 22), "MKT* (3 aa)")
})

// ========================================================================================
// 2. List file
// ========================================================================================

type Item = { name: string; n: number }

const list = new ListFile<Item>({
    fileName: "items.json",
    key: "items",
    kind: "items",
    plural: "items",
    noun: "item",
    problem: (e) =>
        typeof (e as Item).n === "number" && (e as Item).n >= 0 ? undefined : "n is bad",
    nameOf: (e) => e.name,
})

const item = (name: string, n = 1): Item => ({ name, n })

test("no file is an empty list; a write makes it and keeps the other keys", () => {
    const d = dir()
    assert.deepEqual(list.read(d), [])
    writeFileSync(list.file(d), writeJson({ other: { a: 1 }, items: [item("a")] }))
    list.write(d, [item("b")])
    const map = JSON.parse(readFileSync(list.file(d), "utf-8"))
    assert.deepEqual(map.other, { a: 1 })
    assert.deepEqual(list.read(d), [item("b")])
    assert.equal(existsSync(`${list.file(d)}.tmp`), false)
})

test("a tracked read makes a later write after another save refuse", () => {
    const d = dir()
    list.write(d, [item("a")])
    list.read(d, { track: true })
    writeFileSync(list.file(d), writeJson({ items: [item("z")] })) // another copy
    assert.throws(() => list.write(d, [item("b")]), ChangedOnDiskError)
    assert.deepEqual(list.read(d), [item("z")], "nothing was written")
    list.read(d, { track: true }) // reopened
    list.write(d, [item("b")])
})

test("a plain read does not move the base", () => {
    const d = dir()
    list.write(d, [item("a")])
    list.read(d, { track: true })
    writeFileSync(list.file(d), writeJson({ items: [item("z")] }))
    list.read(d)
    assert.throws(() => list.write(d, []), ChangedOnDiskError)
})

test("an unusable file is told and never written over; reset keeps it", () => {
    const d = dir()
    for (const text of ["nope", "[]", '{"items": 3}', '{"items": [{"name":"a","n":-1}]}']) {
        writeFileSync(list.file(d), text)
        assert.throws(
            () => list.read(d),
            (e) => e instanceof UnusableFileError && e.kind === "items",
        )
        assert.throws(() => list.write(d, []), UnusableFileError)
        assert.equal(readFileSync(list.file(d), "utf-8"), text)
    }
    const kept = list.reset(d)
    assert.equal(kept, `${list.file(d)}.corrupt`)
    assert.equal(existsSync(list.file(d)), false)
    assert.equal(list.reset(d), undefined)
    list.write(d, [item("a")])
})

test("names differ without regard to case, on write and on read", () => {
    const d = dir()
    assert.throws(() => list.write(d, [item("A"), item(" a")]), /name in use/)
    assert.equal(existsSync(list.file(d)), false)
    writeFileSync(list.file(d), writeJson({ items: [item("A"), item("a")] }))
    assert.throws(() => list.read(d), UnusableFileError)
})

test("an invalid entry is refused with its reason", () => {
    assert.throws(() => list.write(dir(), [item("a", -1)]), /not a valid item: n is bad/)
})

test("the cap is MAX_ROWS", () => {
    const d = dir()
    const many = Array.from({ length: MAX_ROWS + 1 }, (_, i) => item(`i${i}`))
    assert.throws(() => list.write(d, many), /too many items/)
    list.write(d, many.slice(0, MAX_ROWS))
    assert.equal(list.read(d).length, MAX_ROWS)
})

test("remove drops one entry by name and keeps the rest and the other keys", () => {
    const d = dir()
    writeFileSync(
        list.file(d),
        writeJson({ keep: 1, items: [item("a"), item("B"), item("c")] }),
    )
    assert.equal(list.remove(d, " b "), true)
    assert.deepEqual(list.read(d), [item("a"), item("c")])
    assert.equal(JSON.parse(readFileSync(list.file(d), "utf-8")).keep, 1)
    assert.equal(list.remove(d, "nothing"), false)
})

test("remove: guarded refuses after another copy saved, unguarded does not", () => {
    const d = dir()
    list.write(d, [item("a"), item("b")])
    list.read(d, { track: true })
    writeFileSync(list.file(d), writeJson({ items: [item("a"), item("b"), item("c")] }))
    assert.throws(() => list.remove(d, "a", { guarded: true }), ChangedOnDiskError)
    assert.equal(list.remove(d, "a"), true)
    assert.deepEqual(list.read(d), [item("b"), item("c")], "the other copy's entry kept")
})

test("update writes the change or leaves the file alone", () => {
    const d = dir()
    list.write(d, [item("a")])
    assert.equal(
        list.update(d, () => undefined),
        false,
    )
    assert.equal(
        list.update(d, (l) => [...l, item("b")]),
        true,
    )
    assert.deepEqual(list.read(d), [item("a"), item("b")])
})

test("createParents false does not make a folder that is gone", () => {
    const d = dir()
    const project = new ListFile<Item>({
        fileName: "p.json",
        key: "items",
        kind: "p",
        plural: "items",
        noun: "item",
        problem: () => undefined,
        createParents: false,
    })
    project.write(d, [item("a")])
    rmSync(d, { recursive: true })
    assert.throws(() => project.write(d, [item("a")]))
    assert.equal(existsSync(d), false)
})

// ========================================================================================
// 3. Drafts
// ========================================================================================

const marks = (s: Drafts<string>) => s.rows.map((_, i) => s.mark(i))
const values = (s: Drafts<string>) => s.rows.map((_, i) => s.value(i))

test("saved rows are clean", () => {
    const s = Drafts.of(["a", "b"])
    assert.deepEqual(marks(s), [undefined, undefined])
    assert.deepEqual(values(s), ["a", "b"])
    assert.equal(s.dirty, false)
    assert.equal(Drafts.of([]).length, 0)
})

test("drafts, marks and undo", () => {
    const s = Drafts.of(["a", "b"]).set(0, "a2").add("c").add("d", "e")
    assert.deepEqual(marks(s), ["*", undefined, "*", "*", "*"])
    assert.deepEqual(values(s), ["a2", "b", "c", "d", "e"])
    assert.equal(s.dirty, true)
    assert.equal(s.count, 4)
    // set back to what was saved: no draft
    assert.deepEqual(marks(Drafts.of(["a", "b"]).set(0, "a")), [undefined, undefined])
    // undo of a draft, of a new row (it goes)
    assert.deepEqual(marks(s.undo(0)), [undefined, undefined, "*", "*", "*"])
    assert.deepEqual(values(s.undo(2)), ["a2", "b", "d", "e"])
    // removal of a saved row is a mark, undo brings it back; toSave skips it
    const r = s.remove(1)
    assert.deepEqual(marks(r), ["*", "-", "*", "*", "*"])
    assert.deepEqual(r.toSave(), ["a2", "c", "d", "e"])
    assert.deepEqual(marks(r.undo(1)), ["*", undefined, "*", "*", "*"])
    // removal of a row that was never saved is at once
    assert.equal(s.remove(2).length, 4)
    // commit drops the removed rows and cleans the others
    const c = r.commit()
    assert.deepEqual(marks(c), [undefined, undefined, undefined, undefined])
    assert.deepEqual(values(c), ["a2", "c", "d", "e"])
})

test("objects are compared by value when set back", () => {
    const s = Drafts.of([{ n: 1 }]).set(0, { n: 2 })
    assert.equal(s.mark(0), "*")
    assert.equal(s.set(0, { n: 1 }).mark(0), undefined)
})

test("drop and dropNew", () => {
    const s = Drafts.of(["a", "b", "c"])
    assert.deepEqual(values(s.drop(1)), ["a", "c"])
    assert.deepEqual(values(s.drop(0)), ["b", "c"])
    assert.throws(() => s.drop(3), RangeError)
    const a = s.add("x", "y")
    assert.deepEqual(values(a.dropNew([3])), ["a", "b", "c", "y"])
    assert.deepEqual(values(a.dropNew([3, 4])), ["a", "b", "c"])
    assert.deepEqual(values(s.dropNew([0, 1])), ["a", "b", "c"], "saved rows stay")
})

test("the state is immutable", () => {
    const s = Drafts.of(["a"])
    s.set(0, "b")
    s.remove(0)
    assert.equal(s.dirty, false)
})

test("room for another row", () => {
    assert.equal(Drafts.of(Array(MAX_ROWS - 1).fill(0)).hasRoom, true)
    assert.equal(Drafts.of(Array(MAX_ROWS).fill(0)).hasRoom, false)
    assert.equal(new Drafts().hasRoom, true)
})

test("drafts: sorted puts the rows in alphabetical order and keeps their marks", () => {
    const base = Drafts.of(["Zeta", "alpha", "Mango", "beta"]).set(0, "Zeta2")
    const label = (s: string) => s
    assert.equal(base.isSorted(label), false)
    const sorted = base.sorted(label)
    assert.deepEqual(values(sorted), ["alpha", "beta", "Mango", "Zeta2"])
    // the edited row keeps its mark where it went
    assert.deepEqual(marks(sorted), [undefined, undefined, undefined, "*"])
    assert.equal(sorted.isSorted(label), true)
    // equal names keep their order
    const same = Drafts.of(["b", "B", "a"]).sorted(label)
    assert.deepEqual(values(same), ["a", "b", "B"])
})
