// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the pure parts of the graphics view of the plots (store/plot-graphics.ts) and
// of the painter that draws a sixel picture beside Ink (ui/sixel-view.tsx), and of the
// sixel modules (store/sixel-*.ts): reply parsing, the encoder on a tiny image, the cache
// format, and a round trip through the real libraries (an SVG made here, a PDF when
// `pdftocairo` can make one) and through a real run archive.
//
// Contents:
//   1. The render gate
//   2. Which figure is a plot tab
//   3. The default view, the toggle and the cache decision
//   4. Pixels
//   5. The painter
//   6-9. Sixel modules: replies, encoder, cache, real files (store/sixel-*.ts)

import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { join } from "node:path"
import { test } from "node:test"
import {
    canGraphics,
    centreCells,
    chosenView,
    cropImage,
    figurePairs,
    GRAPHICS_UNSUPPORTED,
    graphicsRefusal,
    maxPanCells,
    mayRender,
    PLOT_NOT_RENDERED,
    padImage,
    paperColour,
    pixelBox,
    plotStem,
    provision,
    renderedFile,
    unrenderedTex,
    zoomLevels,
} from "../src/store/plot-graphics.js"
import { type PlotUnit, runFolder } from "../src/store/plots.js"
import { packRun } from "../src/store/run-archive.js"
import {
    cacheMatches,
    formatSixelHeader,
    parseSixelCache,
    parseSixelHeader,
    readSixelCache,
    SIXEL_ENCODER,
    type SixelCacheEntry,
    sixelCacheName,
    writeSixelCache,
} from "../src/store/sixel-cache.js"
import { judgeSixel, parseTerminalReplies } from "../src/store/sixel-detect.js"
import { encodeSixel } from "../src/store/sixel-encode.js"
import { rasterise } from "../src/store/sixel-raster.js"
import type { SixelBox } from "../src/store/sixel-types.js"
import {
    eraseSequence,
    type Placement,
    paintSequence,
    SixelPainter,
} from "../src/ui/sixel-view.js"
import { tempDir } from "./support/fixtures.js"

const unit = (name: string, tex: string[]): PlotUnit => ({
    project: "proj",
    run: "r1",
    runDir: "/nowhere",
    name,
    tex,
    data: [],
})

// ========================================================================================
// 1. The render gate
// ========================================================================================

test("renderedFile: the exact name wins, else the lowest -N, any format", () => {
    assert.equal(renderedFile(["a.pdf", "a-2.pdf"], "a"), "a.pdf")
    assert.equal(renderedFile(["a-3.png", "a-2.svg"], "a"), "a-2.svg")
    assert.equal(renderedFile(["b.pdf"], "a"), undefined)
    assert.equal(renderedFile(["a_hist_c1.pdf"], "a"), undefined)
})

test("unrenderedTex: a 1:1 map by plot name leaves nothing to render", () => {
    const u = unit("m1", ["m1.tex", "m1_residuals.tex"])
    assert.deepEqual(unrenderedTex(u, []), ["m1.tex", "m1_residuals.tex"])
    assert.deepEqual(unrenderedTex(u, ["m1.pdf"]), ["m1_residuals.tex"])
    assert.deepEqual(unrenderedTex(u, ["m1.pdf", "m1_residuals-2.png"]), [])
})

test("unrenderedTex: the comparison is named after the project", () => {
    const u = unit("comparison", ["compare.tex", "compare_residuals.tex"])
    assert.deepEqual(figurePairs(u), [
        { stem: "compare", dest: "proj-compare" },
        { stem: "compare_residuals", dest: "proj-compare_residuals" },
    ])
    assert.deepEqual(unrenderedTex(u, ["proj-compare.pdf"]), ["compare_residuals.tex"])
})

test("mayRender: offered while a figure is missing, never once all are rendered", () => {
    const root = tempDir("gate-")
    const u = unit("m1", ["m1.tex"])
    assert.equal(mayRender(u, root), true)
    const dir = runFolder(root, u)
    // the run folder does not exist yet: still to render
    assert.equal(mayRender(u, root), true)
    assert.equal(mayRender(unit("m1", []), root), false)
    // rendered: a pdf of the same name
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, "m1.pdf"), "")
    assert.equal(mayRender(u, root), false)
})

