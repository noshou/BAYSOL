// SPDX-License-Identifier: LGPL-3.0-or-later

// The pure parts of the graphics view of the plots (sixel): which rendered file belongs to
// a plot tab, whether a run's figures are rendered ("render" is offered once), whether the
// graphics view is possible and the default, the cache-or-render decision, and the pixel
// arithmetic of the box, zoom, pan and centring. No React, no terminal; the one file read
// is [[listRendered]]. The pieces that do I/O are in `screens/viewer-graphics.ts`.
//
// Contents:
//   1. The rendered files of a run and the render gate
//   2. Which figure is a plot tab
//   3. The view state and the cache decision
//   4. Pixels: box, zoom, pan, crop

import { readdirSync } from "node:fs"
import { basename, extname } from "node:path"
import { destinationName, type PlotUnit, runFolder } from "./plots.js"
import { cacheMatches, type SixelCacheEntry } from "./sixel-cache.js"
import { RASTER_FORMATS } from "./sixel-raster.js"
import type { RgbaImage, SixelBox } from "./sixel-types.js"

// ========================================================================================
// 1. The rendered files and the render gate
// ========================================================================================

/** The name of a file without its folder and its last extension. */
const stemOf = (name: string): string => {
    const base = basename(name)
    return base.slice(0, base.length - extname(base).length)
}

/** The rendered figure formats in order of preference (the PDF is what LaTeX makes). */
const RENDERED_ORDER = RASTER_FORMATS

/**
 * The names of the rendered figures (`.pdf`, `.svg`, `.png`) in a folder.
 *
 * @param dir - the folder (the plot folder of a run).
 * @returns the file names; none when the folder is not there.
 */
export function listRendered(dir: string): string[] {
    try {
        return readdirSync(dir).filter((f) =>
            (RASTER_FORMATS as readonly string[]).includes(extname(f).toLowerCase()),
        )
    } catch {
        return []
    }
}

/**
 * The rendered file of a plot, by name. A file put in the folder beside an older one has
 * `-2`, `-3`, ... before its extension (`freeNames` of `plots.ts`): the exact name wins,
 * else the lowest number.
 *
 * @param listing - the names of the rendered files ([[listRendered]]).
 * @param stem - the plot's name in the folder (no extension).
 * @returns the file name, `undefined` when the plot is not rendered.
 */
export function renderedFile(listing: readonly string[], stem: string): string | undefined {
    for (const ext of RENDERED_ORDER) {
        const exact = listing.find((f) => f === `${stem}${ext}`)
        if (exact !== undefined) return exact
    }
    const numbered = listing
        .map((f) => ({ f, m: /^(.*)-(\d+)$/.exec(stemOf(f)) }))
        .filter((e) => e.m !== null && e.m[1] === stem)
        .sort((a, b) => Number(a.m?.[2]) - Number(b.m?.[2]))
    return numbered[0]?.f
}

/**
 * The plots of a unit: the run-side name of each `.tex` figure (what the sixel cache is
 * named for) and the name it has in the plot folder (what is rendered there).
 */
export type FigurePair = { stem: string; dest: string }

/** The [[FigurePair]]s of a unit's `.tex` figures. */
export const figurePairs = (unit: PlotUnit): FigurePair[] =>
    unit.tex.map((rel) => ({
        stem: stemOf(rel),
        dest: stemOf(destinationName(unit, rel)),
    }))

/**
 * The `.tex` figures of a unit that have no rendered file in its plot folder. This is the
 * render gate: "render plots" is offered while this list is not empty, and then renders
 * just these, so a figure is never rendered twice.
 *
 * @param unit - the model or comparison.
 * @param listing - the names of the rendered files in its plot folder.
 * @returns the `.tex` paths (as in `unit.tex`) without a rendered file.
 */
export function unrenderedTex(unit: PlotUnit, listing: readonly string[]): string[] {
    return unit.tex.filter(
        (rel) => renderedFile(listing, stemOf(destinationName(unit, rel))) === undefined,
    )
}

