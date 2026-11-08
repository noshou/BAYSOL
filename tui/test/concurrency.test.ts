// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { type ChildProcess, spawn } from "node:child_process"
import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    rmSync,
    utimesSync,
    writeFileSync,
} from "node:fs"
import { hostname } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import {
    ChangedOnDiskError,
    FileInUseError,
    noteRead,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../src/core/file-system.js"
import {
    type BufferRow,
    bufferFile,
    readRecipes,
    readSolutes,
    recipesFile,
    removeRecipe,
    renameRecipe,
    saveRecipe,
    writeRecipes,
    writeSolutes,
} from "../src/store/buffer.js"
import { readCustomSolutes, writeCustomSolutes } from "../src/store/custom.js"
import {
    addModel,
    deleteProject,
    isoStamp,
    listModels,
    liveRun,
    markStaleRuns,
    ProjectGoneError,
    RunInProgressError,
    runStatus,
} from "../src/store/projects.js"
import { claimRun } from "../src/store/run.js"
import { defaultCatalog } from "../src/store/settings.js"
import { loadGlobal, loadProject, settingsFile } from "../src/store/settings-store.js"
import { fixture, tempDir as tmp } from "./support/fixtures.js"

const worker = fileURLToPath(new URL("./support/lock-worker.ts", import.meta.url))

/** Runs the worker as a child process; resolves with its exit code. */
function runWorker(file: string, cycles: number): Promise<number | null> {
    return new Promise((resolve, reject) => {
        const args = ["--import", "tsx", worker, file, String(cycles)]
        const child = spawn(process.execPath, args, { stdio: "inherit" })
        child.on("error", reject)
        child.on("exit", resolve)
    })
}

// ---- the lock ----------------------------------------------------------------------

test("four real processes counting under the lock lose no update", async () => {
    const file = join(tmp(), "counter.txt")
    writeFileSync(file, "0")
    const codes = await Promise.all([1, 2, 3, 4].map(() => runWorker(file, 25)))
    assert.deepEqual(codes, [0, 0, 0, 0])
    assert.equal(readFileSync(file, "utf-8"), "100")
    assert.equal(existsSync(`${file}.lock`), false, "every lock was released")
})

test("the lock is released when the work throws, and the result is returned", () => {
    const file = join(tmp(), "x.json")
    assert.throws(
        () =>
            withFileLock(file, () => {
                throw new Error("boom")
            }),
        /boom/,
    )
    assert.equal(
        withFileLock(file, () => 7),
        7,
    )
})

test("a stale lock is broken", () => {
    const file = join(tmp(), "x.json")
    mkdirSync(`${file}.lock`)
    const old = new Date(Date.now() - 60_000)
    utimesSync(`${file}.lock`, old, old)
    assert.equal(
        withFileLock(file, () => "got it"),
        "got it",
    )
})

test("a lock held by another copy times out with a clear error", () => {
    const file = join(tmp(), "settings.json")
    mkdirSync(`${file}.lock`) // fresh: its owner is alive
    const t0 = Date.now()
    assert.throws(
        () => withFileLock(file, () => undefined),
        (e) =>
            e instanceof FileInUseError &&
            e.message === "settings.json is in use by another copy",
    )
    assert.ok(Date.now() - t0 >= 2900, "it waited about 3 s")
})

// ---- settings of two copies --------------------------------------------------------

const saved = (dir: string): Record<string, unknown> => {
    const out: Record<string, unknown> = {}
    const file = JSON.parse(readFileSync(settingsFile(dir), "utf-8")) as Record<
        string,
        Record<string, { value: unknown }>
    >
    for (const sheet of Object.values(file))
        for (const [name, entry] of Object.entries(sheet)) out[name] = entry.value
    return out
}

test("two copies changing different settings both survive", () => {
    const dir = tmp()
    const a = loadGlobal(dir).settings
    const b = loadGlobal(dir).settings
    assert.equal(a.set({ N_ADAPT: 450 }).ok, true)
    assert.equal(b.set({ N_DRAWS: 900 }).ok, true)
    a.save()
    b.save()
    assert.deepEqual(saved(dir), { N_ADAPT: 450, N_DRAWS: 900 })
    assert.equal(b.get("N_ADAPT"), 450, "the saving copy takes over what was written")
    assert.equal(loadGlobal(dir).settings.get("N_DRAWS"), 900)
})

test("for the same setting the last save wins, and a reset is a change too", () => {
    const dir = tmp()
    const a = loadGlobal(dir).settings
    const b = loadGlobal(dir).settings
    a.set({ N_ADAPT: 450, N_DRAWS: 900 })
    b.set({ N_ADAPT: 500 })
    a.save()
    b.save()
    assert.deepEqual(saved(dir), { N_ADAPT: 500, N_DRAWS: 900 })
    const c = loadGlobal(dir).settings
    c.reset(["N_DRAWS"])
    c.save()
    assert.deepEqual(saved(dir), { N_ADAPT: 500 })
})

test("project settings of two copies merge the same way", () => {
    const root = tmp()
    const p = join(root, "projects", "p")
    mkdirSync(p, { recursive: true })
    const a = loadProject(p, root).settings
    const b = loadProject(p, root).settings
    a.set({ N_ADAPT: 450 })
    b.set({ N_CHAINS: 3 })
    a.save()
    b.save()
    assert.deepEqual(saved(p), { N_ADAPT: 450, N_CHAINS: 3 })
})

test("a garbled file is kept aside, never silently written over", () => {
    const dir = tmp()
    const a = loadGlobal(dir).settings
    a.set({ N_ADAPT: 450 })
    writeFileSync(settingsFile(dir), "{ garbled")
    a.save()
    assert.equal(readFileSync(`${settingsFile(dir)}.corrupt`, "utf-8"), "{ garbled")
    assert.deepEqual(saved(dir), { N_ADAPT: 450 })
})

test("the first load does not clobber a file that appeared meanwhile", () => {
    const dir = tmp()
    // The other copy made its file first; a load under the lock finds it.
    writeFileSync(settingsFile(dir), writeJson({ sampler: { N_ADAPT: { value: 450 } } }))
    const r = loadGlobal(dir)
    assert.equal(r.settings.get("N_ADAPT"), 450)
    assert.deepEqual(saved(dir), { N_ADAPT: 450 })
})

test("a save wipes a conflicting value from the other copy as a load does", () => {
    const dir = tmp()
    const a = loadGlobal(dir).settings
    a.set({ N_ADAPT: 450 })
    writeFileSync(
        settingsFile(dir),
        writeJson({ sampler: { N_ADAPT: { value: 450 }, N_DRAWS: { value: -5 } } }),
    )
    a.save()
    assert.deepEqual(saved(dir), { N_ADAPT: 450 })
    assert.equal(defaultCatalog().require("N_DRAWS").default, a.get("N_DRAWS"))
})

// ---- list files --------------------------------------------------------------------

const row = (fixture("buffer/buffer.json").solutes as BufferRow[])[0] as BufferRow

test("a second writer is refused when another copy saved after it read", () => {
    const dir = tmp()
    writeSolutes(dir, [row]) // this copy wrote and so knows the file
    // The other copy saves a different buffer, as a separate process would.
    const theirs = writeJson({ solutes: [row, row] })
    writeAtomic(bufferFile(dir), theirs)
    assert.throws(
        () => writeSolutes(dir, []),
        (e) =>
            e instanceof ChangedOnDiskError &&
            e.message ===
                "buffer.json changed on disk: another copy of BAYSOL saved it; reopen it",
    )
    assert.equal(readFileSync(bufferFile(dir), "utf-8"), theirs, "their file is intact")
    // After the reopen (a read) the write goes through.
    assert.equal(readSolutes(dir, { track: true }).length, 2)
    writeSolutes(dir, [row])
    assert.equal(readSolutes(dir).length, 1)
})

test("same content saved again is no change; a copy that never read may write", () => {
    const dir = tmp()
    writeSolutes(dir, [row])
    writeAtomic(bufferFile(dir), readFileSync(bufferFile(dir), "utf-8"))
    writeSolutes(dir, [row, row])
    const other = tmp()
    writeAtomic(bufferFile(other), writeJson({ solutes: [row] }))
    writeSolutes(other, []) // never read this folder in this process
    assert.deepEqual(readSolutes(other), [])
})

test("a file that appeared after this copy found none is a change", () => {
    const root = tmp()
    assert.deepEqual(readCustomSolutes(root, { track: true }), [])
    writeAtomic(join(root, "custom-solutes.json"), writeJson({ solutes: [] }))
    assert.throws(() => writeCustomSolutes(root, []), ChangedOnDiskError)
})

test("a plain read never moves the base, a tracked read does", () => {
    const dir = tmp()
    writeSolutes(dir, [row]) // baseline: one row
    readSolutes(dir, { track: true })
    const theirs = writeJson({ solutes: [row, row] })
    writeAtomic(bufferFile(dir), theirs) // the other copy saves
    readSolutes(dir) // an unrelated plain read must not accept their save as current
    assert.throws(() => writeSolutes(dir, [row, row, row]), ChangedOnDiskError)
    assert.equal(readFileSync(bufferFile(dir), "utf-8"), theirs, "their file is intact")
    readSolutes(dir, { track: true }) // reopened: the base moves
    writeSolutes(dir, [row, row, row])
    assert.equal(readSolutes(dir).length, 3)
})

test("a plain read alone never makes a later save throw", () => {
    const dir = tmp()
    writeAtomic(bufferFile(dir), writeJson({ solutes: [row] }))
    readSolutes(dir) // never tracked
    writeAtomic(bufferFile(dir), writeJson({ solutes: [row, row] }))
    readSolutes(dir)
    writeSolutes(dir, [])
    assert.deepEqual(readSolutes(dir), [])
})

test("the same holds for custom solutes", () => {
    const root = tmp()
    writeCustomSolutes(root, [])
    readCustomSolutes(root, { track: true })
    writeAtomic(join(root, "custom-solutes.json"), writeJson({ solutes: [], by: "b" }))
    readCustomSolutes(root)
    assert.throws(() => writeCustomSolutes(root, []), ChangedOnDiskError)
})

test("noteRead of a missing file is a version too", () => {
    const dir = tmp()
    noteRead(bufferFile(dir))
    writeAtomic(bufferFile(dir), writeJson({ solutes: [] }))
    assert.throws(() => writeSolutes(dir, []), ChangedOnDiskError)
})

// ---- a deleted project is not made again -----------------------------------------------

test("writes into a project that was deleted are refused and make nothing", () => {
    const root = tmp()
    const p = join(root, "projects", "gone")
    mkdirSync(p, { recursive: true })
    const settings = loadProject(p, root).settings
    settings.set({ N_ADAPT: 450 })
    const src = join(tmp(), "m.pdb")
    writeFileSync(src, "x")
    readSolutes(p, { track: true })
    rmSync(p, { recursive: true })
    const gone = (e: unknown): boolean =>
        e instanceof ProjectGoneError && e.message === "project gone no longer exists"
    assert.throws(() => writeSolutes(p, [row]), gone)
    assert.throws(() => settings.save(), gone)
    assert.throws(() => addModel(p, src), gone)
    assert.throws(() => loadProject(p, root), gone)
    assert.equal(existsSync(p), false, "the folder was not made again")
})

test("the global files still make the data folder", () => {
    const dir = join(tmp(), "baysol-data")
    loadGlobal(dir).settings.set({ N_ADAPT: 450 })
    assert.equal(existsSync(settingsFile(dir)), true)
    writeCustomSolutes(join(dir, "sub"), [])
    assert.equal(existsSync(join(dir, "sub", "custom-solutes.json")), true)
})

// ---- creating things that must be new -------------------------------------------------

test("a model name taken meanwhile is refused by the copy itself", () => {
    const project = tmp()
    const src = tmp()
    mkdirSync(join(src, "a"))
    mkdirSync(join(src, "b"))
    writeFileSync(join(src, "a", "m.pdb"), "first")
    writeFileSync(join(src, "b", "m.pdb"), "second")
    addModel(project, join(src, "a", "m.pdb"))
    assert.throws(() => addModel(project, join(src, "b", "m.pdb")), /EEXIST/)
    assert.equal(readFileSync(join(project, "models", "m.pdb"), "utf-8"), "first")
    assert.deepEqual(listModels(project), ["m.pdb"])
})

// ---- runs: real processes ---------------------------------------------------------------

const here = (name: string): string =>
    fileURLToPath(new URL(`./support/${name}`, import.meta.url))

/** A child process running a support script under tsx, its output collected by line. */
function spawnSupport(script: string, args: string[], env: Record<string, string> = {}) {
    const child = spawn(process.execPath, ["--import", "tsx", here(script), ...args], {
        detached: true,
        stdio: ["ignore", "pipe", "inherit"],
        env: { ...process.env, ...env },
    })
    const lines: string[] = []
    let waiting: ((line: string) => void) | undefined
    child.stdout?.setEncoding("utf-8")
    child.stdout?.on("data", (text: string) => {
        for (const line of text.split("\n").filter(Boolean)) {
            if (waiting) {
                const done = waiting
                waiting = undefined
                done(line)
            } else lines.push(line)
        }
    })
    const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()))
    return {
        child,
        exited,
        /** The next line the worker prints. */
        next: (): Promise<string> => {
            const ready = lines.shift()
            if (ready !== undefined) return Promise.resolve(ready)
            return new Promise((resolve) => {
                waiting = resolve
            })
        },
        /** Ends the worker's whole process group. */
        kill: (signal: NodeJS.Signals = "SIGKILL") => {
            try {
                process.kill(-(child.pid as number), signal)
            } catch {
                // already gone
            }
        },
    }
}

