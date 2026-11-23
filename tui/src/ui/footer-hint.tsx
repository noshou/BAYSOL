// SPDX-License-Identifier: LGPL-3.0-or-later

// A hint on the bottom row, left of the theme line, that a screen puts there while it is
// the one on top (the main menu: the key of the setup wizard).

import { createContext, useContext, useEffect } from "react"

/** The setter of the hint, given by `App`; without it (a test) a hint goes nowhere. */
export const FooterHintContext = createContext<(text: string | undefined) => void>(() => {})

/**
 * Shows `text` on the bottom row while `active`, and takes it away when the screen is no
 * longer active or goes.
 *
 * @param text - the hint.
 * @param active - whether the calling screen is the one on top.
 */
export function useFooterHint(text: string, active: boolean): void {
    const set = useContext(FooterHintContext)
    useEffect(() => {
        if (!active) return
        set(text)
        return () => set(undefined)
    }, [set, text, active])
}
