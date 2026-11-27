// SPDX-License-Identifier: LGPL-3.0-or-later

// Grid: the menu grids every menu screen is built from, and the legend of keys that sits
// under every screen.
//
// Contents:
//   1. Legend: the keys at the bottom of a screen
//   2. Menu options: `MenuSpec`, hotkeys, the menu art (pure)
//   3. Menu header: the logo block above a menu
//   4. `GridMenu`: the grid component with its taskbar

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useEffect, useState } from "react"
import { readAssetText } from "../core/environment.js"
import { displayWidth, padWidth } from "../core/terminal.js"
import {
    arrowKeys,
    type Hotkey,
    type KeyInput,
    keyLabels,
    keys,
    menuOptions,
    NarrowWidth,
    themeLineRows,
    useBodyColumns,
    useKeys,
    useNav,
    useTerminalSize,
} from "./interaction.js"
import { ErrorText, Panel, useTheme } from "./theme.js"

// ========================================================================================
// 1. Legend: the keys at the bottom of a screen
// ========================================================================================

/**
 * One line of a key legend.
 *
 * @property label - what the key does, e.g. `"save"`.
 * @property keys - the key, e.g. `"^w"` (`^` is the Ctrl key) or `"⏎"`.
 */
export type LegendItem = { label: string; keys: string }

/**
 * A legend item whose keys are written from the key constants, so a legend cannot drift
 * from the key it describes.
 *
 * @param label - what the key does, e.g. `"save"`.
 * @param parts - the keys, as for `keyLabels`: a key, or an array written together
 *     (`[keys.up, keys.down]` is `↑↓`).
 * @returns the item.
 * @throws never.
 */
export function legendFor(label: string, ...parts: (Hotkey | Hotkey[])[]): LegendItem {
    return { label, keys: keyLabels(...parts) }
}

/** Back one screen (a legend item nearly every screen has). */
export const legendBack: LegendItem = legendFor("back", keys.back)
/** Choose or edit what the cursor is on. */
export const legendEnter: LegendItem = legendFor("select", keys.enter)

/**
 * The up and down moves of a cursor in a list.
 *
 * @param index - where the cursor is.
 * @param count - the number of rows.
 * @returns up while there is a row above, down while there is a row below.
 */
export function cursorMoves(index: number, count: number): Moves {
    return { up: index > 0, down: index < count - 1 }
}

/**
 * Which arrow keys do something right now.
 *
 * @property up - the cursor can go up.
 * @property down - the cursor can go down.
 * @property left - there is something to the left (a previous group).
 * @property right - there is something to the right (a next group).
 * @property tab - Tab (down) and shift+tab (up) move too: the legend adds `tab` while
 *     down works.
 */
export type Moves = {
    up?: boolean
    down?: boolean
    left?: boolean
    right?: boolean
    tab?: boolean
}

/**
 * The `move` item of a legend, with only the arrows that work from where the cursor is:
 * `↑↓` in the middle of a list, `↓` on its first row, `←→` between groups.
 *
 * @param moves - which arrows work.
 * @returns the item, or `undefined` when no arrow works (nothing to move to).
 */
export function moveLegend(moves: Moves): LegendItem | undefined {
    const arrows = [
        moves.up && keys.up, moves.down && keys.down,
        moves.left && keys.left, moves.right && keys.right,
    ].filter((k): k is Hotkey => k !== false && k !== undefined)
    if (arrows.length === 0) return undefined
    return moves.tab && moves.down
        ? legendFor("move", arrows, keys.tab)
        : legendFor("move", arrows)
}

/**
 * Builds a legend from items that may not apply: a key that does nothing right now is
 * left out, so the legend only lists keys that work.
 *
 * @param items - the items; `false` and `undefined` are skipped, so a screen writes
 *     `canUndo && legendFor("undo", keys.undo)`.
 * @returns the items that remain, in order.
 */
export function legendOf(items: (LegendItem | false | undefined)[]): LegendItem[] {
    return items.filter((item): item is LegendItem => Boolean(item))
}

