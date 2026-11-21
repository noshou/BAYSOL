// SPDX-License-Identifier: LGPL-3.0-or-later

// A smoke test of the retry-ladder editor with an absurd ladder (300 rungs of 20 overrides
// each): the real component is mounted in Ink on a fake terminal and driven by key bytes.
// The cursor must stay in the window, add, remove, move and the sheet of a rung must work,
// and no frame may be taller or wider than the terminal.

import assert from "node:assert/strict"
import { PassThrough } from "node:stream"
import { test } from "node:test"
import { render } from "ink"
import { createElement } from "react"
import type { EditEnd } from "../src/screens/screen-rules.js"
import { ladderRungs, overrideDef } from "../src/screens/screen-rules.js"
import { LadderEditor } from "../src/screens/settings-editors.js"
import { type LadderMap, type SettingValue, validateValue } from "../src/store/settings.js"
import { NavProvider } from "../src/ui/interaction.js"
import { settingDef } from "./support/fixtures.js"

const def = settingDef("LADDER")

/** Every terminal escape sequence (colours, mode switches). */
const ESCAPES = new RegExp(`${String.fromCharCode(27)}\\[[0-9;?]*[a-zA-Z]`, "g")

/** Hotkeys as the terminal sends them. */
const KEY = {
    enter: "\r",
    escape: "\x1b",
    up: "\x1b[A",
    down: "\x1b[B",
    shiftDown: "\x1b[1;2B",
    pageDown: "\x1b[6~",
    end: "\x1b[F",
    home: "\x1b[H",
    add: "\x0e", // ^n
    remove: "\x12", // ^r
    undo: "\x15", // ^u
}

/** An absurd ladder: `count` rungs spread over the classes, each with `width` overrides. */
function absurd(count: number, width: number): LadderMap {
    const names = def.overridable.slice(0, width)
    const map: LadderMap = Object.fromEntries(def.classes.map((c) => [c, []]))
    for (let i = 0; i < count; i++) {
        const cls = def.classes[Math.floor((i * def.classes.length) / count)] as string
        const overrides: Record<string, SettingValue> = {}
        for (const n of names) overrides[n] = overrideDef(def, n)?.default as SettingValue
        map[cls]?.push({ name: `rung ${i + 1}`, overrides })
    }
    return map
}

/** A fake terminal: a stdout whose last write is the frame, and a stdin Ink can read. */
function terminal(columns: number, rows: number) {
    const out = Object.assign(new PassThrough(), { columns, rows, isTTY: true })
    let frame = ""
    out.on("data", (chunk) => {
        // a bare mode switch (bracketed paste on or off) is not a frame
        const text = String(chunk)
        if (text.replace(ESCAPES, "").trim() !== "") frame = text
    })
    const input = Object.assign(new PassThrough(), {
        isTTY: true,
        setRawMode: () => input,
        ref: () => input,
        unref: () => input,
    })
    return { out, input, frame: () => frame }
}

/** Mounts the editor on a terminal of this size; `body` rows are the editor's. */
function mount(map: LadderMap, columns: number, rows: number) {
    const term = terminal(columns, rows)
    const ends: EditEnd<SettingValue>[] = []
    const body = rows - 10
    const app = render(
        createElement(NavProvider, {
            root: createElement(LadderEditor, {
                def,
                current: map as SettingValue,
                rows: body,
                onEnd: (end: EditEnd<SettingValue>) => ends.push(end),
                onLegend: () => {},
            }),
        }),
        {
            stdout: term.out as never,
            stdin: term.input as never,
            debug: true,
            patchConsole: false,
            exitOnCtrlC: false,
        },
    )
    const lines = (): string[] =>
        term
            .frame()
            .split("\n")
            .map((l) => l.replace(ESCAPES, ""))
    const press = async (...keys: string[]): Promise<void> => {
        for (const k of keys) {
            term.input.write(k)
            await new Promise((r) => setTimeout(r, k === KEY.escape ? 80 : 25))
        }
    }
    const type = (text: string) => press(...text.split(""))
    return { lines, press, type, ends, app, body }
}

