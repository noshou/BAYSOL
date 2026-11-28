// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text, useApp, useWindowSize } from "ink"
import { type ReactNode, useRef, useState } from "react"
import { CLOCK_MAX_CELLS, useClock } from "./core/clock.js"
import { appDir } from "./core/environment.js"
import { displayWidth } from "./core/terminal.js"
import { MainMenu } from "./screens/menus.js"
import { SheetViewerScreen } from "./screens/viewer.js"
import { hasActiveRuns, quitAll } from "./store/run.js"
import { readThemeName, writeThemeName } from "./store/theme-file.js"
import { FooterHintContext } from "./ui/footer-hint.js"
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

/** The clock text in its own component: only this re-renders each second. */
function ClockText({ theme }: { theme: Theme }): ReactNode {
    return <Text color={theme.mt}>{useClock()}</Text>
}

/**
 * The last row of the screen: the hint at the left, `theme (^t): <name>` and the logo,
 * and at the right end the live clock ([[CLOCK_MAX_CELLS]] cells, fixed width, one
 * space of gap). The clock is dropped, never the theme switcher, when the row is too
 * narrow for the hint, the switcher and the clock. The row ends one column short
 * (`paddingRight`), so no glyph, a two-cell emoji above all, ever sits in the
 * bottom-right cell of the terminal (a wide glyph there is a weak spot of some
 * terminals); that cell stays a plain space in the theme background.
 *
 * @param props.theme - the theme in use.
 * @param props.hint - a hint of the screen on top, shown at the left end.
 * @param props.columns - the terminal width, to decide whether the clock fits; no clock
 *     when absent.
 * @returns the row.
 */
export function ThemeLine({
    theme,
    hint,
    columns,
}: {
    theme: Theme
    hint?: string
    columns?: number
}): ReactNode {
    const switcher = `theme (${keys.theme.label}): ${theme.nm}`
    // paddings 2, hint, gap, switcher, gap, logo 2, gap, clock
    const needed =
        2 + displayWidth(hint ?? "") + 1 + displayWidth(switcher) + 3 + 1 + CLOCK_MAX_CELLS
    const clock = columns !== undefined && columns >= needed
    return (
        <Box flexGrow={1} justifyContent="space-between" paddingLeft={1} paddingRight={1}>
            <Text color={theme.mt}>{hint ?? ""}</Text>
            <Box columnGap={1}>
                <Text color={theme.mt}>{switcher}</Text>
                <Logo theme={theme} />
                {clock ? <ClockText theme={theme} /> : null}
            </Box>
        </Box>
    )
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
    const [hint, setHint] = useState<string>()
    const { exit } = useApp()
    const { columns, rows } = useWindowSize()
    const tooSmall = columns < minColumns || rows < minRows

    // `^t` opens the picker; while it is open the picker is the only thing that listens
    useKeys((press) => {
        if (press.is(keys.theme)) setPicking(true)
    }, !picking)

    // ^c and ^d (with `q` in the main menu the only exits; Esc never quits). While
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
            <FooterHintContext.Provider value={setHint}>
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
                <Box display={tooSmall ? "none" : "flex"}>
                    <ThemeLine theme={theme} hint={hint} columns={columns} />
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
            </FooterHintContext.Provider>
        </ThemeContext.Provider>
    )
}
