// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The notations a figure colour may be written in, and the maths that turns each into the
 * 8-bit sRGB colour and back: `#rrggbb` (and `#rgb`), `rgb(r, g, b)`, `hsl(h, s%, l%)` and
 * `cmyk(c%, m%, y%, k%)`. This is `src/Pipeline/ColourNotation.jl` line for line, and both
 * read the golden file `test/fixtures/colours/notations.json`, so they cannot drift apart.
 *
 * A colour is three whole numbers 0 to 255; every value in between is a number. Rounding
 * is always `floor(x + 0.5)` (half up).
 */

/** A colour as its three 8-bit channels. */
export type Rgb = readonly [number, number, number]

const roundHalfUp = (x: number): number => Math.floor(x + 0.5)

/** A number of 0 to 255 for a channel of 0 to 1, rounded and kept in range. */
const channel8 = (x: number): number => Math.min(255, Math.max(0, roundHalfUp(255 * x)))

/** A fixed-point number as text, trailing zeros and the point dropped (`-0` is `0`). */
function fixed2(x: number): string {
    // rounded half up first, as `_fixed2` of Julia
    // does (`toFixed` and `@sprintf` differ on ties)
    let text = (Math.floor(x * 100 + 0.5) / 100).toFixed(2)
    if (text.includes(".")) text = text.replace(/0+$/, "").replace(/\.$/, "")
    return text === "-0" ? "0" : text
}

// ---- HSL ---------------------------------------------------------------------------

function rgbToHsl(r8: number, g8: number, b8: number): [number, number, number] {
    const [r, g, b] = [r8 / 255, g8 / 255, b8 / 255]
    const hi = Math.max(r, g, b)
    const lo = Math.min(r, g, b)
    const l = (hi + lo) / 2
    const d = hi - lo
    if (d === 0) return [0, 0, 100 * l]
    const s = d / (1 - Math.abs(2 * l - 1))
    let h: number
    if (hi === r) h = ((g - b) / d) % 6
    else if (hi === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h = 60 * h
    if (h < 0) h += 360
    return [h, 100 * s, 100 * l]
}

function hslToRgb(h: number, s: number, l: number): Rgb {
    const sat = s / 100
    const light = l / 100
    const a = sat * Math.min(light, 1 - light)
    const f = (n: number): number => {
        const k = (n + h / 30) % 12
        return light - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))
    }
    return [channel8(f(0)), channel8(f(8)), channel8(f(4))]
}

// ---- CMYK (the plain formula, no colour profile) -----------------------------------

function rgbToCmyk(r8: number, g8: number, b8: number): [number, number, number, number] {
    const [r, g, b] = [r8 / 255, g8 / 255, b8 / 255]
    const k = 1 - Math.max(r, g, b)
    if (k === 1) return [0, 0, 0, 100]
    return [
        (100 * (1 - r - k)) / (1 - k),
        (100 * (1 - g - k)) / (1 - k),
        (100 * (1 - b - k)) / (1 - k),
        100 * k,
    ]
}

function cmykToRgb(c: number, m: number, y: number, k: number): Rgb {
    const key = 1 - k / 100
    return [
        channel8((1 - c / 100) * key),
        channel8((1 - m / 100) * key),
        channel8((1 - y / 100) * key),
    ]
}

// ---- writing -----------------------------------------------------------------------

/** One colour in every notation (the same digits as `colour_notations` of Julia). */
export type Notations = { hex: string; rgb: string; hsl: string; cmyk: string }

/** The `#rrggbb` text of a colour. */
export const toHex = (rgb: Rgb): string =>
    `#${rgb.map((c) => c.toString(16).padStart(2, "0")).join("")}`

/**
 * The colour written in every notation, each with enough digits (up to 2 decimals for HSL
 * and CMYK) to be read back as the same 8-bit colour.
 */
export function colourNotations(rgb: Rgb): Notations {
    const [r, g, b] = rgb
    const [h, s, l] = rgbToHsl(r, g, b)
    const [c, m, y, k] = rgbToCmyk(r, g, b)
    return {
        hex: toHex(rgb),
        rgb: `rgb(${r}, ${g}, ${b})`,
        hsl: `hsl(${fixed2(h)}, ${fixed2(s)}%, ${fixed2(l)}%)`,
        cmyk: `cmyk(${fixed2(c)}%, ${fixed2(m)}%, ${fixed2(y)}%, ${fixed2(k)}%)`,
    }
}

// ---- reading -----------------------------------------------------------------------

const number = "[+-]?(?:\\d+\\.?\\d*|\\.\\d+)"

/** The numbers of a code `name(...)`, each with its suffix (`%` or none), or none. */
function codeNumbers(text: string, name: string, suffixes: string[]): number[] | undefined {
    const m = new RegExp(`^${name}\\(\\s*(.*?)\\s*\\)$`, "i").exec(text)
    if (m === null) return undefined
    const words = (m[1] as string).split(/\s*,\s*|\s+/).filter((w) => w !== "")
    if (words.length !== suffixes.length) return undefined
    const numbers: number[] = []
    for (const [i, word] of words.entries()) {
        const n = new RegExp(`^(${number})${suffixes[i]}$`).exec(word)
        if (n === null) return undefined
        numbers.push(Number(n[1]))
    }
    return numbers
}

/**
 * The 8-bit colour a code writes: `#rgb`, `#rrggbb`, `rgb(r, g, b)` (whole numbers 0 to
 * 255), `hsl(h, s%, l%)` (hue in degrees, 0 to 100 for the rest) or `cmyk(c%, m%, y%, k%)`
 * (0 to 100). The numbers are read as written and rounded only once, to 8 bits.
 *
 * @returns the colour, or `undefined` if the text is no valid code.
 */
export function parseColourCode(text: string): Rgb | undefined {
    const t = text.trim()
    const hex = /^#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$/.exec(t)
    if (hex !== null) {
        let d = hex[1] as string
        if (d.length === 3) d = [...d].map((c) => c + c).join("")
        const part = (i: number): number => Number.parseInt(d.slice(i, i + 2), 16)
        return [part(0), part(2), part(4)]
    }
    const rgb = codeNumbers(t, "rgb", ["", "", ""])
    if (rgb !== undefined) {
        if (!rgb.every((x) => Number.isInteger(x) && x >= 0 && x <= 255)) return undefined
        return rgb as unknown as Rgb
    }
    const hsl = codeNumbers(t, "hsl", ["", "%", "%"])
    if (hsl !== undefined) {
        const [h, s, l] = hsl as [number, number, number]
        const inRange = h >= 0 && h <= 360 && s >= 0 && s <= 100 && l >= 0 && l <= 100
        if (!inRange) return undefined
        return hslToRgb(h, s, l)
    }
    const cmyk = codeNumbers(t, "cmyk", ["%", "%", "%", "%"])
    if (cmyk !== undefined) {
        if (!cmyk.every((x) => x >= 0 && x <= 100)) return undefined
        const [c, m, y, k] = cmyk as [number, number, number, number]
        return cmykToRgb(c, m, y, k)
    }
    return undefined
}

/** The channels of a `#rrggbb` text. */
export const fromHex = (hex: string): Rgb =>
    [1, 3, 5].map((i) => Number.parseInt(hex.slice(i, i + 2), 16)) as unknown as Rgb