// ========================================================================================
// 2. Which figure is a plot tab
// ========================================================================================

test("plotStem maps the tab titles to the figure names", () => {
    const stems = [
        "m1",
        "m1_residuals",
        "m1_hist_rhoE",
        "m1_hist_deltaRho1",
        "m1_hist_c1",
    ]
    assert.equal(plotStem("fit", stems, 5), "m1")
    assert.equal(plotStem("residuals (3 off the plot)", stems, 5), "m1_residuals")
    assert.equal(plotStem("ρₑ", stems, 5), "m1_hist_rhoE")
    assert.equal(plotStem("δρ₁", stems, 5), "m1_hist_deltaRho1")
    assert.equal(plotStem("c1", stems, 5), "m1_hist_c1")
    assert.equal(plotStem("scale", stems, 5), undefined)
    assert.equal(plotStem("odd", stems, 5), undefined)
    assert.equal(plotStem("odd", ["only"], 1), "only")
    assert.equal(plotStem("odd", ["only"], 2), undefined)
})

test("plotStem maps the comparison tab to compare (the name the run writes)", () => {
    assert.equal(plotStem("comparison", ["compare"], 2), "compare")
    assert.equal(plotStem("comparison", ["m1", "m1_hist_c1"], 2), undefined)
    assert.equal(plotStem("fit", ["compare"], 2), undefined)
    assert.equal(plotStem("ρₑ", ["m1", "m1_hist_rhoE", "m1_hist_c1"], 9), "m1_hist_rhoE")
})

// ========================================================================================
// 3. Default view, toggle, cache decision
// ========================================================================================

test("graphics are possible only with sixel and a figure or a cache", () => {
    assert.equal(canGraphics({ supported: false, hasSource: true, cached: true }), false)
    assert.equal(canGraphics({ supported: true, hasSource: false, cached: false }), false)
    assert.equal(canGraphics({ supported: true, hasSource: true, cached: false }), true)
    assert.equal(canGraphics({ supported: true, hasSource: false, cached: true }), true)
})

test("chosenView: a cache means graphics, a pick wins, no sixel means Unicode", () => {
    const f = { supported: true, hasSource: true, cached: false }
    assert.equal(chosenView(f, undefined), "unicode")
    assert.equal(chosenView(f, "graphics"), "graphics")
    assert.equal(chosenView({ ...f, cached: true }, undefined), "graphics")
    assert.equal(chosenView({ ...f, cached: true }, "unicode"), "unicode")
    const noSixel = { ...f, supported: false, cached: true }
    assert.equal(chosenView(noSixel, "graphics"), "unicode")
})

test("provision: cache when it matches at zoom 1, else render", () => {
    const box = pixelBox(80, 24, { width: 10, height: 20 })
    const entry: SixelCacheEntry = {
        header: { box, image: { width: 800, height: 480 }, encoder: SIXEL_ENCODER },
        sequence: "x",
    }
    assert.equal(provision(entry, box, 1, true), "cache")
    assert.equal(provision(entry, box, 1, false), "cache")
    assert.equal(provision(entry, box, 2, true), "render")
    assert.equal(provision(undefined, box, 1, true), "render-write")
    assert.equal(provision(undefined, box, 1, true, false), "render")
    assert.equal(provision(undefined, box, 1, false), "none")
    const other = pixelBox(70, 24, { width: 10, height: 20 })
    assert.equal(provision(entry, other, 1, true), "render-write")
})

// ========================================================================================
// 4. Pixels
// ========================================================================================

test("pixelBox cuts the height to whole bands; zoomLevels limits the raster", () => {
    const box = pixelBox(80, 25, { width: 9, height: 17 })
    assert.equal(box.widthPx, 720)
    assert.equal(box.heightPx % 6, 0)
    assert.ok(box.heightPx <= 425)
    assert.deepEqual(zoomLevels(box), [1, 1.5, 2, 3, 4])
    const big = pixelBox(400, 100, { width: 20, height: 40 })
    assert.deepEqual(zoomLevels(big), [1])
})

