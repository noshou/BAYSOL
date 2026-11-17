// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/packs.ts and what is built on it: the models of a project in
// `models.7z` and the reference fit in `reference-fit.7z` (notes/models-7z.md): add, list,
// remove, extraction, the old plain folders, an unusable archive, a taken name, and the
// run's staging of the models (`stageModels`, which writes the run's `models.json`).

import assert from "node:assert/strict"
import {
    existsSync,lstatSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    statSync,
    writeFileSync
} from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import {
    ArchiveError,
    archiveTool,
    listEntries,
    rewriteArchiveAsync,
    setArchiveTool,
} from "../src/core/archive.js"
import { PackNameTaken, settleWrites } from "../src/store/packs.js"
import {
    addModel,
    addModels,
    addModelsAsync,
    deleteModel,
    deleteModelAsync,
    extractGenerated,
    extractModels,
    GENERATED_DIR,
    generatedFiles,
    listModels,
    modelsArchive,
    modelsProblem,
    packGenerated,
} from "../src/store/projects.js"
import {
    copyReferences,
    currentReference,
    listReferences,
} from "../src/store/references.js"
import { quitAll, runCache, stageModels, unstageModels } from "../src/store/run.js"
import { tempDir } from "./support/fixtures.js"

/** A file of `text` in a fresh folder, returned by its path. */
function source(name: string, text: string): string {
    const path = join(tempDir(), name)
    writeFileSync(path, text)
    return path
}

/** The text of a model as extraction gives it. */
function model(project: string, name: string): string {
    const into = tempDir()
    extractModels(project, [name], into)
    return readFileSync(join(into, name), "utf-8")
}

/** A project with an old plain `models/` folder (the layout before the archive). */
function oldProject(files: Record<string, string>): string {
    const project = tempDir()
    mkdirSync(join(project, "models"))
    for (const [name, text] of Object.entries(files))
        writeFileSync(join(project, "models", name), text)
    return project
}

test("models: add, list, extract and remove through models.7z, no folder is made", () => {
    const project = tempDir()
    assert.deepEqual(listModels(project), [])
    assert.equal(addModel(project, source("B.pdb", "ATOM b")), modelsArchive(project))
    addModel(project, source("a.cif", "data_a"))
    assert.deepEqual(listModels(project), ["a.cif", "B.pdb"])
    assert.deepEqual(
        listEntries(modelsArchive(project)).map((e) => e.name).sort(),
        ["B.pdb", "a.cif"],
    )
    assert.ok(!existsSync(join(project, "models")))
    assert.equal(model(project, "B.pdb"), "ATOM b")
    assert.equal(model(project, "a.cif"), "data_a")
    assert.equal(deleteModel(project, "a.cif"), true)
    assert.equal(deleteModel(project, "a.cif"), false)
    assert.deepEqual(listModels(project), ["B.pdb"])
    assert.equal(model(project, "B.pdb"), "ATOM b")
    // no temporary file is left beside the archive
    assert.deepEqual(readdirSync(project).filter((f) => f.includes(".tmp")), [])
})

test("models: the archive is solid and compact for alike files", () => {
    const project = tempDir()
    const atom = "ATOM      1  N   ALA A   1      11.104   6.134  -6.504\n"
    const text = atom.repeat(4000)
    addModel(project, source("big.pdb", text))
    assert.ok(statSync(modelsArchive(project)).size < text.length / 20)
})

test("models: an old plain folder is listed, packed at the first change, kept", () => {
    const project = oldProject({ "a.pdb": "A", "b.cif": "B", "notes.txt": "x" })
    assert.deepEqual(listModels(project), ["a.pdb", "b.cif"])
    assert.ok(!existsSync(modelsArchive(project)), "listing writes nothing")
    assert.equal(model(project, "a.pdb"), "A")
    addModel(project, source("c.pdb", "C"))
    assert.ok(existsSync(modelsArchive(project)))
    assert.deepEqual(listModels(project), ["a.pdb", "b.cif", "c.pdb"])
    // the plain folder stays as it was, for its owner to remove
    assert.deepEqual(readdirSync(join(project, "models")).sort(), [
        "a.pdb", "b.cif", "notes.txt",
    ])
    // from now the archive is the list: a removed model does not come back from the folder
    assert.equal(deleteModel(project, "a.pdb"), true)
    assert.deepEqual(listModels(project), ["b.cif", "c.pdb"])
    assert.ok(existsSync(join(project, "models", "a.pdb")))
    // removing the rest leaves an empty archive, not the folder's models
    deleteModel(project, "b.cif")
    deleteModel(project, "c.pdb")
    assert.deepEqual(listModels(project), [])
    assert.equal(modelsProblem(project), undefined)
    addModel(project, source("d.pdb", "D"))
    assert.deepEqual(listModels(project), ["d.pdb"])
})

