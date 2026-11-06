// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import {
    ctrlKey,
    KeyInput,
    keyLabels,
    keyPress,
    keys,
    plainKey,
    shiftKey,
} from "../src/ui/keys.js"
import { legendFor, moveLegend } from "../src/ui/legend.js"

/** The flags Ink reports for a key that types a letter: none set. */
const noFlags = {
    upArrow: false, downArrow: false, leftArrow: false, rightArrow: false,
    pageDown: false, pageUp: false, home: false, end: false,
    return: false, escape: false, ctrl: false, shift: false, tab: false,
    backspace: false, delete: false, meta: false,
    super: false, hyper: false, capsLock: false, numLock: false,
}

test("labels: named keys, Ctrl, Shift and plain letters", () => {
    assert.equal(keys.enter.label, "⏎")
    assert.equal(keys.escape.label, "esc")
    assert.equal(keys.tab.label, "tab")
    assert.equal(keys.up.label, "↑")
    assert.equal(keys.right.label, "→")
    assert.equal(keys.pageUp.label, "pgup")
    assert.equal(keys.home.label, "home")
    assert.equal(keys.remove.label, "^r")
    assert.equal(ctrlKey("w").label, "^w")
    assert.equal(plainKey("o").label, "o")
    assert.equal(shiftKey("d").label, "shift+d")
    assert.equal(shiftKey("d").name, "shift+d")
    assert.equal(keys.enter.name, "enter")
    assert.equal(keys.escape.name, "esc")
})

test("keyLabels: space between keys, runs written together", () => {
    assert.equal(keyLabels(keys.up, keys.down), "↑ ↓")
    assert.equal(keyLabels([keys.up, keys.down]), "↑↓")
    assert.equal(keyLabels([keys.left, keys.right], keys.tab), "←→ tab")
    assert.deepEqual(legendFor("save", keys.save), { label: "save", keys: "^w" })
    assert.equal(moveLegend({ up: true, down: true })?.keys, "↑↓")
    assert.equal(moveLegend({ left: true, right: true })?.keys, "←→")
    assert.equal(moveLegend({}), undefined)
})

test("keyPress: a capital letter is a Shift press, a lower case one is not", () => {
    const d = keyPress("d", noFlags)
    const cap = keyPress("D", noFlags)
    assert.equal(d.shift, false)
    assert.equal(cap.shift, true)
    assert.equal(cap.key_, "d")
    assert.equal(cap.text, "D")
    assert.equal(keyPress("5", noFlags).shift, false)
    assert.equal(keyPress("w", { ...noFlags, ctrl: true }).ctrl, true)
    assert.ok(keyPress("", { ...noFlags, home: true }).is(keys.home))
    assert.ok(keyPress("", { ...noFlags, pageDown: true }).is(keys.pageDown))
})

test("is: a plain hotkey matches either case, a Shift hotkey only the capital", () => {
    const lower = keyPress("d", noFlags)
    const cap = keyPress("D", noFlags)
    assert.ok(lower.is(plainKey("d")))
    assert.ok(cap.is(plainKey("d")))
    assert.ok(cap.is(shiftKey("d")))
    assert.ok(!lower.is(shiftKey("d")))
    // Ctrl and names still have to be equal
    assert.ok(!lower.is(ctrlKey("d")))
    assert.ok(!lower.is(plainKey("g")))
    assert.ok(new KeyInput("r", true).is(keys.remove))
    assert.ok(!new KeyInput("r", true).is(keys.reset))
})

/** The three menu specs of the screens, loaded one by one. */
const menuModules = {
    mainMenuSpec: () => import("../src/screens/main-menu.js").then((m) => m.mainMenuSpec),
    projectMenuSpec: () =>
        import("../src/screens/project-menu.js").then((m) => m.projectMenuSpec),
    settingsMenuSpec: () =>
        import("../src/screens/settings-menu.js").then((m) => m.settingsMenuSpec),
}

test("every option of a menu has a hotkey of its own", async () => {
    for (const [name, load] of Object.entries(menuModules)) {
        const menu = await load()
        const seen = new Set<string>()
        for (const option of menu.names as readonly string[]) {
            const opts = menu.opts as Record<string, { hotkey: KeyInput }>
            const key = opts[option].hotkey
            const id = `${key.ctrl ? "^" : ""}${key.shift ? "S" : ""}${key.key_}`
            assert.ok(!seen.has(id), `${name}: ${option} repeats the hotkey ${id}`)
            seen.add(id)
        }
    }
})

test("a menu finds its option by hotkey, with a capital letter too", async () => {
    const { mainMenuSpec } = await import("../src/screens/main-menu.js")
    assert.equal(mainMenuSpec.byHotkey(keyPress("n", noFlags)), "new")
    assert.equal(mainMenuSpec.byHotkey(keyPress("N", noFlags)), "new")
    assert.equal(mainMenuSpec.byHotkey(keyPress("z", noFlags)), undefined)
})

test("project menu: the grid and the hotkeys m d b s o, no run option", async () => {
    const { projectMenuSpec } = await import("../src/screens/project-menu.js")
    assert.deepEqual(
        [...projectMenuSpec.names],
        ["models", "data", "buffer", "logs", "settings", "open"],
    )
    assert.equal(projectMenuSpec.columns, 2)
    const hot = (c: string) => projectMenuSpec.byHotkey(keyPress(c, noFlags))
    assert.deepEqual(["m", "d", "b", "g", "s", "o"].map(hot), [...projectMenuSpec.names])
    assert.equal(hot("r"), undefined)
})

test("Ctrl-C and Ctrl-D are the keys that leave the program, Esc is not", () => {
    const ctrl = { ...noFlags, ctrl: true }
    assert.ok(keyPress("c", ctrl).is(keys.interrupt))
    assert.ok(keyPress("d", ctrl).is(keys.eof))
    assert.ok(!keyPress("d", noFlags).is(keys.eof))
    assert.equal(keys.interrupt.label, "^c")
    assert.equal(keys.eof.label, "^d")
})

test("taskbar keys are the Shift keys shift+r and shift+y, no plain press", () => {
    assert.deepEqual(
        [keys.runKey.label, keys.resultsKey.label],
        ["shift+r", "shift+y"],
    )
    assert.ok(keyPress("R", noFlags).is(keys.runKey))
    assert.ok(!keyPress("r", noFlags).is(keys.runKey))
    assert.ok(keyPress("Y", noFlags).is(keys.resultsKey))
    assert.ok(!keyPress("y", noFlags).is(keys.resultsKey))
})
