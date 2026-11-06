// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { test } from "node:test"
import {
    accepted,
    addModel,
    addModels,
    deleteModel,
    listModels,
    modelPathProblem,
    modelsDir,
} from "../src/store/models.js"
import { complete, hintsFor } from "../src/store/path-input.js"

/** The hints of a typed path for structure files. */
const hints = (text: string) => hintsFor(text, accepted)

const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

/** Writes a file (its folders made) and returns its path. */
function file(dir: string, name: string, text: string): string {
    const path = join(dir, name)
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, text)
    return path
}

test("accepted files", () => {
    for (const n of ["a.cif", "a.pdb", "A.PDB", "x.y.Cif"]) assert.ok(accepted(n), n)
    for (const n of ["a.txt", "pdb", "a.pdbx", "a.", ""]) assert.ok(!accepted(n), n)
})

test("paths", () => {
    const src = tempRoot()
    const pdb = file(src, "one.pdb", "ATOM")
    assert.equal(modelPathProblem(pdb, []), undefined)
    assert.equal(modelPathProblem("  ", []), "type the full path of a model file first!")
    assert.equal(modelPathProblem("one.pdb", []), "use a full absolute path")
    assert.equal(modelPathProblem(join(src, "none.pdb"), []), "no such file")
    assert.equal(modelPathProblem(src, []), "that is a folder, not a file")
    assert.equal(modelPathProblem(file(src, "n.txt", "x"), []), "only .cif and .pdb files")
    assert.equal(modelPathProblem(pdb, ["ONE.pdb"]), "a model with that name exists")
    for (const m of [
        "use a full absolute path",
        "that is a folder, not a file",
        "a model with that name exists",
        "could not copy the file!",
    ])
        assert.ok(m.length <= 42, m)
})

test("add copies and never moves", () => {
    const src = tempRoot()
    const project = tempRoot()
    const pdb = file(src, "one.pdb", "ATOM")
    assert.deepEqual(listModels(project), []) // no models/ folder: no models
    const copy = addModel(project, pdb)
    assert.equal(readFileSync(copy, "utf-8"), "ATOM")
    assert.equal(copy, join(project, "models", "one.pdb"))
    assert.ok(existsSync(pdb), "the original is still there")
    assert.deepEqual(listModels(project), ["one.pdb"])
    // a model is never overwritten
    writeFileSync(pdb, "CHANGED")
    assert.throws(() => addModel(project, pdb))
    assert.equal(readFileSync(join(project, "models", "one.pdb"), "utf-8"), "ATOM")
})

test("adding several", () => {
    const src = tempRoot()
    const project = tempRoot()
    const a = file(src, "a.pdb", "A")
    const b = file(src, "sub/b.cif", "B")
    const dup = file(src, "sub/a.pdb", "other")
    const txt = file(src, "c.txt", "C")
    const none = join(src, "none.pdb")
    const { copied, skipped } = addModels(project, [a, b, dup, txt, none])
    assert.deepEqual(copied, ["a.pdb", "b.cif"])
    assert.deepEqual(
        skipped.map((s) => s[0]),
        [dup, txt, none],
    )
    assert.deepEqual(
        skipped.map((s) => s[1]),
        ["a model with that name exists", "only .cif and .pdb files", "no such file"],
    )
    assert.equal(readFileSync(join(project, "models", "a.pdb"), "utf-8"), "A") // first wins
    for (const f of [a, b, dup, txt]) assert.ok(existsSync(f), "nothing was moved")
    assert.deepEqual(addModels(project, []), { copied: [], skipped: [] })
})

test("only models are listed", () => {
    const project = tempRoot()
    file(modelsDir(project), "b.CIF", "x")
    file(modelsDir(project), "A.pdb", "x")
    file(modelsDir(project), "notes.txt", "x")
    mkdirSync(join(project, "models", "dir.pdb"))
    assert.deepEqual(listModels(project), ["A.pdb", "b.CIF"])
})

test("deleting is limited to the models", () => {
    const project = tempRoot()
    const outside = file(tempRoot(), "keep.pdb", "x")
    file(modelsDir(project), "a.pdb", "x")
    file(modelsDir(project), "b.cif", "x")
    assert.equal(deleteModel(project, "../../nothing.pdb"), false)
    assert.equal(deleteModel(project, `../${outside}`), false)
    assert.equal(deleteModel(project, "missing.pdb"), false)
    assert.ok(existsSync(outside))
    assert.equal(deleteModel(project, "a.pdb"), true)
    assert.deepEqual(listModels(project), ["b.cif"])
    // deleting them all is the same as having had none
    assert.equal(deleteModel(project, "b.cif"), true)
    assert.deepEqual(listModels(project), [])
    assert.deepEqual(listModels(tempRoot()), [])
})

test("hints and completion", () => {
    const dir = tempRoot()
    mkdirSync(join(dir, "Sub"))
    mkdirSync(join(dir, ".hidden"))
    file(dir, "alpha.pdb", "x")
    file(dir, "Beta.cif", "x")
    file(dir, "notes.txt", "x")
    const d = `${dir}/`
    // folders first, then models, no other files, no dot names
    assert.deepEqual(hints(d), ["Sub/", "alpha.pdb", "Beta.cif"])
    // narrowed by what is typed, case does not matter
    assert.deepEqual(hints(`${d}AL`), ["alpha.pdb"])
    assert.deepEqual(hints(`${d}su`), ["Sub/"])
    assert.deepEqual(hints(`${d}.`), [".hidden/"])
    assert.deepEqual(hints(`${d}zzz`), [])
    // no hints without an absolute path in a folder that exists
    assert.deepEqual(hints(""), [])
    assert.deepEqual(hints("alpha"), [])
    assert.deepEqual(hints("/no/such/folder/x"), [])
    // hintsFor takes any predicate on the file name
    assert.deepEqual(
        hintsFor(d, (n) => n.endsWith(".txt")),
        ["Sub/", "notes.txt"],
    )
    assert.deepEqual(
        hintsFor(d, () => false),
        ["Sub/"],
    )
    assert.deepEqual(hintsFor(d, accepted), hints(d))
    // completion replaces the last part
    assert.equal(complete(`${d}al`, "alpha.pdb"), `${d}alpha.pdb`)
    assert.equal(complete(d, "Sub/"), `${d}Sub/`)
})
