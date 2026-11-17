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
