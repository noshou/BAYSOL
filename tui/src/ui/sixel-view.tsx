// SPDX-License-Identifier: LGPL-3.0-or-later

// Drawing a sixel graphic in the terminal beside Ink. This is the ONE module that does it.
//
// The problem: Ink lays out text cells and writes a whole frame, and it cannot print a raw
// escape sequence inside its layout. In its normal mode (no incremental rendering) every
// frame that differs from the last one is written as "erase all my lines, write the lines
// again", which also wipes a sixel image; a frame equal to the last one is not written at
// all. The way out:
//
//   1. The screen reserves the area as an empty box ([[SixelArea]]): Ink leaves its cells
//      blank and the layout knows where they are (`measureElement`, in cells from the
//      top-left of the frame, which in the alternate screen is the terminal's).
//   2. [[SixelPainter]] writes the sequence straight to stdout at that place, between
//      `ESC 7` and `ESC 8` (save and restore the cursor) with a `CSI row;col H` to get
//      there, so Ink's idea of where the cursor is stays true.
//   3. The painter watches stdout: whenever Ink writes a frame (not the painter itself)
//      the image is gone, so the picture is drawn again IN THE SAME WRITE: Ink brackets a
//      frame with synchronized-output markers (`CSI ? 2026 h` ... `l`) and the painter puts
//      the picture just before the closing marker, so the terminal shows the new text and
//      the picture together, never a blank area between them. Without the markers the
//      picture is appended to the frame's own write. A write that is not a frame (a cursor
//      sequence) or comes in pieces schedules a redraw a few milliseconds later instead.
//      An unchanged frame is not written by Ink, and then nothing is redrawn.
//   4. Taking the image away ([[SixelPainter.hide]]) writes spaces over the area; it is
//      done when the area unmounts (another screen, the sheets mode, the Unicode view, an
//      overlay that replaces the screen) or the screen stops being the one on top.
//
// Terminal resizes make Ink rewrite the frame (a write, so a redraw) and the area is
// measured again after every commit, so a moved area is drawn where it is now.

import { Box, type DOMElement, measureElement } from "ink"
import { type ReactNode, useId, useLayoutEffect, useRef } from "react"
import { centreCells } from "../store/plot-graphics.js"
import type { CellSize } from "../store/sixel-types.js"
import { useScreenActive } from "./interaction.js"
import type { RefreshStream } from "./screen-refresh.js"
import { useTheme } from "./theme.js"

const ESC = "\u001b"

/** Begin and end of a synchronized update (the terminal shows the whole write at once). */
const BSU = `${ESC}[?2026h`
const ESU = `${ESC}[?2026l`

/** A write made only of escape sequences (a cursor move or show/hide): not a frame. */
const ONLY_ESCAPES = new RegExp(`^(?:${ESC}\\[[?0-9;]*[A-Za-z])+$`)

/** The milliseconds after Ink's last write before the image is drawn again. */
const REPAINT_DELAY_MS = 30

/**
 * Where and what to draw.
 *
 * @property owner - who asked (so a screen under another cannot take the image away).
 * @property key - tells one picture from another: the same key at the same place is not
 *     drawn again.
 * @property row - the first row of the area, 1-based.
 * @property column - the first column of the area, 1-based.
 * @property rows - the area's height in cells (erased with it).
 * @property columns - the area's width in cells.
 * @property sequence - the sixel sequence (`ESC P q ... ESC \`).
 * @property offsetColumns - cells to leave before the image (centring).
 * @property offsetRows - cells to leave above the image.
 * @property blank - `#rrggbb` the area is blanked with (the theme's background), so the
 *     erased cells are painted, not left to the terminal's default colour; none blanks
 *     with plain spaces.
 */
export type Placement = {
    owner: string
    key: string
    row: number
    column: number
    rows: number
    columns: number
    sequence: string
    offsetColumns: number
    offsetRows: number
    blank?: string
}

/**
 * The text that draws a placement: save the cursor, go to the image's first cell, the
 * sequence, restore the cursor.
 */
export const paintSequence = (p: Placement): string =>
    `${ESC}7${ESC}[${p.row + p.offsetRows};${p.column + p.offsetColumns}H` +
    `${p.sequence}${ESC}8`

/**
 * The text that blanks the whole area of a placement (cursor saved and restored).
 */
