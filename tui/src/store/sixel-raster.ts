// SPDX-License-Identifier: LGPL-3.0-or-later

// Rasterising a figure file (PDF, SVG or PNG) into RGBA pixels, the WHOLE figure scaled to
// fit a pixel box with its aspect kept (the result is at most the box, not padded to it).
// Backgrounds: a PDF or SVG is drawn onto white (what it paints itself stays), a PNG keeps
// its own alpha channel (the sixel encoder flattens what is left transparent).
//
// Libraries (loaded on first use): `@resvg/resvg-js` (native) for SVG, `pngjs` for
// PNG, [[resizeRgba]] for scaling, `pdf-raster` (PDFium, native) for PDF with
// `pdftocairo` (poppler) as the fallback when PDFium cannot be loaded or fails. In
// the packaged app the native files are assets of the executable
// (`core/native-assets.ts`). The PDF choice lives in ONE place, [[PDF_RENDERERS]].

import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { createRequire } from "node:module"
import { extname } from "node:path"
import { PNG } from "pngjs"
import { extractNativeAsset, inSingleExecutable, loadNativeAddon } from "../core/native-assets.js"
import { flattenOnWhite, resizeRgba } from "./raster-scale.js"
import type { RgbaImage } from "./sixel-types.js"

/** Why a figure could not be rasterised: a sentence for the user. */
class RasteriseError extends Error {}

/** The white that a figure without background is drawn on. */
const WHITE = "#ffffff"

/** The points per inch of a PDF page, so a page at this dpi is one pixel per point. */
const PDF_POINTS_PER_INCH = 72

/** The figure formats [[rasterise]] reads, by lower-case extension. */
export const RASTER_FORMATS = [".pdf", ".svg", ".png"] as const

/**
 * The PDF renderers in the order they are tried: the first that works is used. The only
 * place that decides it; drop `"pdf-raster"` to use poppler alone.
 */
const PDF_RENDERERS: readonly ("pdf-raster" | "pdftocairo")[] = [
    "pdf-raster",
    "pdftocairo",
]

/** Largest side of a box taken, in pixels (a guard against a runaway request). */
const MAX_SIDE = 16384

/** The native files of the packaged app (assets of the single executable, see the build). */
const NATIVE_RESVG = "native/resvg.node"
const NATIVE_PDF_RASTER = "native/pdf-raster.node"
const NATIVE_PDFIUM = "native/pdfium"

/** The native `Resvg` class: its constructor takes the SVG and the options as JSON text. */
type NativeResvg = new (
    svg: Buffer,
    options?: string,
) => {
    width: number
    height: number
    render(): { width: number; height: number; pixels: Buffer }
}

/**
 * The native `Resvg` class: from the extracted addon of the packaged app, else from the
 * `@resvg/resvg-js` package of a checkout (its binding module, not the JS wrapper that
 * turns the options into JSON, so both paths call it the same way).
 */
function nativeResvg(): NativeResvg {
    if (inSingleExecutable())
        return loadNativeAddon(extractNativeAsset(NATIVE_RESVG)).Resvg as NativeResvg
    const specifier = "@resvg/resvg-js/js-binding.js" // not a literal: the bundle has no use for it
    const binding = createRequire(import.meta.url)(specifier) as Record<string, unknown>
    return binding.Resvg as NativeResvg
}

/** RGBA pixels of an encoded PNG. */
function decodePng(bytes: Buffer): RgbaImage {
    const png = PNG.sync.read(bytes)
    return { width: png.width, height: png.height, data: new Uint8Array(png.data) }
}

/** The size of an image fitted into a box with the aspect kept (at least 1 x 1). */
function fitSize(image: RgbaImage, widthPx: number, heightPx: number) {
    const scale = Math.min(widthPx / image.width, heightPx / image.height)
    return {
        width: Math.max(1, Math.round(image.width * scale)),
        height: Math.max(1, Math.round(image.height * scale)),
    }
}

/** Fits an image into the box, drawn onto white first when `flatten`. */
function fit(image: RgbaImage, widthPx: number, heightPx: number, flatten: boolean) {
    const { width, height } = fitSize(image, widthPx, heightPx)
    const scaled = resizeRgba(image, width, height)
    return flatten ? flattenOnWhite(scaled) : scaled
}

/** An SVG drawn onto white, scaled to fit the box. */
async function rasteriseSvg(path: string, widthPx: number, heightPx: number) {
    const Resvg = nativeResvg()
    const svg = readFileSync(path)
    const size = new Resvg(svg)
    const wide = size.width / size.height >= widthPx / heightPx
    const fitTo = wide
        ? { mode: "width" as const, value: widthPx }
        : { mode: "height" as const, value: heightPx }
    const image = new Resvg(svg, JSON.stringify({ fitTo, background: WHITE })).render()
    const raster = {
        width: image.width,
        height: image.height,
        data: new Uint8Array(image.pixels),
    }
    return fit(raster, widthPx, heightPx, true)
}

