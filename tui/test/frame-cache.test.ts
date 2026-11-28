// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the plot viewer's frame pipeline: the frame key, the byte-limited LRU, the queue
// (priority, replacement of the waiting list, failures), the verified raster cache file
// and the frame renderer on a real figure (the sixel and raster caches in a run folder).
//
// Contents:
//   1. Key and LRU
//   2. The queue
//   3. The raster cache file
//   4. The renderer

import assert from "node:assert/strict"
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import test from "node:test"
import {
    ByteLru,
    type Frame,
    FrameLru,
    FrameQueue,
    frameKey,
} from "../src/store/frame-cache.js"
import { renderFrame } from "../src/store/frame-render.js"
import { decodeRaster, encodeRaster, rasterCacheName } from "../src/store/raster-cache.js"
import { tempDir } from "./support/fixtures.js"

const frame = (n: number): Frame => ({
    sequence: "x".repeat(n),
    width: 1,
    height: 1,
    fullWidth: 1,
    fullHeight: 1,
})

const id = {
    figure: "run\0fit",
    stamp: 5,
    widthPx: 100,
    heightPx: 60,
    cell: "10x20",
    zoom: 2,
    left: 3,
    top: 4,
}

// ========================================================================================
// 1. Key and LRU
// ========================================================================================

test("the frame key names figure, box, zoom and pan (pan only when zoomed)", () => {
    assert.notEqual(frameKey(id), frameKey({ ...id, left: 4 }))
    assert.notEqual(frameKey(id), frameKey({ ...id, stamp: 6 }))
    assert.notEqual(frameKey(id), frameKey({ ...id, widthPx: 101 }))
    assert.notEqual(frameKey(id), frameKey({ ...id, cell: "9x20" }))
    assert.equal(
        frameKey({ ...id, zoom: 1, left: 9, top: 9 }),
        frameKey({ ...id, zoom: 1, left: 0, top: 0 }),
    )
})

test("the LRU drops the least recently used frames over its byte limit", () => {
    const lru = new FrameLru(100)
    lru.set("a", frame(40))
    lru.set("b", frame(40))
    lru.get("a") // a is now newer than b
    lru.set("c", frame(40))
    assert.deepEqual(lru.keys(), ["a", "c"])
    assert.equal(lru.bytes, 80)
    assert.equal(lru.has("b"), false)
})

test("the LRU keeps the newest entry even when it alone is over the limit", () => {
    const lru = new ByteLru<number[]>(10, (v) => v.length)
    lru.set("big", new Array(50).fill(0))
    assert.equal(lru.size, 1)
    lru.set("big", [1, 2])
    assert.equal(lru.bytes, 2)
    lru.clear()
    assert.equal(lru.size, 0)
})

// ========================================================================================
// 2. The queue
// ========================================================================================

/** A job that finishes when `release()` is called. */
function gated(key: string, log: string[]) {
    let release: () => void = () => {}
    const gate = new Promise<void>((r) => {
        release = r
    })
    return {
        job: {
            key,
            run: async () => {
                log.push(`run ${key}`)
                await gate
                return frame(5)
            },
        },
        release,
    }
}

const settle = () => new Promise((r) => setImmediate(r))

/**
 * Polls until `ok()` holds (a background write), at most 5 s; a failed read is "not yet".
 */
async function waitFor(ok: () => boolean): Promise<void> {
    for (const end = Date.now() + 5000; Date.now() < end; ) {
        try {
            if (ok()) return
        } catch {
            // the file is not there yet
        }
        await new Promise((r) => setTimeout(r, 20))
    }
}

test("the queue makes the wanted frame first, then the rest, one at a time", async () => {
    const lru = new FrameLru(1000)
    const queue = new FrameQueue(lru)
    const log: string[] = []
    const jobs = ["a", "b", "c"].map((k) => gated(k, log))
    queue.request(jobs.map((j) => j.job))
    await settle()
    assert.deepEqual(log, ["run a"])
    assert.equal(queue.busy, "a")
    jobs[0]?.release()
    await settle()
    assert.deepEqual(log, ["run a", "run b"])
    assert.ok(lru.has("a"))
    jobs[1]?.release()
    jobs[2]?.release()
    await settle()
    await settle()
    assert.deepEqual(log, ["run a", "run b", "run c"])
    assert.equal(queue.busy, undefined)
})

test("a new request replaces the waiting list (a held key: only the last)", async () => {
    const lru = new FrameLru(1000)
    const queue = new FrameQueue(lru)
    const log: string[] = []
    const first = gated("z1", log)
    queue.request([first.job])
    const stale = ["z2", "z3", "z4"].map((k) => gated(k, log))
    queue.request([stale[0]?.job as never])
    queue.request([stale[1]?.job as never])
    const last = gated("z5", log)
    queue.request([last.job])
    first.release()
    last.release()
    await settle()
    await settle()
    // the running one finished, the replaced ones never ran, the last one did
    assert.deepEqual(log, ["run z1", "run z5"])
    assert.ok(lru.has("z1") && lru.has("z5"))
})

