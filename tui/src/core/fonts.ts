// SPDX-License-Identifier: LGPL-3.0-or-later

import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
    closeSync,
    type Dirent,
    fstatSync,
    openSync,
    readdirSync,
    readFileSync,
    readSync,
    statSync,
} from "node:fs"
import { join } from "node:path"
import { writeAtomic } from "./files.js"
import { findExecutable, isMac, isWindows, type System } from "./system.js"

/**
 * The fonts installed on this machine, sorted into math fonts and text fonts by what
 * the font files themselves say: a font is a math font when it has an OpenType `MATH`
 * table, which is what `unicode-math` (and so LuaLaTeX) needs for a math font. Nothing
 * is guessed from a name.
 *
 * The font files are the ones the user has installed and, if a TeX installation is
 * found, those of TeX too, joined without repeats:
 * - The system's font folders (`/usr/share/fonts`, `~/.local/share/fonts`,
 *   `/Library/Fonts`, `C:\Windows\Fonts` ...), walked: this needs no program, so it
 *   works on Linux, macOS and Windows alike. The files fontconfig reports (`fc-list`)
 *   are added when that is installed, and on Windows the files the registry lists
 *   (`reg query`).
 * - With TeX (`kpsewhich` or `luaotfload-tool` on the path): the files the LuaLaTeX font
 *   database lists, which include the fonts of TeX's own `texmf` trees. With no such
 *   database the OpenType and TrueType fonts of the `texmf` trees are walked instead.
 *
 * Each file's header is read for its faces (a `.ttc` or `.otc` holds several), each
 * face's family name from its `name` table, and its table directory for `MATH`. Type 1
 * fonts and anything that is not an OpenType or TrueType file are left out. The result
 * is cached in `fonts.json` with a fingerprint of the files (paths, sizes, times), so a
 * font installed or removed later makes the scan run again.
 *
 * The macOS and Windows locations and the `reg query` parsing come from documentation
 * and have not been run on those systems.
 */

/** The file extensions (lower case) of the font files that are read. */
const fontExtensions = new Set([".otf", ".ttf", ".ttc", ".otc"])

/** The name of the cache file inside the cache folder. */
const cacheFileName = "fonts.json"

/** Limit: tables in one face, so a corrupt header cannot make the scan read without end. */
const maxTables = 512

/** Limit: faces in one collection. */
const maxFaces = 256

/** Limit: bytes of a `name` table that are read. */
const maxNameTable = 4194304

/** Limit: records in a `name` table. */
const maxNameRecords = 20000

/** Limit: how deep a font folder is walked (a symbolic link loop ends here). */
const maxWalkDepth = 32

/** Size in bytes of the header of a face (`sfntVersion`, `numTables`, three more). */
const sfntHeaderSize = 12

/** Size in bytes of one record of the table directory (tag, checksum, offset, length). */
const tableRecordSize = 16

/** Size in bytes of the header of a `name` table (format, count, string offset). */
const nameHeaderSize = 6

/**
 * Size in bytes of one `name` record (platform, encoding, language, id, length, offset).
 */
const nameRecordSize = 12

/** The `name` ids that hold a family: the typographic family, and the plain family. */
const typographicFamilyId = 16
const familyId = 1

/** The platform ids of the `name` table. */
const platformUnicode = 0
const platformMacintosh = 1
const platformWindows = 3

/** The Windows language id of US English, and the Macintosh one of English. */
const windowsEnglish = 0x409
const macEnglish = 0

/** A name record with a rank this high or more is not used (a language-less oddity). */
const rankUnusable = 9

/** The kpathsea variables that name the `texmf` trees of a TeX installation. */
const texmfVariables = [
    "TEXMFDIST",
    "TEXMFLOCAL",
    "TEXMFHOME",
    "TEXMFMAIN",
    "TEXMFSYSVAR",
    "TEXMFVAR",
]

/** The registry hives whose `Fonts` key lists installed fonts (machine, user). */
const registryHives = ["HKLM", "HKCU"]

/** The registry key, below a hive, that lists the installed fonts. */
const registryFontsKey = "\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"

/**
 * One face of a font file.
 *
 * @property family - its family name (typographic family if it has one).
 * @property math - `true` if the face has an OpenType `MATH` table.
 */
export type Face = { family: string; math: boolean }

