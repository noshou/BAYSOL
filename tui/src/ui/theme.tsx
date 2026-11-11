// SPDX-License-Identifier: LGPL-3.0-or-later

// Theme: the look of every screen: the palettes, the logo, the bordered `Panel` and the
// tables drawn in the theme's colours.
//
// Contents:
//   1. Themes: the palettes, `useTheme`, the `Logo`
//   2. `Panel`: a bordered box in the colours of the theme
//   3. Line sets: the box-drawing characters and the pure rule/bar builders
//   4. Segments: `Bar`, `Rule`, drawn in the foreground colour
//   5. `DataTable`: a scrolling table of rows

import { Box, type BoxProps, Text } from "ink"
import {
    createContext,
    Fragment,
    type PropsWithChildren,
    type ReactNode,
    useContext,
} from "react"
import { displayWidth, padWidth, takeWidth, truncate } from "../core/terminal.js"
import type { Design } from "./grid.js"

// ========================================================================================
// 1. Themes: the palettes, `useTheme`, the `Logo`
// ========================================================================================

/** Whether a theme is a light or a dark one. */
type ThemeMode = "light" | "dark"

/**
 * Represents a generic colour theme.
 *
 * @property nm - The name of the theme.
 * @property md - The mode of the theme, `"light"` or `"dark"`; nothing else is allowed.
 * @property bg - The background colour.
 * @property fg - The foreground colour.
 * @property mt - The muted colour, used for secondary text .
 * @property er - The error colour, used for messages indicating an error.
 * @property lg - The logo associated with the theme.
 */
export type Theme = {
    readonly nm : string
    readonly md : ThemeMode
    readonly bg : string
    readonly fg : string
    readonly mt : string
    readonly er : string
    readonly lg : string
}

/**
 * Every theme, in alphabetical order (the order the theme picker lists them). A theme
 * added here is in the picker, the footer and the saved choice at once. Its `md` says
 * whether it is a light or a dark theme; the type allows nothing else.
 */