/** The text of the row the cursor is on (the one after the `>` marker). */
const cursorRow = (lines: string[]): string | undefined =>
    lines.find((l) => l.trimStart().startsWith(">"))

/** Every frame fits the terminal: at most `body` lines, none wider than `columns`. */
function assertFits(lines: string[], columns: number, body: number): void {
    const text = lines.filter((l, i) => i < lines.length - 1 || l.trim() !== "")
    assert.ok(text.length <= body, `${text.length} lines, the body has ${body}`)
    for (const l of text) assert.ok([...l].length <= columns, `wide line: ${l}`)
}

for (const [columns, rows] of [
    [80, 24],
    [120, 40],
] as const) {
    const title = `ladder editor: an absurd ladder scrolls and fits at ${columns}x${rows}`
    test(title, async () => {
        const map = absurd(300, 20)
        const ed = mount(map, columns, rows)
        await ed.press(KEY.home)
        assertFits(ed.lines(), columns, ed.body)
        assert.match(ed.lines().join("\n"), /rung 1 of 300/)
        assert.match(
            cursorRow(ed.lines()) ?? "",
            /step size collapsed\s+▸ rung 1 ▸ 20 overrides/,
        )

        // down through the window: the cursor row is always drawn
        for (let i = 0; i < 40; i++) {
            await ed.press(KEY.down)
            assert.ok(cursorRow(ed.lines()), `no cursor after ${i + 1} downs`)
        }
        assert.match(cursorRow(ed.lines()) ?? "", /rung 41 ▸/)
        await ed.press(KEY.pageDown)
        assert.match(ed.lines().join("\n"), /rung 41\+\d+ of 300|rung \d+ of 300/)
        await ed.press(KEY.end)
        assert.match(ed.lines().join("\n"), /rung 300 of 300/)
        assert.match(cursorRow(ed.lines()) ?? "", /rung 300 ▸ 20 overrides/)
        assertFits(ed.lines(), columns, ed.body)

        // remove the last rung, then move one earlier among its own condition
        await ed.press(KEY.remove)
        assert.match(ed.lines().join("\n"), /rung 299 of 299/)
        await ed.press(KEY.home, KEY.shiftDown)
        assert.match(cursorRow(ed.lines()) ?? "", /rung 1 ▸/) // the rung kept the cursor
        assert.match(ed.lines().join("\n"), /rung 2 of 299/)

        // add a rung: condition (the first), name, setting (the first), value, close
        await ed.press(KEY.add)
        assert.match(ed.lines().join("\n"), /condition:/)
        assertFits(ed.lines(), columns, ed.body)
        await ed.press(KEY.enter)
        await ed.type("new one")
        await ed.press(KEY.enter)
        assert.match(ed.lines().join("\n"), /setting:/)
        await ed.press(KEY.enter)
        await ed.press(KEY.enter) // the value as offered
        assert.match(ed.lines().join("\n"), /new one/)
        assert.match(ed.lines().join("\n"), /1 of 3|row 3 of 3|row \d+ of 3/)
        await ed.press(KEY.escape)
        assert.match(ed.lines().join("\n"), /of 300/)
        assert.match(cursorRow(ed.lines()) ?? "", /new one ▸ 1 override/)

        // open a rung of 20 overrides: the sheet scrolls to its last row and fits
        await ed.press(KEY.home, KEY.enter)
        assert.match(ed.lines().join("\n"), /rung 1 of 300/)
        await ed.press(KEY.end)
        assert.ok(cursorRow(ed.lines()), "no cursor on the sheet")
        assertFits(ed.lines(), columns, ed.body)
        await ed.press(KEY.escape)

        // the whole thing is still a valid ladder when taken
        await ed.press(KEY.escape)
        const done = ed.ends.at(-1)
        assert.equal(done?.kind, "done")
        const value = (done as { value: SettingValue }).value
        assert.ok(validateValue(def, value).ok)
        assert.equal(ladderRungs(value as LadderMap, def.classes).length, 300)
        ed.app.unmount()
    })
}
