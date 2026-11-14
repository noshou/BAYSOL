# SPDX-License-Identifier: LGPL-3.0-or-later

# The offline extractors that regenerate the data bundled with the package: the
# form-factor database (`bysl extract formfactor`), the component table (`bysl extract
# components`) and the 3D-RISM partial molar volumes (`bysl extract pmv`).
module Extract

using ..Common

# --- the form-factor database

module FormFactor

using ...Common

const WHO = "bysl extract formfactor"

const USAGE = """
Rebuilds the form-factor database from xraydb.sqlite.

    bysl extract formfactor xraydb.sqlite src/scattering/form_factors.sqlite3

Waasmaier-Kirfel f0 and Chantler f1/f2 (xraydb 4.5.8, CC0), deuterium as a copy of
hydrogen. Runs dev/scripts/extract-formfactor.jl in the root project (it needs SQLite.jl);
the destination is replaced only when the new database is complete.
"""

"`bysl extract formfactor SRC DST`: runs the script in the root project."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    return run_cmd([find_julia(), "--startup-file=no", "--project=" * root(),
        in_root("dev", "scripts", "extract-formfactor.jl"), argv]) ? 0 : 1
end

end

# --- the component table

module Components

using Dates
using ...Common

const WHO = "bysl extract components"

const USAGE = """
Regenerates src/molecular-structure/components.tsv from the wwPDB dictionary.

    bysl extract components [--check|--update] [SOURCE [OUT]]

    SOURCE      components.cif.gz or an http(s) URL (default: the wwPDB file)
    OUT         the table to write or compare (default: the bundled one)
    --check     exit 1 if the table differs, printing the first differing lines
    --update    rewrite OUT
    --source-date S, --fetched DATE, --url URL
                header values (default: those of OUT, so only data is compared)
    --out FILE  same as OUT
    --val-inference
                print how well each base signal agrees with the declared parents

The gzip is streamed. Columns: id, class, type, parent, formula, base, base_source.
"""

const DEFAULT_URL = "https://files.wwpdb.org/pub/pdb/data/monomers/components.cif.gz"
default_out() = in_root("src", "molecular-structure", "components.tsv")

# --- parsing

"""
A CIF value without the single or double quotes that surround it.
"""
function unquote_value(v::AbstractString)
    if length(v) >= 2 && first(v) in ('\'', '"') && first(v) == last(v)
        return String(chop(v; head = 1, tail = 1))
    end
    return String(v)
end

"""
`"dna"`, `"rna"` or `"other"` for a lower-case `_chem_comp.type`: the word DNA or RNA
anywhere in it, hyphens and spaces counting as word breaks (`"l-rna linking"`, `"dna oh 5
prime terminus"`).
"""
function component_class(typ::AbstractString)
    occursin(r"\bdna\b", typ) && return "dna"
    occursin(r"\brna\b", typ) && return "rna"
    return "other"
end

# A data block: the `_chem_comp` items by name, and for nucleic acid blocks `:atoms` and
# `:bonds`.
const Block = Dict{Any,Any}

nucleic(block) = component_class(lowercase(get(block, "type", "?"))) != "other"

# The tokens of one row of a CIF loop: a word, or text in single or double quotes.
const TOKEN_RE = r"\"(?:[^\"]|\"(?=\S))*\"(?=\s|$)|'(?:[^']|'(?=\S))*'(?=\s|$)|\S+"

"The unquoted tokens of one CIF loop row."
tokens(line::AbstractString) =
    String[unquote_value(m.match) for m in eachmatch(TOKEN_RE, line)]

const ATOM_COLS = ["_chem_comp_atom.atom_id", "_chem_comp_atom.type_symbol"]
const BOND_COLS = ["_chem_comp_bond.atom_id_1", "_chem_comp_bond.atom_id_2"]

