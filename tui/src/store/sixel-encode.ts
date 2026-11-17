// SPDX-License-Identifier: LGPL-3.0-or-later

// The sixel encoder: an RGBA image as a DEC sixel escape sequence (`ESC P q ... ESC \`).
// Written here (a few dozen lines, pure, tested on a tiny image) rather than taken from an
// npm package.
//
// Format used: a raster-attributes header (`"1;1;W;H`), the palette (`#n;2;r;g;b`, rgb in
// percent), then bands of six pixel rows. Per band, per palette colour present in it: `#n`,
// one character per column (`63 + 6 bits`, bit 0 the top row), run-length encoded (`!n c`
// for runs over 3), trailing empty columns left out, `$` (back to the band's start) between
// colours and `-` (next band) between bands.
//
// Colours: an image with at most `maxColors` distinct colours keeps them exactly (palette
// in order of first appearance); otherwise a median cut of the image's own colours (by
// pixel count) makes the palette. Transparent pixels are composed onto `background`.
// Dithering (Floyd-Steinberg) is off by default.
//
// Contents:
//   1. The palette
//   2. The encoder

import type { RgbaImage } from "./sixel-types.js"

/** The most colours a sixel palette is made of here (what terminals reliably hold). */
const SIXEL_MAX_COLORS = 256

/**
 * Options of [[encodeSixel]].
 *
 * @property maxColors - palette size, 2 to 256 (default 256).
 * @property dither - Floyd-Steinberg error diffusion (default false).
 * @property background - RGB that transparent pixels are composed onto (default white).
 */
export type SixelOptions = {
    maxColors?: number
    dither?: boolean
    background?: readonly [number, number, number]
}

const ESC = "\u001b"

// ========================================================================================
// 1. The palette
// ========================================================================================

/** A distinct colour of the image with how many pixels have it: `[rgb24, count]`. */
type Counted = [number, number]

const red = (c: number): number => (c >> 16) & 255
const green = (c: number): number => (c >> 8) & 255
const blue = (c: number): number => c & 255

/** Pixels of the image as opaque RGB24 numbers (alpha composed onto `bg`). */
function flatten(image: RgbaImage, bg: readonly [number, number, number]): Int32Array {
    const { width, height, data } = image
    const out = new Int32Array(width * height)
    const b0 = bg[0]
    const b1 = bg[1]
    const b2 = bg[2]
    // integer arithmetic, no closures: this runs once per pixel
    for (let i = 0, j = 0; i < out.length; i++, j += 4) {
        const a = data[j + 3] as number
        if (a === 255) {
            const r = data[j] as number
            const g = data[j + 1] as number
            out[i] = (r << 16) | (g << 8) | (data[j + 2] as number)
        } else {
            const ia = 255 - a
            const r = Math.round(((data[j] as number) * a + b0 * ia) / 255)
            const g = Math.round(((data[j + 1] as number) * a + b1 * ia) / 255)
            const b = Math.round(((data[j + 2] as number) * a + b2 * ia) / 255)
            out[i] = (r << 16) | (g << 8) | b
        }
    }
    return out
}

/** Median cut: splits boxes of colours at the weighted median of their widest channel. */
function medianCut(colors: Counted[], size: number): number[] {
    const channel = [red, green, blue]
    const boxes: Counted[][] = [colors]
    while (boxes.length < size) {
        // the box with the most pixels that can still be split
        let pick = -1
        let best = 0
        boxes.forEach((box, i) => {
            const weight = box.reduce((s, c) => s + c[1], 0)
            if (box.length > 1 && weight > best) {
                best = weight
                pick = i
            }
        })
        const box = boxes[pick]
        if (box === undefined) break
        // the channel with the widest range
        let widest = 0
        let range = -1
        channel.forEach((f, k) => {
            let lo = 255
            let hi = 0
            for (const [c] of box) {
                lo = Math.min(lo, f(c))
                hi = Math.max(hi, f(c))
            }
            if (hi - lo > range) {
                range = hi - lo
                widest = k
            }
        })
        const f = channel[widest] ?? red
        box.sort((p, q) => f(p[0]) - f(q[0]) || p[0] - q[0])
        const half = box.reduce((s, c) => s + c[1], 0) / 2
        let acc = 0
        let cut = 1
        for (let i = 0; i < box.length - 1; i++) {
            acc += box[i]?.[1] ?? 0
            cut = i + 1
            if (acc >= half) break
        }
        boxes.splice(pick, 1, box.slice(0, cut), box.slice(cut))
    }
    // each box is represented by its pixel-weighted mean colour
    return boxes.map((box) => {
        let n = 0
        let r = 0
        let g = 0
        let b = 0
        for (const [c, w] of box) {
            n += w
            r += red(c) * w
            g += green(c) * w
            b += blue(c) * w
        }
        return (Math.round(r / n) << 16) | (Math.round(g / n) << 8) | Math.round(b / n)
    })
}