test("models: removing from a plain folder packs the rest without it", () => {
    const project = oldProject({ "a.pdb": "A", "b.pdb": "B" })
    assert.equal(deleteModel(project, "a.pdb"), true)
    assert.deepEqual(listModels(project), ["b.pdb"])
    assert.ok(existsSync(join(project, "models", "a.pdb")))
})

test("models: a taken name (any case) is refused, the archive is as it was", () => {
    const project = tempDir()
    addModel(project, source("m.pdb", "first"))
    const before = statSync(modelsArchive(project)).mtimeMs
    assert.throws(() => addModel(project, source("m.pdb", "second")), PackNameTaken)
    assert.throws(() => addModel(project, source("M.PDB", "third")), PackNameTaken)
    assert.equal(statSync(modelsArchive(project)).mtimeMs, before)
    assert.equal(model(project, "m.pdb"), "first")
    const { copied, skipped } = addModels(project, [
        source("m.pdb", "x"),
        source("n.cif", "n"),
    ])
    assert.deepEqual(copied, ["n.cif"])
    assert.equal(skipped[0]?.[1], "a model with that name exists")
    // a name that collides with an old folder's model
    const old = oldProject({ "z.pdb": "Z" })
    assert.throws(() => addModel(old, source("Z.pdb", "x")), PackNameTaken)
})

test("models: an unusable archive is read as the plain folder and kept as .corrupt", () => {
    const project = oldProject({ "old.pdb": "OLD" })
    writeFileSync(modelsArchive(project), "this is not a 7z archive")
    assert.deepEqual(listModels(project), ["old.pdb"])
    assert.match(modelsProblem(project) ?? "", /^models\.7z is unusable/)
    addModel(project, source("new.pdb", "NEW"))
    assert.equal(
        readFileSync(`${modelsArchive(project)}.corrupt`, "utf-8"),
        "this is not a 7z archive",
    )
    assert.equal(modelsProblem(project), undefined)
    assert.deepEqual(listModels(project), ["new.pdb", "old.pdb"])
    assert.equal(model(project, "old.pdb"), "OLD")
})

test("models: a missing 7-Zip is an ArchiveError and nothing is written", () => {
    const project = tempDir()
    const real = archiveTool()
    setArchiveTool("/nonexistent/7z")
    try {
        assert.throws(() => addModel(project, source("a.pdb", "A")), ArchiveError)
    } finally {
        setArchiveTool(real)
    }
    assert.ok(!existsSync(modelsArchive(project)))
    assert.deepEqual(readdirSync(project).filter((f) => f.includes(".tmp")), [])
})

test("the reference fit is read from the old folder and copied for a run", () => {
    const project = tempDir()
    const folder = join(project, "reference-fit")
    mkdirSync(folder)
    writeFileSync(join(folder, "old.tsv"), "0.1\t5\n0.2\t4\n0.3\t3\n")
    assert.equal(currentReference(project, "")?.file, "old.tsv")
    assert.equal(listReferences(project)[0]?.points, 3)
    // a run gets the old folder's curves as its own copies
    const into = tempDir()
    assert.equal(copyReferences(project, into), 1)
    assert.equal(
        readFileSync(join(into, "reference-fit-old.tsv"), "utf-8"),
        "0.1\t5\n0.2\t4\n0.3\t3\n",
    )
})

test("a run gets the models of an archive as files, and models.json says where", () => {
    const project = tempDir()
    const run = join(tempDir(), "run-1")
    mkdirSync(run)
    addModel(project, source("a.pdb", "ATOM a"))
    addModel(project, source("a.cif", "data_a"))
    addModel(project, source("compare.pdb", "ATOM c"))
    const folder = stageModels(project, run, tempDir)
    assert.ok(folder !== undefined)
    const entries = JSON.parse(readFileSync(join(run, "models.json"), "utf-8")) as {
        name: string
        path: string
        size: number
        sha256: string
    }[]
    // Julia's rule: byte order of the file names, the stem, -2 for a taken or reserved one
    assert.deepEqual(
        entries.map((e) => e.name),
        ["a", "a-2", "compare-2"],
    )
    assert.deepEqual(
        entries.map((e) => readFileSync(e.path, "utf-8")),
        ["data_a", "ATOM a", "ATOM c"],
    )
    assert.equal(entries[0]?.size, 6)
    assert.match(entries[0]?.sha256 ?? "", /^[0-9a-f]{64}$/)
    unstageModels(run)
    assert.ok(!existsSync(folder))
})

