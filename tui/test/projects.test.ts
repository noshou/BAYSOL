// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import {
    copyFileSync,
    existsSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { projectsRoot } from "../src/core/paths.js"
import {
    brokenNames,
    createProject,
    entryNames,
    InvalidNameError,
    listProjects,
    nameProblem,
    readProject,
} from "../src/store/projects.js"

const tempRoot = () => mkdtempSync(join(tmpdir(), "baysol-test-"))

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
    const root = tempRoot()
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
    const nowhere = join(tempRoot(), "nowhere")
    assert.deepEqual(listProjects(nowhere), [])
    assert.deepEqual(entryNames(nowhere), [])
})

test("making a project", () => {
    const appRoot = tempRoot()
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
    const appRoot = tempRoot()
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
    const appRoot = tempRoot()
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
    assert.equal(nameProblem("broken", entryNames(projectsRoot(appRoot))), undefined)
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
    for (const n of good) assert.equal(nameProblem(n, []), undefined, n)
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
        assert.equal(nameProblem(name, []), message, JSON.stringify(name))
        assert.ok(message.length <= 29, "the message fits the main menu")
    }
})

test("a name that is taken is refused whatever its case", () => {
    const taken = "that project already exists!"
    assert.equal(nameProblem("run", ["run"]), taken)
    assert.equal(nameProblem("Run", ["run"]), taken)
    assert.equal(nameProblem("RUN", ["Run", "other"]), taken)
    assert.equal(nameProblem("run2", ["run", "other"]), undefined)
    // a loose file takes its name
    assert.equal(nameProblem("notes.txt", ["notes.txt"]), taken)
    // a bad name is told before it is told to be taken
    assert.equal(nameProblem("run.", ["run."]), "must not end with a dot")
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
        const problem = nameProblem(name, [])
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
    const appRoot = tempRoot()
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
        nameProblem("demo", existing, broken),
        "that name is taken by a broken project folder!",
    )
    assert.equal(nameProblem("plain", existing, broken), "that project already exists!")
    assert.equal(nameProblem("demo", existing), "that project already exists!")
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
