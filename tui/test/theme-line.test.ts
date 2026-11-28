// SPDX-License-Identifier: LGPL-3.0-or-later

// The last row of the frame ends one column short: the bottom-right cell of the terminal
// is a plain space, never a glyph, and the logo (two cells) sits right before it.

import assert from "node:assert/strict"
import { test } from "node:test"
import { stripVTControlCharacters } from "node:util"
import { Box, renderToString } from "ink"
import { createElement } from "react"
import { ThemeLine } from "../src/app.js"
import { displayWidth } from "../src/core/terminal.js"
import { logoText, themes } from "../src/ui/theme.js"

for (const [columns, rows] of [
    [80, 24],
    [100, 30],
]) {
    test(`the theme line leaves the last cell empty at ${columns}x${rows}`, () => {
        for (const theme of themes) {
            const frame = createElement(
                Box,
                {
                    width: columns,
                    height: rows,
                    flexDirection: "column",
                    backgroundColor: theme.bg,
                },
                createElement(Box, { flexGrow: 1 }),
                createElement(ThemeLine, { theme }),
            )
            const lines = renderToString(frame, { columns }).replace(/\n+$/, "").split("\n")
            const last = lines[lines.length - 1] as string
            const plain = stripVTControlCharacters(last)
            // the emoji ends at column `columns - 1`: the last cell holds no glyph
            // (without colours Ink trims the painted space, with colours it is a space)
            const logo = logoText(theme.lg)
            const body = plain.trimEnd()
            assert.equal(body.endsWith(logo.trimEnd()), true, `${theme.nm} logo`)
            assert.equal(displayWidth(body), columns - 1, theme.nm)
            assert.equal(plain === body || plain.endsWith(" "), true, theme.nm)
            assert.equal(displayWidth(logo), 2)
        }
    })
}

test("the clock shows when it fits, is dropped when not, the last cell stays empty", () => {
    const theme = themes[0] as (typeof themes)[number]
    for (const [columns, hint, clock] of [
        [100, undefined, true],
        [80, undefined, true],
        [50, undefined, false],
        [80, "x".repeat(40), false],
    ] as const) {
        const frame = createElement(
            Box,
            {
                width: columns,
                height: 3,
                flexDirection: "column",
                backgroundColor: theme.bg,
            },
            createElement(Box, { flexGrow: 1 }),
            createElement(ThemeLine, { theme, hint, columns }),
        )
        const lines = renderToString(frame, { columns }).replace(/\n+$/, "").split("\n")
        const plain = stripVTControlCharacters(lines[lines.length - 1] as string)
        assert.equal(/\d\d:\d\d:\d\d/.test(plain), clock, `${columns} ${hint ?? ""}`)
        assert.equal(plain.includes("theme ("), true)
        assert.equal(displayWidth(plain.trimEnd()) <= columns - 1, true)
        if (clock) assert.equal(displayWidth(plain.trimEnd()), columns - 1)
    }
})
