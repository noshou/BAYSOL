# SPDX-License-Identifier: LGPL-3.0-or-later

# Writes `tui/assets/data/colours.json`: every colour name the terminal interface
# offers for a colour setting, `"name": "#rrggbb"`, one per line, sorted by name, and
# beside it `colour-families.json` (the family of each name, one of 12, for the picker's
# filter) and `colour-julia.json`, the names of that list that Julia's Colors.jl reads
# as the same colour (the 148 CSS names and the X11 names such as `antiquewhite4`): a
# setting keeps a name of that file as it is and any other colour as `#rrggbb`. They
# are built from files of this repository only (no network, no NamedColors.jl): the
# colour sets in `dev/data/colours/` (see the README there for the sources and notices) and
# the sets of `tui/assets/data/colour-sources.json` (government, international-body
# and university colours with their sources). Run it through `bysl harvest colours`.
#
# The rules, in order:
#   1. Every source is read on its own, in priority order: `css` (the 148 colours of the
#      W3C CSS Color Module, so `crimson`, `green` and `grey` keep the CSS value Colors.jl
#      gives them), `x11`, `fed-std-595c`, `tailwind`, `xkcd`, then the sets of
#      `colour-sources.json` in the order of that file, then `nbs-iscc` (its run-together
#      names split into words), `winsor-newton`, `crayola`, `paul-tol` (typos fixed) and
#      `resene` (without its `Resene ` prefix).
#   2. A name is lower case. The same name (blanks, `-`, `_` and accents ignored) with the
#      same 8-bit colour as an earlier entry is an exact duplicate and left out; the same
#      name with another colour keeps both:
#      the first source has the plain name, the later one is `name (set)` (`name (set 2)`
#      if even that is taken).
#   3. The duplicate pass: entries whose names are the same once case, blanks, `-`, `_` and
#      accents are ignored (the first by priority stays), then each group of entries with
#      the same `#rrggbb`: the common names (every `css` name, a plain `x11` name without a
#      digit, a one-word `tailwind` or `xkcd` name) are all kept and the others dropped; a
#      group with no common name keeps its shortest name only.
#
# Usage: julia --project=<root> dev/scripts/harvest_colours.jl OUT [REPORT [BEFORE]]
# REPORT and BEFORE are .json files: what the duplicate pass dropped, the table before it.

using Colors: Colors
using JSON3

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const DATA = joinpath(ROOT, "dev", "data", "colours")
const SOURCES_FILE = joinpath(ROOT, "tui", "assets", "data", "colour-sources.json")

"A colour as three whole numbers 0 to 255."
const RGB8 = NTuple{3,Int}

"The `#rrggbb` text of a colour."
hex_of(c::RGB8) = "#" * join(string.(c; base = 16, pad = 2))

"The colour of a `#rrggbb` text."
function colour_of_hex(text::AbstractString)
    m = match(r"^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$", strip(text))
    m === nothing && error("not a #rrggbb colour: $text")
    return (
        parse(Int, m[1]; base = 16),
        parse(Int, m[2]; base = 16),
        parse(Int, m[3]; base = 16),
    )
end

# ---- name folding (the same as `fold` in
# tui/src/store/colours.ts) ----------------------------

const SPELLED = Dict(
    "ß" => "ss",
    "æ" => "ae",
    "œ" => "oe",
    "ø" => "o",
    "đ" => "d",
    "ð" => "d",
    "ł" => "l",
    "ı" => "i",
    "þ" => "th",
)

"`name` in lower case without accents."
function fold(name::AbstractString)
    text = Base.Unicode.normalize(lowercase(name), :NFD)
    text = replace(text, r"\p{M}" => "")
    return replace(text, SPELLED...)
end

"`name` folded with every character that is not a letter or a digit dropped."
key_of(name::AbstractString) = replace(fold(name), r"[^a-z0-9]" => "")

# ---- the sources read from dev/data/colours
# ---------------------------------------------------

"The lines of a file of this folder."
data_lines(file) = readlines(joinpath(DATA, file))

"A file of `r g b name` lines (X11 style): comment lines start with `!`."
function read_x11(file)
    entries = Pair{String,RGB8}[]
    for line in data_lines(file)
        (isempty(strip(line)) || startswith(line, "!")) && continue
        fields = split(line)
        length(fields) >= 4 || continue
        rgb = (parse(Int, fields[1]), parse(Int, fields[2]), parse(Int, fields[3]))
        push!(entries, strip(join(fields[4:end], " ")) => rgb)
    end
    return entries
end

"A file of `name #rrggbb` lines (the Tailwind file: `;` comments, blank separated)."
function read_tailwind(file)
    entries = Pair{String,RGB8}[]
    for line in data_lines(file)
        (isempty(strip(line)) || startswith(line, ";")) && continue
        name, code = split(line)
        push!(entries, String(name) => colour_of_hex(code))
    end
    return entries
end

"A file of `name<TAB>#rrggbb` lines (the xkcd survey)."
function read_xkcd(file)
    entries = Dict{String,RGB8}()
    for line in data_lines(file)
        isempty(strip(line)) && continue
        name, code = split(line, "\t")
        entries[String(name)] = colour_of_hex(code)
    end
    return collect(entries)
end

