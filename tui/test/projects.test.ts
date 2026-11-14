// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/projects.ts: the run folder, the projects and the models.
//
// Contents:
//   1. Run folder
//   2. Projects
//   3. Models

import assert from "node:assert/strict"
import {
    copyFileSync,
    existsSync,
    mkdirSync,
    readFileSync,
    symlinkSync,
    writeFileSync,
} from "node:fs"
import { hostname } from "node:os"
import { dirname, join } from "node:path"
import { test } from "node:test"
import { projectsRoot } from "../src/core/environment.js"
import { entryNames, writeJson } from "../src/core/file-system.js"
import { pickNote } from "../src/screens/models.js"
import { checkPath, complete, hintsFor, pathSuggestions } from "../src/store/lists.js"
import {
    accepted,
    addModel,
    addModels,
    brokenNames,
    createProject,
    deleteModel,
    deleteProject,
    hasRuns,
    InvalidNameError,
    isoStamp,
    listModels,
    listProjects,
    livePid,
    modelPathProblem,
    modelsDir,
    projectNameProblem,
    readProject,
    runIds,
    runStatus,
    settleRun,
} from "../src/store/projects.js"
import { destructiveQuestion } from "../src/ui/input.js"
import { runOn, tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. Run folder
// ========================================================================================

/** Makes `runs/<id>/` with a `run.json` holding `json` (none when `undefined`). */
function makeRun(project: string, id: string, json?: string): void {
    const dir = join(project, "runs", id)
    mkdirSync(dir, { recursive: true })
    if (json !== undefined) writeFileSync(join(dir, "run.json"), json)
}

test("a project with no runs/ folder has no runs", () => {
    const project = tempDir()
    assert.deepEqual(runIds(project), [])
    assert.equal(hasRuns(project), false)
})

test("runs are the folders of runs/, oldest first, files are not runs", () => {
    const project = tempDir()
    makeRun(project, "15-30-45-000_UTC_+0000_2026-11-02")
    makeRun(project, runOn("2026-11-01"))
    // the new name sorts by its instant (23:00 at -05:00 on the 1st is 04:00Z on the 2nd)
    makeRun(project, "23-00-00-000_EST_-0500_2026-11-01")
    makeRun(project, "09-00-00-000_UTC_+0000_2026-11-02")
    makeRun(project, "unreadable")
    writeFileSync(join(project, "runs", "notes.txt"), "x")
    // the old layout is not read: logs/ and data/ hold no runs
    mkdirSync(join(project, "logs", runOn("2025-01-01")), { recursive: true })
    mkdirSync(join(project, "data", runOn("2025-01-01")), { recursive: true })
    assert.deepEqual(runIds(project), [
        "unreadable",
        runOn("2026-11-01"),
        "23-00-00-000_EST_-0500_2026-11-01",
        "09-00-00-000_UTC_+0000_2026-11-02",
        "15-30-45-000_UTC_+0000_2026-11-02",
    ])
    assert.equal(hasRuns(project), true)
})

test("run.json says how a run ended; a bad file says nothing", () => {
    const project = tempDir()
    makeRun(project, "a", '{"status": "running"}')
    makeRun(project, "b", '{"status": "failed"}')
    makeRun(project, "c", '{"status": "bogus"}')
    makeRun(project, "d", "{ not json")
    makeRun(project, "e")
    assert.equal(runStatus(project, "a"), "running")
    assert.equal(runStatus(project, "b"), "failed")
    for (const id of ["c", "d", "e", "missing"])
        assert.equal(runStatus(project, id), undefined, id)
    assert.equal(hasRuns(project), true)
    makeRun(project, "f", '{"status": "done", "models": []}')
    assert.equal(runStatus(project, "f"), "done")
})

// ---- the run flow's reading side: liveness, the default temperature -------------------

/** Makes a run with a plain `run.LOG` holding `log`. */
function finishedRun(project: string, id: string, status: string, log?: string): string {
    const dir = join(project, "runs", id)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, "run.json"), writeJson({ status }))
    if (log !== undefined) writeFileSync(join(dir, "run.LOG"), log)
    return dir
}

