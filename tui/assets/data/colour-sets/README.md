<!-- SPDX-License-Identifier: LGPL-3.0-or-later -->

# Colour names and their licences

The colour data of the terminal interface: one `<set>.jsonc` file per source set, the merge rules
in `index.jsonc`. Read by `tui/src/store/colours.ts`; the `family` of every row is written by `tui/dev/colour-families.ts` (run it with
`npx tsx tui/dev/colour-families.ts` after a change of the rules or a new row; `--check` only
tests). The sets are edited by hand; there is no generated file.

## File format

A set file is JSONC (comments and one row per line; trailing commas are not allowed). Comment
lines before the object are the notices of the source, kept verbatim (licences, copyright text).

```jsonc
{
    "set": "css",                // the tag: the file name, and the `(set)` of a clash name
    "title": "...",              // what the set is
    "licence": "...",            // licence or terms, as seen
    "url": "https://...",        // the source of the set
    "notes": "...",              // optional
    "colours": [
        {"name": "aliceblue", "hex": "#f0f8ff", "family": "white"},
        // optional per row: "raw" (the name as the source wrote it, where `name` was cleaned:
        // nbs-iscc, paul-tol), "verified": false (only when false), "url" (the source of this
        // row; absent means the url of the set)
    ]
}
```

- `name` is the name before the merge (the list may add `(set)` or `(set 2)` on a clash), `hex`
  is `#rrggbb`, `family` is one of `red`, `orange`, `yellow`, `green`, `cyan`, `blue`, `purple`,
  `pink`, `brown`, `gray`, `black`, `white` and is written by `colour-families.ts` (do not edit it
  by hand; the families of the list are those of the rows).

## `index.jsonc`

The merge data: `order` (the priority of the sets, what wins a shared name: css, x11, fed-std-595c,
tailwind, xkcd, the header-standard sets, then nbs-iscc, winsor-newton, crayola, paul-tol,
resene), `julia` (the sets whose plain names Colors.jl reads), `identifiers`, `hyphenated`,
`common`, `renames`, `placeAbbreviations`, `nationalNames`, `winsorWords` (the name rules) and
`excludedWords` (see "Left out by the owner" below). Adding a set means a new file and its tag in
`order`.

The names the colour picker of the terminal interface offers come from the sets below, one file each in this folder, `<set>.jsonc`: the ten third-party sets (`css`, `x11`, `fed-std-595c`, `tailwind`, `xkcd`, `nbs-iscc`, `winsor-newton`, `crayola`, `paul-tol`, `resene`, whose own comment lines are kept as the sources wrote them) and the header-standard sets (every entry has its source URL, its licence or terms and a `verified` flag; `false` means the value came from a search summary of the source page, not a full read). The loader `tui/src/store/colours.ts` merges them in memory (about 150 ms on first use, then cached) with the rules of `index.jsonc`; nothing is generated any more, and the old generated files `colours.json`, `colour-families.json` and `colour-julia.json` are gone. The names that Julia's Colors.jl reads as the same colour (the CSS and X11 names) are the names of the sets listed under `julia` in `index.jsonc`. Names are lower case (accents kept: `québec blue`; a search or a typed name without the accent finds it); Tailwind `blue.500` is `blue 500`. A colour value is a fact; the terms below are what each source page showed. BAYSOL is LGPL and non-commercial; a registered wordmark or brand is named only for its colours.

How the list is made, in order: a name two sets share with the same 8-bit colour is listed once; with two colours the first set below keeps the plain name and the other is `name (set)` (`green`, `green (x11)`, `green (xkcd)`). Then the duplicate pass (`mergeColourSets` of the loader reports what it took out): of names that are the same once case, blanks, `-`, `_` and accents are ignored the first by priority is kept; of names with the same colour all the common names are kept (any css name, a plain x11 name without a number, and a one-word name of tailwind or xkcd) and the others dropped, and a colour with no common name keeps only its shortest name. A name that was dropped but is spelled like one that was kept still finds it: a typed name falls back to the first name with the same letters and digits (accents ignored).

