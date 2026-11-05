// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, render, Text, useInput, useWindowSize } from "ink"
import { useState } from "react"
import { KeyInput, keyPress } from "./keys.js"
import { MainMenu } from "./main-menu.js"
import { darkTheme, lightTheme, ThemeContext } from "./theme.js"

const toggleKey = new KeyInput("t", true)

function App() {
    const [mode, setMode] = useState<"light"|"dark">()
    const theme = mode === "light" ? lightTheme : darkTheme
    const { columns, rows } = useWindowSize()

    // toggle between light and dark theme
    useInput((input, key) => {
        const press = keyPress(input, key)
        if (press.is(toggleKey))
            { setMode(mode === "light" ? "dark" : "light")  }
    })

    return (
        <ThemeContext.Provider value={theme}>
            <Box
                width = {columns}
                height={rows}
                backgroundColor={theme.bg}
                flexDirection="column"
            >
                <Box flexGrow={1}>
                    <MainMenu/>
                </Box>

                <Box justifyContent="flex-end">
                    <Text color={theme.mt}>
                        {mode === "light" ? "theme (^t): ☀️" : "theme (^t): 🌕"}
                    </Text>
                </Box>
            </Box>
        </ThemeContext.Provider>
    )
}
render (<App/>)
