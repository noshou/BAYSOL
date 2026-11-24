// SPDX-License-Identifier: LGPL-3.0-or-later

// SPDX-License-Identifier: LGPL-3.0-or-later

// ========================================================================================
// zip-writer.ts: a zip of stored (uncompressed) files, in the order given
// ========================================================================================
//
// 7-Zip sorts the entries of a zip by name (without regard to case on Windows, so
// `docProps` lands before `[Content_Types].xml`), whatever the order it is given, and an
// Office file wants `[Content_Types].xml` first. The workbooks the program rebuilds are
// therefore zipped here, by one code path on every OS.
//
// The zip is written to the file entry by entry, a megabyte at a time (a file is read
// twice: once for its CRC, which the local header holds ahead of the data, since no data
// descriptor is used, and once to copy it), so the size of the files and their number
// are not limited by memory. A classic zip is written while every value fits the 32-bit
// fields; from the limits the zip64 structures are added (APPNOTE 4.5.3 and 4.3.14 to
// 4.3.16), and below them the bytes are those of a classic zip.

import { closeSync, fstatSync, openSync, readSync, rmSync, writeSync } from "node:fs"
import { open as openAsync } from "node:fs/promises"
import { join } from "node:path"
import { crc32 } from "node:zlib"

/**
 * The values from which a field is written in zip64 (a value equal to the limit is
 * already the marker of the classic format).
 *
 * @property entries - the number of entries (0xFFFF).
 * @property size - the size of a file (0xFFFFFFFF).
 * @property offset - where an entry, or the central directory, starts (0xFFFFFFFF).
 * @property directory - the size of the central directory (0xFFFFFFFF).
 */
export type ZipLimits = {
    readonly entries: number
    readonly size: number
    readonly offset: number
    readonly directory: number
}

/** The limits of the classic format (the tests lower them to reach the zip64 paths). */
export const ZIP_LIMITS: ZipLimits = {
    entries: 0xffff,
    size: 0xffffffff,
    offset: 0xffffffff,
    directory: 0xffffffff,
}

const CHUNK = 1 << 20
const MARK16 = 0xffff
const MARK32 = 0xffffffff

/** The local time of a file as the date and time words of a zip entry. */
function dosTime(t: Date): { time: number; date: number } {
    const year = Math.min(Math.max(t.getFullYear(), 1980), 2107)
    return {
        time: (t.getHours() << 11) | (t.getMinutes() << 5) | (t.getSeconds() >> 1),
        date: ((year - 1980) << 9) | ((t.getMonth() + 1) << 5) | t.getDate(),
    }
}

/** The zip64 extended information extra field: the 64-bit values, in the order given. */
function zip64Extra(values: readonly number[]): Buffer {
    const extra = Buffer.alloc(4 + 8 * values.length)
    extra.writeUInt16LE(0x0001, 0)
    extra.writeUInt16LE(8 * values.length, 2)
    values.forEach((v, i) => {
        extra.writeBigUInt64LE(BigInt(v), 4 + 8 * i)
    })
    return extra
}

/** A four-byte little-endian signature. */
function signature(value: number): Buffer {
    const b = Buffer.alloc(4)
    b.writeUInt32LE(value, 0)
    return b
}

/**
 * The headers of a zip, made as the entries are given (no input or output): `entry`
 * returns the bytes to write ahead of a file's data, and `finish` those to write after
 * the last file.
 */
class ZipHeaders {
    /** Where the next entry starts. */
    offset = 0
    private readonly central: Buffer[] = []

    constructor(private readonly limits: ZipLimits = ZIP_LIMITS) {}

    /** The local file header of a stored file (its data follows, `size` bytes). */
    entry(name: string, size: number, crc: number, time: Date): Buffer {
        const nameBytes = Buffer.from(name, "utf-8")
        if (nameBytes.length > MARK16) {
            throw new RangeError(`name too long for a zip: ${name}`)
        }
        const { time: t, date: d } = dosTime(time)
        const bigSize = size >= this.limits.size
        const bigOffset = this.offset >= this.limits.offset
        const stamp = (version: number, extraLength: number): Buffer => {
            const b = Buffer.alloc(26)
            b.writeUInt16LE(version, 0) // version needed
            b.writeUInt16LE(0x800, 2) // names are UTF-8, no data descriptor
            b.writeUInt16LE(0, 4) // stored
            b.writeUInt16LE(t, 6)
            b.writeUInt16LE(d, 8)
            b.writeUInt32LE(crc, 10)
            b.writeUInt32LE(bigSize ? MARK32 : size, 14)
            b.writeUInt32LE(bigSize ? MARK32 : size, 18)
            b.writeUInt16LE(nameBytes.length, 22)
            b.writeUInt16LE(extraLength, 24)
            return b
        }
        // the local header holds both sizes whenever it holds the field at all
        const localExtra = bigSize ? zip64Extra([size, size]) : Buffer.alloc(0)
        const local = Buffer.concat([
            signature(0x04034b50),
            stamp(bigSize ? 45 : 20, localExtra.length),
            nameBytes,
            localExtra,
        ])
        // the central one holds the fields that overflowed: the sizes, then the offset
        const overflowed = [
            ...(bigSize ? [size, size] : []),
            ...(bigOffset ? [this.offset] : []),
        ]
        const centralExtra =
            bigSize || bigOffset ? zip64Extra(overflowed) : Buffer.alloc(0)
        const version = centralExtra.length > 0 ? 45 : 20
        const tail = Buffer.alloc(14) // comment, disk, attributes: none
        tail.writeUInt32LE(bigOffset ? MARK32 : this.offset, 10)
        const madeBy = Buffer.alloc(2)
        madeBy.writeUInt16LE(version, 0)
        this.central.push(
            Buffer.concat([
                signature(0x02014b50),
                madeBy,
                stamp(version, centralExtra.length),
                tail,
                nameBytes,
                centralExtra,
            ]),
        )
        this.offset += local.length + size
        return local
    }

