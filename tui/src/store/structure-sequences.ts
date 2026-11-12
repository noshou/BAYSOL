// SPDX-License-Identifier: LGPL-3.0-or-later

// Structure sequences: the chains of a PDB or mmCIF file as sequence text.
//
// The buffer's protein (`^f`) and nucleotide (`^e`) rows take a sequence; a structure
// file is one more place to read it from. A PDB file gives its `SEQRES` records (one
// sequence per chain), an mmCIF file its `_entity_poly` loop (one sequence per entity,
// the canonical one-letter code). Chains with the same sequence are one record whose id
// lists them (`1abc_A+B`); a chain of another kind than the one asked for is not taken,
// and a file with none of the asked kind is refused with the kind it has. The result is
// FASTA text, so the rest of the add flow ([[parseText]]) is unchanged.
//
// Contents:
//   1. Residue names: the one-letter code of a three-letter name, the kind of a chain
//   2. PDB: the SEQRES records
//   3. mmCIF: the _entity_poly category
//   4. The chains of a file as FASTA text

import { readFileSync } from "node:fs"
import { basename, extname } from "node:path"
import { lazyAsset } from "../core/environment.js"
import type { SequenceKind } from "./lists.js"

// ========================================================================================
// 1. Residue names
// ========================================================================================

/** One chain or entity of a structure file. */
export type Chain = {
    /** The chain ids (PDB) or the entity id (mmCIF) that have this sequence. */
    ids: string[]
    /** What the chain is made of. */
    kind: SequenceKind | "other"
    /** The one-letter sequence; `X` (protein) or `N` (nucleotide) for an unknown one. */
    letters: string
}

/**
 * The residue names of `assets/data/residues.json` (harvested from the component table
 * of the Julia package by `bysl harvest residues`): `protein` maps an amino-acid
 * component to its one-letter code (a modified one to its parent's, `X` without one),
 * `dna` and `rna` map a nucleotide component to its base (`N` when it names none).
 */
type Table = Readonly<Record<string, string>>
type Residues = { protein: Table; dna: Table; rna: Table }

const residues = lazyAsset<Residues>("data", "residues.json")

/** The letter a table gives a residue name, `undefined` when it is not in the table. */
function letterOf(table: Table, name: string): string | undefined {
    return Object.hasOwn(table, name) ? table[name] : undefined
}

/**
 * The kind of a chain from its residue names, and its sequence.
 *
 * @param names - the residue names in order (three-letter, or one for plain nucleotides).
 * @returns the kind (`other` for water, ligands or an unknown mix) and the letters: a
 *     modified residue is its parent when known, else `X` (protein) or `N` (nucleotide).
 *     Plain `A C G T` is DNA, plain `A C G U` is RNA, plain `A C G` alone is RNA.
 */
export function classify(names: readonly string[]): {
    kind: Chain["kind"]
    letters: string
} {
    const { protein, dna, rna } = residues()
    const up = names.map((n) => n.toUpperCase())
    const nucleic = up.filter((n) => letterOf(dna, n) ?? letterOf(rna, n)).length
    const amino = up.filter((n) => letterOf(protein, n)).length
    if (up.length === 0 || (nucleic === 0 && amino === 0)) {
        return { kind: "other", letters: "" }
    }
    if (amino >= nucleic) {
        const letters = up.map((n) => letterOf(protein, n) ?? "X").join("")
        return { kind: "protein", letters }
    }
    const isDna = up.some((n) => (letterOf(dna, n) ?? "N") !== "N")
    const letters = up.map((n) => letterOf(dna, n) ?? letterOf(rna, n) ?? "N").join("")
    return { kind: isDna ? "dna" : "rna", letters }
}

// ========================================================================================
// 2. PDB
// ========================================================================================

/**
 * The chains of the SEQRES records of PDB text; a file with no SEQRES record at all (most
 * model files, and AlphaFold or SASBDB models) gives the chains of its ATOM/HETATM
 * records instead ([[atomChains]]).
 *
 * @param text - the file.
 * @returns the chains in file order (chains with the same sequence are not yet merged).
 */
export function pdbChains(text: string): Chain[] {
    const order: string[] = []
    const names = new Map<string, string[]>()
    for (const line of text.split(/\r?\n/)) {
        if (!line.startsWith("SEQRES")) continue
        const id = line.slice(11, 12).trim() || "_"
        if (!names.has(id)) {
            names.set(id, [])
            order.push(id)
        }
        const residues = line.slice(19, 70).trim().split(/\s+/).filter(Boolean)
        names.get(id)?.push(...residues)
    }
    if (order.length === 0) return atomChains(text)
    return order.map((id) => ({
        ids: [id],
        ...classify(names.get(id) as string[]),
    }))
}