/**
 * The fonts of a machine.
 *
 * @property text - the families that are text fonts, sorted without regard to case.
 * @property math - the families with a face that has a `MATH` table, sorted the same.
 */
export type FontList = { text: string[]; math: string[] }

/** The cache file as written: a font list and the fingerprint of the files it is from. */
type FontCache = FontList & { fingerprint: string }

// --- reading a font file

/**
 * Reads `n` bytes of an open file.
 *
 * @param fd - the open file.
 * @param size - the size of the file.
 * @param pos - where to start.
 * @param n - how many bytes.
 * @returns the bytes, or `undefined` if that goes past the end of the file.
 */
function readBytes(fd: number, size: number, pos: number, n: number): Buffer | undefined {
    if (pos < 0 || n < 0 || pos + n > size) return undefined
    const bytes = Buffer.alloc(n)
    let done = 0
    while (done < n) {
        const got = readSync(fd, bytes, done, n - done, pos + done)
        if (got === 0) return undefined
        done += got
    }
    return bytes
}

/**
 * Decodes the string of a `name` record by the encoding its platform uses.
 *
 * @param bytes - the bytes of the string.
 * @param platform - the platform id: Macintosh is Mac Roman (Latin-1 if the runtime has
 *     no such decoder), Windows and Unicode are UTF-16 big-endian.
 * @returns the trimmed text.
 */
function decodeName(bytes: Buffer, platform: number): string {
    if (platform === platformMacintosh) {
        try {
            return new TextDecoder("macintosh").decode(bytes).trim()
        } catch {
            return bytes.toString("latin1").trim()
        }
    }
    const swapped = Buffer.from(bytes.subarray(0, bytes.length - (bytes.length % 2)))
    return swapped.swap16().toString("utf16le").trim()
}

/**
 * How wanted a name record is: an English Windows name, any Windows name, a Unicode
 * name, a Macintosh English name; anything else is not used.
 *
 * @param platform - the platform id.
 * @param language - the language id.
 * @returns a rank, the lower the better.
 */
function nameRank(platform: number, language: number): number {
    if (platform === platformWindows && language === windowsEnglish) return 0
    if (platform === platformWindows) return 1
    if (platform === platformUnicode) return 2
    if (platform === platformMacintosh && language === macEnglish) return 3
    return rankUnusable
}

/**
 * The family name in a `name` table: the typographic family (name 16) if the face has
 * one, else the family (name 1); an English one if there is one.
 *
 * @param table - the bytes of the `name` table.
 * @returns the family, or `undefined` if there is none or the table is damaged.
 */
function familyFromNameTable(table: Buffer): string | undefined {
    if (table.length < nameHeaderSize) return undefined
    const count = table.readUInt16BE(2)
    const strings = table.readUInt16BE(4)
    if (count > maxNameRecords || nameHeaderSize + count * nameRecordSize > table.length)
        return undefined
    const records: {
        id: number
        platform: number
        rank: number
        at: number
        len: number
    }[] = []
    for (let k = 0; k < count; k++) {
        const o = nameHeaderSize + k * nameRecordSize
        const id = table.readUInt16BE(o + 6)
        const len = table.readUInt16BE(o + 8)
        const at = strings + table.readUInt16BE(o + 10)
        if (
            (id === typographicFamilyId || id === familyId) &&
            len > 0 &&
            at + len <= table.length
        ) {
            const platform = table.readUInt16BE(o)
            records.push({
                id,
                platform,
                rank: nameRank(platform, table.readUInt16BE(o + 4)),
                at,
                len,
            })
        }
    }
    for (const id of [typographicFamilyId, familyId]) {
        const best = records
            .filter((r) => r.id === id && r.rank < rankUnusable)
            .sort((a, b) => a.rank - b.rank)[0]
        if (best) {
            const text = decodeName(
                table.subarray(best.at, best.at + best.len),
                best.platform,
            )
            if (text !== "") return text
        }
    }
    return undefined
}

/**
 * The table directory of the face whose header is at `offset` of a file.
 *
 * @param fd - the open file.
 * @param size - the size of the file.
 * @param offset - where the face starts.
 * @returns the tables as `tag -> [offset, length]`, or `undefined` if there is no
 *     TrueType or OpenType header there.
 */
