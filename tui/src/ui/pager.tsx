// SPDX-License-Identifier: LGPL-3.0-or-later

// The pager: ONE way to read a text of several pages (a run's `run.LOG`, every view of the
// logs menu, the Unicode plots of the viewer). The same keys everywhere (shift+↓ and PgDn
// a page down, shift+↑ and PgUp a page up, the arrows a line, Home and End), find (`/`),
// the next and previous match, go to a line, mark (Space) and copy, and one status line,
// `lines 1-15 of 63 · 24%`.
//
// Contents:
//   1. Pure helpers: the page keys, the search, go to a line, the status line
//   2. `usePager`: the cursor, window, mark and search of a text, and its keys
//   3. `PagerLine` and `PagerPrompt`: one line drawn, the find and go-to prompt

import { Text } from "ink"
import { type ReactNode, useState } from "react"
import { displayWidth, writeTerminal } from "../core/terminal.js"
import {
    COPY_LIMIT,
    clampTop,
    clipboardSequence,
    lastTop,
    pagerStatus,
    pageTop,
    sliceCells,
} from "../store/view.js"
import { type LegendItem, legendFor, legendOf, moveLegend } from "./grid.js"
import { Prompt } from "./input.js"
import { type KeyInput, keys, scrollWindow } from "./interaction.js"
import { useTheme } from "./theme.js"

// ========================================================================================
// 1. Pure helpers
// ========================================================================================

/**
 * Whether a press turns a page, and which way. The Shift keys are tested before anything
 * else reads the arrows: a plain `keys.down` also matches shift+↓ (see `KeyInput.is`).
 *
 * @param press - the press.
 * @returns `"down"` for shift+↓ and PgDn, `"up"` for shift+↑ and PgUp, else `undefined`.
 */
export function pageKey(press: KeyInput): "down" | "up" | undefined {
    if (press.is(keys.pageDownShift) || press.is(keys.pageDown)) return "down"
    if (press.is(keys.pageUpShift) || press.is(keys.pageUp)) return "up"
    return undefined
}

/** The legend items of the page keys: both keys of each, the Shift arrow first. */
export const pageLegend = {
    next: legendFor("next page", keys.pageDownShift, keys.pageDown),
    prev: legendFor("prev page", keys.pageUpShift, keys.pageUp),
} as const

/**
 * The lines that contain a text, case-insensitively.
 *
 * @param lines - the lines.
 * @param text - what is searched; an empty text finds nothing.
 * @returns the indices of the lines, in order.
 */
export function findLines(lines: readonly string[], text: string): number[] {
    if (text === "") return []
    const wanted = text.toLowerCase()
    return lines.flatMap((line, i) => (line.toLowerCase().includes(wanted) ? [i] : []))
}

/**
 * The match a step from a line goes to, round the ends.
 *
 * @param matches - the lines that match, in order.
 * @param from - the line the cursor is on.
 * @param dir - 1 for the next match after `from`, -1 for the one before it, 0 for the
 *     first at or after it.
 * @returns the line, or `undefined` when there is no match.
 */
export function stepMatch(
    matches: readonly number[],
    from: number,
    dir: -1 | 0 | 1,
): number | undefined {
    if (matches.length === 0) return undefined
    const last = matches[matches.length - 1]
    if (dir < 0) return [...matches].reverse().find((m) => m < from) ?? last
    return matches.find((m) => (dir === 0 ? m >= from : m > from)) ?? matches[0]
}

/**
 * The line a go-to text names.
 *
 * @param text - what was typed: a line number, 1-based.
 * @param count - how many lines there are.
 * @returns the 0-based line, or the note that says why it is none.
 */
export function parseLine(
    text: string,
    count: number,
): { line: number } | { error: string } {
    const t = text.trim()
    if (!/^\d+$/.test(t)) return { error: "not a line number" }
    const n = Number(t)
    if (n < 1 || n > count) return { error: `no line ${t}: 1 to ${count}` }
    return { line: n - 1 }
}

/**
 * The status line of a pager: which lines are shown, how far down, and the search and the
 * mark when there are any.
 *
 * @param top - the first line shown.
 * @param count - how many lines there are.
 * @param rows - how many fit.
 * @param extra - the match (`match 2 / 5`, `3 matches`) and the mark (`marked 4-9`).
 * @returns the line, `lines 1-15 of 63 · 24%` first.
 */
