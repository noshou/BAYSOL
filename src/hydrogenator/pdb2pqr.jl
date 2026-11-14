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
function _ffArgument(ff::Symbol)::String
    ff in FORCE_FIELDS || throw(
        Pdb2pqrError(
            "unknown force field :$ff (expected one of $(join(FORCE_FIELDS, ", ")))",
        ),
    )
    return uppercase(String(ff))
end

"The pKa records `method` needs for the structure at `pdbPath` (`nothing`: none)."
_pKaRecords(m::Propka, pdbPath::AbstractString) =
    m.pKas === nothing ? propkaPkas(pdbPath) : m.pKas
_pKaRecords(::NoTitration, ::AbstractString) = nothing

"The pdb2pqr arguments that select `method`'s protonation model at `pH`."
_titrationArguments(::Propka, pH::Real) =
    ["--titration-state-method", "propka", "--with-ph", string(pH)]
_titrationArguments(::NoTitration, ::Real) = String[]

"Short name of `method` in the cache file name."
_methodTag(::Propka) = "propka"
_methodTag(::NoTitration) = "notitration"

"""
The terminus flag groups ([`_terminusGroups`](@ref)) of the chains that have a free
terminus to override, from the pKa `records` alone. A single group (or none) means every
chain agrees. [`NoTitration`](@ref) overrides nothing: no groups.
"""
_cheapTerminusGroups(::Propka, records, pH::Real) =
    _terminusGroups(records, pH, _terminiChains(records))
_cheapTerminusGroups(::NoTitration, _, ::Real) = Dict{Vector{String},Vector{String}}()

# ---------------------------------------------------------------------------
#                    pdb2pqr: explicit-hydrogen structure generation
# ---------------------------------------------------------------------------

"""
Run pdb2pqr on `inPath` with the force field `ff` (a [`FORCE_FIELDS`](@ref) entry),
the titration arguments `titrationArgs` and the global --neutraln/--neutralc `flags`,
writing hydrogenated output to `outPath`. Modified nucleotides are run as the standard
residue of their base and get their own names back ([`relabelModified`](@ref)); the
non-nucleotide ends of a nucleic chain run under chain ids of their own
([`isolateChainEnds`](@ref)).
Throws [`Pdb2pqrError`](@ref) if pdb2pqr isn't
found, exits non-zero, doesn't produce `outPath`, or leaves a nucleotide residue of the
input out of it (see [`_checkNucleotidesKept`](@ref)). Heavy atoms pdb2pqr dropped are put
back ([`restoreDroppedAtoms!`](@ref)).

# Returns
The counts `(; restored, added, h5tDropped, ligands)` of that step.
"""
function _runPdb2pqr(
    inPath::AbstractString, ff::Symbol, titrationArgs::Vector{String},
    flags::Vector{String}, outPath::AbstractString,
)
    ffArg = _ffArgument(ff)
    tmpPqr = outPath * ".pqr"
    tools = force(_CONDA[])
    pdb2pqr = tools.pdb2pqr
    pdb2pqr === nothing && throw(Pdb2pqrError("pdb2pqr not found in CondaPkg environment"))
    # modified nucleotides: hydrogenated through the standard residue of their base
    # chains that reuse an id and residue numbers get their own ids, true duplicate atoms
    # are dropped (kept in the output: chain ids never reach the scattering model); waters
    # never scatter and pdb2pqr's water optimisation fails on an oxygen not named O/OW
    # (`O1` in old crystal files), so they are removed from the copy it gets
    sanitized = outPath * ".sanitized.pdb"
    inPath =
        sanitizedCopy(inPath, sanitized; waters = true) === nothing ? inPath : sanitized
    relabeled = outPath * ".relabeled.pdb"
    rel = relabelModified(inPath, relabeled)
    plan = rel.plan
    runIn = (isempty(plan) && !rel.renumbered) ? inPath : relabeled
    # a nucleic chain that starts or ends with a non-nucleotide: those ends run apart
    isolated = outPath * ".isolated.pdb"
    iso = isolateChainEnds(runIn, isolated)
    iso.changed && (runIn = isolated)
    errfile = outPath * ".stderr"   # in the caller's temporary directory
    cmd = `$pdb2pqr --ff $ffArg $titrationArgs $flags`
    cmd = `$cmd --pdb-output $outPath $runIn $tmpPqr`
    try
        run(pipeline(setenv(cmd, tools.env); stdout = devnull, stderr = errfile))
    catch e
        e isa ProcessFailedException || rethrow()
        throw(
            Pdb2pqrError(
                "pdb2pqr failed on \"$inPath\" (--ff $ffArg)" * _stderrTail(errfile),
            ),
        )
    end
    isfile(outPath) || throw(
        Pdb2pqrError("pdb2pqr did not produce expected output for \"$inPath\""),
    )
    restoreChainEnds!(outPath, iso, inPath)
    restoreModified!(outPath, plan, rel.aliases)
    rm(relabeled; force = true)
    rm(isolated; force = true)
    balance = restoreDroppedAtoms!(inPath, outPath)
    _checkNucleotidesKept(inPath, outPath, ff)
    rm(sanitized; force = true)
    return balance
end

"""
Where [`resolveHydrogens`](@ref) caches the hydrogenated .pdb for
`(pdbPath, pH, ff, titration)` (present ⟺ a cache hit).
"""
_hydrogensPath(
    pdbPath::AbstractString, pH::Real, ff::Symbol, titration::TitrationMethod,
) = joinpath(
    _storeDir(),
    "$(splitext(basename(abspath(pdbPath)))[1])_pH$(Float64(pH))" *
    "_$(lowercase(String(ff)))_$(_methodTag(titration)).pdb",
)

