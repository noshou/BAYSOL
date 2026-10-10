# SPDX-License-Identifier: LGPL-2.1-or-later

# Protonation, through two external command-line tools run as plain
# subprocesses in an isolated CondaPkg-managed Python environment:
# propka3 (per-residue-instance pKa prediction, `propka_pKas`) and
# pdb2pqr (explicit-hydrogen structure generation, `resolve_hydrogens`),
# which uses the pKa records to choose each chain's terminus protonation.

using CondaPkg: CondaPkg
using FastClosures: @closure
using ..Runtime: KeyedCache
using BioStructures:
    BioStructures, PDBFormat, writepdb, collectatoms,
    chainid, chainids, collectmodels

# ---------------------------------------------------------------------------
#                         PROPKA: per-residue pKa prediction
# ---------------------------------------------------------------------------

"""
The CondaPkg environment's variables and the paths of the two tools run
from it, captured once. `CondaPkg.withenv` edits the process-wide `ENV`
for the duration of its block, which is not safe beside other tasks; the
subprocesses are given this environment explicitly instead (`setenv`).
"""
struct _CondaTools
    env     :: Dict{String,String}
    propka3 :: Union{Nothing,String}
    pdb2pqr :: Union{Nothing,String}
end

function _read_conda_tools()::_CondaTools
    CondaPkg.withenv() do
        _CondaTools(
            Dict{String,String}(ENV),
            CondaPkg.which("propka3"),
            CondaPkg.which("pdb2pqr"),
        )
    end
end

__init__() = (_CONDA[] = Lazy{_CondaTools}(_read_conda_tools))

_path_lock(path::AbstractString) = get!(ReentrantLock, _PATH_LOCKS, String(path))

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
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
        catch e
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
#                    pdb2pqr: explicit-hydrogen structure generation
# ---------------------------------------------------------------------------

"""
Raised when pdb2pqr cannot be run or produces no usable output (bad input
path, non-zero exit, missing expected output file).
"""
struct Pdb2pqrError <: Exception
    msg::String
end
Base.showerror(io::IO, e::Pdb2pqrError) = print(io, "Pdb2pqrError: ", e.msg)

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
- `chains`: every chain ID in the structure (from `BioStructures.chainids`),
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

"""
Run pdb2pqr on `in_path` with the given global --neutraln/--neutralc flags,
writing hydrogenated output to `out_path`. Throws [`Pdb2pqrError`](@ref) if
pdb2pqr isn't found, exits non-zero, or doesn't produce `out_path`.
"""
function _run_pdb2pqr(
    in_path::AbstractString, flags::Vector{String}, pH::Real, out_path::AbstractString,
)::Nothing
    tmp_pqr = out_path * ".pqr"
    tools = force(_CONDA[])
    pdb2pqr = tools.pdb2pqr
    pdb2pqr === nothing && throw(Pdb2pqrError("pdb2pqr not found in CondaPkg environment"))
    cmd = `$pdb2pqr --ff PARSE --titration-state-method propka --with-ph $pH
            $flags --pdb-output $out_path $in_path $tmp_pqr`
    run(pipeline(setenv(cmd, tools.env); stdout = devnull, stderr = devnull))
    isfile(out_path) || throw(
        Pdb2pqrError(
            "pdb2pqr did not produce expected output for \"$in_path\" at pH=$pH"),
    )
    return nothing
end

"""
Where [`resolve_hydrogens`](@ref) caches the hydrogenated
.pdb for `(pdb_path, pH)` (present ⟺ a cache hit).
"""
_hydrogens_path(pdb_path::AbstractString, pH::Real) =
    joinpath(
        _store_dir(),
        "$(splitext(basename(abspath(pdb_path)))[1])_pH$(Float64(pH)).pdb",
    )

"""
Add explicit hydrogens: runs pdb2pqr on the heavy-atom .pdb at `pdb_path` and
returns the path to a hydrogen-included .pdb stored in [`_store_dir`](@ref).

# Arguments
- `pdb_path`: path to a heavy-atom .pdb (e.g. from [`resolve_structure`](@ref)).
- `pKa_records`: records as returned by [`propka_pKas`](@ref) **on this same
    structure**; this is assumed, not re-verified, since the termini flags
    (and hence the cache key's implicit correctness) are only valid for the
    `pKa_records` that actually correspond to `pdb_path`.
- `pH`: solution pH passed to pdb2pqr and used to resolve termini flags.

# Returns
Absolute path to the hydrogen-included .pdb, stored in [`_store_dir`](@ref).
"""
function resolve_hydrogens(pdb_path::AbstractString, pKa_records, pH::Real)::String
    isfile(pdb_path) || throw(Pdb2pqrError("no such file: $pdb_path"))
    out_path = _hydrogens_path(abspath(pdb_path), pH)
    isfile(out_path) && return out_path
    # one pdb2pqr run per (structure, pH); concurrent
    # callers wait, then find the cached file
    return @lock _path_lock(out_path) _resolve_hydrogens(pdb_path, pKa_records, pH)