export function pagerFooter(
    top: number,
    count: number,
    rows: number,
    extra: readonly (string | undefined)[] = [],
): string {
    return [pagerStatus(top, count, rows), ...extra].filter(Boolean).join(" · ")
}

// ========================================================================================
// 2. `usePager`
// ========================================================================================

/** The longest text the find and go-to prompts take. */
const PROMPT_MAX_LENGTH = 200

/** Where one text is: the cursor line, the first line and column shown, the mark. */
type PagerPos = { cursor: number; top: number; left: number; mark?: number }

/** What the pager draws on a line: the cursor, a mark, a match. */
export type LineLook = { cursor: boolean; marked: boolean; match: boolean }

/**
 * A pager over some lines: what is shown, the keys that work now and the handler.
 *
 * @property top - the first line shown.
 * @property left - the first column shown.
 * @property shown - the lines in view, each with its index and how it is drawn.
 * @property asking - the prompt that is open (`find`, `jump`), `undefined` for none.
 * @property search - the text searched, `""` for none.
 * @property can - what works now: each arrow, a page down and up, whether a range is
 *     marked and the search found lines.
 * @property legend - the keys that work now, without `back`/`close`.
 * @property status - the status line (`pagerFooter`).
 * @property handle - takes a press; `true` when it was a pager key.
 * @property submit - the answer of the open prompt.
 * @property cancel - closes the prompt.
 */
export type Pager = {
    top: number
    left: number
    shown: { index: number; text: string; look: LineLook }[]
    asking: "find" | "jump" | undefined
    search: string
    can: {
        up: boolean
        down: boolean
        left: boolean
        right: boolean
        pageUp: boolean
        pageDown: boolean
        marked: boolean
        matches: boolean
    }
    legend: LegendItem[]
    status: string
    handle: (press: KeyInput) => boolean
    submit: (text: string) => void
    cancel: () => void
}

/**
 * The keys a pager can ever show, for the frame to reserve their height.
 *
 * @returns the items, fullest.
 */
export function pagerFullLegend(): LegendItem[] {
    return [
        pageLegend.next,
        pageLegend.prev,
        legendFor("move", [keys.up, keys.down, keys.left, keys.right]),
        legendFor("find", keys.find),
        legendFor("go to", keys.jump),
        legendFor("unmark", keys.mark),
        legendFor("next match", keys.nextMatch),
        legendFor("prev match", keys.prevMatch),
        legendFor("copy", keys.copy),
    ]
}

/**
 * The cursor, window, mark and search of a text of several pages, and its keys. Each
 * text (`id`) keeps its own place, so a viewer with several plots comes back to where
 * each was. The arrows move the cursor (the window follows), the page keys move both a
 * page less `overlap` lines, left and right move sideways by `sideStep` cells.
 *
 * @param props.id - which text this is (a plot tab); the place is kept per id.
 * @param props.lines - the lines.
 * @param props.rows - how many lines fit.
 * @param props.width - how many cells of a line fit.
 * @param props.overlap - the lines a page turn keeps in view.
 * @param props.sideStep - the cells a sideways step moves.
 * @param props.screenEnds - the page keys put the cursor on the last or the first row in
 *     view (the window stays) instead of turning a page, and the legend has no page items.
 * @param props.say - shows a note (`no match`, `copied 3 lines`), an error when `error`.
 * @returns the [[Pager]].
 */
