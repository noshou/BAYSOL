// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * Writes the `family` of every colour of the sets in `tui/assets/data/colour-sets/`
 * (one of the 12 of `FAMILIES`: the filter of the colour picker). It ports the family
 * rules of the Julia harvester `harvest-colours.jl` (removed 2026-11-13; see git history) (`family_of` and what it uses) exactly and
 * edits the files with `jsonc-parser`'s `modify` and `applyEdits`, so the comments, the
 * order and the one-row-per-line layout of the files stay as they are.
 *
 * The family of a colour is computed from its name in the merged list (the name with its
 * `(set)` tag, as the picker shows it) and its colour; a colour the merge left out (an
 * exact duplicate, or one the duplicate pass dropped) gets the family of its plain name.
 *
 * Usage: `npx tsx tui/dev/colour-families.ts [--check] [--compare FILE]`
 *   (none)          write the families into the set files that change
 *   --check         write nothing; exit 1 if a family is out of date
 *   --compare FILE  also compare the families of the list with a `name: family` JSON
 *                   file (the old `colour-families.json`) and report the differences
 */

import { readFileSync, writeFileSync } from "node:fs"
import { applyEdits, type Edit, modify } from "jsonc-parser"
import { assetPath } from "../src/core/environment.js"
import {
    baseName,
    type ColourIndex,
    type ColourSet,
    colourIndex,
    colourSets,
    FAMILIES,
    isExcluded,
    mergeColourSets,
} from "../src/store/colours.js"

/** A colour as three whole numbers 0 to 255. */
type Rgb8 = [number, number, number]

const rgbOf = (hex: string): Rgb8 => [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
]

const D65_WHITE: [number, number, number] = [95.047, 100.0, 108.883]

// The boundaries of the rules, from the colour as hue (degrees), saturation and
// lightness (0 to 1) of HSL. Every colour gets exactly one family.

/** A colour with less saturation than this has no hue: it is gray (or black or white). */
const FAMILY_NEUTRAL_SATURATION = 0.12
/** A colour with less lightness than this is black, whatever its hue. */
const FAMILY_BLACK_LIGHTNESS = 0.12
/** A colour with more lightness than this is white, whatever its hue. */
const FAMILY_WHITE_LIGHTNESS = 0.93
/**
 * The hue bands, as `[upper edge in degrees, family]`: red below 15 and from 345, orange
 * to 45, yellow to 70, green to 165, cyan to 200, blue to 255, purple to 290; magenta to
 * 345 is pink if light and purple if dark.
 */
const FAMILY_HUE_BANDS: [number, string][] = [
    [15.0, "red"],
    [45.0, "orange"],
    [70.0, "yellow"],
    [165.0, "green"],
    [200.0, "cyan"],
    [255.0, "blue"],
    [290.0, "purple"],
    [345.0, "magenta"],
]
/** A magenta with at least this lightness is pink, a darker one purple. */
const FAMILY_PINK_LIGHTNESS = 0.45
/**
 * Where the magenta band turns to crimson: from this hue (degrees) a dark colour is a red
 * (crimson, burgundy, wine) when it is saturated, not a purple.
 */
const FAMILY_CRIMSON_HUE = 330.0
/** A dark colour in the crimson hues with at least this saturation is red. */
const FAMILY_CRIMSON_SATURATION = 0.5
/** A dark, unsaturated colour in the crimson hues with less lightness is brown. */
const FAMILY_CRIMSON_BROWN_LIGHTNESS = 0.3
/**
 * Words that name a red whatever the hue band put the colour in: a colour in the crimson
 * or orange hues whose name has one of them is red (`burgundy`, `mcmaster maroon`).
 */
