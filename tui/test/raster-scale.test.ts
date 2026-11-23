// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the Lanczos resampler and the white flattening (`store/raster-scale.ts`).

import assert from "node:assert/strict"
import { test } from "node:test"
import { flattenOnWhite, resizeRgba } from "../src/store/raster-scale.js"
import type { RgbaImage } from "../src/store/sixel-types.js"

/** A solid image of one colour. */
function solid(width: number, height: number, rgba: number[]): RgbaImage {
    const data = new Uint8Array(width * height * 4)
    for (let i = 0; i < data.length; i += 4) data.set(rgba, i)
    return { width, height, data }
}

test("a flat colour stays that colour, shrunk or enlarged", () => {
    for (const [w, h] of [
        [3, 2],
        [40, 30],
    ] as const) {
        const out = resizeRgba(solid(17, 9, [200, 100, 50, 255]), w, h)
        assert.deepEqual([out.width, out.height], [w, h])
        for (let i = 0; i < out.data.length; i += 4)
            assert.deepEqual([...out.data.slice(i, i + 4)], [200, 100, 50, 255])
    }
})

test("the same size gives the image itself", () => {
    const image = solid(4, 4, [1, 2, 3, 4])
    assert.equal(resizeRgba(image, 4, 4), image)
})

test("a transparent pixel does not bleed its colour into its neighbours", () => {
    const image = solid(8, 1, [255, 0, 0, 255])
    for (let x = 4; x < 8; x++) image.data.set([0, 255, 0, 0], x * 4) // green, invisible
    const out = resizeRgba(image, 4, 1)
    for (let x = 0; x < 4; x++) {
        const [r, g, , a] = out.data.slice(x * 4, x * 4 + 4)
        if ((a ?? 0) > 0) assert.ok((g ?? 0) <= 1, `pixel ${x} kept a green tinge`)
        assert.ok((r ?? 0) >= 254 || a === 0)
    }
})

test("flattening draws a half-transparent black on grey and opaque stays", () => {
    const out = flattenOnWhite({
        width: 2,
        height: 1,
        data: new Uint8Array([0, 0, 0, 128, 10, 20, 30, 255]),
    })
    assert.deepEqual([...out.data], [127, 127, 127, 255, 10, 20, 30, 255])
})