/**
 * What the legend of an open prompt or dropdown depends on.
 *
 * @property count - how many suggestions it lists now (0 for a plain prompt).
 * @property pick - it is a dropdown: Enter takes the highlighted suggestion, so there
 *     must be one. A prompt takes what is typed.
 * @property canTake - a prompt's Enter has something to take (`true` when left out).
 * @property take - what Enter does, `"take"` when left out; `null` for nothing (not shown).
 * @property extras - keys of this particular overlay (`file picker o`), shown before
 *     `cancel`.
 * @property listedExtras - keys that work only while something is listed (`delete ^r`),
 *     shown after `extras`.
 * @property cancel - what Esc does, `"cancel"` when left out; `null` for nothing (not
 *     shown).
 * @property back - ^x goes back one screen (it differs from Esc), shown last.
 */
export type EntryFacts = {
    count: number
    pick?: boolean
    canTake?: boolean
    take?: string | null
    extras?: LegendItem[]
    listedExtras?: LegendItem[]
    cancel?: string | null
    back?: boolean
}

/**
 * The legend of an open prompt or dropdown: `take` when Enter does something, `move`
 * only when the list has more than one entry, `complete` only when a suggestion is
 * highlighted, then the overlay's own keys, `cancel` and, when it has one, `back`.
 *
 * @param facts - what the overlay is showing.
 * @returns the items, in order.
 */
export function entryLegend(facts: EntryFacts): LegendItem[] {
    const { count, pick = false, canTake = true, take = "take", extras = [] } = facts
    const { listedExtras = [], cancel = "cancel", back = false } = facts
    return legendOf([
        take !== null && (pick ? count > 0 : canTake) && legendFor(take, keys.enter),
        moveLegend({ up: count > 1, down: count > 1 }),
        count > 0 && legendFor("complete", keys.tab),
        ...extras,
        ...(count > 0 ? listedExtras : []),
        cancel !== null && legendFor(cancel, keys.escape),
        back && legendBack,
    ])
}

/** The lines of a column of the legend, the height of the small logo. */
const columnLines = 3

/**
 * The fewest columns a legend that would wrap is cut into (as tall as needed) when they
 * fit.
 */
const longColumns = 3

/** Cuts a list into pieces of `size`; only the last is short (seven items: 3 + 3 + 1).
 *
 * @param items - the list.
 * @param size - the most items in a piece.
 * @returns the pieces, in order.
 */
function chunks<T>(items: T[], size: number): T[][] {
    const out: T[][] = []
    for (let from = 0; from < items.length; from += size)
        out.push(items.slice(from, from + size))
    return out
}

/** The cells a column spends on its `┃` and the gap after it. */
const barCells = 2

/** The cells the labels of a column take (the widest), so its keys line up. */
const labelCells = (column: readonly LegendItem[]): number =>
    Math.max(...column.map((i) => displayWidth(i.label)))

/** The text of one legend item: the label padded to its column, then the keys. */
const itemText = (item: LegendItem, labels: number): string =>
    `${padWidth(`${item.label}:`, labels + 1)} ${item.keys}`

/**
 * The cells the labels of column `j` take over all `bands` (so the keys line up in a
 * grid).
 */
const labelWidths = (bands: LegendItem[][][]): number[] =>
    Array.from({ length: Math.max(...bands.map((b) => b.length)) }, (_, j) =>
        Math.max(...bands.map((b) => (b[j] ? labelCells(b[j]) : 0))))

/** The cells of each column of `bands` (the widest line of the column in any band). */
function columnWidths(bands: LegendItem[][][]): number[] {
    const labels = labelWidths(bands)
    return labels.map((label, j) =>
        Math.max(
            ...bands.flatMap((b) =>
                (b[j] ?? []).map((i) => displayWidth(itemText(i, label))),
            ),
        ))
}

/** The cells a grid of columns takes, with a `┃` and a space either side between them. */
const gridWidth = (widths: number[]): number =>
    widths.reduce((sum, w) => sum + w, 0) + (widths.length - 1) * (barCells + 1)

/**
 * Lays a legend out for some room as a grid: columns of at least three lines (the small
 * logo's height) and at least three columns, in as few lines as fit the width. A legend
 * widens as the room grows (more, shorter columns). One that does not fit in one band is
 * cut into equal bands whose columns line up. The result depends only on items and room, so
 * a screen can reserve the height of its fullest legend ([[legendHeight]]) and its footer
 * never moves.
 *
 * @param items - the legend.
 * @param room - the cells the grid may take (a column wider than that has a band to
 *     itself).
 * @returns the bands, each a list of columns, each column a list of items.
 */
