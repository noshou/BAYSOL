// SPDX-License-Identifier: LGPL-3.0-or-later

import { createContext, useContext } from "react"

/** a generic theme */
export type Theme = {
    bg : string     // background colour
    fg : string     // foreground colour
    mt : string     // muted colour
}

/** light canvas background with warm brown text */
export const lightTheme: Theme = {
    bg : "#F2E9D7",
    fg : "#594422",
    mt : "#aa9379"
}

/** deep navy blue with golden text */
export const darkTheme: Theme = {
    bg : "#162045",
    fg : "#e7d45d",
    mt : "#d7d4bf"
}

/** Default is dark theme. */
export const ThemeContext = createContext<Theme>(darkTheme)

/**
 * returns current theme; only callable within a component.
 * The theme is chosen in b`main.tsx`, by the value of its
 * `ThemeContext.Provider` (light or dark).
 */
export function useTheme(): Theme {
    return useContext(ThemeContext)
}