test("a live run, the pid rule and the heartbeat age", () => {
    const dir = finishedRun(tempDir(), runOn("2026-01-01"), "running")
    const beat = (pid: number, host: string, ms: number) =>
        writeFileSync(
            join(dir, "run.json"),
            writeJson({ status: "running", pid, host, heartbeat: isoStamp(ms) }),
        )
    beat(process.pid, hostname(), Date.now())
    assert.equal(livePid(dir), process.pid)
    beat(2 ** 22 + 5, hostname(), Date.now())
    assert.equal(livePid(dir), undefined, "no such process on this host")
    // another host: the pid cannot be checked, the heartbeat decides
    beat(2 ** 22 + 5, "some-other-host", Date.now())
    assert.equal(livePid(dir), 2 ** 22 + 5)
    beat(2 ** 22 + 5, "some-other-host", Date.now() - 61_000)
    assert.equal(livePid(dir), undefined)
    writeFileSync(join(dir, "run.json"), "{ not json")
    assert.equal(livePid(dir), undefined, "a file that cannot be read is no run")
})

test("settle changes only a running run, and leaves a live one", () => {
    const project = tempDir()
    const done = finishedRun(project, runOn("2026-01-01"), "done", "temperatureC\t20\n")
    assert.equal(settleRun(done, "aborted"), false)
    assert.equal(runStatus(project, runOn("2026-01-01")), "done")
    const live = finishedRun(project, runOn("2026-01-02"), "running", "temperatureC\t20\n")
    writeFileSync(
        join(live, "run.json"),
        writeJson({
            status: "running",
            pid: process.pid,
            host: hostname(),
            heartbeat: isoStamp(Date.now()),
        }),
    )
    assert.equal(settleRun(live, "interrupted", { ifStale: true }), false, "live: kept")
    assert.equal(settleRun(live, "aborted"), true, "the caller knows it is over")
    assert.equal(runStatus(project, runOn("2026-01-02")), "aborted")
})

// ========================================================================================
// 2. Projects
// ========================================================================================

/** Hooks that stand in for the settings module: the "global settings" is a text file. */
function hooksFor(appRoot: string, text = "global settings\n") {
    const globalFile = join(appRoot, "settings.json")
    return {
        prepareGlobal: () => writeFileSync(globalFile, text),
        copySettings: (dir: string) => copyFileSync(globalFile, join(dir, "settings.json")),
        globalFile,
    }
}

test("what is a project", () => {
    const root = tempDir()
    const make = (name: string, text?: string) => {
        mkdirSync(join(root, name), { recursive: true })
        if (text !== undefined) writeFileSync(join(root, name, "project.json"), text)
    }
    make("good", '{"id": "good", "created": "2026-11-01T00:00:00Z"}')
    make("Alpha", '{"id": "Alpha"}')
    make("wrong-id", '{"id": "someone-else"}')
    make("no-id", '{"created": "x"}')
    make("not-json", "{ nonsense")
    make("not-a-map", "[1 2 3]")
    make("no-file")
    make("empty", "")
    writeFileSync(join(root, "loose-file.txt"), "a file is no project")
    // only a folder with a project.json of its own id is a project, sorted
    assert.deepEqual(listProjects(root), ["Alpha", "good"])
    // every name in the folder is taken, a project or not
    assert.deepEqual(
        new Set(entryNames(root)),
        new Set([
            "good",
            "Alpha",
            "wrong-id",
            "no-id",
            "not-json",
            "not-a-map",
            "no-file",
            "empty",
            "loose-file.txt",
        ]),
    )
    assert.equal(readProject(join(root, "good"))?.id, "good")
    assert.equal(readProject(join(root, "wrong-id")), undefined)
    assert.equal(readProject(join(root, "not-json")), undefined)
    assert.equal(readProject(join(root, "missing")), undefined)
    // no projects folder is no projects
    const nowhere = join(tempDir(), "nowhere")
    assert.deepEqual(listProjects(nowhere), [])
    assert.deepEqual(entryNames(nowhere), [])
})

