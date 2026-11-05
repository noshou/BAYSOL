// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { mkdirSync, mkdtempSync, readFileSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { test } from "node:test"
import type { System } from "../src/core/system.js"
import {
    defaultFontDirs,
    fingerprint,
    fontFiles,
    isFontFile,
    loadFonts,
    parseRegistryFonts,
    readFaces,
    scanFonts,
    texInstalled,
} from "../src/system/fonts.js"

const tmp = (): string => mkdtempSync(join(tmpdir(), "baysol-test-"))

// --- building font files, byte by byte

const u16 = (n: number): Buffer => Buffer.from([(n >> 8) & 255, n & 255])
const u32 = (n: number): Buffer =>
    Buffer.from([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255])
const ascii = (s: string): Buffer => Buffer.from(s, "latin1")

type NameRecord = { platform: number; language: number; id: number; bytes: Buffer }

/** A name record; Windows and Unicode strings are UTF-16BE, Macintosh ones Latin-1. */
function nameRecord(
    platform: number,
    language: number,
    id: number,
    text: string,
): NameRecord {
    const bytes = platform === 1 ? ascii(text) : Buffer.from(text, "utf16le").swap16()
    return { platform, language, id, bytes }
}

const english = (family: string): NameRecord[] => [nameRecord(3, 0x409, 1, family)]

function nameTable(records: NameRecord[]): Buffer {
    let offset = 0
    const entries = records.map((r) => {
        const e = Buffer.concat([
            u16(r.platform),
            u16(1),
            u16(r.language),
            u16(r.id),
            u16(r.bytes.length),
            u16(offset),
        ])
        offset += r.bytes.length
        return e
    })
    return Buffer.concat([
        u16(0),
        u16(records.length),
        u16(6 + 12 * records.length),
        ...entries,
        ...records.map((r) => r.bytes),
    ])
}

/** One face: a header and tables whose offsets count from `base`. */
function sfnt(version: Buffer, tables: [string, Buffer][], base: number): Buffer {
    const pad = (n: number): number => 4 * Math.ceil(n / 4)
    let at = base + 12 + 16 * tables.length
    const records = tables.map(([tag, data]) => {
        const r = Buffer.concat([ascii(tag), u32(0), u32(at), u32(data.length)])
        at += pad(data.length)
        return r
    })
    const bodies = tables.map(([, data]) =>
        Buffer.concat([data, Buffer.alloc(pad(data.length) - data.length)]),
    )
    return Buffer.concat([
        version,
        u16(tables.length),
        u16(0),
        u16(0),
        u16(0),
        ...records,
        ...bodies,
    ])
}

const ttf = Buffer.from([0, 1, 0, 0])
const otf = ascii("OTTO")

type Spec = { version?: Buffer; names?: NameRecord[]; math?: boolean }

const tablesOf = (spec: Spec): [string, Buffer][] => [
    ["head", Buffer.alloc(8, 1)],
    ...(spec.names ? ([["name", nameTable(spec.names)]] as [string, Buffer][]) : []),
    ...(spec.math ? ([["MATH", Buffer.alloc(12)]] as [string, Buffer][]) : []),
]

const fontBytes = (spec: Spec): Buffer => sfnt(spec.version ?? ttf, tablesOf(spec), 0)

function ttcBytes(specs: Spec[]): Buffer {
    const header = 12 + 4 * specs.length
    const starts: number[] = []
    let at = header
    for (const s of specs) {
        starts.push(at)
        at += sfnt(s.version ?? ttf, tablesOf(s), 0).length
    }
    return Buffer.concat([
        ascii("ttcf"),
        u32(0x10000),
        u32(specs.length),
        ...starts.map((start) => u32(start)),
        ...specs.map((s, k) => sfnt(s.version ?? ttf, tablesOf(s), starts[k] ?? 0)),
    ])
}

function write(dir: string, name: string, content: Buffer | string): string {
    const file = join(dir, name)
    mkdirSync(dirname(file), { recursive: true })
    writeFileSync(file, content)
    return file
}

// --- reading a font file

test("a TrueType or OpenType face is read, with or without a MATH table", () => {
    const dir = tmp()
    assert.deepEqual(
        readFaces(write(dir, "a.ttf", fontBytes({ names: english("Plain Text") }))),
        [{ family: "Plain Text", math: false }],
    )
    assert.deepEqual(
        readFaces(
            write(
                dir,
                "b.otf",
                fontBytes({ version: otf, names: english("Fancy Math"), math: true }),
            ),
        ),
        [{ family: "Fancy Math", math: true }],
    )
    assert.equal(
        readFaces(
            write(
                dir,
                "c.ttf",
                fontBytes({ version: ascii("true"), names: english("Old Mac") }),
            ),
        )[0]?.family,
        "Old Mac",
    )
})

