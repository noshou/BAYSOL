// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { truncate } from "../core/text.js"
import { useBodyColumns } from "./layout.js"
import { Legend, type LegendItem } from "./legend.js"
import { type SmallLogo, smallLogo } from "./menu-opts.js"
import { Panel } from "./panel.js"
import { useTheme } from "./theme.js"

/** Both small logos, loaded once: they are read from disk. */
const logos = { blocky: smallLogo("blocky"), smooth: smallLogo("smooth") }

/**
 * What a screen tells the frame.
 *
 * @property title - the name of the screen, e.g. `"sampler settings"`.
 * @property subtitle - what it is about, e.g. the project's name.
 * @property legend - the keys that work now.
 * @property logo - which small logo sits at the bottom left, and with it how the keys
 *     are laid out: `"blocky"` for tables, forms and sheets (keys in columns, in a box
 *     with double lines), `"smooth"` for the landing pages (each key in a rounded box).
 *     `"smooth"` when left out.
 * @property counter - a short text in a box at the bottom right, such as
 *     `"sampler [1 / 6]"` or `"solutes [3 / 12]"`.
 * @property note - one line above the keys: a question (`discard 3 changes?`), an
 *     error, or a hint. It is cut to the width of the terminal.
 * @property noteIsError - draw the note in the error colour.
 */
type FrameProps = {
    title:        string
    subtitle?:    string
    legend:       LegendItem[]
    logo?:        SmallLogo
    counter?:     string
    note?:        string
    noteIsError?: boolean
    children?:    ReactNode
}

/**
 * The common shape of every screen below the menus: a title, a body that takes the
 * rest of the terminal, and at the bottom the small BAYSOL logo, the keys that work, an
 * optional note and an optional counter. It reads the size of the terminal and keeps
 * no fixed size of its own.
 *
 * @param props - see [[FrameProps]].
 * @returns the screen.
 */
export function Frame(props: FrameProps): ReactNode {
    const {
        title,
        subtitle,
        legend,
        logo = "smooth",
        counter,
        note,
        noteIsError,
        children,
    } = props
    const theme = useTheme()
    const columns = useBodyColumns()
    const art = logos[logo]

    // the note has a row of its own whether there is one or not, so a note appearing
    // never makes the footer taller (which would push the body, and the logo, up a row)
    const noteLine = (
        <Box height={1} flexShrink={0}>
            {note ? (
                <Text color={noteIsError ? theme.er : theme.fg}>
                    {truncate(note, columns - 6 - art.width)}
                </Text>
            ) : null}
        </Box>
    )
    const logoBox = (
        <Box
            width={art.width}
            height={art.height}
            backgroundColor={theme.bg}
            flexShrink={0}
        >
            <Text color={theme.fg}>{art.text}</Text>
        </Box>
    )
    const counterBox = counter ? (
        <Panel style={logo === "blocky" ? "double" : "round"} paddingX={1}>
            <Text color={theme.fg}>{counter}</Text>
        </Panel>
    ) : null

    return (
        <Box flexDirection="column" flexGrow={1} paddingX={1}>
            <Box columnGap={1}>
                <Text bold color={theme.fg}>{title}</Text>
                {subtitle ? <Text color={theme.mt}>· {subtitle}</Text> : null}
            </Box>

            <Box flexDirection="column" flexGrow={1} marginTop={1}>
                {children}
            </Box>

            {logo === "blocky" ? (
                // the tables, forms and sheets: one box with double lines holds it all
                <Panel style="double" paddingX={1} columnGap={2} alignItems="flex-end">
                    {logoBox}
                    <Box flexDirection="column" flexGrow={1}>
                        {noteLine}
                        <Legend items={legend} style="columns" />
                    </Box>
                    {counterBox}
                </Panel>
            ) : (
                // the landing pages: the logo, then each key in a rounded box of its own
                <Box columnGap={2} alignItems="flex-end">
                    {logoBox}
                    <Box flexDirection="column" flexGrow={1}>
                        {noteLine}
                        <Legend items={legend} style="boxes" />
                    </Box>
                    {counterBox}
                </Box>
            )}
        </Box>
    )
}
