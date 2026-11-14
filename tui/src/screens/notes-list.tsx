// SPDX-License-Identifier: LGPL-3.0-or-later

// The notes list: the titled notes of a project, a buffer or a recipe as a table, each
// opening in the notes editor.
//
// Contents:
//   1. `NotesList`

import { type ReactNode, useRef } from "react"
import { textLength } from "../core/text-area.js"
import { type Row, rowValue } from "../store/lists.js"
import {
    defaultTitle,
    firstLine,
    NOTE_TITLE_MAX,
    type Note,
    notesProblem,
    titleProblem,
} from "../store/notes.js"
import { Frame } from "../ui/frame.js"
import { legendFor } from "../ui/grid.js"
import { keys, scrollWindow, useKeys, useNav } from "../ui/interaction.js"
import { type Naming, useNamePrompt } from "../ui/prompt-flows.js"
import { type Column, DataTable } from "../ui/theme.js"
import { NotesEditor } from "./notes-editor.js"
import { useTableScreen, withNoteText } from "./screen-rules.js"

/** The add key of the legend (also what the footer reserves). */
const ADDS = [legendFor("new note", keys.addNonbio)]

/** The key of the legend that acts on the highlighted note. */
const ROW_KEYS = [legendFor("rename", keys.renameNote)]

/** What the empty table says. */
const EMPTY_HINT = "none"

/** The width of the narrow column of characters. */
const CHARS_WIDTH = 7

/**
 * The notes of one owner as a table with the columns title, characters and the first
 * line of the text. Nothing is kept anywhere before `^w`, which hands the whole list to
 * `onSave` (a project writes its file, a buffer or a recipe takes it as an unsaved change
 * of its own table).
 *
 * Keys: up and down move; Enter opens the note in the [[NotesEditor]] (`^w` there, or
 * leaving it, saves the list through `onSave` at once); `^n` asks a title (`note 1`,
 * `note 2`, ... to start from) and opens a new, empty note; `shift+m` renames the note;
 * `^r` marks the row to go (`-`, undone by `^u`, gone at `^w`); `/` finds a row and
 * `z` puts them in alphabetical order; `^w` saves; `^x` goes back, asking first when
 * something is unsaved. A title is not blank, at most 40 characters, without control
 * characters and unique among the notes (case does not matter).
 *
 * @param props.owner - whose notes they are, shown as the subtitle and in the editor's
 *     title.
 * @param props.items - the notes as the owner has them.
 * @param props.onSave - receives the whole list at `^w`; it may throw, and the screen then
 *     tells the save failed.
 * @returns the screen.
 */
export function NotesList(props: {
    owner: string
    items: readonly Note[]
    onSave: (notes: Note[]) => void
}): ReactNode {
    const { owner, items, onSave } = props
    const nav = useNav()
    const t = useTableScreen<Note>({
        adds: ADDS,
        rowKeys: ROW_KEYS,
        items,
        save: onSave,
        check: (drafts) => {
            const why = notesProblem(drafts.toSave())
            return why === undefined ? undefined : [0, why]
        },
        label: (note) => note.title,
    })
    const noteOf = (r: Row<Note>) => rowValue(r) as Note

    // the drafts as of the latest render: the editor on top keeps saving into them
    const latest = useRef(t.drafts)
    latest.current = t.drafts

    /**
     * The editor's `^w`: the note's text goes through the list's own save, the whole list
     * (other unsaved renames and marks too) as `^w` here would. A throw is the editor's
     * to tell.
     */
    const saveNote = (index: number, text: string) => {
        const next = withNoteText(latest.current, index, text)
        onSave(next.toSave())
        t.adopt(next.commit(), false)
    }

    /** Opens the text of a note (row `index`) in the editor. */
    const openEditor = (index: number, note: Note) => {
        nav.push(
            <NotesEditor
                owner={owner}
                title={note.title}
                initial={note.text}
                onSave={(text) => saveNote(index, text)}
            />,
        )
    }

    /** The title was accepted: a new, empty note (opened), or the note renamed. */
    const addOrRename = (title: string, target: Naming) => {
        if (target.index === undefined) {
            const note: Note = { title, text: "" }
            const at = t.drafts.length
            t.append(note)
            return openEditor(at, note)
        }
        const current = t.drafts.value(target.index) as Note
        t.replaceAt(target.index, { ...current, title })
    }

    const naming = useNamePrompt({
        label: "note title:",
        maxLength: NOTE_TITLE_MAX,
        check: (title, target) => {
            const others = t.drafts.rows.map((r) => ({ title: noteOf(r).title }))
            return titleProblem(others, title, target.index)
        },
        accept: addOrRename,
    })

    useKeys((press) => {
        if (t.handleKey(press)) return
        if (press.is(keys.enter) && t.canEdit && t.current) {
            openEditor(t.cursor.index, t.current)
        } else if (press.is(keys.renameNote) && t.canEdit && t.current) {
            naming.open(t.cursor.index, t.current.title)
        } else if (press.is(keys.addNonbio) && t.canAdd) {
            const rows = t.drafts.rows.map((r) => ({ title: noteOf(r).title }))
            naming.open(undefined, defaultTitle(rows))
        }
    }, naming.naming === undefined)

    const columns: Column<Row<Note>>[] = [
        { title: "title", grow: 2, text: (r) => noteOf(r).title },
        {
            title: "chars",
            width: CHARS_WIDTH,
            align: "right",
            text: (r) => String(textLength(noteOf(r).text)),
        },
        { title: "text", grow: 4, text: (r) => firstLine(noteOf(r).text) },
    ]
    const legend = naming.naming ? naming.legend : t.legend(ADDS)
    const pageSize = naming.pageSize(t.pageSize)
    const offset = scrollWindow(t.cursor.index, t.cursor.offset, pageSize, t.rows.length)
    const changes = t.drafts.count
    return (
        <Frame
            design="blocky"
            title="notes"
            subtitle={changes > 0 ? `${owner} · ${changes} unsaved` : owner}
            legend={legend}
            legendFull={t.legendFull}
            note={naming.naming ? undefined : t.frameNote}
            noteIsError={t.frameNoteIsError}
        >
            <DataTable
                border="double"
                columns={columns}
                rows={t.rows}
                cursor={t.cursor.index}
                offset={offset}
                pageSize={pageSize}
                mark={t.mark}
                empty={EMPTY_HINT}
                width={t.width}
            />
            {t.finder}
            {naming.prompt}
        </Frame>
    )
}
