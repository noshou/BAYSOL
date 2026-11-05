// SPDX-License-Identifier: LGPL-3.0-or-later

import type { ReactNode } from "react"
import { Entry, type EntryProps } from "./entry.js"
import type { Suggestion } from "./suggestion-list.js"

/**
 * A text prompt: type, Enter takes the text, Esc gives up. With `suggest` it hints
 * names under the field (up and down move, Tab completes) but still takes what was
 * typed, which is what a path prompt wants.
 *
 * @param props - the props of an [[Entry]] without `pick`.
 * @returns the prompt.
 */
export function Prompt(props: Omit<EntryProps<Suggestion>, "pick" | "noMatch">): ReactNode {
    return <Entry {...props} pick={false} />
}
