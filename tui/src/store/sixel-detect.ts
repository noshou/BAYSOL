// SPDX-License-Identifier: LGPL-3.0-or-later

// Sixel support detection: asks the terminal, never guesses from environment variables.
// Three queries are sent in one write, the Primary Device Attributes LAST (every terminal
// answers it, and answers come in the order of the questions, so its reply ends the wait):
//
//   CSI 16 t   cell size in pixels         reply  CSI 6 ; height ; width t
//   CSI 14 t   text area size in pixels    reply  CSI 4 ; height ; width t
//   CSI c      Primary Device Attributes   reply  CSI ? 62 ; 4 ; 6 c   (4 = sixel graphics)
//
// Only these queries are used: no OSC 10/11, and nothing that changes a colour or a mode
// (raw mode is set while waiting and put back as it was).
//
// Contents:
//   1. Parsing the replies (pure)
//   2. Asking the terminal

import type { CellSize, SixelSupport } from "./sixel-types.js"

// ========================================================================================
// 1. Parsing the replies
// ========================================================================================

/** The ESC character. */
const ESC = "\u001b"

/** The three questions, in the order they are sent (DA1 last). */
const SIXEL_QUERY = `${ESC}[16t${ESC}[14t${ESC}[c`

/** The attribute of the Primary Device Attributes reply that means "sixel graphics". */
const DA1_SIXEL = 4

/**
 * What the replies of a terminal said.
 *
 * @property attributes - the numbers of the DA1 reply (`undefined`: none arrived).
 * @property cell - the cell size of a `CSI 6 ; h ; w t` reply.
 * @property textArea - the text area in pixels of a `CSI 4 ; h ; w t` reply.
 * @property done - true when the DA1 reply was seen, so no more replies are due.
 */
export type TerminalReplies = {
    attributes?: number[]
    cell?: CellSize
    textArea?: CellSize
    done: boolean
}

/** A positive integer from a reply field, `undefined` for anything else. */
const positive = (text: string | undefined): number | undefined => {
    const n = Number(text)
    return text !== undefined && /^\d+$/.test(text) && n > 0 ? n : undefined
}

/**
 * Reads the replies in what the terminal wrote to the input (other bytes, such as typed
 * keys, are ignored). Pure.
 *
 * @param text - the bytes read from stdin, as text (latin1 or utf-8 alike: only ASCII is
 *     looked at).
 * @returns what was found; `done` says the DA1 reply was among it.
 */
export function parseTerminalReplies(text: string): TerminalReplies {
    const out: TerminalReplies = { done: false }
    // a DA1 reply: ESC [ ? 62 ; 4 ; 6 c   (the `?` is what tells it from a size reply)
    const da1 = new RegExp(`${ESC}\\[\\?([0-9;]*)c`).exec(text)
    if (da1 !== null) {
        out.attributes = (da1[1] ?? "")
            .split(";")
            .filter((s) => s !== "")
            .map(Number)
        out.done = true
    }
    // CSI 6 ; height ; width t (a cell) and CSI 4 ; height ; width t (the text area)
    for (const m of text.matchAll(new RegExp(`${ESC}\\[([46]);(\\d+);(\\d+)t`, "g"))) {
        const height = positive(m[2])
        const width = positive(m[3])
        if (height === undefined || width === undefined) continue
        if (m[1] === "6") out.cell = { width, height }
        else out.textArea = { width, height }
    }
    return out
}

/**
 * Turns the replies into a verdict. The cell size is the `CSI 16 t` one, else the text
 * area divided by the number of columns and rows (`CSI 14 t`), else unknown.
 *
 * @param replies - [[parseTerminalReplies]]'s result.
 * @param columns - the terminal's width in cells (`stdout.columns`), 0 if unknown.
 * @param rows - the terminal's height in cells, 0 if unknown.
 * @returns the verdict; `supported` needs the sixel attribute AND a cell size.
 */
export function judgeSixel(
    replies: TerminalReplies,
    columns: number,
    rows: number,
): SixelSupport {
    let cell = replies.cell
    if (cell === undefined && replies.textArea !== undefined && columns > 0 && rows > 0) {
        const width = Math.floor(replies.textArea.width / columns)
        const height = Math.floor(replies.textArea.height / rows)
        if (width > 0 && height > 0) cell = { width, height }
    }
    const base = cell === undefined ? {} : { cell }
    if (replies.attributes === undefined)
        return { supported: false, ...base, reason: "the terminal did not answer" }
    if (!replies.attributes.includes(DA1_SIXEL))
        return { supported: false, ...base, reason: "the terminal does not draw sixel" }
    if (cell === undefined)
        return { supported: false, reason: "the cell size in pixels is unknown" }
    return { supported: true, cell, reason: "" }
}

// ========================================================================================
// 2. Asking the terminal
// ========================================================================================

/** The streams [[detectSixel]] talks to (the process's own by default). */
export type DetectStreams = {
    stdin: NodeJS.ReadStream
    stdout: NodeJS.WriteStream
}

/**
 * Asks the terminal whether it draws sixel and how big a cell is. Nothing is thrown:
 * every failure is an unsupported verdict. Needs a tty on both streams. It reads stdin
 * for up to `timeoutMs`, so call it when no one else reads stdin (before Ink starts, or
 * while it is paused); typed keys that arrive meanwhile are lost.
 *
 * @param timeoutMs - how long to wait for the DA1 reply (default 400 ms).
 * @param streams - the stdin/stdout pair (default: the process's).
 * @returns the verdict (see [[SixelSupport]]).
 */
export async function detectSixel(
    timeoutMs = 400,
    streams: DetectStreams = { stdin: process.stdin, stdout: process.stdout },
): Promise<SixelSupport> {
    const { stdin, stdout } = streams
    if (!stdin.isTTY || !stdout.isTTY || typeof stdin.setRawMode !== "function")
        return { supported: false, reason: "not a terminal" }
    const wasRaw = stdin.isRaw
    const wasPaused = stdin.isPaused()
    let received = ""
    try {
        stdin.setRawMode(true)
        stdin.resume()
        return await new Promise<SixelSupport>((resolve) => {
            let timer: NodeJS.Timeout | undefined
            const finish = (): void => {
                if (timer !== undefined) clearTimeout(timer)
                stdin.off("data", onData)
                resolve(
                    judgeSixel(
                        parseTerminalReplies(received),
                        stdout.columns ?? 0,
                        stdout.rows ?? 0,
                    ),
                )
            }
            const onData = (chunk: Buffer | string): void => {
                received += chunk.toString("latin1")
                if (parseTerminalReplies(received).done) finish()
            }
            stdin.on("data", onData)
            timer = setTimeout(finish, timeoutMs)
            stdout.write(SIXEL_QUERY)
        })
    } catch (error) {
        return { supported: false, reason: `the query failed: ${String(error)}` }
    } finally {
        try {
            stdin.setRawMode(wasRaw === true)
            if (wasPaused) stdin.pause()
        } catch {
            // the terminal went away: nothing to restore
        }
    }
}
