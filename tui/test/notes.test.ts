// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the notes of a recipe: the rules of the multi-line editor (`core/text-area.ts`),
// the store (`notes` of a recipe in `recipes.json`), and the screens drawn at 80 x 24.
//
// Contents:
//   1. The editor rules
//   2. The store
//   3. The screens

import assert from "node:assert/strict"
import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { createElement, type ReactElement } from "react"
import { UnusableFileError } from "../src/core/file-system.js"
import { displayWidth } from "../src/core/terminal.js"
import {
    cleanText,
    offsetAtCell,
    TAB_SPACES,
    TextArea,
    textLength,
    windowLine,
} from "../src/core/text-area.js"
import { RecipesTable } from "../src/screens/custom-solutes.js"
import { NotesEditor } from "../src/screens/notes-editor.js"
import { NotesList } from "../src/screens/notes-list.js"
import {
    notesCounter,
    withNoteText,
} from "../src/screens/screen-rules.js"
import { SolutesTable } from "../src/screens/solutes.js"
import {
    type Recipe,
    readBufferNotes,
    readConcUnit,
    readConditions,
    readRecipes,
    readSolutes,
    recipesFile,
    removeRecipe,
    renameRecipe,
    saveRecipe,
    updateRecipe,
    withNotes,
    writeBufferNotes,
    writeRecipes,
    writeSolutes,
} from "../src/store/buffer.js"
import { Drafts } from "../src/store/lists.js"
import {
    defaultTitle,
    type Note,
    notesCell,
    notesProblem,
    titleProblem,
} from "../src/store/notes.js"
import {
    createProject,
    readProject,
    readProjectNotes,
    writeProjectNotes,
} from "../src/store/projects.js"
import { claimRun, snapshotInputs } from "../src/store/run.js"
import { scrollWindow, taskbarKeys } from "../src/ui/interaction.js"
import { drawScreen, fixture, tempDir } from "./support/fixtures.js"

// ========================================================================================
// 1. The editor rules
// ========================================================================================

test("the cursor moves across lines with the arrows", () => {
    let a = new TextArea("ab\ncd", 0, 0)
    a = a.right().right()
    assert.deepEqual([a.row, a.col], [0, 2], "end of the first line")
    a = a.right()
    assert.deepEqual([a.row, a.col], [1, 0], "right at a line end goes to the next line")
    a = a.left()
    assert.deepEqual([a.row, a.col], [0, 2], "left at a line start goes to the line above")
    const back = a.left().left().left().left().left().left()
    assert.equal(back.col, 0, "stops at the start")
    const last = new TextArea("ab\ncd")
    assert.deepEqual([last.row, last.col], [1, 2], "a new area ends at the end of its text")
    assert.deepEqual([last.right().row, last.right().col], [1, 2], "stops at the end")
    assert.deepEqual([last.home().col, last.home().end().col], [0, 2])
})

test("up and down keep the column across a short line", () => {
    const a = new TextArea("abcdef\nx\nabcdef", 0, 4)
    const down = a.down()
    assert.deepEqual([down.row, down.col], [1, 1], "the short line ends it")
    const again = down.down()
    assert.deepEqual([again.row, again.col], [2, 4], "the wanted column comes back")
    assert.deepEqual([a.up().row, a.up().col], [0, 0], "up on the first line: the start")
    const end = again.down()
    assert.deepEqual([end.row, end.col], [2, 6], "down on the last line: the end")
})

test("wide characters count two cells for the column", () => {
    const a = new TextArea("日本語\nabcdef", 1, 4)
    assert.equal(a.cell, 4)
    const up = a.up()
    assert.equal(up.col, 2, "two wide characters are 4 cells")
    assert.equal(offsetAtCell("日本語", 3), 1, "never in the middle of a wide character")
})

test("typing inserts, Enter splits a line, backspace and delete join lines", () => {
    let a = new TextArea("")
    a = a.insert("ab").newline().insert("cd")
    assert.equal(a.text, "ab\ncd")
    assert.deepEqual([a.row, a.col], [1, 2])
    a = a.home().backspace()
    assert.equal(a.text, "abcd", "backspace at a line start joins it to the line above")
    assert.deepEqual([a.row, a.col], [0, 2])
    a = a.newline()
    assert.equal(a.text, "ab\ncd")
    a = a.left().delete()
    assert.equal(a.text, "abcd", "delete at a line end joins the next line")
    assert.deepEqual([a.row, a.col], [0, 2])
    assert.equal(new TextArea("").backspace().text, "")
    assert.equal(new TextArea("a", 0, 1).delete().text, "a")
    assert.equal(new TextArea("ab", 0, 1).backspace().text, "b")
    assert.equal(new TextArea("ab", 0, 1).delete().text, "a")
    // a character of several code units goes whole
    assert.equal(new TextArea("éx", 0, 2).backspace().text, "x")
})

