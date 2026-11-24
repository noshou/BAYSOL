// SPDX-License-Identifier: LGPL-3.0-or-later

// The single source of the operating system (`core/environment.ts`): the predicates and
// the executable name.

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    cacheFolder,
    defaultCache,
    defaultStructureCache,
    exeName,
    isLinux,
    isMac,
    isWindows,
    readSystem,
    type System,
    structureCache,
    tmpFolder,
    tmpProcessFolder,
} from "../src/core/environment.js"

const on = (os: NodeJS.Platform): System => ({ os, env: {}, home: "/home/u", cwd: "/" })

test("exactly one predicate holds for each known platform", () => {
    for (const os of ["win32", "darwin", "linux"] as const) {
        const flags = [isWindows(on(os)), isMac(on(os)), isLinux(on(os))]
        assert.equal(flags.filter(Boolean).length, 1)
    }
})

test("the executable name has .exe only on Windows", () => {
    assert.equal(exeName(on("win32"), "baysol"), "baysol.exe")
    assert.equal(exeName(on("linux"), "baysol"), "baysol")
    assert.equal(exeName(on("darwin"), "baysol"), "baysol")
})

test("readSystem reports this machine", () => {
    assert.equal(readSystem().os, process.platform)
})

// The same table is pinned by `test/unit-tests/units/test-platform.jl`
// (`Platform.cache_dir` and friends): change both together, or the two
// implementations have drifted.
const CACHE_CASES: [NodeJS.Platform, Record<string, string>, string][] = [
    ["win32", {}, "/h/u/AppData/Local/baysol-cache"],
    ["win32", { LOCALAPPDATA: "/d/local" }, "/d/local/baysol-cache"],
    ["win32", { LOCALAPPDATA: "rel" }, "/h/u/AppData/Local/baysol-cache"],
    ["darwin", {}, "/h/u/Library/Caches/baysol"],
    ["linux", {}, "/h/u/.cache/baysol"],
    ["linux", { XDG_CACHE_HOME: "/x/cache" }, "/x/cache/baysol"],
    [
        "linux",
        { XDG_CACHE_HOME: "/x/data", XDG_DATA_HOME: "/x/data" },
        "/x/data/baysol-cache",
    ],
]

const slashes = (p: string): string => p.replaceAll("\\", "/")

test("the caches folder and its two caches are the ones the Julia side pins", () => {
    for (const [os, env, folder] of CACHE_CASES) {
        const system: System = { os, env, home: "/h/u", cwd: "/" }
        assert.equal(slashes(cacheFolder(system)), folder, `${os} ${JSON.stringify(env)}`)
        assert.equal(slashes(defaultCache(system)), `${folder}/_cache`)
        assert.equal(slashes(defaultStructureCache(system)), `${folder}/_structures`)
        assert.equal(slashes(structureCache(system)), `${folder}/_structures`)
    }
})

test("BAYSOL_CACHE names the structure cache only as an absolute path", () => {
    const base = { os: "linux", home: "/h/u", cwd: "/" } as const
    assert.equal(
        slashes(structureCache({ ...base, env: { BAYSOL_CACHE: "/b/c" } })),
        "/b/c",
    )
    assert.equal(
        slashes(structureCache({ ...base, env: { BAYSOL_CACHE: "rel" } })),
        "/h/u/.cache/baysol/_structures",
    )
    assert.equal(
        slashes(defaultCache({ ...base, env: { BAYSOL_CACHE: "/b/c" } })),
        "/h/u/.cache/baysol/_cache",
    )
})

// Pinned the same way by `Platform.tmp_dir` and `Platform.tmp_process_dir` in
// `test/unit-tests/units/test-platform.jl`: one `baysol` entry in the temporary folder,
// one folder per pid below it.
test("the temporary root is one baysol folder with one folder per process", () => {
    assert.equal(slashes(tmpFolder("/t")), "/t/baysol")
    assert.equal(slashes(tmpProcessFolder(4242, "/t")), "/t/baysol/4242")
    assert.equal(slashes(tmpFolder("/var/folders/x/T")), "/var/folders/x/T/baysol")
})