const FAMILY_RED_WORDS = [
    "wine",
    "burgundy",
    "maroon",
    "crimson",
    "ruby",
    "cherry",
    "cranberry",
    "bordeaux",
    "claret",
    "scarlet",
    "vermilion",
    "carmine",
    "garnet",
]
/** A red lighter than this (and not gray) is pink. */
const FAMILY_LIGHT_RED_LIGHTNESS = 0.72
/** A red or orange darker than this is brown (not a dark red of the saturation below). */
const FAMILY_BROWN_LIGHTNESS = 0.4
/** A dark red with at least this saturation is red, not brown (maroon). */
const FAMILY_DARK_RED_SATURATION = 0.7
/** An orange with less saturation than this and less lightness than the next is brown. */
const FAMILY_MUTED_ORANGE_SATURATION = 0.5
/** See `FAMILY_MUTED_ORANGE_SATURATION`. */
const FAMILY_MUTED_ORANGE_LIGHTNESS = 0.75
/** A yellow darker than this is green (olive). */
const FAMILY_OLIVE_LIGHTNESS = 0.35
/**
 * The families next to each other: a name whose last word is a family takes it when the
 * computed family is that one or one of its neighbours.
 */
const FAMILY_NEIGHBOURS: Record<string, string[]> = {
    red: ["orange", "pink", "brown", "purple"],
    orange: ["red", "yellow", "brown"],
    yellow: ["orange", "green", "brown"],
    green: ["yellow", "cyan"],
    cyan: ["green", "blue"],
    blue: ["cyan", "purple"],
    purple: ["blue", "pink", "red"],
    pink: ["red", "purple", "white"],
    brown: ["red", "orange", "yellow", "gray", "black"],
    gray: ["black", "white", "brown"],
    black: ["gray"],
    white: ["gray", "pink"],
}
/** The votes of the standard references count this much more than the survey names. */
const FAMILY_STANDARD_WEIGHT = 2.0
/** How many of the nearest references vote on the family of a colour. */
const FAMILY_NEIGHBOUR_COUNT = 9
/** A colour farther than this (CIE76 in Lab) from every reference is ruled by its hue. */
const FAMILY_NBS_MAX_DISTANCE = 30.0
/** Words of a colour name that make it a cyan, besides `cyan` itself. */
const FAMILY_CYAN_WORDS = ["teal", "turquoise", "aqua", "aquamarine", "cyan"]

const isFamily = (word: string): boolean => (FAMILIES as readonly string[]).includes(word)

/** A colour as hue (degrees), saturation and lightness (HSL). */
function hslOf([r8, g8, b8]: Rgb8): [number, number, number] {
    const [r, g, b] = [r8 / 255, g8 / 255, b8 / 255] as [number, number, number]
    const hi = Math.max(r, g, b)
    const lo = Math.min(r, g, b)
    const l = (hi + lo) / 2
    const d = hi - lo
    if (d === 0) return [0.0, 0.0, l]
    const s = d / (1 - Math.abs(2 * l - 1))
    // Julia's `mod` follows the sign of the divisor
    const mod6 = (x: number): number => ((x % 6) + 6) % 6
    const h =
        hi === r
            ? 60 * mod6((g - b) / d)
            : hi === g
              ? 60 * ((b - r) / d + 2)
              : 60 * ((r - g) / d + 4)
    return [h, s, l]
}

/** The words of the ISCC-NBS modifiers, stripped before the noun is read. */
const NBS_MODIFIERS = new RegExp(
    `^(?:${[
        "very",
        "dark",
        "deep",
        "light",
        "pale",
        "strong",
        "vivid",
        "brilliant",
        "moderate",
        "grayish",
        "dusky",
        "blackish",
    ].join("|")})+`,
)

/**
 * The family of an ISCC-NBS name (run together, as `verydarkyellowishgreen`) once its
 * modifiers are off: the noun it ends in, except where our twelve families differ from
 * the system's (the blue-greens are cyan, olive is green, ...).
 */
const NBS_FAMILY_OF_NOUN: Record<string, string> = {
    greenishblue: "cyan",
    bluishgreen: "cyan",
    olive: "green",
    olivegreen: "green",
    yellowgreen: "green",
    yellowishgreen: "green",
    orangeyellow: "yellow",
    greenishyellow: "yellow",
    violet: "purple",
    reddishpurple: "purple",
    purplishblue: "blue",
    purplishred: "red",
    purplishpink: "pink",
    yellowishpink: "pink",
    brownishpink: "pink",
    yellowishbrown: "brown",
    reddishbrown: "brown",
    olivebrown: "brown",
    reddishorange: "orange",
    brownishorange: "orange",
}

