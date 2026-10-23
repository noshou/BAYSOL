# SPDX-License-Identifier: LGPL-3.0-or-later

# Checks and repairs of the text of a .pdb that its readers cannot take as it is: chain ids
# reused by TER-separated blocks, true duplicate atoms, and the detection (only a log) of
# dummy-atom and fragment models, for which BAYSOL's behaviour is undefined.

"""
The atom records of the .pdb at `path` up to the first `ENDMDL`, by text scan (no strict
parse), with the TER block each belongs to.

# Returns
`(; lines, atoms, ters)`: the lines of the file; `atoms`, a vector of `(; i, block, record,
name, alt, resname, chain, num, occ, bfac, element)` (`i` the line index, `name` and `num`
stripped, `occ` and `bfac` `NaN` when not a number, `element` stripped); `ters`, the
`(line index, block)` of the TER records.

# Exceptions
- `SystemError`: `path` cannot be read.
"""
function _scan_atoms(path::AbstractString)
    lines = readlines(path)
    Atom = @NamedTuple{
        i::Int, block::Int, record::String, name::String, alt::Char, resname::String,
        chain::String, num::String, occ::Float64, bfac::Float64, element::String,
    }
    atoms = Atom[]
    ters = Tuple{Int,Int}[]
    block = 1
    num(l, a, b) = length(l) >= b ? something(tryparse(Float64, strip(l[a:b])), NaN) : NaN
    for (i, l) in enumerate(lines)
        startswith(l, "ENDMDL") && break
        if startswith(l, "TER")
            push!(ters, (i, block))
            block += 1
            continue
        end
        (startswith(l, "ATOM") || startswith(l, "HETATM")) && length(l) >= 27 || continue
        push!(
            atoms,
            (;
                i, block,
                record = startswith(l, "ATOM") ? "ATOM" : "HETATM",
                name = String(strip(SubString(l, 13, 16))),
                alt = l[17],
                resname = uppercase(String(strip(SubString(l, 18, 20)))),
                chain = String(strip(SubString(l, 22, 22))),
                num = String(strip(SubString(l, 23, 27))),
                occ = num(l, 55, 60), bfac = num(l, 61, 66),
                element = length(l) >= 78 ? String(strip(SubString(l, 77, 78))) : "",
            ),
        )
    end
    return (; lines, atoms, ters)
end

"""
The chain relabelling of a scanned structure: a TER-separated block whose chain reuses an id
**and** a residue number of an earlier block (two molecules both labelled `A`, numbered
alike) gets the next unused id of [`CHAIN_LETTERS`](@ref). A chain that only continues after
a TER (a ligand or waters under the protein's id, with other residue numbers) is left as it
is.

# Returns
`Dict{Tuple{Int,String},String}`: `(block, chain) => new chain id`, empty when nothing
needs relabelling.

# Exceptions
- `MoleculeError`: more chains need new ids than [`CHAIN_LETTERS`](@ref) has left.
"""
function _chain_relabelling(atoms)
    used = Set(a.chain for a in atoms)
    seen = Dict{String,Set{String}}()
    out = Dict{Tuple{Int,String},String}()
    spare = (c for c in CHAIN_LETTERS if !(string(c) in used))
    state = iterate(spare)
    for block in sort!(unique(a.block for a in atoms))
        chains = unique(a.chain for a in atoms if a.block == block)
        for chain in chains
            nums = Set(a.num for a in atoms if a.block == block && a.chain == chain)
            eff = chain
            if !isempty(intersect(nums, get(seen, chain, Set{String}())))
                state === nothing && throw(
                    MoleculeError(
                        "more chains reuse an id than the $(length(CHAIN_LETTERS)) " *
                        "chain ids available: cannot relabel them",
                    ),
                )
                eff = string(state[1])
                state = iterate(spare, state[2])
                out[(block, chain)] = eff
            end
            union!(get!(seen, eff, Set{String}()), nums)
        end
    end
    return out
end

