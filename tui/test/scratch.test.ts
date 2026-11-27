// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of core/scratch.ts: where the temporary files are, the sweeps at start, the exit
// hook, the periodic maintenance. Folders are made for the test (an injected base), and the
// real exit paths run in a child process (test/support/scratch-worker.ts) whose temporary
// folder the test points at its own.

import assert from "node:assert/strict"
import { type ChildProcess, spawn, spawnSync } from "node:child_process"
import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    utimesSync,
    writeFileSync,
} from "node:fs"
import { dirname, join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import { tmpFolder, tmpProcessFolder } from "../src/core/environment.js"
import {
    maintainScratch,
    pidAlive,
    processFolder,
    removeProcessFolder,
    SCRATCH_POLICY,
    scratchFolder,
    scratchTemp,
    startMaintenance,
    startScratch,
    sweepDeadFolders,
    sweepLegacy,
    withScratch,
} from "../src/core/scratch.js"
import { tempDir } from "./support/fixtures.js"

const worker = fileURLToPath(new URL("./support/scratch-worker.ts", import.meta.url))

/** Makes `<root>/<name>/<file>` and ages it by `age` seconds. */
function make(root: string, name: string, file = "f", age = 0): string {
    const dir = join(root, name)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, file), "x")
    const time = new Date(Date.now() - age * 1000)
    utimesSync(join(dir, file), time, time)
    utimesSync(dir, time, time)
    return dir
}

// ---- where ---------------------------------------------------------------------------

test("the temporary root is one baysol folder, one folder per pid, one per purpose", () => {
    assert.equal(tmpFolder(), join(dirname(tmpFolder()), "baysol"))
    const mine = tmpProcessFolder(process.pid)
    assert.equal(dirname(mine), tmpFolder())
    const view = scratchFolder("view")
    assert.equal(view, join(mine, "view"))
    assert.ok(existsSync(view))
    const temp = scratchTemp("pack")
    assert.equal(dirname(dirname(temp)), mine)
    removeProcessFolder(tmpFolder(), process.pid)
    assert.equal(existsSync(mine), false)
    assert.equal(processFolder("/r", 7).replaceAll("\\", "/"), "/r/7")
})

test("withScratch removes its folder after success and after a failure", async () => {
    let seen = ""
    await withScratch("t", async (folder) => {
        seen = folder
        writeFileSync(join(folder, "x"), "1")
    })
    assert.equal(existsSync(seen), false)
    await assert.rejects(
        withScratch("t", async (folder) => {
            seen = folder
            throw new Error("boom")
        }),
        /boom/,
    )
    assert.equal(existsSync(seen), false)
    removeProcessFolder(tmpFolder(), process.pid)
})