test("a multi-line paste is inserted whole, tabs become spaces", () => {
    const a = new TextArea("ZZ", 0, 1).insert("a\tb\r\nc\rd")
    assert.equal(a.text, `Za${" ".repeat(TAB_SPACES)}b\nc\ndZ`)
    assert.deepEqual([a.row, a.col], [2, 1], "the cursor is after the paste")
    assert.equal(cleanText("x\u0007y\u001bz"), "xyz", "other control characters go")
    assert.equal(cleanText("a\r\nb"), "a\nb")
})

test("there is no cap: a long paste goes in whole, deleting works at any size", () => {
    const big = "é\n".repeat(30000)
    const a = new TextArea("").insert(big)
    assert.equal(textLength(a.text), 60000)
    assert.equal(a.lines.length, 30001)
    assert.equal(a.backspace().backspace().text, big.slice(0, -2))
})

test("pages move a window of lines and the cursor stays in view", () => {
    const text = Array.from({ length: 30 }, (_, i) => `line ${i}`).join("\n")
    let a = new TextArea(text, 0, 0)
    a = a.move(8)
    assert.equal(a.row, 8)
    assert.equal(a.move(100).row, 29, "a long page stops at the last line")
    assert.equal(a.move(-100).row, 0)
    let top = 0
    for (let row = 0; row < 30; row++) {
        top = scrollWindow(row, top, 10, 30)
        assert.ok(row >= top && row < top + 10, `row ${row} in view at ${top}`)
    }
    assert.equal(top, 20, "scrolled the least that keeps the cursor in view")
    assert.equal(scrollWindow(15, 20, 10, 30), 15, "going back up")
})

test("a long line scrolls sideways with the cursor", () => {
    assert.equal(windowLine("abcdefgh", 2, 4), "cdef")
    assert.equal(windowLine("abc", 0, 10), "abc")
    assert.equal(windowLine("abc", 5, 4), "")
    assert.equal(windowLine("日本語", 1, 4), " 本", "a wide character cut at the left edge")
    assert.equal(windowLine("日本語", 0, 3), "日", "and at the right edge")
    // the cursor cell stays inside the window
    const line = "x".repeat(200)
    const a = new TextArea(line, 0, 150)
    const left = scrollWindow(a.cell, 0, 70, Number.POSITIVE_INFINITY)
    assert.ok(a.cell >= left && a.cell < left + 70)
})

test("the counter", () => {
    assert.equal(notesCounter(3, 12, 7, 482), "line 3/12  col 7  482 characters")
})

// ========================================================================================
// 2. The notes list rules and the stores
// ========================================================================================

const rows = (fixture("buffer/buffer.json") as { solutes: Recipe["solutes"] }).solutes
const row = rows[0] as Recipe["solutes"][number]
const two: Note[] = [
    { title: "setup", text: "line 1\nline 2" },
    { title: "source", text: "" },
]
const hooks = { prepareGlobal: () => undefined, copySettings: () => undefined }
const recipe = (name: string, extra: Partial<Recipe> = {}): Recipe => ({
    name,
    solutes: [row],
    ...extra,
})

test("titles are unique without regard to case, short, and default to note N", () => {
    assert.equal(titleProblem(two, "Setup"), "title in use")
    assert.equal(titleProblem(two, "SETUP", 0), undefined, "a note may change its case")
    assert.equal(titleProblem(two, " "), "type a title first!")
    assert.equal(titleProblem(two, "x".repeat(41)), "40 characters at most")
    assert.equal(titleProblem(two, "x".repeat(40)), undefined)
    assert.equal(defaultTitle([]), "note 1")
    assert.equal(defaultTitle([{ title: "note 1" }, { title: "Note 3" }]), "note 2")
    assert.equal(notesCell(two), "setup, source")
    assert.equal(notesCell(undefined), "")
})