export function eraseSequence(p: Placement): string {
    const blank = " ".repeat(p.columns)
    const rgb = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(p.blank ?? "")
    // the cells are painted with the colour (SGR 48;2), the default background put back
    // after; the cursor restore brings back the attributes Ink had
    const channels = rgb?.slice(1).map((h) => Number.parseInt(h, 16)).join(";")
    const paint = rgb === null ? "" : `${ESC}[48;2;${channels}m`
    const reset = rgb === null ? "" : `${ESC}[49m`
    let out = `${ESC}7${paint}`
    for (let r = 0; r < p.rows; r++) out += `${ESC}[${p.row + r};${p.column}H${blank}`
    return `${out}${reset}${ESC}8`
}

/** The write function of a stream, to wrap. */
type WriteFn = NodeJS.WriteStream["write"]

/**
 * Draws a placement on a stream and keeps it there against Ink's own writes.
 *
 * @param stream - the terminal (`process.stdout`).
 * @param delayMs - the repaint delay.
 */
export class SixelPainter {
    private current: Placement | undefined
    private timer: NodeJS.Timeout | undefined
    private writing = false
    private original: WriteFn | undefined
    /** Inside one of Ink's synchronized updates, and a frame was written in it. */
    private inUpdate = false
    private frameInUpdate = false

    /**
     * @param stream - the terminal.
     * @param delayMs - the delay of the fallback redraw.
     * @param sync - wrap the painter's own writes in synchronized-update markers
     *     (default: when the stream is a terminal).
     */
    constructor(
        private readonly stream: RefreshStream,
        private readonly delayMs: number = REPAINT_DELAY_MS,
        private readonly sync: boolean = stream.isTTY === true,
    ) {}

    /** The placement now drawn, if any (for tests). */
    get shown(): Placement | undefined {
        return this.current
    }

    /** Wraps the stream's `write` once, to notice Ink's writes. */
    private attach(): void {
        if (this.original !== undefined) return
        const original = this.stream.write
        this.original = original
        const self = this
        this.stream.write = function (this: unknown, ...args: unknown[]): boolean {
            if (!self.writing) args = self.beside(args)
            return (original as (...a: unknown[]) => boolean).apply(self.stream, args)
        } as WriteFn
    }

    /**
     * What goes to the terminal in place of one of Ink's writes: the picture drawn again
     * in the same write (before the end of a synchronized update, else after the frame).
     */
    private beside(args: unknown[]): unknown[] {
        const chunk = args[0]
        if (typeof chunk !== "string") {
            if (this.current !== undefined) this.schedule()
            return args
        }
        if (chunk === BSU) {
            this.inUpdate = true
            this.frameInUpdate = false
            return args
        }
        const now = this.current
        if (chunk === ESU) {
            const wrote = this.frameInUpdate
            this.inUpdate = false
            this.frameInUpdate = false
            if (!wrote || now === undefined) return args
            return [paintSequence(now) + chunk, ...args.slice(1)]
        }
        if (now === undefined || ONLY_ESCAPES.test(chunk)) return args
        if (this.inUpdate) {
            this.frameInUpdate = true
            return args
        }
        return [chunk + paintSequence(now), ...args.slice(1)]
    }

    /** Puts the stream's own `write` back. */
    detach(): void {
        this.cancel()
        if (this.original !== undefined) this.stream.write = this.original
        this.original = undefined
        this.current = undefined
    }

    private cancel(): void {
        if (this.timer !== undefined) clearTimeout(this.timer)
        this.timer = undefined
    }

    /** Writes text without it counting as one of Ink's writes. */
    private put(text: string): void {
        this.writing = true
        try {
            this.stream.write(this.sync ? `${BSU}${text}${ESU}` : text)
        } finally {
            this.writing = false
        }
    }

    private schedule(): void {
        this.cancel()
        this.timer = setTimeout(() => {
            this.timer = undefined
            if (this.current !== undefined) this.put(paintSequence(this.current))
        }, this.delayMs)
        this.timer.unref()
    }

