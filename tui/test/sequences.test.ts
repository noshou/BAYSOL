// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import {
    isFastaFile,
    parseFile,
    parseText,
    type SequenceKind,
    type SequenceResult,
    summary,
} from "../src/store/sequences.js"

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
    assert.equal(errorOf(parseText(">d\nACGU\n", "dna")), "bad letter U (DNA)")
    assert.equal(errorOf(parseText(">r\nACGT\n", "rna")), "bad letter T (RNA)")
    assert.ok("records" in parseText(">p\nACDEFGHIKLMNPQRSTVWYBJZOUX*\n", "protein"))
    assert.equal(errorOf(parseText(">p\nMK1\n", "protein")), "bad letter 1 (protein)")
    assert.equal(errorOf(parseText(">p\nMK-L\n", "protein")), "bad letter - (protein)")
    // a placeholder is kept, a record of nothing else is empty
    assert.deepEqual(pairs(parseText(">p\nMKT*\n", "protein")), [["p", "MKT*"]])
    assert.equal(errorOf(parseText(">p\n*\n", "protein")), "empty sequence")
    assert.equal(errorOf(parseText(">p\nACX\n", "dna")), "bad letter X (DNA)")
    // an unknown kind is a programming error
    assert.throws(() => parseText(">p\nAC\n", "lipid" as SequenceKind))
})

test("FASTA errors", () => {
    assert.equal(errorOf(parseText("", "dna")), "no records")
    assert.equal(errorOf(parseText("\n \n", "dna")), "no records")
    assert.equal(errorOf(parseText(">a\n", "dna")), "empty sequence")
    assert.equal(errorOf(parseText(">a\nAC\n>b\n\n>c\nGT\n", "dna")), "empty sequence")
    assert.equal(errorOf(parseText("ACGT\n", "dna")), "wrong format")
    assert.equal(errorOf(parseText("#>a\nACGT\n", "dna")), "wrong format")
    // an @ in a FASTA body is no header
    assert.equal(errorOf(parseText(">a\nAC\n@b\nGT\n", "dna")), "bad letter @ (DNA)")
    // every message fits the border note
    for (const text of ["", ">a\n", "x", ">a\nMK1\n", "@a\nAC\n+\nA\n"])
        for (const kind of ["dna", "rna", "protein"] as const) {
            const e = errorOf(parseText(text, kind))
            if (e !== undefined) assert.ok(e.length <= 22, e)
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
    assert.equal(errorOf(parseText("@r\nACQT\n+\nIIII\n", "dna")), "bad letter Q (DNA)")
})

test("files", () => {
    const dir = mkdtempSync(join(tmpdir(), "baysol-test-"))
    const multi = join(dir, "multi.fa")
    writeFileSync(multi, ">p1 one\nMKTAYIAK\nQRQ\n\n>p2\nGSHM*\n")
    const bad = join(dir, "bad.fasta")
    writeFileSync(bad, "ACGT\n")
    assert.deepEqual(pairs(parseFile(multi, "protein")), [
        ["p1", "MKTAYIAKQRQ"],
        ["p2", "GSHM*"],
    ])
    assert.deepEqual(parseFile(bad, "dna"), { error: "wrong format" })
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