test("making a project", () => {
    const appRoot = tempDir()
    const hooks = hooksFor(appRoot)
    const dir = createProject(appRoot, "first", hooks)
    assert.equal(dir, join(projectsRoot(appRoot), "first"))
    const info = JSON.parse(readFileSync(join(dir, "project.json"), "utf-8")) as Record<
        string,
        unknown
    >
    assert.equal(info.id, "first")
    assert.equal(typeof info.created, "string")
    assert.deepEqual(readProject(dir), info)
    // an exact copy of the global settings
    assert.equal(readFileSync(join(dir, "settings.json"), "utf-8"), "global settings\n")
    assert.deepEqual(listProjects(projectsRoot(appRoot)), ["first"])
    createProject(appRoot, "second", hooks)
    assert.deepEqual(listProjects(projectsRoot(appRoot)), ["first", "second"])
})

test("a name that is not valid or is taken makes nothing", () => {
    const appRoot = tempDir()
    const hooks = hooksFor(appRoot)
    createProject(appRoot, "taken", hooks)
    for (const bad of [
        "",
        "has space",
        "a/b",
        "con",
        "name.",
        "x".repeat(41),
        "taken",
        "TAKEN",
    ]) {
        assert.throws(
            () => createProject(appRoot, bad, hooks),
            (e) => e instanceof InvalidNameError && e.reason.length > 0,
            JSON.stringify(bad),
        )
    }
    assert.deepEqual(entryNames(projectsRoot(appRoot)), ["taken"])
})

test("a project that fails half way is removed, and a refused global makes nothing", () => {
    const appRoot = tempDir()
    const hooks = hooksFor(appRoot)
    const failing = {
        ...hooks,
        copySettings: () => {
            throw new Error("cannot write")
        },
    }
    assert.throws(() => createProject(appRoot, "broken", failing), /cannot write/)
    assert.equal(existsSync(join(projectsRoot(appRoot), "broken")), false)
    // and the name is free again
    assert.equal(projectNameProblem("broken", entryNames(projectsRoot(appRoot))), undefined)
    const refused = {
        ...hooks,
        prepareGlobal: () => {
            throw new Error("no settings")
        },
    }
    assert.throws(() => createProject(appRoot, "p", refused), /no settings/)
    assert.equal(existsSync(join(projectsRoot(appRoot), "p")), false)
})

test("good names", () => {
    const good = [
        "a",
        "A",
        "1",
        "run1",
        "My_Project",
        "my-project",
        "my.project",
        "x.y.z",
        "2026-11-01",
        "sasdmj9",
        "SASDMJ9_fit1",
        "a".repeat(40),
        "a--b",
        "a__b",
        "9lives",
        "console",
        "communicate",
        "auxiliary",
        "lpt10",
        "com10",
    ]
    for (const n of good) assert.equal(projectNameProblem(n, []), undefined, n)
})

test("bad names, in the order of the checks", () => {
    const chars = "use only a-z 0-9 . _ -"
    const start = "start with a letter or digit"
    const reserved = "reserved name, pick another"
    const cases: [string, string][] = [
        ["", "type a name first!"],
        ["   ", "type a name first!"],
        ["a".repeat(41), "name too long (40 at most)"],
        ["a".repeat(200), "name too long (40 at most)"],
        ["has space", chars],
        ["a/b", chars],
        ["a\\b", chars],
        ["../up", chars],
        [".hidden", start],
        ["-dash", start],
        ["_under", start],
        ["na:me", chars],
        ["na*me", chars],
        ["na?me", chars],
        ["é", chars],
        ["name\n", chars],
        ["tab\tname", chars],
        ["a~b", chars],
        ["..", start],
        [".", start],
        ["name.", "must not end with a dot"],
        ["a..", "must not end with a dot"],
        ["con", reserved],
        ["CON", reserved],
        ["Nul", reserved],
        ["aux", reserved],
        ["prn", reserved],
        ["com1", reserved],
        ["COM9", reserved],
        ["lpt1", reserved],
        ["con.txt", reserved],
        ["nul.x.y", reserved],
    ]
    for (const [name, message] of cases) {
        assert.equal(projectNameProblem(name, []), message, JSON.stringify(name))
        assert.ok(message.length <= 29, "the message fits the main menu")
    }
})

test("a name that is taken is refused whatever its case", () => {
    const taken = "that project already exists!"
    assert.equal(projectNameProblem("run", ["run"]), taken)
    assert.equal(projectNameProblem("Run", ["run"]), taken)
    assert.equal(projectNameProblem("RUN", ["Run", "other"]), taken)
    assert.equal(projectNameProblem("run2", ["run", "other"]), undefined)
    // a loose file takes its name
    assert.equal(projectNameProblem("notes.txt", ["notes.txt"]), taken)
    // a bad name is told before it is told to be taken
    assert.equal(projectNameProblem("run.", ["run."]), "must not end with a dot")
})