/** A project folder with a project.json, as the project list reads it. */
function runProject(root: string, id: string): string {
    const dir = join(root, "projects", id)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, "project.json"), writeJson({ id, created: "x" }))
    writeFileSync(join(dir, "buffer.json"), '{"solutes": []}\n')
    return dir
}

test("three real processes claiming a run in one project: exactly one wins", async () => {
    const project = runProject(tmp(), "p")
    const gate = join(tmp(), "gate")
    const workers = [1, 2, 3].map(() => spawnSupport("claim-worker.ts", [project, gate]))
    try {
        await new Promise((r) => setTimeout(r, 1500)) // all three wait at the gate
        writeFileSync(gate, "go")
        const answers = await Promise.all(workers.map((w) => w.next()))
        const won = answers.filter((a) => a.startsWith("won "))
        assert.equal(won.length, 1, answers.join(" | "))
        const winner = workers[answers.findIndex((a) => a.startsWith("won "))]
        for (const a of answers.filter((a) => !a.startsWith("won ")))
            assert.equal(a, `refused a run is in progress (pid ${winner?.child.pid})`)
        const folders = readdirSync(join(project, "runs")).filter((n) => !n.startsWith("."))
        assert.equal(folders.length, 1)
        // the winner dies (its Julia never came): its folder is no longer live
        winner?.kill()
        await winner?.exited
        assert.equal(liveRun(project), undefined)
        assert.ok(claimRun(project).id)
    } finally {
        for (const w of workers) w.kill()
    }
})