test("the file rules: an array of {title, text}, no limit on count or length", () => {
    assert.equal(notesProblem(undefined), undefined)
    assert.equal(notesProblem(two), undefined)
    const bad: unknown[] = [
        "x",
        { title: "a", text: "" },
        [1],
        [{ title: "a" }],
        [{ title: 1, text: "" }],
        [{ title: "a", text: 2 }],
        [{ title: "a", text: "" }, { title: "A", text: "" }],
        [{ title: "", text: "" }],
    ]
    for (const b of bad) assert.notEqual(notesProblem(b), undefined, JSON.stringify(b))
    const text = "é\n".repeat(20000)
    const many = Array.from({ length: 500 }, (_, i) => ({ title: `n${i}`, text }))
    assert.equal(notesProblem(many), undefined)
})

test("recipe notes round trip, are absent when empty, kept by save and rename", () => {
    const root = tempDir()
    writeRecipes(root, [recipe("SEC", { pH: 7, "sigmaPh": 0.1, notes: two })])
    const file = JSON.parse(readFileSync(recipesFile(root), "utf-8"))
    assert.deepEqual(Object.keys(file.recipes[0]), [
        "name",
        "solutes",
        "pH",
        "sigmaPh",
        "notes",
    ])
    assert.deepEqual(readRecipes(root)[0]?.notes, two)
    // the buffer has none: the recipe keeps its own
    saveRecipe(root, "sec", [row])
    assert.deepEqual(readRecipes(root)[0]?.notes, two)
    assert.equal(renameRecipe(root, "sec", "SEC 2"), undefined)
    assert.deepEqual(readRecipes(root)[0]?.notes, two)
    // the buffer has some: the recipe takes them
    const other = [{ title: "mine", text: "t" }]
    saveRecipe(root, "SEC 2", [row], undefined, other)
    assert.deepEqual(readRecipes(root)[0]?.notes, other)
    // no notes: no key; an old file stays valid
    writeRecipes(root, [withNotes(recipe("A", { notes: two }), [])])
    assert.ok(!readFileSync(recipesFile(root), "utf-8").includes("notes"))
    writeFileSync(recipesFile(root), JSON.stringify({ recipes: [recipe("old")] }))
    assert.equal(readRecipes(root)[0]?.notes, undefined)
})

test("updateRecipe changes one recipe at once, the others and the file's keys kept", () => {
    const root = tempDir()
    writeRecipes(root, [recipe("A", { notes: two }), recipe("B")])
    const change = (r: Recipe) => withNotes({ ...r, solutes: [row, row] }, [])
    assert.equal(updateRecipe(root, "a", change), true, "found without regard to case")
    const [a, b] = readRecipes(root) as [Recipe, Recipe]
    assert.equal(a.solutes.length, 2)
    assert.equal(a.notes, undefined, "all notes removed takes the key off")
    assert.equal(b.solutes.length, 1)
    assert.equal(updateRecipe(root, "nobody", change), false)
    // a recipe is renamed and removed by the existing store functions, each at once
    assert.equal(renameRecipe(root, "A", "A2"), undefined)
    assert.equal(removeRecipe(root, "B"), true)
    assert.deepEqual(
        readRecipes(root).map((r) => r.name),
        ["A2"],
    )
})

test("recipes with invalid notes are unusable and never overwritten", () => {
    const same = [{ title: "a", text: "" }, { title: "a", text: "" }]
    for (const bad of [1, "text", [{ title: "a" }], same]) {
        const root = tempDir()
        const text = JSON.stringify({ recipes: [{ ...recipe("A"), notes: bad }] })
        writeFileSync(recipesFile(root), text)
        const unusable = (f: () => unknown) =>
            assert.throws(f, (e) => e instanceof UnusableFileError && e.kind === "recipes")
        unusable(() => readRecipes(root))
        unusable(() => saveRecipe(root, "B", [row]))
        assert.equal(readFileSync(recipesFile(root), "utf-8"), text)
        unusable(() => writeRecipes(tempDir(), [{ ...recipe("A"), notes: bad } as Recipe]))
    }
})

