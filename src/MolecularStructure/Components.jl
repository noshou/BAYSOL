# SPDX-License-Identifier: LGPL-3.0-or-later

# Residue components: what a residue name is (nucleotide, amino acid, water, ligand, ...),
# from the bundled wwPDB table, then the local cache, then the RCSB, in that order.

# What a residue name stands for, from the wwPDB Chemical Component Dictionary, so that
# modified nucleotides (HETATM records such as PSU, 5MC, 1MA) can be told from waters, ions
# and ligands, which are not nucleotides.
#
# The lookup order of `component` is:
#   1. the bundled table `components.tsv` (every component of the dictionary at the time it
#      was generated, read once and lazily; source :builtin);
#   2. the cache directory joinpath(_store_dir(), COMPONENT_CACHE_DIR): a file <ID>.cif
#      there is used and nothing is downloaded (source :cache);
#   3. the RCSB (COMPONENT_URL), saved into that cache directory (source :download).
#
# The download goes through an injectable hook, `_COMPONENT_DOWNLOAD`, a Ref to a function
# hook(url::String, dest::String) that must write the file at `dest` or throw. The default
# is Downloads.download with a COMPONENT_TIMEOUT_S timeout; a test assigns its own function
# to simulate an offline or online network. A hook throws `_ComponentNotFound(url)` to say
# that the dictionary has no such component (the default does so for an HTTP 404): the
# residue is then taken as unknown (class :other, never a nucleotide) rather than an error,
# so a custom ligand name or an Amber-style residue name does not stop a run (nor does a
# name that cannot be a wwPDB id, such as `K+`: it is unknown with no lookup at all); any
# other failure (offline, timeout, bad content) is a ComponentError.

using BioStructures:
    MMCIFDict, ishetero, resname, atomname, chainid, resnumber, inscode,
    collectatoms

"""
Raised when a residue cannot be looked up: it is not in the bundled table, not in the
cache and the download failed (typically offline), or its cached file is not a component
file. (A name the dictionary answers "no such component" for is not an error: it is taken
as an unknown, non-nucleotide residue.)
"""
struct ComponentError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ComponentError) = print(io, "ComponentError: ", e.msg)

"""
The default download hook: `Downloads.download` with a [`COMPONENT_TIMEOUT_S`](@ref)
timeout; an HTTP 404 becomes `_ComponentNotFound`, any other failure is rethrown.
"""
function _download_default(url::AbstractString, dest::AbstractString)
    try
        Downloads.download(url, dest; timeout = COMPONENT_TIMEOUT_S)
    catch e
        e isa Downloads.RequestError && e.response.status == 404 &&
            throw(_ComponentNotFound(String(url)))
        rethrow()
    end
    return nothing
end

"""
Thrown by the download hook ([`_COMPONENT_DOWNLOAD`](@ref)) when the dictionary has no
component of that name (the server answers "not found"): a definitive answer, unlike a
network failure. [`component`](@ref) then reports the residue as unknown, not as a
nucleotide.
"""
struct _ComponentNotFound <: Exception
    url::String
end

"""
The record of a component: `id` (upper case), `class` (`:dna`, `:rna` or `:other`),
`type` (the dictionary's `_chem_comp.type`, lower case), `parent` (the standard residue a
modified one derives from, see below), `formula` (as in the dictionary, e.g.
`"C9 H13 N2 O9 P"`), `n_hydrogens` (hydrogens, deuterium included, of the free component's
formula), `source` (`:builtin`, `:cache` or `:download`: where this lookup found it), `base`
(the natural base `A C G U T` a DNA/RNA component stands for, `nothing` when none or not
known) and `base_source` (where `base` comes from: `:parent`, `:self` for a standard
residue, `:letter` the dictionary's one-letter code, `:ring` the ring chemistry, `:name` the
component's name; `:none` when `base` is `nothing`).

`parent` is what the dictionary **declares**, `base` the base the component stands for,
declared or **inferred**, `base_source` says which. The inference is offline, in
`dev/extract_components.clj`, validated there against the declared parents, and only the
bundled table has it: a component read from a cached or downloaded file has the base of its
declared parent, else `nothing`. Nothing in loading, the force-field choice or the
classification depends on `parent` or `base`.

`parent === nothing` means "no declared (or resolvable) parent" and is never an error: the
dictionary's list is split and deduplicated (`DT, DT` is `DT`), a non-standard parent
(`TTD`) is followed up to a standard id, and what cannot be resolved is `nothing`. Of the
843 DNA/RNA components of the bundled table 565 declare a parent and 278 do not (14 of
those are the standard ids, the rest terminal variants and unnatural nucleotides). Nothing
in loading, the force-field choice or the classification depends on the parent.
"""
const ComponentInfo = @NamedTuple{
    id::String,
    class::Symbol,
    type::String,
    parent::Union{Nothing,String},
    formula::String,
    n_hydrogens::Int,
    source::Symbol,
    base::Union{Nothing,String},
    base_source::Symbol,
}