function nbsFamilyOfName(raw: string): string {
    const noun = raw.toLowerCase().replace(NBS_MODIFIERS, "")
    const known = NBS_FAMILY_OF_NOUN[noun]
    if (known !== undefined) return known
    for (const family of [
        "white",
        "black",
        "gray",
        "brown",
        "pink",
        "red",
        "orange",
        "yellow",
        "green",
        "blue",
        "purple",
    ])
        if (noun.endsWith(family)) return family
    return "gray"
}

/** A colour in CIELAB (D65). */
function labOf(c: Rgb8): [number, number, number] {
    const linear = (u: number): number =>
        u <= 0.04045 ? u / 12.92 : ((u + 0.055) / 1.055) ** 2.4
    const [r, g, b] = c.map((v) => linear(v / 255)) as [number, number, number]
    const x = ((0.4124564 * r + 0.3575761 * g + 0.1804375 * b) * 100) / D65_WHITE[0]
    const y = ((0.2126729 * r + 0.7151522 * g + 0.072175 * b) * 100) / D65_WHITE[1]
    const z = ((0.0193339 * r + 0.119192 * g + 0.9503041 * b) * 100) / D65_WHITE[2]
    const f = (t: number): number =>
        t > 216 / 24389 ? Math.cbrt(t) : ((24389 / 27) * t + 16) / 116
    return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
}

/**
 * The W3C CSS colour keywords by the categories of the CSS Color module (as MDN lists
 * them): the authoritative family of each of the 148 keywords. The CSS categories have no
 * cyan: the blue-greens (aqua to teal) are ours, and black is its own family here.
 */
const CSS_FAMILY_OF_KEYWORD: Map<string, string> = (() => {
    const groups: Record<string, string> = {
        pink: "pink hotpink deeppink lightpink palevioletred mediumvioletred",
        red:
            "lightsalmon salmon darksalmon lightcoral indianred crimson firebrick " +
            "darkred red",
        orange: "orangered tomato coral darkorange orange",
        yellow:
            "gold yellow lightyellow lemonchiffon lightgoldenrodyellow papayawhip " +
            "moccasin peachpuff palegoldenrod khaki darkkhaki",
        purple:
            "lavender thistle plum violet orchid fuchsia magenta mediumorchid " +
            "mediumpurple rebeccapurple blueviolet darkviolet darkorchid darkmagenta " +
            "purple indigo slateblue darkslateblue mediumslateblue",
        green:
            "greenyellow chartreuse lawngreen lime limegreen palegreen lightgreen " +
            "mediumspringgreen springgreen mediumseagreen seagreen forestgreen green " +
            "darkgreen yellowgreen olivedrab olive darkolivegreen mediumaquamarine " +
            "darkseagreen",
        cyan:
            "aqua cyan lightcyan paleturquoise aquamarine turquoise mediumturquoise " +
            "darkturquoise lightseagreen darkcyan teal cadetblue",
        blue:
            "steelblue lightsteelblue powderblue lightblue skyblue lightskyblue " +
            "deepskyblue dodgerblue cornflowerblue royalblue blue mediumblue darkblue " +
            "navy midnightblue",
        brown:
            "cornsilk blanchedalmond bisque navajowhite wheat burlywood tan rosybrown " +
            "sandybrown goldenrod darkgoldenrod peru chocolate saddlebrown sienna brown " +
            "maroon",
        white:
            "white snow honeydew mintcream azure aliceblue ghostwhite whitesmoke " +
            "seashell " +
            "beige oldlace floralwhite ivory antiquewhite linen lavenderblush mistyrose",
        gray:
            "gainsboro lightgray lightgrey silver darkgray darkgrey gray grey dimgray " +
            "dimgrey lightslategray lightslategrey slategray slategrey darkslategray " +
            "darkslategrey",
        black: "black",
    }
    const map = new Map<string, string>()
    for (const [family, list] of Object.entries(groups))
        for (const word of list.split(" ")) map.set(word, family)
    return map
})()

/** The name without a trailing `(...)`, as the rules read it. */
const withoutTag = (name: string): string => name.replace(/\s*\(.*\)$/, "")

/** The family the last word of a name gives (`dark pink`, `sea teal`), if any. */
function familyOfLastWord(name: string): string | undefined {
    const parts = withoutTag(name)
        .toLowerCase()
        .split(/\s+/)
        .filter((w) => w !== "")
    const last = parts.at(-1)
    if (last === undefined) return undefined
    const word = last.replaceAll("grey", "gray")
    if (FAMILY_CYAN_WORDS.includes(word)) return "cyan"
    return isFamily(word) ? word : undefined
}

