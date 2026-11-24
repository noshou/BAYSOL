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
import { legendFor, moveLegend } from "../src/ui/grid.js"
import {
    centredWindow,
    clampWindow,
    type Hotkey,
    KeyInput,
    keyLabels,
    keyPress,
    keys,
    menuOptions,
    scrollTo,
    scrollWindow,
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
    assert.equal(keys.save.label, "^w")
    assert.equal(keys.jump.label, "shift+j")
    assert.equal(keys.moveData.label, "shift+d")
    assert.equal(keys.moveData.name, "shift+d")
    // a capital is always written `shift+<letter>`, never `P`
    assert.equal(keys.plots.label, "shift+p")
    assert.equal(keys.moveTex.label, "shift+l")
    // shifted symbols and Shift arrows
    assert.equal(keys.zoomIn.label, "shift+=")
    assert.equal(keys.zoomOut.label, "shift+-")
    assert.equal(keys.pageDownShift.label, "shift+↓")
    assert.equal(keys.pageUpShift.label, "shift+↑")
    assert.equal(keys.pickFiles.label, "^v")
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
    // Tab and shift+tab: the one that works is added (the import screen)
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
    // Tab and shift+tab: both are `keys.tab`, only shift+tab is `keys.shiftTab`
    const tab = keyPress("", { ...noFlags, tab: true })
    const back = keyPress("", { ...noFlags, tab: true, shift: true })
    assert.ok(tab.is(keys.tab) && !tab.is(keys.shiftTab))
    assert.ok(back.is(keys.tab) && back.is(keys.shiftTab))
    assert.ok(keyPress("", { ...noFlags, home: true }).is(keys.home))
    assert.ok(keyPress("", { ...noFlags, pageDown: true }).is(keys.pageDown))
})

test("keyPress: a shifted symbol is the Shift of its key, its text kept", () => {
    // Ink reports `_` and `+` without the Shift flag (checked in a pty)
    const under = keyPress("_", noFlags)
    const plus = keyPress("+", noFlags)
    assert.ok(under.is(keys.zoomOut) && under.text === "_" && under.typed)
    assert.ok(plus.is(keys.zoomIn) && plus.text === "+" && plus.typed)
    // the plain keys are not the zoom keys
    assert.ok(!keyPress("-", noFlags).is(keys.zoomOut))
    assert.ok(!keyPress("=", noFlags).is(keys.zoomIn))
})

test("keyPress: shift+↓ and shift+↑ are page keys (ESC[1;2B reaches Ink as Shift)", () => {
    const down = keyPress("", { ...noFlags, downArrow: true, shift: true })
    const up = keyPress("", { ...noFlags, upArrow: true, shift: true })
    assert.ok(down.is(keys.pageDownShift) && up.is(keys.pageUpShift))
    // a plain arrow is no page key; a plain hotkey also matches the Shift press, so the
    // page keys are read first (see `pageKey`)
    const plain = keyPress("", { ...noFlags, downArrow: true })
    assert.ok(!plain.is(keys.pageDownShift))
    assert.ok(down.is(keys.down))
})

test("pageKey: shift+arrows and PgUp/PgDn turn a page, nothing else does", async () => {
    const { pageKey, pageLegend } = await import("../src/ui/pager.js")
    const press = (flags: Partial<typeof noFlags>) => keyPress("", { ...noFlags, ...flags })
    assert.equal(pageKey(press({ downArrow: true, shift: true })), "down")
    assert.equal(pageKey(press({ pageDown: true })), "down")
    assert.equal(pageKey(press({ upArrow: true, shift: true })), "up")
    assert.equal(pageKey(press({ pageUp: true })), "up")
    assert.equal(pageKey(press({ downArrow: true })), undefined)
    assert.equal(pageKey(keyPress(" ", noFlags)), undefined)
    assert.equal(pageKey(keyPress("k", noFlags)), undefined)
    // the legend lists both keys of each
    assert.deepEqual(pageLegend.next, { label: "next page", keys: "shift+↓ pgdn" })
    assert.deepEqual(pageLegend.prev, { label: "prev page", keys: "shift+↑ pgup" })
})