| set | entries read | what | licence or terms (as seen) | source |
|---|---|---|---|---|
| `css` | 148 | the CSS named colours (what Colors.jl gives them, so `crimson`, `green` and `grey` keep the CSS colour) | W3C specification names | <https://www.w3.org/TR/css-color-4/#named-colors> |
| `x11` | 752 | the X11 colour names | MIT (X licence) | <https://gitlab.freedesktop.org/xorg/app/rgb> |
| `fed-std-595c` | 193 | U.S. Federal Standard 595C, colours used in government procurement (aliases cleaned: no ANA/unk/int'l/number tags; colour from the Illuminant-C or D65 column, read as D65) | federal standard; copyright notice of Aubrey Jaffer below | <https://assist.daps.dla.mil/quicksearch/basic_profile.cfm?ident_number=53815> and the data of NamedColors.jl |
| `tailwind` | 242 | the Tailwind CSS palette (`blue 500`) | MIT | <https://tailwindcss.com/docs/customizing-colors> |
| `xkcd` | 949 | the xkcd colour survey names | CC0 | <https://xkcd.com/color/rgb/> |
| `fip` | 11 | Canadian Federal Identity Program colours | Government of Canada, Treasury Board Secretariat, Design Standard for the Federal Identity Program (Tables 1 and 2, modified 2021-12-13); the page states no licence, only a Terms link; colour values are facts | <https://www.canada.ca/en/treasury-board-secretariat/services/government-communications/federal-identity-program/technical-specifications/official-symbols/colour-values.html> |
| `eu` | 2 | European Union reflex blue and yellow (Regulation (EU) 2014/821 Annex II) | Open Government Licence v3.0 (stated on page; (c) Crown) | <https://www.legislation.gov.uk/eur/2014/821/annex/II> |
| `bc` | 2 | Government of British Columbia design tokens | Apache-2.0 (npm package @bcgov/design-tokens 5.1.0, LICENSE verified; values read from css/variables.css) | <https://www.npmjs.com/package/@bcgov/design-tokens> |
| `ontario` | 37 | Ontario Design System (Government of Ontario) | Apache-2.0 (npm package version 9.2.2; values read from its scss tokens) | <https://www.npmjs.com/package/@ongov/ontario-design-system-global-styles> |
| `alberta` | 3 | Government of Alberta design tokens | Apache-2.0 (npm package version 2.12.9, LICENSE file verified; tokens.css) | <https://www.npmjs.com/package/@abgov/design-tokens> |
| `govcanada` | 63 | Government of Canada Design System colour tokens (`govcanada blue 500`: the family and its step, 50 and every 100; the primary and vivid blues) | MIT (npm package @gcds-core/tokens 1.6.0; Canadian Digital Service) | <https://www.npmjs.com/package/@gcds-core/tokens> |
| `utah` | 6 | State of Utah design tokens | Apache 2.0 (npm package version 5.3.0 licence field; tokens read from css) | <https://www.npmjs.com/package/@utahdts/utah-design-system> |
| `quebec` | 1 | Gouvernement du Québec visual identity (infolettre PIV No. 8, 2020) | no licence text in the document; colour values are facts | <https://www.piv.gouv.qc.ca/fileadmin/documents/infolettres/No.8_Ete_2020.pdf> |
| `yukon` | 6 | Government of Yukon brand standards, colour palette | (c) Government of Yukon; no open licence seen (page 403 live, read from archive); colour values are facts | <https://guide.yukon.ca/en/content-and-design/brand-standards/colour-and-palettes-print> |
| `saskatchewan` | 11 | Government of Saskatchewan digital design system 2021 | Crown copyright; may be reproduced for non-commercial purposes (saskatchewan.ca/copyright); commercial use needs written permission | <https://taskroom.saskatchewan.ca/-/media/project/taskroom/documents/policy/digital-design-system-2021.pdf> |
| `pei` | 6 | Prince Edward Island wordmark guidelines (DRAFT document) | DRAFT document; the wordmark is a registered trademark, permission needed to reproduce it; colour values are facts | <https://www.princeedwardisland.ca/sites/default/files/publications/wordmark_guidelines.pdf> |
| `nunavut` | 7 | Government of Nunavut visual identity guidelines: Authentic Nunavut arts brand (not the government identity) | Authentic Nunavut is a registered trademark (arts brand); permission-based use; colour values are facts | <https://www.gov.nu.ca/sites/default/files/publications/2023-03/visual_identity_guidelines.pdf> |
| `ns` | 9 | Government of Nova Scotia visual identity guide 2020 | no licence text read; colour values are facts | <https://nsgov.github.io/patternlibrary/docs/NS-Visual-Identity-Guide-2020.pdf> |
| `nwt` | 14 | Government of the Northwest Territories brand standards | no licence text read; colour values are facts | <https://www.eia.gov.nt.ca/sites/eia/files/content/gnwt_vip_standards3.1.pdf> |
| `govuk` | 67 | GOV.UK Design System colour palette (`govuk blue tint 25`) | Crown copyright; values are facts | <https://design-system.service.gov.uk/styles/colour/> |
| `royal-navy` | 55 | Royal Navy digital design system colour tokens (`royal navy action blue 700`: user-interface tokens, not the heraldic navy blue; the colour words of the extra palettes are our labels) | Crown copyright; no licence stated on the page; values are facts | <https://design-system.navy.digital.mod.uk/tokens/colour-tokens> |
| `mod-uk` | 3 (3 unverified) | UK Ministry of Defence design system brand colours (seen only in a search snippet, the page was not reachable) | Crown copyright; values are facts | <https://design-system.service.mod.gov.uk/styles/colour> |
| `flags-national` | 1062 | colours of the national flags of the UN member and observer states (`ghana gold`): the value of the flag specification, Pantone or CMYK converted where the source gives no RGB | read from Wikipedia flag articles (text CC BY-SA, not copied; 343 entries) and flagcolorcodes.com (secondary, 185 entries; 520 entries from the Yanseku flag palette, 14 from government design systems); where both give a colour, Wikipedia is the value and the source; values are facts | the Wikipedia article `Flag of <country>` or the flagcolorcodes.com page of each entry, in its row (`url`) |
| `flags-subnational` | 1288 | colours of the flags of provinces, states, regions and the like (`texas red`, `amazonas brazil dark green`; the colour word is the nearest plain word of our vocabulary, or the one that fits the source's own label) | as `flags-national` (82 Wikipedia, 1206 flagcolorcodes.com, 0 government pages) | the source of each entry, in its row (`url`) |
| `intl` | 14 (1 unverified) | International bodies: UN, EU, WHO, UNESCO, NATO, UNHCR, UNDP, ASEAN brand pages | brand-use terms not checked; colour values are facts | each entry's own `url` in the set file |
| `univ-us` | 46 (10 unverified) | US university brand pages | brand-use terms not checked; colour values are facts | each entry's own `url` in the set file |
| `univ-ca` | 30 (1 unverified) | Canadian university brand pages | brand-use terms not checked; colour values are facts | each entry's own `url` in the set file |
| `univ-world` | 21 (18 unverified) | University brand pages outside the US and Canada | brand-use terms not checked; colour values are facts | each entry's own `url` in the set file |
| `univ-palestine` | 13 (4 unverified) | Palestinian university brand colours: arab american uni University (5), Palestine Polytechnic University (4, named `palestine polytechnic <colour>`), Birzeit University (4, from the CMYK of a third-party brand mirror, source_type other) | brand-use terms not checked; colour values are facts | each entry's own `url` in the set file |
| `wikipedia-colours` | 67 | pink, violet and cyan colour names of Wikipedia's lists and colour articles (the Crayola table, List of colors, Shades of pink, rose, purple, ...); names and values only | Wikipedia text is CC BY-SA 4.0 and not copied; names and colour values are facts | the page of each entry, in its row (`url`) |
| `meodai` | 956 (all unverified, secondary) | community-made colour names of meodai/color-names: purples and cyans (532 kept of 802 that fit the hue ranges; filter: letters and blanks only, at most 3 words, the last a colour word such as purple, violet, teal, aqua; 270 fanciful names such as `amethyst gem` dropped) and 424 pinks (hue 300 to 15, lightness 0.62 to 0.93, saturation at least 0.25 or a pink word; last word a pink word such as pink, rose, blush, coral; no reds; names and colours already in the list skipped) | MIT, see the notice below | <https://github.com/meodai/color-names> |
| `nbs-iscc` | 267 | NBS/ISCC colour name dictionary (Kelly and Judd, NBS Special Publication 440, 1976); the run-together names are split into words (`verydarkbluishgreen` is `very dark bluish green`; `mediumgray` too) | copyright notice of Voluntocracy below | <http://tx4.us/nbs-iscc.htm> |
| `winsor-newton` | 300 | Winsor & Newton water-colours (CIE L\*a\*b\* read as D65; the paint name, one entry per paint tone) | copyright notice of Aubrey Jaffer below | the data of NamedColors.jl |
| `crayola` | 196 | Crayola crayon colours (the plain name) | Wikipedia list of Crayola crayon colors, CC BY-SA 3.0; the names are Crayola's | <https://en.wikipedia.org/wiki/List_of_Crayola_crayon_colors> |
| `paul-tol` | 72 | Paul Tol's colour schemes (run-together names split, typos fixed: `brightgreem`, `highconstrastblue`, `decidous`, `foest`; the land-cover colours are `land cover water` and so on) | no licence stated in the file; SRON; transcribed for NamedColors.jl by Ronny Bergmann | <https://personal.sron.nl/~pault/> |
| `resene` | 1383 | Resene Paints colour list (`Resene Red Beech` is `red beech`; a name another set has is `name (resene)`) | copyright notice of Resene Paints Ltd below | <http://www.resene.co.nz> |

Notes: Federal Standard 595C names are cleaned to plain descriptive ones (`beechcraft white`, `dot highway brown`); Saskatchewan is Crown copyright (non-commercial reuse allowed, commercial use needs written permission); the PEI document is a DRAFT and the wordmark a registered trademark; the Nunavut colours belong to the Authentic Nunavut arts brand, not the government identity (`nunavut <colour>`); Québec's `#095797` seen earlier is not in the source document, `#325EA8` is. The sets `x11`, `tailwind`, `xkcd`, `fed-std-595c`, `nbs-iscc` (converted from Latin-1 to UTF-8), `winsor-newton`, `crayola`, `paul-tol` and `resene` are copies of the data of the package NamedColors.jl (<https://github.com/JuliaGraphics/NamedColors.jl>, MIT; its data directory is licensed per file). The five sets after `univ-world` have the lowest priority, Resene last. A name that is the same as an earlier one once blanks, `-`, `_` and accents are ignored counts as the same name for the clash rule, so `dark blue` after `darkblue` with another colour is `dark blue (set)` and is kept.

### Notice for U.S. Federal Standard 595C (`fed-std-595c`)

Kept as it is in the data file (the header of `fed-std-595c.jsonc`):

```text
U.S. FEDERAL STANDARD 595C - COLORS USED IN GOVERNMENT PROCUREMENT
Copyright 2010 Aubrey Jaffer

Permission to copy this dictionary, to modify it, to redistribute it,
to distribute modified versions, and to use it for any purpose is
granted, subject to the following restrictions and understandings.

1.  Any copy made of this dictionary must include this copyright notice
in full.

2.  I have made no warranty or representation that this data is
error-free, and I am under no obligation to provide any services, by
way of maintenance, update, or otherwise.

3.  In conjunction with products arising from the use of this material,
there shall be no use of my name in any advertising, promotional, or
sales literature without prior written consent in each case.

"ASSIST-QuickSearch - Basic Profile"
```

### Notice for Resene Paints Ltd (`resene`)

Kept as it is in the data file (the header of `resene.jsonc`):

```text
Resene RGB Values List
For further information refer to http://www.resene.co.nz
Copyright Resene Paints Ltd 2001

Permission to copy this software, to modify it, to redistribute it,
to distribute modified versions, and to use it for any purpose is
granted, subject to the following restrictions and understandings.

1. Any text copy made of this dictionary must include this copyright
notice in full.

2. Any redistribution in binary form must reproduce this copyright
notice in the documentation or other materials provided with the
distribution.

3. Resene Paints Ltd makes no warranty or representation that this
dictionary is error-free, and is under no obligation to provide
any services, by way of maintenance, update, or otherwise.

4. There shall be no use of the name of Resene or Resene Paints Ltd in
any advertising, promotional, or sales literature without prior
written consent in each case.

5. These RGB colour formulations may not be used to the detriment of
Resene Paints Ltd.
```

### Notice for NBS/ISCC (`nbs-iscc`)

Kept as it is in the data file (the header of `nbs-iscc.jsonc`):

```text
NBS/ISCC Color System Centroids       http://tx4.us/nbs-iscc.htm

Copyright © 2003 Voluntocracy.  Permission is granted to copy and
distribute modified or unmodified versions of this color dictionary
provided the copyright notice and this permission notice are preserved
on all copies and the entire such work is distributed under the terms
of a permission notice identical to this one.
```

### Notice for Winsor & Newton (`winsor-newton`)

Kept as it is in the data file (the header of `winsor-newton.jsonc`): the notice of Aubrey Jaffer shown above for `fed-std-595c`, with "Copyright 2010 Aubrey Jaffer" and the same three restrictions.

### Notice for Crayola (`crayola`)

The list is from the Wikipedia article "List of Crayola crayon colors" (<https://en.wikipedia.org/wiki/List_of_Crayola_crayon_colors>), licensed CC BY-SA 3.0 (<https://creativecommons.org/licenses/by-sa/3.0/>). The colour names are Crayola's.

### Notice for Paul Tol (`paul-tol`)

The colours are from Paul Tol's notes (<https://personal.sron.nl/~pault/>, SRON), transcribed for NamedColors.jl by Ronny Bergmann (kellertuer). The file states no licence.

## Names and rules

- **Identifier of a clash.** A name two sets use for two colours is `name (set)`: the later set
  is named in the brackets, in lower-case words and no dots (`green (xkcd)`, `green (x11)`, `rose (paul tol)`: a hyphen of the tag is a blank, only `fed-std-595c` keeps its own, as the standard is written). The
  Federal Identity Program is `fed id prog` (`yellow (fed id prog)`), set by `SET_IDENTIFIERS` in
  `index.jsonc`. Search ignores punctuation, so `fed id prog` finds them.
- **Short place names** (`PLACE_ABBREVIATIONS`): `nfld` for Newfoundland and Labrador, `nwt` for the
  Northwest Territories (also `north west territories`), `us` and `dc` for `u.s.` and `d.c.`, `palestine polytechnic` for `ppu` (Palestine Polytechnic University); `pei`,
  `ns` and `nwt` are the tags of their own sets. No name has a dotted abbreviation. Chad is `tchad` in the national flag entries (`NATIONAL_NAMES`).
- **Winsor & Newton names** (`WINSOR_WORDS`): the file does not expand the pigment abbreviations, so
  they are written out: `cd` cadmium, `co` cobalt, `cr` chrome (Chrome Yellow, Chrome Green
  Deep), `mn` manganese, `perm` permanent, `trans` transparent; the misspellings `orage`, `pthalo`,
  `davys` and `paynes` are `orange`, `phthalo`, `davy's` and `payne's`. Short words left as they
  are: the agency and university acronyms (`osha`, `dot`, `nasa`, `nato`, `undp`, `ucla`, `mit`,
  `ubc`, ...), `carc` (the Federal Standard's chemical agent resistant coating, `carc aircraft red`)
  and the Resene name `aths special`.
- **Place colours** (`flags-national`, `flags-subnational`, `govcanada`...): `<place> <colour word>`,
  the word the nearest plain one of our vocabulary (CSS and X11 base names) or the one that fits the
  source's own label; two shades of one place are told apart by `dark` and `light`, never by a number.
  A state that shares its name with a country is `georgia usa`, a state of Brazil `amazonas brazil`.
- **Wikipedia first.** Where Wikipedia and flagcolorcodes.com both give a colour of the same flag,
  the Wikipedia value is used and recorded as the source. The flagcolorcodes.com values are
  secondary (`source_type: other`): that site sometimes lists the brand
  colours of a state, not its flag.
- **Pantone only.** A colour whose source gives only a Pantone number (no RGB, hex or CMYK) is not
  converted: the number is proprietary. 76 such entries (18 places) are not in the list; a CMYK
  value is converted with `255 x (1 - c) x (1 - k)`.
- **Left out by the owner.** `excludedWords` of `index.jsonc` lists words no entry may carry in its
  name; an entry of a set with one of them is not built into the list.
- **The duplicate pass** runs over every entry, places and bodies included: of the 7543 names the sets
  give, 1115 are dropped, those with the same name and those with exactly the same
  `#rrggbb`: the common names (every CSS name, a plain X11 name, a one-word Tailwind or xkcd name) are
  all kept, otherwise only the shortest name. Colours that are only close are never dropped.

### Notice for meodai/color-names (`meodai`)

The names and hex values are from the colour name list of David Aerne (meodai),
<https://github.com/meodai/color-names>, 32,005 names made by a community, under the MIT licence:
"Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, ... The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software." The list is secondary: its values are not checked against any
standard, so every entry is marked `verified: false` in its set file. Entries were taken from the file
`colornames.csv` once and the filter above applied; the file is not part of this repository.
