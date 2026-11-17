// SPDX-License-Identifier: LGPL-3.0-or-later

// Rasterising a figure file (PDF, SVG or PNG) into RGBA pixels, the WHOLE figure scaled to
// fit a pixel box with its aspect kept (the result is at most the box, not padded to it).
// Backgrounds: a PDF or SVG is drawn onto white (what it paints itself stays), a PNG keeps
// its own alpha channel (the sixel encoder flattens what is left transparent).
//
// Libraries (all native, loaded on first use): `@resvg/resvg-js` for SVG, `sharp` for PNG
// and for scaling, `pdf-raster` (PDFium) for PDF with `pdftocairo` (poppler) as the
// fallback when PDFium cannot be loaded or fails. The PDF choice lives in ONE place,
// [[PDF_RENDERERS]].

import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { extname } from "node:path"
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

/**
 * Decodes encoded image bytes (PNG) to RGBA scaled to fit the box.
 *
 * @param flatten - draw onto white (true) or keep the alpha channel (false).
 */
async function decodeFit(
    bytes: Buffer,
    widthPx: number,
    heightPx: number,
    flatten: boolean,
): Promise<RgbaImage> {
    const { default: sharp } = await import("sharp")
    let image = sharp(bytes)
    if (flatten) image = image.flatten({ background: WHITE })
    const { data, info } = await image
        .ensureAlpha()
        .resize({ width: widthPx, height: heightPx, fit: "inside" })
        .raw()
        .toBuffer({ resolveWithObject: true })
    return { width: info.width, height: info.height, data: new Uint8Array(data) }
}

/** An SVG drawn onto white, scaled to fit the box. */
async function rasteriseSvg(path: string, widthPx: number, heightPx: number) {
    const { Resvg } = await import("@resvg/resvg-js")
    const svg = readFileSync(path)
    const size = new Resvg(svg)
    const wide = size.width / size.height >= widthPx / heightPx
    const fitTo = wide
        ? { mode: "width" as const, value: widthPx }
        : { mode: "height" as const, value: heightPx }
    const png = new Resvg(svg, { fitTo, background: WHITE }).render().asPng()
    // through sharp once more: the rounding of the fit is then the same as for the others
    return decodeFit(Buffer.from(png), widthPx, heightPx, true)
}

/** The first page of a PDF as PNG bytes through PDFium, at `dpi`. */
async function pdfPngByPdfRaster(path: string, dpi: number): Promise<Buffer> {
    const { convert } = await import("pdf-raster")
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
            const { default: sharp } = await import("sharp")
            const probe = await sharp(await render(path, PDF_POINTS_PER_INCH)).metadata()
            const w = probe.width ?? 0
            const h = probe.height ?? 0
            if (w === 0 || h === 0) throw new Error("empty page")
            // dpi that makes the page at least as large as the box, so it is only shrunk
            const dpi = Math.ceil(
                PDF_POINTS_PER_INCH * Math.max(widthPx / w, heightPx / h, 1),
            )
            return await decodeFit(await render(path, dpi), widthPx, heightPx, true)
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
            return await decodeFit(readFileSync(path), widthPx, heightPx, false)
    } catch (error) {
        if (error instanceof RasteriseError) throw error
        throw new RasteriseError(
            `cannot read ${path}: ${error instanceof Error ? error.message : error}`,
        )
    }
    throw new RasteriseError(`${ext || path} is not a figure format (pdf, svg, png)`)
}
