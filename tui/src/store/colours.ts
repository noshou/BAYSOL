// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The colours a figure setting may name, and how one looks as a terminal colour.
 *
 * A colour is written as a name of the list the colour sets of `assets/data/colour-sets/`
 * make (the CSS names, the X11 and xkcd colours and the government, international and
 * university colours, merged when the list is first needed, see `mergeColourSets`; case,
 * blanks, `-` and `_` do not count), or as a code: `#rgb`,
 * `#rrggbb`, `rgb(r, g, b)` (0 to 255), `hsl(h, s%, l%)` or `cmyk(c%, m%, y%, k%)`. The
 * list is the terminal interface's own: Julia reads the codes and the names of Colors.jl
 * (the 148 CSS names and the X11 names: sets `css`, `x11`), so a setting keeps such a
 * name or a code as it was typed and any other name as the `#rrggbb` of its colour. The
 * swatch of a colour is its `#rrggbb`.
 */

import { readFileSync } from "node:fs"
import {
    type ParseError,
    parse as parseJsonc,
    printParseErrorCode,
} from "jsonc-parser"
import { assetPath, lazy } from "../core/environment.js"
import {
    colourNotations,
    fromHex,
    type Notations,
    parseColourCode as parseCode,
    toHex,
} from "./colour-notation.js"

/** The letters that do not decompose, spelled with ASCII (as `colour_fold` of Julia). */
const spelled: Readonly<Record<string, string>> = {
    "ß": "ss",
    "æ": "ae",
    "œ": "oe",
    "ø": "o",
    "đ": "d",
    "ð": "d",
    "ł": "l",
    "ı": "i",
    "þ": "th",
}

/**
 * A name in lower case without accents: letters are decomposed (NFD), their combining marks
 * dropped (`québec` is `quebec`), and the letters that do not decompose are spelled with
 * ASCII (`ß` is `ss`, `ø` is `o`, ...). The shown and stored names keep their accents.
 */
export const fold = (name: string): string =>
    name
        .toLowerCase()
        .normalize("NFD")
        .replace(/\p{M}/gu, "")
        .replace(/[ßæœøđðłıþ]/g, (c) => spelled[c] ?? c)

/** What a name is compared by: folded, only letters and digits. */
export const colourKey = (name: string): string => fold(name).replace(/[^a-z0-9]/g, "")

/** One colour of a set file, as it is written there (`assets/data/colour-sets/`). */
interface SetColour {
    name: string
    hex: string
    /** The name as the source wrote it, where `name` was cleaned (nbs-iscc, paul-tol). */
    raw?: string
    /** `false` for a value not checked against the source; absent means checked. */
    verified?: boolean
    /** The source of this value; absent means the `url` of the set. */
    url?: string
    /** The colour family, one of `FAMILIES` (written by `tui/dev/colour-families.ts`). */
    family: string
}

/** One colour set file. */
export interface ColourSet {
    set: string
    title: string
    licence: string
    url: string
    notes?: string
    colours: SetColour[]
}

/** The merge rules of `colour-sets/index.jsonc`. */
export interface ColourIndex {
    order: string[]
    julia: string[]
    identifiers: Record<string, string>
    hyphenated: string[]
    common: Record<string, "all" | "no-digit" | "one-word">
    renames: Record<string, string>
    placeAbbreviations: [string, string][]
    nationalNames: [string, string, string][]
    winsorWords: Record<string, string>
    excludedWords: string[]
}

/** A parsed `.jsonc` file; any syntax error is fatal (the parser alone is forgiving). */
function readJsonc<T>(...path: string[]): T {
    const file = assetPath(...path)
    const errors: ParseError[] = []
    const value = parseJsonc(readFileSync(file, "utf-8"), errors, {
        allowTrailingComma: false,
    }) as T
    const first = errors[0]
    if (first !== undefined)
        throw new Error(`${file}: ${printParseErrorCode(first.error)} at ${first.offset}`)
    return value
}

/** The merge rules of the sets (read once). */
export const colourIndex: () => ColourIndex = lazy(() =>
    readJsonc<ColourIndex>("data", "colour-sets", "index.jsonc"),
)

