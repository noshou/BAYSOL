// SPDX-License-Identifier: LGPL-3.0-or-later

// The notes editor screen: free text of a recipe in the built-in multi-line editor.
//
// Contents:
//   1. `NotesEditor`

import { Box, Text } from "ink"
import { type ReactNode, useState } from "react"
import { saveErrorNote } from "../core/file-system.js"
import { textLength } from "../core/text-area.js"
import { Frame } from "../ui/frame.js"
import { type LegendItem, legendFor } from "../ui/grid.js"
import { useNote } from "../ui/input.js"
import { keys, useBodyColumns, useBodyRows, useKeys, useNav } from "../ui/interaction.js"
import { TextAreaView, useTextArea } from "../ui/text-area.js"
import { Panel, useTheme } from "../ui/theme.js"
import { noteScreenTitle, notesCounter } from "./screen-rules.js"

/** The rows besides the lines of text: the panel's two borders and the counter. */
const CHROME_ROWS = 3

/** The rows the blocky footer's box adds to what `useBodyRows` allows for. */
const FOOTER_BOX_ROWS = 2

/** The cells the panel takes of the body's width: its borders and one cell of padding. */
const PANEL_CELLS = 4

/** The keys of the editor (they all work all the time). */
const NOTES_LEGEND: LegendItem[] = [
    legendFor("back", keys.back),
    legendFor("save", keys.save),
    legendFor("new line", keys.enter),
    legendFor("move", [keys.up, keys.down, keys.left, keys.right], keys.home, keys.end),
]

/**
 * The notes of one item (a recipe), edited as plain text in a bordered panel of lines
 * with a visible cursor.
 *
 * Keys: the arrows, home, end, page up and page down move; Enter starts a new line; typed
 * text and a paste (line breaks kept, tabs as spaces) are inserted; backspace and delete
 * remove, joining lines at a line's ends; `^w` hands the text to `onSave` (the screen
 * stays open); Esc and `^x` save a changed text the same way and leave, so nothing is
 * ever dropped (a save that throws is told in the note and the screen stays). There is
 * no limit on the length.
 * Long lines are not wrapped: they scroll sideways with the cursor. Under the panel the
 * counter says the line, the column and the characters.
 *
 * @param props.owner - whose note it is (the project, `buffer` or the recipe's name).
 * @param props.title - the note's title; the screen is `<owner> / <title>`.
 * @param props.initial - the text to start with.
 * @param props.onSave - receives the whole text at `^w` and on leaving a changed text
 *     (empty text is the caller's to take as no notes); it may throw.
 * @returns the screen.
 */
export function NotesEditor(props: {
    owner: string
    title: string
    initial: string
    onSave: (text: string) => void
}): ReactNode {
    const { owner, title, initial, onSave } = props
    const theme = useTheme()
    const nav = useNav()
    const input = useTextArea(initial)
    const { area } = input
    const [saved, setSaved] = useState(initial)
    const { note, say, clear } = useNote()
    const changed = area.text !== saved
    const columns = useBodyColumns()
    // the legend never changes height: it is the fullest one that is shown
    const rows = Math.max(3, useBodyRows(CHROME_ROWS + FOOTER_BOX_ROWS))
    const width = columns - PANEL_CELLS

    /** Hands the text to the owner; `false` (and the error as the note) if it threw. */
    const save = (): boolean => {
        try {
            onSave(area.text)
        } catch (error) {
            say(saveErrorNote(error), true)
            return false
        }
        setSaved(area.text)
        say("saved")
        return true
    }

    useKeys((press) => {
        clear()
        if (press.is(keys.save)) save()
        else if (press.is(keys.escape) || press.is(keys.back)) {
            if (!changed || save()) nav.pop()
        } else input.edit(press, rows - 1)
    })

    const counter = notesCounter(
        area.row + 1,
        area.lines.length,
        area.cell + 1,
        textLength(area.text),
    )
    return (
        <Frame
            design="blocky"
            title={noteScreenTitle(owner, title)}
            subtitle={changed ? "unsaved" : undefined}
            legend={NOTES_LEGEND}
            note={note?.text}
            noteIsError={note?.error}
        >
            <Panel style="double" paddingX={1}>
                <TextAreaView area={area} rows={rows} width={width} />
            </Panel>
            <Box>
                <Text color={theme.mt}>{counter}</Text>
            </Box>
        </Frame>
    )
}
