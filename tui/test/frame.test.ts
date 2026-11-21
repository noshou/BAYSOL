// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the screen kit (`ui/frame.tsx`, `ui/input.tsx`, `ui/grid.tsx`) and the look
// (`ui/theme.tsx`): the corner, the form fields, the input status, the menu taskbar,
// the logo cells and the palettes.
//
// Contents:
//   1. Frame: the corner label
//   2. Fields: widths and cursor moves of a form
//   3. Input: the position status
//   4. Grid: the menu taskbar
//   5. Theme: the logo cells and the palettes

import assert from "node:assert/strict"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { renderToString } from "ink"
import { createElement } from "react"
import { displayWidth } from "../src/core/terminal.js"
import {
    cornerLabel,
    Frame,
    fitCorner,
    footerExtraLines,
    footerKeyRows,
    moveCell,
    placeAt,
} from "../src/ui/frame.js"
import { type LegendItem, legendFor } from "../src/ui/grid.js"
import { positionStatus } from "../src/ui/input.js"
import { keys } from "../src/ui/interaction.js"
import {
    DataTable,
    ErrorText,
    errorStyle,
    linesOf,
    logoCells,
    logoText,
    type Theme,
    themes,
} from "../src/ui/theme.js"

// ========================================================================================
// 1. Frame: the corner label
// ========================================================================================

test("the corner names the project, and the run once one is chosen", () => {
    assert.equal(cornerLabel("demo"), "project: demo")
    assert.equal(
        cornerLabel("demo", "19-33-08-000_UTC_+0000_2026-11-06"),
        "project: demo · run: 19:33:08:000 UTC +00:00 · 2026-11-06",
    )
})

test("the footer is as tall as its logo; a note or long legend adds only its rows", () => {
    assert.equal(footerKeyRows(0, 3, false), 3)
    assert.equal(footerKeyRows(2, 3, true), 3)
    assert.equal(footerKeyRows(3, 3, false), 3)
    assert.equal(footerKeyRows(3, 3, true), 4)
    const items = (n: number): LegendItem[] =>
        Array.from({ length: n }, (_, i) => legendFor(`key${i}`, keys.enter))
    const rows = (design: "blocky" | "smooth", shown: number, full: number, note = "") =>
        renderToString(
            createElement(Frame, {
                title: "t",
                legend: items(shown),
                legendFull: items(full),
                design,
                counter: "x [1 / 2]",
                note,
            }),
            { columns: 80 },
        ).split("\n").length
    // title, margin, then the logo's 3 rows (and the box's 2 rows when blocky), however
    // tall the fullest legend is
    for (const [shown, full] of [[3, 3], [3, 9], [9, 9], [10, 10]]) {
        assert.equal(rows("smooth", shown, full), 5)
        assert.equal(rows("blocky", shown, full), 7)
    }
    assert.equal(rows("smooth", 3, 9, "sure?"), 6)
    assert.equal(rows("smooth", 3, 3), rows("smooth", 3, 3, "sure?") - 1)
    assert.equal(rows("smooth", 3, 3, "sure?"), rows("smooth", 9, 9, "sure?"))
})

test("a corner that fits is drawn whole", () => {
    const label = cornerLabel("demo", "19-33-08-000_UTC_+0000_2026-11-06")
    assert.equal(fitCorner(label, 78, "logs", "runs"), label)
    const fresh = cornerLabel("demo", "23-35-29-123_EST_-0500_2026-11-07")
    assert.equal(fresh, "project: demo · run: 23:35:29:123 EST -05:00 · 2026-11-07")
    assert.equal(fitCorner(fresh, 78, "open", "runs"), fresh)
})

test("a corner is cut before it can push the title, and never wider than its room", () => {
    const stamp = "19-33-08-000_UTC_+0000_2026-11-06"
    const label = cornerLabel("a-very-long-project-name", stamp)
    const title = "logs"
    const subtitle = "view settings"
    for (const columns of [78, 60, 50, 40]) {
        const shown = fitCorner(label, columns, title, subtitle)
        const used = displayWidth(title) + 1 + displayWidth(`· ${subtitle}`)
        if (shown !== undefined) {
            assert.ok(displayWidth(shown) + used < columns, `${columns}: ${shown}`)
            if (displayWidth(label) > columns - used - 2) assert.match(shown, /…$/)
        }
    }
    assert.match(fitCorner(label, 60, title, subtitle) ?? "", /^project: a-very/)
})

test("with too little room the corner is left out, not shown as a stump", () => {
    assert.equal(fitCorner("project: demo", 20, "logs", "a long subtitle here"), undefined)
    assert.equal(fitCorner("project: demo", 10, "logs"), undefined)
})

test("the title with no subtitle leaves its room to the corner", () => {
    assert.equal(fitCorner("project: demo", 30, "logs"), "project: demo")
})

// ========================================================================================
// 2. Fields: widths and cursor moves of a form
// ========================================================================================

/** The shape of the polymer form: name, four unit rows, the end groups (no column 0). */
const unit = [0, 1, 2, 3, 4]
const valid = [[0], unit, unit, unit, unit, [1, 2, 3, 4]]

