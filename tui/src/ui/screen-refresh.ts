// SPDX-License-Identifier: LGPL-3.0-or-later

// Screen refresh: a periodic, flicker-free REPAINT of Ink's last frame. THIS IS A
// WORKAROUND, and a deliberately removable one.
//
// What: the module remembers the last complete frame Ink wrote to the terminal and, now
// and then, writes it again IN PLACE: inside a synchronized update, each row at an
// absolute position (`CSI row;1 H`), the row's text exactly as Ink wrote it, then
// `CSI K` (erase to the end of the row). Nothing is cleared first, so a cell that was
// already right is painted with the same bytes again and nothing flickers.
//
// Why: the owner sees stray characters on screen (bars especially). Ink's byte stream was
// checked and is correct, so the cause is taken to be the terminal's own refresh; a
// repaint of the frame puts every cell back right whatever the terminal did to it.
//
// When it repaints: `refreshSeconds` (run_flow.json, `screen`) after the last write to
// stdout (every write re-arms the timer, and an idle screen repeats), after a window
// resize, and when the terminal reports focus (`CSI ? 1004 h`; the replies `CSI I` and
// `CSI O` are read from stdin without taking them: Ink 8 itself discards a complete
// control sequence that is no key, so a screen never sees them). It NEVER repaints while:
// a write came less than `SETTLE_MS` ago, a sixel picture is shown (exempt: the picture
// must not be disturbed), the terminal belongs to a child program (between Ink's
// `CSI ? 1049 l` and `h`), the recorded frame is stale (another write that is not a frame
// came since, or the terminal size changed since it was written), stdout is no terminal,
// or no frame was recorded.
//
// How it hooks: ONE wrapper of `stream.write` that only LOOKS at what goes by and hands
// every write on, byte for byte, in order and at once, plus a tail of `stdin.read` that
// only looks. [[installScreenRefresh]] is the ONE wiring point (called once in `main.tsx`
// before `render`). The wrapper stacks with the sixel painter's in either order.
//
// How to remove it: delete the `installScreenRefresh()` call (and its import) in
// `main.tsx`; the program then runs as before. For good: delete this file,
// `test/screen-refresh.test.ts`, the `screen.refreshSeconds` key (run_flow.json, the
// `RunFlow` type, its docstring, the key tree in `test/settings.test.ts`), `sixelShown`
// in `ui/sixel-view.tsx` and the section "Screen refresh (workaround)" of notes/tui.md.
// Setting `refreshSeconds` to 0 switches it off without a code change.

import stringWidth from "string-width"
import { RUN_FLOW } from "../core/environment.js"
import { sixelShown } from "./sixel-view.js"

const ESC = "\u001b"

/** Begin and end of a synchronized update, as Ink writes them. */
export const BSU = `${ESC}[?2026h`
export const ESU = `${ESC}[?2026l`

/** Focus reporting on and off, and the alternate screen (left and entered again). */
export const FOCUS_ON = `${ESC}[?1004h`
export const FOCUS_OFF = `${ESC}[?1004l`
const ALT_SCREEN_LEAVE = `${ESC}[?1049l`
const ALT_SCREEN_ENTER = `${ESC}[?1049h`

/** Focus-in as the terminal reports it (focus-out, `CSI O`, is not wanted). */
const FOCUS_IN = `${ESC}[I`

/** Erase to the end of the row, and the reset of the text style. */
const ERASE_TO_END = `${ESC}[K`
const RESET = `${ESC}[0m`

/** The least milliseconds after a write before a repaint may happen. */
export const SETTLE_MS = 150

/** Writes that are no screen content: cursor show/hide, focus, sync, keyboard protocol. */
const HARMLESS = new RegExp(
    `^(?:${ESC}\\[\\?(?:25|1004|2026)[hl]|${ESC}\\[[<>?][0-9;]*u)+$`,
)

/** What Ink puts before a frame: `eraseLines(n)` (n >= 1) or home and erase down. */
const ERASE_LINES = new RegExp(`^(?:${ESC}\\[2K(?:${ESC}\\[1A)?)+${ESC}\\[G`)
const HOME_ERASE = `${ESC}[1;1H${ESC}[J`

/** The only escape sequences a frame may hold: styles. Anything else is not replayed. */
const STYLE = new RegExp(`${ESC}\\[[0-9;]*m`, "g")