"The W3C CSS names: `name #rrggbb` lines."
function read_css(file)
    entries = Pair{String,RGB8}[]
    for line in data_lines(file)
        isempty(strip(line)) && continue
        name, code = split(line)
        push!(entries, String(name) => colour_of_hex(code))
    end
    return entries
end

# ---- U.S. Federal Standard 595C (an XCMS colour database by Aubrey Jaffer)
# -------------------- Each line is `number`, the colour under three illuminants, then
# the names (comma separated aliases, possibly none). The FIRST colour is the one used
# ("Illuminant-C or D65", taken as D65, the white point of sRGB: no chromatic
# adaptation). It is `CIEXYZ` (percent of the white's Y) or, for a few, `CIELAB`.

const D65_WHITE = (95.047, 100.0, 108.883)

gamma(x) = x <= 0.0031308 ? 12.92 * x : 1.055 * x^(1 / 2.4) - 0.055

function xyz_to_rgb(x, y, z)::RGB8
    x, y, z = x / 100, y / 100, z / 100
    r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
    g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
    b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
    channel(v) = clamp(floor(Int, 255 * gamma(clamp(v, 0, 1)) + 0.5), 0, 255)
    return (channel(r), channel(g), channel(b))
end

function lab_to_xyz(l, a, b)
    fy = (l + 16) / 116
    fx, fz = fy + a / 500, fy - b / 200
    inverse(t) = t^3 > 216 / 24389 ? t^3 : (116t - 16) / (24389 / 27)
    return (
        D65_WHITE[1] * inverse(fx),
        D65_WHITE[2] * (l > 8 ? fy^3 : l / (24389 / 27)),
        D65_WHITE[3] * inverse(fz),
    )
end

# Words that are only a maker or a code prefix (`misc hawker beechcraft white` is
# `beechcraft white`), and short acronyms that name an agency, not a colour.
const FED_DROP_WORDS =
    ("misc", "hawker", "int'l", "intl", "unk", "bs", "ral", "ana", "no", "navair")
const FED_ACRONYMS = (
    "dot", "osha", "nasa", "faa", "nps", "usaf", "usn", "usmc", "usda", "mil", "tt",
    "fs",
    "national parks service",
)

"Aliases whose cleaned name would lose what they mean, as `lower-case alias => name`."
const FED_RENAMES = Dict("f-4 aircraft" => "deep gray f-4 phantom")

"The plain descriptive name of an alias, or `\"\"` when nothing descriptive is left."
function fed_clean_name(alias::AbstractString)
    name = lowercase(strip(alias))
    haskey(FED_RENAMES, name) && return FED_RENAMES[name]
    name = replace(name, r"\([^)]*\)" => " ")
    name = replace(name, r"#\s*\d+" => " ")
    name = replace(name, r"\b(?:f\.s\.?|fed\.? std\.?)" => " ")
    name = replace(name, r"\b[a-z]{1,3}-[a-z]-\d+\b" => " ")
    name = replace(name, r"\b[a-z]-\d+[a-z]?\b" => " ")
    name = replace(name, r"\bana\s*\d+\b" => " ")
    name = replace(name, r"\bunk\s*\d*\b" => " ")
    name = replace(name, r"\b\d[\d./-]*[a-z]?\b" => " ")
    name = replace(name, r"[^a-z' -]" => " ")
    words = [w for w in split(name) if !(w in FED_DROP_WORDS)]
    cleaned = join(words, " ")
    (isempty(cleaned) || cleaned in FED_ACRONYMS || length(cleaned) < 3) && return ""
    return cleaned
end

"The entries of the Federal Standard file: one for each cleaned alias of each colour."
function read_fed(file, colour_words = Set{String}())
    entries = Pair{String,RGB8}[]
    given = Set{String}()
    started = false
    for line in data_lines(file)
        if !started
            started = startswith(line, "XCMS_COLORDB_START")
            continue
        end
        startswith(line, "XCMS_COLORDB_END") && break
        m = match(
            r"^(\d+)\s+CIE(XYZ|LAB):([-\d.]+)/([-\d.]+)/([-\d.]+)\s+\S+\s+\S+\s*(.*)$"i,
            line,
        )
        m === nothing && continue
        v = parse.(Float64, (m.captures[3], m.captures[4], m.captures[5]))
        xyz = uppercase(m.captures[2]) == "XYZ" ? Tuple(v) : lab_to_xyz(v...)
        rgb = xyz_to_rgb(xyz...)
        aliases = split(m.captures[6], r"\s*,\s*|\s*/\s*"; keepempty = false)
        # a renamed alias stands for the whole entry (its other aliases only describe it)
        renamed = filter(a -> haskey(FED_RENAMES, lowercase(strip(a))), aliases)
        for (i, alias) in enumerate(isempty(renamed) ? aliases : renamed)
            name = fed_clean_name(alias)
            # a later alias of one word is a fragment ("aircraft"), not a colour name
            (i > 1 && !occursin(' ', name) && !(name in colour_words)) && continue
            (isempty(name) || name in given) && continue
            push!(given, name)
            push!(entries, name => rgb)
        end
    end
    return entries
end

# ---- the other sets of NamedColors.jl (Resene, NBS/ISCC, Winsor & Newton, Crayola, Tol)
# ------------------------------------------------------------------------------------

