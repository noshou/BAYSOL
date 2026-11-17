// SPDX-License-Identifier: LGPL-3.0-or-later

// The graphics side of the plot viewer, as hooks: what the run's cache holds for a plot
// and the picture to show for a plot, a zoom and a pan.
//
// Frames (the encoded sixel picture of figure, box, zoom and pan) are made off the main
// thread (`store/frame-render.ts`: a worker rasterises ONE master per figure, derives
// every zoom from it and encodes) and kept in an in-memory LRU, so a page turn or a zoom
// step that was seen or prefetched is instant. Each time the wanted frame changes, the
// queue (`store/frame-cache.ts`) makes it first and then the neighbours: the next and
// previous plot at zoom 1, the next and previous zoom of this plot. While the wanted
// frame is not ready the previous one stays on screen (never a blank in between). All
// decisions are the pure functions of `store/plot-graphics.ts`.
//
// Contents:
//   1. The cache of the plot
//   2. The picture

import { statSync } from "node:fs"
import { useEffect, useMemo, useReducer, useRef } from "react"
import {
    type Frame,
    type FrameJob,
    FrameLru,
    FrameQueue,
    frameKey,
} from "../store/frame-cache.js"
import { type RenderRequest, renderOffThread } from "../store/frame-render.js"
import {
    PLOT_NOT_RENDERED,
    pixelBox,
    provision,
} from "../store/plot-graphics.js"
import { cacheMatches, readSixelCache, type SixelCacheEntry } from "../store/sixel-cache.js"
import type { CellSize } from "../store/sixel-types.js"
import type { SixelFrame } from "../ui/sixel-view.js"

/** The wait after the last change of zoom, pan or size before the work is asked for. */
const WORK_DELAY_MS = 40

/** The frames kept in memory: sixel text is a few hundred kilobytes per frame. */
const FRAME_LIMIT_BYTES = 128 * 1024 * 1024

/** The finished frames of the program, and the queue that makes them. */
const FRAMES = new FrameLru(FRAME_LIMIT_BYTES)
const QUEUE = new FrameQueue(FRAMES)

// ========================================================================================
// 1. The cache of the plot
// ========================================================================================

/** The plot a picture is for. */
export type GraphicTarget = {
    /** The run folder (packed or not). */
    runDir: string
    /** The run-side name of the figure: the cache is `<stem>.SIXEL_ESCAPE_SEQ`. */
    stem: string
    /** The rendered figure file, `undefined` when it is not rendered. */
    source: string | undefined
    /** Whether the run may be written to (a live or packing run is not). */
    writable: boolean
}

/**
 * Reads the cache of a plot (any box) and keeps it. The read is synchronous and happens
 * once per plot while the viewer is open, so the first render of a plot already knows
 * whether the cache exists (no flash of the Unicode view while it is read).
 *
 * @param target - the plot, `undefined` for none.
 * @param supported - the terminal draws sixel (without it nothing is read).
 * @returns the entry (`undefined`: none) and a setter for when one is written.
 */
export function useCacheEntry(
    target: GraphicTarget | undefined,
    supported: boolean,
): [SixelCacheEntry | undefined, (entry: SixelCacheEntry) => void] {
    const key = target === undefined ? "" : `${target.runDir}\0${target.stem}`
    const held = useRef(new Map<string, SixelCacheEntry | null>())
    const [version, bump] = useReducer((n: number) => n + 1, 0)
    // biome-ignore lint/correctness/useExhaustiveDependencies: version marks a write
    const entry = useMemo(() => {
        if (!supported || target === undefined) return undefined
        let e = held.current.get(key)
        if (e === undefined) {
            e = readSixelCache(target.runDir, target.stem) ?? null
            held.current.set(key, e)
        }
        return e ?? undefined
        // the key is the target's identity
    }, [key, supported, version])
    return [
        entry,
        (e) => {
            held.current.set(key, e)
            bump()
        },
    ]
}

// ========================================================================================
// 2. The picture
// ========================================================================================