const themeList = [

    /** Deep abyssal waters and sea-glass typography */
    {
        nm : "abyssal",
        md : "dark",
        bg : "#061113",
        fg : "#8DD5C6",
        mt : "#72AAA8",
        er : "#E7877A",
        lg : "🪼"
    },

    /** Deep forest green */
    {
        nm : "arboreal",
        md : "dark",
        bg : "#1B311F",
        fg : "#BAD9B9",
        mt : "#BFBF8B",
        er : "#FFA49E",
        lg : "🌲"
    },

    /** Soft autumn leaves and warm harvest tones */
    {
        nm : "autumn",
        md : "light",
        bg : "#F4D9A0",
        fg : "#452C08",
        mt : "#8d7a4e",
        er : "#732D0A",
        lg : "🍂"
    },

    /** Muted citron, blackcurrant and electric accents */
    {
        nm : "citron",
        md : "light",
        bg : "#E8E58A",
        fg : "#4f2544",
        mt : "#704a94",
        er : "#851913",
        lg : "🍋"
    },

    /** Muted graphite and silver */
    {
        nm : "graphite",
        md : "dark",
        bg : "#54565b",
        fg : "#E7E3DC",
        mt : "#bcb9b2",
        er : "#090909",
        lg : "🪨"
    },

    /** Holographic turquoise with fluorescent coral */
    {
        nm : "holograph",
        md : "dark",
        bg : "#000000",
        fg : "#00FFCC",
        mt : "#FF617E",
        er : "#FF6A00",
        lg : "🌃"
    },

    /** white-on-black theme */
    {
        nm : "invert",
        md : "dark",
        bg : "#000000",
        fg : "#ffffff",
        mt : "#ffffff",
        er : "#ffffff",
        lg : "⚪"
    },

    /** Soft lavender and violet */
    {
        nm : "lavender",
        md : "light",
        bg : "#EDE8F6",
        fg : "#43365A",
        mt : "#514467",
        er : "#852743",
        lg : "🪻"
    },

    /** deep navy blue with golden text */
    {
        nm : "luxe",
        md : "dark",
        bg : "#141C3D",
        fg : "#f6c933",
        mt : "#d1e5f9",
        er : "#ff8a6b",
        lg : "👑"
    },

    /** light canvas background with warm brown text */
    {
        nm : "mate",
        md : "light",
        bg : "#DBEAD2",
        fg : "#4e694e",
        mt : "#627A60",
        er : "#873B32",
        lg : "🧉"
    },
    /** black-on-white theme */
    {
        nm : "onigiri",
        md : "light",
        bg : "#ffffff",
        fg : "#000000",
        mt : "#000000",
        er : "#000000",
        lg : "🍙"
    },

    /** Pink lemonade with blood-orange typography */
    {
        nm : "pamplemousse",
        md : "light",
        bg : "#FBE0CC",
        fg : "#5c0635",
        mt : "#cd4f6e",
        er : "#8E1316",
        lg : "🍊"
    },

    /** Clean paper white and dark ink */
    {
        nm : "parchment",
        md : "light",
        bg : "#efe8c6",
        fg : "#000000",
        mt : "#744e07",
        er : "#833833",
        lg : "📜"
    },

    /** Muted rose and burgundy */
    {
        nm : "rose",
        md : "light",
        bg : "#F5E6E8",
        fg : "#5A2F3B",
        mt : "#b673aa",
        er : "#89272E",
        lg : "🌸"
    },

    /** Deep Syrah wine and aged rose */
    {
        nm : "syrah",
        md : "dark",
        bg : "#481326",
        fg : "#F0CFCE",
        mt : "#D2A8B2",
        er : "#F09283",
        lg : "🍷"
    },

    /** Sunlit terracotta, weathered pottery and oxidized iron */
    {
        nm : "terracotta",
        md : "light",
        bg : "#f1e2c9",
        fg : "#A95138",
        mt : "#a87b7b",
        er : "#000000",
        lg : "🏺"
    },

    /** inspired by tweedia flowers */
    {
        nm : "tweedia",
        md : "light",
        bg : "#daeafe",
        fg : "#063E5E",
        mt : "#495887",
        er : "#882525",
        lg : "💠"
    },

    /** Neon pink */
    {
        nm : "ultrapink",
        md : "dark",
        bg : "#1D092A",
        fg : "#FF8CE6",
        mt : "#C49ACF",
        er : "#FF795C",
        lg : "🌆"
    },

    /** Dark woodland brown with warm ivory typography */
    {
        nm : "ursus",
        md : "dark",
        bg : "#59473b",
        fg : "#F2E8D5",
        mt : "#BAAC9D",
        er : "#FF8B7E",
        lg : "🐻"
    },

    /** green on black vt100 like theme*/
    {
        nm : "vt100",
        md : "dark",
        bg : "#000000",
        fg : "#4AF626",
        mt : "rgb(108, 186, 100)",
        er : "#f5f501",
        lg : "📟"
    }
] as const satisfies readonly Theme[]

/** The registry, typed as plain themes: the list's literal types serve `ThemeName`. */
export const themes: readonly Theme[] = themeList

/**
 * The name of a theme that exists: a union of the literal names written in the
 * array above (`"cloudy days" | "rose" | ...`), so a name that is not there is a
 * compile error wherever one is spelled out.
 */
export type ThemeName = (typeof themeList)[number]["nm"]

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
 * against the array, so the error below cannot happen.
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

/** The characters that ask for the colour (`FE0F`) or the text (`FE0E`) form of a glyph. */
const variationSelectors = /[︎️]/g