"The Resene paint list: `\"Resene Name\"<TAB>r<TAB>g<TAB>b` lines after the header."
function read_resene(file)
    entries = Pair{String,RGB8}[]
    started = false
    for line in data_lines(file)
        if !started
            started = startswith(line, "\"Colour Name\"")
            continue
        end
        fields = split(strip(line), "\t")
        length(fields) == 4 || continue
        name = replace(strip(fields[1], '"'), r"^Resene "i => "")
        rgb = (parse(Int, fields[2]), parse(Int, fields[3]), parse(Int, fields[4]))
        push!(entries, name => rgb)
    end
    return entries
end

"""
The Winsor & Newton water-colours (an XCMS colour database of Aubrey Jaffer, CIE L*a*b*
colours read as D65). Each paint is listed twice, as `lamp black light` and as
`LampBlackLight`: only the first is read.
"""
function read_winsor(file)
    entries = Pair{String,RGB8}[]
    started = false
    for line in data_lines(file)
        if !started
            started = startswith(line, "XCMS_COLORDB_START")
            continue
        end
        startswith(line, "XCMS_COLORDB_END") && break
        fields = split(strip(line), '\t'; keepempty = false)
        length(fields) == 2 || continue
        name, spec = fields
        name == lowercase(name) || continue
        m = match(r"^CIELab:([-\d.]+)/([-\d.]+)/([-\d.]+)$"i, spec)
        m === nothing && continue
        lab = parse.(Float64, (m.captures[1], m.captures[2], m.captures[3]))
        push!(entries, name => xyz_to_rgb(lab_to_xyz(lab...)...))
    end
    return entries
end

"A file of `r g b<TAB>name` lines (Crayola): the name is in Title Case."
read_crayola(file) = read_x11(file)

"A file of `name<TAB>#rrggbb` lines, `;` comments (Paul Tol)."
function read_tol(file)
    entries = Pair{String,RGB8}[]
    for line in data_lines(file)
        (isempty(strip(line)) || startswith(line, ";")) && continue
        name, code = split(strip(line), "\t")
        push!(entries, String(name) => colour_of_hex(code))
    end
    return entries
end

# The words of the run-together names of NBS/ISCC (`verydarkbluishgreen`) and of Paul Tol
# (`vibrantteal`), and the typos of the Paul Tol file.
const SEGMENT_WORDS = Set(
    split(
        "very dark deep light pale vivid strong moderate brilliant medium " *
        "grayish blackish whitish yellowish greenish bluish reddish purplish " *
        "pinkish brownish orangish olive white gray grey black brown yellow green " *
        "blue purple red orange pink violet bright high contrast vibrant muted " *
        "cyan teal magenta indigo sand rose wine mint pear",
    ),
)
const TOL_TYPOS = Dict(
    "brightgreem" => "bright green",
    "highconstrastblue" => "high contrast blue",
    "decidous needleleaf forest" => "deciduous needleleaf forest",
    "decidous broadleaf foest" => "deciduous broadleaf forest",
)

"""
The words `text` is made of, as few as possible, or `nothing` when it is not made of
words of `SEGMENT_WORDS` only (the owner gets the list of those).
"""
function segment(text::AbstractString)
    n = length(text)
    best = Vector{Union{Nothing,Vector{String}}}(nothing, n + 1)
    best[1] = String[]
    for j in 1:n, i in 0:(j-1)
        best[i+1] === nothing && continue
        word = text[(i+1):j]
        word in SEGMENT_WORDS || continue
        found = vcat(best[i+1], word)
        (best[j+1] === nothing || length(found) < length(best[j+1])) &&
            (best[j+1] = found)
    end
    return best[n+1] === nothing ? nothing : best[n+1]
end

# The land-cover colours of the Paul Tol file (`water`, `woodland`, ...): not colour names
# on their own, so they are `land cover water`, `land cover woodland`.
const TOL_LAND = Set([
    "water", "evergreen needleleaf forest", "deciduous needleleaf forest",
    "mixed forest", "evergreen broadleaf forest", "deciduous broadleaf forest",
    "woodland", "wooded grassland", "grassland", "cropland", "closed shrubland",
    "open shrubland", "bare ground", "urban and built up",
])

"Names that are made of words run together and could not be split (listed in the report)."
const UNSPLIT = String[]

"`name` as readable words: a name with blanks as it is, a run-together one segmented."
function readable(name::AbstractString)
    name = get(TOL_TYPOS, lowercase(name), lowercase(name))
    name in TOL_LAND && return "land cover " * name
    occursin(' ', name) && return name
    words = segment(name)
    words === nothing && (push!(UNSPLIT, name); return "")
    return join(words, " ")
end

# ---- building the list
# ------------------------------------------------------------------------

"Names changed after reading them, as `raw => name` (a name too long or unclear as it is)."
const RENAMES = Dict(
    "blue with a hint of purple" => "blue hint of purple",
    "tabasco purple" => "tabasco pink",
)

"""
Short forms of long place names, applied to every name (`newfoundland and labrador red`
is `nfld red`): `(pattern, short form)`.
"""
const PLACE_ABBREVIATIONS = [
    (r"\bnewfoundland and labrador\b", "nfld"),
    (r"\bnorth ?west territories\b", "nwt"),
    (r"\bu\.s\.", "us"),
    (r"\bd\.c\.", "dc"),
    (r"\bppu\b", "palestine polytechnic"),
]