/**
 * Is the "render plots" action to be offered? True only while a unit has figures and not
 * every one of them is rendered ([[unrenderedTex]]); once rendered, never again.
 *
 * @param unit - the model or comparison.
 * @param root - the plot folder (`plotRoot`).
 */
export const mayRender = (unit: PlotUnit, root: string): boolean =>
    unit.tex.length > 0 &&
    unrenderedTex(unit, listRendered(runFolder(root, unit))).length > 0

// ========================================================================================
// 2. Which figure is a plot tab
// ========================================================================================

/**
 * The file-name part of each posterior histogram, by the label the Unicode plot is titled
 * with (a mirror of `PLOT_HIST_PARAMS` in `src/pipeline/pipeline.jl`: label and file).
 */
const HISTOGRAM_FILES: Readonly<Record<string, string>> = {
    "ρₑ": "rhoE",
    "δρ₁": "deltaRho1",
    "δρ₂": "deltaRho2",
    "δρ₃": "deltaRho3",
    scale: "scale",
    bkgrndCorr: "bkgrndCorr",
    "bkgrnd corr": "bkgrndCorr",
    c1: "c1",
}

/** The endings that mark a figure other than the fit. */
const OTHER_FIGURE = /^compare$|_(residuals|hist_.+|compar(e|ison).*)$/

/**
 * The figure that a plot tab of the plots text stands for. The tabs are titled by what the
 * Unicode plot says (`fit`, `residuals (3 off the plot)`, the label of a histogram, ...),
 * the figures by their file names (`<name>`, `<name>_residuals`, `<name>_hist_c1`).
 *
 * @param title - the tab's title.
 * @param stems - the run-side names of the unit's figures (no extension).
 * @param plotCount - how many plot tabs the unit has: a unit with one figure and one tab
 *     is that figure whatever the title says.
 * @returns the figure's stem; `undefined` for a tab with no figure (it stays Unicode).
 */
export function plotStem(
    title: string,
    stems: readonly string[],
    plotCount: number,
): string | undefined {
    const t = title.trim()
    const one = (list: readonly string[]): string | undefined =>
        list.length === 1 ? list[0] : undefined
    if (/^fit\b/i.test(t)) return one(stems.filter((s) => !OTHER_FIGURE.test(s)))
    if (/^residuals\b/i.test(t)) return one(stems.filter((s) => s.endsWith("_residuals")))
    const file = HISTOGRAM_FILES[t]
    if (file !== undefined) return one(stems.filter((s) => s.endsWith(`_hist_${file}`)))
    if (/^compar/i.test(t))
        return one(stems.filter((s) => /^compare$|_compar(e|ison)/.test(s)))
    return stems.length === 1 && plotCount === 1 ? stems[0] : undefined
}

// ========================================================================================
// 3. The view state and the cache decision
// ========================================================================================

/**
 * What decides whether the graphics view exists for a plot.
 *
 * @property supported - the terminal draws sixel and its cell size is known.
 * @property hasSource - the figure is rendered (a `.pdf`, `.svg` or `.png` file).
 * @property cached - a sixel cache of the figure is in the run.
 */
export type GraphicsFacts = { supported: boolean; hasSource: boolean; cached: boolean }

/** Can the graphics view be shown (and the toggle offered)? */
export const canGraphics = (f: GraphicsFacts): boolean =>
    f.supported && (f.hasSource || f.cached)

/** The ONE note for a terminal that cannot draw sixel, wherever graphics are offered. */
export const GRAPHICS_UNSUPPORTED = "terminal can only display unicode graphics"

/** The ONE note for a plot with no rendered figure, wherever graphics are offered. */
export const PLOT_NOT_RENDERED = "plot not rendered"

/**
 * What the plot-type key says when the graphics view cannot be shown: the key must never
 * be silent. Two short notes cover every reason, the same ones every place that offers
 * graphics shows: [[GRAPHICS_UNSUPPORTED]] and [[PLOT_NOT_RENDERED]].
 *
 * @param facts.supported - the terminal draws sixel with a known cell size.
 * @param facts.hasFigures - the run has a figure folder and figure names for this model.
 * @param facts.hasStem - this plot tab matches one of the figures.
 * @param facts.hasSource - the figure is rendered.
 * @param facts.cached - a sixel cache of the figure is in the run.
 * @returns the text and whether it is an error; `undefined` when the view can switch.
 */
