// SPDX-License-Identifier: LGPL-3.0-or-later

// SPDX-License-Identifier: LGPL-3.0-or-later

// The stored zip the program writes itself (src/core/zip-writer.ts): the classic format
// below its limits and zip64 above them. A real 4 GiB zip is out of reach of a unit test,
// so the limits are lowered to make small data take every zip64 path.
//
// Each zip is parsed from its bytes, and 7-Zip lists it, tests it (CRCs) and extracts
// every entry, so that the structures are right for a reader that is not this code.

import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"
import { crc32 } from "node:zlib"
import { archiveTool, listEntries, readEntry } from "../src/core/archive.js"
import {
    writeStoredZipAsync,
    writeStoredZipSync,
    ZIP_LIMITS,
    type ZipLimits,
} from "../src/core/zip-writer.js"
import { tempDir, writeFiles } from "./support/fixtures.js"

const FILES: Record<string, string> = {
    "[Content_Types].xml": "<Types/>",
    "docProps/app.xml": "x".repeat(20),
    "_rels/.rels": "<Relationships/>",
    "xl/ρ.xml": "<worksheet/>",
}
const ORDER = Object.keys(FILES)

type Central = {
    name: string
    version: number
    crc: number
    csize: number
    usize: number
    offset: number
    extra: Buffer
}

/** A zip taken apart: the central entries as written (the markers included), the end. */
function parse(zip: Buffer): {
    central: Central[]
    eocd: { count: number; size: number; offset: number }
    z64?: { count: number; size: number; offset: number; at: number }
    locator?: { at: number; offset: number }
} {
    const end = zip.length - 22
    assert.equal(zip.readUInt32LE(end), 0x06054b50)
    const eocd = {
        count: zip.readUInt16LE(end + 10),
        size: zip.readUInt32LE(end + 12),
        offset: zip.readUInt32LE(end + 16),
    }
    let z64: ReturnType<typeof parse>["z64"]
    let locator: ReturnType<typeof parse>["locator"]
    let count = eocd.count
    let at = eocd.offset
    if (zip.readUInt32LE(end - 20) === 0x07064b50) {
        locator = { at: end - 20, offset: Number(zip.readBigUInt64LE(end - 12)) }
        const r = locator.offset
        assert.equal(zip.readUInt32LE(r), 0x06064b50)
        assert.equal(zip.readBigUInt64LE(r + 4), 44n)
        assert.equal(zip.readUInt16LE(r + 12), 45)
        assert.equal(zip.readUInt16LE(r + 14), 45)
        assert.equal(zip.readBigUInt64LE(r + 24), zip.readBigUInt64LE(r + 32))
        z64 = {
            at: r,
            count: Number(zip.readBigUInt64LE(r + 32)),
            size: Number(zip.readBigUInt64LE(r + 40)),
            offset: Number(zip.readBigUInt64LE(r + 48)),
        }
        assert.equal(r, z64.offset + z64.size, "the record follows the directory")
        assert.equal(locator.at, r + 56, "the locator follows the record")
        count = z64.count
        at = z64.offset
    }
    const central: Central[] = []
    for (let i = 0; i < count; i++) {
        assert.equal(zip.readUInt32LE(at), 0x02014b50)
        const nameLength = zip.readUInt16LE(at + 28)
        const extraLength = zip.readUInt16LE(at + 30)
        central.push({
            version: zip.readUInt16LE(at + 6),
            crc: zip.readUInt32LE(at + 16),
            csize: zip.readUInt32LE(at + 20),
            usize: zip.readUInt32LE(at + 24),
            offset: zip.readUInt32LE(at + 42),
            name: zip.subarray(at + 46, at + 46 + nameLength).toString("utf-8"),
            extra: zip.subarray(at + 46 + nameLength, at + 46 + nameLength + extraLength),
        })
        at += 46 + nameLength + extraLength
    }
    assert.equal(at, (z64?.offset ?? eocd.offset) + (z64?.size ?? eocd.size), "directory size")
    return { central, eocd, ...(z64 ? { z64 } : {}), ...(locator ? { locator } : {}) }
}