test("the queue skips held, running, duplicate and failed frames", async () => {
    const lru = new FrameLru(1000)
    lru.set("held", frame(1))
    const queue = new FrameQueue(lru)
    const log: string[] = []
    const heard: number[] = []
    queue.subscribe(() => heard.push(1))
    const bad = {
        key: "bad",
        run: async () => {
            log.push("run bad")
            throw new Error("no figure")
        },
    }
    const ok = {
        key: "ok",
        run: async () => {
            log.push("run ok")
            return frame(1)
        },
    }
    queue.request([{ key: "held", run: async () => frame(1) }, bad, bad, ok])
    await settle()
    await settle()
    assert.deepEqual(log, ["run bad", "run ok"])
    assert.equal(queue.failed.get("bad"), "no figure")
    assert.equal(heard.length, 2)
    // a failed frame is not tried again
    queue.request([bad])
    await settle()
    assert.deepEqual(log, ["run bad", "run ok"])
})

// ========================================================================================
// 3. The raster cache file
// ========================================================================================

const image = (w: number, h: number) => {
    const data = new Uint8Array(w * h * 4)
    for (let i = 0; i < data.length; i++) data[i] = (i * 7) % 256
    return { width: w, height: h, data }
}

test("a raster file round-trips", () => {
    const img = image(13, 9)
    const back = decodeRaster(encodeRaster(img, 42), 42)
    assert.ok(back !== undefined)
    assert.equal(back?.width, 13)
    assert.deepEqual([...(back?.data ?? [])], [...img.data])
    assert.equal(rasterCacheName("m_fit", 640, 480), "m_fit-640x480.RGBA_DEFLATE")
})

test("a raster file that is stale, cut, padded or damaged is never loaded", () => {
    const bytes = encodeRaster(image(20, 10), 1)
    assert.equal(decodeRaster(bytes, 2), undefined) // the figure changed
    assert.equal(decodeRaster(bytes.subarray(0, bytes.length - 3), 1), undefined)
    assert.equal(decodeRaster(Buffer.concat([bytes, Buffer.from([0])]), 1), undefined)
    assert.equal(decodeRaster(bytes.subarray(0, 20), 1), undefined)
    assert.equal(decodeRaster(Buffer.from("not a raster at all, no"), 1), undefined)
    const flipped = Buffer.from(bytes)
    flipped[flipped.length - 5] = (flipped[flipped.length - 5] ?? 0) ^ 0xff
    assert.equal(decodeRaster(flipped, 1), undefined)
    const wrongVersion = Buffer.from(bytes)
    wrongVersion[4] = 9
    assert.equal(decodeRaster(wrongVersion, 1), undefined)
})

// ========================================================================================
// 4. The renderer
// ========================================================================================

const SVG =
    '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">' +
    '<rect width="200" height="100" fill="#eef"/>' +
    '<circle cx="50" cy="50" r="30" fill="red"/>' +
    "</svg>"

test("a frame comes from the run's raster; a damaged raster is replaced", async () => {
    const dir = tempDir("baysol-frames-")
    const source = join(dir, "fig.svg")
    writeFileSync(source, SVG)
    const run = join(dir, "run")
    const { mkdirSync } = await import("node:fs")
    mkdirSync(run)
    const req = {
        runDir: run,
        stem: "fig",
        source,
        stamp: 7,
        writable: true,
        widthPx: 120,
        heightPx: 60,
        cellWidth: 6,
        cellHeight: 12,
        zoom: 2,
        maxZoom: 2,
        left: 0,
        top: 0,
    }
    const first = await renderFrame(req)
    assert.ok(first.sequence.startsWith("\u001bP") && first.sequence.endsWith("\u001b\\"))
    assert.equal(first.width, 120)
    assert.equal(first.fullWidth, 240)
    await settle()
    const file = join(run, rasterCacheName("fig", 240, 120))
    await waitFor(() => existsSync(file))
    assert.ok(existsSync(file), readdirSync(run).join(","))
    // a pan is a crop of the same raster: another frame, no new file
    const panned = await renderFrame({ ...req, left: 5 })
    assert.notEqual(panned.sequence, first.sequence)
    // a damaged cache file is replaced, never trusted
    writeFileSync(file, readFileSync(file).subarray(0, 40))
    const again = await renderFrame({ ...req, stamp: 8 })
    assert.equal(again.fullWidth, 240)
    await waitFor(() => decodeRaster(readFileSync(file), 8) !== undefined)
    assert.ok(decodeRaster(readFileSync(file), 8) !== undefined)
})