/** The write function of a stream. */
type WriteFn = NodeJS.WriteStream["write"]

/**
 * A frame Ink wrote.
 *
 * @property lines - the rows, with their styles, as Ink wrote them.
 * @property trailingNewline - Ink ended the frame with a line feed (the cursor was left
 *     on the row below the frame; a frame as tall as the terminal has none).
 * @property columns - the terminal width when it was written.
 * @property rows - the terminal height when it was written.
 */
export type RecordedFrame = {
    lines: string[]
    trailingNewline: boolean
    columns: number
    rows: number
}

/**
 * Takes the frame out of one write of Ink.
 *
 * @param chunk - the text of one `stdout.write`.
 * @param inUpdate - the write is inside Ink's synchronized update (a first frame, with
 *     nothing to erase, is bare text and is taken only there).
 * @returns the frame's rows and whether it ended with a line feed, or `undefined` when the
 *     write is no frame (an escape sequence other than styles is in it, or it is empty).
 */
export function recordFrame(
    chunk: string,
    inUpdate: boolean,
): { lines: string[]; trailingNewline: boolean } | undefined {
    let text = chunk
    const erase = ERASE_LINES.exec(text)
    if (erase !== null) text = text.slice(erase[0].length)
    else if (text.startsWith(HOME_ERASE)) text = text.slice(HOME_ERASE.length)
    else if (!inUpdate) return undefined
    if (text === "" || text.replace(STYLE, "").includes(ESC)) return undefined
    const trailingNewline = text.endsWith("\n")
    if (trailingNewline) text = text.slice(0, -1)
    return { lines: text.split("\n"), trailingNewline }
}

/**
 * The bytes that paint a frame again in place.
 *
 * @param frame - the recorded frame.
 * @returns a synchronized update with, per row, an absolute cursor position, the row's
 *     text, a style reset and an erase to the end of the row (left out where the row
 *     fills the width: the cursor waits at the last column and the erase would take
 *     the last cell), then the cursor where Ink left it. No screen or line erase
 *     comes before the content.
 */
export function replaySequence(frame: RecordedFrame): string {
    let out = BSU
    frame.lines.forEach((line, i) => {
        const full = stringWidth(line) >= frame.columns
        out += `${ESC}[${i + 1};1H${line}${RESET}${full ? "" : ERASE_TO_END}`
    })
    if (frame.trailingNewline) out += `${ESC}[${frame.lines.length + 1};1H`
    return out + ESU
}

/**
 * What decides whether a repaint may happen now.
 *
 * @property enabled - the refresh is on and installed.
 * @property tty - stdout is a terminal.
 * @property suspended - a child program has the terminal.
 * @property inUpdate - Ink is in the middle of a synchronized update.
 * @property sixel - a sixel picture is shown.
 * @property hasFrame - a frame is recorded and no later write made it stale.
 * @property sizeMatches - the terminal has the size it had when the frame was written.
 * @property sinceWriteMs - milliseconds since the last write to stdout.
 */
export type RefreshState = {
    enabled: boolean
    tty: boolean
    suspended: boolean
    inUpdate: boolean
    sixel: boolean
    hasFrame: boolean
    sizeMatches: boolean
    sinceWriteMs: number
}

/**
 * @param state - the situation.
 * @returns whether a repaint is allowed: every guard must pass.
 */
export function mayRefresh(state: RefreshState): boolean {
    return (
        state.enabled &&
        state.tty &&
        !state.suspended &&
        !state.inUpdate &&
        !state.sixel &&
        state.hasFrame &&
        state.sizeMatches &&
        state.sinceWriteMs >= SETTLE_MS
    )
}

/**
 * What the refresher is given.
 *
 * @property stream - the terminal (`process.stdout`).
 * @property stdin - where the focus reports come from (`process.stdin`); none is read
 *     when left out.
 * @property seconds - the idle time before a repaint (0 switches the refresh off).
 * @property sixelShown - whether a sixel picture is shown now.
 */
export type RefreshOptions = {
    stream: NodeJS.WriteStream
    stdin?: NodeJS.ReadStream
    seconds: number
    sixelShown: () => boolean
}

/**
 * Watches the writes to a terminal, keeps the last frame and repaints it. Made by
 * [[installScreenRefresh]]; the class is exported for the tests.
 */