function legendBands(items: readonly LegendItem[], room: number): LegendItem[][][] {
    // the least tall of: a grid of three columns at least, one of two, columns of three
    // lines as they fit (the earlier wins a tie)
    const height = (bands: LegendItem[][][]): number =>
        bands.reduce((sum, band) => sum + Math.max(...band.map((c) => c.length)), 0)
    const options = [
        bestBands(items, room, longColumns),
        bestBands(items, room, longColumns - 1),
        bandsOf(items, room, columnLines),
    ].filter((o): o is LegendItem[][][] => o !== null)
    return options.reduce((best, o) => (height(o) < height(best) ? o : best))
}

/**
 * The bands of the least height whose grid fits `room` with at least `least` columns, or
 * null.
 */
function bestBands(
    items: readonly LegendItem[],
    room: number,
    least: number,
): LegendItem[][][] | null {
    let best: LegendItem[][][] | null = null
    let bestHeight = Number.POSITIVE_INFINITY
    for (let count = 1; count <= items.length; count++) {
        const size = Math.ceil(items.length / count)
        const groups = chunks([...items], size)
        const fewest = least
        for (let lines = Math.min(columnLines, size); lines <= size; lines++) {
            const cols = Math.ceil(size / lines)
            if (cols < fewest) break
            const bands = groups.map((group) => balanced(group, cols))
            // a grid whose columns line up across bands wins a tie with one that does not
            const aligned = gridWidth(columnWidths(bands)) <= room
            const height = count * lines + (aligned ? 0 : 0.5)
            if (height >= bestHeight || !(aligned || bandsFit(bands, room))) continue
            best = bands
            bestHeight = height
        }
    }
    return best
}

/**
 * Whether every band fits `room` on its own (columns then need not line up across
 * bands).
 */
const bandsFit = (bands: LegendItem[][][], room: number): boolean =>
    bands.every((band) => gridWidth(columnWidths([band])) <= room)

/** Cuts a list into `cols` columns, in order, whose lengths differ by at most one. */
function balanced<T>(items: T[], cols: number): T[][] {
    const out: T[][] = []
    const base = Math.floor(items.length / cols)
    const extra = items.length % cols
    let from = 0
    for (let c = 0; c < cols; c++) {
        const n = base + (c < extra ? 1 : 0)
        if (n > 0) out.push(items.slice(from, from + n))
        from += n
    }
    return out
}

/** The bands of a legend cut into columns of `lines` items, as many per band as fit. */
function bandsOf(
    items: readonly LegendItem[],
    room: number,
    lines: number,
): LegendItem[][][] {
    const widthOf = (column: LegendItem[], first: boolean): number =>
        Math.max(...column.map((i) => displayWidth(itemText(i, labelCells(column)))))
        + (first ? 0 : barCells)
    const bands: LegendItem[][][] = []
    let band: LegendItem[][] = []
    let used = 0
    for (const column of chunks([...items], lines)) {
        const w = widthOf(column, band.length === 0)
        if (band.length > 0 && used + 1 + w > room) {
            bands.push(band)
            band = []
            used = 0
        }
        // the first column of a band has no `┃`, so its width is taken again for a new band
        used += (band.length === 0 ? 0 : 1) + widthOf(column, band.length === 0)
        band.push(column)
    }
    if (band.length > 0) bands.push(band)
    return bands
}

/**
 * The lines a legend takes in some room.
 *
 * @param items - the legend.
 * @param room - the cells a band may take.
 * @param style - how it is drawn: a `boxes` legend that fits one row takes three rows,
 *     one that does not is laid out as columns ([[legendBands]]).
 * @returns the height, 0 for no items.
 */
export function legendHeight(
    items: readonly LegendItem[],
    room: number,
    style: LegendStyle = "columns",
): number {
    if (style === "boxes" && items.length > 0 && boxesFit(items, room)) return boxRows
    return legendBands(items, room).reduce(
        (sum, band) => sum + Math.max(...band.map((column) => column.length)),
        0,
    )
}

