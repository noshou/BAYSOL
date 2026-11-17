// SPDX-License-Identifier: LGPL-3.0-or-later

// Making one frame of the plot viewer: the figure's pixels, cropped to the pan, padded to
// the box and encoded as sixel. It runs in a worker thread (`frame-worker.ts`, started by
// [[renderOffThread]]) so that rasterising and encoding never block Ink's input; when no
// worker can be started the same code runs inline.
//
// The pixels come from ONE "master" raster per figure: the figure rasterised at the box
// times the largest zoom. Every zoom is derived from it by resampling and the pan is a
// crop, so no zoom step or page rasterises the figure again. The master is looked up in
// memory ([[MASTERS]]), then in the run's raster cache (`raster-cache.ts`, verified, a bad
// file is rasterised again and replaced), and only then rasterised and written back.
// Whole frames at zoom 1 are also read from and written to the run's sixel cache.
//
// Contents:
//   1. The request
//   2. The pixels
//   3. The frame
//   4. The worker

import { existsSync } from "node:fs"
import { join } from "node:path"
import { Worker } from "node:worker_threads"
import { PACK_LOCK } from "../core/archive.js"
import { ByteLru, type Frame } from "./frame-cache.js"
import { cropImage, padImage, paperColour } from "./plot-graphics.js"
import {
    decodeRaster,
    encodeRaster,
    RASTER_MAX_RAW,
    rasterCacheName,
} from "./raster-cache.js"
import { readRunBytes } from "./run-archive.js"
import {
    cacheMatches,
    readSixelCache,
    SIXEL_ENCODER,
    writeRunBytes,
    writeSixelCache,
} from "./sixel-cache.js"
import { encodeSixel } from "./sixel-encode.js"
import { rasterise } from "./sixel-raster.js"
import type { RgbaImage, SixelBox } from "./sixel-types.js"

// ========================================================================================
// 1. The request
// ========================================================================================

/**
 * One frame to make.
 *
 * @property runDir - the run (its folder; the caches live in it or its archive).
 * @property stem - the plot's run-side name (the cache files are named for it).
 * @property source - the rendered figure file.
 * @property stamp - its modification time.
 * @property writable - the caches may be written to the run.
 * @property widthPx - the box width in pixels.
 * @property heightPx - the box height in pixels.
 * @property cellWidth - the cell width in pixels.
 * @property cellHeight - the cell height in pixels.
 * @property zoom - the zoom factor of the frame.
 * @property maxZoom - the largest zoom factor the viewer offers (the master's).
 * @property left - the pan in cells across.
 * @property top - the pan in cells down.
 */
export type RenderRequest = {
    runDir: string
    stem: string
    source: string
    stamp: number
    writable: boolean
    widthPx: number
    heightPx: number
    cellWidth: number
    cellHeight: number
    zoom: number
    maxZoom: number
    left: number
    top: number
}

// ========================================================================================
// 2. The pixels
// ========================================================================================

/** The masters kept in memory, by size in bytes (a 5120 x 3120 master is 64 MB). */
const MASTER_LIMIT_BYTES = 160 * 1024 * 1024

/** The masters held by this thread (the worker's, or the main thread's when inline). */
const MASTERS = new ByteLru<RgbaImage>(MASTER_LIMIT_BYTES, (i) => i.data.length)

/** The most the raster cache of one figure may take in the run, compressed. */
const RASTER_FILE_MAX = 64 * 1024 * 1024

/** Cache writes go one after the other (an archive is updated by one writer at a time). */
let writes: Promise<void> = Promise.resolve()

/** Queues a write behind the earlier ones; a failure of a cache write is ignored. */
function queueWrite(job: () => Promise<void>): void {
    writes = writes.then(job).catch(() => {})
}

/**
 * The master raster of a figure: from memory, from the run's raster cache, or rasterised
 * (and cached).
 */
async function master(req: RenderRequest): Promise<RgbaImage> {
    const w = Math.round(req.widthPx * req.maxZoom)
    const h = Math.round(req.heightPx * req.maxZoom)
    const key = `${req.runDir}\0${req.stem}|${req.stamp}|${w}x${h}`
    const held = MASTERS.get(key)
    if (held !== undefined) return held
    const name = rasterCacheName(req.stem, w, h)
    let image: RgbaImage | undefined
    try {
        image = decodeRaster(readRunBytes(req.runDir, name, RASTER_FILE_MAX), req.stamp)
    } catch {
        // no file (or an archive that cannot be read): rasterise
    }
    if (image === undefined || image.data.length > RASTER_MAX_RAW) {
        image = await rasterise(req.source, w, h)
        if (req.writable && !existsSync(join(req.runDir, PACK_LOCK))) {
            const bytes = encodeRaster(image, req.stamp)
            queueWrite(() => writeRunBytes(req.runDir, name, bytes))
        }
    }
    MASTERS.set(key, image)
    return image
}