# Adds one data row of a loop with the column names `cols` to the nucleic block `cur`: an
# atom `(name, element)` (hydrogens and deuterium are dropped) or a bond `(a, b)`.
function loop_row!(cur, cols, line)
    toks = tokens(line)
    at(col) = (
        i = findfirst(==(col), cols);
        i !== nothing && i <= length(toks) ?
        toks[i] : nothing
    )
    if first(ATOM_COLS) in cols
        n, e = at(ATOM_COLS[1]), at(ATOM_COLS[2])
        if n !== nothing && e !== nothing && !(uppercase(e) in ("H", "D"))
            push!(get!(cur, :atoms, Tuple{String,String}[]), (n, uppercase(e)))
        end
    elseif first(BOND_COLS) in cols
        a, b = at(BOND_COLS[1]), at(BOND_COLS[2])
        a !== nothing && b !== nothing &&
            push!(get!(cur, :bonds, Tuple{String,String}[]), (a, b))
    end
    return cur
end

# The `_chem_comp` items kept: the table needs id, type, formula and the parent; the base
# inference reads the name and the one-letter code.
const FIELDS =
    ("id", "type", "formula", "mon_nstd_parent_comp_id", "name", "one_letter_code")

# One `_chem_comp.<field> [value]` line of a data block.
const ITEM_RE = r"^_chem_comp\.([a-z_]+)(?:\s+(.*?))?\s*$"

"""
    read_blocks(io) -> Vector{Block}

The data blocks of a component dictionary read from `io`, streamed line by line, as dicts:
the `_chem_comp` items of `FIELDS` by name (unquoted; a `;` text block, as the name often
is, joined into one line) and, for nucleic acid blocks only, `:atoms` (`(name, ELEMENT)`,
heavy atoms) and `:bonds` (`(atom-1, atom-2)`) from the `_chem_comp_atom` and
`_chem_comp_bond` loops.
"""
function read_blocks(io::IO)::Vector{Block}
    acc = Block[]
    flush!(cur) =
        cur === nothing ? nothing :
        !haskey(cur, "id") ?
        throw(ToolError("$WHO: a data block has no _chem_comp.id", 1)) :
        push!(acc, cur)
    cur = nothing
    # the field whose `;` text block is being read, with the lines so far (nothing: not in
    # one), and whether the block has started
    text_field = nothing
    text_lines = nothing
    # the loop being read: its column names and whether its header is still going on
    cols = nothing
    header = false
    for line in eachline(io)
        if text_field !== nothing
            if text_lines === nothing
                # the line after an empty value: a `;` text block opens, or the value
                # itself sits on this line
                if startswith(line, ";")
                    text_lines = String[line[2:end]]
                else
                    cur[text_field] = unquote_value(strip(line))
                    text_field = nothing
                end
            elseif startswith(line, ";")
                cur[text_field] = strip(join(text_lines, " "))
                text_field = nothing
                text_lines = nothing
            else
                push!(text_lines, line)
            end
        elseif startswith(line, "data_")
            flush!(cur)
            cur = Block()
            cols = nothing
        elseif startswith(line, "loop_")
            cols = String[]
            header = true
        elseif startswith(line, "#")
            cols = nothing
        elseif cols !== nothing && header && startswith(line, "_")
            push!(cols, strip(line))
        elseif cols !== nothing
            cur !== nothing && nucleic(cur) && loop_row!(cur, cols, line)
            header = false
        elseif startswith(line, "_chem_comp.")
            m = match(ITEM_RE, line)
            if m !== nothing && m[1] in FIELDS && cur !== nothing
                if m[2] !== nothing && !isempty(m[2])
                    cur[String(m[1])] = unquote_value(m[2])
                else
                    # an empty value: a `;` text block follows
                    text_field = String(m[1])
                    text_lines = nothing
                end
            end
        end
    end
    flush!(cur)
    return acc
end

# --- the base of a nucleotide
#
# Which of A C G U T a nucleic acid component is built on, written to the table's
# `base` column with the signal that decided it in `base_source`. The signals, from the
# most to the least trusted: the declared parent (`mon_nstd_parent_comp_id`, followed
# up through non-standard parent-of), the standard residues themselves (`self`), the
# one-letter code (`letter`), the ring chemistry (`ring`) and keywords of the name
# (`name`). `validate` measures the last three on the components that declare a parent.