"""
The plan to make a .pdb readable: [`_chain_relabelling`](@ref) of its blocks and the later
copies of true duplicate atoms (same chain after relabelling, residue number with insertion
code, atom name and alternate-location id) to drop.

# Returns
`(; scan, relabel, duplicates)`: the [`_scan_atoms`](@ref) result, the relabelling and the
set of line indices of the duplicates.
"""
function _structure_plan(path::AbstractString)
    scan = _scan_atoms(path)
    relabel = _chain_relabelling(scan.atoms)
    seen = Set{Tuple{String,String,String,Char}}()
    duplicates = Set{Int}()
    for a in scan.atoms
        chain = get(relabel, (a.block, a.chain), a.chain)
        key = (chain, a.num, a.name, a.alt)
        key in seen ? push!(duplicates, a.i) : push!(seen, key)
    end
    return (; scan, relabel, duplicates)
end

"The `(; relabelled, dropped)` counts of a [`_structure_plan`](@ref)."
_plan_counts(plan) =
    (; relabelled = length(plan.relabel), dropped = length(plan.duplicates))

# structures already warned about, so each is reported once per process
const _WARNED = Set{String}()
const _WARNED_LOCK = ReentrantLock()
function _warn_once(
    kind::String, path::AbstractString, msg::Union{AbstractString,Function};
    level = :warn,
)::Nothing
    first_time = @lock _WARNED_LOCK begin
        key = kind * "|" * abspath(path)
        key in _WARNED ? false : (push!(_WARNED, key); true)
    end
    if first_time
        text = msg isa Function ? msg() : msg   # built only when it is shown
        level === :info ? (@info text) : (@warn text)
    end
    return nothing
end
# `do` form: the message is built only if this is the first report for the structure
_warn_once(msg::Function, kind::String, path::AbstractString; level = :warn)::Nothing =
    _warn_once(kind, path, msg; level)

"""
    sanitized_copy(in_path, out_path) -> Union{Nothing,NamedTuple}

Make the .pdb at `in_path` readable when it needs it, writing the repaired copy to
`out_path`: a TER-separated block that reuses a chain id and its residue numbers (two
molecules both labelled `A`) is given the next unused chain id ([`CHAIN_LETTERS`](@ref)),
and later copies of **true** duplicate atoms (same chain after relabelling, residue number,
atom name and alternate-location id), which BioStructures refuses and which would count
twice in the scattering profile, are dropped. Both are logged (`@warn`, once per structure).
Chain ids never reach the scattering model, so the relabelling changes nothing in the
profile; the two real chains stay in the model.

# Returns
`nothing` when the file needs neither (nothing is written), else `(; relabelled, dropped)`,
the numbers of chains relabelled and duplicate atoms dropped.

# Exceptions
- `MoleculeError`: more chains need new ids than there are ids.
- `SystemError`: a path cannot be read or written.
"""
function sanitized_copy(in_path::AbstractString, out_path::AbstractString)
    plan = _structure_plan(in_path)
    counts = _plan_counts(plan)
    counts.relabelled == 0 && counts.dropped == 0 && return nothing
    scan = plan.scan
    block_of_ter = Dict(i => b for (i, b) in scan.ters)
    new_chain = Dict{Int,String}()
    for a in scan.atoms
        c = get(plan.relabel, (a.block, a.chain), nothing)
        c === nothing || (new_chain[a.i] = c)
    end
    for (i, b) in scan.ters
        l = scan.lines[i]
        # the chain of a TER record is that of the residue it ends
        chain = String(strip(length(l) >= 22 ? SubString(l, 22, 22) : ""))
        c = get(plan.relabel, (b, chain), nothing)
        c === nothing || (new_chain[i] = c)
    end
    open(out_path, "w") do io
        dropped_prev = false
        for (i, l) in enumerate(scan.lines)
            if i in plan.duplicates
                dropped_prev = true
                continue
            end
            if dropped_prev && startswith(l, "ANISOU")
                continue   # the record of a dropped atom
            end
            dropped_prev = false
            c = get(new_chain, i, nothing)
            if c !== nothing
                l = rpad(l, 22)
                l = l[1:21] * c * l[23:end]
            end
            println(io, l)
        end
    end
    if counts.relabelled > 0
        _warn_once("chains", in_path) do
            shown = join(
                (
                    "$(k[2] == "" ? "(blank)" : k[2]) → $v" for
                    (k, v) in sort!(collect(plan.relabel); by = first)
                ),
                ", ",
            )
            "$(counts.relabelled) chain(s) of \"$(basename(in_path))\" reuse a chain id " *
            "and its residue numbers: relabelled ($shown)"
        end
    end
    counts.dropped > 0 && _warn_once(
        "dups", in_path,
        "$(counts.dropped) duplicate atom(s) of \"$(basename(in_path))\" (same chain, " *
        "residue, atom name and alternate location) dropped",
    )
    return counts
