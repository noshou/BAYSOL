// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { fileManagerCommands, subshellCommand } from "../src/core/open-folder.js"
import type { System } from "../src/core/system.js"

const system = (os: NodeJS.Platform, env: Record<string, string> = {}): System => ({
    os,
    env,
    home: "/home/u",
    cwd: "/work",
})

test("file manager commands per system", () => {
    assert.deepEqual(fileManagerCommands(system("linux"), "/p"), [
        ["xdg-open", "/p"],
        ["gio", "open", "/p"],
    ])
    assert.deepEqual(fileManagerCommands(system("darwin"), "/p"), [["open", "/p"]])
    assert.deepEqual(fileManagerCommands(system("win32"), "C:\\p"), [["explorer", "C:\\p"]])
    assert.deepEqual(fileManagerCommands(system("plan9" as NodeJS.Platform), "/p"), [])
})

test("the subshell is $SHELL or /bin/sh, %COMSPEC% or cmd.exe", () => {
    assert.deepEqual(subshellCommand(system("linux", { SHELL: "/bin/zsh" })), ["/bin/zsh"])
    assert.deepEqual(subshellCommand(system("linux", { SHELL: "" })), ["/bin/sh"])
    assert.deepEqual(subshellCommand(system("darwin")), ["/bin/sh"])
    assert.deepEqual(subshellCommand(system("win32", { COMSPEC: "C:\\cmd.exe" })), [
        "C:\\cmd.exe",
    ])
    assert.deepEqual(subshellCommand(system("win32")), ["cmd.exe"])
})
