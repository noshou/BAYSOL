// SPDX-License-Identifier: LGPL-3.0-or-later

import { usePaste } from "ink"
import { useRef, useState } from "react"
import type { KeyInput } from "../ui/keys.js"
import { useScreenActive } from "../ui/nav.js"
import { useKeys } from "../ui/use-keys.js"
import type { EditEnd, EditStep } from "./setting-edit.js"

/**
 * Holds the state of a pure editor (see `setting-edit.ts`) and feeds it the keys of the
 * screen. The state is also kept in a ref, so two keys that arrive before a redraw (a
 * fast typist, a held key) each see the result of the one before.
 *
 * @typeParam S - the state of the editor.
 * @typeParam V - the value the editor gives.
 * @param initial - the starting state.
 * @param step - the editor's step function.
 * @param onEnd - called once the edit is over, with how it ended.
 * @param paste - how pasted text changes the state; without it pastes are ignored.
 * @returns the state to draw.
 */
export function useEditor<S, V>(
    initial: S,
    step: (state: S, press: KeyInput) => EditStep<S, V>,
    onEnd: (end: EditEnd<V>) => void,
    paste?: (state: S, text: string) => S,
): S {
    const [state, setState] = useState(initial)
    const latest = useRef(state)
    const onTop = useScreenActive()

    const keep = (next: S): void => {
        latest.current = next
        setState(next)
    }
    useKeys((press) => {
        const result = step(latest.current, press)
        keep(result.state)
        if (result.end !== undefined) onEnd(result.end)
    })
    usePaste((text) => paste !== undefined && keep(paste(latest.current, text)), {
        isActive: onTop && paste !== undefined,
    })
    return state
}