test("a thousand made-up names are judged", () => {
    // A small deterministic generator (a linear congruence), so the run is repeatable.
    let state = 7
    const next = (n: number) => {
        state = (state * 1103515245 + 12345) % 2147483648
        return state % n
    }
    const alphabet = [..."abcXYZ019_-. /\\:é*"]
    for (let i = 0; i < 1000; i++) {
        const name = Array.from(
            { length: 1 + next(12) },
            () => alphabet[next(alphabet.length)],
        ).join("")
        const problem = projectNameProblem(name, [])
        if (/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(name)) {
            assert.ok(
                problem === undefined ||
                    problem === "must not end with a dot" ||
                    problem === "reserved name, pick another",
                name,
            )
        } else assert.notEqual(problem, undefined, name)
        if (problem !== undefined) assert.ok(problem.length <= 29)
    }
})

test("a broken project folder keeps its name", () => {
    const appRoot = tempDir()
    const root = projectsRoot(appRoot)
    mkdirSync(join(root, "Demo"), { recursive: true })
    writeFileSync(join(root, "Demo", "project.json"), '{"id": "other"}')
    mkdirSync(join(root, "plain"))
    // not listed, but listed as broken; a plain folder is not
    assert.deepEqual(listProjects(root), [])
    assert.deepEqual(brokenNames(root), ["Demo"])
    const existing = entryNames(root)
    const broken = brokenNames(root)
    assert.equal(
        projectNameProblem("demo", existing, broken),
        "that name is taken by a broken project folder!",
    )
    const exists = "that project already exists!"
    assert.equal(projectNameProblem("plain", existing, broken), exists)
    assert.equal(projectNameProblem("demo", existing), "that project already exists!")
    // createProject says it too, and leaves the folder alone
    assert.throws(
        () => createProject(appRoot, "demo", hooksFor(appRoot)),
        (e) =>
            e instanceof InvalidNameError &&
            e.reason === "that name is taken by a broken project folder!",
    )
    const file = join(root, "Demo", "project.json")
    assert.equal(readFileSync(file, "utf-8"), '{"id": "other"}')
})

test("deleteProject removes only a real project folder", () => {
    const app = tempDir()
    const root = projectsRoot(app)
    mkdirSync(root, { recursive: true })
    const make = (name: string, info?: string) => {
        mkdirSync(join(root, name))
        writeFileSync(join(root, name, "keep.txt"), "x")
        if (info !== undefined) writeFileSync(join(root, name, "project.json"), info)
    }
    make("good", JSON.stringify({ id: "good" }))
    make("plain")
    make("broken", "{not json")
    make("wrong", JSON.stringify({ id: "other" }))
    // a link to a valid project outside the projects folder
    const outside = join(app, "outside")
    mkdirSync(outside)
    writeFileSync(join(outside, "project.json"), JSON.stringify({ id: "link" }))
    symlinkSync(outside, join(root, "link"))

    const bads = ["../outside", "a/b", "", "..", ".", "link", "plain", "broken", "wrong"]
    for (const bad of bads)
        assert.throws(() => deleteProject(app, bad), Error, bad)
    assert.ok(existsSync(join(outside, "project.json")))
    for (const kept of ["plain", "broken", "wrong", "good"])
        assert.ok(existsSync(join(root, kept, "keep.txt")), kept)

    deleteProject(app, "good")
    assert.ok(!existsSync(join(root, "good")))
    deleteProject(app, "good") // already gone: no error
    assert.ok(existsSync(join(root, "plain", "keep.txt")))
})

// ========================================================================================
// 3. Models
// ========================================================================================

/** The hints of a typed path for structure files. */
const hints = (text: string) => hintsFor(text, accepted)


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
    const src = tempDir()
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
    const src = tempDir()
    const project = tempDir()
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
    const src = tempDir()
    const project = tempDir()
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
    const project = tempDir()
    file(modelsDir(project), "b.CIF", "x")
    file(modelsDir(project), "A.pdb", "x")
    file(modelsDir(project), "notes.txt", "x")
    mkdirSync(join(project, "models", "dir.pdb"))
    assert.deepEqual(listModels(project), ["A.pdb", "b.CIF"])
})

