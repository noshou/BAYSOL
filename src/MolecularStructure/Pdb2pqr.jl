# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Explicit-hydrogen structure generation via the external pdb2pqr CLI.
"""

using CondaPkg: CondaPkg
using FastClosures: @closure
using BioStructures: BioStructures, PDBFormat, writepdb, collectatoms,
                    chainid, chainids, collectmodels

"Raised when pdb2pqr cannot be run or produces no usable output (bad input
path, non-zero exit, missing expected output file)."
struct Pdb2pqrError <: Exception; msg::String end
Base.showerror(io::IO, e::Pdb2pqrError) = print(io, "Pdb2pqrError: ", e.msg)

# ---------------------------------------------------------------------------
#          Henderson-Hasselbalch protonation state of a titratable group
# ---------------------------------------------------------------------------

"""
$(TYPEDSIGNATURES)

Henderson-Hasselbalch fraction of a **base** group's titratable atoms that
are protonated (and therefore, for a base, charged) at solution pH:

    f = 1 / (1 + 10^(pH - pKa))

f -> 1 for pH ≪ pKa, f -> 0 for pH ≫ pKa, and f == 0.5 at pH == pKa.
"""
_fraction_protonated(pH::Real, pKa::Real)::Real = 1 / (1 + 10^(pH - pKa))

"""
$(TYPEDSIGNATURES)

Henderson-Hasselbalch fraction of an **acid** group's titratable atoms that
are deprotonated (and therefore, for an acid, charged) at solution pH:

    f = 1 / (1 + 10^(pKa - pH))

i.e. 1 - [`_fraction_protonated`](@ref)(pH, pKa).
"""
_fraction_deprotonated(pH::Real, pKa::Real)::Real = 1 / (1 + 10^(pKa - pH))

"""
$(TYPEDSIGNATURES)

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
        throw(ArgumentError("unknown charge-group type $(repr(type)) (expected \"acid\" or \"base\")"))
    end
end

"""
$(TYPEDSIGNATURES)

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
    pKa_records, pH::Real, chains::AbstractVector{<:AbstractString}
)::Dict{Vector{String}, Vector{String}}
    n_neutral = Dict{String, Bool}()
    for r in pKa_records
        r.resname == "N+" || continue
        n_neutral[r.chain] = !_group_protonated("base", pH, r.pKa)
    end
    c_neutral = Dict{String, Bool}()
    for r in pKa_records
        r.resname == "C-" || continue
        c_neutral[r.chain] = _group_protonated("acid", pH, r.pKa)
    end

    groups = Dict{Vector{String}, Vector{String}}()
    for chain in chains
        flags = String[]
        get(n_neutral, chain, false) && push!(flags, "--neutraln")
        get(c_neutral, chain, false) && push!(flags, "--neutralc")
        push!(get!(groups, flags, String[]), String(chain))
    end
    return groups
end

"""
$(TYPEDSIGNATURES)

Every chain with at least one N+/C- record in pKa_records -- derived from
pKa_records alone, no structure file I/O. A chain absent from this list has
no free terminus to override and is therefore guaranteed to need no
--neutraln/--neutralc flags regardless of what [`_terminus_groups`](@ref)
decides for the chains that do, which is what lets [`resolve_hydrogens`](@ref)
check for a termini conflict up front without needing to parse pdb_path at
all in the (overwhelmingly common) no-conflict case.
"""
_termini_chains(pKa_records)::Vector{String} =
    unique(String(r.chain) for r in pKa_records if r.resname == "N+" || r.resname == "C-")

"""
$(TYPEDSIGNATURES)

