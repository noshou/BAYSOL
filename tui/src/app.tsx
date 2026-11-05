// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text, useWindowSize } from "ink"
import { type ReactNode, useState } from "react"
import { appDir } from "./core/paths.js"
import { MainMenu } from "./screens/main-menu.js"
import { readThemeMode, type ThemeMode, writeThemeMode } from "./store/theme-store.js"
import { keys } from "./ui/keys.js"
import { minColumns, minRows } from "./ui/layout.js"
import { NavProvider } from "./ui/nav.js"
import { darkTheme, lightTheme, ThemeContext } from "./ui/theme.js"
import { useKeys } from "./ui/use-keys.js"

/**
 * The program: the theme, the size check, and the navigation with the main menu as
 * its first screen. The terminal is filled with the background colour whatever its
 * size; only a terminal below the minimum gets a message instead of the screens.
 *
 * @returns the app.
 */
export function App(): ReactNode {
    // the theme the user left the program in last time (dark on a first start)
    const [mode, setMode] = useState<ThemeMode>(() => readThemeMode(appDir()))
    const theme = mode === "light" ? lightTheme : darkTheme
    const { columns, rows } = useWindowSize()
    const tooSmall = columns < minColumns || rows < minRows

    // toggle between light and dark theme, from any screen, and remember the choice
    useKeys((press) => {
        if (!press.is(keys.theme)) return
        const next = mode === "light" ? "dark" : "light"
        setMode(next)
        writeThemeMode(appDir(), next)
    })

    return (
        <ThemeContext.Provider value={theme}>
            <Box width={columns} height={rows} backgroundColor={theme.bg} flexDirection="column">
                {tooSmall ? (
                    <Text color={theme.fg}>
                        the terminal is {columns} x {rows}; BAYSOL needs at least {minColumns} x{" "}
                        {minRows}
                    </Text>
                ) : (
                    <>
                        <Box flexGrow={1}>
                            <NavProvider root={<MainMenu />} />
                        </Box>
                        <Box justifyContent="flex-end">
                            <Text color={theme.mt}>
                                {mode === "light" ? "theme (^t): ☀️" : "theme (^t): 🌕"}
                            </Text>
                        </Box>
                    </>
                )}
            </Box>
        </ThemeContext.Provider>
    )
}
