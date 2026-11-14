// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the interaction plumbing (`ui/interaction.tsx`): keys, scroll window and list
// cursor, the text buffer.
//
// Contents:
//   1. Keys: names, matching and labels
//   2. Scroll window and list cursor
//   3. `TextBuffer`: the text and cursor of an input

import assert from "node:assert/strict"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import { legendFor, menuOptions, moveLegend } from "../src/ui/grid.js"
import {
    centredWindow,
    clampWindow,
    ctrlKey,
    KeyInput,
    keyLabels,
    keyPress,
    keys,
    plainKey,
    scrollTo,
    scrollWindow,
    shiftKey,
    stepIndex,
} from "../src/ui/interaction.js"
import { TextBuffer } from "../src/ui/text-input.js"

// ========================================================================================
// 1. Keys: names, matching and labels
// ========================================================================================

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
    // Tab and Shift+Tab: the one that works is added (the import screen)
    assert.equal(moveLegend({ down: true, tab: true })?.keys, "↓ tab")
    assert.equal(moveLegend({ up: true, down: true, tab: true })?.keys, "↑↓ tab")
    assert.equal(moveLegend({ up: true, tab: true })?.keys, "↑", "last row: no Tab")
    assert.equal(moveLegend({ tab: true }), undefined)
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
    // Tab and Shift+Tab: both are `keys.tab`, only Shift+Tab is `keys.shiftTab`
    const tab = keyPress("", { ...noFlags, tab: true })
    const back = keyPress("", { ...noFlags, tab: true, shift: true })
    assert.ok(tab.is(keys.tab) && !tab.is(keys.shiftTab))
    assert.ok(back.is(keys.tab) && back.is(keys.shiftTab))
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

/** What a press looks like to the user, for comparing inputs: Ctrl, Shift and the name. */
const inputId = (key: KeyInput): string =>
    `${key.ctrl ? "ctrl+" : ""}${key.shift ? "shift+" : ""}${key.key_}`

test("every input in `keys` and in the menus is one action's, and no other's", () => {
    const owners = new Map<string, string>()
    const claim = (id: string, action: string) => {
        const other = owners.get(id)
        assert.equal(other, undefined, `${id} is both ${other} and ${action}`)
        owners.set(id, action)
    }
    for (const [action, key] of Object.entries(keys)) claim(inputId(key), action)
    for (const [name, option] of Object.entries(menuOptions))
        claim(inputId(option.hotkey), `menu ${name}`)
    // an input a terminal cannot send (Enter, Tab, flow control, suspend, backspace)
    const unusable = ["m", "i", "j", "b", "s", "q", "z", "y", "h"]
    for (const [id, action] of owners) {
        assert.ok(
            !(id.startsWith("ctrl+") && unusable.includes(id.slice(5))),
            `${action} (${id}) is a key terminals do not send`,
        )
    }
})

/** The source files of the program (`.ts` and `.tsx`), as text, except the key table. */
function sourceTexts(dir: string = fileURLToPath(new URL("../src", import.meta.url))) {
    const files: string[] = []
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const path = join(dir, entry.name)
        if (entry.isDirectory()) files.push(...sourceTexts(path).map(([f]) => f))
        else if (/\.tsx?$/.test(entry.name) && entry.name !== "interaction.tsx")
            files.push(path)
    }
    return files.map((f): [string, string] => [f, readFileSync(f, "utf8")])
}

/**
 * The keys that no legend or note shows, on purpose, and why. Every other key of
 * `keys` must be spelled out to the user by a legend (`legendFor`, `keyLabels`) or by
 * its label in a note, so the keys can be learned from the screen.
 */
const legendless: Record<string, string> = {
    enter:
        "the answer of every prompt; via `legendEnter` and `questionLegend`",
    escape: "the cancel of every prompt; legends show it through `questionLegend`",
    tab: "moves between fields and sheets; `entryLegend` and the form legend show it",
    backspace: "text editing",
    delete: "text editing; a delete legend shows `remove`",
    up: "cursor moves; `moveLegend` shows them",
    down: "cursor moves; `moveLegend` shows them",
    left: "cursor moves; `moveLegend` shows them",
    right: "cursor moves; `moveLegend` shows them",
    pageUp: "paging; the pager legend shows it",
    pageDown: "paging; the pager legend shows it",
    home: "text editing and paging",
    end: "text editing and paging",
    interrupt: "leaves the program; the help text says so, no legend",
    eof: "leaves the program, like `interrupt`",
    back: "shown through `legendBack`",
    theme: "shown on the theme line at the foot of every screen",
    runKey: "shown through `taskbarKeys`",
    notesList: "shown through `taskbarKeys`, and in notes of the solutes tables",
    zoomInAlt: "the second key of `zoomIn`, which the legend shows",
    prevSheet: "the second key of `shiftTab`, which the legend shows",
    nextSheet: "the second key of `tab`, which the legend shows",
    space: "the second key of the page-down and of the range mark; the legend shows it",
}

