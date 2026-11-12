// SPDX-License-Identifier: LGPL-3.0-or-later

// Grid: the menu grids every menu screen is built from, and the legend of keys that sits
// under every screen.
//
// Contents:
//   1. Legend: the keys at the bottom of a screen
//   2. Menu options: `MenuSpec`, hotkeys, the menu art (pure)
//   3. Menu header: the logo block above a menu
//   4. `GridMenu`: the grid component with its taskbar

import { readFileSync } from "node:fs"
import { Box, Text } from "ink"
import { type ReactNode, useCallback, useEffect, useState } from "react"
import { assetPath } from "../core/environment.js"
import { displayWidth, padWidth } from "../core/terminal.js"
import {
    type KeyInput,
    keyLabels,
    keys,
    NarrowWidth,
    plainKey,
    themeLineRows,
    useBodyColumns,
    useKeys,
    useNav,
    useTerminalSize,
} from "./interaction.js"
import { Panel, useTheme } from "./theme.js"

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
 * A legend item whose keys are written from the key constants, so a legend cannot
 * drift from the key it describes.
 *
 * @param label - what the key does, e.g. `"save"`.
 * @param parts - the keys, as for `keyLabels`: a key, or an array for a run written
 *     together (`[keys.up, keys.down]` is `↑↓`).
 * @returns the item.
 * @throws never.
 */
export function legendFor(label: string, ...parts: (KeyInput | KeyInput[])[]): LegendItem {
    return { label, keys: keyLabels(...parts) }
}

/** The legend items that nearly every screen has. */
/** Back one screen. */
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
 * @property tab - Tab (down) and Shift+Tab (up) move too: the legend adds `tab` while
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
 * The `move` item of a legend, with only the arrows that work from where the cursor
 * is (like the move hint of the menus): `↑↓` in the middle of a list, `↓` on its first
 * row, `←→` between groups.
 *
 * @param moves - which arrows work.
 * @returns the item, or `undefined` when no arrow works (nothing to move to).
 */
export function moveLegend(moves: Moves): LegendItem | undefined {
    const arrows = [
        moves.up && keys.up, moves.down && keys.down,
        moves.left && keys.left, moves.right && keys.right,
    ].filter((k): k is KeyInput => k !== false && k !== undefined)
    if (arrows.length === 0) return undefined
    return moves.tab && moves.down
        ? legendFor("move", arrows, keys.tab)
        : legendFor("move", arrows)
}

/**
 * Builds a legend from items that may not apply: a key that does nothing right now (undo
 * with nothing to undo, remove on an empty table) is left out, so the legend only ever
 * lists keys that work, as the move hint of the menus does.
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
 * @property take - what Enter does, `"take"` when left out; `null` when Enter does
 *     nothing (a list that is only browsed), so it is not shown.
 * @property extras - keys of this particular overlay (`file picker o`), shown before
 *     `cancel`.
 * @property listedExtras - keys that work only while something is listed (`delete ^r`),
 *     shown after `extras`.
 * @property cancel - what Esc does, `"cancel"` when left out; `null` when Esc does
 *     nothing (a prompt that is the screen itself), so it is not shown.
 * @property back - Ctrl-X goes back one screen (it differs from Esc), shown last.
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
 * Cuts a list into pieces of `size`, filled from the left, so only the last piece is
 * short (seven items are 3 + 3 + 1).
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
 * Lays a legend out for some room. The items go in columns of up to three lines (the
 * height of the small logo) and the columns in as few bands as fit the width: a band is a
 * row of columns, a legend that does not fit one band takes more of them, one under the
 * other, so a legend with many keys grows downwards and never wider than its room. The
 * result depends only on the items and the room, so a screen can reserve the height of its
 * fullest legend ([[legendHeight]]) and its footer then never moves.
 *
 * @param items - the legend.
 * @param room - the cells a band may take (a column wider than that has a band to itself).
 * @returns the bands, each a list of columns, each column a list of items.
 */
