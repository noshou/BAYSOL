// SPDX-License-Identifier: LGPL-3.0-or-later

import { Text } from "ink"
import type { ReactNode } from "react"

/** The cells a [[Swatch]] takes; a caller that wants a gap after it adds its own. */
export const swatchCells = 2

/**
 * A colour swatch: two cells filled with a colour, so a row shows what a colour (or a
 * theme) looks like. It is a `Text`, so it can stand in a row of its own or inside a
 * longer `Text`.
 *
 * @param props.colour - the colour as `#rrggbb`; blank cells of the same width when
 *     `undefined`, so a column of swatches stays aligned.
 * @returns the swatch.
 */
export function Swatch({ colour }: { colour?: string }): ReactNode {
    return <Text backgroundColor={colour}>{" ".repeat(swatchCells)}</Text>
}
