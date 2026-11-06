// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text, useApp, useWindowSize } from "ink"
import { type ReactNode, useState } from "react"
import { appDir } from "./core/paths.js"
import { MainMenu } from "./screens/main-menu.js"
import { readThemeName, writeThemeName } from "./store/theme-store.js"
import { keys } from "./ui/keys.js"
import { minColumns, minRows } from "./ui/layout.js"
import { Logo } from "./ui/logo.js"
import { NavProvider } from "./ui/nav.js"
import {
    defaultTheme,
    type Theme,
    ThemeContext,
    themeByName,
    themes,
} from "./ui/theme.js"
import { ThemePicker } from "./ui/theme-picker.js"
import { useKeys } from "./ui/use-keys.js"

/**
 * The theme the user left the program in last time: the saved name looked up in the
 * registry, the default theme on a first start or when that theme no longer exists.
 *
 * @returns the theme to start with.
 */
function savedTheme(): Theme {
    const known = themes.map((theme) => theme.nm)
    const name = readThemeName(appDir(), known, defaultTheme.nm)
    return themeByName(name) ?? defaultTheme
}

/**
 * The program: the theme, the size check, and the navigation with the main menu as
 * its first screen. The terminal is filled with the background colour whatever its
 * size; a terminal below the minimum gets a message in place of the screens, which
 * stay mounted (hidden, taking no keys), so growing the terminal again returns to the
 * screen the user was on. `^t`, on any screen, opens the theme picker over it; the
 * theme picked is remembered for the next start.
 *
 * @returns the app.
 */
export function App(): ReactNode {
    const [theme, setTheme] = useState<Theme>(savedTheme)
    const [picking, setPicking] = useState(false)
    const { exit } = useApp()
    const { columns, rows } = useWindowSize()
    const tooSmall = columns < minColumns || rows < minRows

    // `^t` opens the picker; while it is open the picker is the only thing that listens
    useKeys((press) => {
        if (press.is(keys.theme)) setPicking(true)
    }, !picking)

    // Ctrl-C and Ctrl-D end the program from anywhere (with `q` in the main menu they are
    // the only exits; Esc never quits). One handler, always on: the run screen will take
    // this over, to stop the fit it started before it leaves.
    useKeys((press) => {
        if (press.is(keys.interrupt) || press.is(keys.eof)) exit()
    })

    /** Uses a theme from now on, and remembers it. */
    const pick = (picked: Theme) => {
        setTheme(picked)
        writeThemeName(appDir(), picked.nm)
        setPicking(false)
    }

    return (
        <ThemeContext.Provider value={theme}>
            <Box
                width={columns}
                height={rows}
                backgroundColor={theme.bg}
                flexDirection="column"
            >
                {tooSmall ? (
                    <Text color={theme.fg}>
                        the terminal is {columns} x {rows}; BAYSOL needs at least
                        {" "}{minColumns} x {minRows}
                    </Text>
                ) : null}
                <Box flexGrow={1} display={tooSmall ? "none" : "flex"}>
                    <NavProvider root={<MainMenu />} suspended={tooSmall || picking} />
                </Box>
                <Box
                    justifyContent="flex-end"
                    columnGap={1}
                    display={tooSmall ? "none" : "flex"}
                >
                    <Text color={theme.mt}>theme ({keys.theme.label}): {theme.nm}</Text>
                    <Logo theme={theme} />
                </Box>
                {picking && !tooSmall ? (
                    <Box
                        position="absolute"
                        width={columns}
                        height={rows}
                        alignItems="center"
                        justifyContent="center"
                    >
                        <ThemePicker
                            current={theme}
                            onPick={pick}
                            onClose={() => setPicking(false)}
                        />
                    </Box>
                ) : null}
            </Box>
        </ThemeContext.Provider>
    )
}