/**
 * The text that draws a theme's logo in EXACTLY `logoCells` cells, whatever the glyph
 * is. Terminals disagree about how wide a glyph with a variation selector is (a snowflake
 * with `FE0F` is one cell in some and two in others), and a disagreement moves every cell
 * after it. So the selectors are dropped, which makes the width the one the glyph has
 * on its own and the same in every terminal; a narrow glyph is then padded with a blank
 * (the terminal fills it with the background), and one that is too wide is cut at a
 * character boundary and padded.
 *
 * @param logo - the logo of a theme, its `lg`.
 * @returns text that is `logoCells` cells wide.
 */
export function logoText(logo: string): string {
    const plain = logo.replace(variationSelectors, "")
    const fitted = displayWidth(plain) > logoCells ? takeWidth(plain, logoCells) : plain
    return fitted + " ".repeat(Math.max(0, logoCells - displayWidth(fitted)))
}

/**
 * A theme's logo in its own two-cell box. Every place that shows a logo (the footer, the
 * theme picker) uses this one component, so they always agree and the columns after a
 * logo never move.
 *
 * @param theme - the theme whose logo to draw (not necessarily the one in use).
 * @returns the logo.
 */
export function Logo({ theme }: { theme: Theme }): ReactNode {
    return (
        <Box width={logoCells} flexShrink={0} overflow="hidden">
            <Text>{logoText(theme.lg)}</Text>
        </Box>
    )
}

/**
 * Draws its children with the muted text colour as the foreground colour, so a box of a
 * picker shows all its text (names, values, counter, hints) in the one foreground colour.
 * The background is the theme's own; only the muted text changes.
 *
 * @param props.children - what is drawn.
 * @returns the children under the changed theme.
 */
export function Bright({ children }: PropsWithChildren): ReactNode {
    const theme = useTheme()
    return (
        <ThemeContext.Provider value={{ ...theme, mt: theme.fg }}>
            {children}
        </ThemeContext.Provider>
    )
}

// ========================================================================================
// 2. `Panel`: a bordered box in the colours of the theme
// ========================================================================================

/**
 * A bordered box in the colours of the theme. A bare Ink box leaves its border (and
 * the cells behind its text) in the terminal's own background, which shows as a
 * differently coloured frame; a `Panel` paints the border, the fill and the text of
 * the box with the theme's background and the foreground border colour (pass
 * `borderColor` for another), so every box on
 * every screen looks alike. Every bordered box of the program is a `Panel`.
 *
 * @param style - the line style, `"round"` when left out (`"double"` on blocky screens).
 * @param props - any other Ink box props (padding, direction, gaps, ...).
 * @returns the box with its children.
 */
export function Panel(
    { style = "round", children, ...props }:
        PropsWithChildren<BoxProps & { style?: "round" | "double" }>
): ReactNode {
    const theme = useTheme()
    return (
        <Box
            borderStyle={style}
            borderColor={theme.fg}
            borderBackgroundColor={theme.bg}
            backgroundColor={theme.bg}
            {...props}
        >
            {children}
        </Box>
    )
}

// ========================================================================================
// 3. Table lines
// ========================================================================================

// The lines of every table of the program: one set of box-drawing characters per style
// and the pure function that builds a rule from the column widths, so no table spells a
// box-drawing character itself. Smooth screens draw thin lines, blocky ones double lines.

/** The kinds of line a table is drawn with. */
export type LineStyle = "single" | "double"

/** @returns the table lines of a design: double on the blocky screens, else thin. */
export function linesOf(design: Design): LineStyle {
    return design === "blocky" ? "double" : "single"
}

/** The kinds of horizontal rule: above the first row, between rows, below the last. */
export type RulePart = "top" | "mid" | "bottom"

/** The horizontal and vertical line, and the left tee, cross and right tee of each rule. */
const lineSets = {
    single: {
        horizontal: "─",
        vertical:   "│",
        top:        ["┌", "┬", "┐"],
        mid:        ["├", "┼", "┤"],
        bottom:     ["└", "┴", "┘"],
    },
    double: {
        horizontal: "═",
        vertical:   "║",
        top:        ["╔", "╦", "╗"],
        mid:        ["╠", "╬", "╣"],
        bottom:     ["╚", "╩", "╝"],
    },
} as const

