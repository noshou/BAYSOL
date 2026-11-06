// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { type TaskbarItem, taskbarItemFor, taskbarLegend } from "../src/ui/grid-menu.js"
import { keyPress, keys, plainKey, taskbarKeys } from "../src/ui/keys.js"

const noFlags = {
    upArrow: false, downArrow: false, leftArrow: false, rightArrow: false,
    pageDown: false, pageUp: false, home: false, end: false,
    return: false, escape: false, ctrl: false, shift: false, tab: false,
    backspace: false, delete: false, meta: false,
    super: false, hyper: false, capsLock: false, numLock: false,
}

const item = (name: keyof typeof taskbarKeys, hits: string[]): TaskbarItem => ({
    ...taskbarKeys[name],
    onPress: () => hits.push(name),
})

test("taskbar: a Shift item answers its capital only, and only when it is passed", () => {
    const hits: string[] = []
    const items = [item("run", hits), item("results", hits)]
    taskbarItemFor(items, keyPress("R", noFlags))?.onPress()
    taskbarItemFor(items, keyPress("Y", noFlags))?.onPress()
    assert.deepEqual(hits, ["run", "results"])
    assert.equal(taskbarItemFor(items, keyPress("r", noFlags)), undefined)
    assert.equal(taskbarItemFor(items, keyPress("y", noFlags)), undefined)
    // there is no Shift+D: lowercase d is the data option, and D is nothing here
    assert.equal(taskbarItemFor(items, keyPress("D", noFlags)), undefined)
    // an item that does not apply is not passed, so its key does nothing
    assert.equal(taskbarItemFor([item("run", hits)], keyPress("Y", noFlags)), undefined)
    assert.equal(taskbarItemFor([], keyPress("R", noFlags)), undefined)
})

test("taskbar: a Shift item wins over a plain one with the same letter", () => {
    const hits: string[] = []
    const plain: TaskbarItem = {
        label: "plain", key: plainKey("y"), onPress: () => hits.push("plain"),
    }
    const items = [plain, item("results", hits)]
    taskbarItemFor(items, keyPress("Y", noFlags))?.onPress()
    taskbarItemFor(items, keyPress("y", noFlags))?.onPress()
    assert.deepEqual(hits, ["results", "plain"])
})

test("taskbar legend: label and key of each item, in order", () => {
    const items = [item("run", []), item("results", [])]
    assert.deepEqual(taskbarLegend(items), [
        { label: "run", keys: keys.runKey.label },
        { label: "results", keys: keys.resultsKey.label },
    ])
    assert.deepEqual(taskbarLegend([]), [])
})