test("only the MATH table makes a math font, never the name", () => {
    const dir = tmp()
    const fake = write(
        dir,
        "fake.otf",
        fontBytes({ version: otf, names: english("Mathematica Fake") }),
    )
    assert.equal(readFaces(fake)[0]?.math, false)
})

test("a collection gives each face its own table directory", () => {
    const dir = tmp()
    const file = write(
        dir,
        "c.ttc",
        ttcBytes([
            { names: english("Coll Text") },
            { names: english("Coll Math"), math: true },
            { names: english("Coll Third") },
        ]),
    )
    assert.deepEqual(readFaces(file), [
        { family: "Coll Text", math: false },
        { family: "Coll Math", math: true },
        { family: "Coll Third", math: false },
    ])
})

test("name choice: typographic, English first, other languages, Mac, Unicode", () => {
    const dir = tmp()
    const family = (names: NameRecord[]): string | undefined =>
        readFaces(write(dir, "x.otf", fontBytes({ names })))[0]?.family
    assert.equal(
        family([
            nameRecord(3, 0x409, 1, "Libre Franklin Medium"),
            nameRecord(3, 0x409, 16, "Libre Franklin"),
        ]),
        "Libre Franklin",
    )
    assert.equal(
        family([
            nameRecord(3, 0x407, 1, "Deutscher Name"),
            nameRecord(3, 0x409, 1, "English Name"),
        ]),
        "English Name",
    )
    assert.equal(family([nameRecord(3, 0x407, 1, "Nur Deutsch")]), "Nur Deutsch")
    assert.equal(family([nameRecord(1, 0, 1, "Mac Family")]), "Mac Family")
    assert.equal(family(english("Ünïcode Fönt δρ")), "Ünïcode Fönt δρ")
})

test("a face with no usable family name is left out", () => {
    const dir = tmp()
    assert.deepEqual(readFaces(write(dir, "n1.ttf", fontBytes({}))), [])
    assert.deepEqual(
        readFaces(
            write(dir, "n2.ttf", fontBytes({ names: [nameRecord(3, 0x409, 2, "Bold")] })),
        ),
        [],
    )
    assert.deepEqual(
        readFaces(write(dir, "n3.ttf", fontBytes({ names: english("   ") }))),
        [],
    )
})

test("files that are not fonts, or are damaged, have no faces and never throw", () => {
    const dir = tmp()
    const good = fontBytes({ names: english("Good Font"), math: true })
    const cases: [string, Buffer][] = [
        ["empty", Buffer.alloc(0)],
        ["three bytes", Buffer.from([1, 2, 3])],
        ["text", ascii("this is not a font at all, just text")],
        ["woff", Buffer.concat([ascii("wOFF"), Buffer.alloc(100)])],
        ["type 1", ascii("%!PS-AdobeFont-1.0: Foo")],
        ["no tables", Buffer.concat([ttf, u16(0), Buffer.alloc(20)])],
        ["too many tables", Buffer.concat([ttf, u16(60000), Buffer.alloc(20)])],
        ["directory cut short", Buffer.concat([ttf, u16(10), Buffer.alloc(20)])],
        ["header only", good.subarray(0, 12)],
        ["half a font", good.subarray(0, good.length >> 1)],
        ["collection of none", Buffer.concat([ascii("ttcf"), u32(0x10000), u32(0)])],
        [
            "collection offsets outside",
            Buffer.concat([ascii("ttcf"), u32(0x10000), u32(2), u32(9999), u32(99999)]),
        ],
        [
            "collection of a million",
            Buffer.concat([ascii("ttcf"), u32(0x10000), u32(1000000), Buffer.alloc(64)]),
        ],
        ["collection cut short", Buffer.concat([ascii("ttcf"), u32(0x10000)])],
        [
            "name table past the end",
            sfnt(
                ttf,
                [
                    [
                        "name",
                        Buffer.concat([
                            u16(0),
                            u16(1),
                            u16(6000),
                            u16(3),
                            u16(1),
                            u16(0x409),
                            u16(1),
                            u16(20),
                            u16(0),
                        ]),
                    ],
                ],
                0,
            ),
        ],
        [
            "a million name records",
            sfnt(ttf, [["name", Buffer.concat([u16(0), u16(60000), u16(6)])]], 0),
        ],
        ["name table too short", sfnt(ttf, [["name", Buffer.from([0, 0])]], 0)],
    ]
    for (const [k, [what, content]] of cases.entries())
        assert.deepEqual(readFaces(write(dir, `f${k}.ttf`, content)), [], what)
    assert.deepEqual(readFaces(join(dir, "no-such-file.ttf")), [])
    assert.deepEqual(readFaces(dir), [])
})

