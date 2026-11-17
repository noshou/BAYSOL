// SPDX-License-Identifier: LGPL-3.0-or-later

// Sixel: the types the four sixel modules share, so a screen needs one import to talk to
// them. The modules (all in `store/`, no React, no UI):
//
//   sixel-detect.ts  does the terminal draw sixel, and how big is a cell (`detectSixel`)
//   sixel-raster.ts  a PDF, SVG or PNG file as an RGBA image fitted to a box (`rasterise`)
//   sixel-encode.ts  an RGBA image as a DEC sixel escape sequence (`encodeSixel`)
//   sixel-cache.ts   `<plot>.SIXEL_ESCAPE_SEQ` files in a run (`readSixelCache`, ...)
//
// Typical use: `detectSixel()` once at start-up (before Ink takes the keyboard, or while
// it is idle); when supported, for a plot: `readSixelCache` for the wanted box, else
// `rasterise` + `encodeSixel` + `writeSixelCache`, then write the sequence to stdout with
// the cursor on the first cell of the area. Unicode plots are always the fallback.

/**
 * A raster image.
 *
 * @property width - pixels per row.
 * @property height - pixel rows.
 * @property data - `width * height * 4` bytes, RGBA, non-premultiplied, row by row.
 */
export type RgbaImage = { width: number; height: number; data: Uint8Array }

/**
 * The size of one character cell of the terminal, in pixels.
 *
 * @property width - pixels across a cell.
 * @property height - pixels down a cell.
 */
export type CellSize = { width: number; height: number }

/**
 * What the terminal can do.
 *
 * @property supported - true only when the terminal said it draws sixel AND its cell size
 *     is known (so a box of cells can be turned into pixels); false for everything else:
 *     no reply, a timeout, no tty, no sixel attribute, unknown cell size.
 * @property cell - the cell size when it is known (also when `supported` is false).
 * @property reason - one phrase for why it is unsupported, empty when supported.
 */
export type SixelSupport = {
    supported: boolean
    cell?: CellSize
    reason: string
}

/**
 * The pixel box a figure is fitted into, and the cells it was worked out from. The cache
 * keeps both: the same box in cells can be another box in pixels after a font change.
 *
 * @property widthPx - box width in pixels.
 * @property heightPx - box height in pixels.
 * @property cell - the cell size the box was computed with.
 */
export type SixelBox = { widthPx: number; heightPx: number; cell: CellSize }