/**
 * The chains of the ATOM and HETATM records of PDB text, for a file with no SEQRES: the
 * residues of the first MODEL in file order, each residue (chain, number and insertion
 * code) once whatever its alternate locations, and only residues the residue table knows
 * as amino acid or nucleotide (waters, ions and ligands such as heme are no sequence).
 * A residue missing from the structure (a gap, a disordered loop) is missing here too:
 * the sequence is what the model holds, not the deposited one.
 *
 * @param text - the file.
 * @returns the chains in file order.
 */
function atomChains(text: string): Chain[] {
    const { protein, dna, rna } = residues()
    const order: string[] = []
    const names = new Map<string, string[]>()
    const seen = new Set<string>()
    for (const line of text.split(/\r?\n/)) {
        if (line.startsWith("ENDMDL")) break
        if (!(line.startsWith("ATOM") || line.startsWith("HETATM"))) continue
        const name = line.slice(17, 20).trim().toUpperCase()
        const known = letterOf(protein, name) ?? letterOf(dna, name) ?? letterOf(rna, name)
        if (!known) continue
        const chain = line.slice(21, 22).trim() || "_"
        const key = `${chain}|${line.slice(22, 27)}`
        if (seen.has(key)) continue
        seen.add(key)
        if (!names.has(chain)) {
            names.set(chain, [])
            order.push(chain)
        }
        names.get(chain)?.push(name)
    }
    return order.map((id) => ({ ids: [id], ...classify(names.get(id) as string[]) }))
}

// ========================================================================================
// 3. mmCIF
// ========================================================================================

/**
 * The values of one line of a CIF loop or key list: words, with single or double quotes
 * keeping their blanks.
 */
function cifWords(line: string): string[] {
    const words: string[] = []
    const re = /'((?:[^']|'(?=\S))*)'(?=\s|$)|"((?:[^"]|"(?=\S))*)"(?=\s|$)|(\S+)/g
    for (const m of line.matchAll(re)) words.push(m[1] ?? m[2] ?? m[3] ?? "")
    return words
}

/**
 * The rows of the category `_entity_poly` of mmCIF text, each as a column name -> value
 * map (a `;` text block is one value, its lines joined).
 *
 * @param text - the file.
 * @returns the rows (one for the key-value form, one per entity for a loop).
 */
export function entityPolyRows(text: string): Record<string, string>[] {
    const lines = text.split(/\r?\n/)
    const rows: Record<string, string>[] = []
    let i = 0
    // the next value tokens of the lines from `i`, one text block counting as one token
    const takeTokens = (): string[] => {
        const line = lines[i] as string
        if (line.startsWith(";")) {
            const parts = [line.slice(1)]
            i++
            while (i < lines.length && !(lines[i] as string).startsWith(";")) {
                parts.push(lines[i] as string)
                i++
            }
            i++
            return [parts.join("").replace(/\s+/g, "")]
        }
        i++
        return cifWords(line)
    }
    while (i < lines.length) {
        const line = (lines[i] as string).trim()
        if (line === "loop_") {
            i++
            const columns: string[] = []
            while (i < lines.length && (lines[i] as string).trim().startsWith("_")) {
                columns.push((lines[i] as string).trim())
                i++
            }
            if (!columns.some((c) => c.startsWith("_entity_poly."))) continue
            let tokens: string[] = []
            while (i < lines.length) {
                const next = (lines[i] as string).trim()
                if (next === "" || next.startsWith("#")) {
                    if (next === "") {
                        i++
                        continue
                    }
                    break
                }
                if (/^(loop_|_|data_)/.test(next)) break
                tokens = tokens.concat(takeTokens())
            }
            for (let at = 0; at + columns.length <= tokens.length; at += columns.length) {
                const row: Record<string, string> = {}
                columns.forEach((c, k) => {
                    row[c.slice("_entity_poly.".length)] = tokens[at + k] as string
                })
                rows.push(row)
            }
        } else if (line.startsWith("_entity_poly.")) {
            const row: Record<string, string> = {}
            const isKey = (k: number) =>
                (lines[k] as string).trim().startsWith("_entity_poly.")
            while (i < lines.length && isKey(i)) {
                const [key, ...rest] = (lines[i] as string).trim().split(/\s+/)
                i++
                let value = rest.join(" ")
                if (value === "" && i < lines.length) value = takeTokens().join("")
                const name = (key as string).slice("_entity_poly.".length)
                row[name] = cifWords(value)[0] ?? ""
            }
            rows.push(row)
        } else {
            i++
        }
    }
    return rows
}

