// SPDX-License-Identifier: LGPL-3.0-or-later

import { createContext, useContext } from "react"

/** a generic theme */
export type Theme = {
    bg : string
    fg : string
}

/** lavender background with deep purple text */
export const lightTheme: Theme = {
    bg : "#FCE5FE",
    fg : "#5B1675"
}

/** deep navy blue with golden text */
export const darkTheme: Theme = {
    bg : "#162045",
    fg : "#DBCF7F"
}

/** Default is light theme. */
export const ThemeContext = createContext<Theme>(lightTheme)

/**
 * returns current theme; only callable within a component.
 * The theme is chosen in `main.tsx`, by the value of its
 * `ThemeContext.Provider` (light or dark).
 */
export function useTheme(): Theme {
    return useContext(ThemeContext)
}
