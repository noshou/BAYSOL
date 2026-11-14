# SPDX-License-Identifier: LGPL-3.0-or-later

# The harvesters: each keeps one generated file of the terminal interface or one constant
# of the Julia package in step with the sources it is derived from.
module Harvest

using ..Common

module Defaults

using ...Common

const WHO = "bysl harvest defaults"

const USAGE = """
Writes the settings defaults to JSON.

    bysl harvest defaults [--check]

    (none)      write tui/assets/data/default_settings.json and setting_relations.json
                from the params.jl files (dev/scripts/harvest-defaults.jl)
    --check     change nothing; exit 1 if one of the two is out of date
"""
# Runs the script that harvests the defaults into the file `out` (and the rules beside it);
# true on success.
harvest!(out)::Bool = sh(false, find_julia(), "--startup-file=no", "--project=" * root(),
    in_root("dev", "scripts", "harvest-defaults.jl"), out)

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    unknown = findfirst(!=("--check"), argv)
    unknown === nothing ||
        fail(WHO, "unknown option $(argv[unknown]) (the only one is --check)")
    resources = in_root("tui", "assets", "data")
    defaults_file = joinpath(resources, "default_settings.json")
    relations_file = joinpath(resources, "setting_relations.json")
    if "--check" in argv
        scratch = joinpath(resources, "default_settings.check.json")
        scratch_rules = joinpath(resources, "setting_relations.check.json")
        same(fresh, old) = slurp8(fresh) == (isfile(old) ? slurp8(old) : nothing)
        try
            harvest!(scratch) || return 1
            if same(scratch, defaults_file) && same(scratch_rules, relations_file)
                println(WHO, ": the defaults and the rules are up to date")
                return 0
            end
            println(WHO, ": default_settings.json or setting_relations.json is out of date")
            return 1
        finally
            for f in (scratch, scratch_rules)
                rm(f; force = true)
            end
        end
    end
    return harvest!(defaults_file) ? 0 : 1
end

end

module Solutes

using JSON3

using ...Common

const WHO = "bysl harvest solutes"

const USAGE = """
Writes the index of typeable solute names to JSON.

    bysl harvest solutes [--check]

    (none)      write tui/assets/data/solute_index.json from the alias and value
                tables of src/bulk-electron-density and polymer_families.json
    --check     change nothing; exit 1 if the file is out of date
"""

const BDE = ("src", "bulk-electron-density")

# What the molarity of a polymer means where it is not the moles of chains
# (src/bulk-electron-density/README.md, section Polymers): the first pattern that matches
# the grade or one of its aliases decides.
const BASIS_RULES = [r"dextran|amphipol|\bpvp\b|\bpva\b" => "per monomer unit",
    r"ficoll" => "per 1000 Da"]

"""
    basis_of(target, aliases) -> Union{Nothing,String}

What the molarity of a polymer is per, from its grade key and its aliases (all
lower-case): `"per monomer unit"` for dextran, amphipol, PVP and PVA, `"per 1000 Da"` for
Ficoll, `nothing` (per mole of chains) for the rest.
"""
function basis_of(target, aliases)
    for (rx, text) in BASIS_RULES
        any(s -> occursin(rx, s), vcat([target], aliases)) && return text
    end
    return nothing
end

read_json(parts...) = JSON3.read(slurp8(in_root(BDE..., parts...)))

lower(s) = lowercase(String(s))

"""
    kind_table(lookup, values, reserved)

One kind's names and targets from its alias table `lookup` (alias => target) and its value
table `values` (target => row), all keys lower-cased: `(targets, names, dropped)`, the
targets sorted, the names `(name, target position)` pairs (positions from 0).
"""
function kind_table(lookup, values, reserved)
    targets = sort(String[lower(k) for k in keys(values)])
    pos = Dict(t => i - 1 for (i, t) in enumerate(targets))
    pairs = vcat([(t, t) for t in targets], [(lower(a), lower(t)) for (a, t) in lookup])
    kept = filter(p -> haskey(pos, p[2]), pairs)
    names = [(n, pos[t]) for (n, t) in unique(filter(p -> !(p[1] in reserved), kept))]
    sort!(names; by = first)
    return (; targets, names, dropped = length(unique(pairs)) - length(unique(kept)))
end