const STANDARD_BASES = Dict("A" => "A", "C" => "C", "G" => "G", "U" => "U", "T" => "T",
    "DA" => "A", "DC" => "C", "DG" => "G", "DT" => "T", "DU" => "U")

# The ids of a `parent` column text ("DT, DT", "C", "-"), as a vector.
parent_ids(parent) =
    parent in ("-", "?", "") ? String[] :
    String[strip(p) for p in split(parent, ',')]

"""
    parent_base(parentOf, parent) -> Union{Nothing,String}

The base A/C/G/U/T that the declared parent `parent` of a component leads to, or
`nothing`.
"""
function parent_base(parentOf, parent)
    function of_id(id, seen)
        haskey(STANDARD_BASES, id) && return STANDARD_BASES[id]
        id in seen && return nothing
        return of_list(parent_ids(get(parentOf, id, "-")), union(seen, [id]))
    end
    function of_list(ids, seen)
        bs = Set(of_id(i, seen) for i in ids)
        (!isempty(ids) && length(bs) == 1 && first(bs) !== nothing) ? first(bs) : nothing
    end
    return of_list(parent_ids(parent), Set{String}())
end

"The base of a usable `_chem_comp.one_letter_code` (A C G U T), else `nothing`."
function letter_base(code)
    code === nothing && return nothing
    up = uppercase(code)
    return up in ("A", "C", "G", "U", "T") ? up : nothing
end

# Keywords of nucleoside names, per base.
const NAME_KEYWORDS = ["A" => r"ADENO|ADENIN|ADENYL", "G" => r"GUANO|GUANIN|GUANYL",
    "C" => r"CYTID|CYTOSIN|CYTIDYL", "T" => r"THYMID|THYMIN|THYMIDYL",
    "U" => r"URID|URACIL|URIDYL"]

"The base a component's name mentions, or `nothing` when it mentions none or more than one."
function name_base(nm)
    up = uppercase(something(nm, ""))
    found = [b for (b, re) in NAME_KEYWORDS if occursin(re, up)]
    return length(found) == 1 ? only(found) : nothing
end

const Graph = Dict{String,Set{String}}

# The bond graph of a block: atom name to the set of bonded heavy atoms.
function adjacency(block)
    atoms = get(block, :atoms, Tuple{String,String}[])
    known = Set(first.(atoms))
    g = Graph(a => Set{String}() for a in known)
    for (a, b) in get(block, :bonds, Tuple{String,String}[])
        if a in known && b in known && a != b
            push!(g[a], b)
            push!(g[b], a)
        end
    end
    return g
end

# Every simple cycle of `n` atoms of the graph `g`, as a set of atom-name sets.
function cycles_of_length(g::Graph, n::Int)
    found = Set{Set{String}}()
    for start in keys(g)
        function extend(path)
            if length(path) == n
                last(path) in keys(g) && first(path) in g[last(path)] &&
                    push!(found, Set(path))
                return
            end
            for nb in g[last(path)]
                (nb in path || !(nb > start)) && continue
                extend(vcat(path, [nb]))
            end
        end
        extend([start])
    end
    return found
end

# The `(c1, n, ring)` of the nucleoside in graph `g` (elements in `el`): a five-ring of
# one O and four C whose carbon next to the ring O carries a nitrogen outside the ring;
# `nothing` unless there is exactly one such pair (abasic sugars, C-nucleosides and
# molecules with several nucleosides have none).
function glycosidic(g::Graph, el)
    hits = Set{Tuple{String,String,Set{String}}}()
    for ring in cycles_of_length(g, 5)
        os = [a for a in ring if el[a] == "O"]
        (length(os) == 1 && count(a -> el[a] == "C", ring) == 4) || continue
        for c1 in g[first(os)]
            c1 in ring || continue
            for n in g[c1]
                !(n in ring) && el[n] == "N" && push!(hits, (c1, n, ring))
            end
        end
    end
    return length(hits) == 1 ? first(hits) : nothing
end