/**
 * How a legend is drawn: `columns` puts the items in columns separated by `┃` (tables,
 * forms, sheets); `boxes` puts each in a small rounded box in one row (menus and
 * landings). A `boxes` legend too wide for its room is drawn as columns.
 */
export type LegendStyle = "columns" | "boxes"

/** The rows of a box of the `boxes` style: the border above and below, and the text. */
const boxRows = 3

/** The cells of a box of the `boxes` style: the border and the padding on both sides. */
const boxCells = 4

/** The text of one item of a `boxes` legend. */
const boxText = (item: LegendItem): string => `${item.label}: ${item.keys}`

/**
 * Whether a `boxes` legend fits one row of some room.
 *
 * @param items - the legend.
 * @param room - the cells the row may take.
 * @returns the answer (the boxes are one cell apart).
 */
export function boxesFit(items: readonly LegendItem[], room: number): boolean {
    const width = items.reduce((sum, i) => sum + displayWidth(boxText(i)) + boxCells, 0)
    return width + Math.max(0, items.length - 1) <= room
}

/**
 * Keys with what they do, as `label: keys` pairs in the muted colour, in columns or in
 * boxes.
 *
 * @param props.items - the keys to show, in order.
 * @param props.room - the cells the legend may take (`columns` uses as many bands as it
 *     needs, [[legendBands]]).
 * @param props.style - `"columns"` (default) or `"boxes"`.
 * @returns the legend.
 */
export function Legend({
    items,
    room,
    style = "columns",
}: {
    items: LegendItem[]
    room: number
    style?: LegendStyle
}): ReactNode {
    const theme = useTheme()
    if (style === "boxes" && boxesFit(items, room))
        return (
            <Box columnGap={1}>
                {items.map((item) => (
                    <Panel key={item.label} paddingX={1}>
                        <Text color={theme.mt}>{boxText(item)}</Text>
                    </Panel>
                ))}
            </Box>
        )
    const bands = legendBands(items, room)
    // columns line up across bands when the room
    // allows, else each band is as narrow as it is
    const aligned = gridWidth(columnWidths(bands)) <= room
    const labels = aligned ? labelWidths(bands) : null
    const widths = aligned ? columnWidths(bands) : null
    return (
        <Box flexDirection="column">
            {bands.map((band) => {
                // every `┃` is as tall as the tallest column of its band
                const height = Math.max(...band.map((column) => column.length))
                return (
                    <Box key={band[0]?.[0]?.label} columnGap={1}>
                        {band.map((column, i) => (
                            <Box key={column[0]?.label} columnGap={1}>
                                {i > 0 ? (
                                    <Text color={theme.mt}>
                                        {Array(height).fill("┃").join("\n")}
                                    </Text>
                                ) : null}
                                <Box flexDirection="column">
                                    {column.map((item) => (
                                        <Text key={item.label} color={theme.mt}>
                                            {labels && widths
                                                ? padWidth(
                                                    itemText(item, labels[i] ?? 0),
                                                    widths[i] ?? 0,
                                                )
                                                : itemText(item, labelCells(column))}
                                        </Text>
                                    ))}
                                </Box>
                            </Box>
                        ))}
                    </Box>
                )
            })}
        </Box>
    )
}

// ========================================================================================
// 2. Menu options
// ========================================================================================

/** The name of a menu option: one of the keys of `menuOptions`. */
export type MenuOptions = keyof typeof menuOptions

/** An art piece: its text and its size in terminal cells. */
export type Art = {
    text:   string
    width:  number
    height: number
}

/**
 * One loaded menu option: its art piece and the hotkey that selects it. The selected
 * state is drawn with the theme's colours, not a second piece of art.
 *
 * @property hotkey - the key that selects the option.
 */
export type MenuOption = Art & {
    hotkey: Hotkey
}

/**
 * Reads an art piece from a file below `assets/` and measures it.
 *
 * @param path - the folders and the file name below `assets/`, one string each,
 *     e.g. `"logo", "logo-large.txt"`.
 * @returns the text, and its size in terminal cells (`width` is the longest line,
 *     `height` the number of lines).
 * @throws if the file does not exist or cannot be read.
 */