test("maxPanCells and centreCells", () => {
    assert.equal(maxPanCells(1000, 50, 10), 50)
    assert.equal(maxPanCells(400, 50, 10), 0)
    assert.equal(centreCells(800, 400, 10), 20)
    assert.equal(centreCells(800, 800, 10), 0)
    assert.equal(centreCells(800, 900, 10), 0)
})

test("cropImage takes a clamped window", () => {
    const data = new Uint8Array(4 * 4 * 4)
    for (let i = 0; i < 16; i++) data[i * 4] = i
    const img = { width: 4, height: 4, data }
    assert.equal(cropImage(img, 0, 0, 10, 10), img)
    const c = cropImage(img, 1, 1, 2, 2)
    assert.equal(c.width, 2)
    assert.deepEqual([c.data[0], c.data[4], c.data[8], c.data[12]], [5, 6, 9, 10])
    const edge = cropImage(img, 99, 99, 2, 2)
    assert.equal(edge.data[0], 10)
})

// ========================================================================================
// 5. The painter
// ========================================================================================

const place = (over: Partial<Placement> = {}): Placement => ({
    owner: "a",
    key: "k1",
    row: 3,
    column: 2,
    rows: 2,
    columns: 4,
    sequence: "SIX",
    offsetColumns: 1,
    offsetRows: 0,
    ...over,
})

/** A fake terminal that records writes. */
function fakeStream(): { stream: NodeJS.WriteStream; out: string[] } {
    const out: string[] = []
    const stream = {
        write: (text: string): boolean => {
            out.push(String(text))
            return true
        },
    } as NodeJS.WriteStream
    return { stream, out }
}

test("paint and erase sequences position, save and restore the cursor", () => {
    assert.equal(paintSequence(place()), "\u001b7\u001b[3;3HSIX\u001b8")
    assert.equal(
        eraseSequence(place()),
        "\u001b7\u001b[3;2H    \u001b[4;2H    \u001b8",
    )
})

test("erase paints the theme background on a smaller and a larger placement", () => {
    const blank = "#061113"
    const on = "\u001b[48;2;6;17;19m"
    assert.equal(
        eraseSequence(place({ blank })),
        `\u001b7${on}\u001b[3;2H    \u001b[4;2H    \u001b[49m\u001b8`,
    )
    assert.equal(
        eraseSequence(place({ blank, rows: 3, columns: 6, column: 1 })),
        `\u001b7${on}\u001b[3;1H      \u001b[4;1H      \u001b[5;1H      \u001b[49m\u001b8`,
    )
    // zoom out then in at the same place: the old (larger) area is the one blanked
    const { stream, out } = fakeStream()
    const painter = new SixelPainter(stream, 5)
    const big = place({ blank, rows: 3, columns: 6, key: "z2" })
    painter.show(big)
    const small = place({ blank, key: "z1" })
    painter.show(small)
    assert.equal(out[1], eraseSequence(big) + paintSequence(small))
    painter.show(big)
    assert.equal(out[2], eraseSequence(small) + paintSequence(big))
    painter.detach()
})

test("the painter draws once, redraws inside Ink's write, hides on request", () => {
    const { stream, out } = fakeStream()
    const original = stream.write
    const painter = new SixelPainter(stream, 5)
    painter.show(place())
    assert.equal(out.length, 1)
    painter.show(place()) // the same picture: nothing
    assert.equal(out.length, 1)
    // Ink's frame is ONE write that carries the picture again (no second write)
    stream.write("frame1")
    assert.equal(out.length, 2)
    assert.equal(out[1], `frame1${paintSequence(place())}`)
    // a write of cursor sequences only is not a frame
    stream.write("\u001b[?25l")
    assert.equal(out[2], "\u001b[?25l")
    // a picture that moved blanks the old area first, in one write
    painter.show(place({ row: 5 }))
    assert.ok(out[3]?.startsWith(eraseSequence(place())))
    assert.equal(out.length, 4)
    // another owner cannot take the picture away
    painter.hide("b")
    assert.ok(painter.shown !== undefined)
    painter.hide("a")
    assert.equal(painter.shown, undefined)
    const n = out.length
    stream.write("frame3")
    assert.equal(out.length, n + 1)
    assert.equal(out[n], "frame3") // no redraw once hidden
    painter.detach()
    assert.equal(stream.write, original)
})

