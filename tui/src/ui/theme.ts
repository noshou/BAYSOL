// SPDX-License-Identifier: LGPL-3.0-or-later

import { createContext, useContext } from "react"

/** a generic theme */
export type Theme = {
    bg : string     // background colour
    fg : string     // foreground colour
    mt : string     // muted colour
    er : string     // error colour: a message about something wrong
}

/** light canvas background with warm brown text */
export const lightTheme: Theme = {
    bg : "#F2E9D7",
    fg : "#594422",
    mt : "#aa9379",
    er : "#a8321d"
}

/** deep navy blue with golden text */
export const darkTheme: Theme = {
    bg : "#162045",
    fg : "#e7d45d",
    mt : "#d7d4bf",
    er : "#ff8a6b"
}

/** Default is dark theme. */
export const ThemeContext = createContext<Theme>(darkTheme)

/**
 * returns current theme; only callable within a component.
 * The theme is chosen in `app.tsx`, by the value of its
 * `ThemeContext.Provider` (light or dark).
 */
export function useTheme(): Theme {
    return useContext(ThemeContext)
}
