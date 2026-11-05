// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text } from "ink"
import { type ReactNode, useCallback, useEffect, useState } from "react"
import { type KeyInput, keys } from "./keys.js"
import {
    type Art,
    type ArrowLayout,
    loadOpts,
    type MenuOption,
    type MenuOptions,
    menuArrows,
    menuCursor,
} from "./menu-opts.js"
import { useTheme } from "./theme.js"
import { useNav } from "./nav.js"
import { useKeys } from "./use-keys.js"

/** The blank columns between the cursor and the text of an option. */
const cursorGap = 2

/** The blank columns between the two columns of the grid. */
const columnGap = 2

/** How long a hotkey waits, in milliseconds, before it chooses its option. */
const hotkeyDelay = 50

/** The four arrow keys, the names of the moves a grid allows. */
type Direction = "up" | "down" | "left" | "right"

/**
 * A menu laid out on a grid: which options it has, in which order, and the art that
 * goes with them (the option pictures, the cursor, one move hint per grid position).
 * It is built once, at module level, because it reads its art from disk.
 *
 * Positions count from the top-left, one row at a time. The arrows allowed from a
 * position follow from the grid, and the hint of position n (`menuArrows`) shows
 * exactly those, so the grid must be full: its shape is `columns` by
 * `names.length / columns`.
 *
 * @typeParam N - the names of the options.
 * @param names - the options, row by row, each with art in `assets/menu-options/`.
 * @param layout - the grid shape with move hints, `"2x2"` or `"2x3"` (columns x rows).
 * @throws if the number of options is not the number of positions of `layout`, or
 *     a file of the art cannot be read.
 */
export class MenuSpec<N extends MenuOptions> {
    readonly columns: number
    readonly opts:    Record<N, MenuOption>
    readonly cursor:  Art
    private readonly hints: Art[]

    /**
     * The width of one cell: the cursor, the gap, and the widest piece. Every cell uses
     * it, so the columns mirror each other and the gap between them is in the middle.
     */
    readonly cellWidth: number

    constructor(readonly names: readonly N[], layout: ArrowLayout) {
        this.columns = Number(layout.split("x")[0])
        this.opts    = loadOpts(names)
        this.cursor  = menuCursor()
        this.hints   = menuArrows(layout)
        if (this.hints.length !== names.length)
            throw new Error(`a ${layout} grid has ${this.hints.length} options, not ${names.length}`)
        this.cellWidth =
            Math.max(...names.map((n) => this.opts[n].width)) + this.cursor.width + cursorGap
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
     * The hint that shows the arrows possible from an option.
     *
     * @param name - the option the cursor is on.
     * @returns its art.
     */
    hint(name: N): Art {
        return this.hints[this.names.indexOf(name)]
    }

    /**
     * The option a key is the hotkey of.
     *
     * @param press - the key press.
     * @returns the option, or `undefined` if the key is no option's hotkey.
     */
    byHotkey(press: KeyInput): N | undefined {
        return this.names.find((n) => this.opts[n].hotkey.is(press))
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
 * What the grid menu is told.
 *
 * @property spec - the menu: its options and art.
 * @property header - what goes above the grid (the logo, a title).
 * @property onChoose - called when an option is chosen, by Enter or by its hotkey.
 * @property escape - what Esc does: `"quit"` ends the program (the default, for the
 *     menus below the main one), `"ignore"` does nothing (the main menu, which has a
 *     `quit` option of its own); the legend only offers `quit: esc` when it works.
 * @property onKey - called for every other key press, for the keys a menu adds (the
 *     settings menu's Ctrl-E); not called while a hotkey is waiting.
 * @property legend - extra text for the hint box, e.g. `"custom solutes: ^e"`.
 * @property notice - a line shown under the grid (an error, e.g. `no projects to load!`);
 *     the menu keeps taking keys.
 * @property overlay - a prompt or dropdown to show in place of the hint box. While one
 *     is given the menu takes no keys, because the overlay is the one that listens.
 */
export type GridMenuProps<N extends MenuOptions> = {
    spec:      MenuSpec<N>
    header?:   ReactNode
    onChoose:  (name: N) => void
    escape?:   "quit" | "ignore"
    onKey?:    (press: KeyInput) => void
    legend?:   string
    notice?:   string
    overlay?:  ReactNode
}

/**
 * A menu of options on a grid, moved with the arrow keys, chosen with Enter or with a
 * hotkey, and left with Ctrl-X (back) or Esc (quit). The main menu, the project menu
 * and the settings menu are all this component with a different [[MenuSpec]].
 *
 * A hotkey first moves the cursor to its option and chooses it after `hotkeyDelay`, so
 * the highlight is seen before the screen changes.
 *
 * @param props - see [[GridMenuProps]].
 * @returns the menu: header, grid, and the hint box at the bottom.
 */
export function GridMenu<N extends MenuOptions>(props: GridMenuProps<N>): ReactNode {
    const { spec, header, onChoose, escape = "quit", onKey, legend, overlay, notice } = props
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
        // while a hotkey waits to choose its option, ignore every key
        if (pending !== null) return

        if (press.is(keys.enter)) onChoose(selected)
        else if (press.is(keys.back)) nav.pop()
        else if (press.is(keys.escape)) { if (escape === "quit") nav.quit() }
        else {
            const move = arrowKeys.find(([key]) => press.is(key))
            const next = move && spec.neighbour(selected, move[1])
            const hot  = spec.byHotkey(press)
            if (next) setSelected(next)
            else if (hot) jumpTo(hot)
            else onKey?.(press)
        }
    }, overlay === undefined)

    const hint = spec.hint(selected)
    return (
        <Box flexDirection="column" alignItems="center" flexGrow={1}>

            {/* header: the logo and version, or a title */}
            {header}

            {/* options grid */}
            <Box flexDirection="column" alignItems="center" marginTop={1}>
                {spec.rows.map((row) => (
                    <Box key={row[0]} columnGap={columnGap}>
                        {row.map((name) => (
                            <Cell key={name} spec={spec} name={name} active={selected === name} />
                        ))}
                    </Box>
                ))}
            </Box>

            {notice ? <Text color={theme.er}>{notice}</Text> : null}

            {/* an open prompt takes the place of the hint, right under the grid */}
            {overlay !== undefined ? <Box marginTop={1}>{overlay}</Box> : null}

            {/* move hint: the arrows that work from the selected option, and the keys */}
            <Box flexGrow={1} flexDirection="column" justifyContent="flex-end">
                <Box
                    borderStyle="round"
                    borderColor={theme.mt}
                    borderBackgroundColor={theme.bg}
                    alignItems="center"
                    columnGap={1}
                >
                    <Text color={theme.mt}>move:</Text>
                    <Box width={hint.width} height={hint.height} flexShrink={0}>
                        <Text color={theme.mt}>{hint.text}</Text>
                    </Box>
                    <Text color={theme.mt}>
                        {`    select: ⏎${nav.depth > 1 ? "    back: ^x" : ""}${escape === "quit" ? "    quit: esc" : ""}`}
                        {legend ? `    ${legend}` : ""}
                    </Text>
                </Box>
            </Box>
        </Box>
    )
}