"""
How a country is named in the national flag entries when that is not its English short name
(owner's decision, 2026-11-10): Chad is `tchad` (`tchad blue`). Applied to the start of the
names of the `flags-national` set only, so another `chad` in a colour name is not touched.
"""
const NATIONAL_NAMES = [(r"^chad\b", "tchad")]

"""
What a set is called inside the parentheses of a clash name (`yellow (fed id prog)`), for
the sets whose tag is not the best name: the Federal Identity Program is `fed id prog`.
The identifier is lower-case words only, no dots.
"""
const SET_IDENTIFIERS = Dict("fip" => "fed id prog")

"""
The pigment abbreviations and misspellings of the Winsor & Newton names (the file does not
expand them), as `word => words`: cadmium, cobalt, chrome (Chrome Yellow, Chrome Green
Deep), manganese, permanent and transparent paints.
"""
const WINSOR_WORDS = Dict(
    "cd" => "cadmium", "co" => "cobalt", "cr" => "chrome", "mn" => "manganese",
    "perm" => "permanent", "trans" => "transparent", "orage" => "orange",
    "pthalo" => "phthalo", "davys" => "davy's", "paynes" => "payne's",
)

"""
Words no entry of the list may carry in its name: an entry of a set with one of them is left
out when the list is built, so a rebuild from sets that still hold such an entry does not
bring it back. This is the owner exclusion rule (2026-11-10): the country and its
institutions by name. Palestinian entries are not covered by it.
"""
const EXCLUDED_WORDS = (
    "israel", "technion", "weizmann", "hebrew university", "tel aviv", "ben-gurion",
    "ben gurion", "bar-ilan", "bar ilan", "university of haifa", "ariel university",
)

"Whether the name of an entry carries a word of `EXCLUDED_WORDS`."
excluded(name::AbstractString) = any(w -> occursin(w, lowercase(name)), EXCLUDED_WORDS)

"""
The sets whose tag keeps its hyphens in an identifier because they are part of the name of
the standard (`FED-STD-595C`); every other hyphen of a tag is a blank (`paul tol`).
"""
const HYPHENATED_TAGS = ("fed-std-595c",)

"""
The identifier of the set `tag` in a clash name: the table, else the tag with blanks for
its hyphens (`paul-tol` is `paul tol`, `nbs-iscc` is `nbs iscc`), except the standard's own.
"""
function identifier(tag::AbstractString)
    haskey(SET_IDENTIFIERS, tag) && return SET_IDENTIFIERS[tag]
    return tag in HYPHENATED_TAGS ? tag : replace(tag, '-' => ' ')
end

"The lower-case name of an entry of a source, before clashes are settled."
function base_name(tag::AbstractString, raw::AbstractString)
    name = lowercase(strip(raw))
    tag == "tailwind" && (name = replace(name, '.' => ' '))
    name = strip(replace(name, r"\bf\.s\.?\s*" => ""))
    for (pattern, short) in PLACE_ABBREVIATIONS
        name = replace(name, pattern => short)
    end
    if tag == "flags-national"
        for (pattern, country) in NATIONAL_NAMES
            name = replace(name, pattern => country)
        end
    end
    tag == "winsor-newton" &&
        (name = join((get(WINSOR_WORDS, w, w) for w in split(name)), " "))
    return get(RENAMES, name, name)
end

"""
A name everybody knows: any `css` name, a plain `x11` name (no number: not `brown1`), and a
plain base colour word of `tailwind` or `xkcd` (one word of letters only).
"""
function is_common(tag::AbstractString, base::AbstractString)
    tag == "css" && return true
    tag == "x11" && return !occursin(r"\d", base)
    return tag in ("tailwind", "xkcd") && occursin(r"^[a-z]+$", base)
end

"The sources in priority order, as `(tag, entries)`."
function sources()
    sorted(entries) = sort(entries; by = first)
    css = sorted(read_css("css148.txt"))
    x11 = sorted(read_x11("x11rgb.txt"))
    # the one-word names of the standard sets: what a one-word FED alias must be to count
    plain = [first(e) for e in vcat(css, x11) if !occursin(r"[\d ]", first(e))]
    words = Set(lowercase.(plain))
    result = Any[
        ("css", css),
        ("x11", x11),
        ("fed-std-595c", sorted(read_fed("FED-STD-595C.txt", words))),
        ("tailwind", sorted(read_tailwind("tailwind.txt"))),
        ("xkcd", sorted(read_xkcd("xkcd.txt"))),
    ]
    file = JSON3.read(read(SOURCES_FILE, String))
    rows = Dict(String(s.tag) => Pair{String,RGB8}[] for s in file.sets)
    for e in file.colours
        push!(rows[String(e.set)], String(e.name) => colour_of_hex(String(e.hex)))
    end
    for s in file.sets
        push!(result, (String(s.tag), rows[String(s.tag)]))
    end
    nbs = [readable(first(e)) => last(e) for e in read_x11("NBS-ISCC-rgb.txt")]
    tol = [readable(first(e)) => last(e) for e in read_tol("paul-tol.txt")]
    push!(result, ("nbs-iscc", sorted(filter(e -> !isempty(first(e)), nbs))))
    push!(result, ("winsor-newton", sorted(read_winsor("winsor-newton-lab.txt"))))
    push!(result, ("crayola", sorted(read_crayola("crayola.txt"))))
    push!(result, ("paul-tol", sorted(filter(e -> !isempty(first(e)), tol))))
    push!(result, ("resene", sorted(read_resene("resenecolours.txt"))))
    return result
