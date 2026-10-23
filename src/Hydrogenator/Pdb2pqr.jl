# SPDX-License-Identifier: LGPL-3.0-or-later

# pdb2pqr: explicit-hydrogen structure generation, for a chosen force field and
# titration method.

"""
Raised when pdb2pqr cannot be run or produces no usable output (bad input
path, non-zero exit, missing expected output file), or is asked for a force field
it does not have.
"""
struct Pdb2pqrError <: Exception
    msg::String
end
Base.showerror(io::IO, e::Pdb2pqrError) = print(io, "Pdb2pqrError: ", e.msg)

"""
The `--ff` argument of a force field in [`FORCE_FIELDS`](@ref), as pdb2pqr spells it
(upper case).

# Exceptions
- `Pdb2pqrError`: `ff` is not in [`FORCE_FIELDS`](@ref).
"""
function _ff_argument(ff::Symbol)::String
    ff in FORCE_FIELDS || throw(
        Pdb2pqrError(
            "unknown force field :$ff (expected one of $(join(FORCE_FIELDS, ", ")))",
        ),
    )
    return uppercase(String(ff))
end

"The pKa records `method` needs for the structure at `pdb_path` (`nothing`: none)."
_pKa_records(m::Propka, pdb_path::AbstractString) =
    m.pKas === nothing ? propka_pKas(pdb_path) : m.pKas
_pKa_records(::NoTitration, ::AbstractString) = nothing

"The pdb2pqr arguments that select `method`'s protonation model at `pH`."
_titration_arguments(::Propka, pH::Real) =
    ["--titration-state-method", "propka", "--with-ph", string(pH)]
_titration_arguments(::NoTitration, ::Real) = String[]

"Short name of `method` in the cache file name."
_method_tag(::Propka) = "propka"
_method_tag(::NoTitration) = "notitration"

"""
The terminus flag groups ([`_terminus_groups`](@ref)) of the chains that have a free
terminus to override, from the pKa `records` alone. A single group (or none) means every
chain agrees. [`NoTitration`](@ref) overrides nothing: no groups.
"""
_cheap_terminus_groups(::Propka, records, pH::Real) =
    _terminus_groups(records, pH, _termini_chains(records))
_cheap_terminus_groups(::NoTitration, _, ::Real) = Dict{Vector{String},Vector{String}}()

# ---------------------------------------------------------------------------
#                    pdb2pqr: explicit-hydrogen structure generation
# ---------------------------------------------------------------------------

"""
Run pdb2pqr on `in_path` with the force field `ff` (a [`FORCE_FIELDS`](@ref) entry),
the titration arguments `titration_args` and the global --neutraln/--neutralc `flags`,
writing hydrogenated output to `out_path`. Modified nucleotides are run as the standard
residue of their base and get their own names back ([`relabel_modified`](@ref)); the
non-nucleotide ends of a nucleic chain run under chain ids of their own
([`isolate_chain_ends`](@ref)).
Throws [`Pdb2pqrError`](@ref) if pdb2pqr isn't
found, exits non-zero, doesn't produce `out_path`, or leaves a nucleotide residue of the
input out of it (see [`_check_nucleotides_kept`](@ref)). Heavy atoms pdb2pqr dropped are put
back ([`restore_dropped_atoms!`](@ref)).

# Returns
The counts `(; restored, added, h5t_dropped)` of that step.
"""
function _run_pdb2pqr(
    in_path::AbstractString, ff::Symbol, titration_args::Vector{String},
    flags::Vector{String}, out_path::AbstractString,
)
    ff_arg = _ff_argument(ff)
    tmp_pqr = out_path * ".pqr"
    tools = force(_CONDA[])
    pdb2pqr = tools.pdb2pqr
    pdb2pqr === nothing && throw(Pdb2pqrError("pdb2pqr not found in CondaPkg environment"))
    # modified nucleotides: hydrogenated through the standard residue of their base
    # chains that reuse an id and residue numbers get their own ids, true duplicate atoms
    # are dropped (kept in the output: chain ids never reach the scattering model)
    sanitized = out_path * ".sanitized.pdb"
    in_path = sanitized_copy(in_path, sanitized) === nothing ? in_path : sanitized
    relabeled = out_path * ".relabeled.pdb"
    rel = relabel_modified(in_path, relabeled)
    plan = rel.plan
    run_in = (isempty(plan) && !rel.renumbered) ? in_path : relabeled
    # a nucleic chain that starts or ends with a non-nucleotide: those ends run apart
    isolated = out_path * ".isolated.pdb"
    iso = isolate_chain_ends(run_in, isolated)
    iso.changed && (run_in = isolated)
    errfile = out_path * ".stderr"   # in the caller's temporary directory
    cmd = `$pdb2pqr --ff $ff_arg $titration_args $flags`
    cmd = `$cmd --pdb-output $out_path $run_in $tmp_pqr`
    try
        run(pipeline(setenv(cmd, tools.env); stdout = devnull, stderr = errfile))
    catch e
        e isa ProcessFailedException || rethrow()
        throw(
            Pdb2pqrError(
                "pdb2pqr failed on \"$in_path\" (--ff $ff_arg)" * _stderr_tail(errfile),
            ),
        )
    end
    isfile(out_path) || throw(
        Pdb2pqrError("pdb2pqr did not produce expected output for \"$in_path\""),
    )
    restore_chain_ends!(out_path, iso, in_path)
    restore_modified!(out_path, plan, rel.aliases)
    rm(relabeled; force = true)
    rm(isolated; force = true)
    balance = restore_dropped_atoms!(in_path, out_path)
    _check_nucleotides_kept(in_path, out_path, ff)
    rm(sanitized; force = true)
    return balance
