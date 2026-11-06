// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, type BoxProps } from "ink"
import type { PropsWithChildren, ReactNode } from "react"
import { useTheme } from "./theme.js"

/**
 * A bordered box in the colours of the theme. A bare Ink box leaves its border (and
 * the cells behind its text) in the terminal's own background, which shows as a
 * differently coloured frame; a `Panel` paints the border, the fill and the text of
 * the box with the theme's background and the foreground border colour (pass
 * `borderColor` for another), so every box on
 * every screen looks alike. Every bordered box of the program is a `Panel`.
 *
 * @param style - the line style, `"round"` when left out (`"double"` for the footer
 *     of the sheets).
 * @param props - any other Ink box props (padding, direction, gaps, ...).
 * @returns the box with its children.
 */
export function Panel(
    { style = "round", children, ...props }:
        PropsWithChildren<BoxProps & { style?: "round" | "double" | "single" }>
): ReactNode {
    const theme = useTheme()
    return (
        <Box
            borderStyle={style}
            borderColor={theme.fg}
            borderBackgroundColor={theme.bg}
            backgroundColor={theme.bg}
            {...props}
        >
            {children}
        </Box>
    )
}