"{target => basis} for the polymer targets of `lookup` and `values` that have one, sorted."
function polymer_bases(lookup, values)
    aliases = Dict{String,Vector{String}}()
    for (a, t) in lookup
        push!(get!(aliases, lower(t), String[]), lower(a))
    end
    found = Pair{String,String}[]
    for t in sort(String[lower(k) for k in keys(values)])
        b = basis_of(t, get(aliases, t, String[]))
        b === nothing || push!(found, t => b)
    end
    return found
end

"""
    index(nb_lookup, nb_values, pol_lookup, pol_values, families)

The index as data from the four tables (parsed JSON objects) and the families (the vector
of polymer_families.json).
"""
function index(nb_lookup, nb_values, pol_lookup, pol_values, families)
    fam = Dict{String,Any}()
    for f in families, n in f[:names]
        fam[lower(n)] = f[:id]
    end
    fam_names = sort!(collect(fam); by = first)
    nb = kind_table(nb_lookup, nb_values, Set{String}())
    pol = kind_table(pol_lookup, pol_values, Set(keys(fam)))
    return (nonbiological = nb,
        polymers = (;
            pol.targets,
            pol.names,
            basis = polymer_bases(pol_lookup, pol_values),
        ),
        families = fam_names, dropped = nb.dropped)
end

jstr(s) = JSON3.write(String(s))

"""
    render(idx) -> String

The text of the file for the index `idx`: one name to a line.
"""
function render(idx)::String
    items(xs, f) = "[\n" * join(("   " * f(x) for x in xs), ",\n") * "\n  ]"
    name_pair((n, i)) = "[" * jstr(n) * ", " * string(i) * "]"
    kind(k) = string("  \"targets\": ", items(k.targets, jstr), ",\n  \"names\": ",
        items(k.names, name_pair))
    basis = join((string("   ", jstr(t), ": ", jstr(b)) for (t, b) in idx.polymers.basis),
        ",\n")
    families =
        join((string("  [", jstr(n), ", ", jstr(id), "]") for (n, id) in idx.families),
            ",\n")
    return string("{\n \"nonbiological\": {\n", kind(idx.nonbiological),
        "\n },\n \"polymers\": {\n", kind(idx.polymers), ",\n  \"basis\": {\n", basis,
        "\n  }\n },\n \"families\": [\n", families, "\n ]\n}\n")
end

"The file text from the repository's tables."
function build_text()::String
    idx = index(read_json("non-biological", "nonbio_lookup.json"),
        read_json("non-biological", "nonbiological.json"),
        read_json("polymers", "polymers_lookup.json"),
        read_json("polymers", "polymers.json"),
        JSON3.read(slurp8(in_root("tui", "assets", "data", "polymer_families.json"))))
    idx.dropped > 0 && println(WHO, ": ", idx.dropped,
        " alias(es) left out: target not in the table")
    return render(idx)
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    unknown = findfirst(!=("--check"), argv)
    unknown === nothing ||
        fail(WHO, "unknown option $(argv[unknown]) (the only one is --check)")
    out_file = in_root("tui", "assets", "data", "solute_index.json")
    text = build_text()
    if "--check" in argv
        if text == (isfile(out_file) ? slurp8(out_file) : nothing)
            println(WHO, ": the solute index is up to date")
            return 0
        end
        println(WHO, ": solute_index.json is out of date")
        return 1
    end
    mkpath(dirname(out_file))
    spit8(out_file, text)
    println(WHO, ": wrote ", out_file)
    return 0
end

end

module Residues

using JSON3

using ...Common

const WHO = "bysl harvest residues"

const USAGE = """
Writes the residue table of the terminal interface to JSON.

    bysl harvest residues [--check]

    (none)      write tui/assets/data/residues.json from the Chemical Component
                Dictionary subset src/molecular-structure/components.tsv: the
                one-letter code of every amino-acid component, the base of every
                DNA and RNA component
    --check     change nothing; exit 1 if the file is out of date
"""

const TABLE_PATH = ("src", "molecular-structure", "components.tsv")

# The Julia file that defines `LEGACY_NUCLEOTIDE_NAMES`, the old residue names (`ADE`,
# `GUA`, `CYT`, `URI`, `THY`) the structure side still reads; the table of the terminal
# interface has them too, so a structure file with such names gives the same sequence.
const LEGACY_PATH = ("src", "molecular-structure", "molecular-structure.jl")