/**
 * The distinct colours of an image, in order of first appearance, with their pixel counts
 * and, per pixel, the number of its colour.
 */
function countColours(pixels: Int32Array): {
    colours: number[]
    counts: number[]
    ids: Int32Array
} {
    let cap = 1 << 16
    for (;;) {
        const keys = new Int32Array(cap).fill(-1)
        const slotId = new Int32Array(cap)
        const ids = new Int32Array(pixels.length)
        const colours: number[] = []
        const counts: number[] = []
        const mask = cap - 1
        let full = false
        for (let i = 0; i < pixels.length; i++) {
            const c = pixels[i] ?? 0
            let h = (Math.imul(c, 0x9e3779b1) >>> 8) & mask
            while (keys[h] !== -1 && keys[h] !== c) h = (h + 1) & mask
            let id: number
            if (keys[h] === -1) {
                if (colours.length * 2 >= cap) {
                    full = true
                    break
                }
                keys[h] = c
                id = colours.length
                slotId[h] = id
                colours.push(c)
                counts.push(0)
            } else id = slotId[h] ?? 0
            ids[i] = id
            counts[id] = (counts[id] ?? 0) + 1
        }
        if (!full) return { colours, counts, ids }
        cap *= 2
    }
}

/** Index of the palette entry nearest (squared RGB distance) to the colour. */
function nearest(palette: readonly number[], c: number): number {
    const r = red(c)
    const g = green(c)
    const b = blue(c)
    let best = 0
    let bestD = Number.POSITIVE_INFINITY
    for (let i = 0; i < palette.length; i++) {
        const p = palette[i] ?? 0
        const d = (red(p) - r) ** 2 + (green(p) - g) ** 2 + (blue(p) - b) ** 2
        if (d < bestD) {
            bestD = d
            best = i
        }
    }
    return best
}

// ========================================================================================
// 2. The encoder
// ========================================================================================

/** Run-length encodes the characters of one colour row of a band, trailing `?` cut. */
function runLength(codes: Uint8Array, length: number): string {
    let end = length
    while (end > 0 && codes[end - 1] === 0) end--
    let out = ""
    for (let i = 0; i < end; ) {
        const code = codes[i] ?? 0
        let n = 1
        while (i + n < end && codes[i + n] === code) n++
        const ch = String.fromCharCode(63 + code)
        out += n > 3 ? `!${n}${ch}` : ch.repeat(n)
        i += n
    }
    return out
}

/**
 * Encodes an image as a DEC sixel sequence, ready to write to a sixel terminal.
 *
 * @param image - the pixels (see [[RgbaImage]]).
 * @param options - see [[SixelOptions]].
 * @returns the whole sequence, `ESC P q ... ESC \`.
 * @throws Error for an image with a side of 0, data of the wrong length, or `maxColors`
 *     outside 2 to 256.
 */
