// SPDX-License-Identifier: LGPL-3.0-or-later

// The worker thread of the plot viewer's frames: it answers each request of
// `frame-render.ts` with a frame, or with the reason it failed.

import { parentPort } from "node:worker_threads"
import { type RenderRequest, renderFrame } from "./frame-render.js"

parentPort?.on("message", (m: { id: number; req: RenderRequest }) => {
    renderFrame(m.req).then(
        (frame) => parentPort?.postMessage({ id: m.id, frame }),
        (error: unknown) =>
            parentPort?.postMessage({
                id: m.id,
                error: error instanceof Error ? error.message : String(error),
            }),
    )
})
