// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, Text, useApp, useInput } from "ink"
import { useCallback, useEffect, useState }  from "react"
import { KeyInput, keyPress }  from "./keys.js"
import {
    type Art,
    loadOpts,
    menuArrows,
    menuCursor,
    menuLogo
} from "./menu-opts.js"
import { useTheme} from "./theme.js"
import { version } from "./version.js"

const names = ["new", "load", "open", "settings", "help", "quit"] as const
type Name = (typeof names)[number]

// load assets
const opts = loadOpts(names)
const curs = menuCursor()
const logo = menuLogo()
const arws = menuArrows("2x3")

/** The blank columns between the cursor and the text of an option. */
const cursorGap = 2

/**
 * The width of one cell: the cursor, the gap, and the widest piece. Both columns
 * use it, so they mirror each other and the gap between them sits exactly in the
 * middle.
 */
const colWidth =
    Math.max(...names.map((name) => opts[name].width)) + curs.width + cursorGap

/**
 * One option of the grid: the cursor slot and the text.
 *
 * The slot is always reserved, so the text does not move when the cursor does.
 * The cursor is drawn, and the text is in the full foreground colour, when the
 * option is active. Otherwise the text is muted.
 *
 * @param name - the option to draw, one of the six in `names`.
 * @param active - whether the cursor is on this option.
 * @returns the cell, `colWidth` wide and as tall as the option's art.
 */
function Cell({ name, active }: { name: Name; active: boolean }) {
    const theme = useTheme()
    return (
        <Box
            width={colWidth}
            height={opts[name].height}
            flexShrink={0}
        >
            {/* stateful cursor */}
            <Box width={curs.width} flexShrink={0} marginRight={cursorGap}>
                {active ? <Text color={theme.fg}>{curs.text}</Text> : null}
            </Box>

            {/* stateful text */}
            <Text color={active ? theme.fg : theme.mt}>{opts[name].text}</Text>
        </Box>
    )
}

/**
 * where each arrow key goes, and the hint that shows those arrows.
 */
type State = {
    moves: Partial<Record<string, Name>>
    hint:  Art
}

/**
 * The state of each option of the grid. The hint of the n-th option in `names` is
 * the n-th piece of `arws` (position n), and it shows exactly the arrows in `moves`.
 */
const states: Record<Name, State> = {
    new: {
        moves: { right: "load", down: "open" },
        hint:  arws[0],
    },
    load: {
        moves: { left: "new", down: "settings" },
        hint:  arws[1],
    },
    open: {
        moves: { up: "new", right: "settings", down: "help" },
        hint:  arws[2],
    },
    settings: {
        moves: { up: "load", left: "open", down: "quit" },
        hint:  arws[3],
    },
    help: {
        moves: { up: "open", right: "quit" },
        hint:  arws[4],
    },
    quit: {
        moves: { up: "settings", left: "help" },
        hint:  arws[5],
    }
}

/** The enter key, which chooses the selected option. */
const enterKey = new KeyInput("return")

/** How long a hotkey waits, in milliseconds, before it chooses its option. */
const hotkeyDelay = 50

export function MainMenu() {
    const theme = useTheme()
    const [selected, setSelected] = useState<Name>("new")
    const [pending, setPending] = useState<Name | null>(null)
    const { exit } = useApp()

    // what Enter does on an option; `quit` leaves, the others have no state yet
    const choose = useCallback(
        (name: Name) => {
            if (name === "quit") exit()
        },
        [exit]
    )

    // a hotkey selects its option now and chooses it after `hotkeyDelay`, so the
    // highlight is on state first; the cleanup cancels the timer if it is replaced
    useEffect(() => {
        if (pending === null) return
        const timer = setTimeout(() => {
            choose(pending)
            setPending(null)
        }, hotkeyDelay)
        return () => clearTimeout(timer)
    }, [pending, choose])

    useInput((input, key) => {

        // while a hotkey waits to choose its option, ignore every key
        if (pending !== null) return

        const press = keyPress(input, key)
        const next  = states[selected].moves[press.key_]
        const hot   = names.find((n) => opts[n].hotkey.is(press))

        // enter chooses the selected option at once
        if (press.is(enterKey)) choose(selected)

        // the arrow keys move the cursor to the next option, if the state allows it
        if (next) setSelected(next)

        // a hotkey selects its option, and the effect above chooses it after a delay
        if (hot) {
            setSelected(hot)
            setPending(hot)
        }
    })

    return (

        <Box
            flexDirection="column"
            alignItems="center"
            flexGrow={1}
        >

            {/* centered BAYSOL logo + version name */}
            <Box
                flexDirection="column"
                alignItems="center"
            >
                <Box
                    width={logo.width}
                    height={logo.height}
                    flexShrink={0}
                    marginTop={1}
                >
                    <Text color={theme.fg}>
                        {logo.text}
                    </Text>
                </Box>
                <Text color={theme.mt}> {version} </Text>
            </Box>

            {/* options grid */}
            <Box
                flexDirection="column"
                alignItems="center"
                marginTop={1}
            >
                {/* row 1: new | load */}
                <Box columnGap={2}>
                    <Cell name="new"  active={selected === "new"}/>
                    <Cell name="load" active={selected === "load"}/>
                </Box>

                {/* row 2: open | settings */}
                <Box columnGap={2}>
                    <Cell name="open"     active={selected === "open"}/>
                    <Cell name="settings" active={selected === "settings"}/>
                </Box>

                {/* row 3: help | quit */}
                <Box columnGap={2}>
                    <Cell name="help" active={selected === "help"}/>
                    <Cell name="quit" active={selected === "quit"}/>
                </Box>
            </Box>

            {/* move hint: the arrows that work from the selected option */}
            <Box flexGrow={1} flexDirection="column" justifyContent="flex-end">
                <Box
                    borderStyle="round"
                    borderColor={theme.mt}
                    borderBackgroundColor={theme.bg}
                    alignItems="center"
                    columnGap={1}
                >
                    <Text color={theme.mt}>move:</Text>
                    <Box
                        width={states[selected].hint.width}
                        height={states[selected].hint.height}
                        flexShrink={0}
                    >
                        <Text color={theme.mt}>{states[selected].hint.text}</Text>
                    </Box>
                    <Text color={theme.mt}>    select: ⏎</Text>
                </Box>
            </Box>
        </Box>
    )
}