end

"""
The duplicate pass: takes the entries the list should not have out of `table` and returns
what it took out, as `(; dropped, kept, rule)`.
"""
function prune!(table, origin)
    dropped = NamedTuple[]
    place(name) = origin[name].place
    by_key = Dict{String,Vector{String}}()
    for name in keys(table)
        push!(get!(by_key, key_of(name), String[]), name)
    end
    for names in values(by_key)
        length(names) > 1 || continue
        sort!(names; by = place)
        for name in names[2:end]
            push!(dropped, (; dropped = name, kept = names[1], rule = "name"))
            delete!(table, name)
        end
    end
    by_colour = Dict{RGB8,Vector{String}}()
    for (name, c) in table
        push!(get!(by_colour, c, String[]), name)
    end
    for names in values(by_colour)
        length(names) > 1 || continue
        sort!(names; by = place)
        common = [n for n in names if is_common(origin[n].tag, origin[n].base)]
        if isempty(common)
            keep = [first(sort(names; by = n -> (length(n), place(n))))]
            rule = "shortest"
        else
            keep = common
            rule = "common"
        end
        for name in names
            name in keep && continue
            push!(dropped, (; dropped = name, kept = join(keep, ", "), rule))
            delete!(table, name)
        end
    end
    return dropped
end

"""
The list: the name => colour table, the per-source
counts and what the duplicate pass took out.
"""
function build()
    table = Dict{String,RGB8}()
    claimed = Dict{String,Vector{RGB8}}()
    plain_keys = Set{String}()
    counts = Dict{String,NamedTuple}()
    origin = Dict{String,NamedTuple}()
    for (tag, entries) in sources()
        raw_count = duplicates = tagged = numbered = 0
        for (raw, rgb) in entries
            excluded(raw) && continue
            raw_count += 1
            base = base_name(tag, raw)
            key = key_of(base)
            seen = get!(claimed, key, RGB8[])
            if rgb in seen
                duplicates += 1
                continue
            end
            name = base
            if haskey(table, name) || key in plain_keys
                name = "$base ($(identifier(tag)))"
                tagged += 1
                if haskey(table, name)
                    n = 1
                    while haskey(table, name)
                        n += 1
                        name = "$base ($(identifier(tag)) $n)"
                    end
                    numbered += 1
                end
            end
            push!(seen, rgb)
            name == base && push!(plain_keys, key)
            table[name] = rgb
            origin[name] = (; place = length(origin) + 1, tag, base)
        end
        counts[tag] = (; raw = raw_count, duplicates, tagged, numbered)
    end
    before = copy(table)
    dropped = prune!(table, origin)
    return table, counts, dropped, before, origin
end

"""
Whether Colors.jl reads `name` and gives it the colour `c` (so a setting may keep the name).
"""
function julia_reads(name::AbstractString, c::RGB8)
    parsed = try
        convert(Colors.RGB{Colors.N0f8}, Colors.parse(Colors.Colorant, name))
    catch
        return false
    end
    channels = (
        Int(reinterpret(UInt8, parsed.r)),
        Int(reinterpret(UInt8, parsed.g)),
        Int(reinterpret(UInt8, parsed.b)),
    )
    return channels == c
end

# ---- the family of each colour
# ------------------------------------------------------------------------------------

"The colour families of the picker's filter: the 11 basic colour terms and cyan."
const FAMILIES = (
    "red", "orange", "yellow", "green", "cyan", "blue", "purple", "pink", "brown",
    "gray",
    "black", "white",
)

# The boundaries of the rules, from the colour as hue (degrees), saturation and lightness
# (0 to 1) of HSL. Every colour gets exactly one family.

"A colour with less saturation than this has no hue: it is gray (or black or white)."
const FAMILY_NEUTRAL_SATURATION = 0.12

"A colour with less lightness than this is black, whatever its hue."
const FAMILY_BLACK_LIGHTNESS = 0.12

"A colour with more lightness than this is white, whatever its hue."
const FAMILY_WHITE_LIGHTNESS = 0.93

"""
The hue bands, as `(upper edge in degrees, family)`: red below 15 and from 345, orange to
45, yellow to 70, green to 165, cyan to 200, blue to 255, purple to 290; magenta to 345 is
pink if light and purple if dark.
"""
const FAMILY_HUE_BANDS = (
    (15.0, "red"), (45.0, "orange"), (70.0, "yellow"), (165.0, "green"),
    (200.0, "cyan"),
    (255.0, "blue"), (290.0, "purple"), (345.0, "magenta"),
)

"A magenta with at least this lightness is pink, a darker one purple."
const FAMILY_PINK_LIGHTNESS = 0.45

"""
Where the magenta band turns to crimson: from this hue (degrees) a dark colour is a red
(crimson, burgundy, wine) when it is saturated, not a purple.
"""
const FAMILY_CRIMSON_HUE = 330.0

"A dark colour in the crimson hues with at least this saturation is red."
const FAMILY_CRIMSON_SATURATION = 0.5

"A dark, unsaturated colour in the crimson hues with less lightness than this is brown."
const FAMILY_CRIMSON_BROWN_LIGHTNESS = 0.30