export class ScreenRefresher {
    private original: WriteFn | undefined
    private wrapper: WriteFn | undefined
    private originalRead: NodeJS.ReadStream["read"] | undefined
    private readWrapper: NodeJS.ReadStream["read"] | undefined
    private disabled = false
    private frame: RecordedFrame | undefined
    private pending: RecordedFrame | undefined
    private inUpdate = false
    private tainted = false
    private suspended = false
    private lastWrite = Number.NEGATIVE_INFINITY
    private timer: NodeJS.Timeout | undefined
    private wanted = false
    private own = false
    private focusOn = false

    /** @param options - the terminal, the input, the delay and the picture query. */
    constructor(private readonly options: RefreshOptions) {}

    /** @returns the recorded frame, `undefined` when none or when it went stale (tests). */
    get recorded(): RecordedFrame | undefined {
        return this.frame
    }

    /** Wraps `stream.write` and `stdin.read`, turns focus reporting on, arms the timer. */
    install(): void {
        const { stream, stdin, seconds } = this.options
        if (seconds <= 0 || stream.isTTY !== true || this.wrapper !== undefined) return
        const original = stream.write
        const self = this
        const wrapper = function (this: unknown, ...args: unknown[]): boolean {
            const pass = original as (...a: unknown[]) => boolean
            if (self.disabled) return pass.apply(stream, args)
            self.look(args[0])
            const result = pass.apply(stream, args)
            self.afterWrite(args[0])
            return result
        } as WriteFn
        this.original = original
        this.wrapper = wrapper
        stream.write = wrapper
        stream.on("resize", this.onResize)
        if (stdin !== undefined) {
            const read = stdin.read
            this.originalRead = read
            const readWrapper = function (this: unknown, ...args: unknown[]): unknown {
                const chunk = (read as (...a: unknown[]) => unknown).apply(stdin, args)
                if (chunk !== null && chunk !== undefined) {
                    if (String(chunk).includes(FOCUS_IN)) self.request()
                }
                return chunk
            } as NodeJS.ReadStream["read"]
            this.readWrapper = readWrapper
            stdin.read = readWrapper
        }
        this.setFocus(true)
        this.arm()
    }

    /** Takes everything back: the timer, the wrappers (when still on top), focus. */
    uninstall(): void {
        const { stream, stdin } = this.options
        if (this.wrapper === undefined) return
        this.disarm()
        this.setFocus(false)
        stream.off("resize", this.onResize)
        // a wrapper that another layer sits on cannot be unlinked: it passes through
        this.disabled = true
        if (stream.write === this.wrapper && this.original !== undefined)
            stream.write = this.original
        if (stdin !== undefined && stdin.read === this.readWrapper && this.originalRead)
            stdin.read = this.originalRead
        this.wrapper = undefined
        this.frame = undefined
    }

    /** A resize asks for a repaint once Ink has redrawn. */
    private readonly onResize = (): void => this.request()

    /** Asks for a repaint after the settle time. */
    private request(): void {
        this.wanted = true
        this.arm()
    }

    /** Writes focus reporting on or off, unless it is already so (own write). */
    private setFocus(on: boolean): void {
        if (this.focusOn === on) return
        this.focusOn = on
        this.ownWrite(on ? FOCUS_ON : FOCUS_OFF)
    }

    private ownWrite(text: string): void {
        this.own = true
        try {
            this.options.stream.write(text)
        } finally {
            this.own = false
        }
    }

    private forget(): void {
        this.frame = undefined
        this.pending = undefined
    }

