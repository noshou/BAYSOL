// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { useTheme } from "./theme.js"

/**
 * One tab of a [[ChoiceTabs]] row as text: `[pdf]` when the choice is on, `(pdf)` when
 * it is off, the tab in focus in capitals.
 *
 * @param option - the choice.
 * @param on - whether it is on.
 * @param focused - whether it is the tab in focus.
 * @returns the text.
 */
export function tabLabel(option: string, on: boolean, focused: boolean): string {
    const label = focused ? option.toUpperCase() : option
    return on ? `[${label}]` : `(${label})`
}

/**
 * A one-line row of tabs for a choice of a few options, each on or off. It only draws:
 * the screen moves the focus and toggles (the figure formats of the output sheet).
 *
 * @param options - every choice, in order.
 * @param selected - the choices that are on.
 * @param focus - the index of the tab in focus; none when left out.
 * @returns the row, the tab in focus bold, the ones that are off muted.
 */
export function ChoiceTabs(props: {
    options: readonly string[]
    selected: ReadonlySet<string>
    focus?: number
}): ReactNode {
    const { options, selected, focus } = props
    const theme = useTheme()
    return (
        <Box columnGap={1}>
            {options.map((option, i) => {
                const on = selected.has(option)
                return (
                    <Text key={option} bold={i === focus} color={on ? theme.fg : theme.mt}>
                        {tabLabel(option, on, i === focus)}
                    </Text>
                )
            })}
        </Box>
    )
}