    /**
     * Shows a picture. The same placement as the one shown is left alone (Ink's writes
     * redraw it); another one at the same place replaces it; one that moved blanks the old
     * area first.
     */
    show(p: Placement): void {
        this.attach()
        const now = this.current
        if (
            now !== undefined &&
            now.owner === p.owner &&
            now.key === p.key &&
            now.row === p.row &&
            now.column === p.column &&
            now.rows === p.rows &&
            now.columns === p.columns &&
            now.offsetRows === p.offsetRows &&
            now.offsetColumns === p.offsetColumns
        )
            return
        const moved =
            now !== undefined &&
            (now.row !== p.row ||
                now.column !== p.column ||
                now.rows !== p.rows ||
                now.columns !== p.columns ||
                now.offsetRows !== p.offsetRows ||
                now.offsetColumns !== p.offsetColumns)
        this.current = p
        this.cancel()
        this.put((moved && now !== undefined ? eraseSequence(now) : "") + paintSequence(p))
    }

    /**
     * Takes the picture away (blanks its area) when `owner` is the one that drew it.
     *
     * @param owner - the asker; any when left out.
     */
    hide(owner?: string): void {
        const now = this.current
        if (now === undefined || (owner !== undefined && now.owner !== owner)) return
        this.cancel()
        this.current = undefined
        this.put(eraseSequence(now))
    }
}

/** The painter of the program's terminal, made on first use. */
let shared: SixelPainter | undefined

/** @returns the painter of `process.stdout`. */
function terminalPainter(): SixelPainter {
    shared ??= new SixelPainter(process.stdout)
    return shared
}

/** @returns whether a sixel picture is shown now (the screen refresh keeps off then). */
export function sixelShown(): boolean {
    return shared?.shown !== undefined
}

/**
 * Blanks the picture now, before the state change that replaces it with text: erasing in
 * the unmount effect comes after Ink has written the new lines and would wipe them.
 */
export function hideSixelNow(): void {
    terminalPainter().hide()
}

/**
 * What the area shows.
 *
 * @property sequence - the sixel sequence.
 * @property key - changes with the picture (plot, zoom, pan, size).
 * @property width - the image's width in pixels.
 * @property height - the image's height in pixels.
 */
export type SixelFrame = { sequence: string; key: string; width: number; height: number }

/**
 * An area of the screen kept empty for a sixel picture, and the picture drawn on it after
 * each commit. Nothing is drawn while the screen is not the one on top or there is no
 * frame; the picture goes away when the component unmounts.
 *
 * @param props.columns - the area's width in cells.
 * @param props.rows - the area's height in cells.
 * @param props.cell - the cell size in pixels (to centre a picture smaller than the area).
 * @param props.frame - the picture; none leaves the area blank.
 * @returns the empty box.
 */
export function SixelArea(props: {
    columns: number
    rows: number
    cell: CellSize
    frame: SixelFrame | undefined
}): ReactNode {
    const { columns, rows, cell, frame } = props
    const ref = useRef<DOMElement>(null)
    const owner = useId()
    const onTop = useScreenActive()
    const theme = useTheme()
    // a screen that is no longer on top lets go of the picture while it renders, before
    // Ink writes the screen that covers it (an erase after that write would blank it)
    if (!onTop) terminalPainter().hide(owner)
    // after every commit Ink has laid the frame out, so the area's place is known. A
    // layout effect: it runs right after Ink's write of the commit, in the same tick, so
    // the new picture follows the new text with no gap
    useLayoutEffect(() => {
        const painter = terminalPainter()
        const node = ref.current
        if (!onTop || frame === undefined || node === null) {
            painter.hide(owner)
            return
        }
        const { x, y } = measureElement(node)
        painter.show({
            owner,
            key: frame.key,
            row: y + 1,
            column: x + 1,
            rows,
            columns,
            sequence: frame.sequence,
            offsetColumns: centreCells(columns * cell.width, frame.width, cell.width),
            offsetRows: centreCells(rows * cell.height, frame.height, cell.height),
            blank: theme.bg,
        })
    })
    // the cleanup of a layout effect runs while React removes the area, BEFORE Ink writes
    // the text that replaces it: the picture is blanked first and the text lands on top
    useLayoutEffect(() => () => terminalPainter().hide(owner), [owner])
    // while no picture is shown (loading, a size being rendered) the cells are painted
    // in the theme's background; with a picture the box stays unpainted, so Ink never
    // writes cells over the sixel
    return (
        <Box
            ref={ref}
            width={columns}
            height={rows}
            flexShrink={0}
            backgroundColor={frame === undefined ? theme.bg : undefined}
        />
    )
}