/**
 * The colour sets of `assets/data/colour-sets/`, in priority order (read once: about
 * 8,300 rows in 36 files).
 *
 * @returns the sets, the first having the plain name of a name two sets share.
 */
export const colourSets: () => readonly ColourSet[] = lazy(() =>
    colourIndex().order.map((tag) => {
        const set = readJsonc<ColourSet>("data", "colour-sets", `${tag}.jsonc`)
        if (set.set !== tag) throw new Error(`${tag}.jsonc is the set ${set.set}`)
        return set
    }),
)

/** How one colour of a set came to be in the list. */
interface Placed {
    /** The name in the list (with its `(set)` tag if the plain name was taken). */
    name: string
    hex: string
    /** The set it comes from and its row there. */
    set: string
    row: number
    /** The lower-case name before clashes were settled. */
    base: string
}

/** What the duplicate pass dropped and why. */
interface Dropped {
    dropped: string
    kept: string
    rule: "name" | "common" | "shortest"
}

/** The merged list. */
export interface MergedColours {
    /** The colours of the list, sorted by (lower-case name, name). */
    list: Placed[]
    /** Every colour placed before the duplicate pass (the dropped ones too). */
    placed: Placed[]
    dropped: Dropped[]
    /** Per set: rows read, exact duplicates left out, tagged and numbered names. */
    counts: Record<
        string,
        { raw: number; duplicates: number; tagged: number; numbered: number }
    >
}

/** The words a clash name has for a set: `paul-tol` is `paul tol`. */
function identifier(tag: string, index: ColourIndex): string {
    const known = index.identifiers[tag]
    if (known !== undefined) return known
    return index.hyphenated.includes(tag) ? tag : tag.replaceAll("-", " ")
}

/** The lower-case name of a row of a set, before clashes are settled. */
export function baseName(tag: string, raw: string, index: ColourIndex): string {
    let name = raw.trim().toLowerCase()
    if (tag === "tailwind") name = name.replaceAll(".", " ")
    name = name.replace(/\bf\.s\.?\s*/g, "").trim()
    for (const [pattern, short] of index.placeAbbreviations)
        name = name.replace(new RegExp(pattern, "g"), short)
    for (const [set, pattern, country] of index.nationalNames)
        if (set === tag) name = name.replace(new RegExp(pattern, "g"), country)
    if (tag === "winsor-newton")
        name = name
            .split(/\s+/)
            .filter((w) => w !== "")
            .map((w) => index.winsorWords[w] ?? w)
            .join(" ")
    return index.renames[name] ?? name
}

/** Whether a row is a name of an excluded word (the owner rule of `index.jsonc`). */
export const isExcluded = (name: string, index: ColourIndex): boolean => {
    const lower = name.toLowerCase()
    return index.excludedWords.some((w) => lower.includes(w))
}

/** Whether a name is one everybody knows (`common` of `index.jsonc`). */
function isCommon(tag: string, base: string, index: ColourIndex): boolean {
    const rule = index.common[tag]
    if (rule === "all") return true
    if (rule === "no-digit") return !/\d/.test(base)
    return rule === "one-word" && /^[a-z]+$/.test(base)
}

const compareText = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0)

/**
 * Merges the sets into the list: the same steps and results as `build` and `prune!` of
 * the Julia harvester this replaces. Each set is read in priority order; a name is lower
 * case; the same name (case, blanks, `-`, `_` and accents ignored) with the same colour
 * as an earlier entry is left out; the same name with another colour is `name (set)`
 * (`name (set 2)` if even that is taken). The duplicate pass then drops, of entries
 * whose names are the same once folded, all but the first, and of each group with exactly
 * one colour all but the common names (all if none: the shortest name stays).
 *
 * @param sets - the sets in priority order.
 * @param index - the rules.
 * @returns the list, what was placed before the pass, what the pass dropped and counts.
 */