export function graphicsRefusal(facts: {
    supported: boolean
    hasFigures: boolean
    hasStem: boolean
    hasSource: boolean
    cached: boolean
}): { text: string; error: boolean } | undefined {
    if (!facts.supported) return { text: GRAPHICS_UNSUPPORTED, error: true }
    if (!facts.hasFigures || !facts.hasStem || (!facts.hasSource && !facts.cached))
        return { text: PLOT_NOT_RENDERED, error: true }
    return undefined
}

/**
 * Which view a plot opens in: graphics when the run already has the cache of the figure
 * (a graphic was made before), else Unicode until the user asks for graphics. A choice
 * made with the key wins.
 *
 * @param facts - the plot's facts.
 * @param pick - the user's last choice, `undefined` before any.
 * @returns `"graphics"` only when it is possible ([[canGraphics]]).
 */
export function chosenView(
    facts: GraphicsFacts,
    pick: "graphics" | "unicode" | undefined,
): "graphics" | "unicode" {
    if (!canGraphics(facts)) return "unicode"
    return (pick ?? (facts.cached ? "graphics" : "unicode")) as "graphics" | "unicode"
}

/**
 * Where the pixels of the fit view come from.
 *
 * - `cache`: the cache file serves the box.
 * - `render-write`: rasterise and encode, then write the cache (the fit view only).
 * - `render`: rasterise and encode, nothing is cached (a zoomed view, or a run that must
 *   not be written to).
 * - `none`: nothing to show (no matching cache and no source).
 *
 * @param entry - the cache read for the plot, `undefined` for none.
 * @param wanted - the box now wanted.
 * @param zoom - the zoom factor (1 is the fit view; the cache holds only that).
 * @param hasSource - the figure is rendered.
 * @param writable - the run may be written to.
 */
export function provision(
    entry: SixelCacheEntry | undefined,
    wanted: SixelBox,
    zoom: number,
    hasSource: boolean,
    writable = true,
): "cache" | "render-write" | "render" | "none" {
    if (zoom === 1 && entry !== undefined && cacheMatches(entry.header, wanted))
        return "cache"
    if (!hasSource) return "none"
    return zoom === 1 && writable ? "render-write" : "render"
}

// ========================================================================================
// 4. Pixels
// ========================================================================================

/** The sixel bands are six pixel rows high: a box is cut to a multiple of that. */
const SIXEL_BAND = 6

/** The zoom factors of the graphics view, in steps like the Unicode sizes. */
const GRAPHIC_ZOOMS: readonly number[] = [1, 1.5, 2, 3, 4]

/** The longest side a zoomed raster may have (memory: 8192 x 8192 x 4 bytes is 256 MB). */
const ZOOM_MAX_SIDE = 4096

/**
 * The pixel box of an area of cells.
 *
 * @param columns - cells across.
 * @param rows - cells down.
 * @param cell - the cell size in pixels.
 * @returns the box; its height is cut down to whole sixel bands so the last band cannot
 *     spill into the row under the area.
 */
export function pixelBox(
    columns: number,
    rows: number,
    cell: { width: number; height: number },
): SixelBox {
    const h = rows * cell.height
    return {
        widthPx: Math.max(1, columns * cell.width),
        heightPx: Math.max(SIXEL_BAND, h - (h % SIXEL_BAND)),
        cell: { width: cell.width, height: cell.height },
    }
}

/** The zoom factors usable with a box: the raster at that factor must not be huge. */
export const zoomLevels = (box: SixelBox): number[] =>
    GRAPHIC_ZOOMS.filter(
        (z) =>
            z === 1 ||
            (box.widthPx * z <= ZOOM_MAX_SIDE && box.heightPx * z <= ZOOM_MAX_SIDE),
    )

/**
 * The most a view can be panned, in cells: what the image sticks out past the area.
 *
 * @param imagePx - the image's size along the axis, in pixels.
 * @param areaCells - the area's size along the axis, in cells.
 * @param cellPx - one cell along the axis, in pixels.
 */
