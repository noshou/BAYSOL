// SPDX-License-Identifier: LGPL-3.0-or-later

// Resampling an RGBA image to another size: a separable Lanczos-3 filter (the kernel
// `sharp` used for the zoom of a figure), written here because a native image library
// cannot travel inside the single executable. The filter is widened by the scale factor
// when shrinking, so no detail aliases, and the colours are averaged premultiplied by
// alpha, so a transparent pixel does not bleed its colour into its neighbours.

import type { RgbaImage } from "./sixel-types.js"

/** The radius of the Lanczos kernel, in source pixels at scale 1. */
const LOBES = 3

/** The Lanczos kernel of radius [[LOBES]]: `sinc(x) sinc(x / 3)` inside, 0 outside. */
function lanczos(x: number): number {
    if (x === 0) return 1
    if (Math.abs(x) >= LOBES) return 0
    const px = Math.PI * x
    return (LOBES * Math.sin(px) * Math.sin(px / LOBES)) / (px * px)
}

/** One output position: the first source index and the normalised weights from there. */
type Taps = { first: number; weights: Float64Array }

/** The taps of every output position along one axis (`from` source pixels to `to`). */
function axisTaps(from: number, to: number): Taps[] {
    const scale = from / to
    const stretch = Math.max(scale, 1)
    const radius = LOBES * stretch
    const taps: Taps[] = []
    for (let i = 0; i < to; i++) {
        const centre = (i + 0.5) * scale
        const first = Math.max(0, Math.floor(centre - radius))
        const last = Math.min(from - 1, Math.ceil(centre + radius))
        const weights = new Float64Array(last - first + 1)
        let sum = 0
        for (let j = first; j <= last; j++) {
            const w = lanczos((j + 0.5 - centre) / stretch)
            weights[j - first] = w
            sum += w
        }
        for (let k = 0; k < weights.length; k++) weights[k] = (weights[k] ?? 0) / sum
        taps.push({ first, weights })
    }
    return taps
}

/** Premultiplied float channels (RGBA) of an image. */
function premultiplied(image: RgbaImage): Float32Array {
    const out = new Float32Array(image.data.length)
    for (let i = 0; i < image.data.length; i += 4) {
        const a = (image.data[i + 3] ?? 0) / 255
        out[i] = (image.data[i] ?? 0) * a
        out[i + 1] = (image.data[i + 1] ?? 0) * a
        out[i + 2] = (image.data[i + 2] ?? 0) * a
        out[i + 3] = a * 255
    }
    return out
}

/**
 * Resamples an image to `width` x `height` pixels (the aspect is not kept: the caller
 * chooses the size).
 *
 * @param image - the source, RGBA non-premultiplied.
 * @param width - the new width in pixels, at least 1.
 * @param height - the new height in pixels, at least 1.
 * @returns the image itself when it already has that size, else the resampled copy.
 */
export function resizeRgba(image: RgbaImage, width: number, height: number): RgbaImage {
    if (width === image.width && height === image.height) return image
    const src = premultiplied(image)
    const across = axisTaps(image.width, width)
    const down = axisTaps(image.height, height)
    // horizontal pass: image.height rows of `width` pixels
    const mid = new Float32Array(width * image.height * 4)
    for (let y = 0; y < image.height; y++) {
        for (let x = 0; x < width; x++) {
            const { first, weights } = across[x] as Taps
            let r = 0
            let g = 0
            let b = 0
            let a = 0
            for (let k = 0; k < weights.length; k++) {
                const w = weights[k] as number
                const at = (y * image.width + first + k) * 4
                r += w * (src[at] as number)
                g += w * (src[at + 1] as number)
                b += w * (src[at + 2] as number)
                a += w * (src[at + 3] as number)
            }
            const to = (y * width + x) * 4
            mid[to] = r
            mid[to + 1] = g
            mid[to + 2] = b
            mid[to + 3] = a
        }
    }
    // vertical pass, then back to non-premultiplied bytes
    const data = new Uint8Array(width * height * 4)
    for (let y = 0; y < height; y++) {
        const { first, weights } = down[y] as Taps
        for (let x = 0; x < width; x++) {
            let r = 0
            let g = 0
            let b = 0
            let a = 0
            for (let k = 0; k < weights.length; k++) {
                const w = weights[k] as number
                const at = ((first + k) * width + x) * 4
                r += w * (mid[at] as number)
                g += w * (mid[at + 1] as number)
                b += w * (mid[at + 2] as number)
                a += w * (mid[at + 3] as number)
            }
            const alpha = Math.min(255, Math.max(0, a))
            const to = (y * width + x) * 4
            const unscale = alpha > 0 ? 255 / alpha : 0
            data[to] = Math.round(Math.min(255, Math.max(0, r * unscale)))
            data[to + 1] = Math.round(Math.min(255, Math.max(0, g * unscale)))
            data[to + 2] = Math.round(Math.min(255, Math.max(0, b * unscale)))
            data[to + 3] = Math.round(alpha)
        }
    }
    return { width, height, data }
}

/**
 * Draws an image onto an opaque white background (what is transparent becomes white).
 *
 * @returns a new image, every alpha 255.
 */
export function flattenOnWhite(image: RgbaImage): RgbaImage {
    const data = new Uint8Array(image.data.length)
    for (let i = 0; i < data.length; i += 4) {
        const a = (image.data[i + 3] ?? 0) / 255
        for (let c = 0; c < 3; c++)
            data[i + c] = Math.round((image.data[i + c] ?? 0) * a + 255 * (1 - a))
        data[i + 3] = 255
    }
    return { width: image.width, height: image.height, data }
}