test("inside a synchronized update the picture goes just before its end", () => {
    const { stream, out } = fakeStream()
    const painter = new SixelPainter(stream, 5, false)
    painter.show(place())
    const Bsu = "\u001b[?2026h"
    const Esu = "\u001b[?2026l"
    stream.write(Bsu)
    stream.write("frame")
    stream.write(Esu)
    assert.deepEqual(out.slice(1), [Bsu, "frame", paintSequence(place()) + Esu])
    // an update with no frame in it draws nothing
    stream.write(Bsu)
    stream.write(Esu)
    assert.deepEqual(out.slice(-2), [Bsu, Esu])
    painter.detach()
})

test("the painter's own writes are one synchronized write on a terminal", () => {
    const { stream, out } = fakeStream()
    const painter = new SixelPainter(stream, 5, true)
    painter.show(place())
    assert.equal(out.length, 1)
    assert.equal(out[0], `\u001b[?2026h${paintSequence(place())}\u001b[?2026l`)
    // a new picture at the same place: ONE write, no erase before it
    painter.show(place({ key: "k2", sequence: "SIY" }))
    assert.equal(out.length, 2)
    assert.ok(!(out[1] ?? "").includes("    "))
    painter.detach()
})

const ESC = "\u001b"

// ========================================================================================
// 6. Sixel: detection
// ========================================================================================

test("a full reply set is parsed: cell, text area and the DA1 attributes", () => {
    const r = parseTerminalReplies(`${ESC}[6;18;9t${ESC}[4;864;720t${ESC}[?62;4;6c`)
    assert.deepEqual(r.cell, { width: 9, height: 18 })
    assert.deepEqual(r.textArea, { width: 720, height: 864 })
    assert.deepEqual(r.attributes, [62, 4, 6])
    assert.equal(r.done, true)
})

test("typed keys among the replies are ignored, and no DA1 means not done", () => {
    const r = parseTerminalReplies(`abc${ESC}[6;20;10t`)
    assert.deepEqual(r.cell, { width: 10, height: 20 })
    assert.equal(r.attributes, undefined)
    assert.equal(r.done, false)
})

test("judging: sixel attribute and cell size make it supported", () => {
    const ok = judgeSixel(parseTerminalReplies(`${ESC}[6;18;9t${ESC}[?62;4c`), 80, 24)
    assert.deepEqual(ok, { supported: true, cell: { width: 9, height: 18 }, reason: "" })
})

test("judging: the cell falls back to the text area over columns and rows", () => {
    const r = judgeSixel(parseTerminalReplies(`${ESC}[4;480;720t${ESC}[?4c`), 80, 24)
    assert.equal(r.supported, true)
    assert.deepEqual(r.cell, { width: 9, height: 20 })
})

test("judging: no sixel attribute, no cell size and no answer are all unsupported", () => {
    const none = judgeSixel(parseTerminalReplies(`${ESC}[6;18;9t${ESC}[?62;6c`), 80, 24)
    assert.equal(none.supported, false)
    assert.match(none.reason, /sixel/)
    const nocell = judgeSixel(parseTerminalReplies(`${ESC}[?62;4c`), 80, 24)
    assert.equal(nocell.supported, false)
    assert.match(nocell.reason, /cell size/)
    const silent = judgeSixel(parseTerminalReplies(""), 80, 24)
    assert.equal(silent.supported, false)
    assert.match(silent.reason, /did not answer/)
})

// ========================================================================================
// 7. Sixel: the encoder
// ========================================================================================

