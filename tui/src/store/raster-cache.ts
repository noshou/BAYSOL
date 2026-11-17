// SPDX-License-Identifier: LGPL-3.0-or-later

// The raster cache: the rasterised figure (the pixels the sixel encoder reads), kept
// compressed in the run so that showing a plot, a zoom or a pan never rasterises the
// figure again. One file per figure and size, `<plot name>-<W>x<H>.RGBA_DEFLATE`, a flat
// file of the run like the sixel cache (so it is packed into the run's `.7z` too).
//
// Format (binary, big-endian numbers), the header is 33 bytes:
//
//   0   4  magic `BRGA`
//   4   1  version ([[RASTER_VERSION]])
//   5   8  stamp: the figure file's modification time (float64); another time = stale
//  13   4  width in pixels
//  17   4  height in pixels
//  21   4  length of the raw RGBA data (width * height * 4)
//  25   4  CRC-32 of the raw data
//  29   4  length of the deflated payload
//  33  ..  the payload (zlib deflate of the RGBA bytes)
//
// [[decodeRaster]] checks magic, version, stamp, every length and the CRC and answers
// `undefined` for anything that does not agree, so a half-written or damaged file is
// never loaded as a picture: the caller rasterises again and replaces it. Writing is
// atomic (`writeRunBytes`: a temporary file renamed over the old one, or an archive
// update). Pure: no file is touched here.

import { crc32, deflateSync, inflateSync } from "node:zlib"
import type { RgbaImage } from "./sixel-types.js"

/** The version of the file format; another one is read as no cache. */
const RASTER_VERSION = 1

const MAGIC = "BRGA"
const HEADER_BYTES = 33

/** The largest raster read back, in raw bytes (a 4096 x 4096 RGBA picture is 64 MB). */
export const RASTER_MAX_RAW = 128 * 1024 * 1024

/**
 * The file name of a raster in the run.
 *
 * @param plotName - the plot's name.
 * @param width - the width the figure was rasterised for, in pixels.
 * @param height - the height, in pixels.
 */
export const rasterCacheName = (plotName: string, width: number, height: number): string =>
    `${plotName}-${width}x${height}.RGBA_DEFLATE`

/**
 * The bytes of a raster file.
 *
 * @param image - the pixels.
 * @param stamp - the figure file's modification time.
 */
export function encodeRaster(image: RgbaImage, stamp: number): Buffer {
    const raw = Buffer.from(image.data.buffer, image.data.byteOffset, image.data.byteLength)
    const payload = deflateSync(raw, { level: 1 })
    const head = Buffer.alloc(HEADER_BYTES)
    head.write(MAGIC, 0, "latin1")
    head.writeUInt8(RASTER_VERSION, 4)
    head.writeDoubleBE(stamp, 5)
    head.writeUInt32BE(image.width, 13)
    head.writeUInt32BE(image.height, 17)
    head.writeUInt32BE(raw.length, 21)
    head.writeUInt32BE(crc32(raw), 25)
    head.writeUInt32BE(payload.length, 29)
    return Buffer.concat([head, payload])
}

/**
 * Reads a raster file, verifying it.
 *
 * @param bytes - the file's content.
 * @param stamp - the figure file's modification time now.
 * @returns the pixels; `undefined` when the file is not a raster of this format and
 *     version, is for another figure version (stamp), is cut short, is longer than its
 *     header says, or its data does not match its length or CRC.
 */
export function decodeRaster(bytes: Buffer, stamp: number): RgbaImage | undefined {
    try {
        if (bytes.length < HEADER_BYTES || bytes.toString("latin1", 0, 4) !== MAGIC)
            return undefined
        if (bytes.readUInt8(4) !== RASTER_VERSION || bytes.readDoubleBE(5) !== stamp)
            return undefined
        const width = bytes.readUInt32BE(13)
        const height = bytes.readUInt32BE(17)
        const rawLength = bytes.readUInt32BE(21)
        const crc = bytes.readUInt32BE(25)
        const payloadLength = bytes.readUInt32BE(29)
        if (width < 1 || height < 1 || rawLength !== width * height * 4) return undefined
        if (rawLength > RASTER_MAX_RAW || bytes.length !== HEADER_BYTES + payloadLength)
            return undefined
        const raw = inflateSync(bytes.subarray(HEADER_BYTES), {
            maxOutputLength: rawLength,
        })
        if (raw.length !== rawLength || crc32(raw) !== crc) return undefined
        const data = new Uint8Array(raw.buffer, raw.byteOffset, rawLength)
        return { width, height, data }
    } catch {
        // a damaged payload is no cache
        return undefined
    }
}