# The twenty standard amino acids and the two rare ones, three letters to one.
const STANDARD = Dict("ALA" => "A", "ARG" => "R", "ASN" => "N", "ASP" => "D",
    "CYS" => "C", "GLN" => "Q", "GLU" => "E", "GLY" => "G", "HIS" => "H", "ILE" => "I",
    "LEU" => "L", "LYS" => "K", "MET" => "M", "PHE" => "F", "PRO" => "P", "SER" => "S",
    "THR" => "T", "TRP" => "W", "TYR" => "Y", "VAL" => "V", "SEC" => "U", "PYL" => "O")

# The letter of a base that is none of A C G T U (inosine, a base that is not named).
const UNKNOWN_BASE = "N"

# The letter of an amino acid without a standard parent.
const UNKNOWN_AMINO = "X"

"""
    legacy_names(julia_text) -> Dict{String,String}

The name => base pairs of the `LEGACY_NUCLEOTIDE_NAMES` constant in the text of
`molecular-structure.jl`.

# Exceptions
- `ErrorException`: the constant is not there, or has no pair.
"""
function legacy_names(julia_text::AbstractString)
    m = match(r"const LEGACY_NUCLEOTIDE_NAMES\s*=\s*Dict\(([^)]*)\)"s, julia_text)
    m === nothing && error("LEGACY_NUCLEOTIDE_NAMES not found in molecular-structure.jl")
    pairs = [(p[1], p[2]) for p in eachmatch(r"\"(\w+)\"\s*=>\s*\"(\w)\"", m[1])]
    isempty(pairs) && error("LEGACY_NUCLEOTIDE_NAMES has no pair")
    return Dict(pairs)
end

"""
    residues(table_text, legacy = Dict()) -> (; protein, dna, rna)

The residue names of the component table text: `protein` maps every peptide-linking
component (`l-`, `d-` and plain, not `peptide-like`) to its one-letter code (the parent's
when it has exactly one standard parent, itself when it is standard, else `X`); `dna` and
`rna` map every component of that class with a linking type to its base (`N` when the
table names none). The `legacy` names are added when the table does not have them: `THY`
(base `T`) is DNA, the others RNA (a text of residue names has no `O2'` atom to tell
`ADE GUA CYT` of DNA from RNA; the structure side decides by that atom, here RNA is the
default and a `T` or `THY` in the chain makes it DNA).
"""
function residues(table_text::AbstractString, legacy = Dict{String,String}())
    protein = Dict{String,String}()
    dna = Dict{String,String}()
    rna = Dict{String,String}()
    for line in eachline(IOBuffer(table_text))
        (isempty(line) || startswith(line, '#')) && continue
        cols = split(line, '\t')
        length(cols) >= 6 || continue
        id, class, type, parent, base = cols[1], cols[2], cols[3], cols[4], cols[6]
        if endswith(type, "peptide linking")
            protein[id] = get(STANDARD, id, get(STANDARD, parent, UNKNOWN_AMINO))
        elseif class in ("dna", "rna") && endswith(type, "linking")
            (class == "dna" ? dna : rna)[id] = base == "-" ? UNKNOWN_BASE : base
        end
    end
    for (name, base) in legacy
        table = base == "T" ? dna : rna
        haskey(dna, name) || haskey(rna, name) || (table[name] = base)
    end
    return (; protein, dna, rna)
end

jstr(s) = JSON3.write(String(s))

"""
    render(res) -> String

The text of the file for `res` (the result of `residues`): one name to a line, sorted.
"""
function render(res)::String
    entry(d, k) = string("  ", jstr(k), ": ", jstr(d[k]))
    block(d) = join((entry(d, k) for k in sort!(collect(keys(d)))), ",\n")
    return string("{\n \"protein\": {\n", block(res.protein), "\n },\n \"dna\": {\n",
        block(res.dna), "\n },\n \"rna\": {\n", block(res.rna), "\n }\n}\n")
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    unknown = findfirst(!=("--check"), argv)
    unknown === nothing ||
        fail(WHO, "unknown option $(argv[unknown]) (the only one is --check)")
    out_file = in_root("tui", "assets", "data", "residues.json")
    legacy = legacy_names(slurp8(in_root(LEGACY_PATH...)))
    text = render(residues(slurp8(in_root(TABLE_PATH...)), legacy))
    if "--check" in argv
        if text == (isfile(out_file) ? slurp8(out_file) : nothing)
            println(WHO, ": the residue table is up to date")
            return 0
        end
        println(WHO, ": residues.json is out of date")
        return 1
    end
    mkpath(dirname(out_file))
    spit8(out_file, text)
    println(WHO, ": wrote ", out_file)
    return 0