    /** Looks at one write BEFORE it goes on: what it does to the recorded frame. */
    private look(chunk: unknown): void {
        if (this.own) return
        this.lastWrite = Date.now()
        if (typeof chunk !== "string") {
            this.forget()
            return
        }
        // the terminal goes to a child program and comes back
        if (chunk.includes(ALT_SCREEN_LEAVE)) {
            this.suspended = true
            this.inUpdate = false
            this.forget()
            return
        }
        if (chunk.includes(ALT_SCREEN_ENTER)) {
            this.suspended = false
            this.forget()
            return
        }
        if (chunk === BSU) {
            this.inUpdate = true
            this.pending = undefined
            this.tainted = false
            return
        }
        if (this.inUpdate) {
            if (chunk === ESU) {
                this.inUpdate = false
                if (this.tainted) {
                    this.forget()
                    return
                }
                if (this.pending !== undefined) this.frame = this.pending
                this.pending = undefined
                return
            }
            if (chunk.endsWith(ESU)) {
                // the sixel painter's picture put in front of the closing marker
                this.inUpdate = false
                this.forget()
                return
            }
            if (HARMLESS.test(chunk)) return
            const found = recordFrame(chunk, true)
            const sized = found === undefined ? undefined : this.sized(found)
            if (sized === undefined || this.pending !== undefined) this.tainted = true
            else this.pending = sized
            return
        }
        if (HARMLESS.test(chunk)) return
        const found = chunk.startsWith(BSU) ? undefined : recordFrame(chunk, false)
        if (found === undefined) {
            this.forget()
            return
        }
        this.frame = this.sized(found)
    }

    /** Adds the terminal size to a frame, or drops a frame taller than the terminal. */
    private sized(found: {
        lines: string[]
        trailingNewline: boolean
    }): RecordedFrame | undefined {
        const { columns, rows } = this.options.stream
        if (!(columns > 0 && rows > 0) || found.lines.length > rows) return undefined
        return { ...found, columns, rows }
    }

    /** After a write has gone on: focus follows the alternate screen, the timer re-arms. */
    private afterWrite(chunk: unknown): void {
        if (this.own) return
        if (typeof chunk === "string") {
            if (chunk.includes(ALT_SCREEN_LEAVE)) this.setFocus(false)
            else if (chunk.includes(ALT_SCREEN_ENTER)) this.setFocus(true)
        }
        this.arm()
    }

    private disarm(): void {
        if (this.timer !== undefined) clearTimeout(this.timer)
        this.timer = undefined
    }

    /** (Re)starts the timer: the settle time for a wanted repaint, else the idle time. */
    private arm(): void {
        this.disarm()
        if (this.disabled) return
        const delay = this.wanted ? SETTLE_MS : this.options.seconds * 1000
        this.timer = setTimeout(() => this.tick(), delay)
        this.timer.unref()
    }

    private tick(): void {
        this.timer = undefined
        const since = Date.now() - this.lastWrite
        if (since < SETTLE_MS) {
            this.timer = setTimeout(() => this.tick(), SETTLE_MS - since)
            this.timer.unref()
            return
        }
        if (this.state(since) && this.frame !== undefined) this.refresh(this.frame)
        this.wanted = false
        this.arm()
    }

    private state(sinceWriteMs: number): boolean {
        const { stream } = this.options
        const frame = this.frame
        return mayRefresh({
            enabled: !this.disabled,
            tty: stream.isTTY === true,
            suspended: this.suspended,
            inUpdate: this.inUpdate,
            sixel: this.options.sixelShown(),
            hasFrame: frame !== undefined,
            sizeMatches:
                frame !== undefined &&
                frame.columns === stream.columns &&
                frame.rows === stream.rows,
            sinceWriteMs,
        })
    }

    /** Paints the frame again: one write, not counted as one of Ink's. */
    private refresh(frame: RecordedFrame): void {
        this.ownWrite(replaySequence(frame))
    }
}

/**
 * The ONE wiring point: starts the screen refresh on the program's terminal, once, BEFORE
 * Ink renders (Ink writes its first frame while `render` runs, and a screen that never
 * changes again would otherwise have none recorded). Does nothing (and writes nothing)
 * when `refreshSeconds` is 0 or stdout is no terminal. It ends by itself when Ink leaves
 * the alternate screen (no repaint after that, focus reporting off) and at process exit.
 *
 * @param options - the terminal, the delay and the picture query (default: the process's
 *     streams, `RUN_FLOW.screen.refreshSeconds`, the sixel painter).
 * @returns the function that takes the refresh away again.
 */
export function installScreenRefresh(
    options: Partial<RefreshOptions> = {},
): () => void {
    const refresher = new ScreenRefresher({
        stream: process.stdout,
        stdin: process.stdin,
        seconds: RUN_FLOW.screen.refreshSeconds,
        sixelShown,
        ...options,
    })
    refresher.install()
    const stop = (): void => refresher.uninstall()
    process.on("exit", stop)
    return stop
}