"""
Hydrogens in a dictionary formula such as `"C9 H13 N2 O9 P"`: the count of the `H` and `D`
(deuterium) entries; an entry without a number counts once.
"""
function _count_hydrogens(formula::AbstractString)::Int
    n = 0
    for tok in split(formula)
        m = match(r"^([A-Za-z]+)(\d*)$", tok)
        m === nothing && continue
        (m[1] == "H" || m[1] == "D") || continue
        n += isempty(m[2]) ? 1 : parse(Int, m[2])
    end
    return n
end

"`:dna`, `:rna` or `:other` from a dictionary `_chem_comp.type` (lower case)."
function _component_class(type::AbstractString)::Symbol
    occursin("dna", type) && return :dna
    occursin("rna", type) && return :rna
    return :other
end

"""
The standard parent of a component from the dictionary's raw `parent` text: comma/blank
separated lists are split and deduplicated (`"DT, DT"` is `DT`); a single standard id
([`STANDARD_NUCLEOTIDES`](@ref)) is kept; a single non-standard id (`TTD`) is followed
through the table up to a standard id, with a guard against cycles. `nothing` when there is
no declared parent, the list names several different ones, or the chain does not end in a
standard id (`standard`, the nucleotides' by default). Never an error. `parent_of(id)`
gives the raw parent text of another component
(`nothing` if none or unknown).
"""
function _resolve_parent(
    raw, parent_of, seen = String[]; standard = STANDARD_NUCLEOTIDES,
)
    raw === nothing && return nothing
    ids = unique(filter(!isempty, String.(split(raw, r"[,\s]+"))))
    length(ids) == 1 || return nothing
    p = only(ids)
    p in standard && return p
    p in seen && return nothing
    return _resolve_parent(parent_of(p), parent_of, push!(seen, p); standard)
end

"""
All rows of the bundled table, by id, read from `components.tsv` (`#` lines are comments).

# Exceptions
- `ComponentError`: the file is missing or has a row that has neither the five fields
    (`id`, `class`, `type`, `parent`, `formula`) nor those five plus `base` and
    `base_source` (`-` for none; a five-field row has no base).
"""
function _read_components()::Dict{String,ComponentInfo}
    isfile(COMPONENTS_TABLE) || throw(
        ComponentError("the bundled component table is missing: $COMPONENTS_TABLE"),
    )
    table = Dict{String,ComponentInfo}()
    for line in eachline(COMPONENTS_TABLE)
        (isempty(line) || startswith(line, '#')) && continue
        f = split(line, '\t')
        length(f) in (5, 7) || throw(
            ComponentError("malformed row in $COMPONENTS_TABLE: \"$line\""),
        )
        id = String(f[1])
        table[id] = ComponentInfo((
            id, Symbol(f[2]), String(f[3]),
            f[4] == "-" ? nothing : String(f[4]), String(f[5]),
            _count_hydrogens(f[5]), :builtin,
            length(f) == 7 && f[6] != "-" ? String(f[6]) : nothing,
            length(f) == 7 && f[7] != "-" ? Symbol(f[7]) : :none,
        ))
    end
    raw = Dict(id => i.parent for (id, i) in table)
    for (id, i) in table
        i.parent === nothing && continue
        parent = _resolve_parent(i.parent, p -> get(raw, p, nothing))
        parent == i.parent || (table[id] = (; i..., parent))
    end
    return table
end