function loadArt(...path: string[]): Art {
    const text = readAssetText(...path)
    const lines = text.split("\n")
    return {
        text,
        width: Math.max(...lines.map((line) => line.length)),
        height: lines.length,
    }
}

/**
 * Loads menu options, each with its art piece, from `assets/menu-options/<name>.txt`.
 * Call it once, at module level: it reads the files from disk each time.
 *
 * @param names - the options to load.
 * @returns a record with exactly the given names as keys, each its [[MenuOption]]; a name
 *     not passed is a type error to look up.
 * @throws if a file cannot be read.
 */
function loadOpts<N extends MenuOptions>(
    names: readonly N[]
): Record<N, MenuOption> {
    // filled below, so the cast says "complete by the return"
    const result = {} as Record<N, MenuOption>
    for (const name of names) {
        result[name] = {
            ...loadArt("menu-options", `${name}.txt`),
            hotkey: menuOptions[name].hotkey,
        }
    }
    return result
}

/**
 * Loads the cursor drawn beside the selected menu item.
 *
 * @returns the cursor art with its size in terminal cells.
 * @throws if `assets/menu-options/cursor.txt` cannot be read.
 */
function menuCursor(): Art { return loadArt("menu-options", "cursor.txt") }

/**
 * Loads the logo shown at the top of the menu.
 *
 * @returns the logo art with its size in terminal cells.
 * @throws if `assets/logo/logo-large.txt` cannot be read.
 */
function menuLogo(): Art { return loadArt("logo", "logo-large.txt") }

/** The small logo of the screens below the menus: `blocky` on tables, else `smooth`. */
export type Design = "blocky" | "smooth"

/**
 * Loads a small logo.
 *
 * @param design - which of the two.
 * @returns the logo art with its size in terminal cells.
 * @throws if `assets/logo/logo-<design>.txt` cannot be read.
 */
export function smallLogo(design: Design): Art {
    return loadArt("logo", `logo-small-${design}.txt`)
}

// ========================================================================================
// 3. Menu header
// ========================================================================================

/** The logo, loaded once: it is read from disk. */
const logo = menuLogo()

/** The rows a [[MenuHeader]] takes: the logo and the line under it. */
const menuHeaderRows = logo.height + 1

/**
 * What the top of a menu shows: the BAYSOL logo, centred, with one line under it (the
 * version, the project's name, ...). It has no margin: the `GridMenu` adds one when the
 * terminal has room.
 *
 * @param caption - the line under the logo.
 * @returns the header, to pass to a `GridMenu`.
 */
export function MenuHeader({ caption }: { caption: string }): ReactNode {
    const theme = useTheme()
    return (
        <Box flexDirection="column" alignItems="center">
            <Box width={logo.width} height={logo.height} flexShrink={0}>
                <Text color={theme.fg}>{logo.text}</Text>
            </Box>
            <Text color={theme.mt}> {caption} </Text>
        </Box>
    )
}

// ========================================================================================
// 4. GridMenu
// ========================================================================================

/** The blank columns between the cursor and the text of an option. */
const cursorGap = 2

/** The rows of the move-hint art (arrows on three lines). */
const hintArtHeight = 3

/** The border rows of the `Panel` around the hint art, top and bottom. */
const hintBorderRows = 2

/** The most cells an open prompt or list takes: it is a dropdown, not half the screen. */
const overlayMaxWidth = 44

/** The rows the hint box (or the legend of an open overlay) takes at the bottom. */
const hintRows = hintArtHeight + hintBorderRows

/** The blank row above the header and the one between the header and the grid. */
const marginRows = 2

/** The row reserved for a notice under the grid. */
const noticeRows = 1

/** How long a hotkey waits, in milliseconds, before it chooses its option. */
const hotkeyDelay = 50

/** The four arrow keys, the names of the moves a grid allows. */
type Direction = "up" | "down" | "left" | "right"

/**
 * A menu laid out on a grid: its options in order and their art (pictures, cursor, one
 * move hint per position). Built once, at module level, because it reads its art from
 * disk.
 *
 * Positions count from the top-left, a row at a time; the last row may be short. The
 * move hint (`hint`) is drawn from the arrows the grid allows.
 * @typeParam N - the names of the options.
 * @param names - the options, row by row, each with art in `assets/menu-options/`.
 * @param columns - how many options a row has.
 * @throws if a file of the art cannot be read.
 */
