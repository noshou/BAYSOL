// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the look (`ui/theme.tsx`): the logo cells and the palettes.

import assert from "node:assert/strict"
import { readdirSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { renderToString } from "ink"
import { createElement } from "react"
import { displayWidth } from "../src/core/terminal.js"
import { footerExtraLines } from "../src/ui/frame.js"
import { legendFor } from "../src/ui/grid.js"
import { keys } from "../src/ui/interaction.js"
import {
    DataTable,
    linesOf,
    logoCells,
    logoText,
    themes,
} from "../src/ui/theme.js"

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
        "settings-screens.tsx",
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