export function usePager(props: {
    id?: string | number
    lines: readonly string[]
    rows: number
    width: number
    overlap: number
    sideStep: number
    screenEnds?: boolean
    say: (text: string, error?: boolean) => void
}): Pager {
    const { id = 0, lines, width, overlap, sideStep, say, screenEnds = false } = props
    const rows = Math.max(1, props.rows)
    const count = lines.length
    const [places, setPlaces] = useState<Record<string, PagerPos>>({})
    const [asking, setAsking] = useState<"find" | "jump" | undefined>()
    const [search, setSearch] = useState("")

    const widest = lines.reduce((m, l) => Math.max(m, displayWidth(l)), 0)
    const maxLeft = Math.max(0, widest - width)
    /** A place kept inside the text: it may have changed (another size of a plot). */
    const clamped = (saved: PagerPos | undefined): PagerPos => {
        const at = saved ?? { cursor: 0, top: 0, left: 0 }
        const c = Math.min(at.cursor, Math.max(0, count - 1))
        return {
            cursor: c,
            top: scrollWindow(c, clampTop(at.top, count, rows), rows, count),
            left: Math.min(at.left, maxLeft),
            mark: at.mark !== undefined && at.mark < count ? at.mark : undefined,
        }
    }
    const { cursor, top, left, mark } = clamped(places[id])
    const range =
        mark === undefined
            ? undefined
            : { from: Math.min(mark, cursor), to: Math.max(mark, cursor) }
    const matches = findLines(lines, search)
    const matchSet = new Set(matches)
    const matchAt = matches.indexOf(cursor)

    // every move is computed from the latest place (an updater), so presses that come
    // faster than the screen is drawn (a held arrow) are all counted
    const update = (move: (at: PagerPos) => Partial<PagerPos>): void =>
        setPlaces((s) => {
            const at = clamped(s[id])
            return { ...s, [id]: { ...at, ...move(at) } }
        })
    const lastLine = Math.max(0, count - 1)
    /** The cursor on a line, the window following it. */
    const onLine = (at: PagerPos, line: number): Partial<PagerPos> => {
        const c = Math.min(Math.max(line, 0), lastLine)
        return { cursor: c, top: scrollWindow(c, at.top, rows, count) }
    }
    const go = (line: number): void => update((at) => onLine(at, line))
    /** A page down or up: the window and the cursor move together; at an end the
     * cursor goes to the first or the last line. */
    const page = (down: boolean): void =>
        update((at) => {
            const t = pageTop(at.top, count, rows, overlap, down)
            const moved = t - at.top
            const c = moved !== 0 ? at.cursor + moved : down ? lastLine : 0
            return { top: t, cursor: Math.min(Math.max(c, 0), lastLine) }
        })
    /** The cursor on the last (or first) row in view; the window stays. */
    const screenEnd = (down: boolean): void =>
        update((at) => ({
            cursor: Math.min(down ? at.top + rows - 1 : at.top, lastLine),
        }))
    const copy = () => {
        if (count === 0) return say("nothing to copy", true)
        const from = range?.from ?? cursor
        const to = range?.to ?? cursor
        const text = lines.slice(from, to + 1).join("\n")
        // the viewer's cap: a terminal is not sent megabytes through OSC 52
        if (Buffer.byteLength(text) > COPY_LIMIT)
            return say(`too much to copy (${COPY_LIMIT / 1024} KB at most)`, true)
        if (!writeTerminal(clipboardSequence(text))) return say("no terminal", true)
        update(() => ({ mark: undefined }))
        const n = to - from + 1
        say(n === 1 ? `copied line ${from + 1}` : `copied ${n} lines`)
    }
    const toMatch = (line: number | undefined) => {
        if (line === undefined) return say("no match")
        go(line)
    }

    const handle = (press: KeyInput): boolean => {
        const turn = pageKey(press)
        if (turn !== undefined) {
            if (screenEnds) screenEnd(turn === "down")
            else page(turn === "down")
        }
        else if (press.is(keys.escape) && range !== undefined)
            update(() => ({ mark: undefined }))
        else if (press.is(keys.up)) update((at) => onLine(at, at.cursor - 1))
        else if (press.is(keys.down)) update((at) => onLine(at, at.cursor + 1))
        else if (press.is(keys.left))
            update((at) => ({ left: Math.max(0, at.left - sideStep) }))
        else if (press.is(keys.right))
            update((at) => ({ left: Math.min(maxLeft, at.left + sideStep) }))
        else if (press.is(keys.home)) update(() => ({ cursor: 0, top: 0 }))
        else if (press.is(keys.end))
            update(() => ({ cursor: lastLine, top: lastTop(count, rows) }))
        else if (count === 0) return false
        else if (press.is(keys.find)) setAsking("find")
        else if (press.is(keys.jump)) setAsking("jump")
        else if (press.is(keys.mark))
            update((at) => ({ mark: at.mark === undefined ? at.cursor : undefined }))
        else if (press.is(keys.copy)) copy()
        else if (press.is(keys.nextMatch) || press.is(keys.prevMatch)) {
            // the keys are in the legend only with matches: before a search they do nothing
            if (search !== "")
                toMatch(stepMatch(matches, cursor, press.is(keys.prevMatch) ? -1 : 1))
        } else return false
        return true
    }

    const submit = (text: string) => {
        const what = asking
        setAsking(undefined)
        if (what === "find") {
            setSearch(text)
            if (text !== "") toMatch(stepMatch(findLines(lines, text), cursor, 0))
            return
        }
        const to = parseLine(text, count)
        if ("error" in to) return say(to.error, true)
        go(to.line)
    }

    const can = {
        up: cursor > 0,
        down: cursor < count - 1,
        left: left > 0,
        right: left < maxLeft,
        pageUp: top > 0 || cursor > 0,
        pageDown: top < lastTop(count, rows) || cursor < count - 1,
        marked: range !== undefined,
        matches: matches.length > 0,
    }
    const legend = legendOf([
        !screenEnds && can.pageDown && pageLegend.next,
        !screenEnds && can.pageUp && pageLegend.prev,
        moveLegend(can),
        count > 0 && legendFor("find", keys.find),
        count > 0 && legendFor("go to", keys.jump),
        count > 0 && legendFor(range ? "unmark" : "mark", keys.mark),
        can.matches && legendFor("next match", keys.nextMatch),
        can.matches && legendFor("prev match", keys.prevMatch),
        count > 0 && legendFor("copy", keys.copy),
    ])

    const status = pagerFooter(top, count, rows, [
        search === ""
            ? undefined
            : matchAt >= 0
                ? `match ${matchAt + 1} / ${matches.length}`
                : `${matches.length} matches`,
        range === undefined ? undefined : `marked ${range.from + 1}-${range.to + 1}`,
    ])

    const shown = lines.slice(top, top + rows).map((line, k) => {
        const index = top + k
        return {
            index,
            text: sliceCells(line, left, width),
            look: {
                cursor: index === cursor,
                marked: range !== undefined && index >= range.from && index <= range.to,
                match: matchSet.has(index),
            },
        }
    })

    return {
        top,
        left,
        shown,
        asking,
        search,
        can,
        legend,
        status,
        handle,
        submit,
        cancel: () => setAsking(undefined),
    }
}