function legendBands(items: readonly LegendItem[], room: number): LegendItem[][][] {
    const widthOf = (column: LegendItem[], first: boolean): number =>
        Math.max(...column.map((i) => displayWidth(itemText(i, labelCells(column)))))
        + (first ? 0 : barCells)
    const bands: LegendItem[][][] = []
    let band: LegendItem[][] = []
    let used = 0
    for (const column of chunks([...items], columnLines)) {
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
 * @param style - how it is drawn: a `boxes` legend that fits one row takes the three rows
 *     of its boxes (the height of the small logo), one that does not fit is laid out as
 *     columns, so it takes what [[legendBands]] says.
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
 * forms and sheets); `boxes` puts each item in a small rounded box of its own, in one
 * row (the menus and landings, whose footer has three rows for it). A `boxes` legend
 * too wide for its room is drawn as columns, so it never overflows.
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
 * Keys with what they do, as `label: keys` pairs, in the muted colour: in columns
 * separated by `┃`, or each in a rounded box of its own.
 *
 * @param props.items - the keys to show, in order.
 * @param props.room - the cells the legend may take; the `columns` style lays itself out
 *     in as many bands under one another as that needs ([[legendBands]]).
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
    return (
        <Box flexDirection="column">
            {legendBands(items, room).map((band) => {
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
                                            {itemText(item, labelCells(column))}
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

/**
 * Every menu option and its hotkey. Its keys are the allowed option names
 * ([[MenuOptions]]), and each name must have a `<name>.txt` in
 * `assets/menu-options/`.
 */
const menuOptions = {
    buffer:   { hotkey: plainKey("b") },
    data:     { hotkey: plainKey("d") },
    help:     { hotkey: plainKey("h") },
    load:     { hotkey: plainKey("l") },
    logs:     { hotkey: plainKey("g") },
    models:   { hotkey: plainKey("m") },
    new:      { hotkey: plainKey("n") },
    open:     { hotkey: plainKey("o") },
    output:   { hotkey: plainKey("u") },
    plots:    { hotkey: plainKey("p") },
    quit:     { hotkey: plainKey("q") },
    recipes:  { hotkey: plainKey("y") },
    sampler:  { hotkey: plainKey("a") },
    settings: { hotkey: plainKey("s") },
    solutes:  { hotkey: plainKey("t") },
} as const satisfies Record<string, { hotkey: KeyInput }>

/** The name of a menu option: one of the keys of `menuOptions`. */
export type MenuOptions = keyof typeof menuOptions

/** An art piece: its text and its size in terminal cells. */
export type Art = {
    text:   string
    width:  number
    height: number
}

/**
 * One loaded menu option: its art piece (`text`, `width`, `height`) and the
 * hotkey that selects it. The selected state is drawn with the theme's colours,
 * not with a second piece of art.
 *
 * @property hotkey - the key that selects the option.
 */
export type MenuOption = Art & {
    hotkey: KeyInput
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
    const text = readFileSync(assetPath(...path), "utf-8")
    const lines = text.split("\n")
    return {
        text,
        width: Math.max(...lines.map((line) => line.length)),
        height: lines.length,
    }
}

/**
 * Loads menu options, each with its art piece, from
 * `assets/menu-options/<name>.txt`.
 *
 * Call it once, at module level: it reads the files from disk each time.
 *
 * @param names - the options to load.
 * @returns a record with exactly the given names as keys, each mapping to its
 *     [[MenuOption]]: its art with its size, and its hotkey. A name that was not
 *     passed is a type error to look up, and a passed one is never `undefined`.
 * @throws if a file cannot be read.
 */
function loadOpts<N extends MenuOptions>(
    names: readonly N[]
): Record<N, MenuOption> {
    // starts empty and is filled below, so the cast says "complete by the return"
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

/**
 * The small BAYSOL logo at the bottom left of the screens below the menus: `blocky`
 * (square corners) on the table-style screens, `smooth` (rounded) on the others.
 */
export type Design = "blocky" | "smooth"

/**
 * Loads a small logo.
 *
 * @param design - which of the two.
 * @returns the logo art with its size in terminal cells.
 * @throws if `assets/logo/logo-<design>.txt` cannot be read.
 */
export function smallLogo(design: Design): Art {
    return loadArt("logo", `logo-${design === "smooth" ? "small" : design}.txt`)
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
 * version on the main menu, the project's name on the project menu, ...).
 *
 * It has no margin of its own: the `GridMenu` that shows it puts one above it when
 * the terminal has room for it.
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
 * A menu laid out on a grid: which options it has, in which order, and the art that
 * goes with them (the option pictures, the cursor, one move hint per grid position).
 * It is built once, at module level, because it reads its art from disk.
 *
 * Positions count from the top-left, one row at a time; the last row may be short.
 * The arrows allowed from a position follow from the grid, and the move hint is drawn
 * from exactly those (`hint`), so it is always right for the option the cursor is on.
 *
 * @typeParam N - the names of the options.
 * @param names - the options, row by row, each with art in `assets/menu-options/`.
 * @param columns - how many options a row has.
 * @throws if a file of the art cannot be read.
 */
export class MenuSpec<N extends MenuOptions> {
    readonly opts:    Record<N, MenuOption>
    readonly cursor:  Art
    /**
     * The width of one cell: the cursor, the gap, and the widest piece. Every cell uses
     * it, so the columns mirror each other and the gap between them is in the middle.
     */
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
     * The hint that shows the arrows possible from an option: an arrow where the
     * cursor can go that way, a blank where it cannot. It is drawn from the grid, so
     * it follows the options there are (a short last row, a lone option).
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
const arrowKeys: [KeyInput, Direction][] = [
    [keys.up, "up"], [keys.down, "down"], [keys.left, "left"], [keys.right, "right"],
]

/**
 * One option of the grid: the cursor slot and the text.
 *
 * The slot is always reserved, so the text does not move when the cursor does.
 * The cursor is drawn, and the text is in the full foreground colour, when the
 * option is active. Otherwise the text is muted.
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
export type TaskbarItem = { label: string; key: KeyInput; onPress: () => void }

/**
 * What the grid menu is told.
 *
 * @property spec - the menu: its options and art.
 * @property header - what goes above the grid (the logo, a title).
 * @property onChoose - called when an option is chosen, by Enter or by its hotkey.
 * @property taskbar - extra actions that apply right now, shown as keys beside
 *     the move hint and each a hotkey of the menu. The screen passes an item only when
 *     it applies; the room for the keys is always reserved, so the grid never moves
 *     when items come and go. Esc does nothing at menu level: the only way out of the
 *     program is `q` in the main menu (and Ctrl-C / Ctrl-D, handled by the app).
 * @property taskbarNote - a small box in the taskbar's corner while there is no taskbar
 *     item, e.g. `missing components: models, data`; the box goes when items appear.
 * @property onKey - called, with the option the cursor is on, for every other key press,
 *     for the keys a menu adds (the settings menu's reset of an unusable file); not
 *     called while a hotkey is waiting.
 * @property intercept - called first with every key press; returns `true` when it took
 *     the press (an open question), and the menu then does nothing with it.
 * @property legend - extra text for the hint box, e.g. `"reset file: r"`; a function
 *     gets the option the cursor is on, so the text can follow the cursor.
 * @property notice - a line shown under the grid (an error, e.g. `no projects to load!`);
 *     the menu keeps taking keys.
 * @property overlayLegend - the keys of the open overlay, shown in place of the move
 *     hint while an overlay is open (so the hint box never lists keys that do nothing).
 * @property overlay - a prompt or dropdown to show in place of the hint box. While one
 *     is given the menu takes no keys, because the overlay is the one that listens.
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
    overlay?:  ReactNode
    overlayLegend?: LegendItem[]
}

/**
 * A menu of options on a grid, moved with the arrow keys, chosen with Enter or with a
 * hotkey, and left with Ctrl-X (back); Esc does nothing here. The main menu, the project
 * menu and the settings menu are all this component with a different [[MenuSpec]].
 *
 * A hotkey first moves the cursor to its option and chooses it after `hotkeyDelay`, so
 * the highlight is seen before the screen changes.
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
            const move = arrowKeys.find(([key]) => press.is(key))
            const next = move && spec.neighbour(selected, move[1])
            const hot  = spec.byHotkey(press)
            if (next) setSelected(next)
            else if (hot) jumpTo(hot)
            else onKey?.(press, selected)
        }
    }, overlay === undefined)

    // the two blank rows (above the header, above the grid) are decoration: they go
    // when the terminal is too short to fit them with everything else, so the notice
    // never lands on the art
    const { rows: terminalRows, columns: terminalColumns } = useTerminalSize()
    const bodyColumns = useBodyColumns()
    const overlayWidth = Math.min(Math.floor(bodyColumns / 2), overlayMaxWidth)
    const fixedRows = menuHeaderRows + noticeRows + hintRows + themeLineRows
    const needed = fixedRows + spec.gridHeight + marginRows
    const margin = terminalRows >= needed ? 1 : 0

    const hint = spec.hint(selected)
    return (
        <Box flexDirection="column" alignItems="center" flexGrow={1}>

            {/* header: the logo and version, or a title */}
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

                {/* an open prompt or list covers the whole right-hand column of the grid
                    (the right half, as high as the grid) and nothing else, so the left
                    column stays in view and opening it never moves the grid */}
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

            {/* the notice has a row of its own at all times, so showing one never moves
                the grid */}
            <Box height={1} flexShrink={0}>
                {notice ? <Text color={theme.er}>{notice}</Text> : null}
            </Box>

            {/* move hint: the arrows that work from the selected option, and the keys */}
            {/* the same height whether it shows the hint or the keys of an overlay, so
                opening an overlay never changes the room the grid has */}
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

                        {/* the taskbar: only what applies now; its corner of the hint
                            area is always there, so nothing else moves */}
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