# The atoms of the base ring system hanging on the glycosidic nitrogen `n`: everything
# reachable from `n` without passing through the sugar (`c1` and the furanose ring atoms
# `sugar`), pruned of its dead ends until only rings and the bonds between them remain.
function base_core(g::Graph, n, sugar)
    seen = Set([n])
    todo = [n]
    while !isempty(todo)
        x = pop!(todo)
        for y in g[x]
            (y in seen || y in sugar) && continue
            push!(seen, y)
            push!(todo, y)
        end
    end
    core = copy(seen)
    while true
        dead = [a for a in core if count(in(core), g[a]) <= 1]
        isempty(dead) && return core
        foreach(a -> delete!(core, a), dead)
    end
end

# The heavy atoms bonded to `a` that are not in `core`.
subs_of(g, core, a) = [x for x in g[a] if !(x in core)]

# The base of a pyrimidine base ring: the ring `core` (6 atoms, glycosidic nitrogen `n1`)
# in graph `g` with elements `el`, numbered from N1. "C" for a C4 amine with a C2 oxygen
# (a C5 substituent does not matter: an amine only at C5 is not a C), `:ut` for oxygens on
# C2 and C4 (a uracil or a thymine: the dictionary's parent-of do not follow the C5
# methyl, so the ring does not decide), else `nothing`.
function ring_pyrimidine(g::Graph, el, core, n1)
    others = [a for a in core if a != n1]
    firstof(xs) = isempty(xs) ? nothing : first(xs)
    n3 = firstof([a for a in others if el[a] == "N"])
    n3 === nothing && return nothing
    c2 = firstof([a for a in g[n1] if a in core && a in g[n3]])
    c2 === nothing && return nothing
    c6 = firstof([a for a in g[n1] if a in core && a != c2])
    c4 = firstof([a for a in g[n3] if a in core && a != c2])
    c6 === nothing && return nothing
    c4 === nothing && return nothing
    c5 = firstof([a for a in core if !(a in (n1, n3, c2, c4, c6))])
    c5 === nothing && return nothing
    (
        count(a -> el[a] == "N", others) == 1 &&
        Set(a for a in g[c4] if a in core) == Set([n3, c5]) &&
        Set(a for a in g[c5] if a in core) == Set([c4, c6])
    ) || return nothing
    sub_els(a) = sort([el[x] for x in subs_of(g, core, a)])
    sub_els(c2) == ["O"] || return nothing
    s4 = sub_els(c4)
    return s4 == ["N"] ? "C" : s4 == ["O"] ? :ut : nothing
end

# The base (A or G) of a purine base ring system: `core` (9 atoms) with glycosidic
# nitrogen `n9` in graph `g` with elements `el`, numbered from N9, or `nothing`.
function ring_purine(g::Graph, el, core, n9)
    firstof(xs) = isempty(xs) ? nothing : first(xs)
    deg(a) = count(in(core), g[a])
    nb9 = [a for a in g[n9] if a in core]
    c4 = firstof([a for a in nb9 if deg(a) == 3])
    c8 = firstof([a for a in nb9 if a != c4])
    c4n = c4 === nothing ? nothing : [a for a in g[c4] if a in core && a != n9]
    c5 = c4n === nothing ? nothing : firstof([a for a in c4n if deg(a) == 3])
    n3 = c4n === nothing ? nothing : firstof([a for a in c4n if a != c5])
    c5n = c5 === nothing ? nothing : [a for a in g[c5] if a in core && a != c4]
    n7 =
        (c5n === nothing || c8 === nothing) ? nothing :
        firstof([a for a in c5n if a in get(g, c8, Set{String}())])
    c6 = c5n === nothing ? nothing : firstof([a for a in c5n if a != n7])
    c2 = n3 === nothing ? nothing : firstof([a for a in g[n3] if a in core && a != c4])
    n1 = c2 === nothing ? nothing : firstof([a for a in g[c2] if a in core && a != n3])
    ok =
        all(!isnothing, (c4, c8, c5, n3, n7, c6, c2, n1)) &&
        all(a -> el[a] == "C", (c4, c8, c5, c6, c2)) &&
        all(a -> el[a] == "N", (n3, n7, n1)) &&
        Set([n9, c4, c8, n7, c5, n3, c2, n1, c6]) == core && c6 in g[n1]
    ok || return nothing
    s6 = sort([el[x] for x in subs_of(g, core, c6)])
    s2 = sort([el[x] for x in subs_of(g, core, c2)])
    if s6 == ["N"] && !any(in(("N", "O")), s2)
        return "A"
    elseif s6 == ["O"] && s2 == ["N"]
        return "G"
    end
    return nothing
