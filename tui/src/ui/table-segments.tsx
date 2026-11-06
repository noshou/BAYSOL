// SPDX-License-Identifier: LGPL-3.0-or-later

import { Text } from "ink"
import type { ReactNode } from "react"
import {
    columnBar,
    type LineStyle,
    lineSets,
    type RuleOptions,
    type RulePart,
    ruleLine,
} from "./table-lines.js"
import { useTheme } from "./theme.js"

/**
 * A vertical separator between two cells of one row, in the border colour
 * (`theme.fg`) whatever colour the text of the row has. Put it inside the `Text` of the
 * row, between the segments of its cells.
 *
 * @param props.style - the line style.
 * @returns the separator.
 */
export function Bar(props: { style: LineStyle }): ReactNode {
    const theme = useTheme()
    return <Text color={theme.fg}>{lineSets[props.style].vertical}</Text>
}

/**
 * A column of separators as tall as a block of `height` lines, in the border colour.
 *
 * @param props.style - the line style.
 * @param props.height - the lines.
 * @returns the column.
 */
export function BarColumn(props: { style: LineStyle; height: number }): ReactNode {
    const theme = useTheme()
    return <Text color={theme.fg}>{columnBar(props.style, props.height)}</Text>
}

/**
 * A horizontal rule of a table, in the border colour.
 *
 * @param props.style - the line style.
 * @param props.part - top, between rows or bottom.
 * @param props.widths - the cells inside each column, padding included.
 * @param props.options - see `RuleOptions`.
 * @param props.indent - blank cells before the line.
 * @param props.background - the background of the cells behind the line, if the
 *     table paints one.
 * @returns the rule.
 */
export function Rule(props: {
    style: LineStyle
    part: RulePart
    widths: readonly number[]
    options?: RuleOptions
    indent?: number
    background?: string
}): ReactNode {
    const theme = useTheme()
    const { style, part, widths, options, indent = 0, background } = props
    return (
        <Text color={theme.fg} backgroundColor={background}>
            {`${" ".repeat(indent)}${ruleLine(style, part, widths, options)}`}
        </Text>
    )
}