// ========================================================================================
// 3. `PagerLine` and `PagerPrompt`
// ========================================================================================

/**
 * One line of a pager: bold and inverted on the cursor (a text that fits one screen
 * shows its cursor moving), inverted when marked, underlined when it
 * matches the search.
 *
 * @param props.text - the cells of the line in view.
 * @param props.look - how it is drawn.
 * @returns the line (a blank one keeps its row).
 */
export function PagerLine({ text, look }: { text: string; look: LineLook }): ReactNode {
    const theme = useTheme()
    return (
        <Text
            wrap="truncate"
            bold={look.cursor}
            inverse={look.cursor && !look.marked}
            underline={look.match}
            color={look.marked ? theme.bg : theme.fg}
            backgroundColor={look.marked ? theme.mt : undefined}
        >
            {text || " "}
        </Text>
    )
}

/**
 * The prompt of a pager while find or go to asks (else nothing).
 *
 * @param props.pager - the pager.
 * @param props.onLegend - receives the keys of the prompt.
 * @returns the prompt, or `null`.
 */
export function PagerPrompt(props: {
    pager: Pager
    onLegend: (items: LegendItem[]) => void
}): ReactNode {
    const { pager, onLegend } = props
    if (pager.asking === undefined) return null
    const find = pager.asking === "find"
    return (
        <Prompt
            label={find ? "find:" : "go to line:"}
            initial={find ? pager.search : ""}
            maxLength={PROMPT_MAX_LENGTH}
            take={find ? "find" : "go"}
            onLegend={onLegend}
            onSubmit={pager.submit}
            onCancel={pager.cancel}
        />
    )
}
