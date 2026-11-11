// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The colours a figure setting may name, and how one looks as a terminal colour.
 *
 * A colour is written as a name of `assets/data/colours.json` (the CSS names, the X11 and
 * xkcd colours and the government, international and university colours, harvested by
 * `bysl harvest colours`; case, blanks, `-` and `_` do not count), or as a code: `#rgb`,
 * `#rrggbb`, `rgb(r, g, b)` (0 to 255), `hsl(h, s%, l%)` or `cmyk(c%, m%, y%, k%)`. The
 * list is the terminal interface's own: Julia reads the codes and the names of Colors.jl
 * (the 148 CSS names and the X11 names, `colour-julia.json`), so a setting keeps such a
 * name or a code as it was typed and any other name as the `#rrggbb` of its colour. The
 * swatch of a colour is its `#rrggbb`.
 */

import { lazy, readAssetJson } from "../core/environment.js"
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

/** The colours of `colours.json` by name (read once; every lookup is a plain scan). */
const table: () => { byName: Map<string, string> } = lazy(() => {
    const file = readAssetJson<Record<string, string>>("data", "colours.json")
    return { byName: new Map(Object.entries(file)) }
})

/** The names Julia reads (`colour-julia.json`), with the colour the list gives them. */
const julianNames: () => ReadonlySet<string> = lazy(
    () => new Set(readAssetJson<string[]>("data", "colour-julia.json")),
)

/** @returns every colour name, in the order of the (sorted) file. */
export const colourNames = (): readonly string[] => [...table().byName.keys()]

/**
 * The colour families of the picker's filter: the 11 basic colour terms and cyan. Every
 * name of the list is in exactly one (`colour-families.json`, computed by
 * `bysl harvest colours` from the colour: see the constants there).
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

/** The family of each name of the list (read once). */
const families: () => ReadonlyMap<string, Family> = lazy(
    () =>
        new Map(
            Object.entries(
                readAssetJson<Record<string, Family>>("data", "colour-families.json"),
            ),
        ),
)

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
 * that differs only in blanks, `-` and `_` (the rule of `colour_rgb` in Julia).
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
    return julianNames().has(name) ? name : table().byName.get(name)
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
