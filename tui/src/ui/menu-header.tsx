// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import type { ReactNode } from "react"
import { menuLogo } from "./menu-opts.js"
import { useTheme } from "./theme.js"

/** The logo, loaded once: it is read from disk. */
const logo = menuLogo()

/**
 * What the top of a menu shows: the BAYSOL logo, centred, with one line under it (the
 * version on the main menu, the project's name on the project menu, ...).
 *
 * @param caption - the line under the logo.
 * @returns the header, to pass to a `GridMenu`.
 */
export function MenuHeader({ caption }: { caption: string }): ReactNode {
    const theme = useTheme()
    return (
        <Box flexDirection="column" alignItems="center">
            <Box width={logo.width} height={logo.height} flexShrink={0} marginTop={1}>
                <Text color={theme.fg}>{logo.text}</Text>
            </Box>
            <Text color={theme.mt}> {caption} </Text>
        </Box>
    )
}