test("reading randomly damaged fonts never fails and gives well-formed faces", () => {
    const dir = tmp()
    const sources = [
        fontBytes({ version: otf, names: english("Fuzz Font"), math: true }),
        ttcBytes([{ names: english("A One") }, { names: english("B Two"), math: true }]),
    ]
    let seed = 20261101
    const next = (n: number): number => {
        seed = (Math.imul(seed, 1103515245) + 12345) >>> 0
        return (seed >>> 8) % n
    }
    for (let n = 0; n < 500; n++) {
        let bytes = Buffer.from(sources[n % 2] ?? Buffer.alloc(0))
        for (let k = 0, edits = 1 + next(6); k < edits && bytes.length > 0; k++) {
            const i = next(bytes.length)
            const kind = next(3)
            if (kind === 0) bytes[i] = next(256)
            else if (kind === 1)
                bytes = Buffer.concat([bytes.subarray(0, i), bytes.subarray(i + 1)])
            else bytes = bytes.subarray(0, i)
        }
        for (const face of readFaces(write(dir, "fuzz.bin", bytes))) {
            assert.ok(face.family.trim() !== "")
            assert.equal(typeof face.math, "boolean")
        }
    }
})

// --- sorting, fingerprint, cache

test("fonts are sorted into math and text, by case-blind order, a family once", () => {
    const dir = tmp()
    const files = [
        write(dir, "a.otf", fontBytes({ version: otf, names: english("Alpha Text") })),
        write(
            dir,
            "b.otf",
            fontBytes({ version: otf, names: english("beta Math"), math: true }),
        ),
        write(dir, "c.otf", fontBytes({ version: otf, names: english("Gamma Text") })),
        write(dir, "d.otf", fontBytes({ version: otf, names: english("Alpha Text") })),
        write(
            dir,
            "e.ttc",
            ttcBytes([
                { names: english("Mixed") },
                { names: english("Mixed"), math: true },
            ]),
        ),
        write(dir, "junk.ttf", "not a font"),
    ]
    assert.deepEqual(scanFonts(files), {
        math: ["beta Math", "Mixed"],
        text: ["Alpha Text", "Gamma Text"],
    })
    assert.deepEqual(scanFonts([]), { math: [], text: [] })
})

test("the fingerprint follows the files", () => {
    const dir = tmp()
    const a = write(dir, "a.ttf", fontBytes({ names: english("A Font") }))
    const b = write(dir, "b.ttf", fontBytes({ names: english("B Font") }))
    const before = fingerprint([a, b])
    assert.equal(before, fingerprint([b, a]))
    assert.notEqual(before, fingerprint([a]))
    assert.notEqual(
        before,
        fingerprint([a, b, write(dir, "c.ttf", Buffer.from([1, 2, 3]))]),
    )
    write(dir, "b.ttf", fontBytes({ names: english("B Font Longer Name") }))
    const replaced = fingerprint([a, b])
    assert.notEqual(before, replaced)
    utimesSync(b, new Date(), new Date(Date.now() + 5000))
    assert.notEqual(replaced, fingerprint([a, b]))
})

test("the cache is used while the fonts are the same and mended when damaged", () => {
    const dir = tmp()
    const cache = join(dir, "cache", "fonts.json")
    const a = write(
        dir,
        "fonts/a.otf",
        fontBytes({ version: otf, names: english("Alpha") }),
    )
    const b = write(
        dir,
        "fonts/b.otf",
        fontBytes({ version: otf, names: english("Beta Math"), math: true }),
    )
    assert.deepEqual(loadFonts(cache, [a, b]), { math: ["Beta Math"], text: ["Alpha"] })
    assert.deepEqual(JSON.parse(readFileSync(cache, "utf8")).math, ["Beta Math"])
    // the cache wins while the fingerprint is the same: plant a marker and see it come back
    const planted = { ...JSON.parse(readFileSync(cache, "utf8")), text: ["From Cache"] }
    writeFileSync(cache, JSON.stringify(planted))
    assert.deepEqual(loadFonts(cache, [a, b]).text, ["From Cache"])
    // a font installed changes the fingerprint: scanned again, the cache rewritten
    const c = write(
        dir,
        "fonts/c.otf",
        fontBytes({ version: otf, names: english("Gamma") }),
    )
    assert.deepEqual(loadFonts(cache, [a, b, c]).text, ["Alpha", "Gamma"])
    assert.deepEqual(JSON.parse(readFileSync(cache, "utf8")).text, ["Alpha", "Gamma"])
    for (const bad of [
        "{ not json",
        "",
        "[1,2]",
        '{"fingerprint":"x"}',
        '{"fingerprint":"x","math":5,"text":6}',
        "null",
    ]) {
        writeFileSync(cache, bad)
        assert.deepEqual(loadFonts(cache, [a]).text, ["Alpha"], bad)
        assert.deepEqual(JSON.parse(readFileSync(cache, "utf8")).text, ["Alpha"], bad)
    }
    // a cache that cannot be written does not stop the fonts being read
    const blocked = join(write(dir, "a-file", "x"), "fonts.json")
    assert.deepEqual(loadFonts(blocked, [a, b]).math, ["Beta Math"])
})