"""
The standard amino acid each amino acid component of the table derives from, by id, read
from `components.tsv`: the parent column of the rows whose type names a peptide
([`_is_amino_type`](@ref)), split, deduplicated and followed up to one of
[`STANDARD_AMINO_ACIDS`](@ref) like the nucleotides' ([`_resolve_parent`](@ref)); rows
whose parent cannot be resolved (a list of different ones, none) are absent.

# Exceptions
- `ComponentError`: the table is missing or malformed.
"""
function _read_amino_parents()::Dict{String,String}
    isfile(COMPONENTS_TABLE) || throw(
        ComponentError("the bundled component table is missing: $COMPONENTS_TABLE"),
    )
    raw = Dict{String,Union{Nothing,String}}()
    types = Dict{String,String}()
    for line in eachline(COMPONENTS_TABLE)
        (isempty(line) || startswith(line, '#')) && continue
        f = split(line, '\t')
        length(f) in (5, 7) || throw(
            ComponentError("malformed row in $COMPONENTS_TABLE: \"$line\""),
        )
        raw[f[1]] = f[4] == "-" ? nothing : String(f[4])
        types[f[1]] = f[3]
    end
    out = Dict{String,String}()
    for (id, type) in types
        _is_amino_type(type) || continue
        p = _resolve_parent(
            raw[id], q -> get(raw, q, nothing); standard = STANDARD_AMINO_ACIDS,
        )
        p === nothing || (out[id] = p)
    end
    return out
end

# Components not in the table, resolved once per process (the source of the first lookup is
# kept as `:cache` afterwards: the file is in the cache by then).
const _COMPONENT_MEMO = Dict{String,ComponentInfo}()
const _COMPONENT_MEMO_LOCK = ReentrantLock()
const _COMPONENT_LOCKS = KeyedCache{String,ReentrantLock}()

"The file a downloaded component is cached in."
_component_path(id::AbstractString) =
    joinpath(_store_dir(), COMPONENT_CACHE_DIR, id * ".cif")

"""
First element of a CIF value (the reader returns vectors), without quotes; `nothing` when
absent or `?`/`.`.
"""
function _cif_value(d, key::AbstractString)::Union{Nothing,String}
    haskey(d, key) || return nothing
    v = d[key]
    v isa AbstractVector && (v = isempty(v) ? nothing : first(v))
    v === nothing && return nothing
    s = strip(strip(String(v)), ['"', '\''])
    return (isempty(s) || s == "?" || s == ".") ? nothing : String(s)
end

"""
The record of the component file at `path` (read with `BioStructures.MMCIFDict`).

# Exceptions
- `ComponentError`: not a readable component file, its `_chem_comp.id` is not `id`, or it
    has no (or an empty) `_chem_comp.type` or `_chem_comp.formula`.
"""
function _parse_component(id::AbstractString, path::AbstractString, source::Symbol)
    local d
    try
        d = MMCIFDict(path)
    catch e
        throw(
            ComponentError("\"$path\" is not a component file: $(sprint(showerror, e))"),
        )
    end
    got = _cif_value(d, "_chem_comp.id")
    (got !== nothing && uppercase(got) == id) || throw(
        ComponentError("\"$path\" describes $(repr(got)), not residue $id"),
    )
    type = lowercase(something(_cif_value(d, "_chem_comp.type"), ""))
    formula = something(_cif_value(d, "_chem_comp.formula"), "")
    for (field, value) in (("type", type), ("formula", formula))
        isempty(value) && throw(
            ComponentError(
                "\"$path\" has no _chem_comp.$field: not a usable component file",
            ),
        )
    end
    table = force(_COMPONENT_TABLE)
    parent = _resolve_parent(
        _cif_value(d, "_chem_comp.mon_nstd_parent_comp_id"),
        p -> (i = get(table, p, nothing); i === nothing ? nothing : i.parent),
    )
    pinfo = parent === nothing ? nothing : get(table, parent, nothing)
    base = pinfo === nothing ? nothing : pinfo.base
    return ComponentInfo((
        id, _component_class(type), type, parent, formula,
        _count_hydrogens(formula), source,
        base, base === nothing ? :none : :parent,
    ))
end