Run pdb2pqr on in_path with the given global --neutraln/--neutralc flags,
writing hydrogenated output to out_path. Throws [`Pdb2pqrError`](@ref) if
pdb2pqr isn't found, exits non-zero, or doesn't produce out_path.
"""
function _run_pdb2pqr(
    in_path::AbstractString, flags::Vector{String}, pH::Real, out_path::AbstractString
)::Nothing
    tmp_pqr = out_path * ".pqr"
    @closure CondaPkg.withenv() do
        pdb2pqr = CondaPkg.which("pdb2pqr")
        pdb2pqr === nothing && throw(Pdb2pqrError("pdb2pqr not found in CondaPkg environment"))
        cmd =  `$pdb2pqr --ff PARSE --titration-state-method propka --with-ph $pH
                $flags --pdb-output $out_path $in_path $tmp_pqr`
        run(pipeline(cmd; stdout = devnull, stderr = devnull))
    end
    isfile(out_path) || throw(Pdb2pqrError(
        "pdb2pqr did not produce expected output for \"$in_path\" at pH=$pH"))
    return nothing
end

"Where [`resolve_hydrogens`](@ref) caches the hydrogenated .pdb for `(pdb_path, pH)` (present ⟺ a cache hit)."
_hydrogens_path(pdb_path::AbstractString, pH::Real) =
    joinpath(_store_dir(), "$(splitext(basename(abspath(pdb_path)))[1])_pH$(Float64(pH)).pdb")

"""
$(TYPEDSIGNATURES)

Resolve whether/how pdb_path gets explicit hydrogens.

With add=true (the default), runs pdb2pqr on the heavy-atom .pdb at
pdb_path and returns the path to a hydrogen-included .pdb stored in
[`_store_dir`](@ref) (identical to this function's old add_hydrogens
behaviour). With add=false, this is a genuine no-op: pdb_path is returned
unchanged, with no file write, no [`_store_dir`](@ref) entry, and no
pdb2pqr subprocess invoked at all.

# Arguments
- `pdb_path`: path to a heavy-atom .pdb (e.g. from [`resolve_structure`](@ref)).
- `pKa_records`: records as returned by [`propka_pKas`](@ref) **on this same
    structure**; this is assumed, not re-verified, since the termini flags
    (and hence the cache key's implicit correctness) are only valid for the
    pKa_records that actually correspond to pdb_path. Ignored when
    add=false.
- `pH`: solution pH passed to pdb2pqr and used to resolve termini flags.
    Ignored when add=false.
- `add`: whether to actually add hydrogens (default true).

# Returns
Absolute path to the hydrogen-included .pdb when add=true, stored in
[`_store_dir`](@ref); pdb_path itself, unchanged, when add=false.
"""
function resolve_hydrogens(pdb_path::AbstractString, pKa_records, pH::Real; add::Bool=true)::String
    add || return pdb_path

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

        tmpdir = mktempdir()
        try
            if length(cheap_groups) ≤ 1
                # Common case: every chain (if any even has a free terminus)
                # rounds to the same termini decision -- one pdb2pqr run on
                # the whole structure, no BioStructures parse needed at all.
                flags = isempty(cheap_groups) ? String[] : only(keys(cheap_groups))
                tmp_out = joinpath(tmpdir, "hydrogenated.pdb")
                _run_pdb2pqr(abspdb, flags, pH, tmp_out)
                # A concurrent resolve_hydrogens call for this same (stem, pH)
                # may have finished first between the isfile(out_path) check
                # above and this mv -- (stem, pH) fully determines the
                # output, so reuse whatever's already there instead of
                # erroring; tmp_out is discarded with the rest of tmpdir below.
                isfile(out_path) || mv(tmp_out, out_path)
            else
                # Genuine conflict: NOW the full chain list is needed (so a
                # chain with no free terminus of its own still ends up kept
                # in exactly one group below, not silently dropped), so
                # parse the original structure for real.
                local struc
                try
                    struc = BioStructures.read(abspdb, PDBFormat)
                catch e
                    throw(Pdb2pqrError("failed reading \"$pdb_path\" to partition its conflicting chain termini: $(sprint(showerror, e))"))
                end
                groups = _terminus_groups(pKa_records, pH, chainids(first(collectmodels(struc))))
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
                    kept = collectatoms(first(collectmodels(run_struc)), at -> chainid(at) in group_chains)
                    append!(merged_atoms, kept)
                end
                writepdb(out_path, merged_atoms)
            end
        catch e
            e isa Pdb2pqrError && rethrow()
            throw(Pdb2pqrError("pdb2pqr failed on \"$pdb_path\" at pH=$pH: $(sprint(showerror, e))"))
        finally
            rm(tmpdir; recursive = true, force = true)
        end
    end

    return out_path
end