"""
Words that name a red whatever the hue band put the colour in: a colour in the crimson or
orange hues whose name has one of them is red (`burgundy`, `mcmaster maroon`).
"""
const FAMILY_RED_WORDS = (
    "wine", "burgundy", "maroon", "crimson", "ruby", "cherry", "cranberry", "bordeaux",
    "claret", "scarlet", "vermilion", "carmine", "garnet",
)

"A red lighter than this (and not gray) is pink."
const FAMILY_LIGHT_RED_LIGHTNESS = 0.72

"A red or orange darker than this is brown (a dark red with the saturation below is not)."
const FAMILY_BROWN_LIGHTNESS = 0.40

"A dark red with at least this saturation is red, not brown (maroon)."
const FAMILY_DARK_RED_SATURATION = 0.7

"An orange with less saturation than this and less lightness than the next is brown (tan)."
const FAMILY_MUTED_ORANGE_SATURATION = 0.5

"See `FAMILY_MUTED_ORANGE_SATURATION`."
const FAMILY_MUTED_ORANGE_LIGHTNESS = 0.75

"A yellow darker than this is green (olive)."
const FAMILY_OLIVE_LIGHTNESS = 0.35

"""
The families next to each other: a name whose last word is a family takes it when the
computed family is that one or one of its neighbours.
"""
const FAMILY_NEIGHBOURS = Dict(
    "red" => ("orange", "pink", "brown", "purple"),
    "orange" => ("red", "yellow", "brown"),
    "yellow" => ("orange", "green", "brown"),
    "green" => ("yellow", "cyan"),
    "cyan" => ("green", "blue"),
    "blue" => ("cyan", "purple"),
    "purple" => ("blue", "pink", "red"),
    "pink" => ("red", "purple", "white"),
    "brown" => ("red", "orange", "yellow", "gray", "black"),
    "gray" => ("black", "white", "brown"),
    "black" => ("gray",),
    "white" => ("gray", "pink"),
)

"A colour as hue (degrees), saturation and lightness (HSL)."
function hsl_of(c::RGB8)
    r, g, b = c ./ 255
    hi, lo = max(r, g, b), min(r, g, b)
    l = (hi + lo) / 2
    d = hi - lo
    d == 0 && return (0.0, 0.0, l)
    s = d / (1 - abs(2l - 1))
    h = if hi == r
        60 * mod((g - b) / d, 6)
    elseif hi == g
        60 * ((b - r) / d + 2)
    else
        60 * ((r - g) / d + 4)
    end
    return (h, s, l)
end

"""
The reference of the families: the 267 colour centres of the ISCC-NBS system (1955, the
standard dictionary of colour names; `NBS-ISCC-rgb.txt`), each with the basic colour its
name ends in. A colour belongs to the family of the nearest centre in CIELAB.
"""
const NBS_MODIFIERS = Regex(
    "^(?:" *
    join(
        ["very", "dark", "deep", "light", "pale", "strong", "vivid", "brilliant"] ∪
        ["moderate", "grayish", "dusky", "blackish"],
        "|",
    ) * ")+",
)

"""
The family of an ISCC-NBS name (run together, as `verydarkyellowishgreen`) once its
modifiers are off: the noun it ends in, except where our twelve families differ from the
system's: the blue-greens (`greenishblue`, `bluishgreen`) are cyan; `olive` and
`olivegreen` are green, `yellowgreen` is green, `orangeyellow` and `greenishyellow` are
yellow; `violet` and the reddish purples are purple; `purplishred` is red.
"""
const NBS_FAMILY_OF_NOUN = Dict(
    "greenishblue" => "cyan", "bluishgreen" => "cyan", "olive" => "green",
    "olivegreen" => "green", "yellowgreen" => "green", "yellowishgreen" => "green",
    "orangeyellow" => "yellow", "greenishyellow" => "yellow", "violet" => "purple",
    "reddishpurple" => "purple", "purplishblue" => "blue", "purplishred" => "red",
    "purplishpink" => "pink", "yellowishpink" => "pink", "brownishpink" => "pink",
    "yellowishbrown" => "brown", "reddishbrown" => "brown", "olivebrown" => "brown",
    "reddishorange" => "orange", "brownishorange" => "orange",
)

function nbs_family_of_name(raw::AbstractString)::String
    noun = replace(lowercase(raw), NBS_MODIFIERS => "")
    haskey(NBS_FAMILY_OF_NOUN, noun) && return NBS_FAMILY_OF_NOUN[noun]
    for family in ("white", "black", "gray", "brown", "pink", "red", "orange", "yellow",
        "green", "blue", "purple")
        endswith(noun, family) && return family
    end
    return "gray"
end