/** A reference of the families: its colour in Lab, its family and its weight. */
interface Reference {
    lab: [number, number, number]
    family: string
    weight: number
}

/**
 * The references of the families: the CSS keywords, the ISCC-NBS centres, and the colours
 * of the xkcd colour survey and of Resene whose name ends in a family word (a name the
 * crowd or the paint maker gave: `hot pink`, `sky blue`).
 */
function references(sets: readonly ColourSet[]): Reference[] {
    const refs: Reference[] = []
    const rowsOf = (tag: string) => sets.find((s) => s.set === tag)?.colours ?? []
    for (const row of rowsOf("css")) {
        const family = CSS_FAMILY_OF_KEYWORD.get(row.name.toLowerCase())
        if (family !== undefined)
            refs.push({
                lab: labOf(rgbOf(row.hex)),
                family,
                weight: FAMILY_STANDARD_WEIGHT,
            })
    }
    for (const row of rowsOf("nbs-iscc"))
        refs.push({
            lab: labOf(rgbOf(row.hex)),
            family: nbsFamilyOfName(row.raw ?? row.name.replaceAll(" ", "")),
            weight: FAMILY_STANDARD_WEIGHT,
        })
    for (const row of [...rowsOf("xkcd"), ...rowsOf("resene")]) {
        const family = familyOfLastWord(row.name)
        if (family !== undefined)
            refs.push({ lab: labOf(rgbOf(row.hex)), family, weight: 1.0 })
    }
    return refs
}

/** The family of a colour by its hue, saturation and lightness alone (the first rules). */
function ruleFamily(c: Rgb8): string {
    const [h, s, l] = hslOf(c)
    if (l < FAMILY_BLACK_LIGHTNESS) return "black"
    if (l > FAMILY_WHITE_LIGHTNESS) return "white"
    if (s < FAMILY_NEUTRAL_SATURATION) return "gray"
    const band =
        h >= 345
            ? "red"
            : (FAMILY_HUE_BANDS.find(([edge]) => h < edge) as [number, string])[1]
    if (band === "magenta") {
        if (l >= FAMILY_PINK_LIGHTNESS) return "pink"
        if (h < FAMILY_CRIMSON_HUE) return "purple"
        if (s >= FAMILY_CRIMSON_SATURATION) return "red"
        return l < FAMILY_CRIMSON_BROWN_LIGHTNESS ? "brown" : "purple"
    }
    if (band === "red") {
        if (l > FAMILY_LIGHT_RED_LIGHTNESS) return "pink"
        const dark = l < FAMILY_BROWN_LIGHTNESS && s < FAMILY_DARK_RED_SATURATION
        return dark ? "brown" : "red"
    }
    if (band === "orange") {
        if (l < FAMILY_BROWN_LIGHTNESS) return "brown"
        const muted =
            s < FAMILY_MUTED_ORANGE_SATURATION && l < FAMILY_MUTED_ORANGE_LIGHTNESS
        return muted ? "brown" : "orange"
    }
    if (band === "yellow") return l < FAMILY_OLIVE_LIGHTNESS ? "green" : "yellow"
    return band
}

/**
 * The family of a colour: the weighted vote of the nearest references (each counts
 * `weight / (distance + 1)`), or the hue rules when no reference is near.
 */
function computedFamily(c: Rgb8, refs: readonly Reference[]): string {
    const lab = labOf(c)
    const distances = refs.map((r) =>
        Math.sqrt(r.lab.reduce((sum, v, i) => sum + (lab[i] as number - v) ** 2, 0)),
    )
    const nearest = distances
        .map((d, i) => [d, i] as const)
        .sort((a, b) => a[0] - b[0] || a[1] - b[1])
        .slice(0, FAMILY_NEIGHBOUR_COUNT)
    if ((nearest[0] as readonly [number, number])[0] > FAMILY_NBS_MAX_DISTANCE)
        return ruleFamily(c)
    const votes = new Map<string, number>()
    for (const [d, i] of nearest) {
        const ref = refs[i] as Reference
        votes.set(ref.family, (votes.get(ref.family) ?? 0) + ref.weight / (d + 1))
    }
    let best = ""
    let most = Number.NEGATIVE_INFINITY
    for (const [family, weight] of votes)
        if (weight > most) {
            best = family
            most = weight
        }
    return best
}