function tableDirectory(
    fd: number,
    size: number,
    offset: number,
): Map<string, [number, number]> | undefined {
    const head = readBytes(fd, size, offset, sfntHeaderSize)
    if (!head) return undefined
    const version = head.toString("latin1", 0, 4)
    const n = head.readUInt16BE(4)
    const known =
        ["OTTO", "true", "typ1"].includes(version) || head.readUInt32BE(0) === 0x00010000
    if (!known || n < 1 || n > maxTables) return undefined
    const records = readBytes(fd, size, offset + sfntHeaderSize, n * tableRecordSize)
    if (!records) return undefined
    const tables = new Map<string, [number, number]>()
    for (let k = 0; k < n; k++) {
        const o = k * tableRecordSize
        tables.set(records.toString("latin1", o, o + 4), [
            records.readUInt32BE(o + 8),
            records.readUInt32BE(o + 12),
        ])
    }
    return tables
}

/**
 * The faces of a font file. Never throws: a file that is not a font, is damaged or
 * cannot be read has no faces.
 *
 * @param file - the path of the file.
 * @returns one entry for each face that is a TrueType or OpenType font with a family
 *     name; `math` is `true` when the face has a `MATH` table.
 */
export function readFaces(file: string): Face[] {
    let fd: number | undefined
    try {
        fd = openSync(file, "r")
        const size = fstatSync(fd).size
        const head = readBytes(fd, size, 0, 4)
        if (!head) return []
        let offsets = [0]
        if (head.toString("latin1") === "ttcf") {
            const h = readBytes(fd, size, 0, sfntHeaderSize)
            if (!h) return []
            const n = Math.min(maxFaces, h.readUInt32BE(8))
            const list = readBytes(fd, size, sfntHeaderSize, 4 * n)
            offsets = list
                ? Array.from({ length: n }, (_, k) => list.readUInt32BE(4 * k))
                : []
        }
        const faces: Face[] = []
        for (const offset of offsets) {
            const tables = tableDirectory(fd, size, offset)
            const name = tables?.get("name")
            if (!tables || !name) continue
            const [at, length] = name
            if (length <= 0 || length > maxNameTable) continue
            const bytes = readBytes(fd, size, at, length)
            const family = bytes ? familyFromNameTable(bytes) : undefined
            if (family) faces.push({ family, math: tables.has("MATH") })
        }
        return faces
    } catch {
        return []
    } finally {
        if (fd !== undefined) closeSync(fd)
    }
}

// --- finding the font files

/**
 * The font folders of a system that exist.
 *
 * @param system - the machine.
 * @returns the folders.
 */
export function defaultFontDirs(system: System): string[] {
    const env = (name: string): string | undefined => system.env[name] || undefined
    let dirs: string[]
    if (isWindows(system)) {
        dirs = [
            join(env("WINDIR") ?? "C:\\Windows", "Fonts"),
            join(
                env("LOCALAPPDATA") ?? join(system.home, "AppData", "Local"),
                "Microsoft",
                "Windows",
                "Fonts",
            ),
        ]
    } else if (isMac(system)) {
        dirs = [
            "/System/Library/Fonts",
            "/Library/Fonts",
            join(system.home, "Library", "Fonts"),
        ]
    } else {
        dirs = [
            "/usr/share/fonts",
            "/usr/local/share/fonts",
            join(system.home, ".fonts"),
            join(system.home, ".local", "share", "fonts"),
        ]
    }
    return dirs.filter(isDirectory)
}

/**
 * @param path - a path.
 * @returns `true` if it is a folder (a link to one counts).
 */
function isDirectory(path: string): boolean {
    try {
        return statSync(path).isDirectory()
    } catch {
        return false
    }
}

/**
 * @param path - a path or file name; Windows and Unix separators are both read.
 * @returns `true` if it is named like a TrueType or OpenType font file.
 */
export function isFontFile(path: string): boolean {
    const extension = /\.([^./\\]+)$/.exec(path)?.[1] ?? ""
    return fontExtensions.has(`.${extension.toLowerCase()}`)
}

/**
 * The non-blank lines that a program prints.
 *
 * @param system - the machine whose environment (`PATH`) it runs in.
 * @param program - the program.
 * @param args - its arguments.
 * @returns the trimmed lines, or `undefined` if it cannot run or fails.
 */