test("buffer notes live next to solutes and survive writes that do not name them", () => {
    const dir = tempDir()
    writeSolutes(dir, [row], undefined, undefined, two)
    assert.deepEqual(readBufferNotes(dir), two)
    writeSolutes(dir, [row, row], { pH: 7, "sigmaPh": 0.1 }, "M")
    assert.deepEqual(readBufferNotes(dir), two, "kept by the other writers")
    writeSolutes(dir, [row], undefined, undefined, [])
    assert.deepEqual(readBufferNotes(dir), [])
    assert.ok(!readFileSync(join(dir, "buffer.json"), "utf-8").includes("notes"))
    writeFileSync(join(dir, "buffer.json"), '{"solutes": [], "notes": [{"title": 1}]}')
    assert.throws(() => readBufferNotes(dir), (e) => e instanceof UnusableFileError)
    const text = readFileSync(join(dir, "buffer.json"), "utf-8")
    assert.throws(() => writeSolutes(dir, [row]))
    assert.equal(readFileSync(join(dir, "buffer.json"), "utf-8"), text, "never overwritten")
})

test("buffer notes are written alone, at once; a later table save is not refused", () => {
    const dir = tempDir()
    const cond = { pH: 7, "sigmaPh": 0.1 }
    writeSolutes(dir, [row], cond, "M", two)
    // the table reads the file for editing, then notes are saved from its list
    const held = readSolutes(dir, { track: true })
    writeBufferNotes(dir, [{ title: "new", text: "t" }])
    assert.deepEqual(readBufferNotes(dir), [{ title: "new", text: "t" }])
    assert.deepEqual(readSolutes(dir), held, "the solutes stay as on disk")
    assert.deepEqual(readConditions(dir), cond, "so does the pH")
    assert.equal(readConcUnit(dir), "M", "and the unit")
    // a pending solute draft is only written by the table's own ^w, which still works
    writeSolutes(dir, [row, row], cond, "M", readBufferNotes(dir))
    assert.equal(readSolutes(dir).length, 2)
    assert.deepEqual(readBufferNotes(dir), [{ title: "new", text: "t" }])
    writeBufferNotes(dir, [])
    assert.ok(!readFileSync(join(dir, "buffer.json"), "utf-8").includes("notes"))
    assert.equal(readSolutes(dir).length, 2)
    assert.throws(() => writeBufferNotes(dir, [...two, { title: "SETUP", text: "" }]))
})

test("project notes live in project.json, every other key kept", () => {
    const root = tempDir()
    const dir = createProject(root, "p1", hooks)
    assert.deepEqual(readProjectNotes(dir), [])
    writeProjectNotes(dir, two)
    assert.deepEqual(readProjectNotes(dir), two)
    const info = readProject(dir)
    assert.equal(info?.id, "p1")
    assert.ok(info?.created)
    assert.deepEqual(info?.notes, two)
    writeProjectNotes(dir, [])
    assert.ok(!readFileSync(join(dir, "project.json"), "utf-8").includes("notes"))
    assert.equal(readProject(dir)?.id, "p1")
    assert.throws(() => writeProjectNotes(dir, [...two, { title: "SETUP", text: "" }]))
    // invalid notes in the file: the project still opens, the notes say what is wrong
    const file = join(dir, "project.json")
    writeFileSync(file, '{"id": "p1", "notes": "x"}')
    assert.equal(readProject(dir)?.id, "p1")
    assert.throws(() => readProjectNotes(dir), (e) => e instanceof UnusableFileError)
})

test("a run's snapshot carries the project's notes (project.json) and the buffer's", () => {
    const root = tempDir()
    const dir = createProject(root, "p2", hooks)
    writeProjectNotes(dir, two)
    writeSolutes(dir, [row], undefined, undefined, [{ title: "buf", text: "b" }])
    writeFileSync(join(dir, "data.tsv"), "0.1\t1\t0.1\n")
    writeFileSync(join(dir, "data.json"), "{}\n")
    const run = claimRun(dir)
    snapshotInputs(dir, run.dir)
    const info = JSON.parse(readFileSync(join(run.dir, "project.json"), "utf-8"))
    assert.equal(info.id, "p2")
    assert.deepEqual(info.notes, two)
    const buffer = JSON.parse(readFileSync(join(run.dir, "buffer.json"), "utf-8"))
    assert.deepEqual(buffer.notes, [{ title: "buf", text: "b" }])
})

// ========================================================================================
// 3. The screens
// ========================================================================================

function draw(screen: ReactElement, columns = 80): string[] {
    return drawScreen(screen, columns).split("\n")
}

function fits(lines: string[], columns: number, what: string): void {
    assert.ok(lines.length <= 24, `${what}: ${lines.length} rows`)
    for (const line of lines)
        assert.ok(displayWidth(line) <= columns, `${what}: ${line}`)
}