"""
Fetch the component file of `id` into the cache: the download goes to a temporary file in
the cache directory, is checked to be a component file and only then moved into place, so
a failed or partial download never leaves a file behind.

# Exceptions
- `ComponentError`: the download failed (typically offline) or gave no component file.
"""
function _download_component(id::AbstractString, dest::AbstractString)::Nothing
    url = replace(COMPONENT_URL, "{ID}" => id)
    mkpath(dirname(dest))
    tmpdir = mktempdir(dirname(dest))
    try
        tmp = joinpath(tmpdir, id * ".cif")
        try
            _COMPONENT_DOWNLOAD[](url, tmp)
            _parse_component(id, tmp, :download)
        catch e
            (e isa _ComponentNotFound || e isa ComponentError) && rethrow()
            throw(
                ComponentError(
                    "couldn't look up residue $id; are you offline? " *
                    "($(sprint(showerror, e)))",
                ),
            )
        end
        mv(tmp, dest; force = true)
    finally
        rm(tmpdir; recursive = true, force = true)
    end
    return nothing
end

"""
The lookup of an id that is not in the table: the cache first, a download otherwise,
under the lock of the cache path so concurrent callers fetch once.
"""
function _lookup_external(id::String)::ComponentInfo
    hit = @lock _COMPONENT_MEMO_LOCK get(_COMPONENT_MEMO, id, nothing)
    hit === nothing || return hit
    # a name that cannot be a wwPDB id (`K+`, empty, longer than 5): an unknown residue,
    # without any lookup, as for a "not found" answer
    occursin(r"^[A-Z0-9]{1,5}$", id) ||
        return ComponentInfo((
            id, :other, "unknown", nothing, "", 0, :builtin, nothing, :none,
        ))
    path = _component_path(id)
    info = try
        _fetch_component(id, path)
    catch e
        e isa _ComponentNotFound || rethrow()
        # not a component of the dictionary (a custom ligand, an Amber residue name):
        # nothing to cache on disk, remembered for this process only
        ComponentInfo((id, :other, "unknown", nothing, "", 0, :download, nothing, :none))
    end
    @lock _COMPONENT_MEMO_LOCK _COMPONENT_MEMO[id] = (; info..., source = :cache)
    return info
end

"The record of `id` from the cache file `path`, downloaded into it first if need be."
function _fetch_component(id::String, path::String)::ComponentInfo
    return @lock get!(ReentrantLock, _COMPONENT_LOCKS, path) begin
        if isfile(path)
            # an invalid cached file (truncated, wrong content) is ignored and fetched
            # once more; the result of that fetch is validated before it is cached
            try
                return _parse_component(id, path, :cache)
            catch e
                e isa ComponentError || rethrow()
                rm(path; force = true)
            end
        end
        _download_component(id, path)
        _parse_component(id, path, :download)
    end
end

"""
The record of a name of [`AMBER_NUCLEIC_NAMES`](@ref): the nucleotide it is, with the
plain base `parent` it stands for and that base's formula and hydrogen count (a terminal
residue has a different count, so `n_hydrogens` is the base's); `base` is the plain
base's, with source `:self`.
"""
function _amber_component(id::String, class::Symbol, parent::String)::ComponentInfo
    base = force(_COMPONENT_TABLE)[parent]
    return ComponentInfo((
        id, class, string(class) * " linking", parent, base.formula, base.n_hydrogens,
        :builtin, base.base, base.base === nothing ? :none : :self,
    ))
end

"""
    component(id::AbstractString) -> ComponentInfo

The record of the residue `id` (matched case-insensitively): [`AMBER_NUCLEIC_NAMES`](@ref)
first, then the bundled table, then
the local cache, then a download into the cache (see the lookup order of this file's
module documentation). `ComponentInfo` is the named tuple
`(id, class, type, parent, formula, n_hydrogens, source)`; `source` is `:builtin`,
`:cache` or `:download`; `parent` as in [`ComponentInfo`](@ref).

# Returns
The [`ComponentInfo`](@ref) of `id` (upper case in the result).

# Exceptions
- `ComponentError`: `id` is not in the table or the cache and could not be downloaded
    ("couldn't look up residue ID; are you offline?" and the reason), or a cached file is
    not a component file.
"""
function component(id::AbstractString)::ComponentInfo
    key = uppercase(strip(String(id)))
    amber = get(AMBER_NUCLEIC_NAMES, key, nothing)
    amber === nothing || return _amber_component(key, amber...)
    info = get(force(_COMPONENT_TABLE), key, nothing)
    info === nothing || return info
    return _lookup_external(key)
end

