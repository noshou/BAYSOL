# SPDX-License-Identifier: LGPL-3.0-or-later

# PROPKA: per-residue pKa prediction (propka3 run as a subprocess) and the terminus
# protonation rule the pKas feed ([`Propka`](@ref) titration).

"""
Raised when propka3 cannot be run or its output cannot be parsed
(bad input path, non-zero exit, malformed .pka file).
"""
struct PropkaError <: Exception
    msg::String
end
Base.showerror(io::IO, e::PropkaError) = print(io, "PropkaError: ", e.msg)


"""
Parse a propka3 .pka output file into one record per standard titratable
group. Non-standard rows (ligand groups, carrying a trailing ligand
atom-type column) are skipped.

# Arguments
- `path`: path to a .pka file produced by propka3.
"""
function _parse_pka(path::AbstractString)
    lines = readlines(path)
    i = findfirst(@closure(l -> occursin("SUMMARY OF THIS PREDICTION", l)), lines)
    i === nothing && throw(PropkaError("no 'SUMMARY OF THIS PREDICTION' section in $path"))
    # line i+1 is the column header ("Group  pKa  model-pKa  ligand atom-type");
    # rows follow until a blank line or EOF.
    out = NamedTuple{(:resname, :resnum, :chain, :pKa),Tuple{String,Int,String,Float64}}[]
    for line in @view lines[(i+2):end]
        stripped = strip(line)
        isempty(stripped) && break
        toks = split(stripped)
        length(toks) < 4 && continue
        resname = String(toks[1])
        resname in _STANDARD_GROUPS || continue
        resnum = tryparse(Int, toks[2])
        # trailing '*' flags a coupled residue
        pka = tryparse(Float64, rstrip(toks[4], '*'))
        (resnum === nothing || pka === nothing) && continue
        chain = String(toks[3])
        push!(out, (resname = resname, resnum = resnum, chain = chain, pKa = pka))
    end
    return out
end

"Where [`propka_pKas`](@ref) caches the .pka for `pdb_path` (present ⟺ a cache hit)."
_pka_path(pdb_path::AbstractString) =
    joinpath(_store_dir(), splitext(basename(abspath(pdb_path)))[1] * ".pka")

"""
Run propka3 on `abspdb` in a private temporary directory inside `storedir` (no
change of the process's working directory) and move its `.pka` to `pka_path`. The
move is a rename within one directory, so a reader sees the whole file or none.

# Exceptions
- `PropkaError`: propka3 is missing, fails, or writes no `.pka`.
"""
function _run_propka3(abspdb::String, storedir::String, pka_path::String)::Nothing
    tools = force(_CONDA[])
    tools.propka3 === nothing &&
        throw(PropkaError("propka3 not found in CondaPkg environment"))
    tmp = mktempdir(storedir)
    try
        try
            cmd = setenv(`$(tools.propka3) $abspdb`, tools.env; dir = tmp)
            errfile = joinpath(tmp, "stderr.txt")
            try
                run(pipeline(cmd; stdout = devnull, stderr = errfile))
            catch e
                throw(
                    PropkaError(
                        "propka3 failed on $abspdb: $(sprint(showerror, e))" *
                        _stderr_tail(errfile),
                    ),
                )
            end
        catch e
            e isa PropkaError && rethrow()
            throw(PropkaError("propka3 failed on $abspdb: $(sprint(showerror, e))"))
        end
        made = joinpath(tmp, basename(pka_path))
        isfile(made) ||
            throw(PropkaError("propka3 did not produce expected output $pka_path"))
        mv(made, pka_path; force = true)
    finally
        rm(tmp; recursive = true, force = true)
    end
    return nothing
end

"""
Run propka3 on a PDB structure and return one record per standard
titratable group: (resname::String, resnum::Int, chain::String, pKa::Float64).

# Arguments
- `pdb_path`: path to a PDB file.

# Returns
Records for ASP, GLU, CYS, TYR, HIS, LYS, ARG, N+, C-
groups only; ligand/hetero rows are skipped.
"""
function propka_pKas(pdb_path::AbstractString)
    isfile(pdb_path) || throw(PropkaError("no such file: $pdb_path"))

    abspdb = abspath(pdb_path)
    storedir = _store_dir()
    pka_path = _pka_path(abspdb)

    if !isfile(pka_path)
        # one propka3 run per structure; others wait, then find the cached file
        @lock _path_lock(pka_path) begin
            isfile(pka_path) || _run_propka3(abspdb, storedir, pka_path)
        end
    end

    return _parse_pka(pka_path)