test("the notes editor fits 80 x 24 with its text, counter and keys", () => {
    const text = Array.from({ length: 40 }, (_, i) => `line ${i + 1} ${"word ".repeat(30)}`)
    for (const initial of ["", "short\nnotes", text.join("\n")])
        for (const columns of [80, 100]) {
            const lines = draw(
                createElement(NotesEditor, {
                    owner: "SEC buffer",
                    title: "setup",
                    initial,
                                        onSave: () => undefined,
                }),
                columns,
            )
            fits(lines, columns, "notes editor")
            const all = lines.join("\n")
            assert.ok(all.includes("SEC buffer / setup"), all)
            assert.ok(all.includes(" characters"), all)
            for (const label of ["back:", "new line:", "move:"])
                assert.ok(all.includes(label), `${label} in\n${all}`)
            assert.ok(/save:\s+\^w/.test(all), `save is always in the legend:\n${all}`)
            assert.ok(!all.includes("discard"), "no discard question")
        }
})

test("the editor's ^w goes through the list's save, owners take it", () => {
    const drafts = Drafts.of(two)
    const next = withNoteText(drafts, 1, "new text")
    assert.deepEqual(next.toSave(), [two[0], { title: "source", text: "new text" }])
    assert.equal(next.commit().dirty, false, "adopted as saved")
    // project owner: the save writes project.json at once
    const dir = createProject(tempDir(), "p3", hooks)
    writeProjectNotes(dir, next.toSave())
    assert.equal(readProjectNotes(dir)[1]?.text, "new text")
    // recipe and buffer owners: the notes go into the table's draft; its save writes
    const root = tempDir()
    writeRecipes(root, [withNotes(recipe("R"), next.toSave())])
    assert.equal(readRecipes(root)[0]?.notes?.[1]?.text, "new text")
    const bdir = tempDir()
    writeSolutes(bdir, [row], undefined, undefined, next.toSave())
    assert.equal(readBufferNotes(bdir)[1]?.text, "new text")
    // a list that would not be valid throws, for the editor to tell
    const clash = Drafts.of([{ title: "a", text: "" }, { title: "A", text: "" }])
    assert.throws(() => withNoteText(clash, 0, "x"), /title in use/)
})

test("the notes list shows titles and first lines and fits 80 x 24", () => {
    for (const columns of [80, 100]) {
        const lines = draw(
            createElement(NotesList, { owner: "SEC", items: two, onSave: () => undefined }),
            columns,
        )
        fits(lines, columns, "notes list")
        const all = lines.join("\n")
        for (const word of ["setup", "source", "line 1", "new note:", "rename:"])
            assert.ok(all.includes(word), `${word} in\n${all}`)
        assert.ok(!all.includes("line 2"), "only the first line")
    }
})

test("the recipes table has a notes column and shift+n, and fits 80 x 24", () => {
    const home = tempDir("baysol-notes-")
    process.env.BAYSOL_HOME = home
    process.env.BAYSOL_CACHE = `${home}/cache`
    writeRecipes(home, [recipe("with notes", { notes: two }), recipe("plain")])
    for (const columns of [80, 100]) {
        const lines = draw(createElement(RecipesTable), columns)
        fits(lines, columns, "recipes")
        const all = lines.join("\n")
        assert.ok(all.includes("setup, so"), all)
        assert.ok(/notes:\s+shift\+n/.test(all), `the key is in the legend:\n${all}`)
        assert.ok(!all.includes("unsaved") && !all.includes("*"), "no unsaved state")
        assert.ok(!/save:/.test(all), "save only while a recipe is marked")
        assert.ok(/delete:\s+\^r/.test(all), `delete is in the legend:\n${all}`)
        assert.ok(!/undo:/.test(all), "undo only on a mark")
    }
})

test("the buffer table offers notes: shift+n and fits 80 x 24", () => {
    const lines = draw(createElement(SolutesTable, {
            items: [],
            save: () => undefined,
            onNotes: () => undefined,
        }))
    fits(lines, 80, "buffer table")
    assert.ok(/notes:\s+shift\+n/.test(lines.join("\n")), lines.join("\n"))
})

test("the project menu offers notes: shift+n", () => {
    assert.equal(taskbarKeys.notes.label, "notes")
    assert.equal(taskbarKeys.notes.key.label, "shift+n")
})