/**
 * What [[useGraphicFrame]] has.
 *
 * @property frame - the picture; while the wanted one is being made, the previous one;
 *     `undefined` until the first is ready (show Unicode meanwhile).
 * @property full - the size in pixels of the whole picture at this zoom (a pan is a window
 *     of it), `undefined` with no frame.
 * @property error - why no picture could be made, `undefined` when none went wrong.
 * @property busy - the wanted frame is not ready (`frame` is an older one or none).
 */
export type GraphicState = {
    frame: SixelFrame | undefined
    full: { width: number; height: number } | undefined
    error: string | undefined
    busy: boolean
}

const NOTHING: GraphicState = {
    frame: undefined,
    full: undefined,
    error: undefined,
    busy: false,
}

/** The modification time of a figure file (0 when it cannot be read). */
function stampOf(path: string): number {
    try {
        return statSync(path).mtimeMs
    } catch {
        return 0
    }
}

/** The frame an up-to-date cache entry holds. */
const frameOfEntry = (entry: SixelCacheEntry): Frame => ({
    sequence: entry.sequence,
    width: entry.header.image.width,
    height: entry.header.image.height,
    fullWidth: entry.header.image.width,
    fullHeight: entry.header.image.height,
})

/** What a frame is asked for: the view. */
type View = { zoom: number; left: number; top: number }

/**
 * The picture of a plot: from the memory of finished frames, else made in the background
 * (and the neighbouring frames after it).
 *
 * @param args.target - the plot.
 * @param args.ahead - the plots likely to be shown next, most likely first (made at
 *     zoom 1 after the wanted frame).
 * @param args.enabled - the graphics view is wanted (nothing is done otherwise).
 * @param args.cell - the cell size in pixels.
 * @param args.columns - the area's width in cells.
 * @param args.rows - the area's height in cells.
 * @param args.zoom - the zoom factor, 1 for the fit view.
 * @param args.levels - the zoom factors the viewer offers.
 * @param args.pan - the first cell shown, across and down (a zoomed view only).
 * @param args.entry - the cache read ([[useCacheEntry]]).
 * @param args.stored - called with the entry when a fit-view frame was made for the
 *     cache.
 * @returns the state.
 */