/** The zip64 extra field as its 64-bit values. */
function values(extra: Buffer): number[] {
    if (extra.length === 0) return []
    assert.equal(extra.readUInt16LE(0), 0x0001)
    assert.equal(extra.readUInt16LE(2), extra.length - 4)
    return Array.from({ length: (extra.length - 4) / 8 }, (_, i) =>
        Number(extra.readBigUInt64LE(4 + 8 * i)),
    )
}

/** Writes the zip both ways (same bytes), and has 7-Zip test, list and extract it. */
async function make(limits: ZipLimits): Promise<Buffer> {
    const folder = tempDir()
    writeFiles(folder, FILES)
    const sync = join(tempDir(), "s.zip")
    const async_ = join(tempDir(), "a.zip")
    writeStoredZipSync(folder, ORDER, sync, limits)
    await writeStoredZipAsync(folder, ORDER, async_, limits)
    const bytes = readFileSync(sync)
    assert.ok(bytes.equals(readFileSync(async_)), "sync and async agree")
    const tested = spawnSync(archiveTool(), ["t", "-bd", sync], { encoding: "utf-8" })
    assert.equal(tested.status, 0, `7-Zip: ${tested.stdout}${tested.stderr}`)
    assert.deepEqual(listEntries(sync).map((e) => e.name).sort(), [...ORDER].sort())
    for (const name of ORDER) assert.equal(readEntry(sync, name).toString("utf-8"), FILES[name])
    return bytes
}

/** The entries as local headers read them, in the order of the file. */
function localNames(zip: Buffer): string[] {
    const { central } = parse(zip)
    return central
        .map((c) => ({ name: c.name, at: c.offset === 0xffffffff ? Infinity : c.offset }))
        .sort((a, b) => a.at - b.at)
        .map((c) => c.name)
}

/** The size of a local entry up to its data, the name and extra field included. */
const first = (): number => 30 + Buffer.byteLength(ORDER[0] as string)

test("below the limits the zip is a classic one: no zip64 structure anywhere", async () => {
    const zip = await make(ZIP_LIMITS)
    const p = parse(zip)
    assert.equal(p.z64, undefined)
    assert.equal(zip.includes(Buffer.from([0x50, 0x4b, 0x06, 0x06])), false)
    assert.deepEqual(p.central.map((c) => c.name), ORDER)
    for (const c of p.central) {
        assert.equal(c.version, 20)
        assert.equal(c.extra.length, 0)
        assert.equal(c.crc, crc32(Buffer.from(FILES[c.name] as string)))
    }
    assert.equal(zip.readUInt16LE(4), 20)
    assert.equal(zip.readUInt16LE(28), 0, "no extra field in a local header")
    assert.equal(p.eocd.count, ORDER.length)
})

test(
    "the entry count at its limit: zip64 end records, 0xFFFF in the classic one",
    async () => {
        const zip = await make({ ...ZIP_LIMITS, entries: ORDER.length })
        const p = parse(zip)
        assert.equal(p.eocd.count, 0xffff)
        assert.equal(p.z64?.count, ORDER.length)
        assert.ok(p.locator)
        // the other fields of the classic record stay as they are
        assert.equal(p.eocd.offset, p.z64?.offset)
        assert.equal(p.eocd.size, p.z64?.size)
        for (const c of p.central) assert.equal(c.extra.length, 0)
    },
)

test(
    "a size at its limit: zip64 extra in the local and central headers, version 45",
    async () => {
        const zip = await make({ ...ZIP_LIMITS, size: 20 })
        const p = parse(zip)
        const big = p.central.find((c) => c.name === "docProps/app.xml")
        assert.ok(big)
        assert.equal(big.usize, 0xffffffff)
        assert.equal(big.csize, 0xffffffff)
        assert.equal(big.version, 45)
        assert.deepEqual(values(big.extra), [20, 20], "uncompressed size, then compressed")
        // its local header: the same two sizes, the extra field after the name
        const at = big.offset
        assert.equal(zip.readUInt32LE(at), 0x04034b50)
        assert.equal(zip.readUInt16LE(at + 4), 45)
        assert.equal(zip.readUInt16LE(at + 6) & 0x8, 0, "no data descriptor")
        assert.equal(zip.readUInt32LE(at + 18), 0xffffffff)
        assert.equal(zip.readUInt32LE(at + 22), 0xffffffff)
        const nameLength = zip.readUInt16LE(at + 26)
        assert.equal(zip.readUInt16LE(at + 28), 20)
        assert.deepEqual(values(zip.subarray(at + 30 + nameLength, at + 50 + nameLength)), [20, 20])
        // the others stay classic
        for (const c of p.central.filter((c) => c !== big)) {
            assert.equal(c.version, 20)
            assert.equal(c.extra.length, 0)
        }
        assert.equal(p.z64, undefined, "nothing else overflowed")
    },
)

