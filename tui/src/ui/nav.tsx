// SPDX-License-Identifier: LGPL-3.0-or-later

import { Box, useApp } from "ink"
import {
    createContext,
    type ReactElement,
    type ReactNode,
    useCallback,
    useContext,
    useMemo,
    useState,
} from "react"

/**
 * What a screen can ask of the navigation: open another screen on top of it, go back
 * to the one below, or quit the program.
 *
 * @property push - opens `screen` on top of the current one.
 * @property pop - closes the current screen; the one below is shown again, as it was.
 * @property quit - ends the program.
 * @property depth - how many screens are open (1 for the first).
 */
export type Nav = {
    push:  (screen: ReactElement) => void
    pop:   () => void
    quit:  () => void
    depth: number
}

const NavContext = createContext<Nav | null>(null)

/**
 * Whether the screen that reads this is the one on top. Every screen stays mounted
 * while another is open on it (so it comes back as it was), and only the top one
 * takes keys.
 */
const ActiveContext = createContext<boolean>(true)

/**
 * The navigation of the program; only callable within a screen.
 *
 * @returns the [[Nav]] that opens and closes screens.
 * @throws if there is no [[NavProvider]] above the caller.
 */
export function useNav(): Nav {
    const nav = useContext(NavContext)
    if (nav === null) throw new Error("useNav needs a NavProvider above it")
    return nav
}

/** @returns `true` when the calling screen is the one on top and may take keys. */
export function useScreenActive(): boolean {
    return useContext(ActiveContext)
}

/**
 * Keeps the stack of open screens and draws all of them, the top one visible.
 * Lower screens keep their state because they are hidden, not unmounted.
 *
 * @param root - the first screen.
 * @returns the provider; put it around the whole program.
 */
export function NavProvider({ root }: { root: ReactElement }): ReactNode {
    const { exit } = useApp()
    const [stack, setStack] = useState<ReactElement[]>([root])

    const push = useCallback((screen: ReactElement) => setStack((s) => [...s, screen]), [])
    // the first screen is never popped: going back from it would leave nothing to show
    const pop = useCallback(
        () => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s)),
        []
    )
    const nav = useMemo(
        () => ({ push, pop, quit: exit, depth: stack.length }),
        [push, pop, exit, stack.length]
    )

    return (
        <NavContext.Provider value={nav}>
            {stack.map((screen, i) => (
                <ActiveContext.Provider key={i} value={i === stack.length - 1}>
                    <Box
                        display={i === stack.length - 1 ? "flex" : "none"}
                        flexGrow={1}
                        flexDirection="column"
                    >
                        {screen}
                    </Box>
                </ActiveContext.Provider>
            ))}
        </NavContext.Provider>
    )
}