end

"The body of [`resolve_hydrogens`](@ref), run under the lock of its output path."
function _resolve_hydrogens(pdb_path::AbstractString, pKa_records, pH::Real)::String
    isfile(pdb_path) || throw(Pdb2pqrError("no such file: $pdb_path"))

    abspdb = abspath(pdb_path)
    storedir = _store_dir()
    out_path = _hydrogens_path(abspdb, pH)

    if !isfile(out_path)
        # Cheap pre-check, straight from pKa_records, no file I/O: does a
        # termini conflict genuinely exist? Deciding this doesn't need the
        # full chain list (a chain with no free terminus can't disagree with
        # anything), which matters because some legacy/tool-generated .pdb
        # fixtures (e.g. non-standard MODEL-record spacing from a DCD->PDB
        # trajectory converter) fail BioStructures' strict fixed-column
        # parser even though pdb2pqr itself handles them fine -- the common
        # (no-conflict) case below must never require that strict parse, or
        # every such file would regress even though nothing here actually
        # needed to read it.
        cheap_groups = _terminus_groups(pKa_records, pH, _termini_chains(pKa_records))

        # inside the store, so the final move is a rename within
        # one directory (a reader sees the whole file or none)
        tmpdir = mktempdir(storedir)
        try
            if length(cheap_groups) ≤ 1
                # Common case: every chain (if any even has a free terminus)
                # rounds to the same termini decision -- one pdb2pqr run on
                # the whole structure, no BioStructures parse needed at all.
                flags = isempty(cheap_groups) ? String[] : only(keys(cheap_groups))
                tmp_out = joinpath(tmpdir, "hydrogenated.pdb")
                _run_pdb2pqr(abspdb, flags, pH, tmp_out)
                # Callers for this (stem, pH) are serialized by
                # `resolve_hydrogens`'s lock, and (stem, pH) fully determines
                # the output, so replacing an existing file is harmless.
                mv(tmp_out, out_path; force = true)
            else
                # Genuine conflict: NOW the full chain list is needed (so a
                # chain with no free terminus of its own still ends up kept
                # in exactly one group below, not silently dropped), so
                # parse the original structure for real.
                local struc
                try
                    struc = BioStructures.read(abspdb, PDBFormat)
                catch e
                    throw(
                        Pdb2pqrError(
                            "failed reading \"$pdb_path\" to partition its " *
                            "conflicting chain termini: $(sprint(showerror, e))",
                        ),
                    )
                end
                groups =
                    _terminus_groups(pKa_records, pH, chainids(first(collectmodels(struc))))
                # Different chains need different --neutraln/--neutralc
                # settings, which pdb2pqr can't apply per-chain in one run.
                # Run pdb2pqr once per needed flag combination -- always on
                # the FULL original structure, never a chain subset, so
                # PROPKA/pdb2pqr's own titration-state and hydrogen-
                # placement geometry always sees the intact multi-chain
                # complex (interface termini are exactly the ones likely to
                # be sensitive to neighbouring chains, so isolating a chain
                # before this step would change the electrostatic/steric
                # context PROPKA reasons over, not just which flag applies)
                # -- then keep, from each run's output, only the chains
                # that actually needed that run's flags, and merge those
                # per-chain slices into one hydrogenated structure.
                merged_atoms = BioStructures.AbstractAtom[]
                for (i, (flags, group_chains)) in enumerate(groups)
                    tmp_out = joinpath(tmpdir, "run$(i).pdb")
                    _run_pdb2pqr(abspdb, flags, pH, tmp_out)
                    run_struc = BioStructures.read(tmp_out, PDBFormat)
                    kept = collectatoms(
                        first(collectmodels(run_struc)),
                        at -> chainid(at) in group_chains,
                    )
                    append!(merged_atoms, kept)
                end
                merged = joinpath(tmpdir, "merged.pdb")
                writepdb(merged, merged_atoms)
                mv(merged, out_path; force = true)
            end
        catch e
            e isa Pdb2pqrError && rethrow()
            throw(
                Pdb2pqrError(
                    "pdb2pqr failed on \"$pdb_path\" at pH=$pH: $(sprint(showerror, e))",
                ),
            )
        finally
            rm(tmpdir; recursive = true, force = true)
        end
    end

    return out_path
end