    /** The central directory and the end records, to write after the last file's data. */
    finish(): Buffer[] {
        const count = this.central.length
        const directoryOffset = this.offset
        const directorySize = this.central.reduce((n, b) => n + b.length, 0)
        const bigCount = count >= this.limits.entries
        const bigOffset = directoryOffset >= this.limits.offset
        const bigSize = directorySize >= this.limits.directory
        const out = [...this.central]
        if (bigCount || bigOffset || bigSize) {
            const record = Buffer.alloc(56)
            record.writeUInt32LE(0x06064b50, 0)
            record.writeBigUInt64LE(44n, 4) // the rest of the record
            record.writeUInt16LE(45, 12) // made by
            record.writeUInt16LE(45, 14) // version needed
            record.writeBigUInt64LE(BigInt(count), 24) // entries on this disk
            record.writeBigUInt64LE(BigInt(count), 32) // entries
            record.writeBigUInt64LE(BigInt(directorySize), 40)
            record.writeBigUInt64LE(BigInt(directoryOffset), 48)
            const locator = Buffer.alloc(20)
            locator.writeUInt32LE(0x07064b50, 0)
            locator.writeBigUInt64LE(BigInt(directoryOffset + directorySize), 8)
            locator.writeUInt32LE(1, 16) // disks
            out.push(record, locator)
        }
        const end = Buffer.alloc(22)
        end.writeUInt32LE(0x06054b50, 0)
        end.writeUInt16LE(bigCount ? MARK16 : count, 8)
        end.writeUInt16LE(bigCount ? MARK16 : count, 10)
        end.writeUInt32LE(bigSize ? MARK32 : directorySize, 12)
        end.writeUInt32LE(bigOffset ? MARK32 : directoryOffset, 16)
        out.push(end)
        return out
    }
}

/**
 * Writes a stored zip of the files of a folder, in the order given.
 *
 * @param out - the zip's path, which must not exist; a zip that fails is removed.
 * @param limits - the thresholds of zip64 (the tests lower them).
 */
export function writeStoredZipSync(
    folder: string,
    files: readonly string[],
    out: string,
    limits: ZipLimits = ZIP_LIMITS,
): void {
    const fd = openSync(out, "wx")
    try {
        const headers = new ZipHeaders(limits)
        const buffer = Buffer.alloc(CHUNK)
        const put = (b: Buffer): void => {
            for (let at = 0; at < b.length; ) at += writeSync(fd, b, at, b.length - at)
        }
        for (const name of files) {
            const input = openSync(join(folder, name), "r")
            try {
                const { size, mtime } = fstatSync(input)
                const pass = (each: (chunk: Buffer) => void): void => {
                    for (let pos = 0; pos < size; ) {
                        const want = Math.min(CHUNK, size - pos)
                        const n = readSync(input, buffer, 0, want, pos)
                        if (n === 0) throw new Error(`${name} changed while it was zipped`)
                        each(buffer.subarray(0, n))
                        pos += n
                    }
                }
                let crc = 0
                pass((chunk) => {
                    crc = crc32(chunk, crc)
                })
                put(headers.entry(name, size, crc, mtime))
                pass(put)
            } finally {
                closeSync(input)
            }
        }
        for (const b of headers.finish()) put(b)
    } catch (error) {
        closeSync(fd)
        rmSync(out, { force: true })
        throw error
    }
    closeSync(fd)
}

/** [[writeStoredZipSync]] without blocking. */
export async function writeStoredZipAsync(
    folder: string,
    files: readonly string[],
    out: string,
    limits: ZipLimits = ZIP_LIMITS,
): Promise<void> {
    const sink = await openAsync(out, "wx")
    try {
        const headers = new ZipHeaders(limits)
        const buffer = Buffer.alloc(CHUNK)
        const put = async (b: Buffer): Promise<void> => {
            for (let at = 0; at < b.length; )
                at += (await sink.write(b, at, b.length - at)).bytesWritten
        }
        for (const name of files) {
            const input = await openAsync(join(folder, name), "r")
            try {
                const { size, mtime } = await input.stat()
                const pass = async (
                    each: (chunk: Buffer) => void | Promise<void>,
                ): Promise<void> => {
                    for (let pos = 0; pos < size; ) {
                        const { bytesRead: n } = await input.read(
                            buffer,
                            0,
                            Math.min(CHUNK, size - pos),
                            pos,
                        )
                        if (n === 0) throw new Error(`${name} changed while it was zipped`)
                        await each(buffer.subarray(0, n))
                        pos += n
                    }
                }
                let crc = 0
                await pass((chunk) => {
                    crc = crc32(chunk, crc)
                })
                await put(headers.entry(name, size, crc, mtime))
                await pass(put)
            } finally {
                await input.close()
            }
        }
        for (const b of headers.finish()) await put(b)
    } catch (error) {
        await sink.close()
        rmSync(out, { force: true })
        throw error
    }
    await sink.close()
}
