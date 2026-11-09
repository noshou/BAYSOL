// SPDX-License-Identifier: LGPL-3.0-or-later

// The screen of a run while it lives and after it: the tail of Julia's output and the way
// back to the project menu.

import { Box, Text } from "ink"
import { type ReactNode, useEffect, useState, useSyncExternalStore } from "react"
import { displayWidth, wrapLine } from "../core/terminal.js"
import { runDisplay } from "../store/projects.js"
import { elapsedText, isEnd, type RunPhase, type RunSession } from "../store/run.js"
import { Frame } from "../ui/frame.js"
import { type LegendItem, legendFor } from "../ui/grid.js"
import {
    keys,
    useBodyColumns,
    useBodyRows,
    useKeys,
    useNav,
} from "../ui/interaction.js"
import { Panel, useTheme } from "../ui/theme.js"

/** The keys of the screen while the run lives: the one way out is to abort and quit. */
const ABORT_LEGEND: LegendItem = legendFor("abort and quit", keys.interrupt)

/** The key of the screen at the end: back to the project menu. */
const BACK_LEGEND: LegendItem = legendFor("back", keys.enter)

/** The rows the output panel gives up besides the frame's: its two border lines. */
const RUN_PANEL_ROWS = 2

/** The columns the output panel gives up: its two border columns and the padding. */
const RUN_PANEL_COLUMNS = 4

/** What the muted line says before the child has printed anything. */
const WAITING = "waiting for julia..."

/**
 * The note line under the output: what the run is doing between running and the end.
 *
 * @param phase - the phase.
 * @param note - what the run itself has to tell (a failed start).
 * @returns the note, or `undefined`.
 */
export function runNote(phase: RunPhase, note: string | undefined): string | undefined {
    if (phase === "aborting") return "stopping the run..."
    if (phase === "packing") return "packing the run..."
    return note
}

/**
 * The last of the output lines that fit a panel, each wrapped to its width.
 *
 * @param lines - all the lines kept.
 * @param rows - the rows of the panel's inside.
 * @param columns - the cells of a line.
 * @returns at most `rows` rows, the newest last.
 */
export function visibleTail(
    lines: readonly string[],
    rows: number,
    columns: number,
): string[] {
    return lines.flatMap((line) => wrapLine(line, columns)).slice(-rows)
}

/**
 * The full-screen view of a run: the live tail of what Julia prints (the unicode plots are
 * in `plots.txt`, not here), the state (running, aborting, then done, failed or
 * aborted) with the elapsed time, and keys that are locked: while the run lives the only
 * key is `^c` / `^d` (handled by the app: it aborts and quits the whole program), and at
 * the end Enter returns to the project menu. The smooth logo, like every screen below the
 * menus except the settings sheets.
 *
 * @param props.session - the run.
 * @returns the screen.
 */
export function RunScreen({ session }: { session: RunSession }): ReactNode {
    const theme = useTheme()
    const nav = useNav()
    const view = useSyncExternalStore(session.subscribe, session.snapshot)
    const columns = useBodyColumns()
    const rows = useBodyRows()
    const ended = isEnd(view.phase)

    // the clock ticks once a second until the child has ended
    const [now, setNow] = useState(() => Date.now())
    useEffect(() => {
        if (view.endedMs !== undefined) return
        const timer = setInterval(() => setNow(Date.now()), 1000)
        return () => clearInterval(timer)
    }, [view.endedMs])
    const elapsed = elapsedText((view.endedMs ?? now) - view.startedMs)

    useKeys((press) => {
        if (ended && press.is(keys.enter)) nav.pop()
    })

    const shown = visibleTail(
        view.lines,
        rows - RUN_PANEL_ROWS,
        columns - RUN_PANEL_COLUMNS,
    )
    const legend = ended ? [BACK_LEGEND] : view.phase === "running" ? [ABORT_LEGEND] : []
    const note = runNote(view.phase, view.note)
    return (
        <Frame
            title="run"
            subtitle={`${view.project} · ${runDisplay(view.id)}`}
            legend={legend}
            legendFull={[ABORT_LEGEND, BACK_LEGEND]}
            counter={`${view.phase} ${elapsed}`}
            note={note}
            noteIsError={view.phase === "failed"}
        >
            <Panel flexDirection="column" flexGrow={1} paddingX={1}>
                {shown.length === 0 ? (
                    <Text color={theme.mt}>{WAITING}</Text>
                ) : (
                    shown.map((line, i) => (
                        // the tail scrolls: a line's place is its identity
                        // biome-ignore lint/suspicious/noArrayIndexKey: see above
                        <Box key={i} height={1}>
                            <Text color={theme.fg}>
                                {displayWidth(line) === 0 ? " " : line}
                            </Text>
                        </Box>
                    ))
                )}
            </Panel>
        </Frame>
    )
}