// --- finding the files

const system = (
    os: NodeJS.Platform,
    env: Record<string, string>,
    home = "/home/u",
): System => ({
    os,
    env,
    home,
    cwd: "/work",
})

test("the font folders of each system are the ones that exist", () => {
    const home = tmp()
    for (const d of [".local/share/fonts", ".fonts", "Library/Fonts", "Fonts"])
        mkdirSync(join(home, d), { recursive: true })
    const linux = defaultFontDirs(system("linux", {}, home))
    assert.ok(linux.includes(join(home, ".local", "share", "fonts")))
    assert.ok(linux.includes(join(home, ".fonts")))
    assert.ok(!linux.some((d) => d.includes("Library")))
    const mac = defaultFontDirs(system("darwin", {}, home))
    assert.ok(mac.includes(join(home, "Library", "Fonts")))
    assert.ok(!mac.some((d) => d.includes(".fonts")))
    const windows = defaultFontDirs(
        system("win32", { WINDIR: home, LOCALAPPDATA: home }, home),
    )
    assert.ok(windows.includes(join(home, "Fonts")))
})

test("what is named like a font file", () => {
    for (const p of [
        "a.ttf",
        "a.OTF",
        "x/y/Z.ttc",
        "b.otc",
        "dir.with.dots/c.TTF",
        "C:\\Windows\\Fonts\\arial.ttf",
    ])
        assert.ok(isFontFile(p), p)
    for (const p of [
        "a.pfb",
        "a.t1",
        "a.woff",
        "a.woff2",
        "a.txt",
        "ttf",
        "a.ttf.bak",
        "a",
        "",
        "x.otf/readme",
    ])
        assert.ok(!isFontFile(p), p)
})

test("the font files of the folders are gathered once each, other kinds left out", () => {
    const home = tmp()
    const a = write(
        home,
        ".fonts/one.otf",
        fontBytes({ version: otf, names: english("One") }),
    )
    const b = write(
        home,
        ".local/share/fonts/sub/two.ttf",
        fontBytes({ names: english("Two") }),
    )
    write(home, ".fonts/readme.txt", "no")
    write(home, ".fonts/old.pfb", "no")
    // PATH is empty: no fc-list, no TeX; the walk of the folders is all there is
    const found = fontFiles(system("linux", { PATH: "" }, home))
    assert.ok(found.includes(a))
    assert.ok(found.includes(b))
    assert.ok(!found.some((f) => f.endsWith(".txt") || f.endsWith(".pfb")))
    assert.equal(found.length, new Set(found).size)
})

test("the registry of Windows names the font files", () => {
    const mine = "C:\\Users\\me\\AppData\\Local\\Microsoft\\Windows\\Fonts\\mine.otf"
    const output = [
        "",
        "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
        "    Arial (TrueType)    REG_SZ    arial.ttf",
        "    Cambria & Cambria Math (TrueType)    REG_SZ    cambria.ttc",
        "    Segoe UI Variable (TrueType)    REG_SZ    SegUIVar.ttf",
        `    Mine (TrueType)    REG_SZ    ${mine}`,
        "    Network (TrueType)    REG_SZ    \\\\server\\share\\net.ttf",
        "    Old (Type 1)    REG_SZ    old.pfb",
        "    Count    REG_DWORD    0x00000003",
        "    Empty (TrueType)    REG_SZ    ",
        "",
    ].join("\r\n")
    const parsed = parseRegistryFonts(output, "C:\\Windows\\Fonts")
    assert.equal(parsed.length, 5)
    assert.ok(
        parsed.some((p) => p.endsWith("arial.ttf") && p.startsWith("C:\\Windows\\Fonts")),
    )
    assert.ok(parsed.includes(mine))
    assert.ok(parsed.includes("\\\\server\\share\\net.ttf"))
    assert.ok(!parsed.some((p) => p.includes("old.pfb") || p.includes("0x")))
    assert.deepEqual(parseRegistryFonts(undefined, "C:\\F"), [])
    assert.deepEqual(
        parseRegistryFonts("ERROR: The system cannot find the key", "C:\\F"),
        [],
    )
})

test("TeX is found on the path", () => {
    const bin = tmp()
    writeFileSync(join(bin, "kpsewhich"), "#!/bin/sh\n", { mode: 0o755 })
    assert.equal(texInstalled(system("linux", { PATH: bin })), true)
    assert.equal(texInstalled(system("linux", { PATH: tmp() })), false)
    assert.equal(texInstalled(system("linux", {})), false)
})