function programLines(
    system: System,
    program: string,
    args: string[],
): string[] | undefined {
    const result = spawnSync(program, args, {
        encoding: "utf8",
        env: system.env,
        stdio: ["ignore", "pipe", "ignore"],
    })
    if (result.error || result.status !== 0) return undefined
    return result.stdout
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line !== "")
}

/**
 * @param system - the machine.
 * @returns `true` if a TeX installation is on its path: `kpsewhich`, or LuaLaTeX's
 *     `luaotfload-tool`.
 */
export function texInstalled(system: System): boolean {
    return (
        findExecutable(system, "kpsewhich") !== undefined ||
        findExecutable(system, "luaotfload-tool") !== undefined
    )
}

/**
 * The folders of the OpenType and TrueType fonts in the `texmf` trees of the TeX
 * installation: `fonts/opentype` and `fonts/truetype` under each tree `kpsewhich` names.
 *
 * @param system - the machine.
 * @returns the folders that exist; none if there is no `kpsewhich`.
 */
function texFontDirs(system: System): string[] {
    const trees = new Set<string>()
    for (const variable of texmfVariables) {
        for (const line of programLines(system, "kpsewhich", [`-var-value=${variable}`]) ??
            []) {
            for (const part of line.split(/[:;,{}]/)) {
                const tree = part.replace(/^!!/, "").replace(/[/\\]+$/, "")
                if (tree !== "") trees.add(tree)
            }
        }
    }
    return [...trees]
        .flatMap((tree) =>
            ["opentype", "truetype"].map((kind) => join(tree, "fonts", kind)),
        )
        .filter(isDirectory)
}

/**
 * The font files under some folders.
 *
 * @param dirs - the folders, walked recursively (links to folders are followed, to a
 *     bounded depth).
 * @returns the paths of the files named like fonts.
 */
function walkFonts(dirs: string[]): string[] {
    const found: string[] = []
    const walk = (dir: string, depth: number): void => {
        if (depth > maxWalkDepth) return
        let entries: Dirent[]
        try {
            entries = readdirSync(dir, { withFileTypes: true })
        } catch {
            return
        }
        for (const entry of entries) {
            const path = join(dir, entry.name)
            if (entry.isDirectory() || (entry.isSymbolicLink() && isDirectory(path)))
                walk(path, depth + 1)
            else if (isFontFile(entry.name)) found.push(path)
        }
    }
    for (const dir of dirs) walk(dir, 0)
    return found
}

/**
 * The font files named in the text `reg query` prints for a registry key of installed
 * fonts: each `Name (TrueType)    REG_SZ    file` line gives a file, a path of its own
 * for a font installed for one user, else a file name in the fonts folder.
 *
 * @param output - the text printed by `reg query`.
 * @param fontsDir - the folder a bare file name belongs to.
 * @returns the paths of the TrueType and OpenType files named; other values (Type 1,
 *     numbers, empty) are left out.
 */
export function parseRegistryFonts(output: string | undefined, fontsDir: string): string[] {
    const files: string[] = []
    for (const line of (output ?? "").split(/\r?\n/)) {
        const value = /\s+REG_SZ\s+(.+?)\s*$/.exec(line)?.[1]
        if (value === undefined || !isFontFile(value)) continue
        files.push(
            /^([A-Za-z]:[\\/]|\\\\|\/)/.test(value) ? value : `${fontsDir}\\${value}`,
        )
    }
    return files
}

/**
 * On Windows, the font files the registry lists as installed, for the machine and for
 * the user (some lie outside the system's font folders). Untested on Windows.
 *
 * @param system - the machine.
 * @returns the paths; none elsewhere or when `reg` cannot run.
 */
function registryFonts(system: System): string[] {
    if (!isWindows(system)) return []
    const fontsDir = `${system.env.WINDIR || "C:\\Windows"}\\Fonts`
    return registryHives.flatMap((hive) => {
        const result = spawnSync("reg", ["query", hive + registryFontsKey], {
            encoding: "utf8",
            env: system.env,
            stdio: ["ignore", "pipe", "ignore"],
        })
        return parseRegistryFonts(result.error ? undefined : result.stdout, fontsDir)
    })
}