export class MenuSpec<N extends MenuOptions> {
    readonly opts:    Record<N, MenuOption>
    readonly cursor:  Art
    /** The width of one cell (cursor, gap, widest piece); every cell uses it. */
    readonly cellWidth: number

    constructor(readonly names: readonly N[], readonly columns: number) {
        this.opts    = loadOpts(names)
        this.cursor  = menuCursor()
        this.cellWidth =
            Math.max(...names.map((n) => this.opts[n].width)) +
            this.cursor.width +
            cursorGap
    }

    /**
     * The option the cursor goes to for an arrow key.
     *
     * @param from - the option the cursor is on.
     * @param direction - the arrow key.
     * @returns the neighbour in that direction, or `undefined` at the edge of the grid.
     */
    neighbour(from: N, direction: Direction): N | undefined {
        const i = this.names.indexOf(from)
        const col = i % this.columns
        const target = {
            up:    i - this.columns,
            down:  i + this.columns,
            left:  col > 0 ? i - 1 : -1,
            right: col < this.columns - 1 ? i + 1 : -1,
        }[direction]
        return this.names[target]
    }

    /**
     * The hint that shows the arrows possible from an option: an arrow where the cursor
     * can go that way, a blank where it cannot.
     *
     * @param name - the option the cursor is on.
     * @returns its art, 5 cells wide and 3 high.
     */
    hint(name: N): Art {
        const go = (d: Direction, arrow: string) => (this.neighbour(name, d) ? arrow : " ")
        const text = [
            `  ${go("up", keys.up.label)}  `,
            `${go("left", keys.left.label)}   ${go("right", keys.right.label)}`,
            `  ${go("down", keys.down.label)}  `,
        ].join("\n")
        return { text, width: 5, height: hintArtHeight }
    }

    /**
     * The option a key is the hotkey of.
     *
     * @param press - the key press.
     * @returns the option, or `undefined` if the key is no option's hotkey.
     */
    byHotkey(press: KeyInput): N | undefined {
        return this.names.find((n) => press.is(this.opts[n].hotkey))
    }

    /** The rows the options take when drawn: the tallest art of each row, added up. */
    get gridHeight(): number {
        return this.rows.reduce(
            (sum, row) => sum + Math.max(...row.map((name) => this.opts[name].height)),
            0,
        )
    }

    /** The options cut into rows of `columns`, for drawing. */
    get rows(): N[][] {
        const rows: N[][] = []
        for (let i = 0; i < this.names.length; i += this.columns)
            rows.push(this.names.slice(i, i + this.columns))
        return rows
    }
}

/** The arrow keys and the move each one asks for. */
const arrowMoves: [Hotkey, Direction][] = [
    [arrowKeys.up, "up"], [arrowKeys.down, "down"],
    [arrowKeys.left, "left"], [arrowKeys.right, "right"],
]

/**
 * One option of the grid: the cursor slot (always reserved, so the text does not move)
 * and the text, full foreground when active, else muted.
 *
 * @param spec - the menu the option belongs to.
 * @param name - the option to draw.
 * @param active - whether the cursor is on this option.
 * @returns the cell, `spec.cellWidth` wide and as tall as the option's art.
 */
function Cell<N extends MenuOptions>(
    { spec, name, active }: { spec: MenuSpec<N>; name: N; active: boolean }
): ReactNode {
    const theme = useTheme()
    return (
        <Box width={spec.cellWidth} height={spec.opts[name].height} flexShrink={0}>
            {/* stateful cursor */}
            <Box width={spec.cursor.width} flexShrink={0} marginRight={cursorGap}>
                {active ? <Text color={theme.fg}>{spec.cursor.text}</Text> : null}
            </Box>

            {/* stateful text */}
            <Text color={active ? theme.fg : theme.mt}>{spec.opts[name].text}</Text>
        </Box>
    )
}

/**
 * One taskbar action: its name and key as the legend shows them, and what it does.
 *
 * @property label - what it does, e.g. `"run"`.
 * @property key - its hotkey, normally a Shift key (see `KeyInput.is`).
 * @property onPress - called when the key is pressed.
 */