/** The page converter of `pdf-raster`, its native files from the executable when packaged. */
async function pdfConvert() {
    if (inSingleExecutable()) {
        // the wrapper reads these two variables before it looks for a platform package
        process.env.NAPI_RS_NATIVE_LIBRARY_PATH ??= extractNativeAsset(NATIVE_PDF_RASTER)
        process.env.PDFIUM_LIB_PATH ??= extractNativeAsset(NATIVE_PDFIUM)
    }
    return (await import("pdf-raster")).convert
}

/** The first page of a PDF as PNG bytes through PDFium, at `dpi`. */
async function pdfPngByPdfRaster(path: string, dpi: number): Promise<Buffer> {
    const convert = await pdfConvert()
    const [page] = await convert(path, { pages: [0], dpi, outputFormat: "png" })
    if (page === undefined) throw new Error("no page")
    return page.data
}

/** The first page of a PDF as PNG bytes through poppler's `pdftocairo`, at `dpi`. */
function pdfPngByPdftocairo(path: string, dpi: number): Promise<Buffer> {
    return new Promise((resolve, reject) => {
        const child = spawn(
            "pdftocairo",
            ["-png", "-singlefile", "-f", "1", "-l", "1", "-r", String(dpi), path, "-"],
            { windowsHide: true },
        )
        const chunks: Buffer[] = []
        let failure = ""
        child.stdout.on("data", (c: Buffer) => chunks.push(c))
        child.stderr.on("data", (c: Buffer) => {
            failure += c.toString("utf-8")
        })
        child.on("error", (e) =>
            reject(new Error(`pdftocairo could not run: ${e.message}`)),
        )
        child.on("close", (code) =>
            code === 0
                ? resolve(Buffer.concat(chunks))
                : reject(new Error(failure.trim().split("\n")[0] || `pdftocairo ${code}`)),
        )
    })
}

/** The first page of a PDF, fitted: the page size comes from a first render at 72 dpi. */
async function rasterisePdf(path: string, widthPx: number, heightPx: number) {
    const problems: string[] = []
    for (const renderer of PDF_RENDERERS) {
        const render = renderer === "pdf-raster" ? pdfPngByPdfRaster : pdfPngByPdftocairo
        try {
            const probe = decodePng(await render(path, PDF_POINTS_PER_INCH))
            if (probe.width === 0 || probe.height === 0) throw new Error("empty page")
            // dpi that makes the page at least as large as the box, so it is only shrunk
            const dpi = Math.ceil(
                PDF_POINTS_PER_INCH *
                    Math.max(widthPx / probe.width, heightPx / probe.height, 1),
            )
            return fit(decodePng(await render(path, dpi)), widthPx, heightPx, true)
        } catch (error) {
            problems.push(`${renderer}: ${error instanceof Error ? error.message : error}`)
        }
    }
    throw new RasteriseError(`cannot render the PDF (${problems.join("; ")})`)
}

/**
 * Rasterises the whole figure in a file, fitted into a box with the aspect kept.
 *
 * @param path - a `.pdf` (first page), `.svg` or `.png` file.
 * @param widthPx - the box width in pixels (1 to 16384).
 * @param heightPx - the box height in pixels (1 to 16384).
 * @returns the image, as large as fits the box (one side equals the box's, the other at
 *     most), RGBA. PDF and SVG are drawn onto white; a PNG keeps its alpha.
 * @throws [[RasteriseError]] for a box that is not sensible, an extension that is not one
 *     of [[RASTER_FORMATS]], or a file the libraries cannot read.
 */
export async function rasterise(
    path: string,
    widthPx: number,
    heightPx: number,
): Promise<RgbaImage> {
    const side = (n: number): boolean => Number.isInteger(n) && n >= 1 && n <= MAX_SIDE
    if (!side(widthPx) || !side(heightPx))
        throw new RasteriseError(`the box ${widthPx}x${heightPx} px is not usable`)
    const ext = extname(path).toLowerCase()
    try {
        if (ext === ".svg") return await rasteriseSvg(path, widthPx, heightPx)
        if (ext === ".pdf") return await rasterisePdf(path, widthPx, heightPx)
        if (ext === ".png")
            return fit(decodePng(readFileSync(path)), widthPx, heightPx, false)
    } catch (error) {
        if (error instanceof RasteriseError) throw error
        throw new RasteriseError(
            `cannot read ${path}: ${error instanceof Error ? error.message : error}`,
        )
    }
    throw new RasteriseError(`${ext || path} is not a figure format (pdf, svg, png)`)
}