"A colour in CIELAB (D65)."
function lab_of(c::RGB8)
    linear(u) = u <= 0.04045 ? u / 12.92 : ((u + 0.055) / 1.055)^2.4
    r, g, b = linear.(c ./ 255)
    x = (0.4124564r + 0.3575761g + 0.1804375b) * 100 / D65_WHITE[1]
    y = (0.2126729r + 0.7151522g + 0.0721750b) * 100 / D65_WHITE[2]
    z = (0.0193339r + 0.1191920g + 0.9503041b) * 100 / D65_WHITE[3]
    f(t) = t > 216 / 24389 ? cbrt(t) : (24389 / 27 * t + 16) / 116
    return (116f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
end

"""
The W3C CSS colour keywords by the categories of the CSS Color module (as MDN lists them):
the authoritative family of each of the 148 keywords. The CSS categories have no cyan: the
blue-greens (aqua to teal) are ours, and black is its own family here.
"""
const CSS_FAMILY_OF_KEYWORD = let
    groups = Dict(
        "pink" => """
            pink hotpink deeppink lightpink palevioletred mediumvioletred
            """,
        "red" => """
            lightsalmon salmon darksalmon lightcoral indianred crimson firebrick darkred
            red
            """,
        "orange" => """
            orangered tomato coral darkorange orange
            """,
        "yellow" => """
            gold yellow lightyellow lemonchiffon lightgoldenrodyellow papayawhip
            moccasin peachpuff palegoldenrod khaki darkkhaki
            """,
        "purple" => """
            lavender thistle plum violet orchid fuchsia magenta mediumorchid
            mediumpurple rebeccapurple blueviolet darkviolet darkorchid darkmagenta
            purple indigo slateblue darkslateblue mediumslateblue
            """,
        "green" => """
            greenyellow chartreuse lawngreen lime limegreen palegreen lightgreen
            mediumspringgreen springgreen mediumseagreen seagreen forestgreen green
            darkgreen yellowgreen olivedrab olive darkolivegreen mediumaquamarine
            darkseagreen
            """,
        "cyan" => """
            aqua cyan lightcyan paleturquoise aquamarine turquoise mediumturquoise
            darkturquoise lightseagreen darkcyan teal cadetblue
            """,
        "blue" => """
            steelblue lightsteelblue powderblue lightblue skyblue lightskyblue
            deepskyblue dodgerblue cornflowerblue royalblue blue mediumblue darkblue
            navy midnightblue
            """,
        "brown" => """
            cornsilk blanchedalmond bisque navajowhite wheat burlywood tan rosybrown
            sandybrown goldenrod darkgoldenrod peru chocolate saddlebrown sienna brown
            maroon
            """,
        "white" => """
            white snow honeydew mintcream azure aliceblue ghostwhite whitesmoke seashell
            beige oldlace floralwhite ivory antiquewhite linen lavenderblush mistyrose
            """,
        "gray" => """
            gainsboro lightgray lightgrey silver darkgray darkgrey gray grey dimgray
            dimgrey lightslategray lightslategrey slategray slategrey darkslategray
            darkslategrey
            """,
        "black" => """
            black
            """,
    )
    Dict(word => family for (family, words) in groups for word in split(words))
end

"The ISCC-NBS centres as `(Lab, family)`, read once."
const NBS_CENTRES = Ref{Vector{Tuple{NTuple{3,Float64},String,Float64}}}()

"""
Words of a colour name that make it a cyan (the blue-greens), besides `cyan` itself: the
names of the other families are the family words.
"""
const FAMILY_CYAN_WORDS = ("teal", "turquoise", "aqua", "aquamarine", "cyan")

"The family the last word of a name gives (`dark pink`, `sea teal`), or `nothing`."
function family_of_last_word(name::AbstractString)
    words = split(lowercase(replace(name, r"\s*\(.*\)$" => "")))
    isempty(words) && return nothing
    word = replace(last(words), "grey" => "gray")
    word in FAMILY_CYAN_WORDS && return "cyan"
    return word in FAMILIES ? word : nothing
end

"""
The votes of the standard references count this much more than those of the survey names:
the CSS keywords (W3C categories) and the ISCC-NBS centres are authoritative.
"""
const FAMILY_STANDARD_WEIGHT = 2.0

"How many of the nearest references vote on the family of a colour."
const FAMILY_NEIGHBOUR_COUNT = 9

"""
The references of the families as `(Lab, family, weight)`: the CSS keywords, the ISCC-NBS
centres, and the colours of the xkcd colour survey and of Resene whose name ends in a
family word (a name the crowd or the paint maker gave: `hot pink`, `sky blue`).
"""
function nbs_centres()
    isassigned(NBS_CENTRES) && return NBS_CENTRES[]
    standard = FAMILY_STANDARD_WEIGHT
    refs = Tuple{NTuple{3,Float64},String,Float64}[]
    for (name, rgb) in read_css("css148.txt")
        haskey(CSS_FAMILY_OF_KEYWORD, lowercase(name)) &&
            push!(refs, (lab_of(rgb), CSS_FAMILY_OF_KEYWORD[lowercase(name)], standard))
    end
    for (name, rgb) in read_x11("NBS-ISCC-rgb.txt")
        push!(refs, (lab_of(rgb), nbs_family_of_name(name), standard))
    end
    for (name, rgb) in vcat(read_xkcd("xkcd.txt"), read_resene("resenecolours.txt"))
        family = family_of_last_word(name)
        family === nothing || push!(refs, (lab_of(rgb), family, 1.0))
    end
    NBS_CENTRES[] = refs
    return refs
end

"""
A colour farther than this (CIE76 distance in Lab) from every reference is outside what
they cover (vivid screen colours): the hue rules decide it.
"""
const FAMILY_NBS_MAX_DISTANCE = 30.0

"""
The family of a colour: the weighted vote of the nearest references (each counts
`weight / (distance + 1)`), or the hue rules when no reference is near.
"""
function computed_family(c::RGB8)::String
    lab = lab_of(c)
    refs = nbs_centres()
    distances = [sqrt(sum(abs2, lab .- r[1])) for r in refs]
    nearest = partialsortperm(distances, 1:FAMILY_NEIGHBOUR_COUNT)
    distances[first(nearest)] > FAMILY_NBS_MAX_DISTANCE && return rule_family(c)
    votes = Dict{String,Float64}()
    for i in nearest
        votes[refs[i][2]] = get(votes, refs[i][2], 0.0) + refs[i][3] / (distances[i] + 1)
    end
    return first(sort!(collect(votes); by = last, rev = true))[1]
end

"The family of a colour by its hue, saturation and lightness alone (the first rules)."
function rule_family(c::RGB8)::String
    h, s, l = hsl_of(c)
    l < FAMILY_BLACK_LIGHTNESS && return "black"
    l > FAMILY_WHITE_LIGHTNESS && return "white"
    s < FAMILY_NEUTRAL_SATURATION && return "gray"
    band = h >= 345 ? "red" : first(f for (edge, f) in FAMILY_HUE_BANDS if h < edge)
    if band == "magenta"
        l >= FAMILY_PINK_LIGHTNESS && return "pink"
        h < FAMILY_CRIMSON_HUE && return "purple"
        s >= FAMILY_CRIMSON_SATURATION && return "red"
        return l < FAMILY_CRIMSON_BROWN_LIGHTNESS ? "brown" : "purple"
    elseif band == "red"
        l > FAMILY_LIGHT_RED_LIGHTNESS && return "pink"
        dark = l < FAMILY_BROWN_LIGHTNESS && s < FAMILY_DARK_RED_SATURATION
        return dark ? "brown" : "red"
    elseif band == "orange"
        l < FAMILY_BROWN_LIGHTNESS && return "brown"
        muted = s < FAMILY_MUTED_ORANGE_SATURATION && l < FAMILY_MUTED_ORANGE_LIGHTNESS
        return muted ? "brown" : "orange"
    elseif band == "yellow"
        return l < FAMILY_OLIVE_LIGHTNESS ? "green" : "yellow"
    end
    return band
end

"""
The family of the entry `name` with colour `c`: the family its last word names (`dark
brown`, `light pink`; `grey` is gray) when that is the computed family or one next to
it, else the computed family.
"""
function family_of(name::AbstractString, c::RGB8)::String
    computed = computed_family(c)
    words = split(lowercase(replace(name, r"\s*\(.*\)$" => "")))
    h = first(hsl_of(c))
    named = replace(lowercase(last(words)), "grey" => "gray") in FAMILIES
    if !named && computed in ("purple", "pink", "brown", "orange") &&
       (h >= 325 || h < 20) &&
       any(w -> w in FAMILY_RED_WORDS, words)
        return "red"
    end
    last_word = last(split(replace(name, r"\s*\(.*\)$" => "")))
    word = replace(lowercase(last_word), "grey" => "gray")
    word in FAMILIES || return computed
    near = word == computed || word in get(FAMILY_NEIGHBOURS, computed, ())
    return near ? word : computed
end

function main(args)
    isempty(args) &&
        (println(stderr, "usage: harvest_colours.jl OUT [REPORT [BEFORE]]"); return 2)
    out = first(args)
    table, counts, dropped, before, origin = build()
    isempty(UNSPLIT) ||
        println("harvest colours: not split into words, left out: ", join(UNSPLIT, ", "))
    rows = [
        " $(JSON3.write(name)): $(JSON3.write(hex_of(c)))" for (name, c) in
        sort!(collect(table); by = p -> (lowercase(first(p)), first(p)))
    ]
    write(out, "{\n" * join(rows, ",\n") * "\n}\n")
    known = joinpath(
        dirname(out),
        replace(basename(out), "colours" => "colour-julia"; count = 1),
    )
    families_file = joinpath(
        dirname(out),
        replace(basename(out), "colours" => "colour-families"; count = 1),
    )
    families = Dict(name => family_of(name, c) for (name, c) in table)
    family_rows = [
        " $(JSON3.write(name)): $(JSON3.write(families[name]))" for
        name in sort!(collect(keys(table)); by = n -> (lowercase(n), n))
    ]
    write(families_file, "{\n" * join(family_rows, ",\n") * "\n}\n")
    println(
        "harvest colours: families ",
        join(("$f $(count(==(f), values(families)))" for f in FAMILIES), ", "),
    )
    julia_names = sort!([name for (name, c) in table if julia_reads(name, c)])
    write(known, "[\n" * join((" " * JSON3.write(n) for n in julia_names), ",\n") * "\n]\n")
    if length(args) >= 3
        # the table before the duplicate pass, with the set of each entry (to reverse it)
        pre = [
            (; name, hex = hex_of(c), set = origin[name].tag) for
            (name, c) in sort!(collect(before); by = first)
        ]
        write(args[3], JSON3.write(pre))
    end
    if length(args) >= 2
        report = (;
            total = length(table),
            counts = Dict(k => v for (k, v) in counts),
            dropped = sort(dropped; by = d -> (d.rule, d.dropped)),
        )
        write(args[2], JSON3.write(report))
    end
    println("harvest colours: wrote $out ($(length(table)) names)")
    return 0
end

exit(main(ARGS))
