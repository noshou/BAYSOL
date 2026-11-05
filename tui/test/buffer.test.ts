// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { UnusableFileError } from "../src/core/files.js"
import {
    type BufferRow,
    bufferFile,
    kinds,
    readSolutes,
    resetBuffer,
    rowProblem,
    writeSolutes,
} from "../src/store/buffer.js"
import { MAX_ROWS } from "../src/store/limits.js"
import { fixture, fixtureText } from "./support/fixtures.js"

const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

/** The fixtures the Julia loader is tested against too. */
const fixtureRows = fixture("buffer/buffer.json").solutes as BufferRow[]

/** A copy of a fixture row, to change and check. */
const row = (kind: string, n = 0): Record<string, unknown> =>
    structuredClone(fixtureRows.filter((r) => r.kind === kind)[n]) as Record<
        string,
        unknown
    >

/** A project folder whose buffer.json holds `text`. */
function projectWith(text: string): string {
    const dir = tempRoot()
    writeFileSync(bufferFile(dir), text)
    return dir
}

test("every row of the shared fixture is valid, one of each kind at least", () => {
    for (const r of fixtureRows) assert.equal(rowProblem(r), undefined, JSON.stringify(r))
    for (const kind of kinds)
        assert.ok(
            fixtureRows.some((r) => r.kind === kind),
            kind,
        )
    const recipes = fixture("buffer/recipes.json") as {
        recipes: { solutes: unknown[] }[]
    }
    for (const recipe of recipes.recipes)
        for (const r of recipe.solutes) assert.equal(rowProblem(r), undefined)
})

test("a custom-solutes entry is no buffer row, but its snapshot is", () => {
    type Entry = Record<string, unknown> & { name: string; units: unknown[] }
    const file = fixture("buffer/custom-solutes.json") as { solutes: Entry[] }
    const entries = file.solutes
    for (const entry of entries)
        assert.notEqual(rowProblem({ ...entry, mM: 1, "sigma-mM": 0 }), undefined)
    for (const e of entries) {
        const base = { name: e.name, custom: e.name, mM: 1, "sigma-mM": 0 }
        const snapshot =
            e.kind === "nonbiological"
                ? {
                      kind: "custom-nonbio",
                      ...base,
                      z: e.z,
                      pmv: e.pmv,
                      "sigma-pmv": e.sigma,
                  }
                : {
                      kind: "custom-polymer",
                      ...base,
                      units: e.units,
                      counts: e.units.map(() => 3),
                      "z-ends": e["z-ends"],
                      "pmv-ends": e["pmv-ends"],
                      "sigma-ends": e["sigma-ends"],
                  }
        assert.equal(rowProblem(snapshot), undefined, e.name)
    }
})

test("the common keys", () => {
    assert.equal(rowProblem("x"), "a row is not a map")
    assert.equal(rowProblem([]), "a row is not a map")
    assert.equal(rowProblem(null), "a row is not a map")
    assert.equal(rowProblem({ ...row("dna"), kind: "lipid" }), "unknown kind")
    assert.equal(rowProblem({ ...row("dna"), kind: undefined }), "unknown kind")
    for (const bad of [0, -1, Number.NaN, "5", null, undefined, true])
        assert.equal(
            rowProblem({ ...row("dna"), mM: bad }),
            "mM must be above 0",
            String(bad),
        )
    for (const bad of [-0.1, Number.NaN, "1", null, undefined, false])
        assert.equal(
            rowProblem({ ...row("dna"), "sigma-mM": bad }),
            "sigma-mM must be 0 or more",
            String(bad),
        )
    assert.equal(rowProblem({ ...row("dna"), "sigma-mM": 0 }), undefined)
    // the name is only a label
    assert.equal(rowProblem({ ...row("dna"), name: "" }), undefined)
})

test("the argument of a row that has one", () => {
    for (const kind of ["nonbiological", "polymer", "dna", "rna", "protein"])
        for (const bad of [undefined, null, "", "  ", 3]) {
            assert.equal(
                rowProblem({ ...row(kind), arg: bad }),
                "arg must be a name",
                kind,
            )
        }
    const { arg: _arg, ...without } = row("dna")
    assert.equal(rowProblem(without), "arg must be a name")
    // provenance is optional
    const { source: _s, record: _r, ...plain } = row("dna")
    assert.equal(rowProblem(plain), undefined)
})

test("custom non-biological rows", () => {
    const base = row("custom-nonbio")
    assert.equal(rowProblem({ ...base, custom: " " }), "custom must be a name")
    assert.equal(rowProblem({ ...base, z: 1.5 }), "z must be an integer")
    assert.equal(rowProblem({ ...base, z: "102" }), "z must be an integer")
    assert.equal(rowProblem({ ...base, pmv: "x" }), "pmv must be a number")
    assert.equal(
        rowProblem({ ...base, "sigma-pmv": "x" }),
        "sigma-pmv must be a number or null",
    )
    // the key must be there, null or a number
    const { "sigma-pmv": _gone, ...missing } = base
    assert.equal(rowProblem(missing), "sigma-pmv must be a number or null")
    assert.equal(rowProblem({ ...base, "sigma-pmv": null }), undefined)
    // no :arg is needed
    assert.equal("arg" in base, false)
})