/** An image from rows of `[r, g, b, a]` pixels. */
const image = (rows: number[][][]) => ({
    width: rows[0]?.length ?? 0,
    height: rows.length,
    data: new Uint8Array(rows.flat(2)),
})

test("a 2x2 red/blue image encodes to the known sequence", () => {
    const R = [255, 0, 0, 255]
    const B = [0, 0, 255, 255]
    const out = encodeSixel(image([[R, B], [R, B]]))
    // header, palette in order of appearance, one band: red has column 0 on both rows
    // (bits 1+2 = 3 -> 'B'), blue column 1 ('?B' with its empty first column)
    assert.equal(out, `${ESC}Pq"1;1;2;2#0;2;100;0;0#1;2;0;0;100#0B$#1?B${ESC}\\`)
})

test("runs over three are run-length coded, shorter ones are repeated", () => {
    const K = [0, 0, 0, 255]
    const W = [255, 255, 255, 255]
    const row = [K, K, K, K, K, W, W, W]
    const out = encodeSixel(image([row]))
    assert.equal(out, `${ESC}Pq"1;1;8;1#0;2;0;0;0#1;2;100;100;100#0!5@$#1!5?@@@${ESC}\\`)
})

test("bands of six rows are separated by -, the last band may be short", () => {
    const K = [0, 0, 0, 255]
    const rows = Array.from({ length: 7 }, () => [K])
    const out = encodeSixel(image(rows))
    // 6 rows -> bits 63 ('~'), 1 row -> bit 1 ('@')
    assert.equal(out, `${ESC}Pq"1;1;1;7#0;2;0;0;0#0~-#0@${ESC}\\`)
})

test("transparent pixels are composed onto the background (white by default)", () => {
    const out = encodeSixel(image([[[10, 20, 30, 0]]]))
    assert.ok(out.includes("#0;2;100;100;100"))
    const dark = encodeSixel(image([[[10, 20, 30, 0]]]), { background: [0, 0, 0] })
    assert.ok(dark.includes("#0;2;0;0;0"))
})