test("every key of the table is shown by a legend or is documented as legend-less", () => {
    const texts = sourceTexts()
    const shown = (name: string): boolean =>
        texts.some(([, text]) =>
            text.split("\n").some(
                (line) =>
                    new RegExp(`keys\\.${name}\\b`).test(line) &&
                    /legendFor\(|keyLabels\(|\.label|\.name\b|label:/.test(line),
            ),
        )
    for (const name of Object.keys(keys)) {
        if (name in legendless) continue
        assert.ok(shown(name), `keys.${name} is in no legend: show it or document why not`)
    }
    for (const name of Object.keys(legendless))
        assert.ok(name in keys, `legendless lists ${name}, which is not a key`)
})

/** The three menu specs of the screens, loaded one by one. */
const menuModules = {
    mainMenuSpec: () =>
        import("../src/screens/menus.js").then((m) => m.mainMenuSpec),
    projectMenuSpec: () =>
        import("../src/screens/menus.js").then((m) => m.projectMenuSpec),
    settingsMenuSpec: () =>
        import("../src/screens/settings-screens.js").then((m) => m.settingsMenuSpec),
    globalMenuSpec: () =>
        import("../src/screens/settings-screens.js").then((m) => m.globalMenuSpec),
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
    const { mainMenuSpec } = await import("../src/screens/menus.js")
    assert.equal(mainMenuSpec.byHotkey(keyPress("n", noFlags)), "new")
    assert.equal(mainMenuSpec.byHotkey(keyPress("N", noFlags)), "new")
    assert.equal(mainMenuSpec.byHotkey(keyPress("z", noFlags)), undefined)
})

test("project menu: 3 rows of 2, hotkeys m d b g s o, logs among them", async () => {
    const { projectMenuSpec } = await import("../src/screens/menus.js")
    assert.deepEqual(
        [...projectMenuSpec.names],
        ["models", "data", "buffer", "logs", "settings", "open"],
    )
    assert.equal(projectMenuSpec.columns, 2)
    assert.deepEqual(projectMenuSpec.rows, [
        ["models", "data"],
        ["buffer", "logs"],
        ["settings", "open"],
    ])
    const hot = (c: string) => projectMenuSpec.byHotkey(keyPress(c, noFlags))
    assert.deepEqual(["m", "d", "b", "g", "s", "o"].map(hot), [...projectMenuSpec.names])
    // `run` is not an option and `r` is no key
    assert.equal(hot("r"), undefined)
    // the arrows of the grid: logs has a neighbour on every side but the right
    assert.equal(projectMenuSpec.neighbour("logs", "left"), "buffer")
    assert.equal(projectMenuSpec.neighbour("logs", "down"), "open")
    assert.equal(projectMenuSpec.neighbour("logs", "up"), "data")
    assert.equal(projectMenuSpec.neighbour("logs", "right"), undefined)
})

// ========================================================================================
// 2. Scroll window and list cursor
// ========================================================================================

test("the window of a table follows the cursor with the least movement", () => {
    assert.equal(scrollWindow(0, 0, 5, 20), 0)
    assert.equal(scrollWindow(4, 0, 5, 20), 0)
    assert.equal(scrollWindow(5, 0, 5, 20), 1)
    assert.equal(scrollWindow(2, 10, 5, 20), 2)
    assert.equal(scrollWindow(19, 0, 5, 20), 15)
    // the window shrank (a prompt opened) and the cursor stays in view
    assert.equal(scrollWindow(9, 7, 3, 20), 7)
    assert.equal(scrollWindow(9, 5, 3, 20), 7)
    // a short list shows from the top, a size of 0 is taken as 1
    assert.equal(scrollWindow(1, 3, 10, 4), 0)
    assert.equal(scrollWindow(2, 0, 0, 4), 2)
})

test("clampWindow keeps the window inside the list", () => {
    assert.equal(clampWindow(-3, 5, 20), 0)
    assert.equal(clampWindow(18, 5, 20), 15)
    assert.equal(clampWindow(4, 5, 20), 4)
    assert.equal(clampWindow(4, 5, 3), 0)
})

test("centredWindow puts the highlight in the middle, clamped at both ends", () => {
    assert.equal(centredWindow(3, 2, 5), 0)
    assert.equal(centredWindow(20, 0, 5), 0)
    assert.equal(centredWindow(20, 10, 5), 8)
    assert.equal(centredWindow(20, 19, 5), 15)
})

test("scrollTo moves the top only as far as the fitting rows need", () => {
    assert.equal(
        scrollTo(0, 7, () => 3),
        5,
    )
    assert.equal(
        scrollTo(6, 2, () => 3),
        2,
    )
    assert.equal(
        scrollTo(1, 2, () => 3),
        1,
    )
})

test("stepIndex stops at the ends, or goes round when it wraps", () => {
    assert.equal(stepIndex(1, 4, true), 2)
    assert.equal(stepIndex(3, 4, true), 3)
    assert.equal(stepIndex(0, 4, false), 0)
    assert.equal(stepIndex(3, 4, true, true), 0)
    assert.equal(stepIndex(0, 4, false, true), 3)
    assert.equal(stepIndex(2, 4, false, true), 1)
    // an empty list keeps the highlight on 0
    assert.equal(stepIndex(0, 0, true, true), 0)
})

// ========================================================================================
// 3. `TextBuffer`: the text and cursor of an input
// ========================================================================================

test("typing inserts at the cursor and moves it", () => {
    const b = new TextBuffer("ac").left().insert("b")
    assert.equal(b.text, "abc")
    assert.equal(b.cursor, 2)
})

test("backspace and delete remove whole characters", () => {
    assert.equal(new TextBuffer("a👍").backspace().text, "a")
    assert.equal(new TextBuffer("ab", 0).delete().text, "b")
    assert.equal(new TextBuffer("", 0).backspace().text, "")
})

test("the length limit cuts what is typed and says it is full", () => {
    const b = new TextBuffer("", undefined, 3).insert("abcdef")
    assert.equal(b.text, "abc")
    assert.ok(b.full)
})

test("a paste loses its newlines", () => {
    assert.equal(new TextBuffer().insert("a\nb\r\n").text, "ab")
})
