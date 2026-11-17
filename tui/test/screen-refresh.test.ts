// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the screen refresh (`ui/screen-refresh.ts`): the frame taken out of Ink's
// writes, the bytes that paint it again, the guards, the timer and the triggers, with a
// fake terminal and fake timers.

import assert from "node:assert/strict"
import { EventEmitter } from "node:events"
import { afterEach, beforeEach, mock, test } from "node:test"
import {
    BSU,
    ESU,
    FOCUS_OFF,
    FOCUS_ON,
    installScreenRefresh,
    mayRefresh,
    type RecordedFrame,
    type RefreshState,
    recordFrame,
    replaySequence,
    ScreenRefresher,
    SETTLE_MS,
} from "../src/ui/screen-refresh.js"
import { type Placement, SixelPainter } from "../src/ui/sixel-view.js"

const ESC = "\u001b"
const COLS = 20
const ROWS = 4

/** What Ink puts before a frame that replaces one of `n` lines. */
const eraseLines = (n: number): string => {
    let out = ""
    for (let i = 0; i < n; i++) out += `${ESC}[2K${i < n - 1 ? `${ESC}[1A` : ""}`
    return n > 0 ? `${out}${ESC}[G` : out
}

/** A fake terminal: records every write that reaches it. */
class FakeTerminal extends EventEmitter {
    isTTY = true
    columns = COLS
    rows = ROWS
    out: string[] = []
    write = (chunk: unknown, ..._rest: unknown[]): boolean => {
        this.out.push(String(chunk))
        return true
    }
}

/** A fake stdin: `read` hands out what was pushed, then null. */
class FakeInput extends EventEmitter {
    queue: string[] = []
    read = (): string | null => this.queue.shift() ?? null
}

/** The way Ink writes a synchronized frame (three writes). */
function inkFrame(term: FakeTerminal, text: string, previousLines: number): void {
    term.write(BSU)
    term.write(eraseLines(previousLines) + text)
    term.write(ESU)
}

type Rig = {
    term: FakeTerminal
    input: FakeInput
    refresher: ScreenRefresher
    shown: { value: boolean }
}

function rig(seconds = 5): Rig {
    const term = new FakeTerminal()
    const input = new FakeInput()
    const shown = { value: false }
    const refresher = new ScreenRefresher({
        stream: term as unknown as NodeJS.WriteStream,
        stdin: input as unknown as NodeJS.ReadStream,
        seconds,
        sixelShown: () => shown.value,
    })
    refresher.install()
    return { term, input, refresher, shown }
}

/** The writes that are replays (a BSU, the address of row 1 and an ESU in ONE write). */
const replays = (term: FakeTerminal): string[] =>
    term.out.filter((w) => w.startsWith(`${BSU}${ESC}[1;1H`))

beforeEach(() => {
    mock.timers.enable({ apis: ["setTimeout", "Date"] })
})

afterEach(() => {
    mock.timers.reset()
})

// ----------------------------------------------------------------------------------------
// Pure parts
// ----------------------------------------------------------------------------------------

test("recordFrame: the frame behind the erase prefix, a first frame, a home clear", () => {
    const styled = `${ESC}[31mred${ESC}[39m`
    assert.deepEqual(recordFrame(`${eraseLines(2)}ab\n${styled}`, true), {
        lines: ["ab", styled],
        trailingNewline: false,
    })
    assert.deepEqual(recordFrame("one\ntwo\n", true), {
        lines: ["one", "two"],
        trailingNewline: true,
    })
    assert.deepEqual(recordFrame(`${ESC}[1;1H${ESC}[Jtop\nbottom`, false), {
        lines: ["top", "bottom"],
        trailingNewline: false,
    })
})

test("recordFrame: not a frame: bare text outside an update, other escapes, empty", () => {
    assert.equal(recordFrame("bare text", false), undefined)
    assert.equal(recordFrame(`${ESC}]52;c;AAAA\u0007`, true), undefined)
    assert.equal(recordFrame(`${ESC}Pq#0;2;0;0;0${ESC}\\`, true), undefined)
    assert.equal(recordFrame(`${ESC}[3;3Hhello`, true), undefined)
    assert.equal(recordFrame(eraseLines(3), true), undefined)
})

const frame = (over: Partial<RecordedFrame> = {}): RecordedFrame => ({
    lines: ["first", `${ESC}[1mbold${ESC}[22m`],
    trailingNewline: false,
    columns: COLS,
    rows: ROWS,
    ...over,
})

test("replaySequence: absolute rows, text as it is, erase after, no clear before", () => {
    const out = replaySequence(frame())
    assert.ok(out.startsWith(BSU) && out.endsWith(ESU))
    assert.equal(
        out,
        `${BSU}${ESC}[1;1Hfirst${ESC}[0m${ESC}[K` +
            `${ESC}[2;1H${ESC}[1mbold${ESC}[22m${ESC}[0m${ESC}[K${ESU}`,
    )
    // nothing that clears the screen, a line or the frame comes before the content
    assert.doesNotMatch(out, new RegExp(`${ESC}\\[[0-9;]*J`))
    assert.doesNotMatch(out, new RegExp(`${ESC}\\[2K`))
    assert.doesNotMatch(out, new RegExp(`${ESC}\\[[0-9]*A`))
    assert.ok(out.indexOf(`${ESC}[K`) > out.indexOf("first"))
})

test("replaySequence: a full row has no erase, a trailing newline a last move", () => {
    const full = "x".repeat(COLS)
    const out = replaySequence(frame({ lines: [full, "y"], trailingNewline: true }))
    assert.equal(
        out,
        `${BSU}${ESC}[1;1H${full}${ESC}[0m${ESC}[2;1Hy${ESC}[0m${ESC}[K` +
            `${ESC}[3;1H${ESU}`,
    )
})

const ready: RefreshState = {
    enabled: true,
    tty: true,
    suspended: false,
    inUpdate: false,
    sixel: false,
    hasFrame: true,
    sizeMatches: true,
    sinceWriteMs: SETTLE_MS,
}

test("mayRefresh: every guard on its own stops it", () => {
    assert.equal(mayRefresh(ready), true)
    for (const [name, value] of [
        ["enabled", false],
        ["tty", false],
        ["suspended", true],
        ["inUpdate", true],
        ["sixel", true],
        ["hasFrame", false],
        ["sizeMatches", false],
        ["sinceWriteMs", SETTLE_MS - 1],
    ] as const)
        assert.equal(mayRefresh({ ...ready, [name]: value }), false, name)
})

// ----------------------------------------------------------------------------------------
// The refresher
// ----------------------------------------------------------------------------------------

test("idle timer: replays the frame once the quiet time has passed, then repeats", () => {
    const { term } = rig(5)
    inkFrame(term, "aa\nbb", 0)
    assert.equal(replays(term).length, 0)
    mock.timers.tick(4999)
    assert.equal(replays(term).length, 0)
    mock.timers.tick(1)
    assert.equal(replays(term).length, 1)
    assert.equal(
        replays(term)[0],
        replaySequence({
            lines: ["aa", "bb"],
            trailingNewline: false,
            columns: COLS,
            rows: ROWS,
        }),
    )
    mock.timers.tick(5000)
    assert.equal(replays(term).length, 2)
})

test("idle timer: a write re-arms it", () => {
    const { term } = rig(5)
    inkFrame(term, "aa", 0)
    mock.timers.tick(3000)
    inkFrame(term, "bb", 1)
    mock.timers.tick(3000)
    assert.equal(replays(term).length, 0)
    mock.timers.tick(2000)
    assert.equal(replays(term).length, 1)
    assert.match(replays(term)[0] ?? "", /bb/)
})

test("the refresh's own write does not count as a write (no loop, no re-record)", () => {
    const { term, refresher } = rig(1)
    inkFrame(term, "aa", 0)
    mock.timers.tick(1000)
    assert.equal(replays(term).length, 1)
    assert.deepEqual(refresher.recorded?.lines, ["aa"])
    mock.timers.tick(1000)
    assert.equal(replays(term).length, 2)
})

test("a setting of 0 switches it off: nothing wrapped, no focus reporting", () => {
    const term = new FakeTerminal()
    const before = term.write
    const refresher = new ScreenRefresher({
        stream: term as unknown as NodeJS.WriteStream,
        seconds: 0,
        sixelShown: () => false,
    })
    refresher.install()
    assert.equal(term.write, before)
    inkFrame(term, "aa", 0)
    mock.timers.tick(60_000)
    assert.equal(replays(term).length, 0)
    assert.ok(!term.out.includes(FOCUS_ON))
})

test("no terminal, no frame: nothing is wrapped or replayed", () => {
    const term = new FakeTerminal()
    term.isTTY = false
    const before = term.write
    new ScreenRefresher({
        stream: term as unknown as NodeJS.WriteStream,
        seconds: 1,
        sixelShown: () => false,
    }).install()
    assert.equal(term.write, before)
    const { term: tty } = rig(1)
    mock.timers.tick(10_000)
    assert.equal(replays(tty).length, 0)
})

test("a sixel picture exempts the screen from any refresh", () => {
    const { term, shown } = rig(1)
    inkFrame(term, "aa", 0)
    shown.value = true
    mock.timers.tick(10_000)
    assert.equal(replays(term).length, 0)
    shown.value = false
    mock.timers.tick(1000)
    assert.equal(replays(term).length, 1)
})

test("no replay within 150 ms of a write: the timer waits for the quiet", () => {
    const { term, input } = rig(5)
    inkFrame(term, "aa", 0)
    mock.timers.tick(1000)
    // a focus report asks for a repaint after 150 ms, but a write comes in between
    input.queue.push(`${ESC}[I`)
    input.read()
    mock.timers.tick(100)
    term.write(`${ESC}[?25l`)
    mock.timers.tick(100)
    assert.equal(replays(term).length, 0)
    mock.timers.tick(50)
    assert.equal(replays(term).length, 1)
})

test("a write that is not a frame drops the recording until Ink writes a frame", () => {
    const { term, refresher } = rig(1)
    inkFrame(term, "aa", 0)
    term.write(`${ESC}]52;c;QUJD\u0007`)
    assert.equal(refresher.recorded, undefined)
    mock.timers.tick(5000)
    assert.equal(replays(term).length, 0)
    inkFrame(term, "bb", 1)
    mock.timers.tick(1000)
    assert.equal(replays(term).length, 1)
})

test("a sixel write (a picture drawn by the painter) drops the recording", () => {
    const { term, refresher } = rig(1)
    inkFrame(term, "aa", 0)
    term.write(`${BSU}${ESC}7${ESC}[3;3H${ESC}Pq#0${ESC}\\${ESC}8${ESU}`)
    assert.equal(refresher.recorded, undefined)
})

test("a resize makes the recording stale until Ink redraws, and asks for a repaint", () => {
    const { term, refresher } = rig(60)
    inkFrame(term, "aa", 0)
    term.columns = COLS + 10
    term.emit("resize")
    mock.timers.tick(SETTLE_MS)
    // the frame was written for the old size: no replay
    assert.equal(replays(term).length, 0)
    term.emit("resize")
    inkFrame(term, "cc", 1)
    term.emit("resize")
    mock.timers.tick(SETTLE_MS)
    assert.equal(replays(term).length, 1)
    assert.equal(refresher.recorded?.columns, COLS + 10)
})

test("focus-in repaints after the settle time and is not taken from Ink", () => {
    const { term, input } = rig(60)
    inkFrame(term, "aa", 0)
    mock.timers.tick(1000)
    input.queue.push(`${ESC}[O`, `${ESC}[I`, "x")
    assert.equal(input.read(), `${ESC}[O`)
    mock.timers.tick(SETTLE_MS)
    assert.equal(replays(term).length, 0)
    assert.equal(input.read(), `${ESC}[I`)
    assert.equal(input.read(), "x")
    assert.equal(input.read(), null)
    mock.timers.tick(SETTLE_MS)
    assert.equal(replays(term).length, 1)
})

test("focus reporting: on at install, off around a suspension, off at exit", () => {
    const { term, refresher } = rig(1)
    assert.deepEqual(term.out, [FOCUS_ON])
    inkFrame(term, "aa", 0)
    // suspendTerminal: Ink leaves the alternate screen, later enters it again
    term.write(`${ESC}[?1049l`)
    assert.equal(term.out.at(-1), FOCUS_OFF)
    mock.timers.tick(10_000)
    assert.equal(replays(term).length, 0)
    term.write(`${ESC}[?1049h`)
    assert.equal(term.out.at(-1), FOCUS_ON)
    mock.timers.tick(10_000)
    assert.equal(replays(term).length, 0)
    inkFrame(term, "bb", 1)
    mock.timers.tick(1000)
    assert.equal(replays(term).length, 1)
    refresher.uninstall()
    assert.equal(term.out.at(-1), FOCUS_OFF)
})

test("uninstall puts the writers back and stops the timer", () => {
    const term = new FakeTerminal()
    const input = new FakeInput()
    const write = term.write
    const read = input.read
    const refresher = new ScreenRefresher({
        stream: term as unknown as NodeJS.WriteStream,
        stdin: input as unknown as NodeJS.ReadStream,
        seconds: 1,
        sixelShown: () => false,
    })
    refresher.install()
    assert.notEqual(term.write, write)
    inkFrame(term, "aa", 0)
    refresher.uninstall()
    assert.equal(term.write, write)
    assert.equal(input.read, read)
    mock.timers.tick(10_000)
    assert.equal(replays(term).length, 0)
})

test("installScreenRefresh: the stop it returns takes the wrapper away", () => {
    const term = new FakeTerminal()
    const before = term.write
    const stop = installScreenRefresh({
        stream: term as unknown as NodeJS.WriteStream,
        stdin: undefined,
        seconds: 1,
    })
    assert.notEqual(term.write, before)
    stop()
    assert.equal(term.write, before)
})

// ----------------------------------------------------------------------------------------
// Stacking with the sixel painter, and Ink's writes staying as they are
// ----------------------------------------------------------------------------------------

const place: Placement = {
    owner: "t",
    key: "k",
    row: 2,
    column: 2,
    rows: 1,
    columns: 3,
    sequence: "SIX",
    offsetColumns: 0,
    offsetRows: 0,
}

/** What reaches the sink when Ink writes frames with a picture shown. */
function run(order: "none" | "refresh-first" | "painter-first"): string[] {
    const term = new FakeTerminal()
    const sink = term.out
    const stream = term as unknown as NodeJS.WriteStream
    const painter = new SixelPainter(stream, 30, true)
    const refresher = new ScreenRefresher({
        stream,
        stdin: undefined,
        seconds: 1,
        sixelShown: () => painter.shown !== undefined,
    })
    if (order === "refresh-first") refresher.install()
    painter.show(place)
    if (order === "painter-first") refresher.install()
    for (const [i, text] of ["aa\nbb", "cc\ndd", "ee\nff"].entries())
        inkFrame(term, text, i === 0 ? 0 : 2)
    // the focus switch is the refresher's own write: leave it out of the comparison
    const result = sink.filter((w) => w !== FOCUS_ON)
    refresher.uninstall()
    painter.detach()
    return result
}

test("stacking with the painter in either order keeps Ink's writes as they are", () => {
    const alone = run("none")
    assert.ok(alone.length > 3)
    assert.deepEqual(run("refresh-first"), alone)
    assert.deepEqual(run("painter-first"), alone)
})

test("with the painter's wrapper on top of ours, a picture still stops the refresh", () => {
    for (const order of ["refresh-first", "painter-first"] as const) {
        const term = new FakeTerminal()
        const stream = term as unknown as NodeJS.WriteStream
        const painter = new SixelPainter(stream, 30, true)
        const refresher = new ScreenRefresher({
            stream,
            stdin: undefined,
            seconds: 1,
            sixelShown: () => painter.shown !== undefined,
        })
        if (order === "refresh-first") refresher.install()
        painter.show(place)
        if (order === "painter-first") refresher.install()
        inkFrame(term, "aa", 0)
        mock.timers.tick(30_000)
        assert.equal(replays(term).length, 0, order)
        painter.hide()
        inkFrame(term, "bb", 1)
        mock.timers.tick(1000)
        assert.equal(replays(term).length, 1, order)
        refresher.uninstall()
        painter.detach()
    }
})

test("the wrapper hands every write on with its own arguments", () => {
    const term = new FakeTerminal()
    const seen: unknown[][] = []
    term.write = (...args: unknown[]): boolean => {
        seen.push(args)
        return true
    }
    const refresher = new ScreenRefresher({
        stream: term as unknown as NodeJS.WriteStream,
        seconds: 1,
        sixelShown: () => false,
    })
    refresher.install()
    const callback = (): void => {}
    term.write("x", "utf8", callback)
    assert.deepEqual(seen.at(-1), ["x", "utf8", callback])
    refresher.uninstall()
})