test(
    "an entry offset at its limit: the offset in the central extra field only",
    async () => {
        // the second entry starts at `first` + its data
        const limit = first() + (FILES[ORDER[0] as string] as string).length
        const zip = await make({ ...ZIP_LIMITS, offset: limit })
        const p = parse(zip)
        const [a, ...rest] = p.central
        assert.ok(a)
        assert.equal(a.extra.length, 0)
        assert.equal(a.version, 20)
        for (const c of rest) {
            assert.equal(c.offset, 0xffffffff)
            assert.equal(c.version, 45)
            assert.equal(c.usize, (FILES[c.name] as string).length, "sizes stay in 32 bits")
            assert.equal(values(c.extra).length, 1)
        }
        // the values are the places of the local headers, in order
        const places = rest.map((c) => values(c.extra)[0] as number)
        assert.deepEqual(places, [...places].sort((x, y) => x - y))
        for (const [i, c] of rest.entries()) {
            const at = places[i] as number
            assert.equal(zip.readUInt32LE(at), 0x04034b50)
            assert.equal(zip.subarray(at + 30, at + 30 + Buffer.byteLength(c.name)).toString(), c.name)
        }
        // the directory is past the limit too
        assert.ok(p.z64)
        assert.equal(p.eocd.offset, 0xffffffff)
    },
)

test(
    "only the central directory offset at its limit: the entries stay classic",
    async () => {
        const classic = parse(await make(ZIP_LIMITS))
        const data = classic.eocd.offset
        const zip = await make({ ...ZIP_LIMITS, offset: data })
        const p = parse(zip)
        for (const c of p.central) {
            assert.equal(c.extra.length, 0)
            assert.equal(c.version, 20)
        }
        assert.equal(p.eocd.offset, 0xffffffff)
        assert.equal(p.eocd.count, ORDER.length)
        assert.equal(p.z64?.offset, data)
        assert.deepEqual(localNames(zip), ORDER)
    },
)

test(
    "the central directory size at its limit: zip64 end records, 0xFFFFFFFF size",
    async () => {
        const zip = await make({ ...ZIP_LIMITS, directory: 1 })
        const p = parse(zip)
        assert.equal(p.eocd.size, 0xffffffff)
        assert.ok(p.z64 && p.z64.size > 0)
        assert.notEqual(p.eocd.offset, 0xffffffff)
    },
)

test(
    "sizes and offsets together: the extra field holds sizes first, then the offset",
    async () => {
        const zip = await make({ entries: 2, size: 20, offset: first() + 1, directory: 1 })
        const p = parse(zip)
        const big = p.central.find((c) => c.name === "docProps/app.xml")
        assert.ok(big)
        assert.equal(big.extra.readUInt16LE(2), 24)
        const [usize, csize, offset] = values(big.extra)
        assert.equal(usize, 20)
        assert.equal(csize, 20)
        assert.equal(zip.readUInt32LE(offset as number), 0x04034b50)
        assert.equal(p.eocd.count, 0xffff)
    },
)

test("a zip that cannot be written leaves nothing behind", async () => {
    const folder = tempDir()
    const out = join(tempDir(), "bad.zip")
    assert.throws(() => writeStoredZipSync(folder, ["missing"], out))
    await assert.rejects(writeStoredZipAsync(folder, ["missing"], out))
    assert.throws(() => readFileSync(out))
})