"""
    is_nucleotide(id::AbstractString) -> Bool

Whether the residue `id` is a DNA or RNA component (standard or modified: `DC`, `A`, `PSU`,
`5MC`, ...). The water names ([`WATER_NAMES`](@ref)) are `false` without any lookup.

# Returns
`true` when the class of [`component`](@ref)`(id)` is `:dna` or `:rna`.

# Exceptions
- `ComponentError`: as for [`component`](@ref).
"""
function is_nucleotide(id::AbstractString)::Bool
    key = uppercase(strip(String(id)))
    key in WATER_NAMES && return false
    return component(key).class in (:dna, :rna)
end

"""
    nucleotide_selector(at) -> Bool

A BioStructures atom selector that keeps every standard (ATOM) atom and the HETATM atoms
of nucleotides (modified bases), and drops waters, ions and ligands: the replacement of
`standardselector` wherever a structure is read or written.

# Returns
`!ishetero(at) || is_nucleotide(resname(at))`.

# Exceptions
- `ComponentError`: as for [`is_nucleotide`](@ref), for a HETATM residue name.
"""
nucleotide_selector(at) = !ishetero(at) || is_nucleotide(resname(at))

"""
Whether a dictionary `type` is an amino acid's: it names `peptide linking` (L, D and plain)
or an amino or carboxy terminus of a peptide, and not `peptide-like`.
"""
function _is_amino_type(type::AbstractString)::Bool
    occursin("peptide-like", type) && return false
    occursin("peptide linking", type) && return true
    return occursin("peptide", type) && occursin("terminus", type)
end

"""
    is_amino_acid(id::AbstractString) -> Bool

Whether the residue `id` is an amino acid: its dictionary type is a peptide-linking one
(standard, modified, D) or a peptide terminus ([`_is_amino_type`](@ref)). `UNK`, the unknown
residue, and the water names are `false` without a lookup, and so is every name the
dictionary does not know.

# Returns
`true` for an amino acid component.

# Exceptions
- `ComponentError`: as for [`component`](@ref).
"""
function is_amino_acid(id::AbstractString)::Bool
    key = uppercase(strip(String(id)))
    (key == "UNK" || key in WATER_NAMES) && return false
    return _is_amino_type(component(key).type)
end

"""
    amino_parent(id::AbstractString) -> Union{Nothing,String}

The standard amino acid ([`STANDARD_AMINO_ACIDS`](@ref)) the amino acid component `id` is
derived from (`MSE` is `MET`, `SEP` is `SER`), read from the bundled table; `nothing` when
`id` is not an amino acid, has no declared or resolvable parent, or is not in the table (a
component from the cache or a download has no amino parent here).
"""
amino_parent(id::AbstractString) =
    get(force(_AMINO_PARENTS), uppercase(strip(String(id))), nothing)

"""
    polymer_selector(at) -> Bool

The selector of the loader and the canonical writer: standard (ATOM) atoms and the HETATM
atoms of residues that are part of the polymer, nucleotides and amino acids, modified ones
included (`PSU`, `MSE`): `!ishetero(at) || is_nucleotide(name) || is_amino_acid(name)`.
Waters, ions, ligands, saccharides and `UNK` are dropped.

# Exceptions
- `ComponentError`: as for [`is_nucleotide`](@ref), for a HETATM residue name.
"""
function polymer_selector(at)
    ishetero(at) || return true
    name = resname(at)
    return is_nucleotide(name) || is_amino_acid(name)
end

"""
The distinct residue names of the ATOM and HETATM records of the .pdb at `path`, in order
of first appearance, waters ([`WATER_NAMES`](@ref)) left out. A light text scan of columns
18-20: it needs no valid structure, as BioStructures' strict parser does.

# Returns
`Vector{String}`, names stripped and upper case.

# Exceptions
- `SystemError`: `path` cannot be read.
"""
function residue_names(path::AbstractString)::Vector{String}
    seen = Set{String}()
    names = String[]
    for line in eachline(path)
        (startswith(line, "ATOM") || startswith(line, "HETATM")) || continue
        length(line) >= 20 || continue
        n = uppercase(strip(SubString(line, 18, 20)))
        (isempty(n) || n in WATER_NAMES || n in seen) && continue
        push!(seen, n)
        push!(names, n)
    end
    return names
end