test("up and down keep the column asked for", () => {
    let pos = placeAt(1, 3)
    pos = moveCell(valid, pos, -1, 0)
    assert.deepEqual(pos, { row: 0, col: 0, want: 3 })
    pos = moveCell(valid, pos, 1, 0)
    assert.deepEqual(pos, { row: 1, col: 3, want: 3 })
})

test("the end groups have no column 0: the cursor goes to the nearest", () => {
    const pos = moveCell(valid, placeAt(4, 0), 1, 0)
    assert.deepEqual(pos, { row: 5, col: 1, want: 0 })
})

test("left and right stay on the row and change the column asked for", () => {
    let pos = moveCell(valid, placeAt(1, 0), 0, 1)
    assert.deepEqual(pos, { row: 1, col: 1, want: 1 })
    pos = moveCell(valid, placeAt(1, 4), 0, 1)
    assert.equal(pos.col, 4)
    pos = moveCell(valid, placeAt(5, 1), 0, -1)
    assert.equal(pos.col, 1)
    pos = moveCell(valid, placeAt(0, 0), 0, 1)
    assert.equal(pos.col, 0)
})

test("up and down stop at the ends", () => {
    assert.equal(moveCell(valid, placeAt(0, 0), -1, 0).row, 0)
    assert.equal(moveCell(valid, placeAt(5, 1), 1, 0).row, 5)
})

// ========================================================================================
// 3. Input: the position status
// ========================================================================================

test("positionStatus counts from one", () => {
    assert.equal(positionStatus(0, 12), "1 of 12")
    assert.equal(positionStatus(11, 12), "12 of 12")
})

// ========================================================================================
// 5. Theme: the logo cells and the palettes
// ========================================================================================

test("every theme's logo is drawn in exactly two cells, with no variation selector", () => {
    for (const theme of themes) {
        const drawn = logoText(theme.lg)
        const why = `${theme.nm}: ${JSON.stringify(drawn)}`
        assert.equal(displayWidth(drawn), logoCells, why)
        assert.ok(!/[︎️]/.test(drawn), `${theme.nm} keeps a variation selector`)
    }
})

test("a narrow glyph is padded, a wide one kept, an overlong one cut", () => {
    assert.equal(logoText("❄️"), "❄ ")
    assert.equal(logoText("🪨"), "🪨")
    assert.equal(logoText("⚪"), "⚪")
    assert.equal(displayWidth(logoText("🪨🪨🪨")), logoCells)
    assert.equal(logoText(""), "  ")
})

test("blocky draws double lines, smooth thin ones", () => {
    assert.equal(linesOf("blocky"), "double")
    assert.equal(linesOf("smooth"), "single")
    const table = (border?: "single" | "double") =>
        renderToString(
            createElement(DataTable<{ a: string }>, {
                columns: [
                    { title: "x", width: 3, text: (r) => r.a },
                    { title: "y", width: 3, text: (r) => r.a },
                ],
                rows: [{ a: "1" }],
                cursor: 0,
                offset: 0,
                pageSize: 3,
                width: 40,
                border,
            }),
        )
    assert.match(table("double"), /═╬═/)
    assert.match(table("double"), /║/)
    assert.doesNotMatch(table("double"), /[─│]/)
    assert.match(table(), /─┼─/)
    assert.doesNotMatch(table(), /[═║]/)
})

test("a blocky footer reserves the two rows of its box, and the keys' own lines", () => {
    const keysOf = (n: number) =>
        Array.from({ length: n }, (_, i) => legendFor(`key${i}`, keys.save))
    for (const n of [3, 6, 9]) {
        for (const columns of [78, 108]) {
            const smooth = footerExtraLines(keysOf(n), columns, 3)
            const blocky = footerExtraLines(keysOf(n), columns, 3, "blocky")
            assert.equal(blocky, smooth + 2, `${n} keys at ${columns}`)
        }
    }
})

test("only the table-style screens ask for the blocky design", () => {
    // the files that draw tables, forms, settings sheets and the logs pages
    const allowed = [
        "custom-solutes.tsx",
        "logs-menu.tsx",
        "notes-editor.tsx",
        "notes-list.tsx",
        "polymers.tsx",
        "screen-rules.ts",
        "settings-sheet.tsx",
        "solutes.tsx",
    ]
    const dir = join(import.meta.dirname, "..", "src", "screens")
    for (const file of readdirSync(dir)) {
        const code = readFileSync(join(dir, file), "utf-8")
            .split("\n")
            .filter((l) => !/^\s*(\*|\/\/|\/\*)/.test(l))
            .join("\n")
        // asking: the `design="blocky"` prop or a "blocky" argument (not a comparison)
        const asks = /design="blocky"|, "blocky"\)/.test(code)
        assert.equal(asks, allowed.includes(file), `${file} and the blocky design`)
    }
})

test("an error is drawn in the error colour, in one place", () => {
    for (const theme of Object.values(themes)) {
        assert.deepEqual(errorStyle(theme), { color: theme.er })
    }
    const theme = Object.values(themes)[0] as Theme
    assert.equal(renderToString(createElement(ErrorText, null, "")), "")
    assert.equal(renderToString(createElement(ErrorText, null, " ")), "")
    assert.equal(
        renderToString(createElement(ErrorText, null, "no good!")),
        "no good!",
    )
    assert.ok(theme.er !== theme.bg)
})