export type TaskbarItem = { label: string; key: Hotkey; onPress: () => void }

/**
 * What the grid menu is told.
 *
 * @property spec - the menu: its options and art.
 * @property header - what goes above the grid (the logo, a title).
 * @property onChoose - called when an option is chosen, by Enter or by its hotkey.
 * @property taskbar - extra actions that apply right now, shown beside the move hint,
 *     each a hotkey of the menu. The room is always reserved, so the grid never moves.
 *     Esc does nothing at menu level: the only way out of the program is `q` in the main
 *     menu (and ^c / ^d, handled by the app).
 * @property taskbarNote - a small box in the taskbar's corner while there is no item,
 *     e.g. `missing components: models, data`.
 * @property onKey - called, with the option the cursor is on, for every other key press
 *     (keys a menu adds); not called while a hotkey is waiting.
 * @property intercept - called first with every key press; returns `true` when it took
 *     the press (an open question), and the menu then does nothing with it.
 * @property legend - extra text for the hint box, e.g. `"reset file: r"`; a function
 *     gets the option the cursor is on, so the text can follow the cursor.
 * @property notice - a line shown under the grid (an error, e.g. `no projects to load!`);
 *     the menu keeps taking keys.
 * @property noticeIsError - the notice is a problem, drawn on the error background
 *     (true when left out); `false` for plain information.
 * @property overlayLegend - the keys of the open overlay, shown in place of the move hint.
 * @property overlay - a prompt or dropdown over the grid. While one is given the menu
 *     takes no keys: the overlay listens.
 */
type GridMenuProps<N extends MenuOptions> = {
    spec:      MenuSpec<N>
    header?:   ReactNode
    onChoose:  (name: N) => void
    taskbar?:  TaskbarItem[]
    taskbarNote?: string
    onKey?:    (press: KeyInput, selected: N) => void
    intercept?: (press: KeyInput) => boolean
    legend?:   string | ((selected: N) => string | undefined)
    notice?:   string
    noticeIsError?: boolean
    overlay?:  ReactNode
    overlayLegend?: LegendItem[]
}

/**
 * A menu of options on a grid, moved with the arrow keys, chosen with Enter or a hotkey,
 * left with ^x (back); Esc does nothing here. A hotkey first moves the cursor and
 * chooses after `hotkeyDelay`, so the highlight is seen before the screen changes.
 *
 * @param props - see [[GridMenuProps]].
 * @returns the menu: header, grid, and the hint box at the bottom.
 */