end

# ---------------------------------------------------------------------------
#          Henderson-Hasselbalch protonation state of a titratable group
# ---------------------------------------------------------------------------

"""
Henderson-Hasselbalch fraction of a **base** group's titratable atoms that
are protonated (and therefore, for a base, charged) at solution pH:

    f = 1 / (1 + 10^(pH - pKa))

f -> 1 for pH ≪ pKa, f -> 0 for pH ≫ pKa, and f == 0.5 at pH == pKa.
"""
_fraction_protonated(pH::Real, pKa::Real)::Real = 1 / (1 + 10^(pH - pKa))

"""
Henderson-Hasselbalch fraction of an **acid** group's titratable atoms that
are deprotonated (and therefore, for an acid, charged) at solution pH:

    f = 1 / (1 + 10^(pKa - pH))

i.e. 1 - [`_fraction_protonated`](@ref)(pH, pKa).
"""
_fraction_deprotonated(pH::Real, pKa::Real)::Real = 1 / (1 + 10^(pKa - pH))

"""
Whether an ionizable group of type ("acid" or "base") carries its
titratable hydrogen at solution pH. For a base, protonated ⟺ charged; for an
acid, protonated ⟺ neutral. Both reduce to the same rule on the group's
charged fraction: charged ⟺ fraction > 0.5. A group sitting exactly at its
own pKa (fraction == 0.5) rounds to its uncharged state for both types.
"""
function _group_protonated(type::AbstractString, pH::Real, pKa::Real)::Bool
    if type == "base"
        return _fraction_protonated(pH, pKa) > 0.5
    elseif type == "acid"
        return !(_fraction_deprotonated(pH, pKa) > 0.5)
    else
        throw(
            ArgumentError(
                "unknown charge-group type $(repr(type)) (expected \"acid\" or \"base\")",
            ),
        )
    end
end

"""
Partition `chains` by the pdb2pqr --neutraln/--neutralc flag combination
each one individually needs, using [`_group_protonated`](@ref) per chain's
own N+/C- record rather than demanding one global decision across the whole
structure. A chain with no free-terminus record of its own (no N+/C- entry
-- not every chain has a genuinely free terminus) needs no override and
lands in the empty-flags group.

Almost always returns a single-entry Dict (every chain needs the same
flags); a multi-entry result means different chains round to different
protonation states at this pH, which [`resolve_hydrogens`](@ref) resolves
by running pdb2pqr once per group.

# Arguments
- `pKa_records`: records as returned by [`propka_pKas`](@ref); only
    resname == "N+"/"C-" records are consulted.
- `pH`: solution pH, matching the pH [`propka_pKas`](@ref)'s caller intends
    to use with pdb2pqr.
- `chains`: every chain ID in the structure (from the text of the file),
    so a chain with no N+/C- record still appears in exactly one group.
"""
function _terminus_groups(
    pKa_records, pH::Real, chains::AbstractVector{<:AbstractString},
)::Dict{Vector{String},Vector{String}}
    n_neutral = Dict{String,Bool}()
    for r in pKa_records
        r.resname == "N+" || continue
        n_neutral[r.chain] = !_group_protonated("base", pH, r.pKa)
    end
    c_neutral = Dict{String,Bool}()
    for r in pKa_records
        r.resname == "C-" || continue
        c_neutral[r.chain] = _group_protonated("acid", pH, r.pKa)
    end

    groups = Dict{Vector{String},Vector{String}}()
    for chain in chains
        flags = String[]
        get(n_neutral, chain, false) && push!(flags, "--neutraln")
        get(c_neutral, chain, false) && push!(flags, "--neutralc")
        push!(get!(groups, flags, String[]), String(chain))
    end
    return groups
end

"""
Every chain with at least one N+/C- record in `pKa_records` -- derived from
`pKa_records` alone, no structure file I/O. A chain absent from this list has
no free terminus to override and is therefore guaranteed to need no
--neutraln/--neutralc flags regardless of what [`_terminus_groups`](@ref)
decides for the chains that do, which is what lets [`resolve_hydrogens`](@ref)
check for a termini conflict up front without needing to parse `pdb_path` at
all in the (overwhelmingly common) no-conflict case.
"""
_termini_chains(pKa_records)::Vector{String} =
    unique(String(r.chain) for r in pKa_records if r.resname == "N+" || r.resname == "C-")
