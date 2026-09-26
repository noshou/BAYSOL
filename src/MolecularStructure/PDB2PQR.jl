# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Explicit-hydrogen structure generation via the external pdb2pqr CLI.
"""

using CondaPkg: CondaPkg
using FastClosures: @closure
using BioStructures: BioStructures, PDBFormat, writepdb, collectatoms,
                     chainid, chainids

"Raised when pdb2pqr cannot be run or produces no usable output (bad input
path, non-zero exit, missing expected output file)."
struct PDB2PQRError <: Exception; msg::String end
Base.showerror(io::IO, e::PDB2PQRError) = print(io, "PDB2PQRError: ", e.msg)

"""
    _terminus_groups(pKa_records, pH::Real, chains) -> Dict{Vector{String}, Vector{String}}

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
- `chains`: every chain ID in the structure (from [`BioStructures.chainids`](@ref)),
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
    _termini_chains(pKa_records) -> Vector{String}

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
    _run_pdb2pqr(in_path, flags, pH, out_path) -> Nothing

Run pdb2pqr on in_path with the given global --neutraln/--neutralc flags,
writing hydrogenated output to out_path. Throws [`PDB2PQRError`](@ref) if
pdb2pqr isn't found, exits non-zero, or doesn't produce out_path.
"""
function _run_pdb2pqr(
    in_path::AbstractString, flags::Vector{String}, pH::Real, out_path::AbstractString
)::Nothing
    tmp_pqr = out_path * ".pqr"
    @closure CondaPkg.withenv() do
        pdb2pqr = CondaPkg.which("pdb2pqr")
        pdb2pqr === nothing && throw(PDB2PQRError("pdb2pqr not found in CondaPkg environment"))
        cmd =  `$pdb2pqr --ff PARSE --titration-state-method propka --with-ph $pH
                $flags --pdb-output $out_path $in_path $tmp_pqr`
        run(pipeline(cmd; stdout = devnull, stderr = devnull))
    end
    isfile(out_path) || throw(PDB2PQRError(
        "pdb2pqr did not produce expected output for \"$in_path\" at pH=$pH"))
    return nothing
end

"""
    resolve_hydrogens(pdb_path::AbstractString, pKa_records, pH::Real; add::Bool=true) -> String

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

    isfile(pdb_path) || throw(PDB2PQRError("no such file: $pdb_path"))

    abspdb = abspath(pdb_path)
    stem = splitext(basename(abspdb))[1]
    storedir = _store_dir()
    out_path = joinpath(storedir, "$(stem)_pH$(Float64(pH)).pdb")

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
                    throw(PDB2PQRError("failed reading \"$pdb_path\" to partition its conflicting chain termini: $(sprint(showerror, e))"))
                end
                groups = _terminus_groups(pKa_records, pH, chainids(struc[1]))
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
                    kept = collectatoms(run_struc[1], at -> chainid(at) in group_chains)
                    append!(merged_atoms, kept)
                end
                writepdb(out_path, merged_atoms)
            end
        catch e
            e isa PDB2PQRError && rethrow()
            throw(PDB2PQRError("pdb2pqr failed on \"$pdb_path\" at pH=$pH: $(sprint(showerror, e))"))
        finally
            rm(tmpdir; recursive = true, force = true)
        end
    end

    return out_path
end