test("a project without an archive is left to Julia: no models.json", () => {
    const project = oldProject({ "a.pdb": "A" })
    const run = join(tempDir(), "run-2")
    mkdirSync(run)
    assert.equal(stageModels(project, run, tempDir), undefined)
    assert.ok(!existsSync(join(run, "models.json")))
})

// ========================================================================================
// Background writes
// ========================================================================================

test("addModelsAsync adds the files in one rewrite, skipping failures", async () => {
    const project = tempDir()
    addModel(project, source("keep.pdb", "ATOM k"))
    const result = await addModelsAsync(project, [
        source("a.cif", "data_a"),
        source("b.pdb", "ATOM b"),
        source("keep.pdb", "again"),
        join(tempDir(), "nowhere.pdb"),
    ])
    assert.deepEqual(result.copied, ["a.cif", "b.pdb"])
    assert.equal(result.skipped.length, 2)
    assert.equal(result.problem, undefined)
    assert.deepEqual(listModels(project), ["a.cif", "b.pdb", "keep.pdb"])
    assert.equal(model(project, "keep.pdb"), "ATOM k")
    assert.deepEqual(readdirSync(project).filter((n) => n.includes(".tmp.")), [])
})

test("writes of one archive queue: an add and a delete both land", async () => {
    const project = tempDir()
    await addModelsAsync(project, [source("a.pdb", "A"), source("b.pdb", "B")])
    const adding = addModelsAsync(project, [source("c.pdb", "C")])
    const deleting = deleteModelAsync(project, "a.pdb")
    const again = addModelsAsync(project, [source("d.pdb", "D")])
    await settleWrites()
    assert.equal(await deleting, true)
    assert.deepEqual((await adding).copied, ["c.pdb"])
    assert.deepEqual((await again).copied, ["d.pdb"])
    assert.deepEqual(listModels(project), ["b.pdb", "c.pdb", "d.pdb"])
    assert.equal(await deleteModelAsync(project, "a.pdb"), false)
})

test("quitting waits for the writes in the background to finish", async () => {
    const project = tempDir()
    const adding = addModelsAsync(project, [source("a.pdb", "A"), source("b.pdb", "B")])
    await quitAll("^c")
    assert.deepEqual(listModels(project), ["a.pdb", "b.pdb"])
    assert.deepEqual((await adding).copied, ["a.pdb", "b.pdb"])
})

test("a failed background write reports why and leaves the archive as it was", async () => {
    const project = tempDir()
    await addModelsAsync(project, [source("a.pdb", "A")])
    const before = readFileSync(modelsArchive(project))
    const tool = archiveTool()
    setArchiveTool(join(tempDir(), "no-such-7z"))
    try {
        const result = await addModelsAsync(project, [source("b.pdb", "B")])
        assert.deepEqual(result.copied, [])
        assert.ok(result.problem !== undefined)
        assert.equal(await deleteModelAsync(project, "a.pdb"), false)
    } finally {
        setArchiveTool(tool)
    }
    assert.deepEqual(readFileSync(modelsArchive(project)), before)
    assert.deepEqual(readdirSync(project).filter((n) => n.includes(".tmp.")), [])
    assert.deepEqual(listModels(project), ["a.pdb"])
})

test("a rewrite whose archive changed meanwhile is refused at the rename", async () => {
    const project = tempDir()
    addModel(project, source("a.pdb", "A"))
    const archive = modelsArchive(project)
    const other = source("x.pdb", "X")
    await assert.rejects(
        rewriteArchiveAsync(archive, ["a.pdb"], new Map([["x.pdb", other]]), (step) => {
            writeFileSync(archive, "another copy wrote this")
            return step()
        }),
        /changed by another copy/,
    )
    assert.equal(readFileSync(archive, "utf-8"), "another copy wrote this")
    assert.deepEqual(readdirSync(project).filter((n) => n.includes(".tmp.")), [])
})

test("the locked step of a background write runs for the rename only", async () => {
    const project = tempDir()
    const calls: number[] = []
    await rewriteArchiveAsync(
        join(project, "x.7z"),
        [],
        new Map([["a.pdb", source("a.pdb", "A")]]),
        (step) => {
            calls.push(1)
            return step()
        },
    )
    assert.equal(calls.length, 1)
    assert.deepEqual(listEntries(join(project, "x.7z")).map((e) => e.name), ["a.pdb"])
})

// ========================================================================================
// Generated files
// ========================================================================================

/** A project with the models `a.cif` and `b.pdb` in `models.7z`. */
async function packedProject(): Promise<string> {
    const project = tempDir()
    await addModelsAsync(project, [source("a.cif", "data_a"), source("b.pdb", "ATOM b")])
    return project
}

