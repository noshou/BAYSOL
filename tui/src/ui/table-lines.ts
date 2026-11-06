// SPDX-License-Identifier: LGPL-3.0-or-later

// The lines of every table of the program: one set of box-drawing characters for the
// thin (`single`) and the `double` kind, and the pure functions that build a rule from
// the widths of the columns. A table draws each line through here and in the border
// colour (`ui/table-segments.tsx`), so no table spells a box-drawing character itself.

/** The kinds of line a table is drawn with. */
export type LineStyle = "single" | "double"

/** The kinds of horizontal rule: above the first row, between rows, below the last. */
export type RulePart = "top" | "mid" | "bottom"

/**
 * The characters of one line style.
 *
 * @property horizontal - the horizontal line.
 * @property vertical - the vertical line.
 * @property top - left corner, tee and right corner of the top rule.
 * @property mid - left tee, cross and right tee of a rule between rows.
 * @property bottom - left corner, tee and right corner of the bottom rule.
 */
export type LineSet = {
    horizontal: string
    vertical:   string
    top:        readonly [string, string, string]
    mid:        readonly [string, string, string]
    bottom:     readonly [string, string, string]
}

/** The character set of each [[LineStyle]]. */
export const lineSets: Record<LineStyle, LineSet> = {
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
}

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
export function ruleLine(
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

/**
 * `n` lines of the vertical line of a table, for a column of separators beside a block
 * of several lines.
 *
 * @param style - the line style.
 * @param n - how many lines.
 * @returns the lines joined with newlines.
 */
export function columnBar(style: LineStyle, n: number): string {
    return Array.from({ length: n }, () => lineSets[style].vertical).join("\n")
}