/**
 * What a rule is drawn with besides the widths.
 *
 * @property frame - whether the table has an outer frame: the rule then starts and ends
 *     with a corner or tee; without it only the crosses between the columns are drawn
 *     (`true` when left out).
 * @property lead - horizontal characters before the rule, for the cells a table keeps
 *     in front of its first column (a cursor, a mark); 0 when left out.
 */
export type RuleOptions = { frame?: boolean; lead?: number }

/**
 * A horizontal rule of a table.
 *
 * @param style - the line style.
 * @param part - which rule: top, between rows or bottom.
 * @param widths - the cells inside each column, padding included.
 * @param options - see [[RuleOptions]].
 * @returns the line, as wide as the table.
 */
function ruleLine(
    style: LineStyle,
    part: RulePart,
    widths: readonly number[],
    options: RuleOptions = {},
): string {
    const { frame = true, lead = 0 } = options
    const set = lineSets[style]
    const [left, cross, right] = set[part]
    const bar = (n: number): string => set.horizontal.repeat(Math.max(0, n))
    const body = widths.map(bar).join(cross)
    return bar(lead) + (frame ? left + body + right : body)
}

// ========================================================================================
// 4. Segments
// ========================================================================================

/**
 * A vertical separator between two cells of one row, in the border colour
 * (`theme.fg`) whatever colour the text of the row has. Put it inside the `Text` of the
 * row, between the segments of its cells.
 *
 * @param props.style - the line style, thin when left out.
 * @returns the separator.
 */
export function Bar({ style = "single" }: { style?: LineStyle }): ReactNode {
    const theme = useTheme()
    return <Text color={theme.fg}>{lineSets[style].vertical}</Text>
}

/**
 * A horizontal rule of a table, in the border colour.
 *
 * @param props.style - the line style, thin when left out.
 * @param props.part - top, between rows or bottom.
 * @param props.widths - the cells inside each column, padding included.
 * @param props.options - see `RuleOptions`.
 * @param props.indent - blank cells before the line.
 * @param props.background - the background of the cells behind the line, if the
 *     table paints one.
 * @returns the rule.
 */
export function Rule(props: {
    style?: LineStyle
    part: RulePart
    widths: readonly number[]
    options?: RuleOptions
    indent?: number
    background?: string
}): ReactNode {
    const theme = useTheme()
    const { style = "single", part, widths, options, indent = 0, background } = props
    return (
        <Text color={theme.fg} backgroundColor={background}>
            {`${" ".repeat(indent)}${ruleLine(style, part, widths, options)}`}
        </Text>
    )
}

// ========================================================================================
// 5. DataTable
// ========================================================================================

/**
 * One column of a [[DataTable]].
 *
 * @typeParam R - the row type.
 * @property title - the header text.
 * @property width - a fixed width in cells; without it the column shares the rest of
 *     the width with the other flexible ones (`grow`).
 * @property grow - the share of the remaining width, 1 when left out.
 * @property align - `"right"` for numbers, `"left"` when left out.
 * @property text - the cell's text for a row.
 */
export type Column<R> = {
    title:  string
    width?: number
    grow?:  number
    align?: "left" | "right"
    text:   (row: R) => string
}

/**
 * What a table is told.
 *
 * @property columns - the columns, left to right.
 * @property rows - all the rows (the table shows the window from `offset`).
 * @property cursor - the index of the row the cursor is on.
 * @property offset - the first row shown.
 * @property pageSize - how many rows are shown.
 * @property mark - the one-character mark of a row (`*` new or edited, `-` marked for
 *     removal, a space for none); drawn in front of the first column.
 * @property emphasis - rows drawn in the full colour although the cursor is not on them
 *     (the others are muted); none are when left out.
 * @property empty - what to say when there are no rows.
 * @property width - the cells the table may use (the body width of the terminal).
 * @property border - the lines of the header rule and between the columns: `"single"`
 *     (smooth screens, default) or `"double"` (blocky screens, [[linesOf]]).
 */
