# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Explicit-hydrogen structure generation via the external `pdb2pqr` CLI.
"""

using CondaPkg: CondaPkg

"Raised when `pdb2pqr` cannot be run or produces no usable output (bad input
path, non-zero exit, missing expected output file), or when the requested
N-/C-terminus override can't be represented by `pdb2pqr`'s global
`--neutraln`/`--neutralc` flags (see [`_terminus_flags`](@ref))."
struct PDB2PQRError <: Exception; msg::String end
Base.showerror(io::IO, e::PDB2PQRError) = print(io, "PDB2PQRError: ", e.msg)

"""
    _terminus_flags(pKa_records, pH::Real) -> Vector{String}

Decide `pdb2pqr`'s `--neutraln`/`--neutralc` CLI flags from
`pKa_records` (as produced by [`propka_pKas`](@ref)) and `pH`, using 
[`_group_protonated`](@ref) rather than `pdb2pqr`'s
(non-pH-driven, fixed-charged-by-default) terminus handling.

# Arguments
- `pKa_records`: records as returned by [`propka_pKas`](@ref); only
    `resname == "N+"`/`"C-"` records are consulted.
- `pH`: solution pH, matching the `pH` [`propka_pKas`](@ref)'s caller intends
    to use with `pdb2pqr`.
"""
function _terminus_flags(pKa_records, pH::Real)::Vector{String}
    flags = String[]

    nplus = [r for r in pKa_records if r.resname == "N+"]
    if !isempty(nplus)
        decisions = Set(_group_protonated("base", pH, r.pKa) for r in nplus)
        length(decisions) > 1 && throw(PDB2PQRError(
            "multiple free N-termini round to different protonation states at pH=$pH; " *
            "pdb2pqr's --neutraln flag is global, not per-chain, so this multi-chain " *
            "case cannot be represented by a single run"))
        only(decisions) || push!(flags, "--neutraln")
    end

    cminus = [r for r in pKa_records if r.resname == "C-"]
    if !isempty(cminus)
        decisions = Set(_group_protonated("acid", pH, r.pKa) for r in cminus)
        length(decisions) > 1 && throw(PDB2PQRError(
            "multiple free C-termini round to different protonation states at pH=$pH; " *
            "pdb2pqr's --neutralc flag is global, not per-chain, so this multi-chain " *
            "case cannot be represented by a single run"))
        only(decisions) && push!(flags, "--neutralc")
    end

    return flags
end

"""
    resolve_hydrogens(pdb_path::AbstractString, pKa_records, pH::Real; add::Bool=true) -> String

Resolve whether/how `pdb_path` gets explicit hydrogens.

With `add=true` (the default), runs `pdb2pqr` on the heavy-atom `.pdb` at
`pdb_path` and returns the path to a hydrogen-included `.pdb` stored in
[`_store_dir`](@ref) (identical to this function's old `add_hydrogens`
behaviour). With `add=false`, this is a genuine no-op: `pdb_path` is returned
unchanged, with no file write, no [`_store_dir`](@ref) entry, and no
`pdb2pqr` subprocess invoked at all.

# Arguments
- `pdb_path`: path to a heavy-atom `.pdb` (e.g. from [`resolve_structure`](@ref)).
- `pKa_records`: records as returned by [`propka_pKas`](@ref) **on this same
    structure** -- this is assumed, not re-verified, since the termini flags
    (and hence the cache key's implicit correctness) are only valid for the
    `pKa_records` that actually correspond to `pdb_path`. Ignored when
    `add=false`.
- `pH`: solution pH passed to `pdb2pqr` and used to resolve termini flags.
    Ignored when `add=false`.
- `add`: whether to actually add hydrogens (default `true`).

# Returns
Absolute path to the hydrogen-included `.pdb` when `add=true`, stored in
[`_store_dir`](@ref); `pdb_path` itself, unchanged, when `add=false`.
"""
function resolve_hydrogens(pdb_path::AbstractString, pKa_records, pH::Real; add::Bool=true)::String
    add || return pdb_path

    isfile(pdb_path) || throw(PDB2PQRError("no such file: $pdb_path"))

    abspdb = abspath(pdb_path)
    stem = splitext(basename(abspdb))[1]
    storedir = _store_dir()
    out_path = joinpath(storedir, "$(stem)_pH$(Float64(pH)).pdb")

    if !isfile(out_path)
        flags = _terminus_flags(pKa_records, pH)

        tmpdir = mktempdir()
        tmp_out = joinpath(tmpdir, "hydrogenated.pdb")
        tmp_pqr = joinpath(tmpdir, "hydrogenated.pqr")
        try
            CondaPkg.withenv() do
                pdb2pqr = CondaPkg.which("pdb2pqr")
                pdb2pqr === nothing && throw(PDB2PQRError("pdb2pqr not found in CondaPkg environment"))
                cmd =  `$pdb2pqr --ff PARSE --titration-state-method propka --with-ph $pH
                        $flags --pdb-output $tmp_out $abspdb $tmp_pqr`
                run(pipeline(cmd; stdout = devnull, stderr = devnull))
            end
            isfile(tmp_out) || throw(PDB2PQRError(
                "pdb2pqr did not produce expected output for \"$pdb_path\" at pH=$pH"))
            mv(tmp_out, out_path)
        catch e
            e isa PDB2PQRError && rethrow()
            throw(PDB2PQRError("pdb2pqr failed on \"$pdb_path\" at pH=$pH: $(sprint(showerror, e))"))
        finally
            rm(tmpdir; recursive = true, force = true)
        end
    end

    return out_path
end