export function encodeSixel(image: RgbaImage, options: SixelOptions = {}): string {
    const { width, height } = image
    const maxColors = options.maxColors ?? SIXEL_MAX_COLORS
    if (!(width > 0 && height > 0) || image.data.length !== width * height * 4)
        throw new Error(`not an image: ${width}x${height}, ${image.data.length} bytes`)
    if (!Number.isInteger(maxColors) || maxColors < 2 || maxColors > SIXEL_MAX_COLORS)
        throw new Error(`maxColors must be 2 to ${SIXEL_MAX_COLORS}, not ${maxColors}`)
    const pixels = flatten(image, options.background ?? [255, 255, 255])

    // the palette: the exact colours when there are few, else a median cut. The distinct
    // colours are counted in an open-addressing table (a Map of a million pixels is slow)
    const table = countColours(pixels)
    const counted: Counted[] = table.colours.map((c, i) => [c, table.counts[i] ?? 0])
    const exact = counted.length <= maxColors
    const palette = exact ? table.colours : medianCut(counted, maxColors)

    // palette index of every pixel (with error diffusion when asked)
    const index = new Uint16Array(width * height)
    if (options.dither === true) {
        let row = new Float32Array((width + 2) * 3)
        let next = new Float32Array((width + 2) * 3)
        for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
                const c = pixels[y * width + x] ?? 0
                const want = [red(c), green(c), blue(c)].map((v, k) =>
                    Math.min(255, Math.max(0, Math.round(v + (row[(x + 1) * 3 + k] ?? 0)))),
                )
                const got = nearest(
                    palette,
                    ((want[0] ?? 0) << 16) | ((want[1] ?? 0) << 8) | (want[2] ?? 0),
                )
                index[y * width + x] = got
                const p = palette[got] ?? 0
                const have = [red(p), green(p), blue(p)]
                // Floyd-Steinberg: 7/16 right, 3/16 below-left, 5/16 below, 1/16 other
                for (let k = 0; k < 3; k++) {
                    const err = (want[k] ?? 0) - (have[k] ?? 0)
                    row[(x + 2) * 3 + k] = (row[(x + 2) * 3 + k] ?? 0) + (err * 7) / 16
                    next[x * 3 + k] = (next[x * 3 + k] ?? 0) + (err * 3) / 16
                    next[(x + 1) * 3 + k] = (next[(x + 1) * 3 + k] ?? 0) + (err * 5) / 16
                    next[(x + 2) * 3 + k] = (next[(x + 2) * 3 + k] ?? 0) + err / 16
                }
            }
            row = next
            next = new Float32Array((width + 2) * 3)
        }
    } else {
        // the palette index of each DISTINCT colour, then one lookup per pixel
        const byColour = new Int16Array(table.colours.length)
        for (let k = 0; k < byColour.length; k++)
            byColour[k] = exact ? k : nearest(palette, table.colours[k] ?? 0)
        for (let i = 0; i < pixels.length; i++) index[i] = byColour[table.ids[i] ?? 0] ?? 0
    }

    // header and palette (rgb in percent)
    let out = `${ESC}Pq"1;1;${width};${height}`
    const pct = (v: number): number => Math.round((v * 100) / 255)
    palette.forEach((c, i) => {
        out += `#${i};2;${pct(red(c))};${pct(green(c))};${pct(blue(c))}`
    })

    // bands of six rows; one flat buffer of 6-bit column codes per palette colour, only the
    // colours that occur in a band are cleared and written
    const colours = palette.length
    const codesOf = new Uint8Array(colours * width)
    const present = new Uint8Array(colours)
    const parts: string[] = [out]
    for (let top = 0; top < height; top += 6) {
        const rows = Math.min(6, height - top)
        for (let r = 0; r < rows; r++) {
            const base = (top + r) * width
            for (let x = 0; x < width; x++) {
                const k = index[base + x] ?? 0
                present[k] = 1
                codesOf[k * width + x] = (codesOf[k * width + x] ?? 0) | (1 << r)
            }
        }
        let first = true
        let band = ""
        for (let k = 0; k < colours; k++) {
            if (present[k] === 0) continue
            const codes = codesOf.subarray(k * width, (k + 1) * width)
            band += `${first ? "" : "$"}#${k}${runLength(codes, width)}`
            codes.fill(0)
            present[k] = 0
            first = false
        }
        parts.push(top + 6 < height ? `${band}-` : band)
    }
    out = parts.join("")
    return `${out}${ESC}\\`
}