test("generated files are packed under generated/, the model list stays", async () => {
    const project = await packedProject()
    const run = join(tempDir(), "run-g")
    mkdirSync(run)
    const shared = tempDir()
    stageModels(project, run, () => shared)
    const cache = runCache(run)
    assert.ok(cache !== undefined)
    // what Julia writes: canonical, hydrogenated and balance, pka, a temp file, a folder
    for (const [name, text] of Object.entries({
        "a.pdb": "canon",
        "a_pH7.0_parse_propka.pdb": "H",
        "a_pH7.0_parse_propka.pdb.balance": "0\t1\t0\t0\n",
        "a.pka": "pka",
        "stranger.pdb": "not from a model",
        "b_pH7.0_parse_none.pdb.tmp.123": "half",
    }))
        writeFileSync(join(cache, name), text)
    mkdirSync(join(cache, "tmpdir"))
    writeFileSync(join(cache, "tmpdir", "x.pdb"), "x")
    assert.equal(await packGenerated(project, cache), 4)
    unstageModels(run)
    assert.ok(runCache(run) === undefined)
    assert.deepEqual(listModels(project), ["a.cif", "b.pdb"])
    assert.deepEqual([...generatedFiles(project).keys()].sort(), [
        "a.pdb",
        "a.pka",
        "a_pH7.0_parse_propka.pdb",
        "a_pH7.0_parse_propka.pdb.balance",
    ])
    const entries = listEntries(modelsArchive(project)).map((e) => e.name)
    assert.ok(entries.includes(`${GENERATED_DIR}/a.pka`))
    // nothing new: nothing is rewritten
    const second = join(tempDir(), "run-g2")
    mkdirSync(second)
    stageModels(project, second, () => shared)
    const again = runCache(second) as string
    assert.equal(readFileSync(join(again, "a_pH7.0_parse_propka.pdb"), "utf-8"), "H")
    assert.equal(readFileSync(join(again, "a.pka"), "utf-8"), "pka")
    assert.equal(await packGenerated(project, again), 0)
    // the shared components are linked, not copied
    assert.ok(lstatSync(join(again, "components")).isSymbolicLink())
    unstageModels(second)
    assert.ok(existsSync(join(shared, "components")), "the shared cache stays")
})

test("generated files survive an added model and go with their model", async () => {
    const project = await packedProject()
    const run = join(tempDir(), "run-d")
    mkdirSync(run)
    stageModels(project, run, tempDir)
    const cache = runCache(run) as string
    writeFileSync(join(cache, "a.pdb"), "canon a")
    writeFileSync(join(cache, "a_pH7.0_parse_propka.pdb"), "H a")
    writeFileSync(join(cache, "b.pdb"), "canon b")
    await packGenerated(project, cache)
    unstageModels(run)
    await addModelsAsync(project, [source("c.pdb", "ATOM c")])
    assert.deepEqual([...generatedFiles(project).keys()].sort(), [
        "a.pdb",
        "a_pH7.0_parse_propka.pdb",
        "b.pdb",
    ])
    assert.equal(await deleteModelAsync(project, "a.cif"), true)
    assert.deepEqual([...generatedFiles(project).keys()], ["b.pdb"])
    assert.deepEqual(listModels(project), ["b.pdb", "c.pdb"])
    // a model of the same name added again starts clean: nothing stale is reused
    await addModelsAsync(project, [source("a.cif", "data_changed")])
    const next = join(tempDir(), "run-d2")
    mkdirSync(next)
    stageModels(project, next, tempDir)
    const staged = readdirSync(runCache(next) as string)
    assert.deepEqual(staged.filter((n) => n !== "components"), ["b.pdb"])
    // the synchronous delete drops them too
    assert.equal(deleteModel(project, "b.pdb"), true)
    assert.deepEqual([...generatedFiles(project).keys()], [])
})

test("a project without models.7z stores nothing, Julia keeps its cache", async () => {
    const project = oldProject({ "a.pdb": "A" })
    const run = join(tempDir(), "run-p")
    mkdirSync(run)
    stageModels(project, run, tempDir)
    assert.equal(runCache(run), undefined)
    assert.deepEqual([...generatedFiles(project).keys()], [])
    const cache = tempDir()
    writeFileSync(join(cache, "a.pdb"), "x")
    assert.equal(await packGenerated(project, cache), 0)
    assert.ok(!existsSync(modelsArchive(project)))
    assert.deepEqual(extractGenerated(await packedProject(), tempDir()).length > 0, true)
})