end

"""
    structure_issues(path) -> NamedTuple

How many chains of the .pdb at `path` [`sanitized_copy`](@ref) would relabel and how many
duplicate atoms it would drop, without writing anything.

# Returns
`(; relabelled, dropped)`.

# Exceptions
- `MoleculeError`: more chains need new ids than there are ids.
- `SystemError`: `path` cannot be read.
"""
structure_issues(path::AbstractString) = _plan_counts(_structure_plan(path))

# heavy-atom test of a scanned atom
_is_heavy(a) =
    !(a.element in ("H", "D")) &&
    !(isempty(a.element) && !isempty(a.name) && first(lstrip(isdigit, a.name)) in "HD")

"Heavy atoms in a component `formula` (`C9 H13 N2 O9 P` is 13)."
function _heavy_in_formula(formula::AbstractString)::Int
    n = 0
    for tok in split(formula)
        m = match(r"^([A-Za-z]+)(\d*)$", tok)
        m === nothing && continue
        m[1] in ("H", "D") && continue
        n += isempty(m[2]) ? 1 : parse(Int, m[2])
    end
    return n
end

"""
    dummy_like_residues(path) -> NamedTuple

Find what looks like a dummy-atom or fragment model (CORAL/EOM linker residues, `UNK` dummy
residues, bead models, phosphates split off as separate residues), for which BAYSOL's
behaviour is **undefined**. Detection only: nothing is changed. A text scan, chains as
[`sanitized_copy`](@ref) would relabel them. The rules, per residue:

1. its name is one of [`DUMMY_RESIDUE_NAMES`](@ref) and it is an ATOM record (a HETATM
   `UNK` is an unknown ligand, as in SASDTK5, not a dummy residue);
2. an ATOM-record residue with at most [`DUMMY_MAX_HEAVY_ATOMS`](@ref) heavy atoms, unless
   the residue is a water, an ion or a component that small itself (a formula of at most
   that many heavy atoms) or its name cannot be a component id (`K+`);
3. a protein residue (the dictionary type names a peptide) lacking one of
   [`PROTEIN_BACKBONE_ATOMS`](@ref);
4. a nucleotide residue with fewer than [`BACKBONE_MIN`](@ref) of the
   [`BACKBONE_ATOMS`](@ref) and none of the [`NUCLEOBASE_ATOMS`](@ref);

and for the structure: duplicate atoms (same chain, residue, atom name, alternate location),
and more than [`DUMMY_ZERO_FRACTION`](@ref) of the atoms with a B-factor of exactly 0.00 and
an occupancy of 0.

# Returns
`(; residues, duplicates, zero_fraction, n)`: `residues`, a vector of `(; chain, num, name,
reasons)` for the flagged residues (`reasons`, symbols `:name :few_atoms :protein_backbone
:nucleotide_fragment`); `duplicates`, the number of duplicate atoms; `zero_fraction`, the
fraction of atoms with B = 0 and occupancy 0; `n`, the number of findings (flagged residues,
plus one for each structure-level rule that fires).

# Exceptions
- `ComponentError`: a residue name that could not be looked up (offline) and is needed.
- `SystemError`: `path` cannot be read.
"""
function dummy_like_residues(path::AbstractString)
    plan = _structure_plan(path)
    atoms = plan.scan.atoms
    res = Dict{Tuple{String,String},Any}()
    order = Tuple{String,String}[]
    for a in atoms
        i = a.i
        i in plan.duplicates && continue
        key = (get(plan.relabel, (a.block, a.chain), a.chain), a.num)
        r = get!(res, key) do
            push!(order, key)
            (;
                name = a.resname,
                atom = Set{String}(),
                heavy = Ref(0),
                record = Ref("HETATM"),
            )
        end
        push!(r.atom, replace(a.name, '*' => '\''))
        _is_heavy(a) && (r.heavy[] += 1)
        a.record == "ATOM" && (r.record[] = "ATOM")
    end
    found = NamedTuple{(:chain, :num, :name, :reasons),
        Tuple{String,String,String,Vector{Symbol}}}[]
    for key in order
        r = res[key]
        reasons = Symbol[]
        r.name in DUMMY_RESIDUE_NAMES && r.record[] == "ATOM" && push!(reasons, :name)
        info = r.name in WATER_NAMES ? nothing :
               try
            component(r.name)
        catch e
            e isa ComponentError || rethrow()
            nothing
        end
        if r.record[] == "ATOM" && r.heavy[] <= DUMMY_MAX_HEAVY_ATOMS &&
           !(r.name in WATER_NAMES) && !(:name in reasons)
            small =
                info !== nothing && info.type != "unknown" &&
                _heavy_in_formula(info.formula) <= DUMMY_MAX_HEAVY_ATOMS
            invalid =
                info !== nothing && info.type == "unknown" &&
                !occursin(r"^[A-Z0-9]{3,5}$", r.name)
            small || invalid || push!(reasons, :few_atoms)
        end
        if info !== nothing
            if occursin("peptide", info.type) && !occursin("peptide-like", info.type)
                all(in(r.atom), PROTEIN_BACKBONE_ATOMS) ||
                    r.heavy[] <= DUMMY_MAX_HEAVY_ATOMS ||
                    push!(reasons, :protein_backbone)
            elseif info.class in (:dna, :rna) &&
                   count(in(r.atom), BACKBONE_ATOMS) < BACKBONE_MIN &&
                   !any(in(r.atom), NUCLEOBASE_ATOMS)
                push!(reasons, :nucleotide_fragment)
            end
        end
        isempty(reasons) ||
            push!(found, (; chain = key[1], num = key[2], name = r.name, reasons))
    end
    zero = count(a -> a.bfac == 0.0 && a.occ == 0.0, atoms)
    zero_fraction = isempty(atoms) ? 0.0 : zero / length(atoms)
    ndup = length(plan.duplicates)
    n =
        length(found) + (ndup > 0 ? 1 : 0) +
        (DUMMY_ZERO_FRACTION < zero_fraction < DUMMY_ZERO_MAX_FRACTION ? 1 : 0)
    return (; residues = found, duplicates = ndup, zero_fraction, n)
