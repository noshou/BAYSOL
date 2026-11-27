// SPDX-License-Identifier: LGPL-3.0-or-later

// The help screen of the main menu: what the program is, where its files are, the keys,
// the setup wizard and how to uninstall. A read-only text in the pager of the logs menu.

import type { ReactNode } from "react"
import { appDir } from "../core/environment.js"
import { keys } from "../ui/interaction.js"
import { TextPager } from "./logs-menu.js"

/**
 * The text of the help screen.
 *
 * @returns the lines, joined by newlines.
 */
export function helpText(): string {
    return [
        "BAYSOL: Bayesian CRYSOL",
        "",
        "Fits a measured SAXS/SANS curve against a structure and samples the posterior of",
        "the solvent nuisance parameters, so a fit comes with probabilities.",
        "",
        "Projects",
        "  A project is a folder (data, buffer, models, settings, runs). New makes one,",
        "  Load opens one, Open shows the projects folder in the file manager. Settings",
        "  on the main menu are global; each project can override them.",
        "",
        "Keys",
        "  arrows, Enter   move and choose          Esc   closes what is open; never quits",
        "  the letter shown on a tile opens it      ^x    back one screen",
        "  q               quit (main menu)         ^t    theme list",
        "  ^c, ^d          quit from anywhere, also while a fit runs (it is stopped first)",
        "  In a text: PgUp/PgDn or shift+arrows a page, / find, Home/End.",
        "",
        "Fits that do not converge",
        "  When the first attempt is borderline, the retry ladder runs longer warm-ups",
        "  and longer chains, so a fit can take far longer than similar ones, and the",
        "  ladder does not guarantee it ends in convergence. If a fit is much slower",
        "  than usual, stop it (^c) and try another seed (Settings, sampler, sampling:",
        "  RNG seed) or a shorter ladder (Settings, sampler, retry ladder) before",
        "  allowing more. Do not shop for a seed that passes: report the one you used.",
        "  A failed run still writes its log with the failure class.",
        "",
        "Setup wizard (packaged app)",
        `  ${keys.setup.label} opens it from the main menu; \`baysol setup\` from a shell.`,
        "  Set up or change: projects folder, cache, structure cache, threads per fit,",
        "  desktop entry and PATH link. Nothing is written until you apply.",
        "  Repair: rewrites a missing or wrong desktop entry or link.",
        "  Changes take effect when the program is restarted.",
        "",
        "Uninstall",
        "  Open the setup wizard and choose Uninstall:",
        "    App and caches    removes the app, caches, shortcuts and the setup file; your",
        "                      projects folder stays.",
        "    Everything        also deletes the projects folder (type delete to confirm).",
        "  The program quits when the app is gone.",
        "",
        "Documentation: the repository README and the docs site (guides per module).",
    ].join("\n")
}

/**
 * The help screen.
 *
 * @returns the screen.
 */
export function HelpScreen(): ReactNode {
    return (
        <TextPager
            title="help"
            subtitle="BAYSOL"
            corner="help"
            runDir={appDir()}
            load={helpText}
        />
    )
}