end

"""
    ring_base(block) -> Union{Nothing,String,Symbol}

The base A/C/G/U/T a nucleic acid component's heavy-atom bond graph describes, or
`nothing` (`:ut`: a uracil or a thymine, which the ring alone does not decide).
"""
function ring_base(block)
    g = adjacency(block)
    el = Dict(get(block, :atoms, Tuple{String,String}[]))
    hit = glycosidic(g, el)
    hit === nothing && return nothing
    c1, n, ring = hit
    core = base_core(g, n, union(ring, [c1]))
    nn = count(a -> el[a] == "N", core)
    nc = count(a -> el[a] == "C", core)
    if length(core) == 6 && nn == 2 && nc == 4 && all(a -> count(in(core), g[a]) == 2, core)
        return ring_pyrimidine(g, el, core, n)
    elseif length(core) == 9 && nn == 4 && nc == 5
        return ring_purine(g, el, core, n)
    end
    return nothing
end

# The signals that may write a base; `validate` shows the precision that decides it.
const TRUSTED_SIGNALS = (:letter, :ring, :name)

"""
The base each inference signal finds for a nucleic acid `block`: `letter`, `ring` and
`name`.
"""
base_signals(block) = (letter = letter_base(get(block, "one_letter_code", nothing)),
    ring = ring_base(block), name = name_base(get(block, "name", nothing)))

"""
    infer_base(block) -> Tuple{String,String}

`(base, source)` of a nucleic acid `block` without a usable declared parent: the standard
residue itself (`self`), else the base of the first of letter, ring and name that finds
one, as long as the signals that found one agree; `("-", "-")` when none finds one or two
disagree.
"""
function infer_base(block)
    id = get(block, "id", nothing)
    sig = base_signals(block)
    found = [(s, getfield(sig, s)) for s in TRUSTED_SIGNALS if getfield(sig, s) !== nothing]
    function agree(bs)
        sets = [b === :ut ? Set(["U", "T"]) : Set([b]) for b in bs]
        return length(reduce(intersect, sets)) == 1
    end
    haskey(STANDARD_BASES, id) && return (STANDARD_BASES[id], "self")
    (!isempty(found) && agree(last.(found))) || return ("-", "-")
    i = findfirst(p -> last(p) !== :ut, found)
    i === nothing && return ("-", "-")
    base = last(found[i])
    src = first(s for (s, b) in found if b == base)
    return (base, String(src))
end

"""
    row_of(block, base_of) -> Vector{String}

The table row (the seven columns) of one data block `block` (field name to unquoted value,
as `read_blocks` makes it).
"""
function row_of(block, base_of)
    clean(s) = replace(s, '\t' => ' ')
    id = clean(block["id"])
    typ = lowercase(clean(get(block, "type", "?")))
    parent = clean(get(block, "mon_nstd_parent_comp_id", "?"))
    return String[id, component_class(typ), typ, parent in ("?", "") ? "-" : parent,
        clean(get(block, "formula", "?")), base_of[1], base_of[2]]
end

"""
    rowsOf(blocks) -> Vector{Vector{String}}

The unsorted table rows of the data `blocks`: five columns, then the base and its source.
"""
function rowsOf(blocks)
    parentOf = Dict{String,String}()
    for b in blocks
        p = get(b, "mon_nstd_parent_comp_id", "?")
        parentOf[b["id"]] = p in ("?", "") ? "-" : p
    end
    return [row_of(b, if nucleic(b)
        pb = parent_base(parentOf, parentOf[b["id"]])
        pb !== nothing ? (pb, "parent") : infer_base(b)
    else
        ("-", "-")
    end) for b in blocks]