type DataTableProps<R> = {
    columns:  Column<R>[]
    rows:     R[]
    cursor:   number
    offset:   number
    pageSize: number
    mark?:    (row: R) => string
    emphasis?: (row: R) => boolean
    empty?:   string
    width:    number
    border?:  LineStyle
}

/** The cells taken by the cursor, the mark and the separators that frame the cells. */
const gutter = 3

/**
 * Works out the width of every column: the fixed ones as given, the flexible ones
 * share what is left in proportion to their `grow`, none narrower than its title.
 *
 * @param columns - the columns.
 * @param width - the total width of the table.
 * @returns one width per column, in order.
 */
export function columnWidths<R>(columns: Column<R>[], width: number): number[] {
    // each cell has one space of padding on both sides and the columns share one rule
    const room = width - gutter - columns.length * 3
    const fixed = columns.reduce((sum, c) => sum + (c.width ?? 0), 0)
    const grows = columns.reduce(
        (sum, c) => sum + (c.width === undefined ? (c.grow ?? 1) : 0),
        0,
    )
    const left = Math.max(0, room - fixed)
    return columns.map((c) =>
        c.width ??
            Math.max(displayWidth(c.title), Math.floor((left * (c.grow ?? 1)) / grows))
    )
}

/**
 * A table of rows that scrolls under a cursor: a header, a rule, then the rows of the
 * window, the cursor row marked with `>` and drawn in the full foreground colour.
 * Widths follow the terminal, nothing is fixed.
 *
 * @param props - see [[DataTableProps]].
 * @returns the table.
 */
export function DataTable<R>(props: DataTableProps<R>): ReactNode {
    const { columns, rows, cursor, offset, pageSize, mark, emphasis, empty, width } = props
    const border = props.border ?? "single"
    const theme = useTheme()
    const widths = columnWidths(columns, width)

    // a row of text segments in the colour of the row, the separators in the border colour
    const line = (
        cells: string[],
        lead: string,
        ink: string,
        bold: boolean,
    ): ReactNode => (
        <Text>
            <Text color={ink} bold={bold}>{lead}</Text>
            {cells.map((c, i) => {
                const col = columns[i] as Column<R>
                const w = widths[i] as number
                const cut = truncate(c, w)
                const pad = " ".repeat(Math.max(0, w - displayWidth(cut)))
                const body = col.align === "right" ? pad + cut : padWidth(cut, w)
                return (
                    // biome-ignore lint/suspicious/noArrayIndexKey: a column is its place
                    <Fragment key={i}>
                        {i > 0 ? <Bar style={border} /> : null}
                        <Text color={ink} bold={bold}>{` ${body} `}</Text>
                    </Fragment>
                )
            })}
        </Text>
    )

    const shown = rows.slice(offset, offset + pageSize)
    return (
        <Box flexDirection="column">
            {line(columns.map((c) => c.title), "   ", theme.fg, true)}
            <Rule
                style={border}
                part="mid"
                widths={widths.map((w) => w + 2)}
                options={{ frame: false, lead: 3 }}
            />
            {rows.length === 0 ? (
                <Text color={theme.mt}>{empty ?? "nothing here yet"}</Text>
            ) : null}
            {shown.map((row, i) => {
                const on = offset + i === cursor
                const ink = on || emphasis?.(row) ? theme.fg : theme.mt
                const lead = `${on ? ">" : " "}${mark ? mark(row) : " "} `
                return (
                    // biome-ignore lint/suspicious/noArrayIndexKey: position is the id
                    <Fragment key={offset + i}>
                        {line(columns.map((c) => c.text(row)), lead, ink, on)}
                    </Fragment>
                )
            })}
            {rows.length > pageSize ? (
                <Text color={theme.mt}>{`${cursor + 1} / ${rows.length}`}</Text>
            ) : null}
        </Box>
    )
}
