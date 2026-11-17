// SPDX-License-Identifier: LGPL-3.0-or-later

// The pure parts of the plot viewer's frame pipeline: the key of a frame, a byte-limited
// LRU of finished frames, and the queue that makes them one at a time. No React, no
// terminal, no worker: `screens/viewer-graphics.ts` plugs the renderer in.
//
// A frame is the encoded sixel picture of (figure, pixel box, zoom, pan). Paging and zoom
// are instant when the frame is already in the LRU; otherwise the queue renders it in the
// background, the frame wanted NOW first, then the neighbours (next and previous plot, next
// and previous zoom) so the following key press finds them done. The queue holds ONE
// waiting list: every new request replaces what was waiting (a held key asks for many
// frames and only the last one is rendered); the job that is running finishes, its result
// still goes into the LRU.
//
// Contents:
//   1. The key and the LRU
//   2. The queue

// ========================================================================================
// 1. The key and the LRU
// ========================================================================================

/**
 * What identifies a frame.
 *
 * @property figure - the figure (run and plot name, or the rendered file's path).
 * @property stamp - changes when the figure's file does (its modification time).
 * @property widthPx - the box width in pixels.
 * @property heightPx - the box height in pixels.
 * @property cell - the cell size, `WxH`.
 * @property zoom - the zoom factor.
 * @property left - the pan in cells across (ignored at zoom 1: the picture fits).
 * @property top - the pan in cells down (ignored at zoom 1).
 */
export type FrameId = {
    figure: string
    stamp: number
    widthPx: number
    heightPx: number
    cell: string
    zoom: number
    left: number
    top: number
}

/** The string key of a frame (the pan counts only when the view is zoomed). */
export const frameKey = (id: FrameId): string =>
    `${id.figure}|${id.stamp}|${id.widthPx}x${id.heightPx}|${id.cell}|${id.zoom}|` +
    (id.zoom === 1 ? "0,0" : `${id.left},${id.top}`)

/** A finished frame: what the painter writes and what the viewer needs to pan. */
export type Frame = {
    sequence: string
    width: number
    height: number
    fullWidth: number
    fullHeight: number
}

/** The bytes a frame holds in memory (its sequence is one-byte text). */
const frameBytes = (f: Frame): number => f.sequence.length

/**
 * A least-recently-used store limited by bytes. `get` and `set` make an entry the newest;
 * the oldest go when the total passes the limit (the newest always stays).
 *
 * @param maxBytes - the limit.
 * @param sizeOf - the bytes an entry holds.
 */
export class ByteLru<V> {
    private readonly map = new Map<string, V>()
    private total = 0

    constructor(
        private readonly maxBytes: number,
        private readonly sizeOf: (value: V) => number,
    ) {}

    /** The number of entries held. */
    get size(): number {
        return this.map.size
    }

    /** The bytes held. */
    get bytes(): number {
        return this.total
    }

    /** The keys, oldest first. */
    keys(): string[] {
        return [...this.map.keys()]
    }

    /** Is the entry held (does not count as a use)? */
    has(key: string): boolean {
        return this.map.has(key)
    }

    /** The entry, made the newest; `undefined` when not held. */
    get(key: string): V | undefined {
        const value = this.map.get(key)
        if (value === undefined) return undefined
        this.map.delete(key)
        this.map.set(key, value)
        return value
    }

    /** Stores an entry as the newest and drops the oldest ones over the limit. */
    set(key: string, value: V): void {
        const old = this.map.get(key)
        if (old !== undefined) this.total -= this.sizeOf(old)
        this.map.delete(key)
        this.map.set(key, value)
        this.total += this.sizeOf(value)
        for (const [k, v] of this.map) {
            if (this.total <= this.maxBytes || this.map.size <= 1) break
            this.map.delete(k)
            this.total -= this.sizeOf(v)
        }
    }

    /** Forgets every entry. */
    clear(): void {
        this.map.clear()
        this.total = 0
    }
}

/** The LRU of finished frames. */
export class FrameLru extends ByteLru<Frame> {
    constructor(maxBytes: number) {
        super(maxBytes, frameBytes)
    }
}

// ========================================================================================
// 2. The queue
// ========================================================================================

/**
 * One frame to make.
 *
 * @property key - the frame's key ([[frameKey]]).
 * @property run - makes the frame (called at most once per request, never when the LRU
 *     already holds the key).
 * @property done - called with the frame once it is in the LRU (a cache write).
 */
export type FrameJob = {
    key: string
    run: () => Promise<Frame>
    done?: (frame: Frame) => void
}

/** Makes frames one at a time into an [[FrameLru]]; see the top of the file. */
export class FrameQueue {
    private waiting: FrameJob[] = []
    private running: string | undefined
    private readonly listeners = new Set<() => void>()
    /** Why a frame could not be made, by key (a failed job is not tried again). */
    readonly failed = new Map<string, string>()

    constructor(private readonly lru: FrameLru) {}

    /** The key being made now, `undefined` when idle. */
    get busy(): string | undefined {
        return this.running
    }

    /** Is the frame waiting or being made? */
    pending(key: string): boolean {
        return this.running === key || this.waiting.some((j) => j.key === key)
    }

    /** Calls `fn` after every frame made or failed; returns the way to stop. */
    subscribe(fn: () => void): () => void {
        this.listeners.add(fn)
        return () => {
            this.listeners.delete(fn)
        }
    }

    /**
     * Replaces the waiting list. The first job is the one wanted now; the others are
     * made after it, in order. Jobs whose frame is held, that failed before, or that is
     * running now are left out.
     *
     * @param jobs - the frames to make, most wanted first.
     */
    request(jobs: readonly FrameJob[]): void {
        const seen = new Set<string>()
        this.waiting = jobs.filter((j) => {
            if (seen.has(j.key)) return false
            seen.add(j.key)
            return !this.lru.has(j.key) && !this.failed.has(j.key) && j.key !== this.running
        })
        this.pump()
    }

    private pump(): void {
        if (this.running !== undefined) return
        const job = this.waiting.shift()
        if (job === undefined) return
        this.running = job.key
        job.run().then(
            (frame) => {
                this.lru.set(job.key, frame)
                this.running = undefined
                job.done?.(frame)
                this.notify()
                this.pump()
            },
            (error: unknown) => {
                const why = error instanceof Error ? error.message : String(error)
                this.failed.set(job.key, why)
                this.running = undefined
                this.notify()
                this.pump()
            },
        )
    }

    private notify(): void {
        for (const fn of [...this.listeners]) fn()
    }
}
