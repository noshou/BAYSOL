// SPDX-License-Identifier: LGPL-3.0-or-later

// Structure sequences: PDB SEQRES and mmCIF _entity_poly as sequence records.

import assert from "node:assert/strict"
import { writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { isSequenceFile, parseFile } from "../src/store/lists.js"
import {
    cifChains,
    classify,
    entityPolyRows,
    isStructureFile,
    pdbChains,
    structureFasta,
} from "../src/store/structure-sequences.js"
import { tempDir } from "./support/fixtures.js"

/** A SEQRES line: chain, count, the residues (13 to a line). */
const seqres = (n: number, chain: string, count: number, names: string[]) =>
    `SEQRES ${String(n).padStart(3)} ${chain} ${String(count).padStart(4)}  ` +
    names.join(" ")

const PDB = [
    "HEADER    TEST",
    seqres(1, "A", 5, ["MET", "LYS", "MSE", "ZZZ", "GLY"]),
    seqres(1, "B", 5, ["MET", "LYS", "MSE", "ZZZ", "GLY"]),
    seqres(1, "C", 4, ["DA", "DC", "DG", "DT"]),
    seqres(1, "D", 4, ["A", "C", "G", "U"]),
    "ATOM      1  N   MET A   1      0.000   0.000   0.000  1.00  0.00           N",
].join("\n")

const CIF = `data_TEST
loop_
_entity.id
_entity.type
1 polymer
2 polymer
#
loop_
_entity_poly.entity_id
_entity_poly.type
_entity_poly.pdbx_seq_one_letter_code
_entity_poly.pdbx_seq_one_letter_code_can
1 'polypeptide(L)'
;MKT(MSE)
AG
;
;MKTMAG
;
2 polyribonucleotide ACGU ACGU
#
`

test("residue names: kind and letters, modified residues by parent", () => {
    assert.deepEqual(classify(["MET", "MSE", "ZZZ"]), { kind: "protein", letters: "MMX" })
    assert.deepEqual(classify(["DA", "DC", "DG", "DT"]), { kind: "dna", letters: "ACGT" })
    assert.deepEqual(classify(["A", "C", "G", "T"]), { kind: "dna", letters: "ACGT" })
    assert.deepEqual(classify(["A", "C", "G", "U"]), { kind: "rna", letters: "ACGU" })
    assert.deepEqual(classify(["PSU", "A", "A"]), { kind: "rna", letters: "UAA" })
    assert.equal(classify(["HOH"]).kind, "other")
    assert.equal(classify([]).kind, "other")
})

test("legacy nucleotide names (ADE GUA CYT URI THY) are read as in Julia", () => {
    const rna = classify(["URI", "ADE", "GUA", "CYT"])
    assert.deepEqual(rna, { kind: "rna", letters: "UAGC" })
    const dna = classify(["ADE", "THY", "GUA"])
    assert.deepEqual(dna, { kind: "dna", letters: "ATG" })
    const names = ["ADE", "GUA", "CYT", "URI"]
    const pdb = seqres(1, "A", names.length, names)
    assert.deepEqual(
        pdbChains(pdb).map((c) => [c.kind, c.letters]),
        [["rna", "AGCU"]],
    )
})

test("PDB SEQRES gives one chain per chain id", () => {
    const chains = pdbChains(PDB)
    assert.deepEqual(
        chains.map((c) => [c.ids[0], c.kind, c.letters]),
        [
            ["A", "protein", "MKMXG"],
            ["B", "protein", "MKMXG"],
            ["C", "dna", "ACGT"],
            ["D", "rna", "ACGU"],
        ],
    )
})

/** An ATOM record: residue name, chain, number, altloc, atom name. */
const atom = (
    name: string,
    chain: string,
    num: number,
    alt = " ",
    at = "CA",
    rec = "ATOM",
) =>
    `${rec.padEnd(6)}    1  ${at.padEnd(3)}${alt}${name.padStart(3)} ` +
    `${chain}${String(num).padStart(4)}    ` +
    "   0.000   0.000   0.000  1.00  0.00           C"

test("a PDB without SEQRES gives its chains from the ATOM records", () => {
    const pdb = [
        "MODEL        1",
        atom("MET", "A", 1),
        atom("MET", "A", 1, "A", "CB"),
        atom("LYS", "A", 2),
        atom("LYS", "A", 2, "B", "CB"),
        atom("HEM", "A", 200, " ", "FE", "HETATM"),
        atom("HOH", "A", 300, " ", "O", "HETATM"),
        atom("DA", "B", 1, " ", "P"),
        atom("DC", "B", 2, " ", "P"),
        atom("DG", "B", 3, " ", "P"),
        atom("DT", "B", 4, " ", "P"),
        "ENDMDL",
        "MODEL        2",
        atom("GLY", "A", 9),
        "ENDMDL",
    ].join("\n")
    assert.deepEqual(
        pdbChains(pdb).map((c) => [c.ids[0], c.kind, c.letters]),
        [
            ["A", "protein", "MK"],
            ["B", "dna", "ACGT"],
        ],
    )
    // SEQRES wins when it is there
    const both = `${seqres(1, "A", 2, ["ALA", "GLY"])}\n${pdb}`
    assert.deepEqual(
        pdbChains(both).map((c) => [c.ids[0], c.letters]),
        [["A", "AG"]],
    )
})

test("mmCIF _entity_poly: loop form, quotes and text blocks", () => {
    const rows = entityPolyRows(CIF)
    assert.equal(rows.length, 2)
    assert.equal(rows[0]?.type, "polypeptide(L)")
    assert.equal(rows[0]?.pdbx_seq_one_letter_code, "MKT(MSE)AG")
    assert.deepEqual(
        cifChains(CIF).map((c) => [c.ids[0], c.kind, c.letters]),
        [
            ["1", "protein", "MKTMAG"],
            ["2", "rna", "ACGU"],
        ],
    )
})

test("mmCIF _entity_poly: key-value form", () => {
    const text = [
        "data_X",
        "_entity_poly.entity_id 1",
        "_entity_poly.type polydeoxyribonucleotide",
        "_entity_poly.pdbx_seq_one_letter_code_can ACGT",
        "#",
    ].join("\n")
    assert.deepEqual(
        cifChains(text).map((c) => [c.kind, c.letters]),
        [["dna", "ACGT"]],
    )
})

test("a structure file is a sequence file", () => {
    assert.ok(isStructureFile("a/B.PDB") && isStructureFile("x.mmcif"))
    assert.ok(isSequenceFile("1abc.cif") && isSequenceFile("x.fa"))
    assert.ok(!isSequenceFile("notes.txt"))
})

test("identical chains are one record, the other kinds are refused with a hint", () => {
    const dir = tempDir()
    const pdb = join(dir, "1abc.pdb")
    writeFileSync(pdb, PDB)
    const protein = parseFile(pdb, "protein")
    assert.ok("records" in protein)
    assert.deepEqual(
        protein.records.map((r) => [r.id, r.letters]),
        [["1abc_A+B", "MKMXG"]],
    )
    const dna = parseFile(pdb, "dna")
    assert.ok("records" in dna)
    assert.deepEqual(
        dna.records.map((r) => [r.id, r.letters]),
        [["1abc_C", "ACGT"]],
    )
    const cif = join(dir, "2xyz.cif")
    writeFileSync(cif, CIF)
    const rna = structureFasta(cif, "rna")
    assert.deepEqual(rna, { text: ">2xyz_2\nACGU" })
    assert.deepEqual(structureFasta(cif, "dna"), {
        error: "no DNA in the file (it has protein and RNA: use ^f / ^e)",
    })
})

test("a file with no sequences or that cannot be read is an error", () => {
    const dir = tempDir()
    const empty = join(dir, "e.pdb")
    writeFileSync(empty, "HEADER\nATOM\n")
    assert.deepEqual(structureFasta(empty, "protein"), {
        error: "no sequences in the file",
    })
    assert.deepEqual(structureFasta(join(dir, "none.pdb"), "protein"), {
        error: "cannot read file",
    })
})