export function useGraphicFrame(args: {
    target: GraphicTarget | undefined
    ahead: readonly GraphicTarget[]
    enabled: boolean
    cell: CellSize
    columns: number
    rows: number
    zoom: number
    levels: readonly number[]
    pan: { left: number; top: number }
    entry: SixelCacheEntry | undefined
    stored: (entry: SixelCacheEntry) => void
}): GraphicState {
    const { target, ahead, enabled, cell, columns, rows, zoom, levels, pan, entry } = args
    const [, redraw] = useReducer((n: number) => n + 1, 0)
    const storedRef = useRef(args.stored)
    storedRef.current = args.stored
    const box = pixelBox(columns, rows, cell)
    const maxZoom = Math.max(1, ...levels)

    /** The job (and its key) of a plot at a view; `undefined` without a figure file. */
    const jobOf = (t: GraphicTarget, v: View): FrameJob | undefined => {
        if (t.source === undefined) return undefined
        const stamp = stampOf(t.source)
        const key = frameKey({
            figure: `${t.runDir}\0${t.stem}`,
            stamp,
            widthPx: box.widthPx,
            heightPx: box.heightPx,
            cell: `${cell.width}x${cell.height}`,
            ...v,
        })
        const req: RenderRequest = {
            runDir: t.runDir,
            stem: t.stem,
            source: t.source,
            stamp,
            writable: t.writable,
            widthPx: box.widthPx,
            heightPx: box.heightPx,
            cellWidth: cell.width,
            cellHeight: cell.height,
            zoom: v.zoom,
            maxZoom,
            left: v.left,
            top: v.top,
        }
        return {
            key,
            run: () => renderOffThread(req),
            done: (frame) => {
                // the worker has written the sixel cache of a fit view: the viewer's
                // knowledge of the cache follows (the view opens as graphics next time)
                if (v.zoom === 1 && t.writable)
                    storedRef.current({
                        sequence: frame.sequence,
                        header: {
                            box,
                            image: { width: frame.width, height: frame.height },
                            encoder: 2,
                        },
                    })
            },
        }
    }

    const fit = zoom === 1
    const view: View = { zoom, left: fit ? 0 : pan.left, top: fit ? 0 : pan.top }
    const plan =
        target === undefined
            ? "none"
            : provision(entry, box, zoom, target.source !== undefined, target.writable)
    const wanted = !enabled || target === undefined ? undefined : jobOf(target, view)
    // a fit view the run's cache already holds needs no work at all
    const wantedKey =
        wanted?.key ??
        (enabled && target !== undefined
            ? frameKey({
                figure: `${target.runDir}\0${target.stem}`,
                stamp: 0,
                widthPx: box.widthPx,
                heightPx: box.heightPx,
                cell: `${cell.width}x${cell.height}`,
                ...view,
            })
            : "")
    if (
        enabled &&
        plan === "cache" &&
        entry !== undefined &&
        zoom === 1 &&
        cacheMatches(entry.header, box) &&
        !FRAMES.has(wantedKey)
    )
        FRAMES.set(wantedKey, frameOfEntry(entry))

    // the frame shown until the wanted one is ready
    const shown = useRef<{ key: string; frame: Frame } | undefined>(undefined)
    const current = enabled ? FRAMES.get(wantedKey) : undefined
    if (!enabled) shown.current = undefined
    else if (current !== undefined) shown.current = { key: wantedKey, frame: current }
    const failure = enabled ? QUEUE.failed.get(wantedKey) : undefined
    const wantedRef = useRef("")
    wantedRef.current = wantedKey

    // frames made in the background: render when the wanted one (or a failure) lands
    useEffect(
        () =>
            QUEUE.subscribe(() => {
                if (FRAMES.has(wantedRef.current) || QUEUE.failed.has(wantedRef.current))
                    redraw()
            }),
        [],
    )

    // ask for the wanted frame, then its neighbours; each new request replaces the waiting
    // list, so a held key renders only where it stops
    const aheadSignature = ahead.map((t) => `${t.runDir}\0${t.stem}\0${t.source}`).join("|")
    // biome-ignore lint/correctness/useExhaustiveDependencies: the keys stand for inputs
    useEffect(() => {
        if (!enabled || target === undefined) {
            QUEUE.request([])
            return
        }
        const timer = setTimeout(() => {
            const at = levels.indexOf(zoom)
            const jobs: (FrameJob | undefined)[] = [wanted]
            for (const z of [levels[at + 1], levels[at - 1]])
                if (z !== undefined) jobs.push(jobOf(target, { zoom: z, left: 0, top: 0 }))
            for (const t of ahead) jobs.push(jobOf(t, { zoom: 1, left: 0, top: 0 }))
            QUEUE.request(jobs.filter((j): j is FrameJob => j !== undefined))
        }, WORK_DELAY_MS)
        return () => {
            clearTimeout(timer)
        }
    }, [enabled, wantedKey, aheadSignature, levels.join(","), target?.source])
    // nothing is waiting for a viewer that is gone
    useEffect(
        () => () => {
            QUEUE.request([])
        },
        [],
    )

    if (!enabled || target === undefined) return NOTHING
    if (failure !== undefined) return { ...NOTHING, error: failure }
    if (plan === "none" && current === undefined)
        return { ...NOTHING, error: PLOT_NOT_RENDERED }
    const frame = shown.current
    if (frame === undefined) return { ...NOTHING, busy: true }
    return {
        frame: {
            sequence: frame.frame.sequence,
            key: frame.key,
            width: frame.frame.width,
            height: frame.frame.height,
        },
        full: { width: frame.frame.fullWidth, height: frame.frame.fullHeight },
        error: undefined,
        busy: frame.key !== wantedKey,
    }
}
