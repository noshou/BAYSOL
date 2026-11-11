// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of store/colours.ts and of how the settings take a colour: names (any spelling),
// codes (#rgb, #rrggbb, rgb(), hsl()), lists and tuples with commas inside brackets.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { test } from "node:test"
import { readAssetJson } from "../src/core/environment.js"
import { narrow, parseSetting, pickValue } from "../src/screens/screen-rules.js"
import {
    colourFamily,
    colourHex,
    colourKey,
    colourNames,
    colourWords,
    FAMILIES,
    fold,
    looksLikeCode,
    namesOfCode,
    narrowColours,
    narrowInFamily,
    nextFamily,
    parseColourCode,
    splitTopLevel,
} from "../src/store/colours.js"
import { defaultCatalog, validateValue } from "../src/store/settings.js"
import { positionStatus } from "../src/ui/input.js"
import { fixture } from "./support/fixtures.js"

const def = (name: string) => {
    const found = defaultCatalog().get(name)
    assert.ok(found, name)
    return found
}

test("the list is lower case and unique, with no bare numbers or catalogue tags", () => {
    const names = colourNames()
    assert.ok(names.length > 4000)
    assert.ok(names.every((n) => n === n.toLowerCase()))
    assert.equal(new Set(names).size, names.length)
    // no two names are the same once case, blanks, accents and punctuation are ignored
    assert.equal(new Set(names.map(colourKey)).size, names.length)
    // no name is a bare number or starts with one, or carries a catalogue tag
    assert.ok(names.every((n) => !/^\d/.test(n) && !/\b(unk|f\.s|ana \d)/.test(n)))
    // a word of digits only is a shade after a family (`blue 500`, `gray 100 (tailwind)`)
    // or the number of a clash (`name (set 2)`), never a name on its own
    for (const n of names) {
        const bare = n.split(" ").filter((w) => /^\d+$/.test(w))
        if (bare.length > 0)
            assert.match(n, /^[a-z' -]+ (tint |shade )?\d+( \([a-z -]+\))?$|\(.* \d+\)$/, n)
    }
    for (const n of ["crimson", "darkorange", "gray20", "black", "antiquewhite4"])
        assert.ok(names.includes(n), n)
    // a name two sets share with two colours is kept by both: the set is the tag
    assert.ok(names.includes("green") && names.includes("green (xkcd)"))
    assert.ok(names.includes("green (x11)"))
    assert.ok(names.includes("fip red") && names.includes("yellow (fed id prog)"))
    // no name has a dotted abbreviation (the Federal Identity Program is `fed id prog`)
    assert.ok(names.every((n) => !/\b[a-z]{1,3}\.(?: |$)/.test(n)))
})

test("every listed name shows the colour the file gives it", () => {
    const file = readAssetJson<Record<string, string>>("data", "colours.json")
    for (const [name, hex] of Object.entries(file)) {
        assert.equal(colourHex(name), hex, name)
        // any case of the name finds the same colour
        assert.equal(colourHex(name.toUpperCase()), hex, name)
    }
})

test("the CSS names have the CSS colour (what Colors.jl gives them)", () => {
    assert.equal(colourHex("crimson"), "#dc143c")
    assert.equal(colourHex("Green"), "#008000")
    assert.equal(colourHex("grey"), "#808080")
    assert.equal(colourHex("gray"), "#808080")
    assert.equal(colourHex("rebeccapurple"), "#663399")
    assert.equal(colourHex("antiquewhite4"), "#8b8378")
    assert.equal(colourHex("nope"), undefined)
    // the other sets keep their own colour under a tagged name
    assert.equal(colourHex("green (x11)"), "#00ff00")
    assert.equal(colourHex("grey (x11)"), "#bebebe")
})

test("all 148 CSS names are in the list with the colour of the W3C table", () => {
    const julia = readAssetJson<string[]>("data", "colour-julia.json")
    const table = readFileSync(
        new URL("../../dev/data/colours/css148.txt", import.meta.url),
        "utf8",
    )
        .split("\n")
        .filter((line) => line.trim() !== "")
        .map((line) => line.trim().split(/\s+/) as [string, string])
    assert.equal(table.length, 148)
    // the names Julia reads (CSS and X11) are all listed, with the colour the list gives
    for (const [name, hex] of table) {
        assert.equal(colourHex(name), hex, name)
        assert.ok(julia.includes(name), name)
    }
    for (const name of julia) assert.ok(colourNames().includes(name), name)
})

test("codes: #rgb, #rrggbb, rgb(), hsl()", () => {
    assert.equal(parseColourCode("#FF0000"), "#ff0000")
    assert.equal(parseColourCode("#f00"), "#ff0000")
    assert.equal(parseColourCode(" rgb(255, 0, 0) "), "#ff0000")
    assert.equal(parseColourCode("rgb(0,128,255)"), "#0080ff")
    assert.equal(parseColourCode("hsl(0, 100%, 50%)"), "#ff0000")
    assert.equal(parseColourCode("hsl(120, 100%, 25%)"), "#008000")
    assert.equal(parseColourCode("cmyk(0%, 100%, 100%, 0%)"), "#ff0000")
    const bads = ["#ff00", "#gggggg", "rgb(1,2)", "rgb(256,0,0)", "hsl(0,50,50)", "hsl(x)"]
    for (const bad of [...bads, "cmyk(0,0,0,0)"]) {
        assert.equal(parseColourCode(bad), undefined, bad)
        assert.equal(colourHex(bad), undefined, bad)
    }
    assert.equal(colourHex("rgb(10, 20, 30)"), "#0a141e")
    assert.ok(looksLikeCode("rgb(") && looksLikeCode("#12") && !looksLikeCode("red"))
})

test("typing finds the text anywhere in a name, best matches first", () => {
    const names = [
        "Abbey",
        "Abbey (Xkcd)",
        "Sky Blue",
        "Brown",
        "Brown (Xkcd)",
        "brown1",
        "Crimson",
        "Dark Brown",
        "Light-Brown",
        "saddlebrown",
        "Zebrown Stripe",
    ]
    // exact, then starts with, then a word starts with, then anywhere; each alphabetical
    assert.deepEqual(narrowColours(names, "brown"), [
        "Brown",
        "Brown (Xkcd)",
        "brown1",
        "Dark Brown",
        "Light-Brown",
        "saddlebrown",
        "Zebrown Stripe",
    ])
    assert.deepEqual(narrowColours(names, "BROWN"), narrowColours(names, "brown"))
    assert.deepEqual(narrowColours(names, "dark-brown"), ["Dark Brown"])
    assert.deepEqual(narrowColours(names, "abbey xkcd"), ["Abbey (Xkcd)"])
    assert.deepEqual(narrowColours(names, "(xkcd)"), ["Abbey (Xkcd)", "Brown (Xkcd)"])
    assert.deepEqual(narrowColours(names, "sky_blue"), ["Sky Blue"])
    assert.deepEqual(narrowColours(names, "rim"), ["Crimson"])
    assert.deepEqual(narrowColours(names, "zzz"), [])
    assert.deepEqual(narrowColours(names, ""), names)
    assert.deepEqual(narrow(names, "abb"), ["Abbey", "Abbey (Xkcd)"])
})

test("the real list: brown finds every name that has brown in it", () => {
    const all = colourNames()
    const found = narrowColours(all, "brown")
    const has = all.filter((n) => colourKey(n).includes("brown"))
    assert.deepEqual([...found].sort(), [...has].sort())
    assert.ok(found.length > 30)
    // the exact name leads, and names that merely contain it come after those that start
    assert.equal(found[0]?.toLowerCase(), "brown")
    const firstInside = found.findIndex((n) => !n.toLowerCase().startsWith("brown"))
    assert.ok(found.slice(firstInside).every((n) => !n.toLowerCase().startsWith("brown")))
})

test("a list and a tuple split at the commas outside brackets", () => {
    assert.deepEqual(splitTopLevel("rgb(1, 2, 3), 0.6"), ["rgb(1, 2, 3)", "0.6"])
    assert.deepEqual(colourWords("red blue"), ["red", "blue"])
    assert.deepEqual(colourWords("green (xkcd), red"), [
        "green (xkcd)",
        "red",
    ])
    assert.deepEqual(colourWords("hsl(0, 100%, 50%) #00f"), ["hsl(0, 100%, 50%)", "#00f"])
    assert.deepEqual(colourWords("indian red"), ["indian red"])
})

test("a setting keeps a CSS name or a code, any other name becomes hex", () => {
    const one = def("PLOT_COLOUR_MAP")
    const typed = ["crimson", "Sky Blue", "#f00", "rgb(1, 2, 3)", "hsl(10, 50%, 50%)"]
    for (const text of typed) {
        const picked = pickValue("colour", colourNames(), text, undefined)
        assert.deepEqual(picked, { value: text })
        assert.equal(validateValue(one, text).ok, true, text)
    }
    // Julia reads the CSS and X11 names and the codes, so those are kept; the rest
    // become hex
    assert.deepEqual(validateValue(one, "Crimson"), { ok: true, value: "crimson" })
    assert.deepEqual(validateValue(one, "sky blue"), { ok: true, value: "skyblue" })
    assert.deepEqual(validateValue(one, "antiquewhite4"), {
        ok: true,
        value: "antiquewhite4",
    })
    assert.deepEqual(validateValue(one, "nunavut yellow"), { ok: true, value: "#e7a615" })
    assert.deepEqual(validateValue(one, "green (x11)"), { ok: true, value: "#00ff00" })
    assert.deepEqual(validateValue(one, " rgb(1, 2, 3) "), {
        ok: true,
        value: "rgb(1, 2, 3)",
    })
    assert.deepEqual(pickValue("colour", [], "rgb(1,2)", undefined), {
        error: "not a colour code",
    })
    assert.deepEqual(pickValue("colour", [], "xyz", "Crimson"), { value: "Crimson" })
    assert.equal(validateValue(one, "rgb(1,2)").ok, false)
    assert.deepEqual(validateValue(one, "green (xkcd)"), { ok: true, value: "#15b01a" })
})

test("a tuple and a list of colours may hold codes with commas", () => {
    const tuple = def("PLOT_COLOUR_ERRORBAR")
    assert.deepEqual(parseSetting(tuple, "rgb(10, 20, 30), 0.5"), {
        value: ["rgb(10, 20, 30)", 0.5],
    })
    const list = def("PLOT_COMPARE_COLOURS")
    assert.deepEqual(parseSetting(list, "Sky Blue, hsl(0, 100%, 50%), #00f"), {
        value: ["skyblue", "hsl(0, 100%, 50%)", "#00f"],
    })
    assert.deepEqual(parseSetting(list, "nunavut yellow, red"), {
        value: ["#e7a615", "red"],
    })
    assert.ok("error" in parseSetting(list, "red, nonsense"))
})

test("opening the list and filtering ~2,000 names stays fast (a generous bound)", () => {
    const started = performance.now()
    const names = colourNames()
    const typedTexts = ["", "b", "br", "brown", "dark brown", "#a52a2a", "hsl(0, 59%, 40%)"]
    for (const typed of typedTexts) {
        narrowColours(names, typed)
        namesOfCode(typed)
    }
    // measured: about 3 ms to read the file, 1.5 ms for each narrowing; far above that
    assert.ok(performance.now() - started < 1000)
})

test("search ignores accents: quebec finds québec; the name keeps its accents", () => {
    const typed = "Québec Côte d'Ivoire München Straße Æsir Œuvre Ørsted Đorđe Łódź"
    assert.equal(
        fold(typed),
        "quebec cote d'ivoire munchen strasse aesir oeuvre orsted dorde lodz",
    )
    const names = ["québec blue", "quebec green", "côte d'ivoire", "münchen", "straße"]
    assert.deepEqual(narrowColours(names, "quebec"), ["québec blue", "quebec green"])
    assert.deepEqual(narrowColours(names, "québec"), ["québec blue", "quebec green"])
    assert.deepEqual(narrowColours(names, "cote d'ivoire"), ["côte d'ivoire"])
    assert.deepEqual(narrowColours(names, "munchen"), ["münchen"])
    assert.deepEqual(narrowColours(names, "STRASSE"), ["straße"])
    const orsted = narrowColours(["orsted x", "ørsted"], "orsted")
    assert.deepEqual(orsted, ["ørsted", "orsted x"])
    // the ranking is the same: exact, starts with, a word starts with, inside
    const list = ["dark quebec", "xquebecx", "quebec", "québec blue"]
    const ranked = narrowColours(list, "quebec")
    assert.deepEqual(ranked, ["quebec", "québec blue", "dark quebec", "xquebecx"])
    // a typed unaccented name resolves to the stored accented one
    assert.ok(colourHex("québec blue") !== undefined)
    assert.equal(colourHex("quebec blue"), colourHex("québec blue"))
})

test("the merged sets: short places, expanded pigments, identifiers, exclusions", () => {
    const names = colourNames()
    // short forms of long place names, and no dotted abbreviation
    assert.ok(names.some((n) => n.startsWith("nfld ")))
    assert.ok(names.every((n) => !n.includes("newfoundland and labrador")))
    assert.ok(names.every((n) => !n.includes("northwest territories")))
    assert.ok(names.includes("us virgin islands gold"))
    // the Winsor & Newton pigment abbreviations are written out
    assert.ok(names.includes("cadmium green light"))
    assert.ok(names.includes("chrome yellow light"))
    assert.ok(names.every((n) => !/^(cd|co|cr|mn|perm|trans) /.test(n)))
    // the government design tokens are `govcanada`, never `gc`
    assert.ok(names.includes("govcanada blue 500"))
    assert.ok(names.every((n) => !n.startsWith("gc ")))
    // the Federal Identity Program is `fed id prog` in the brackets, and search finds it
    const fip = names.filter((n) => n.endsWith("(fed id prog)"))
    assert.ok(fip.length > 0)
    assert.ok(narrowColours(names, "fed id prog").some((n) => fip.includes(n)))
    // the owner's exclusions (EXCLUDED_WORDS of the harvest) are in no name
    assert.ok(names.every((n) => !/israel/.test(n)))
    // Chad's national entries are `tchad ...`; no name starts with `chad `
    assert.ok(names.includes("tchad gold"))
    assert.ok(names.every((n) => !/^chad /.test(n)))
    // Palestinian entries stay, with their full names (never the abbreviations)
    assert.ok(names.includes("palestine crimson"))
    assert.ok(names.includes("palestine polytechnic blue"))
    assert.ok(names.every((n) => !/^ppu /.test(n) && !/\b(pna|plo)\b/.test(n)))
    // a state that shares a name with a country, a state of Brazil
    assert.ok(names.some((n) => n.startsWith("georgia usa ")))
    assert.ok(names.some((n) => n.startsWith("amazonas brazil ")))
})

test("every name has exactly one family, and all twelve families are used", () => {
    const names = colourNames()
    const file = readAssetJson<Record<string, string>>("data", "colour-families.json")
    // one tag for each name of the list, and no tag for anything else
    assert.deepEqual(Object.keys(file).sort(), [...names].sort())
    for (const family of Object.values(file)) assert.ok(FAMILIES.includes(family as never))
    assert.equal(FAMILIES.length, 12)
    for (const family of FAMILIES)
        assert.ok(
            names.some((n) => colourFamily(n) === family),
            family,
        )
    // a name of a family word is in it unless its colour is far from it, a code has the
    // family of the first name with its colour
    assert.equal(colourFamily("crimson"), "red")
    assert.equal(colourFamily("#dc143c"), "red")
    assert.equal(colourFamily("nope"), undefined)
    assert.equal(colourFamily("#123457"), undefined)
})

test("the family counts are the golden ones (update deliberately)", () => {
    const golden = fixture("colours/family-counts.json") as {
        total: number
        families: Record<string, number>
    }
    const names = colourNames()
    assert.equal(names.length, golden.total)
    const counts: Record<string, number> = {}
    for (const family of FAMILIES)
        counts[family] = names.filter((n) => colourFamily(n) === family).length
    assert.deepEqual(counts, golden.families)
})

test("the family filter narrows the search and the counter counts what is left", () => {
    const names = colourNames()
    assert.deepEqual(narrowInFamily(names, "blue", "all"), narrowColours(names, "blue"))
    const purple = narrowInFamily(names, "blue", "purple")
    assert.ok(purple.length > 0 && purple.length < narrowColours(names, "blue").length)
    assert.ok(purple.every((n) => colourFamily(n) === "purple" && /blue/.test(n)))
    // no text: the whole family
    const pink = narrowInFamily(names, "", "pink")
    assert.deepEqual(pink, names.filter((n) => colourFamily(n) === "pink"))
    // the counter reads `n of m` of the filtered list
    assert.equal(positionStatus(0, pink.length), `1 of ${pink.length}`)
    const n = pink.length
    assert.equal(positionStatus(n - 1, n), `${n} of ${n}`)
    // the key goes through all, each family and back
    let filter = nextFamily("all")
    assert.equal(filter, "red")
    for (let i = 1; i < FAMILIES.length; i++) filter = nextFamily(filter)
    assert.equal(filter, "white")
    assert.equal(nextFamily(filter), "all")
})

test("a clash tag shows its set with blanks (hyphens only in the standard's name)", () => {
    const names = colourNames()
    const tags = new Set(
        names.flatMap((n) => {
            const m = /\(([^)]*)\)$/.exec(n)
            return m?.[1] === undefined ? [] : [m[1]]
        }),
    )
    for (const tag of ["paul tol", "nbs iscc", "fed id prog", "fed-std-595c", "xkcd"])
        assert.ok(tags.has(tag), tag)
    // no other tag has a hyphen
    for (const tag of tags) if (tag !== "fed-std-595c") assert.ok(!tag.includes("-"), tag)
    // the search finds a tag with or without the hyphen
    const spaced = narrowColours(names, "paul tol")
    assert.ok(spaced.length > 0)
    assert.deepEqual(narrowColours(names, "paul-tol"), spaced)
    assert.deepEqual(narrowColours(names, "nbs-iscc"), narrowColours(names, "nbs iscc"))
})