test("a killed child becomes interrupted; a live one is never touched", async () => {
    const project = runProject(tmp(), "p")
    const run = join(project, "runs", "20260101T000000Z")
    mkdirSync(run, { recursive: true })
    const julia = spawnSupport("fake-julia.ts", [project, "20", run], { FAKE_MODE: "hang" })
    try {
        assert.equal(await julia.next(), "fake julia started")
        assert.equal(runStatus(project, "20260101T000000Z"), "running")
        assert.equal(liveRun(project)?.pid, julia.child.pid)
        assert.deepEqual(markStaleRuns(project), [], "it lives: left alone")
        julia.kill("SIGKILL") // no chance to say goodbye
        await julia.exited
        assert.equal(runStatus(project, "20260101T000000Z"), "running", "file not told")
        assert.equal(liveRun(project), undefined, "the pid is gone, the heartbeat is fresh")
        assert.deepEqual(markStaleRuns(project), ["20260101T000000Z"])
        assert.equal(runStatus(project, "20260101T000000Z"), "interrupted")
    } finally {
        julia.kill()
    }
})

test("a project cannot be deleted while a run is live, and can when not", async () => {
    const root = tmp()
    const project = runProject(root, "p")
    const run = join(project, "runs", "20260101T000000Z")
    mkdirSync(run, { recursive: true })
    const julia: ChildProcess = spawn("sleep", ["300"], { detached: true, stdio: "ignore" })
    try {
        writeFileSync(
            join(run, "run.json"),
            writeJson({
                status: "running",
                pid: julia.pid,
                host: hostname(),
                heartbeat: isoStamp(Date.now()),
            }),
        )
        assert.throws(
            () => deleteProject(root, "p"),
            (e: Error) =>
                e instanceof RunInProgressError &&
                e.message === `a run is in progress (pid ${julia.pid})`,
        )
        assert.equal(existsSync(project), true, "nothing was deleted")
        process.kill(julia.pid as number, "SIGKILL")
        await new Promise((r) => julia.once("exit", r))
        deleteProject(root, "p")
        assert.equal(existsSync(project), false)
    } finally {
        julia.kill("SIGKILL")
    }
})

