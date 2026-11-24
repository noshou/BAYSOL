// SPDX-License-Identifier: LGPL-3.0-or-later

// The sixel cache: the escape sequence of a plot kept in the run, so a figure is not
// rasterised and encoded again each time it is shown.
//
// File: `<plot name>.SIXEL_ESCAPE_SEQ` ([[sixelCacheName]]), a flat file of the run like
// `<plot name>.tex`, so it is packed into the run's `.7z` like the other files. Text:
//
//   line 1   `# box WxH px, cell CWxCH, image IWxIH px`   (the header, see [[SixelHeader]])
//   line 2   `ESC P q ... ESC \\`                         (the sequence, to write as it is)
//
// `box` is the pixel box the figure was fitted into and `cell` the cell size it was worked
// out from; `image` is the size the fitted figure came out as. A cached file matches a
// wanted box when box and cell are both equal ([[cacheMatches]]): a resized terminal, a
// font change or another cell size asks for a new rendering, which replaces the file.
//
// Where it lives: a run is a plain folder while it goes (and when its pack failed) and one
// `.7z` once it is packed (`store/run-archive.ts`). Reading takes either ([[readRunText]]:
// the folder first). Writing goes to the folder if it is there, else INTO the archive,
// which is updated in place (`addToArchive`, `core/archive.ts`; other entries untouched).

