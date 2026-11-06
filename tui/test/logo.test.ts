// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { readdirSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { test } from "node:test"
import { fileURLToPath } from "node:url"
import { displayWidth } from "../src/core/text.js"
import { logoText } from "../src/ui/logo.js"
import { logoCells, themes } from "../src/ui/theme.js"

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

test("only the settings sheet and the logs pages use the blocky logo", () => {
    // the rule of the screens: blocky (with double-line grids) = the sheets and the logs
    // pages, smooth = the rest. Screens written later (data, run, results) follow it by
    // not naming a logo at all, because smooth is the default of `Frame`.
    const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "screens")
    const blocky = readdirSync(dir)
        .filter((file) => file.endsWith(".tsx"))
        .filter((file) => /logo=["{]+blocky/.test(readFileSync(join(dir, file), "utf-8")))
    const allowed = (file: string) => file === "settings-sheet.tsx" || /^logs-/.test(file)
    assert.deepEqual(blocky.filter((file) => !allowed(file)), [])
})