export function mergeColourSets(
    sets: readonly ColourSet[],
    index: ColourIndex,
): MergedColours {
    const table = new Map<string, Placed>()
    const claimed = new Map<string, Set<string>>()
    const plainKeys = new Set<string>()
    const counts: MergedColours["counts"] = {}
    const placed: Placed[] = []
    const place = new Map<string, number>()
    for (const { set: tag, colours } of sets) {
        const count = { raw: 0, duplicates: 0, tagged: 0, numbered: 0 }
        counts[tag] = count
        colours.forEach((row, at) => {
            if (isExcluded(row.name, index)) return
            count.raw++
            const base = baseName(tag, row.name, index)
            const key = colourKey(base)
            const seen = claimed.get(key) ?? new Set<string>()
            claimed.set(key, seen)
            if (seen.has(row.hex)) {
                count.duplicates++
                return
            }
            let name = base
            if (table.has(name) || plainKeys.has(key)) {
                name = `${base} (${identifier(tag, index)})`
                count.tagged++
                if (table.has(name)) {
                    let n = 1
                    while (table.has(name)) {
                        n++
                        name = `${base} (${identifier(tag, index)} ${n})`
                    }
                    count.numbered++
                }
            }
            seen.add(row.hex)
            if (name === base) plainKeys.add(key)
            const entry = { name, hex: row.hex, set: tag, row: at, base }
            table.set(name, entry)
            place.set(name, place.size + 1)
            placed.push(entry)
        })
    }
    const dropped: Dropped[] = []
    const where = (name: string): number => place.get(name) as number
    // entries with the same folded name: the first by priority stays
    const byKey = new Map<string, string[]>()
    for (const name of table.keys()) {
        const key = colourKey(name)
        byKey.set(key, [...(byKey.get(key) ?? []), name])
    }
    for (const names of byKey.values()) {
        if (names.length < 2) continue
        names.sort((a, b) => where(a) - where(b))
        for (const name of names.slice(1)) {
            dropped.push({ dropped: name, kept: names[0] as string, rule: "name" })
            table.delete(name)
        }
    }
    // entries with exactly one colour: the common names, else the shortest
    const byColour = new Map<string, string[]>()
    for (const [name, { hex }] of table)
        byColour.set(hex, [...(byColour.get(hex) ?? []), name])
    for (const names of byColour.values()) {
        if (names.length < 2) continue
        names.sort((a, b) => where(a) - where(b))
        const common = names.filter((n) => {
            const { set, base } = table.get(n) as Placed
            return isCommon(set, base, index)
        })
        const shortest = [...names].sort(
            (a, b) => [...a].length - [...b].length || where(a) - where(b),
        )[0] as string
        const keep = common.length > 0 ? common : [shortest]
        for (const name of names) {
            if (keep.includes(name)) continue
            dropped.push({
                dropped: name,
                kept: keep.join(", "),
                rule: common.length > 0 ? "common" : "shortest",
            })
            table.delete(name)
        }
    }
    const list = [...table.values()].sort(
        (a, b) =>
            compareText(a.name.toLowerCase(), b.name.toLowerCase()) ||
            compareText(a.name, b.name),
    )
    return { list, placed, dropped, counts }
}

/** The merged list with the families of the set files (read once). */
const merged: () => MergedColours = lazy(() =>
    mergeColourSets(colourSets(), colourIndex()),
)

/** The colours of the list by name (every lookup is a plain scan or a Map hit). */
const table: () => { byName: Map<string, string> } = lazy(() => ({
    byName: new Map(merged().list.map((c) => [c.name, c.hex])),
}))

/** The names Julia reads: the plain names the sets of `julia` of the index have. */
export const juliaColourNames: () => ReadonlySet<string> = lazy(
    () =>
        new Set(
            merged()
                .list.filter(
                    (c) => colourIndex().julia.includes(c.set) && c.name === c.base,
                )
                .map((c) => c.name),
        ),
)

/** @returns every colour of the list as `[name, hex]`, in the order of `colourNames`. */
export const colourList = (): readonly (readonly [string, string])[] => [
    ...table().byName,
]

/** @returns every colour name, in the order of the (sorted) file. */
export const colourNames = (): readonly string[] => [...table().byName.keys()]

/**
 * The colour families of the picker's filter: the 11 basic colour terms and cyan. Every
 * name of the list is in exactly one (the `family` of its row in the set file, written by
 * `tui/dev/colour-families.ts` from the colour: see the constants there).
 */
