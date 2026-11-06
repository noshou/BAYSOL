// SPDX-License-Identifier: LGPL-3.0-or-later

import { createContext, useContext } from "react"

/**
 * Represents a generic colour theme.
 *
 * @property nm - The name of the theme.
 * @property bg - The background colour.
 * @property fg - The foreground colour.
 * @property mt - The muted colour, used for secondary text .
 * @property er - The error colour, used for messages indicating an error.
 * @property lg - The logo associated with the theme.
 */
export type Theme = {
    readonly nm : string
    readonly bg : string
    readonly fg : string
    readonly mt : string
    readonly er : string
    readonly lg : string
}

//////////////////
// LIGHT THEMES //
//////////////////

/** The light themes, in the order the theme picker lists them. */
export const lightThemes = [
    /** Soft autumn leaves and warm harvest tones */
    {
        nm : "autumn",
        bg : "#F3E6D2",
        fg : "#65452F",
        mt : "#A17B58",
        er : "#B74732",
        lg : "🍂"
    },

    /** Soft lavender and violet */
    {
        nm : "lavender",
        bg : "#EDE8F6",
        fg : "#51416D",
        mt : "#8776A5",
        er : "#A83255",
        lg : "🪻"
    },

    /** light canvas background with warm brown text */
    {
        nm : "mate",
        bg : "#EEF0DF",
        fg : "#839576",
        mt : "#809f95",
        er : "#000000",
        lg : "🧉"
    },

    /** black-on-white theme */
    {
        nm : "onigiri",
        bg : "#ffffff",
        fg : "#000000",
        mt : "#000000",
        er : "#000000",
        lg : "🍙"
    },

    /** Pink lemonade with blood-orange typography */
    {
        nm : "pamplemousse",
        bg : "#fffdd9",
        fg : "#ad4558",
        mt : "#ec8999",
        er : "#9a9984",
        lg : "🍊"
    },

    /** Clean paper white and dark ink */
    {
        nm : "parchment",
        bg : "#f8f3de",
        fg : "#454327",
        mt : "#777875",
        er : "#A0443F",
        lg : "📜"
    },

    /** Muted rose and burgundy */
    {
        nm : "rose",
        bg : "#F5E6E8",
        fg : "#713B4B",
        mt : "#A36E7B",
        er : "#A12E36",
        lg : "🌸"
    },

    /** inspired by tweedia flowers */
    {
        nm : "tweedia",
        bg : "#daeafe",
        fg : "#0b77b5`",
        mt : "#5d7cd7",
        er : "#B83232",
        lg : "💠"
    },
] as const satisfies readonly Theme[]

/////////////////
// DARK THEMES //
/////////////////

/** The dark themes, in the order the theme picker lists them. */
export const darkThemes = [

    /** Deep forest green */
    {
        nm : "arboreal",
        bg : "#294b30",
        fg : "#79b577",
        mt : "#b1b071",
        er : "#FF7066",
        lg : "🌲"
    },

    /** Muted graphite and silver */
    {
        nm : "graphite",
        bg : "#4a4c51",
        fg : "#D6D0C4",
        mt : "#A09D96",
        er : "#FF7168",
        lg : "🪨"
    },

    /** Holographic turquoise with fluorescent coral */
    {
        nm : "holograph",
        bg : "#0A1010",
        fg : "#00FFCC",
        mt : "#FF4D6D",
        er : "#FF6A00",
        lg : "🌃"
    },

    /** white-on-black theme */
    {
        nm : "invert",
        bg : "#000000",
        fg : "#ffffff",
        mt : "#ffffff",
        er : "#ffffff",
        lg : "⚪"
    },

    /** deep navy blue with golden text */
    {
        nm : "luxe",
        bg : "#162045",
        fg : "#f6c933",
        mt : "#d1e5f9",
        er : "#ff8a6b",
        lg : "👑"
    },

    /** Neon pink */
    {
        nm : "ultrapink",
        bg : "#34104c",
        fg : "#FF4FD8",
        mt : "#C49ACF",
        er : "#FF795C",
        lg : "🌆"
    },

    /** Dark woodland brown with warm ivory typography */
    {
        nm : "ursus",
        bg : "#3e322a",
        fg : "#F2E8D5",
        mt : "#B8A99A",
        er : "#FF6B5A",
        lg : "🐻"
    },

    /** green on black vt100 like theme*/
    {
        nm : "vt100",
        bg : "#000000",
        fg : "#4AF626",
        mt : "#9ac995",
        er : "#C94A44",
        lg : "📟"
    },
] as const satisfies readonly Theme[]

/**
 * Every theme, the light ones first. Worked out from the two arrays above: a themeim
 * added to either one is in the picker, the footer and the saved choice at once.
 */
export const themes: readonly Theme[] = [...lightThemes, ...darkThemes]

/**
 * The name of a theme that exists: a union of the literal names written in the two
 * arrays above (`"cloudy days" | "rose" | ...`), so a name that is not there is a
 * compile error wherever one is spelled out.
 */
export type ThemeName = (typeof lightThemes | typeof darkThemes)[number]["nm"]

/** The name of the theme of a first start; it must be one of the themes above. */
const defaultThemeName: ThemeName = "holograph"

/**
 * Finds a theme by its name.
 *
 * @param name - the name of a theme, its `nm`.
 * @returns the theme, or `undefined` if there is none of that name (a theme removed
 *     since the name was saved).
 */
export function themeByName(name: string): Theme | undefined {
    return themes.find((theme) => theme.nm === name)
}

/**
 * The theme of a first start. It is looked up by a name the compiler has checked
 * against the arrays, so the error below cannot happen.
 */
export const defaultTheme: Theme = (() => {
    const found = themeByName(defaultThemeName)
    if (found === undefined) throw new Error(`no theme is called ${defaultThemeName}`)
    return found
})()

/**
 * The cells the logo (emoji) of a theme is assumed to take. Emoji widths vary between
 * terminals; every place that draws a logo reserves this much, so the columns after it
 * line up whatever the terminal makes of it.
 */
export const logoCells = 2

/** What a screen sees when nothing above it chose a theme: the default theme. */
export const ThemeContext = createContext<Theme>(defaultTheme)

/**
 * returns current theme; only callable within a component.
 * The theme is chosen in `app.tsx` (the picker opened with `^t`), by the value of the
 * `ThemeContext.Provider` there.
 */
export function useTheme(): Theme {
    return useContext(ThemeContext)
}