test("custom polymer rows", () => {
    const base = row("custom-polymer", 1)
    const units = base.units as Record<string, unknown>[]
    assert.equal(rowProblem({ ...base, custom: "" }), "custom must be a name")
    assert.equal(rowProblem({ ...base, units: [] }), "units needs 1 to 4")
    assert.equal(
        rowProblem({ ...base, units: [...units, units[0]] }),
        "units needs 1 to 4",
    )
    assert.equal(rowProblem({ ...base, units: "x" }), "units needs 1 to 4")
    assert.equal(
        rowProblem({ ...base, units: ["x", ...units.slice(1)] }),
        "a unit is not a map",
    )
    assert.equal(
        rowProblem({ ...base, units: [{ ...units[0], z: 1.5 }, ...units.slice(1)] }),
        "unit z must be an integer",
    )
    assert.equal(
        rowProblem({ ...base, units: [{ ...units[0], slope: null }, ...units.slice(1)] }),
        "unit slope must be a number",
    )
    const { sigma: _s, ...noSigma } = units[0] as Record<string, unknown>
    assert.equal(
        rowProblem({ ...base, units: [noSigma, ...units.slice(1)] }),
        "unit sigma must be a number or null",
    )
    assert.equal(rowProblem({ ...base, counts: [1, 2, 3] }), "counts needs one per unit")
    assert.equal(rowProblem({ ...base, counts: [1, 2, 3, "x"] }), "counts must be numbers")
    assert.equal(rowProblem({ ...base, counts: 3 }), "counts must be numbers")
    assert.equal(rowProblem({ ...base, "z-ends": 0.5 }), "z-ends must be an integer")
    assert.equal(rowProblem({ ...base, "pmv-ends": "x" }), "pmv-ends must be a number")
    assert.equal(
        rowProblem({ ...base, "sigma-ends": "x" }),
        "sigma-ends must be a number or null",
    )
})

test("a missing or empty file is a buffer with no solutes", () => {
    const dir = tempRoot()
    assert.deepEqual(readSolutes(dir), [])
    for (const text of ["", "  \n", "{}", '{"solutes": []}'])
        assert.deepEqual(readSolutes(projectWith(text)), [], JSON.stringify(text))
})

test("a file that cannot be used is told and never written over", () => {
    const unusable = [
        "[1 2 3]",
        '"a string"',
        "42",
        "{ truncated",
        "// a comment",
        '{"solutes": null}',
        '{"solutes": {}}',
        '{"solutes": [1]}',
        '{"solutes": [{"kind": "dna", "name": "x", "arg": "AC", "mM": 0, "sigma-mM": 0}]}',
    ]
    for (const text of unusable) {
        const dir = projectWith(text)
        assert.throws(() => readSolutes(dir), UnusableFileError, text)
        assert.throws(() => writeSolutes(dir, []), UnusableFileError, text)
        assert.equal(readFileSync(bufferFile(dir), "utf-8"), text)
    }
    // more than 999 solutes
    const rows = Array.from({ length: MAX_ROWS + 1 }, () => fixtureRows[0] as BufferRow)
    assert.throws(() => writeSolutes(tempRoot(), rows), /too many/)
    const one =
        '{"kind": "polymer", "name": "p", "arg": "PEG 3350", "mM": 1, "sigma-mM": 0}'
    const text = `{"solutes": [${rows.map(() => one).join(",")}]}`
    assert.throws(() => readSolutes(projectWith(text)), UnusableFileError)
    const full = rows.slice(1).map(() => fixtureRows[0] as BufferRow)
    const dir = tempRoot()
    writeSolutes(dir, full)
    assert.equal(readSolutes(dir).length, MAX_ROWS)
})

test("the fixture is read, and what is written reads back the same", () => {
    const dir = projectWith(fixtureText("buffer/buffer.json"))
    const solutes = readSolutes(dir)
    assert.deepEqual(solutes, fixtureRows)
    const other = tempRoot()
    writeSolutes(other, solutes)
    assert.deepEqual(readSolutes(other), solutes)
    // the kind goes out as a plain string, two-space indented, ending in a newline
    const text = readFileSync(bufferFile(other), "utf-8")
    assert.match(text, /"kind": "custom-polymer"/)
    assert.ok(text.endsWith("}\n"))
})

test("writing keeps the other keys of the file and refuses a bad row", () => {
    const dir = projectWith('{"solutes": [], "ph": 7.4}')
    const rows = [fixtureRows[0] as BufferRow]
    writeSolutes(dir, rows)
    const written = JSON.parse(readFileSync(bufferFile(dir), "utf-8")) as Record<
        string,
        unknown
    >
    assert.equal(written.ph, 7.4)
    assert.deepEqual(written.solutes, rows)
    const before = readFileSync(bufferFile(dir), "utf-8")
    assert.throws(
        () => writeSolutes(dir, [{ ...rows[0], mM: 0 } as BufferRow]),
        /not a valid buffer row: mM must be above 0/,
    )
    assert.equal(readFileSync(bufferFile(dir), "utf-8"), before)
})

test("a reset keeps the unusable file as .corrupt", () => {
    const dir = projectWith("[1, 2, 3]")
    const kept = resetBuffer(dir)
    assert.equal(kept, `${bufferFile(dir)}.corrupt`)
    assert.equal(readFileSync(`${bufferFile(dir)}.corrupt`, "utf-8"), "[1, 2, 3]")
    assert.equal(existsSync(bufferFile(dir)), false)
    assert.deepEqual(readSolutes(dir), [])
    assert.equal(resetBuffer(dir), undefined) // nothing to rename now
})