/**
 * The family of the entry `name` with colour `c`: the family its last word names (`dark
 * brown`, `light pink`; `grey` is gray) when that is the computed family or one next to
 * it, else the computed family.
 */
function familyOf(name: string, c: Rgb8, refs: readonly Reference[]): string {
    const computed = computedFamily(c, refs)
    const parts = withoutTag(name)
        .toLowerCase()
        .split(/\s+/)
        .filter((w) => w !== "")
    const h = (hslOf(c) as [number, number, number])[0]
    const named = isFamily((parts.at(-1) as string).replaceAll("grey", "gray"))
    if (
        !named &&
        ["purple", "pink", "brown", "orange"].includes(computed) &&
        (h >= 325 || h < 20) &&
        parts.some((w) => FAMILY_RED_WORDS.includes(w))
    )
        return "red"
    const lastWord = withoutTag(name)
        .split(/\s+/)
        .filter((w) => w !== "")
        .at(-1) as string
    const word = lastWord.toLowerCase().replaceAll("grey", "gray")
    if (!isFamily(word)) return computed
    const near = word === computed || (FAMILY_NEIGHBOURS[computed] ?? []).includes(word)
    return near ? word : computed
}

/** The family of every row of every set, by set and row. */
export function familiesOfSets(
    sets: readonly ColourSet[],
    index: ColourIndex,
): Map<string, string[]> {
    const refs = references(sets)
    const { placed } = mergeColourSets(sets, index)
    const finalName = new Map(placed.map((p) => [`${p.set}\u0000${p.row}`, p.name]))
    const result = new Map<string, string[]>()
    for (const { set, colours } of sets)
        result.set(
            set,
            colours.map((row, at) => {
                if (isExcluded(row.name, index)) return ""
                const name =
                    finalName.get(`${set}\u0000${at}`) ?? baseName(set, row.name, index)
                return familyOf(name, rgbOf(row.hex), refs)
            }),
        )
    return result
}

function main(): number {
    const args = process.argv.slice(2)
    const check = args.includes("--check")
    const compareAt = args.indexOf("--compare")
    const compareFile = compareAt >= 0 ? args[compareAt + 1] : undefined
    const index = colourIndex()
    const sets = colourSets()
    const families = familiesOfSets(sets, index)
    const counts = new Map<string, number>()
    let stale = 0
    for (const set of sets) {
        const file = assetPath("data", "colour-sets", `${set.set}.jsonc`)
        const text = readFileSync(file, "utf-8")
        const edits: Edit[] = []
        const have = families.get(set.set) as string[]
        set.colours.forEach((row, at) => {
            const family = have[at] as string
            if (family !== "") counts.set(family, (counts.get(family) ?? 0) + 1)
            if (row.family === family) return
            stale++
            edits.push(
                ...modify(text, ["colours", at, "family"], family, {
                    formattingOptions: { insertSpaces: true, tabSize: 4, eol: "\n" },
                }),
            )
        })
        if (edits.length > 0 && !check) writeFileSync(file, applyEdits(text, edits))
    }
    console.log(`colour families: ${stale} rows ${check ? "out of date" : "written"}`)
    const perFamily = FAMILIES.map((f) => `${f} ${counts.get(f) ?? 0}`)
    console.log(`rows per family: ${perFamily.join(", ")}`)
    if (compareFile !== undefined) {
        const old = JSON.parse(readFileSync(compareFile, "utf-8")) as Record<string, string>
        const list = mergeColourSets(sets, index).list
        const different: string[] = []
        for (const entry of list) {
            const family = families.get(entry.set)?.[entry.row]
            if (old[entry.name] !== family)
                different.push(`${entry.name}: ${old[entry.name]} -> ${family}`)
        }
        const summary = `${list.length} names, ${different.length} differ`
        console.log(`compared with ${compareFile}: ${summary}`)
        for (const d of different) console.log(`  ${d}`)
    }
    return check && stale > 0 ? 1 : 0
}

if (process.argv[1]?.endsWith("colour-families.ts")) process.exit(main())