export const FAMILIES = [
    "red",
    "orange",
    "yellow",
    "green",
    "cyan",
    "blue",
    "purple",
    "pink",
    "brown",
    "gray",
    "black",
    "white",
] as const

/** One of the colour families. */
export type Family = (typeof FAMILIES)[number]

/** The filter of the picker: one family, or `all`. */
export type FamilyFilter = Family | "all"

/** The family of each name of the list (read once; from the `family` of the rows). */
const families: () => ReadonlyMap<string, Family> = lazy(
    () => new Map(merged().list.map((c) => [c.name, rowFamily(c)])),
)

/** The family a placed colour has in its set file. */
function rowFamily(c: Placed): Family {
    const sets = colourSets()
    const at = colourIndex().order.indexOf(c.set)
    return (sets[at]?.colours[c.row]?.family ?? "") as Family
}

/**
 * The family of a listed colour, by its name or by a code.
 *
 * @param colour - a name of the list (any spelling) or a colour code (then the family of
 *   the first name with exactly that colour).
 * @returns the family, or `undefined` for a code no name has.
 */
export function colourFamily(colour: string): Family | undefined {
    const isCode = parseColourCode(colour) !== undefined
    const name = isCode ? namesOfCode(colour)?.[0] : listedName(colour)
    return name === undefined ? undefined : families().get(name)
}

/**
 * The next filter after `current`: all, then each family, then all again.
 *
 * @param current - the filter now.
 * @returns the next one.
 */
export function nextFamily(current: FamilyFilter): FamilyFilter {
    const order: FamilyFilter[] = ["all", ...FAMILIES]
    return order[(order.indexOf(current) + 1) % order.length] as FamilyFilter
}

/**
 * The names a typed text finds in the list, in one family only (or all of them).
 *
 * @param names - the whole list, alphabetical.
 * @param typed - the text.
 * @param family - the filter.
 * @returns what `narrowColours` finds, without the names of other families.
 */
export function narrowInFamily(
    names: readonly string[],
    typed: string,
    family: FamilyFilter,
): string[] {
    const found = narrowColours(names, typed)
    if (family === "all") return found
    const of = families()
    return found.filter((name) => of.get(name) === family)
}