export function GridMenu<N extends MenuOptions>(props: GridMenuProps<N>): ReactNode {
    const {
        spec,
        header,
        onChoose,
        taskbar,
        taskbarNote,
        onKey,
        intercept,
        legend,
        overlay,
        overlayLegend,
        notice,
        noticeIsError = true,
    } = props
    const theme = useTheme()
    const nav = useNav()
    const [selected, setSelected] = useState<N>(spec.names[0])
    const [pending, setPending] = useState<N | null>(null)
    const legendText = typeof legend === "function" ? legend(selected) : legend

    // a hotkey chooses its option after `hotkeyDelay`; the cleanup cancels the timer
    useEffect(() => {
        if (pending === null) return
        const timer = setTimeout(() => {
            onChoose(pending)
            setPending(null)
        }, hotkeyDelay)
        return () => clearTimeout(timer)
    }, [pending, onChoose])

    /** Selects an option now and chooses it after the delay. */
    const jumpTo = useCallback((name: N) => {
        setSelected(name)
        setPending(name)
    }, [])

    useKeys((press) => {
        if (intercept?.(press)) return
        const action = taskbar?.find((item) => press.is(item.key))
        // while a hotkey waits to choose its option, ignore every key
        if (pending !== null) return

        if (press.is(keys.enter)) onChoose(selected)
        else if (press.is(keys.back)) nav.pop()
        else if (action) action.onPress()
        else {
            const move = arrowMoves.find(([key]) => press.is(key))
            const next = move && spec.neighbour(selected, move[1])
            const hot  = spec.byHotkey(press)
            if (next) setSelected(next)
            else if (hot) jumpTo(hot)
            else onKey?.(press, selected)
        }
    }, overlay === undefined)

    // the two blank rows (above the header and the grid) go when the terminal is too
    // short, so the notice never lands on the art
    const { rows: terminalRows, columns: terminalColumns } = useTerminalSize()
    const bodyColumns = useBodyColumns()
    const overlayWidth = Math.min(Math.floor(bodyColumns / 2), overlayMaxWidth)
    const fixedRows = menuHeaderRows + noticeRows + hintRows + themeLineRows
    const needed = fixedRows + spec.gridHeight + marginRows
    const margin = terminalRows >= needed ? 1 : 0

    const hint = spec.hint(selected)
    return (
        <Box flexDirection="column" alignItems="center" flexGrow={1}>

            <Box marginTop={margin}>{header}</Box>

            {/* options grid: it takes all the room between the header and the hint, the
                rows spread down it and the cells across the whole width */}
            <Box
                flexDirection="column"
                flexGrow={1}
                width="100%"
                justifyContent="space-around"
                marginTop={margin}
            >
                {spec.rows.map((row) => (
                    <Box key={row[0]} width="100%" justifyContent="space-around">
                        {row.map((name) => (
                            <Cell
                                key={name}
                                spec={spec}
                                name={name}
                                active={selected === name}
                            />
                        ))}
                    </Box>
                ))}

                {/* an open prompt or list covers only the right half of the grid, so the
                    left stays in view and the grid never moves */}
                {overlay !== undefined ? (
                    <Box
                        position="absolute"
                        top={0}
                        right={0}
                        bottom={0}
                        width={Math.floor(bodyColumns / 2)}
                        backgroundColor={theme.bg}
                        justifyContent="center"
                    >
                        <Panel
                            flexDirection="column"
                            alignSelf="flex-start"
                            width={overlayWidth}
                            paddingX={1}
                        >
                            {/* the panel's width, less the border and the padding */}
                            <NarrowWidth.Provider value={overlayWidth - 4}>
                                {overlay}
                            </NarrowWidth.Provider>
                        </Panel>
                    </Box>
                ) : null}
            </Box>

            {/* the notice has a row of its own, so showing one never moves the grid */}
            <Box height={1} flexShrink={0}>
                {noticeIsError ? (
                    <ErrorText>{notice}</ErrorText>
                ) : (
                    <Text color={theme.fg}>{notice}</Text>
                )}
            </Box>

            {/* the move hint, or the keys of an overlay: the same height either way */}
            <Box
                height={hintRows}
                width={taskbar ? "100%" : undefined}
                flexShrink={0}
                flexDirection="column"
                justifyContent="flex-end"
            >
                {overlay !== undefined && overlayLegend ? (
                    <Legend items={overlayLegend} room={terminalColumns} style="boxes" />
                ) : (
                    <Box
                        width="100%"
                        paddingX={taskbar ? 1 : 0}
                        justifyContent={taskbar ? "space-between" : "center"}
                    >
                        <Panel borderColor={theme.mt} alignItems="center" columnGap={1}>
                            <Text color={theme.mt}>move:</Text>
                            <Box width={hint.width} height={hint.height} flexShrink={0}>
                                <Text color={theme.mt}>{hint.text}</Text>
                            </Box>
                            <Text color={theme.mt}>
                                {`    select: ${keys.enter.label}` +
                                    (nav.depth > 1 ? `    back: ${keys.back.label}` : "")}
                                {legendText ? `    ${legendText}` : ""}
                            </Text>
                        </Panel>

                        {/* the taskbar: only what applies now */}
                        {taskbar && taskbar.length === 0 && taskbarNote ? (
                            <Panel borderColor={theme.mt} paddingX={1} flexShrink={1}>
                                <Text color={theme.mt} wrap="truncate-end">
                                    {taskbarNote}
                                </Text>
                            </Panel>
                        ) : taskbar ? (
                            <Box justifyContent="flex-end" alignItems="flex-end">
                                <Legend
                                    items={taskbar.map((i) => legendFor(i.label, i.key))}
                                    room={terminalColumns}
                                />
                            </Box>
                        ) : null}
                    </Box>
                )}
            </Box>
        </Box>
    )
}