test("is: a plain hotkey matches either case, a Shift hotkey only the capital", () => {
    const lower = keyPress("d", noFlags)
    const cap = keyPress("D", noFlags)
    const s = keyPress("s", noFlags)
    const capS = keyPress("S", noFlags)
    assert.ok(!s.is(keys.sort))
    assert.ok(capS.is(keys.sort))
    // a plain hotkey (the copy answers, the menus) still answers its capital
    assert.ok(keyPress("C", noFlags).is(keys.copyCell))
    assert.ok(cap.is(keys.moveData))
    assert.ok(!lower.is(keys.moveData))
    // Ctrl and names still have to be equal
    assert.ok(!lower.is(keys.eof))
    assert.ok(!lower.is(keys.jump))
    assert.ok(new KeyInput("r", true).is(keys.remove))
    assert.ok(!new KeyInput("z", true).is(keys.reset))
})

/**
 * The plain (unmodified) keys that may have a meaning besides the menu hotkeys: the
 * named keys (arrows, Enter, Esc, Tab, Backspace ...), Space (mark), `/` (find) and the
 * answers of the viewer's copy question, asked while nothing else listens. Every other
 * key needs Ctrl or Shift (owner, 2026-11-14).
 */
const plainAllowed = new Set([
    "enter", "escape", "tab", "backspace", "delete", "up", "down", "left", "right",
    "pageUp", "pageDown", "home", "end", "mark", "find",
    "copyCell", "copyRow", "copyColumn",
])

test("raw keys only for navigation, find, mark and the copy question", () => {
    for (const [action, key] of Object.entries(keys)) {
        if (key.ctrl || key.shift) continue
        assert.ok(plainAllowed.has(action), `${action} (${key.label}) needs Ctrl or Shift`)
    }
    for (const [name, option] of Object.entries(menuOptions))
        assert.ok(!option.hotkey.ctrl && !option.hotkey.shift, `menu ${name} is plain`)
})

test("a label never shows a bare capital", () => {
    for (const [action, key] of Object.entries(keys))
        assert.ok(!/^[A-Z]$/.test(key.label), `${action} is labelled ${key.label}`)
})

/** What a press looks like to the user, for comparing inputs: Ctrl, Shift and the name. */
const inputId = (key: Hotkey): string =>
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

/** The files that insert typed text and so read `press.text` (the text entry code). */
const textEntryFiles = ["text-input.tsx", "text-area.tsx"]

test("no key is defined, spelled or compared outside `ui/interaction.tsx`", () => {
    const stray: [string, RegExp][] = [
        [
            "a hotkey factory",
            /\b(ctrlKey|plainKey|shiftKey|namedKey|makeHotkey)\(/,
        ],
        ["a Hotkey constructed", /new\s+Hotkey\b/],
        ["Ink's useInput", /\buseInput\b/],
        ["press.key_ against a literal", /\.key_\s*[!=]==/],
        ["a key name against a literal", /\b(key|press)\.name\s*[!=]==/],
    ]
    const textRule: [string, RegExp] = [
        "press.text against a literal outside text entry",
        /\b(press|key)\.text\s*[!=]==\s*["'`]/,
    ]
    for (const [file, text] of sourceTexts()) {
        const rules = textEntryFiles.some((f) => file.endsWith(f))
            ? stray
            : [...stray, textRule]
        text.split("\n").forEach((line, i) => {
            for (const [what, re] of rules)
                assert.ok(!re.test(line), `${file}:${i + 1}: ${what}: use \`keys\``)
        })
    }
})

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
        import("../src/screens/settings-menu.js").then((m) => m.settingsMenuSpec),
    globalMenuSpec: () =>
        import("../src/screens/settings-menu.js").then((m) => m.globalMenuSpec),
}

test("every option of a menu has a hotkey of its own", async () => {
    for (const [name, load] of Object.entries(menuModules)) {
        const menu = await load()
        const seen = new Set<string>()
        for (const option of menu.names as readonly string[]) {
            const opts = menu.opts as Record<string, { hotkey: Hotkey }>
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