end

# --- validating the inference

"""
    validate(blocks)

How well each signal finds the base of the nucleic acid components of `blocks` that
declare a parent (the base that parent leads to is the truth): `(total, signals, ring_ut,
combined)`, each signal's tally a `(found, correct, confusion)` with `confusion` counting
`(truth, predicted)`; `combined` is the same for `infer_base` as it stands.
"""
function validate(blocks)
    parentOf = Dict(b["id"] => get(b, "mon_nstd_parent_comp_id", "?") for b in blocks)
    judged = Tuple{String,Block}[]
    for b in blocks
        nucleic(b) || continue
        truth = parent_base(parentOf, parentOf[b["id"]])
        truth === nothing || push!(judged, (truth, b))
    end
    function tally(pairs)
        found = filter(p -> p[2] !== nothing, pairs)
        confusion = Dict{Tuple{String,String},Int}()
        for p in found
            confusion[p] = get(confusion, p, 0) + 1
        end
        return (found = length(found), correct = count(p -> p[1] == p[2], found), confusion)
    end
    signals = Dict(
        s => tally([
            (t, (v = getfield(base_signals(b), s); v === :ut ? nothing : v))
            for (t, b) in judged
        ]) for s in TRUSTED_SIGNALS
    )
    ut = [p for p in judged if base_signals(p[2]).ring === :ut]
    ring_ut = (found = length(ut), correct = count(p -> p[1] in ("U", "T"), ut))
    combined = tally([
        (
            t,
            (r = infer_base(Dict(k => v for (k, v) in b if k != "id"));
                r[2] != "-" ? r[1] : nothing),
        ) for (t, b) in judged
    ])
    return (total = length(judged), signals, ring_ut, combined)
end

"""
The report of `validate` as text: per signal the coverage and precision and the confusion
counts.
"""
function validation_text(v)
    function line(k, t)
        io = IOBuffer()
        print(io, rpad(string(k), 9), " found ", lpad(t.found, 4), " of ", v.total,
            " (coverage ", lpad(fmt("%.1f", 100.0 * t.found / max(v.total, 1)), 5),
            " %), correct ", lpad(t.correct, 4), " (precision ",
            lpad(fmt("%.1f", 100.0 * t.correct / max(t.found, 1)), 5), " %)\n")
        for ((tr, p), n) in sort(collect(t.confusion))
            print(
                io,
                "          ",
                tr,
                " -> ",
                p,
                ": ",
                n,
                tr == p ? "" : "   <-- wrong",
                "\n",
            )
        end
        return String(take!(io))
    end
    return string("validation on ", v.total,
        " nucleic acid components with a declared parent\n",
        join((line(k, v.signals[k]) for k in TRUSTED_SIGNALS)),
        "ring: ", v.ring_ut.found, " more are a uracil or a thymine (", v.ring_ut.correct,
        " truly U or T), not decided\n", line(:combined, v.combined))
end

# --- the table text

"The `#` header of the table; `rows` is the number of data rows."
header_lines(h, rows) = [
    "# Chemical Component Dictionary subset: " *
    "id, class, type, parent, formula, base, base_source.",
    "# Source: $(h.url)",
    "# Last-Modified $(h.source_date); fetched $(h.fetched).",
    "# class: dna or rna when the type names DNA or RNA, else other. parent: - when none.",
    "# base: the natural base (A C G U T, - if none) of a dna or rna component.",
    "# base_source: parent, self, letter, ring, name or -.",
    "# Generated by `bysl extract components`; do not edit by hand.",
    "# rows: $rows",
    "#id\tclass\ttype\tparent\tformula\tbase\tbase_source",
]

"""
    table_text(head, rows) -> String

The whole table as text (every line ended by a newline): the header for `head` (`url`,
`source_date`, `fetched`) and the `rows` sorted by id.
"""
function table_text(head, rows)
    sorted = sort(rows; by = first)
    for i in 2:length(sorted)
        first(sorted[i]) == first(sorted[i-1]) && throw(ToolError(
            "$WHO: component id $(first(sorted[i])) occurs twice", 1))
    end
    return join(vcat(header_lines(head, length(sorted)), [join(r, "\t") for r in sorted]),
        "\n") * "\n"