/** What starts a colour code (so a malformed one is told from an unknown name). */
const codeStart = /^(#|rgb\s*\(|hsl\s*\(|cmyk\s*\()/i

/** Whether a text is written like a code, valid or not. */
export const looksLikeCode = (text: string): boolean => codeStart.test(text.trim())

/**
 * The `#rrggbb` a colour code stands for.
 *
 * @param text - `#rgb`, `#rrggbb`, `rgb(r, g, b)`, `hsl(h, s%, l%)` or
 *   `cmyk(c%, m%, y%, k%)`.
 * @returns the colour, or `undefined` if the text is no valid code.
 */
export function parseColourCode(text: string): string | undefined {
    const rgb = parseCode(text)
    return rgb === undefined ? undefined : toHex(rgb)
}

/**
 * The name of the list a text spells: the name itself in any case, else the first name
 * that differs only in blanks, `-` and `_` (the rule of `colourRgb` in Julia).
 *
 * @returns the listed name, or `undefined` if there is none.
 */
export function listedName(text: string): string | undefined {
    const { byName } = table()
    const exact = text.trim().toLowerCase()
    if (byName.has(exact)) return exact
    const want = colourKey(text)
    for (const name of byName.keys()) if (colourKey(name) === want) return name
    return undefined
}

/**
 * The colour of a name or a code as the `#rrggbb` text a terminal colour takes, for a
 * `Swatch`.
 *
 * @param colour - a name of the list (any spelling) or a colour code.
 * @returns the colour, or `undefined` if the text is neither.
 */
export function colourHex(colour: string): string | undefined {
    const code = parseColourCode(colour)
    if (code !== undefined) return code
    if (looksLikeCode(colour)) return undefined
    const name = listedName(colour)
    return name === undefined ? undefined : table().byName.get(name)
}

/**
 * The colour of a name or code in every notation.
 *
 * @returns the `#rrggbb`, `rgb()`, `hsl()` and `cmyk()` texts, or `undefined` if the text
 *   is neither a name nor a valid code.
 */
export function colourInfo(text: string): Notations | undefined {
    const hex = colourHex(text)
    return hex === undefined ? undefined : colourNotations(fromHex(hex))
}

/**
 * Every named colour with exactly the 8-bit sRGB colour a code writes (the reverse lookup).
 *
 * @param code - a colour code in any notation.
 * @returns the names (none if no name has that colour), or `undefined` if the text is
 *   no code.
 */
export function namesOfCode(code: string): readonly string[] | undefined {
    const hex = parseColourCode(code)
    if (hex === undefined) return undefined
    return [...table().byName].filter(([, h]) => h === hex).map(([name]) => name)
}

/**
 * Whether a raw value is a colour a figure can use, and the form a setting keeps it in:
 * a code as typed, a name Julia reads (a CSS or X11 name) as the listed
 * name, any other name as the `#rrggbb` of its colour (Julia does not know it).
 *
 * @returns the text to keep, or `undefined` if the value is no name or valid code.
 */
export function colourOf(raw: unknown): string | undefined {
    if (typeof raw !== "string") return undefined
    const text = raw.trim()
    if (parseColourCode(text) !== undefined) return text
    if (looksLikeCode(text)) return undefined
    const name = listedName(text)
    if (name === undefined) return undefined
    return juliaColourNames().has(name) ? name : table().byName.get(name)
}

/** A name's key and where each of its words starts in that key. */
function keyOf(name: string): { key: string; starts: number[] } {
    let key = ""
    const starts: number[] = []
    let boundary = true
    for (const c of fold(name)) {
        if (/[a-z0-9]/.test(c)) {
            if (boundary) starts.push(key.length)
            key += c
            boundary = false
        } else boundary = true
    }
    return { key, starts }
}

/**
 * The names a typed text finds in the list: every name that has the typed letters and
 * digits anywhere in it (`brown` finds `dark brown`, `saddlebrown`, `brown1`). Case,
 * blanks, `-`, `_` and the brackets of a tag such as `(xkcd)` do not count. They come
 * in four groups, each in the order of the list (alphabetical): the name that is exactly
 * the text, names that start with it, names with a word that starts with it, the rest.
 *
 * @param names - the whole list, alphabetical.
 * @param typed - the text.
 * @returns the names that match, best group first.
 */
export function narrowColours(names: readonly string[], typed: string): string[] {
    const want = colourKey(typed)
    if (want === "") return [...names]
    const exact: string[] = []
    const prefix: string[] = []
    const word: string[] = []
    const inside: string[] = []
    for (const name of names) {
        const { key, starts } = keyOf(name)
        if (key === want) exact.push(name)
        else if (key.startsWith(want)) prefix.push(name)
        else if (starts.some((at) => key.startsWith(want, at))) word.push(name)
        else if (key.includes(want)) inside.push(name)
    }
    return [...exact, ...prefix, ...word, ...inside]
}

/** Splits at the commas that are not inside brackets: `rgb(1, 2, 3), red` is two words. */
export function splitTopLevel(text: string): string[] {
    const words: string[] = []
    let depth = 0
    let start = 0
    for (let i = 0; i < text.length; i++) {
        const c = text[i]
        if (c === "(") depth++
        else if (c === ")") depth = Math.max(0, depth - 1)
        else if (c === "," && depth === 0) {
            words.push(text.slice(start, i).trim())
            start = i + 1
        }
    }
    words.push(text.slice(start).trim())
    return words
}

/**
 * The colours of a typed list. Commas separate the words (a name may have blanks:
 * `green (xkcd), red`); a word that is no colour as it stands is split at its
 * blanks outside brackets (`red blue`), so commas and blanks may be mixed.
 */
export function colourWords(text: string): string[] {
    const words: string[] = []
    for (const piece of splitTopLevel(text.trim())) {
        if (piece === "") continue
        if (colourHex(piece) !== undefined) {
            words.push(piece)
            continue
        }
        let depth = 0
        let word = ""
        for (const c of piece) {
            if (c === "(") depth++
            else if (c === ")") depth = Math.max(0, depth - 1)
            if (/\s/.test(c) && depth === 0) {
                if (word !== "") words.push(word)
                word = ""
            } else word += c
        }
        if (word !== "") words.push(word)
    }
    return words
}
