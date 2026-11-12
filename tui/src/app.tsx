// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text, useApp, useWindowSize } from "ink"
import { type ReactNode, useRef, useState } from "react"
import { appDir } from "./core/environment.js"
import { MainMenu } from "./screens/menus.js"
import { SheetViewerScreen } from "./screens/viewer.js"
import { hasActiveRuns, quitAll } from "./store/run.js"
import { readThemeName, writeThemeName } from "./store/settings-store.js"
import { ThemePicker } from "./ui/input.js"
import { keys, minColumns, minRows, NavProvider, useKeys } from "./ui/interaction.js"
import {
    defaultTheme,
    Logo,
    type Theme,
    ThemeContext,
    themeByName,
    themes,
} from "./ui/theme.js"

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
 * @param props.viewFile - a workbook or table file to open in the viewer at once instead
 *     of the main menu (`--view FILE`, a developer's way to look at a file).
 * @returns the app.
 */
export function App({ viewFile }: { viewFile?: string }): ReactNode {
    const [theme, setTheme] = useState<Theme>(savedTheme)
    const [picking, setPicking] = useState(false)
    const { exit } = useApp()
    const { columns, rows } = useWindowSize()
    const tooSmall = columns < minColumns || rows < minRows

    // `^t` opens the picker; while it is open the picker is the only thing that listens
    useKeys((press) => {
        if (press.is(keys.theme)) setPicking(true)
    }, !picking)

    // Ctrl-C and Ctrl-D (with `q` in the main menu the only exits; Esc never quits). While
    // a run is going the first press only stops the run (its Julia stopped, its status
    // written, its logs packed) and the screen stays; the next press, while that happens
    // or once the run is over, ends the program.
    const stopping = useRef(false)
    useKeys((press) => {
        if (!(press.is(keys.interrupt) || press.is(keys.eof))) return
        if (hasActiveRuns() && !stopping.current) {
            stopping.current = true
            void quitAll(press.label)
                .catch(() => {})
                .finally(() => {
                    stopping.current = false
                })
            return
        }
        void quitAll(press.label)
            .catch(() => {})
            .finally(exit)
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
                    <NavProvider
                        root={
                            viewFile === undefined ? (
                                <MainMenu />
                            ) : (
                                <SheetViewerScreen workbookPath={viewFile} />
                            )
                        }
                        suspended={tooSmall || picking}
                    />
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
