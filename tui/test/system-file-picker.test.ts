// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import type { System } from "../src/core/system.js"
import {
    parsePickerOutput,
    pickerCommands,
    pickerSpecs,
} from "../src/system/file-picker.js"

const system = (os: NodeJS.Platform, env: Record<string, string> = {}): System => ({
    os,
    env,
    home: "/home/u",
    cwd: "/work",
})
const linux = system("linux")
const kde = system("linux", { XDG_CURRENT_DESKTOP: "KDE" })
const programs = (cmds: string[][]): (string | undefined)[] => cmds.map((c) => c[0])

test("Linux: zenity first, kdialog first on KDE, both multiple choice", () => {
    assert.deepEqual(programs(pickerCommands(linux, "/h")), ["zenity", "kdialog"])
    assert.deepEqual(programs(pickerCommands(kde, "/h")), ["kdialog", "zenity"])
    for (const c of pickerCommands(linux, "/h")) assert.ok(c.includes("--multiple"))
})

test("the start folder is in the command", () => {
    assert.ok(pickerCommands(linux, "/home/me")[0]?.includes("--filename=/home/me/"))
})

test("the sequence picker is for one FASTA or FASTQ file", () => {
    const spec = pickerSpecs.sequence
    const cmds = pickerCommands(linux, "/h", spec)
    assert.equal(spec.multiple, false)
    assert.deepEqual(programs(cmds), ["zenity", "kdialog"])
    for (const c of cmds) {
        assert.ok(!c.includes("--multiple"))
        assert.ok(c.some((a) => a.includes("*.fasta")))
        assert.ok(c.some((a) => a.includes("*.FQ")))
    }
    assert.ok(cmds[0]?.some((a) => a.includes("Sequence files")))
    assert.ok(
        pickerCommands(system("darwin"), "/h", spec)[0]?.some((a) => a.includes("fasta")),
    )
    assert.ok(
        pickerCommands(system("win32"), "C:\\Users", spec)[0]?.some((a) =>
            a.includes("$false"),
        ),
    )
    assert.deepEqual(
        pickerCommands(linux, "/h"),
        pickerCommands(linux, "/h", pickerSpecs.structure),
    )
})

test("other systems", () => {
    assert.equal(pickerCommands(system("darwin"), "/h")[0]?.[0], "osascript")
    assert.equal(pickerCommands(system("win32"), "C:\\Users")[0]?.[0], "powershell")
    assert.deepEqual(pickerCommands(system("plan9" as NodeJS.Platform), "/h"), [])
})

test("a quote in the start folder is doubled for PowerShell", () => {
    const text = pickerCommands(system("win32"), "C:\\it's")[0]?.at(-1) ?? ""
    assert.ok(text.includes("InitialDirectory = 'C:\\it''s'"))
})

test("the picker output is one path to a line", () => {
    assert.deepEqual(parsePickerOutput("/a/one.pdb\n/b/two three.cif\n"), [
        "/a/one.pdb",
        "/b/two three.cif",
    ])
    assert.deepEqual(parsePickerOutput("/a/one.pdb\r\n\n"), ["/a/one.pdb"])
    assert.deepEqual(parsePickerOutput(""), [])
    assert.deepEqual(parsePickerOutput(undefined), [])
})