"""
Add explicit hydrogens: runs pdb2pqr on the heavy-atom .pdb at `pdbPath` and
returns the path to a hydrogen-included .pdb stored in the `MolecularStructure` store.

# Arguments
- `pdbPath`: path to a heavy-atom .pdb (e.g. from `resloveStruct`).
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
function resolveHydrogens(
    pdbPath::AbstractString, pH::Real;
    ff::Symbol = DEFAULT_FORCE_FIELD, titration::TitrationMethod = NoTitration(),
)::String
    isfile(pdbPath) || throw(Pdb2pqrError("no such file: $pdbPath"))
    _ffArgument(ff)  # reject an unknown force field before anything is looked up
    outPath = _hydrogensPath(abspath(pdbPath), pH, ff, titration)
    _cached(outPath) && return outPath
    # one pdb2pqr run per (structure, pH, ff, method); concurrent
    # callers wait, then find the cached file
    return @lock _pathLock(outPath) _resolveHydrogens(pdbPath, pH, ff, titration)
end

"""
Whether `outPath` is a usable cache hit: the file and its `.balance` side file. A file
without the side file, or with the three-field one of the versions that put no ligand back,
is recomputed (it lacks the ligands pdb2pqr dropped).
"""
_cached(outPath::AbstractString)::Bool =
    isfile(outPath) && hydrogenationBalance(outPath) !== nothing

"""
Record the heavy-atom `balance` ([`restoreDroppedAtoms!`](@ref)) of the run that wrote
`outPath` beside it, so a later cache hit can report it ([`hydrogenationBalance`](@ref)).
"""
function _writeBalance(outPath::AbstractString, balance)::Nothing
    write(
        outPath * ".balance",
        "$(balance.restored)\t$(balance.added)\t$(balance.h5tDropped)\t" *
        "$(balance.ligands)\n",
    )
    return nothing
end

"""
    hydrogenationBalance(hydrogenated_path) -> Union{Nothing,NamedTuple}

The heavy-atom balance of the pdb2pqr run that wrote `hydrogenated_path`: `(; restored,
added, h5tDropped, ligands)`, the number of heavy atoms pdb2pqr dropped and that were put
back, the number it added, the `H5T` removed with a restored phosphorus and the atoms of the
ligand residues put back; `nothing` when none was recorded.
"""
function hydrogenationBalance(path::AbstractString)
    f = path * ".balance"
    isfile(f) || return nothing
    v = tryparse.(Int, split(strip(read(f, String)), '\t'))
    (length(v) == 4 && all(!isnothing, v)) || return nothing
    return (; restored = v[1], added = v[2], h5tDropped = v[3], ligands = v[4])
end

"""
The chain ids (column 22, stripped; a blank id is `""`) of the first model of the .pdb at
`path`, in order of first appearance, by text scan: no strict parse, so hybrid-36 serials
and other oddities pdb2pqr accepts do not matter.
"""
function _textChainIds(path::AbstractString)::Vector{String}
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
function _mergeChainsByText(runs, dest::AbstractString)::Nothing
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

"The body of [`resolveHydrogens`](@ref), run under the lock of its output path."
function _resolveHydrogens(
    pdbPath::AbstractString, pH::Real, ff::Symbol, titration::TitrationMethod,
)::String
    abspdb = abspath(pdbPath)
    storedir = _storeDir()
    outPath = _hydrogensPath(abspdb, pH, ff, titration)

    if !_cached(outPath)
        records = _pKaRecords(titration, abspdb)
        targs = _titrationArguments(titration, pH)
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
        cheapGroups = _cheapTerminusGroups(titration, records, pH)

        # inside the store, so the final move is a rename within
        # one directory (a reader sees the whole file or none)
        tmpdir = mktempdir(storedir)
        try
            if length(cheapGroups) ≤ 1
                # Common case: every chain (if any even has a free terminus)
                # rounds to the same termini decision -- one pdb2pqr run on
                # the whole structure, no BioStructures parse needed at all.
                flags = isempty(cheapGroups) ? String[] : only(keys(cheapGroups))
                tmpOut = joinpath(tmpdir, "hydrogenated.pdb")
                balance = _runPdb2pqr(abspdb, ff, targs, flags, tmpOut)
                # Callers for this key are serialized by `resolveHydrogens`'s
                # lock, and the key fully determines the output, so replacing
                # an existing file is harmless.
                mv(tmpOut, outPath; force = true)
                _writeBalance(outPath, balance)
            else
                # Genuine conflict: NOW the full chain list is needed (so a
                # chain with no free terminus of its own still ends up kept
                # in exactly one group below, not silently dropped). It is read
                # by text, from the chain-id column: BioStructures' strict parser
                # refuses files pdb2pqr handles fine (hybrid-36 atom serials).
                groups = _terminusGroups(records, pH, _textChainIds(abspdb))
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
                total = (; restored = 0, added = 0, h5tDropped = 0, ligands = 0)
                for (i, (flags, groupChains)) in enumerate(groups)
                    tmpOut = joinpath(tmpdir, "run$(i).pdb")
                    b = _runPdb2pqr(abspdb, ff, targs, flags, tmpOut)
                    total = map(+, total, b)
                    push!(runs, (tmpOut, groupChains))
                end
                merged = joinpath(tmpdir, "merged.pdb")
                _mergeChainsByText(runs, merged)
                mv(merged, outPath; force = true)
                _writeBalance(outPath, total)
            end
        catch e
            e isa Pdb2pqrError && rethrow()
            throw(
                Pdb2pqrError(
                    "pdb2pqr failed on \"$pdbPath\" at pH=$pH: $(sprint(showerror, e))",
                ),
            )
        finally
            rm(tmpdir; recursive = true, force = true)
        end
    end

    return outPath
end