test("deleting is limited to the models", () => {
    const project = tempDir()
    const outside = file(tempDir(), "keep.pdb", "x")
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
    assert.deepEqual(listModels(tempDir()), [])
})

test("hints and completion", () => {
    const dir = tempDir()
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

// ---- the path prompt (store/lists.ts)

test("pathSuggestions show the name and complete to the whole path", () => {
    const dir = tempDir()
    mkdirSync(join(dir, "sub"))
    writeFileSync(join(dir, "m1.pdb"), "")
    writeFileSync(join(dir, "notes.txt"), "")
    assert.deepEqual(pathSuggestions(`${dir}/`, accepted), [
        { label: "sub/", completion: `${dir}/sub/` },
        { label: "m1.pdb", completion: `${dir}/m1.pdb` },
    ])
    assert.deepEqual(
        pathSuggestions(`${dir}/m`, accepted).map((s) => s.completion),
        [`${dir}/m1.pdb`],
    )
    assert.deepEqual(pathSuggestions("relative", accepted), [])
    assert.deepEqual(pathSuggestions(`${dir}/nope/x`, accepted), [])
})

test("checkPath answers with the wording of its budget, in a fixed order", () => {
    const dir = tempDir()
    const kind = { accept: (n: string) => n.endsWith(".ok"), message: "K" }
    writeFileSync(join(dir, "a.ok"), "")
    writeFileSync(join(dir, "a.no"), "")
    for (const budget of [22, 42] as const) {
        const empty =
            budget === 42
                ? "type the full path of a model file first!"
                : "type a path first!"
        assert.equal(checkPath(" ", budget), empty)
        assert.equal(checkPath(join(dir, "none.ok"), budget), "no such file")
        assert.equal(checkPath(join(dir, "a.no"), budget, kind), "K")
        assert.equal(checkPath(join(dir, "a.no"), budget), undefined)
        assert.equal(checkPath(join(dir, "a.ok"), budget, kind), undefined)
    }
    assert.equal(checkPath("a.ok", 22), "use a full path")
    assert.equal(checkPath("a.ok", 42), "use a full absolute path")
    assert.equal(checkPath(dir, 22), "that is a folder")
    assert.equal(checkPath(dir, 42), "that is a folder, not a file")
})

test("a path that is not absolute or not in a folder has no suggestions", () => {
    assert.deepEqual(pathSuggestions("relative/path", () => true), [])
    assert.deepEqual(pathSuggestions("/no/such/folder/ab", () => true), [])
})

// ---- the notes of the models screen

test("pickNote tells copied and skipped files", () => {
    assert.equal(pickNote({ copied: [], skipped: [] }), "nothing was picked")
    assert.equal(pickNote({ copied: ["a.pdb"], skipped: [] }), "copied a.pdb")
    assert.equal(pickNote({ copied: ["a.pdb", "b.cif"], skipped: [] }), "copied 2 files")
    assert.equal(
        pickNote({
            copied: ["a.pdb"],
            skipped: [["/x/b.txt", "only .cif and .pdb files"]],
        }),
        "copied a.pdb, skipped 1: only .cif and .pdb files",
    )
    assert.equal(
        pickNote({ copied: [], skipped: [["/x/b.txt", "no such file"], ["/y", "z"]] }),
        "skipped 2: no such file",
    )
})

test("the deletion question names the model and warns", () => {
    const q = destructiveQuestion("model a.pdb").text
    assert.match(q, /^delete model a\.pdb\?/)
    assert.match(q, /cannot be undone/)
    assert.equal(q, "delete model a.pdb? this cannot be undone!")
    // a long name is cut (from its start), never the kind or the warning behind it
    assert.equal(
        destructiveQuestion("model SASDCQ2_fit3_model1").text,
        "delete model SASDCQ2_fit3_model1? this cannot be undone!",
    )
    const long = destructiveQuestion(`model ${"x".repeat(80)}`).text
    assert.ok(long.endsWith("? this cannot be undone!"))
    assert.ok(long.includes("…"))
    assert.ok(long.startsWith("delete model …x"))
    assert.ok(long.length <= 58)
})