test("nothing in src asks for the system's temporary folder but environment.ts", () => {
    const src = fileURLToPath(new URL("../src", import.meta.url))
    const found: string[] = []
    const walk = (dir: string): void => {
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
            const path = join(dir, entry.name)
            if (entry.isDirectory()) walk(path)
            else if (
                /\.(ts|tsx)$/.test(entry.name) &&
                /\btmpdir\(|mkdtemp(?!Sync\(join\(scratchFolder)/.test(
                    readFileSync(path, "utf-8"),
                )
            )
                found.push(path.slice(src.length + 1).replaceAll("\\", "/"))
        }
    }
    walk(src)
    // environment.ts defines the root; scratch.ts makes the folders inside it
    assert.deepEqual(found.sort(), ["core/environment.ts", "core/scratch.ts"])
})

// ---- sweeps at start -----------------------------------------------------------------

test("the sweep removes only the folders of dead pids", () => {
    const root = tempDir()
    const dead = make(root, "111", "book.xlsx")
    make(root, "222")
    make(root, "333")
    for (const other of ["abc", "12x", "0", "111-x", "baysol-111"]) {
        mkdirSync(join(root, other))
    }
    writeFileSync(join(root, "444"), "a file")
    const removed = sweepDeadFolders(root, 333, (pid) => pid === 222)
    assert.deepEqual(removed, ["111"])
    assert.equal(existsSync(dead), false)
    for (const kept of ["222", "333", "abc", "12x", "0", "111-x", "baysol-111", "444"])
        assert.ok(existsSync(join(root, kept)), kept)
    assert.deepEqual(sweepDeadFolders(join(root, "nope"), 1), [])
})

test("pidAlive: this process is alive", () => {
    assert.equal(pidAlive(process.pid), true)
})

test(
    "the legacy sweep removes our old names only, old ones only, never a live pid's",
    () => {
        const base = tempDir()
        const now = Date.now()
        const day = 24 * 3600
        const gone = [
            make(base, "baysol-111"),
            make(base, "baysol-book-aB3dE9", "f", 2 * day),
            make(base, "baysol-pack-aB3dE9", "f", 2 * day),
            make(base, "baysol-run-aB3dE9", "f", 2 * day),
            make(base, "baysol-add-aB3dE9", "f", 2 * day),
            make(base, "baysol-sixel-aB3dE9", "f", 2 * day),
            make(base, "baysol-move-aB3dE9", "f", 2 * day),
        ]
        const kept = [
            make(base, "baysol-222"), // alive
            make(base, "baysol-book-zzzzzz"), // fresh
            make(base, "baysol-other-aB3dE9", "f", 2 * day), // not ours
            make(base, "baysol-pack-short", "f", 2 * day),
            make(base, "baysol", "f", 2 * day), // the new root
            make(base, "unrelated", "f", 2 * day),
        ]
        const removed = sweepLegacy(base, (pid) => pid === 222, now)
        assert.equal(removed.length, gone.length)
        for (const path of gone) assert.equal(existsSync(path), false, path)
        for (const path of kept) assert.ok(existsSync(path), path)
    },
)

test(
    "startScratch sweeps dead pids, cleans the legacy names once, hooks the exit once",
    () => {
        const base = tempDir()
        const root = join(base, "baysol")
        const old = make(base, "baysol-book-aB3dE9", "f", 2 * 24 * 3600)
        const dead = make(root, "999999")
        const live = make(root, "888888")
        const before = process.listenerCount("exit")
        assert.equal(startScratch(root, base, (pid) => pid === 888888), root)
        assert.equal(
            process.listenerCount("exit"),
            before + 1,
            "the exit hook is registered",
        )
        startScratch(root, base, (pid) => pid === 888888)
        assert.equal(process.listenerCount("exit"), before + 1, "once, not again")
        assert.equal(existsSync(dead), false)
        assert.ok(existsSync(live))
        assert.equal(existsSync(old), false)
        // the legacy cleanup is one-time: a new old leftover stays now
        const again = make(base, "baysol-pack-aB3dE9", "f", 2 * 24 * 3600)
        startScratch(root, base, (pid) => pid === 888888)
        assert.ok(existsSync(again))
        // a base that is not there does not stop the program starting
        assert.doesNotThrow(() =>
            startScratch(join(base, "no", "such"), join(base, "nope")),
        )
    },
)

// ---- the exit paths, in a real process ------------------------------------------------

type Child = {
    child: ChildProcess
    folder: string
    exited: Promise<void>
    kill: () => void
}

/**
 * Starts the worker with `base` as its temporary folder; resolves when it made its file.
 */
function start(base: string, how: string): Promise<Child> {
    const env = { ...process.env, TMPDIR: base, TEMP: base, TMP: base }
    const child = spawn(process.execPath, ["--import", "tsx", worker, how], {
        env,
        stdio: ["ignore", "pipe", "ignore"],
    })
    const exited = new Promise<void>((resolve) => child.on("exit", () => resolve()))
    const kill = (): void => {
        // Windows has no signals that run handlers, and no process groups: end it by pid
        if (process.platform === "win32")
            spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], {
                windowsHide: true,
            })
        else child.kill("SIGKILL")
    }
    return new Promise((resolve, reject) => {
        let text = ""
        child.on("error", reject)
        child.stdout?.on("data", (chunk: Buffer) => {
            text += chunk.toString()
            if (text.includes("\n"))
                resolve({
                    child,
                    folder: (text.split("\n")[0] as string).trim(),
                    exited,
                    kill,
                })
        })
        child.on("exit", () => reject(new Error(`exited early: ${text}`)))
    })
}

