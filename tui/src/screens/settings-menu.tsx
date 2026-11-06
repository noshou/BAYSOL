// SPDX-License-Identifier: LGPL-3.0-or-later

import { type ReactNode, useCallback } from "react"
import { type Scope, scopeTitle } from "../store/scope.js"
import { GridMenu, MenuSpec } from "../ui/grid-menu.js"
import { type KeyInput, keys } from "../ui/keys.js"
import { MenuHeader } from "../ui/menu-header.js"
import { useNav } from "../ui/nav.js"
import { CustomLanding } from "./custom-landing.js"
import { SettingsSheet } from "./settings-sheet.js"

/**
 * The four groups of settings, as a grid: output, model / sampler, plots. Exported so a
 * test can check the hotkeys.
 */
export const settingsMenuSpec = new MenuSpec(["output", "models", "sampler", "plots"], 2)

/**
 * The id of the sheet each option opens. Every option is the id of its sheet except
 * the model settings, which share the art (and the `m` hotkey) of `models`.
 */
const sheetOf = {
    output:  "output",
    models:  "model",
    sampler: "sampler",
    plots:   "plots",
} as const

/**
 * The settings menu, for the global settings or those of one project. The global one
 * also opens the custom solutes and recipes with Ctrl-E.
 *
 * @param scope - whose settings.
 * @returns the screen.
 */
export function SettingsMenu({ scope }: { scope: Scope }): ReactNode {
    const nav = useNav()
    const global = scope.kind === "global"

    // the names of the options are the ids of the sheets of the settings catalog
    const choose = useCallback(
        (name: (typeof settingsMenuSpec.names)[number]) =>
            nav.push(<SettingsSheet scope={scope} sheetId={sheetOf[name]} />),
        [nav, scope]
    )
    const onKey = useCallback((press: KeyInput) => {
        if (global && press.is(keys.addNucleotide)) nav.push(<CustomLanding />)
    }, [global, nav])

    return (
        <GridMenu
            spec={settingsMenuSpec}
            header={<MenuHeader caption={scopeTitle(scope)} />}
            onChoose={choose}
            onKey={onKey}
            legend={global ? `custom solutes: ${keys.addNucleotide.label}` : undefined}
        />
    )
}