end

"""
    header_meta(text) -> Union{Nothing,NamedTuple}

The `url`, `source_date` and `fetched` the `# Source:` line of table `text` carries, or
`nothing` if it has none.
"""
function header_meta(text)
    m = match(r"(?m)^# Source: (\S+)\n# Last-Modified (.*?); fetched (.*?)\.$", text)
    m === nothing && return nothing
    return (url = String(m[1]), source_date = String(m[2]), fetched = String(m[3]))
end

# --- the source

is_url(s) = occursin(r"^https?://", s)

# The two libraries are loaded when a source is read, not when the tools load.
const DOWNLOADS = Base.PkgId(Base.UUID("f43a241f-c20a-4ad4-852c-f6b1247861c6"), "Downloads")
const CODEC = Base.PkgId(Base.UUID("944b1d66-785c-5afd-91f1-9de20f533193"), "CodecZlib")

# Downloads `url` to the file `dest` (streamed, redirects followed); returns the
# Last-Modified header text, or `nothing` if the server sent none.
function download!(url, dest)
    dl = Base.require(DOWNLOADS)
    response = Base.invokelatest(dl.request, url; output = dest)
    response.status == 200 ||
        throw(ToolError("$WHO: $url answered HTTP $(response.status)", 1))
    for (k, v) in response.headers
        lowercase(k) == "last-modified" && return String(v)
    end
    return nothing
end

# The modification time of the local file `path` in the HTTP date form.
function mtime_text(path)
    t = Dates.unix2datetime(mtime(path))
    return Dates.format(t, Dates.dateformat"e, d u yyyy HH:MM:SS") * " GMT"
end

# The data blocks of the gzip file `path` (see `read_blocks`).
function read_gz(path)
    codec = Base.require(CODEC)
    open(path) do file
        stream = Base.invokelatest(codec.GzipDecompressorStream, file)
        # run in the newest world: the codec was loaded just now
        try
            return Base.invokelatest(read_blocks, stream)
        finally
            Base.invokelatest(close, stream)
        end
    end
end

# Calls `f(blocks, last_modified)` with the data blocks of `source` (a gzip path or an
# http(s) URL, downloaded to a temporary file that is removed afterwards) and the text of
# its Last-Modified header or modification time.
function with_source(f, source)
    remote = is_url(source)
    tmp = remote ? tempname() * ".cif.gz" : nothing
    try
        lm = remote ? download!(source, tmp) : mtime_text(source)
        return f(read_gz(something(tmp, source)), lm)
    finally
        tmp === nothing || rm(tmp; force = true)
    end
end

"""
    generate(source, opts) -> String

Reads `source` (a gzip path or an http(s) URL) and returns the table text.
"""
function generate(source, opts)
    return with_source(source) do blocks, lm
        d = get(opts, :defaults, nothing)
        pick(k, fallback) = something(get(opts, k, nothing),
            d === nothing ? nothing : getfield(d, k), fallback)
        table_text(
            (url = pick(:url, is_url(source) ? source : DEFAULT_URL),
                source_date = pick(:source_date, something(lm, "unknown")),
                fetched = pick(:fetched, Dates.format(Dates.today(), "yyyy-mm-dd"))),
            rowsOf(blocks))
    end
end

# --- check and update