export const maxPanCells = (imagePx: number, areaCells: number, cellPx: number): number =>
    Math.max(0, Math.ceil(imagePx / cellPx) - areaCells)

/**
 * The cells to leave before an image to centre it in an area (0 when it fills it).
 *
 * @param areaPx - the area's size along the axis, in pixels.
 * @param imagePx - the image's size along the axis, in pixels.
 * @param cellPx - one cell along the axis, in pixels.
 */
export const centreCells = (areaPx: number, imagePx: number, cellPx: number): number =>
    Math.max(0, Math.floor((areaPx - imagePx) / 2 / cellPx))

/**
 * A window of an image (the part that a pan shows).
 *
 * @param image - the image.
 * @param left - the first pixel column (clamped so the window stays inside).
 * @param top - the first pixel row (clamped likewise).
 * @param width - the window's width (cut to what the image has).
 * @param height - the window's height (cut likewise).
 * @returns a new image; the image itself when the window is all of it.
 */
export function cropImage(
    image: RgbaImage,
    left: number,
    top: number,
    width: number,
    height: number,
): RgbaImage {
    const w = Math.min(width, image.width)
    const h = Math.min(height, image.height)
    if (w === image.width && h === image.height) return image
    const x = Math.max(0, Math.min(left, image.width - w))
    const y = Math.max(0, Math.min(top, image.height - h))
    const data = new Uint8Array(w * h * 4)
    for (let row = 0; row < h; row++) {
        const from = ((y + row) * image.width + x) * 4
        data.set(image.data.subarray(from, from + w * 4), row * w * 4)
    }
    return { width: w, height: h, data }
}

/**
 * The colour of a figure's paper: its top-left pixel, composed onto white when it is
 * transparent. The figure's own background colour (`PLOT_BG_COLOUR`) is painted over the
 * whole page, so the corner is that colour.
 *
 * @param image - the figure's pixels.
 * @returns `[r, g, b]`, white for an empty image.
 */
export function paperColour(image: RgbaImage): [number, number, number] {
    if (image.data.length < 4) return [255, 255, 255]
    const a = (image.data[3] ?? 255) / 255
    const mix = (v: number | undefined): number =>
        Math.round((v ?? 255) * a + 255 * (1 - a))
    return [mix(image.data[0]), mix(image.data[1]), mix(image.data[2])]
}

/**
 * The image centred on a canvas of `width` x `height` pixels in `paper`, every pixel
 * opaque: the image's own transparent pixels are composed onto the paper, so no pixel of
 * the result is left for the terminal's background. An image larger than the canvas is
 * cropped (centred).
 *
 * @param image - the pixels.
 * @param width - the canvas width in pixels.
 * @param height - the canvas height in pixels.
 * @param paper - `[r, g, b]` of the canvas and of what shows through.
 * @returns a new `width` x `height` image, alpha 255 everywhere.
 */
export function padImage(
    image: RgbaImage,
    width: number,
    height: number,
    paper: readonly [number, number, number],
): RgbaImage {
    const data = new Uint8Array(width * height * 4)
    for (let i = 0; i < data.length; i += 4) {
        data[i] = paper[0]
        data[i + 1] = paper[1]
        data[i + 2] = paper[2]
        data[i + 3] = 255
    }
    const dx = Math.floor((width - image.width) / 2)
    const dy = Math.floor((height - image.height) / 2)
    for (let y = 0; y < image.height; y++) {
        const ty = y + dy
        if (ty < 0 || ty >= height) continue
        for (let x = 0; x < image.width; x++) {
            const tx = x + dx
            if (tx < 0 || tx >= width) continue
            const from = (y * image.width + x) * 4
            const to = (ty * width + tx) * 4
            const a = (image.data[from + 3] ?? 255) / 255
            for (let k = 0; k < 3; k++)
                data[to + k] = Math.round(
                    (image.data[from + k] ?? 0) * a + (paper[k] ?? 255) * (1 - a),
                )
        }
    }
    return { width, height, data }
}
