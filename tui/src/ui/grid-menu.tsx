// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text, useWindowSize } from "ink"
import { type ReactNode, useCallback, useEffect, useState } from "react"
import { type KeyInput, keys } from "./keys.js"
import { themeLineRows } from "./layout.js"
import { Legend, type LegendItem, legendFor } from "./legend.js"
import { menuHeaderRows } from "./menu-header.js"
import {
    type Art,
    loadOpts,
    type MenuOption,
    type MenuOptions,
    menuCursor,
} from "./menu-opts.js"
import { useNav } from "./nav.js"
import { Panel } from "./panel.js"
import { useTheme } from "./theme.js"
import { useKeys } from "./use-keys.js"

/** The blank columns between the cursor and the text of an option. */
const cursorGap = 2

/** The rows of the move-hint art (arrows on three lines). */
const hintArtHeight = 3

/** The border rows of the `Panel` around the hint art, top and bottom. */
const hintBorderRows = 2

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
 * The taskbar item a press is the key of. A Shift key is tested before a plain one
 * because a capital press matches both (`D` is `results`, `d` is the `data` option):
 * the menu calls this before it looks at the option hotkeys.
 *
 * @param items - the items the screen passes.
 * @param press - the key press.
 * @returns the item, or `undefined` when the press is none of them.
 */
export function taskbarItemFor(
    items: readonly TaskbarItem[], press: KeyInput
): TaskbarItem | undefined {
    return items.find((item) => item.key.shift && press.is(item.key))
        ?? items.find((item) => press.is(item.key))
}

/** The legend items of a taskbar, in order, each as `label: key`. */
export function taskbarLegend(items: readonly TaskbarItem[]): LegendItem[] {
    return items.map((item) => legendFor(item.label, item.key))
}

/**
 * What the grid menu is told.
 *
 * @property spec - the menu: its options and art.
 * @property header - what goes above the grid (the logo, a title).
 * @property onChoose - called when an option is chosen, by Enter or by its hotkey.
 * @property taskbar - extra actions that apply right now, shown as small boxes beside
 *     the move hint and each a hotkey of the menu. The screen passes an item only when
 *     it applies; the room for the boxes is always reserved, so the grid never moves
 *     when items come and go. Esc does nothing at menu level: the only way out of the
 *     program is `q` in the main menu (and Ctrl-C / Ctrl-D, handled by the app).
 * @property onKey - called for every other key press, for the keys a menu adds (the
 *     settings menu's Ctrl-E); not called while a hotkey is waiting.
 * @property legend - extra text for the hint box, e.g. `"custom solutes: ^e"`.
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
    onKey?:    (press: KeyInput) => void
    legend?:   string
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
        onKey,
        legend,
        overlay,
        overlayLegend,
        notice,
    } = props
    const theme = useTheme()
    const nav = useNav()
    const [selected, setSelected] = useState<N>(spec.names[0])
    const [pending, setPending] = useState<N | null>(null)

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
        const action = taskbarItemFor(taskbar ?? [], press)
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
            else onKey?.(press)
        }
    }, overlay === undefined)

    // the two blank rows (above the header, above the grid) are decoration: they go
    // when the terminal is too short to fit them with everything else, so the notice
    // never lands on the art
    const { rows: terminalRows } = useWindowSize()
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
                    <Box position="absolute" top={0} right={0} bottom={0} width="50%">
                        <Panel flexDirection="column" flexGrow={1} paddingX={1}>
                            {overlay}
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
                    <Legend items={overlayLegend} style="boxes" />
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
                                {legend ? `    ${legend}` : ""}
                            </Text>
                        </Panel>

                        {/* the taskbar: only what applies now; its corner of the hint
                            area is always there, so nothing else moves */}
                        {taskbar ? (
                            <Box justifyContent="flex-end" alignItems="flex-end">
                                <Legend items={taskbarLegend(taskbar)} style="boxes" />
                            </Box>
                        ) : null}
                    </Box>
                )}
            </Box>
        </Box>
    )
}
