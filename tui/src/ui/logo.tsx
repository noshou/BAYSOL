// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { displayWidth, takeWidth } from "../core/text.js"
import { logoCells, type Theme } from "./theme.js"

/** The characters that ask for the colour (`FE0F`) or the text (`FE0E`) form of a glyph. */
const variationSelectors = /[︎️]/g

/**
 * The text that draws a theme's logo in EXACTLY `logoCells` cells, whatever the glyph
 * is. Terminals disagree about how wide a glyph with a variation selector is (a snowflake
 * with `FE0F` is one cell in some and two in others), and a disagreement moves every cell
 * after it. So the selectors are dropped, which makes the width the one the glyph has
 * on its own and the same in every terminal; a narrow glyph is then padded with a blank
 * (the terminal fills it with the background), and one that is too wide is cut at a
 * character boundary and padded.
 *
 * @param logo - the logo of a theme, its `lg`.
 * @returns text that is `logoCells` cells wide.
 */
export function logoText(logo: string): string {
    const plain = logo.replace(variationSelectors, "")
    const fitted = displayWidth(plain) > logoCells ? takeWidth(plain, logoCells) : plain
    return fitted + " ".repeat(Math.max(0, logoCells - displayWidth(fitted)))
}

/**
 * A theme's logo in its own two-cell box. Every place that shows a logo (the footer, the
 * theme picker) uses this one component, so they always agree and the columns after a
 * logo never move.
 *
 * @param theme - the theme whose logo to draw (not necessarily the one in use).
 * @returns the logo.
 */
export function Logo({ theme }: { theme: Theme }): ReactNode {
    return (
        <Box width={logoCells} flexShrink={0} overflow="hidden">
            <Text>{logoText(theme.lg)}</Text>
        </Box>
    )
}