import {
    mkdirSync,
    renameSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs"
import { dirname, join } from "node:path"
import { ArchiveError, addToArchive, isSafeEntryName } from "../core/archive.js"
import { scratchTemp } from "../core/scratch.js"
import { archivePath, readRunText } from "./run-archive.js"
import type { CellSize, SixelBox } from "./sixel-types.js"

/**
 * The version of the picture a cache file holds. A file written by an older encoder
 * (no version in its header counts as 0) does not match, so it is made again and the
 * normal write replaces it. Raise it when the pixels the encoder gets change (2: the
 * picture is composed onto the figure's paper colour and padded to the whole box).
 */
export const SIXEL_ENCODER = 2

/** The extension of a cache file. */
const SIXEL_CACHE_EXTENSION = ".SIXEL_ESCAPE_SEQ"

/** The most bytes a cache file is read or written with (a figure of a few megapixels). */
const SIXEL_CACHE_MAX_BYTES = 32 * 1024 * 1024

/**
 * The first line of a cache file, as numbers.
 *
 * @property box - the pixel box and cell size the figure was fitted to.
 * @property image - the size of the fitted figure in pixels.
 * @property encoder - the version of the picture ([[SIXEL_ENCODER]]); a header made
 *     without one is written with the current version, one read without one has 0.
 */
export type SixelHeader = { box: SixelBox; image: CellSize; encoder?: number }

/**
 * A cache file read.
 *
 * @property header - its first line.
 * @property sequence - the sixel sequence (everything after the first line).
 */
export type SixelCacheEntry = { header: SixelHeader; sequence: string }

/**
 * The file name of a plot's cache.
 *
 * @param plotName - the plot's name (`res_hist_c1`; no extension, no folder part needed).
 * @returns `<plotName>.SIXEL_ESCAPE_SEQ`.
 */
export const sixelCacheName = (plotName: string): string =>
    `${plotName}${SIXEL_CACHE_EXTENSION}`

/**
 * Makes the header line (no line break).
 *
 * @param header - the numbers to write.
 */
export function formatSixelHeader({ box, image, encoder }: SixelHeader): string {
    return (
        `# box ${box.widthPx}x${box.heightPx} px, ` +
        `cell ${box.cell.width}x${box.cell.height}, ` +
        `image ${image.width}x${image.height} px, ` +
        `encoder ${encoder ?? SIXEL_ENCODER}`
    )
}

const HEADER_LINE = new RegExp(
    "^# box (\\d+)x(\\d+) px, cell (\\d+)x(\\d+), " +
        "image (\\d+)x(\\d+) px(?:, encoder (\\d+))?$",
)

/**
 * Reads a header line. Pure.
 *
 * @param line - the text of the first line.
 * @returns the numbers, `undefined` when the line is not a header of this format.
 */
export function parseSixelHeader(line: string): SixelHeader | undefined {
    const m = HEADER_LINE.exec(line.trim())
    if (m === null) return undefined
    const n = m.slice(1).map(Number)
    const [bw, bh, cw, ch, iw, ih] = n
    if ([bw, bh, cw, ch, iw, ih].some((v) => v === undefined || v < 1)) return undefined
    return {
        box: {
            widthPx: bw ?? 0,
            heightPx: bh ?? 0,
            cell: { width: cw ?? 0, height: ch ?? 0 },
        },
        image: { width: iw ?? 0, height: ih ?? 0 },
        encoder: Number(m[7] ?? 0),
    }
}

/**
 * Does a cached file serve the wanted box? Pure.
 *
 * @param header - the cache's header.
 * @param wanted - the box now wanted.
 * @returns true when pixel box and cell size are both the same and the picture is of
 *     the current encoder version ([[SIXEL_ENCODER]]).
 */
export function cacheMatches(header: SixelHeader, wanted: SixelBox): boolean {
    const b = header.box
    return (
        b.widthPx === wanted.widthPx &&
        b.heightPx === wanted.heightPx &&
        b.cell.width === wanted.cell.width &&
        b.cell.height === wanted.cell.height &&
        (header.encoder ?? 0) === SIXEL_ENCODER
    )
}

/**
 * Splits the text of a cache file into header and sequence. Pure.
 *
 * @returns the entry, `undefined` for a file that is not a cache file (no header, or no
 *     sixel sequence after it).
 */
export function parseSixelCache(text: string): SixelCacheEntry | undefined {
    const cut = text.indexOf("\n")
    if (cut < 0) return undefined
    const header = parseSixelHeader(text.slice(0, cut))
    const sequence = text.slice(cut + 1).replace(/\n$/, "")
    const framed = sequence.startsWith("\u001bP") && sequence.endsWith("\u001b\\")
    if (header === undefined || !framed) return undefined
    return { header, sequence }
}

/**
 * Reads a plot's cache from a run (its folder, else its archive).
 *
 * @param runDir - the run (its folder's path; it need not exist once packed).
 * @param plotName - the plot's name, as given to [[writeSixelCache]].
 * @param wanted - when given, a cache that does not match this box counts as none.
 * @returns the entry, `undefined` for no file, an unreadable or malformed one, or one
 *     for another box. Never throws: a cache is only ever an optimisation.
 */
export function readSixelCache(
    runDir: string,
    plotName: string,
    wanted?: SixelBox,
): SixelCacheEntry | undefined {
    try {
        const text = readRunText(runDir, sixelCacheName(plotName), SIXEL_CACHE_MAX_BYTES)
        const entry = parseSixelCache(text)
        if (entry === undefined) return undefined
        const fits = wanted === undefined || cacheMatches(entry.header, wanted)
        return fits ? entry : undefined
    } catch {
        // no file, or an archive that cannot be read: there is simply no cache
        return undefined
    }
}

/** Is the run a plain folder (so a file can be written beside the others)? */
function isFolder(path: string): boolean {
    try {
        return statSync(path).isDirectory()
    } catch {
        return false
    }
}

/**
 * Writes a plot's cache into a run: into its folder when it is a plain folder, else into
 * its `.7z` archive (the archive is updated in place; an older cache of the plot is
 * replaced; nothing else in it changes).
 *
 * @param runDir - the run (folder path).
 * @param plotName - the plot's name (a safe entry name without `.SIXEL_ESCAPE_SEQ`).
 * @param sequence - the sixel sequence from `encodeSixel`.
 * @param header - the box and the image size, for the first line.
 * @throws [[ArchiveError]] when the run is nowhere (neither folder nor archive), the name
 *     is not safe, the file is too large, or the archive cannot be updated.
 */
export async function writeSixelCache(
    runDir: string,
    plotName: string,
    sequence: string,
    header: SixelHeader,
): Promise<void> {
    const name = sixelCacheName(plotName)
    if (!isSafeEntryName(name)) throw new ArchiveError(`not a safe name: ${name}`)
    const text = `${formatSixelHeader(header)}\n${sequence}\n`
    if (text.length > SIXEL_CACHE_MAX_BYTES) throw new ArchiveError(`${name} is too large`)
    await writeRunBytes(runDir, name, Buffer.from(text, "utf-8"))
}

/**
 * Writes a file into a run, atomically: a plain folder gets a temporary file renamed over
 * the name (a reader sees the old file or the new one, never half of it); an archive is
 * updated in place by 7-Zip (its own temporary archive, renamed when done).
 *
 * @param runDir - the run (folder path).
 * @param name - a safe entry name (`/`-separated, relative to the run).
 * @param bytes - the content.
 * @throws [[ArchiveError]] when the name is not safe, the run is nowhere or the archive
 *     cannot be updated.
 */
export async function writeRunBytes(
    runDir: string,
    name: string,
    bytes: Buffer,
): Promise<void> {
    if (!isSafeEntryName(name)) throw new ArchiveError(`not a safe name: ${name}`)
    if (isFolder(runDir)) {
        const path = join(runDir, ...name.split("/"))
        mkdirSync(dirname(path), { recursive: true })
        const part = `${path}.${process.pid}.${Date.now()}.part`
        try {
            writeFileSync(part, bytes)
            renameSync(part, path)
        } finally {
            rmSync(part, { force: true })
        }
        return
    }
    const archive = archivePath(runDir)
    const stage = scratchTemp("sixel")
    try {
        const path = join(stage, ...name.split("/"))
        mkdirSync(dirname(path), { recursive: true })
        writeFileSync(path, bytes)
        await addToArchive(archive, stage, [name])
    } finally {
        rmSync(stage, { recursive: true, force: true })
    }
}