end

"""
Where [`resolve_hydrogens`](@ref) caches the hydrogenated .pdb for
`(pdb_path, pH, ff, titration)` (present ⟺ a cache hit).
"""
_hydrogens_path(
    pdb_path::AbstractString, pH::Real, ff::Symbol, titration::TitrationMethod,
) = joinpath(
    _store_dir(),
    "$(splitext(basename(abspath(pdb_path)))[1])_pH$(Float64(pH))" *
    "_$(lowercase(String(ff)))_$(_method_tag(titration)).pdb",
)

"""
Add explicit hydrogens: runs pdb2pqr on the heavy-atom .pdb at `pdb_path` and
returns the path to a hydrogen-included .pdb stored in the `MolecularStructure` store.

# Arguments
- `pdb_path`: path to a heavy-atom .pdb (e.g. from `resolve_structure`).
- `pH`: solution pH, passed to pdb2pqr and used to resolve the termini flags when
    `titration` is pH-driven.

# Keywords
- `ff::Symbol=DEFAULT_FORCE_FIELD`: the force field, one of [`FORCE_FIELDS`](@ref).
- `titration::TitrationMethod=NoTitration()`: how titratable groups are protonated,
    [`Propka`](@ref) or [`NoTitration`](@ref). PROPKA is never implied.

# Returns
Absolute path to the hydrogen-included .pdb, named after the structure, the pH, the force
field and the titration method (a repeat call with the same four is a cache hit).

# Exceptions
- `Pdb2pqrError`: no such file, unknown force field, or pdb2pqr cannot be run or
    produces no output.
"""
function resolve_hydrogens(
    pdb_path::AbstractString, pH::Real;
    ff::Symbol = DEFAULT_FORCE_FIELD, titration::TitrationMethod = NoTitration(),
)::String
    isfile(pdb_path) || throw(Pdb2pqrError("no such file: $pdb_path"))
    _ff_argument(ff)  # reject an unknown force field before anything is looked up
    out_path = _hydrogens_path(abspath(pdb_path), pH, ff, titration)
    isfile(out_path) && return out_path
    # one pdb2pqr run per (structure, pH, ff, method); concurrent
    # callers wait, then find the cached file
    return @lock _path_lock(out_path) _resolve_hydrogens(pdb_path, pH, ff, titration)
end

"""
Record the heavy-atom `balance` ([`restore_dropped_atoms!`](@ref)) of the run that wrote
`out_path` beside it, so a later cache hit can report it ([`hydrogenation_balance`](@ref)).
"""
function _write_balance(out_path::AbstractString, balance)::Nothing
    write(
        out_path * ".balance",
        "$(balance.restored)\t$(balance.added)\t$(balance.h5t_dropped)\n",
    )
    return nothing
end