"""
The legacy-named nucleotide residues ([`LEGACY_NUCLEOTIDE_NAMES`](@ref)) among `records`,
an iterable of `(chain, number, residue name, atom name)` text tuples (chain and number,
with the insertion code, stripped; atom names with `*` read as `'`).

A residue qualifies when it has a `P` atom, or at least [`BACKBONE_MIN`](@ref) of the
[`BACKBONE_ATOMS`](@ref) and its chain has at least two residues that have a `P` or that
many backbone atoms (so a free adenine or uridine ligand, and a lone residue, are not
nucleotides). `THY` is DNA, `URI` RNA, and `ADE GUA CYT` RNA when the residue has an `O2'`
atom, else DNA.

# Returns
`Dict{Tuple{String,String},NamedTuple}`: `(chain, number) => (; name, class, base)`.
"""
function _legacy_nucleotides(records)
    res = Dict{Tuple{String,String},Tuple{String,Set{String}}}()
    for (chain, number, name, atom) in records
        haskey(LEGACY_NUCLEOTIDE_NAMES, name) || continue
        r = get!(() -> (name, Set{String}()), res, (chain, number))
        push!(r[2], replace(atom, '*' => '\''))
    end
    carries(atoms) = "P" in atoms || count(in(atoms), BACKBONE_ATOMS) >= BACKBONE_MIN
    per_chain = Dict{String,Int}()
    for ((chain, _), (_, atoms)) in res
        carries(atoms) && (per_chain[chain] = get(per_chain, chain, 0) + 1)
    end
    Legacy = @NamedTuple{name::String, class::Symbol, base::String}
    out = Dict{Tuple{String,String},Legacy}()
    for (key, (name, atoms)) in res
        (("P" in atoms) || (carries(atoms) && get(per_chain, key[1], 0) >= 2)) || continue
        class = name == "THY" ? :dna : name == "URI" ? :rna :
                                       ("O2'" in atoms ? :rna : :dna)
        out[key] = (; name, class, base = LEGACY_NUCLEOTIDE_NAMES[name])
    end
    return out
end

"""
[`_legacy_nucleotides`](@ref) of the .pdb at `path`, by text scan of the ATOM/HETATM
records (no strict parse).

# Returns
`Dict` `(chain, number) => (; name, class, base)`, empty when there is none.

# Exceptions
- `SystemError`: `path` cannot be read.
"""
function legacy_nucleotides_in_file(path::AbstractString)
    records = Iterators.filter(!isnothing, (
        _legacy_record(l) for l in eachline(path)
    ))
    return _legacy_nucleotides(records)
end

function _legacy_record(line::AbstractString)
    (startswith(line, "ATOM") || startswith(line, "HETATM")) || return nothing
    length(line) >= 27 || return nothing
    name = String(strip(SubString(line, 18, 20)))
    haskey(LEGACY_NUCLEOTIDE_NAMES, uppercase(name)) || return nothing
    return (
        String(strip(SubString(line, 22, 22))),
        String(strip(SubString(line, 23, 27))),
        uppercase(name),
        String(strip(SubString(line, 13, 16))),
    )
end

"[`_legacy_nucleotides`](@ref) of the atoms of a parsed BioStructures `model`."
function legacy_nucleotides_in_model(model)
    is_legacy(at) = haskey(LEGACY_NUCLEOTIDE_NAMES, uppercase(resname(at)))
    records = (
        (_residue_key(at)..., uppercase(resname(at)), atomname(at))
        for at in collectatoms(model, is_legacy)
    )
    return _legacy_nucleotides(records)
end

"The `(chain, number with insertion code)` key of an atom's residue, stripped."
_residue_key(at) = (
    String(strip(chainid(at))), string(resnumber(at)) * strip(string(inscode(at))),
)

"""
The atom selector of the loader and the canonical writer for a parsed `model`: standard
atoms, HETATM atoms of nucleotides and amino acids ([`polymer_selector`](@ref)) and
the HETATM atoms of
the legacy-named nucleotide residues of `model` ([`legacy_nucleotides_in_model`](@ref)).
"""
function _model_selector(model)
    legacy = legacy_nucleotides_in_model(model)
    isempty(legacy) && return polymer_selector
    return function (at)
        polymer_selector(at) && return true
        return haskey(legacy, _residue_key(at))
    end
end