for (const how of ["exit", "throw", "reject"]) {
    test(`the process folder is removed when the program leaves by ${how}`, async () => {
        const base = tempDir()
        const run = await start(base, how)
        assert.equal(dirname(dirname(run.folder)), join(base, "baysol"))
        await run.exited
        assert.equal(existsSync(dirname(run.folder)), false)
    })
}

for (const signal of ["SIGTERM", "SIGHUP"] as const) {
    test(
        `the process folder is removed on ${signal}`,
        {
            skip: process.platform === "win32" && "Windows has no signal handlers",
        },
        async () => {
            const base = tempDir()
            const run = await start(base, "wait")
            assert.ok(existsSync(run.folder))
            run.child.kill(signal)
            await run.exited
            assert.equal(existsSync(dirname(run.folder)), false)
        },
    )
}

test("a killed program leaves its folder; the next start sweeps it", async () => {
    const base = tempDir()
    const run = await start(base, "wait")
    const mine = dirname(run.folder)
    run.kill()
    await run.exited
    assert.ok(existsSync(mine), "no hook ran")
    sweepDeadFolders(join(base, "baysol"), process.pid)
    assert.equal(existsSync(mine), false)
})

// ---- maintenance -----------------------------------------------------------------------

test("maintenance removes what sat idle, keeps what is fresh and a run's folders", () => {
    const folder = tempDir()
    const hour = 3600
    make(join(folder, "view"), "old", "f", 2 * hour)
    make(join(folder, "view"), "new", "f", 10)
    make(join(folder, "pack"), "stray", "f", 3 * hour)
    make(join(folder, "run-models"), "k", "f", 5 * hour)
    make(join(folder, "run-cache"), "k", "f", 5 * hour)
    const removed = maintainScratch(folder).sort()
    assert.deepEqual(removed, ["pack/stray", "view/old"])
    assert.ok(existsSync(join(folder, "view", "new")))
    assert.ok(existsSync(join(folder, "run-models", "k")))
    assert.ok(existsSync(join(folder, "run-cache", "k")))
    assert.deepEqual(maintainScratch(join(folder, "none")), [])
})

test(
    "maintenance evicts the least recently used over the cap, never a run's models",
    () => {
        const folder = tempDir()
        const policy = { ...SCRATCH_POLICY, capBytes: 20 }
        const put = (purpose: string, name: string, bytes: number, age: number): void => {
            const dir = join(folder, purpose, name)
            mkdirSync(dir, { recursive: true })
            writeFileSync(join(dir, "f"), Buffer.alloc(bytes))
            const t = new Date(Date.now() - age * 1000)
            utimesSync(join(dir, "f"), t, t)
            utimesSync(dir, t, t)
        }
        put("run-models", "k", 15, 900) // oldest, but a running fit's
        put("view", "a", 10, 300)
        put("view", "b", 10, 200)
        put("sixel", "c", 10, 100)
        // 45 bytes against 20: a goes (35), b goes (25), c goes (15); models stay
        assert.deepEqual(maintainScratch(folder, policy), ["view/a", "view/b", "sixel/c"])
        assert.ok(existsSync(join(folder, "run-models", "k")))
        // the injected clock decides idleness
        put("view", "d", 1, 0)
        const later = Date.now() + 2 * SCRATCH_POLICY.idleMs
        assert.deepEqual(maintainScratch(folder, SCRATCH_POLICY, later), ["view/d"])
    },
)

test("the periodic timer does not keep the program alive", () => {
    const timer = startMaintenance(tempDir(), { ...SCRATCH_POLICY, maintainEveryMs: 1000 })
    assert.equal(timer.hasRef(), false)
    clearInterval(timer)
})