/**
 * The font files of this machine, without repeats: those in the system's font folders,
 * those fontconfig lists, on Windows those the registry lists, and, when TeX is found,
 * those of the LuaLaTeX font database (or the `texmf` font trees walked, if the
 * database is missing or empty). A source that is not there adds nothing.
 *
 * @param system - the machine.
 * @returns the paths of files that exist.
 */
export function fontFiles(system: System): string[] {
    const tex = texInstalled(system)
    const fromFontconfig = programLines(system, "fc-list", ["--format", "%{file}\\n"]) ?? []
    const luaotfloadArgs = ["--no-reload", "--list=*", "--fields=fullpath"]
    const fromLuaotfload = tex
        ? (programLines(system, "luaotfload-tool", luaotfloadArgs) ?? [])
        : []
    const fromTexmf =
        tex && !fromLuaotfload.some(isFontFile) ? walkFonts(texFontDirs(system)) : []
    const all = [
        ...walkFonts(defaultFontDirs(system)),
        ...fromFontconfig,
        ...registryFonts(system),
        ...fromLuaotfload,
        ...fromTexmf,
    ]
    return [...new Set(all.filter(isFontFile))].filter((file) => {
        try {
            return statSync(file).isFile()
        } catch {
            return false
        }
    })
}

// --- the scan and its cache

/**
 * Sorts the fonts of some files into math and text fonts.
 *
 * @param files - the font files.
 * @returns the families, each list sorted without regard to case; a family with a face
 *     that has a `MATH` table is a math font and not a text font.
 */
export function scanFonts(files: string[]): FontList {
    const math = new Set<string>()
    const text = new Set<string>()
    for (const file of files)
        for (const face of readFaces(file)) (face.math ? math : text).add(face.family)
    for (const family of math) text.delete(family)
    const sorted = (set: Set<string>): string[] =>
        [...set].sort(
            (a, b) => a.toLowerCase().localeCompare(b.toLowerCase()) || (a < b ? -1 : 1),
        )
    return { text: sorted(text), math: sorted(math) }
}

/**
 * A token that stands for the font files as they are: their paths, sizes and times of
 * change. It changes when a font is installed, removed or replaced.
 *
 * @param files - the font files (a file that cannot be read counts by its path only).
 * @returns a hash as hexadecimal text, the same for any order of `files`.
 */
export function fingerprint(files: string[]): string {
    const lines = files.map((file) => {
        try {
            const s = statSync(file)
            return `${file}\0${s.size}\0${s.mtimeMs}`
        } catch {
            return `${file}\0-\0-`
        }
    })
    return createHash("sha256").update(lines.sort().join("\n")).digest("hex")
}

/**
 * @param file - the cache file.
 * @returns its content, or `undefined` if there is none or it is not a font cache.
 */
function readCache(file: string): FontCache | undefined {
    try {
        const value: unknown = JSON.parse(readFileSync(file, "utf8"))
        const c = value as Partial<FontCache> | null
        const strings = (x: unknown): boolean =>
            Array.isArray(x) && x.every((s) => typeof s === "string")
        return c && typeof c.fingerprint === "string" && strings(c.math) && strings(c.text)
            ? (c as FontCache)
            : undefined
    } catch {
        return undefined
    }
}

/**
 * The fonts of some files, from the cache file when the files are the ones it was made
 * from, else by scanning them (and writing the cache; a failure to write is ignored,
 * the scan is just done again next time).
 *
 * @param cacheFile - the cache file (`fonts.json`).
 * @param files - the font files.
 * @returns the fonts.
 */
export function loadFonts(cacheFile: string, files: string[]): FontList {
    const current = fingerprint(files)
    const cached = readCache(cacheFile)
    if (cached && cached.fingerprint === current)
        return { text: cached.text, math: cached.math }
    const fonts = scanFonts(files)
    try {
        writeAtomic(cacheFile, JSON.stringify({ ...fonts, fingerprint: current }))
    } catch {
        // an unwritable cache only costs a new scan
    }
    return fonts
}

/**
 * The installed fonts of this machine, sorted into text and math fonts.
 *
 * @param system - the machine.
 * @param cacheFolder - the folder the cache file `fonts.json` lives in (see `cacheDir`).
 * @returns the families.
 */
export function listFonts(system: System, cacheFolder: string): FontList {
    return loadFonts(join(cacheFolder, cacheFileName), fontFiles(system))
}