"""
    hydrogenation_balance(hydrogenated_path) -> Union{Nothing,NamedTuple}

The heavy-atom balance of the pdb2pqr run that wrote `hydrogenated_path`: `(; restored,
added, h5t_dropped)`, the number of heavy atoms pdb2pqr dropped and that were put back, the
number it added, and the `H5T` removed with a restored phosphorus; `nothing` when none was
recorded (a file from an older version).
"""
function hydrogenation_balance(path::AbstractString)
    f = path * ".balance"
    isfile(f) || return nothing
    v = tryparse.(Int, split(strip(read(f, String)), '\t'))
    (length(v) == 3 && all(!isnothing, v)) || return nothing
    return (; restored = v[1], added = v[2], h5t_dropped = v[3])
end

"""
The chain ids (column 22, stripped; a blank id is `""`) of the first model of the .pdb at
`path`, in order of first appearance, by text scan: no strict parse, so hybrid-36 serials
and other oddities pdb2pqr accepts do not matter.
"""
function _text_chain_ids(path::AbstractString)::Vector{String}
    ids = String[]
    for line in eachline(path)
        startswith(line, "ENDMDL") && break
        (startswith(line, "ATOM") || startswith(line, "HETATM")) || continue
        length(line) >= 22 || continue
        c = String(strip(SubString(line, 22, 22)))
        c in ids || push!(ids, c)
    end
    return ids
end

"""
Write to `dest` the lines of each run's output `(path, chains)` that belong to its
`chains` (ATOM, HETATM, ANISOU and TER records, by the chain-id column, verbatim, first
model only), run after run, then `END`.
"""
function _merge_chains_by_text(runs, dest::AbstractString)::Nothing
    open(dest, "w") do io
        for (path, chains) in runs
            for line in eachline(path)
                startswith(line, "ENDMDL") && break
                (
                    startswith(line, "ATOM") || startswith(line, "HETATM") ||
                    startswith(line, "ANISOU") || startswith(line, "TER")
                ) || continue
                length(line) >= 22 || continue
                String(strip(SubString(line, 22, 22))) in chains && println(io, line)
            end
        end
        println(io, "END")
    end
    return nothing
end

"The body of [`resolve_hydrogens`](@ref), run under the lock of its output path."
function _resolve_hydrogens(
    pdb_path::AbstractString, pH::Real, ff::Symbol, titration::TitrationMethod,
)::String
    abspdb = abspath(pdb_path)
    storedir = _store_dir()
    out_path = _hydrogens_path(abspdb, pH, ff, titration)

    if !isfile(out_path)
        records = _pKa_records(titration, abspdb)
        targs = _titration_arguments(titration, pH)
        # Cheap pre-check, straight from the pKa records, no file I/O: does a
        # termini conflict genuinely exist? Deciding this doesn't need the
        # full chain list (a chain with no free terminus can't disagree with
        # anything), which matters because some legacy/tool-generated .pdb
        # fixtures (e.g. non-standard MODEL-record spacing from a DCD->PDB
        # trajectory converter) fail BioStructures' strict fixed-column
        # parser even though pdb2pqr itself handles them fine -- the common
        # (no-conflict) case below must never require that strict parse, or
        # every such file would regress even though nothing here actually
        # needed to read it.
        cheap_groups = _cheap_terminus_groups(titration, records, pH)

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
                balance = _run_pdb2pqr(abspdb, ff, targs, flags, tmp_out)
                # Callers for this key are serialized by `resolve_hydrogens`'s
                # lock, and the key fully determines the output, so replacing
                # an existing file is harmless.
                mv(tmp_out, out_path; force = true)
                _write_balance(out_path, balance)
            else
                # Genuine conflict: NOW the full chain list is needed (so a
                # chain with no free terminus of its own still ends up kept
                # in exactly one group below, not silently dropped). It is read
                # by text, from the chain-id column: BioStructures' strict parser
                # refuses files pdb2pqr handles fine (hybrid-36 atom serials).
                groups = _terminus_groups(records, pH, _text_chain_ids(abspdb))
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
                # per-chain slices into one hydrogenated structure (by text,
                # the lines verbatim).
                runs = Tuple{String,Vector{String}}[]
                total = (; restored = 0, added = 0, h5t_dropped = 0)
                for (i, (flags, group_chains)) in enumerate(groups)
                    tmp_out = joinpath(tmpdir, "run$(i).pdb")
                    b = _run_pdb2pqr(abspdb, ff, targs, flags, tmp_out)
                    total = map(+, total, b)
                    push!(runs, (tmp_out, group_chains))
                end
                merged = joinpath(tmpdir, "merged.pdb")
                _merge_chains_by_text(runs, merged)
                mv(merged, out_path; force = true)
                _write_balance(out_path, total)
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