test("more colours than the palette holds are cut down and every index is valid", () => {
    const rows = [Array.from({ length: 64 }, (_, i) => [i * 4, 255 - i * 4, 7, 255])]
    for (const dither of [false, true]) {
        const out = encodeSixel(image(rows), { maxColors: 8, dither })
        const colours = [...out.matchAll(/#(\d+);2;/g)].map((m) => Number(m[1]))
        assert.equal(colours.length, 8)
        for (const m of out.matchAll(/#(\d+)(?![\d;])/g)) assert.ok(Number(m[1]) < 8)
    }
})

test("bad input is refused", () => {
    assert.throws(() => encodeSixel({ width: 2, height: 2, data: new Uint8Array(3) }))
    assert.throws(() => encodeSixel(image([[[0, 0, 0, 255]]]), { maxColors: 1 }))
})

// ========================================================================================
// 8. Sixel: the cache, names, header, matching
// ========================================================================================

const BOX: SixelBox = { widthPx: 800, heightPx: 500, cell: { width: 9, height: 18 } }
const HEADER = {
    box: BOX,
    image: { width: 800, height: 493 },
    encoder: SIXEL_ENCODER,
}

test("cache names, headers and matching", () => {
    assert.equal(sixelCacheName("res_hist_c1"), "res_hist_c1.SIXEL_ESCAPE_SEQ")
    const line = formatSixelHeader(HEADER)
    assert.equal(line, "# box 800x500 px, cell 9x18, image 800x493 px, encoder 2")
    assert.deepEqual(parseSixelHeader(line), HEADER)
    assert.equal(parseSixelHeader("# box 800x500"), undefined)
    assert.equal(cacheMatches(HEADER, BOX), true)
    assert.equal(cacheMatches(HEADER, { ...BOX, widthPx: 799 }), false)
    assert.equal(cacheMatches(HEADER, { ...BOX, cell: { width: 10, height: 18 } }), false)
})

test("a cache file is split into header and sequence, junk is refused", () => {
    const seq = `${ESC}Pq#0B${ESC}\\`
    const parsed = parseSixelCache(`${formatSixelHeader(HEADER)}\n${seq}\n`)
    assert.deepEqual(parsed, { header: HEADER, sequence: seq })
    assert.equal(parseSixelCache("no header\n"), undefined)
    assert.equal(parseSixelCache(`${formatSixelHeader(HEADER)}\nnot sixel\n`), undefined)
})

// ========================================================================================
// 9. Sixel: rasterising and the cache in a run (real files)
// ========================================================================================

const SVG =
    '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">' +
    '<circle cx="50" cy="50" r="40" fill="red"/>' +
    '<rect x="110" y="20" width="60" height="60" fill="blue" fill-opacity="0.5"/></svg>'

test("an SVG is rasterised fitted, on white, and cached in a run", async () => {
    const dir = tempDir("baysol-sixel-test-")
    const svg = join(dir, "fig.svg")
    writeFileSync(svg, SVG)
    const img = await rasterise(svg, 100, 100)
    // 2:1 figure into a square box: full width, half the height
    assert.deepEqual([img.width, img.height], [100, 50])
    assert.equal(img.data.length, 100 * 50 * 4)
    // the corner is white and opaque (no background in the file: drawn onto white)
    assert.deepEqual([...img.data.slice(0, 4)], [255, 255, 255, 255])
    const sixel = encodeSixel(img)
    assert.ok(sixel.startsWith(`${ESC}Pq"1;1;100;50`) && sixel.endsWith(`${ESC}\\`))

    // the cache in a plain run folder, then in the packed archive
    const run = join(dir, "run-1")
    const make = async (name: string) => {
        await writeSixelCache(run, name, sixel, {
            box: { widthPx: 100, heightPx: 100, cell: { width: 9, height: 18 } },
            image: { width: img.width, height: img.height },
        })
    }
    execFileSync("mkdir", [run])
    writeFileSync(join(run, "run.LOG"), "x\n")
    await make("plot_a")
    const want = { widthPx: 100, heightPx: 100, cell: { width: 9, height: 18 } }
    assert.equal(readSixelCache(run, "plot_a", want)?.sequence, sixel)
    assert.equal(readSixelCache(run, "plot_a", { ...want, widthPx: 90 }), undefined)
    assert.equal(readSixelCache(run, "plot_b"), undefined)

    assert.equal(await packRun(run), 2)
    assert.equal(existsSync(run), false)
    assert.equal(readSixelCache(run, "plot_a", want)?.sequence, sixel)
    // written into the finished archive: the other entries stay
    await make("plot_b")
    assert.equal(readSixelCache(run, "plot_b", want)?.sequence, sixel)
    assert.equal(readSixelCache(run, "plot_a", want)?.sequence, sixel)
    assert.ok(existsSync(`${run}.7z`))
    // and replaced
    await writeSixelCache(run, "plot_a", `${ESC}Pq#0B${ESC}\\`, HEADER)
    assert.equal(readSixelCache(run, "plot_a")?.sequence, `${ESC}Pq#0B${ESC}\\`)
})

test("a PNG keeps its alpha, a PDF is drawn on white", async () => {
    const dir = tempDir("baysol-sixel-test-")
    const svg = join(dir, "fig.svg")
    writeFileSync(svg, SVG)
    let pdf: string | undefined
    try {
        pdf = join(dir, "fig.pdf")
        execFileSync("pdftocairo", ["-pdf", svg, pdf])
    } catch {
        pdf = undefined // no poppler here: the PDF part is skipped
    }
    const png = join(dir, "fig.png")
    const Resvg = createRequire(import.meta.url)("@resvg/resvg-js").Resvg
    writeFileSync(png, new Resvg(readFileSync(svg)).render().asPng())
    const p = await rasterise(png, 400, 400)
    assert.deepEqual([p.width, p.height], [400, 200])
    assert.equal(p.data[3], 0, "the PNG's transparent corner stays transparent")
    if (pdf !== undefined && existsSync(pdf)) {
        const d = await rasterise(pdf, 300, 300)
        assert.deepEqual([d.width, d.height], [300, 150])
        assert.deepEqual([...d.data.slice(0, 4)], [255, 255, 255, 255])
    }
    await assert.rejects(rasterise(join(dir, "x.txt"), 10, 10), /not a figure format/)
    await assert.rejects(rasterise(svg, 0, 10), /not usable/)
})

test("the `bkgrnd corr` tab finds the bkgrndCorr figure", () => {
    const stems = ["m", "m_residuals", "m_hist_bkgrndCorr"]
    assert.equal(plotStem("bkgrnd corr", stems, 3), "m_hist_bkgrndCorr")
    assert.equal(plotStem("bkgrndCorr", stems, 3), "m_hist_bkgrndCorr")
})

test("the plot-type key always has a reason when the graphics view cannot open", () => {
    const ok = {
        supported: true,
        hasFigures: true,
        hasStem: true,
        hasSource: true,
        cached: false,
    }
    assert.equal(graphicsRefusal(ok), undefined)
    assert.equal(graphicsRefusal({ ...ok, hasSource: false, cached: true }), undefined)
    const why = (over: Partial<typeof ok>) =>
        graphicsRefusal({ ...ok, ...over }) ?? { text: "", error: false }
    const term = why({ supported: false })
    assert.equal(term.text, GRAPHICS_UNSUPPORTED)
    assert.equal(term.text, "terminal can only display unicode graphics")
    assert.equal(term.error, true)
    for (const over of [{ hasFigures: false }, { hasStem: false }, { hasSource: false }])
        assert.equal(why(over).text, PLOT_NOT_RENDERED)
    assert.equal(PLOT_NOT_RENDERED, "plot not rendered")
})

// ========================================================================================
// 10. Sixel: opaque pixels, padding, cache version
// ========================================================================================

test("paperColour is the corner, a transparent corner is white", () => {
    const two = image([[[10, 20, 30, 255], [1, 2, 3, 255]]])
    assert.deepEqual(paperColour(two), [10, 20, 30])
    assert.deepEqual(paperColour(image([[[10, 20, 30, 0]]])), [255, 255, 255])
})

test("padImage: transparent pixels become the paper, the canvas is padded with it", () => {
    const paper = [20, 40, 60] as const
    const out = padImage(image([[[255, 0, 0, 255], [9, 9, 9, 0]]]), 4, 3, paper)
    assert.deepEqual([out.width, out.height, out.data.length], [4, 3, 48])
    const px = (x: number, y: number) => {
        const at = (y * 4 + x) * 4
        return [...out.data.slice(at, at + 4)]
    }
    // 2x1 image centred in 4x3: at x 1..2, y 1
    assert.deepEqual(px(1, 1), [255, 0, 0, 255])
    assert.deepEqual(px(2, 1), [20, 40, 60, 255])
    assert.deepEqual(px(0, 0), [20, 40, 60, 255])
    assert.deepEqual(px(3, 2), [20, 40, 60, 255])
    for (let i = 3; i < out.data.length; i += 4) assert.equal(out.data[i], 255)
})

test("a padded image encodes with the same header form and no white where paper is", () => {
    const paper = [20, 40, 60] as const
    const out = encodeSixel(padImage(image([[[255, 0, 0, 255]]]), 6, 6, paper))
    assert.ok(out.startsWith(`${ESC}Pq"1;1;6;6`) && out.endsWith(`${ESC}\\`))
    assert.ok(out.includes(";2;8;16;24"))
    assert.ok(!out.includes(";2;100;100;100"))
})

test("cache header: encoder version written, unversioned header is a miss", () => {
    const line = formatSixelHeader({ box: BOX, image: { width: 8, height: 4 } })
    assert.match(line, /, encoder 2$/)
    assert.equal(parseSixelHeader(line)?.encoder, SIXEL_ENCODER)
    const old = parseSixelHeader("# box 800x500 px, cell 9x18, image 800x493 px")
    assert.equal(old?.encoder, 0)
    assert.ok(old !== undefined && !cacheMatches(old, BOX))
    assert.ok(cacheMatches(HEADER, BOX))
})