end

end

module PmvMean

using JSON3

using ...Common

const WHO = "bysl harvest pmv-mean"

const USAGE = """
Writes the mean stated PMV uncertainty into its Julia constant.

    bysl harvest pmv-mean [--check]

    (none)      set NONBIO_MEAN_UNCERTAINTY in bulk-electron-density.jl to the mean of
                the stated uncertainties of nonbiological.json (six decimals)
    --check     change nothing; exit 1 if the constant is out of date
"""

const TABLE_PATH = ("src", "bulk-electron-density", "non-biological", "nonbiological.json")
const MODULE_PATH = ("src", "bulk-electron-density", "bulk-electron-density.jl")
const BEGIN_MARK = "# BEGIN harvested: nonbio-mean-uncertainty"
const END_MARK = "# END harvested: nonbio-mean-uncertainty"
const DECIMALS = 6

"""
    mean_uncertainty(json_text) -> Float64

The mean of the stated (not null) uncertainties of the rows of the table text `json_text`
(an object from name to `[electrons, volume, uncertainty]`), rounded to six decimals.
"""
function mean_uncertainty(json_text::AbstractString)::Float64
    rows = JSON3.read(json_text)
    us = Float64[]
    for row in values(rows)
        length(row) >= 3 && row[3] !== nothing && push!(us, Float64(row[3]))
    end
    isempty(us) && throw(ToolError("$WHO: the table states no uncertainty", 1))
    # rounded half up
    return floor(sum(us) / length(us) * 10.0^DECIMALS + 0.5) / 10.0^DECIMALS
end

"The Julia line that defines the constant as `value`."
literal_line(value) = "const NONBIO_MEAN_UNCERTAINTY = $value"

"""
    replace_literal(text, value) -> String

The module text `text` with the line between the markers replaced by the one for `value`;
an error when the markers are missing or do not enclose exactly one line.
"""
function replace_literal(text::AbstractString, value)::String
    lines = split(text, '\n'; keepempty = true)
    b = findfirst(==(BEGIN_MARK), lines)
    e = findfirst(==(END_MARK), lines)
    (b === nothing || e === nothing || e != b + 2) && throw(
        ToolError(
            "$WHO: the module file needs the line $BEGIN_MARK, one line, then $END_MARK",
            1),
    )
    lines[b+1] = literal_line(value)
    return join(lines, "\n")
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    unknown = findfirst(!=("--check"), argv)
    unknown === nothing ||
        fail(WHO, "unknown option $(argv[unknown]) (the only one is --check)")
    module_file = in_root(MODULE_PATH...)
    text = slurp8(module_file)
    value = mean_uncertainty(slurp8(in_root(TABLE_PATH...)))
    fresh = replace_literal(text, value)
    same = fresh == text
    if "--check" in argv
        if same
            println(WHO, ": NONBIO_MEAN_UNCERTAINTY = ", value, " is up to date")
            return 0
        end
        println(stderr, WHO, ": NONBIO_MEAN_UNCERTAINTY in ", module_file,
            " is out of date (the table gives ", value, "); run bysl harvest pmv-mean")
        return 1
    elseif same
        println(WHO, ": already up to date (", value, ")")
        return 0
    end
    spit8(module_file, fresh)
    println(WHO, ": NONBIO_MEAN_UNCERTAINTY = ", value)
    return 0
end

end

const SUBS = [
    "defaults" =>
        (Defaults, "tui/assets/data/default_settings.json from the params.jl files"),
    "solutes" => (Solutes, "tui/assets/data/solute_index.json from the solute tables"),
    "residues" => (Residues, "tui/assets/data/residues.json from the component table"),
    "pmv-mean" => (PmvMean, "the mean PMV uncertainty, as a Julia constant"),
]

const SUMMARY = """
Regenerates the generated files and constants.

    bysl harvest [defaults|solutes|residues|pmv-mean] [--check]

With no name all four run. --check changes nothing and exits 1 if one is out of date.
"""

"""
    run(argv) -> Int

`bysl harvest`: a subcommand and its options, or (no subcommand) every harvester with the
options given.
"""
function run(argv::Vector{String})::Int
    if isempty(argv) || first(argv) == "--check"
        status = 0
        for (name, (mod, _)) in SUBS
            println("--- harvest ", name)
            status = max(status, mod.run(argv))
        end
        return status
    end
    return dispatch("bysl harvest", SUMMARY, SUBS, argv)
end

end
