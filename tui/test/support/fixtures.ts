// SPDX-License-Identifier: LGPL-3.0-or-later

import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { renderToString } from "ink"
import { createElement, type ReactElement } from "react"
import { readAssetJson } from "../../src/core/environment.js"
import { NavProvider } from "../../src/ui/interaction.js"
import { defaultTheme, ThemeContext } from "../../src/ui/theme.js"

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

/**
 * A project folder with the inputs of a run: an empty buffer and a three-column data
 * file with its units.
 *
 * @returns the folder.
 */
export function scratchProject(): string {
    const dir = tempDir()
    writeFileSync(join(dir, "buffer.json"), '{"solutes": []}\n')
    writeFileSync(join(dir, "data.tsv"), "0.1\t5\t0.1\n")
    writeFileSync(join(dir, "data.json"), '{"units": "A-1", "energy": 8000}\n')
    return dir
}

/**
 * Draws a screen on the default theme, as the terminal would show it (24 rows).
 *
 * @param screen - the screen.
 * @param columns - the width of the terminal.
 * @returns the text, lines joined by newlines.
 */
export function drawScreen(screen: ReactElement, columns = 80): string {
    return renderToString(
        createElement(
            ThemeContext.Provider,
            { value: defaultTheme },
            createElement(NavProvider, { root: screen }),
        ),
        { columns },
    )
}

/** The residue names of `assets/data/residues.json`, name to one-letter code. */
const residueLetters = readAssetJson<
    Record<"protein" | "dna" | "rna", Record<string, string>>
>("data", "residues.json")

/**
 * The sequence of a chain, read from the SEQRES records of a PDB file of
 * `test/fixtures/molecules/` (real biology, not made up): amino acids and nucleotides
 * (`DA`, `DC`, ... or `A`, `U`, ...) as one letter each, a modified residue as its
 * parent (the table of `residues.json`).
 *
 * @param file - the file name, `1CRN-TEST.pdb`.
 * @param chain - the chain id.
 * @returns the letters.
 * @throws if the chain has no SEQRES or a residue has no letter.
 */
export function seqresLetters(file: string, chain: string): string {
    const names = fixtureText(`molecules/${file}`)
        .split("\n")
        .filter((l) => l.startsWith("SEQRES") && l[11] === chain)
        .flatMap((l) => l.slice(19).trim().split(/\s+/))
    if (names.length === 0) throw new Error(`no SEQRES of chain ${chain} in ${file}`)
    return names
        .map((n) => {
            // "X" (no amino acid) and "N" (no base) are the table's "unknown"
            const amino = residueLetters.protein[n]
            const base = residueLetters.dna[n] ?? residueLetters.rna[n]
            if (amino !== undefined && amino !== "X") return amino
            if (amino === undefined && base !== undefined && base !== "N") return base
            throw new Error(`residue ${n} of ${file} has no letter`)
        })
        .join("")
}

/**
 * A run folder name of the current format at a UTC time.
 *
 * @param date - `YYYY-MM-DD`.
 * @param time - `HH-MM-SS`, midnight when left out.
 * @returns the name (`00-00-00-000_UTC_+0000_2026-11-01`).
 */
export const runOn = (date: string, time = "00-00-00"): string =>
    `${time}-000_UTC_+0000_${date}`