/**
 * The kind an `_entity_poly.type` value stands for.
 *
 * @param type - the value (`polypeptide(L)`, `polyribonucleotide`, ...).
 * @returns the kind, `other` for the rest.
 */
function entityKind(type: string): Chain["kind"] {
    if (type.startsWith("polypeptide")) return "protein"
    if (type === "polydeoxyribonucleotide") return "dna"
    if (type === "polyribonucleotide") return "rna"
    return "other"
}

/**
 * The entities of mmCIF text as chains.
 *
 * @param text - the file.
 * @returns the entities in file order; the canonical code is used, so a modified
 *     residue is already its parent.
 */
export function cifChains(text: string): Chain[] {
    return entityPolyRows(text).map((row) => ({
        ids: [row.entity_id ?? "?"],
        kind: entityKind(row.type ?? ""),
        letters: (row.pdbx_seq_one_letter_code_can ?? "").toUpperCase(),
    }))
}

// ========================================================================================
// 4. The chains of a file as FASTA text
// ========================================================================================

/** The file extensions (lower case) of a structure file. */
const structureExtensions: readonly string[] = [".pdb", ".ent", ".cif", ".mmcif"]

/**
 * Whether a file name (or path) is a structure file.
 *
 * @param fileName - the name or path.
 * @returns the answer (case does not matter).
 */
export function isStructureFile(fileName: string): boolean {
    const low = fileName.toLowerCase()
    return structureExtensions.some((e) => low.endsWith(e))
}

/** The chains with the same kind and sequence merged: their ids listed together. */
function merged(chains: readonly Chain[]): Chain[] {
    const out: Chain[] = []
    for (const c of chains) {
        const same = out.find((o) => o.kind === c.kind && o.letters === c.letters)
        if (same) same.ids.push(...c.ids)
        else out.push({ ...c, ids: [...c.ids] })
    }
    return out
}

/** The word for a kind in a message. */
const KIND_WORD: Readonly<Record<Chain["kind"], string>> = {
    protein: "protein",
    dna: "DNA",
    rna: "RNA",
    other: "other",
}

/** The key that adds a kind of sequence. */
const KIND_KEY: Readonly<Record<SequenceKind, string>> = {
    protein: "^f",
    dna: "^e",
    rna: "^e",
}

/**
 * The sequences of one kind in a structure file, as FASTA text.
 *
 * @param path - a PDB (`.pdb`, `.ent`) or mmCIF (`.cif`, `.mmcif`) file.
 * @param kind - the kind asked for. DNA and RNA are one nucleotide choice: a chain of the
 *     other nucleotide kind is refused with a note.
 * @returns `{ text }` with one record per distinct sequence (id `<file>_<ids joined
 *     by +>`),
 *     or `{ error }`: `cannot read file`, `no sequences in the file`, or
 *     `no <kind> in the file (it has <kinds>: use ^f / ^e)`.
 */
export function structureFasta(
    path: string,
    kind: SequenceKind,
): { text: string } | { error: string } {
    let text: string
    try {
        text = readFileSync(path, "utf-8")
    } catch {
        return { error: "cannot read file" }
    }
    const low = path.toLowerCase()
    const isCif = low.endsWith(".cif") || low.endsWith(".mmcif")
    const all = isCif ? cifChains(text) : pdbChains(text)
    const chains = merged(all.filter((c) => c.kind !== "other" && c.letters !== ""))
    if (chains.length === 0) return { error: "no sequences in the file" }
    const taken = chains.filter((c) => c.kind === kind)
    if (taken.length === 0) {
        const found = [...new Set(chains.map((c) => c.kind))]
        const word = found.map((k) => KIND_WORD[k]).join(" and ")
        const keys = [...new Set(found.map((k) => KIND_KEY[k as SequenceKind]))].join(" / ")
        return { error: `no ${KIND_WORD[kind]} in the file (it has ${word}: use ${keys})` }
    }
    const stem = basename(path, extname(path))
    const fasta = taken
        .map((c) => `>${stem}_${c.ids.join("+")}\n${c.letters}`)
        .join("\n")
    return { text: fasta }
}
