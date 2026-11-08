// SPDX-License-Identifier: LGPL-3.0-or-later

import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

/**
 * The fixtures the Julia side and this program are both tested against: the files of
 * `test/fixtures/` at the root of the repository (plain JSON).
 */

/**
 * The text of a shared fixture file.
 *
 * @param path - the path below `test/fixtures/` of the repository, `buffer/buffer.json`.
 * @returns the file's text.
 * @throws if there is no such file.
 */
export function fixtureText(path: string): string {
    return readFileSync(
        fileURLToPath(new URL(`../../../test/fixtures/${path}`, import.meta.url)),
        "utf-8",
    )
}

/**
 * The object of a shared fixture file.
 *
 * @param path - as for [[fixtureText]].
 * @returns the object; its keys are those of the file.
 * @throws if there is no such file or it is not a JSON object.
 */
export function fixture(path: string): Record<string, unknown> {
    return JSON.parse(fixtureText(path)) as Record<string, unknown>
}

/** The folders [[tempDir]] made, removed when this process exits. */
const made = new Set<string>()
process.once("exit", () => {
    for (const dir of made) rmSync(dir, { recursive: true, force: true })
})

/**
 * A fresh empty folder below the system temp folder, for a test that writes files. It is
 * removed when the test process exits (the real-process tests clean their own).
 *
 * @param prefix - the start of the folder's name.
 * @returns the absolute path.
 */
export function tempDir(prefix = "baysol-test-"): string {
    const dir = mkdtempSync(join(tmpdir(), prefix))
    made.add(dir)
    return dir
}

/** One-letter codes of the twenty standard amino acids, by their PDB names. */
const aminoLetters: Readonly<Record<string, string>> = {
    ALA: "A", ARG: "R", ASN: "N", ASP: "D", CYS: "C", GLN: "Q", GLU: "E", GLY: "G",
    HIS: "H", ILE: "I", LEU: "L", LYS: "K", MET: "M", PHE: "F", PRO: "P", SER: "S",
    THR: "T", TRP: "W", TYR: "Y", VAL: "V",
}

/**
 * The sequence of a chain, read from the SEQRES records of a PDB file of
 * `test/fixtures/molecules/` (real biology, not made up): amino acids and nucleotides
 * (`DA`, `DC`, ... or `A`, `U`, ...) as one letter each.
 *
 * @param file - the file name, `1CRN-TEST.pdb`.
 * @param chain - the chain id.
 * @returns the letters.
 * @throws if the chain has no SEQRES or a residue is modified.
 */
export function seqresLetters(file: string, chain: string): string {
    const names = fixtureText(`molecules/${file}`)
        .split("\n")
        .filter((l) => l.startsWith("SEQRES") && l[11] === chain)
        .flatMap((l) => l.slice(19).trim().split(/\s+/))
    if (names.length === 0) throw new Error(`no SEQRES of chain ${chain} in ${file}`)
    return names
        .map((n) => {
            const letter = aminoLetters[n] ?? (/^D?[ACGTU]$/.test(n) ? n.slice(-1) : "")
            if (letter === "") throw new Error(`modified residue ${n} in ${file}`)
            return letter
        })
        .join("")
}