test("recipe operations that read and write in one step never conflict", () => {
    const root = tmp()
    saveRecipe(root, "A", [row])
    readRecipes(root)
    // another copy adds a recipe
    writeAtomic(
        recipesFile(root),
        writeJson({ recipes: [...readRecipes(root), { name: "B", solutes: [row] }] }),
    )
    saveRecipe(root, "C", [row]) // reads again under the lock: B is kept
    assert.deepEqual(
        readRecipes(root).map((r) => r.name),
        ["A", "B", "C"],
    )
    writeAtomic(
        recipesFile(root),
        writeJson({ recipes: [...readRecipes(root), { name: "D", solutes: [] }] }),
    )
    assert.equal(renameRecipe(root, "A", "AA"), undefined)
    writeAtomic(
        recipesFile(root),
        writeJson({ recipes: [...readRecipes(root), { name: "E", solutes: [] }] }),
    )
    assert.equal(removeRecipe(root, "B"), true)
    assert.deepEqual(
        readRecipes(root).map((r) => r.name),
        ["AA", "C", "D", "E"],
    )
    writeAtomic(recipesFile(root), writeJson({ recipes: [] }))
    assert.throws(() => writeRecipes(root, []), ChangedOnDiskError)
})

test("the same holds for recipes", () => {
    const root = tmp()
    saveRecipe(root, "A", [row])
    readRecipes(root, { track: true })
    writeAtomic(recipesFile(root), writeJson({ recipes: [] }))
    readRecipes(root)
    assert.throws(() => writeRecipes(root, readRecipes(root)), ChangedOnDiskError)
    readRecipes(root, { track: true })
    writeRecipes(root, [])
})