end

"""
    log_dummy_like(path) -> NamedTuple

[`dummy_like_residues`](@ref) of `path`, logging what it finds with one `@warn` per
structure (counts per rule and the first few residues): "undefined behaviour". The flow
is not changed.

# Returns
The result of [`dummy_like_residues`](@ref).
"""
function log_dummy_like(path::AbstractString)
    d = dummy_like_residues(path)
    d.n == 0 && return d
    counts = Dict{Symbol,Int}()
    for r in d.residues, why in r.reasons
        counts[why] = get(counts, why, 0) + 1
    end
    parts = ["$(v) $(k)" for (k, v) in sort!(collect(counts); by = first)]
    d.duplicates > 0 && push!(parts, "$(d.duplicates) duplicate atoms")
    DUMMY_ZERO_FRACTION < d.zero_fraction < DUMMY_ZERO_MAX_FRACTION && push!(
        parts,
        "$(round(100 * d.zero_fraction; digits = 1)) % atoms with B = 0 and occupancy 0",
    )
    _warn_once("dummy", path) do
        first_few =
            join(("$(r.name) $(r.chain)$(r.num)" for r in first(d.residues, 5)), ", ")
        "\"$(basename(path))\" looks like a dummy-atom or fragment model (" *
        join(parts, "; ") * (isempty(first_few) ? "" : "; e.g. " * first_few) *
        "): BAYSOL's behaviour on it is undefined"
    end
    return d
end