/** Resamples the master to what fits `w` x `h` (the master itself when it is that). */
async function derive(image: RgbaImage, w: number, h: number): Promise<RgbaImage> {
    const scale = Math.min(w / image.width, h / image.height)
    const dw = Math.max(1, Math.round(image.width * scale))
    const dh = Math.max(1, Math.round(image.height * scale))
    if (dw === image.width && dh === image.height) return image
    const { default: sharp } = await import("sharp")
    const { data, info } = await sharp(image.data, {
        raw: { width: image.width, height: image.height, channels: 4 },
    })
        .resize({ width: dw, height: dh, fit: "fill", kernel: "lanczos3" })
        .raw()
        .toBuffer({ resolveWithObject: true })
    return { width: info.width, height: info.height, data: new Uint8Array(data) }
}

// ========================================================================================
// 3. The frame
// ========================================================================================

/**
 * Makes a frame.
 *
 * @param req - what to make.
 * @returns the frame.
 * @throws Error when the figure cannot be rasterised.
 */
export async function renderFrame(req: RenderRequest): Promise<Frame> {
    const box: SixelBox = {
        widthPx: req.widthPx,
        heightPx: req.heightPx,
        cell: { width: req.cellWidth, height: req.cellHeight },
    }
    // the whole frame at zoom 1 may be in the sixel cache already
    if (req.zoom === 1) {
        const cached = readSixelCache(req.runDir, req.stem)
        if (cached !== undefined && cacheMatches(cached.header, box))
            return {
                sequence: cached.sequence,
                width: cached.header.image.width,
                height: cached.header.image.height,
                fullWidth: cached.header.image.width,
                fullHeight: cached.header.image.height,
            }
    }
    const base = await master(req)
    const image = await derive(
        base,
        Math.round(req.widthPx * req.zoom),
        Math.round(req.heightPx * req.zoom),
    )
    const view = cropImage(
        image,
        req.left * req.cellWidth,
        req.top * req.cellHeight,
        req.widthPx,
        req.heightPx,
    )
    // every pixel of the area painted: the figure's paper colour fills the box
    const padded = padImage(view, req.widthPx, req.heightPx, paperColour(image))
    const sequence = encodeSixel(padded)
    if (req.zoom === 1 && req.writable && !existsSync(join(req.runDir, PACK_LOCK))) {
        const header = {
            box,
            image: { width: padded.width, height: padded.height },
            encoder: SIXEL_ENCODER,
        }
        queueWrite(() => writeSixelCache(req.runDir, req.stem, sequence, header))
    }
    return {
        sequence,
        width: padded.width,
        height: padded.height,
        fullWidth: image.width,
        fullHeight: image.height,
    }
}

// ========================================================================================
// 4. The worker
// ========================================================================================

type Pending = { resolve: (f: Frame) => void; reject: (e: Error) => void }

let worker: Worker | undefined
let broken = false
let nextId = 1
const pending = new Map<number, Pending>()

/** Starts the worker once; `undefined` when it cannot be (the caller renders inline). */
function startWorker(): Worker | undefined {
    if (broken) return undefined
    if (worker !== undefined) return worker
    try {
        const ext = import.meta.url.endsWith(".ts") ? "ts" : "js"
        const w = new Worker(new URL(`./frame-worker.${ext}`, import.meta.url))
        w.unref()
        w.on("message", (m: { id: number; frame?: Frame; error?: string }) => {
            const p = pending.get(m.id)
            if (p === undefined) return
            pending.delete(m.id)
            if (m.frame !== undefined) p.resolve(m.frame)
            else p.reject(new Error(m.error ?? "the frame worker failed"))
        })
        const fail = (error: Error): void => {
            broken = true
            worker = undefined
            for (const p of pending.values()) p.reject(error)
            pending.clear()
        }
        w.on("error", fail)
        w.on("exit", () => fail(new Error("the frame worker stopped")))
        worker = w
        return w
    } catch {
        broken = true
        return undefined
    }
}

/**
 * Makes a frame in the worker thread, inline when no worker can run.
 *
 * @param req - what to make.
 */
export function renderOffThread(req: RenderRequest): Promise<Frame> {
    const w = startWorker()
    if (w === undefined) return renderFrame(req)
    return new Promise<Frame>((resolve, reject) => {
        const id = nextId++
        pending.set(id, { resolve, reject })
        w.postMessage({ id, req })
    }).catch((error: Error) =>
        // a worker that died is replaced by the inline path, once
        broken ? renderFrame(req) : Promise.reject(error),
    )
}