# Compares `text` with the table file `out`: prints the first differing lines to stderr
# and returns 1, or reports the table up to date and returns 0.
function check(text, out)
    have_text = isfile(out) ? slurp8(out) : nothing
    have = have_text === nothing ? String[] : split_lines(have_text)
    want = split_lines(text)
    if have_text == text
        println(out, " is up to date (", length(want), " lines)")
        return 0
    end
    println(stderr, out, " is out of date; regenerate: bysl extract components --update")
    shown = 0
    for i in 1:max(length(have), length(want))
        shown >= 10 && break
        a = i <= length(have) ? have[i] : nothing
        b = i <= length(want) ? want[i] : nothing
        a == b && continue
        println(stderr, "  line ", i, " checked-in: ", something(a, "nil"))
        println(stderr, "  line ", i, " generated : ", something(b, "nil"))
        shown += 1
    end
    return 1
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    (; opts, flags, specs) =
        split_args(WHO, ["--source-date", "--fetched", "--url", "--out"],
            ["--check", "--update", "--val-inference", "--help", "-h"], argv)
    opt(k) =
        (i = findlast(p -> first(p) == k, opts); i === nothing ? nothing : last(opts[i]))
    flag(f) = f in flags
    if flag("--help") || flag("-h")
        usage(USAGE)
        return 0
    end
    flag("--check") && flag("--update") && fail(WHO, "give --check or --update, not both")
    length(specs) > 2 && fail(WHO, "at most a SOURCE and an OUT")
    if flag("--val-inference")
        with_source(something(first(specs, 1)..., DEFAULT_URL)) do blocks, _
            print(validation_text(validate(blocks)))
        end
        return 0
    end
    source = isempty(specs) ? DEFAULT_URL : first(specs)
    out = length(specs) >= 2 ? specs[2] : something(opt("--out"), default_out())
    existing = flag("--check") && isfile(out) ? header_meta(slurp8(out)) : nothing
    t0 = time()
    text = generate(
        source,
        (url = opt("--url"), source_date = opt("--source-date"),
            fetched = opt("--fetched"), defaults = existing),
    )
    println(stderr, "read ", source, " in ", fmt("%.1f", time() - t0), " s")
    if flag("--check")
        return check(text, out)
    elseif flag("--update") || length(specs) >= 2
        spit8(out, text)
        println("wrote ", out)
    else
        print(text)
    end
    return 0
end

end

# --- the 3D-RISM partial molar volumes

module Pmv

using ...Common

const WHO = "bysl extract pmv"

const USAGE = """
Estimates partial molar volumes by 3D-RISM with a Bayesian group correction.

    bysl extract pmv SUBCOMMAND [args]

Runs dev/pmv-rism/pmv.py with the Python of the AmberTools environment (\$AMBERHOME,
default ~/.conda/envs/amber26: RDKit, antechamber, parmchk2, tleap, rism3d.snglpnt). The
subcommands are pmv.py's: run NAME SMILES NCONF CHARGE, batch FILE [--tier T], fit,
holdout, estimate NAME SMILES, row NAME SMILES COMMON IUPAC FORMULA CHARGE [--apply],
diagnostics REPORT, status, selftest (the last three are cheap and need no RISM).
`bysl extract pmv --help` lists them. A 3D-RISM job is long and takes every core: run
one at a time, on a quiet machine. Nothing is written to the package tables unless
`row --apply` is given.
"""

"The Python of the AmberTools environment (\$AMBERHOME or ~/.conda/envs/amber26)."
function amber_python()::String
    home = get(ENV, "AMBERHOME", joinpath(homedir(), ".conda", "envs", "amber26"))
    py = joinpath(home, "bin", "python")
    isfile(py) || throw(ToolError("no Python in $home (set AMBERHOME)", 1))
    return py
end

"`bysl extract pmv ARGS`: passes the arguments to dev/pmv-rism/pmv.py."
function run(argv::Vector{String})::Int
    if isempty(argv) || any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    script = in_root("dev", "pmv-rism", "pmv.py")
    return run_cmd([amber_python(), script, argv]) ? 0 : 1
end

end

const SUBS = [
    "formfactor" => (FormFactor, "rebuild the form-factor database from xraydb.sqlite"),
    "components" =>
        (Components, "regenerate the component table from the wwPDB dictionary"),
    "pmv" => (Pmv, "partial molar volumes by 3D-RISM (dev/pmv-rism/pmv.py)"),
]

const SUMMARY =
    "Regenerates the data bundled with the package.\n\n" *
    "    bysl extract SUBCOMMAND [options]"

"`bysl extract`: the subcommand `formfactor`, `components` or `pmv` and its options."
run(argv::Vector{String})::Int = dispatch("bysl extract", SUMMARY, SUBS, argv)

end
