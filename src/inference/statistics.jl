# SPDX-License-Identifier: LGPL-3.0-or-later

# The run statistics: what the sampler and its phases did, recorded as they happen.
#
# Each phase of a run (the MAP search, the chains, the convergence gate, a retry, a ladder
# rung, the restart with c1 sampled) appends the values it has just computed to a
# `StatBuffer` and the buffer is flushed to a scratch file at every phase boundary and
# whenever it passes its size cap, so it never grows past the cap and nothing is rewritten.
# `BAYSOL.results` (or `_runLogged` after a failure) moves the scratch file into the run's
# section of `statistics-<ID>.LOG` (`Pipeline.writeStatistics`). The buffer is one per run:
# it lives in the run's `StageLog` (`info["statistics"]`), so a `runModel` call without a
# `results` call just drops it. Every value is the sampler's own: nothing is replayed or
# re-estimated here, and a value that is not available is written as such. Where
# `bysl fits diagnose` replays the model, the log gives the same layout from the run's own
# draws (proxies, documented in the README). The grammar (`-- name --` sections, scalar
# rows, tab-separated tables, text) is listed in `STAT_SECTIONS` and read by `statParse`.
# The divergent draws are kept apart (`statDivergences`) for the workbook's sheet.

using Statistics: mean, median, std, cor, cov
using LinearAlgebra: Symmetric, eigvals, diag
using ..Scattering: MEMORY_HEADROOM, _systemMemory
using ..Platform

"The share of the memory budget a [`StatBuffer`](@ref) may hold before it flushes."
const STATISTICS_MEMORY_SHARE = 1.0e-4

"The least flush size (bytes) whatever the budget says: a few attempts' blocks fit in it."
const STATISTICS_BUFFER_MIN = 65_536

"The largest flush size (bytes): the buffer is a guard, never a cache."
const STATISTICS_BUFFER_MAX = 67_108_864

"""
    statisticsCap(headroom = MEMORY_HEADROOM; memory = Scattering._systemMemory) -> Int

The size, in bytes, at which a [`StatBuffer`](@ref) flushes to its scratch file even
between two phases: `STATISTICS_MEMORY_SHARE` (0.01 %) of the memory budget the forward
cache works in (the free memory minus `headroom` percent of the total, the same
`Platform.free_memory()` / `Sys.total_memory()` reading as the static build,
`Scattering._systemMemory`), held between `STATISTICS_BUFFER_MIN` and
`STATISTICS_BUFFER_MAX`. A run's statistics are a few kilobytes per attempt, so the cap is a
guard against a run that records far more (many chains, many rungs), not a limit met in
practice; a machine with no free memory still gets the minimum.

# Arguments
- `headroom`: percent of the total memory left free (the run's `memoryHeadroom`).
- `memory`: a function returning `(free, total)` bytes, as for the forward cache.

# Returns
- The cap in bytes, an `Int`.

# Exceptions
- None.
"""
function statisticsCap(headroom::Real = MEMORY_HEADROOM; memory = _systemMemory)
    free, total = memory()
    budget = max(free - round(Int, headroom / 100 * total), 0)
    return clamp(round(Int, STATISTICS_MEMORY_SHARE * budget),
        STATISTICS_BUFFER_MIN, STATISTICS_BUFFER_MAX)
end
"The width of the name column of a statistics row (a multiple of 8, so rows align)."
const _STAT_NAME_WIDTH = 32

"The width of a table cell of the statistics (a multiple of 8)."
const _STAT_CELL_WIDTH = 16

"The gap in c1 between two neighbouring draws of an axis that counts as a jump."
const STAT_C1_JUMP = 0.05

"How far from a c1 bound (absolute) a draw's c1 still counts as pinned at it."
const STAT_C1_PIN_TOL = 1.0e-6

"The fewest draws a bin of the axis shape needs for its median to be reported."
const STAT_BIN_MIN = 5

"""
    STAT_SECTIONS

The sections of the statistics log: `name`, `kind` (`:scalars`, `:table` or `:text`) and
`columns` (the row names of a scalars section, the header of a table, `String[]` for text),
`level` (`:run` once per run, `:attempt` in each attempt's block) and `open` (a table whose
header may continue past `columns`, one column per sampled parameter). Every section a run
writes is in it, with its names and header exactly as listed (a scalar row may be left out
when it does not apply); `src/inference/README.md` lists the same table, and the unit test
checks the writer against it. [`statParse`](@ref) reads a log by it.
"""
const STAT_SECTIONS = [
    (name = "settings", kind = :scalars, level = :attempt, open = false,
        columns = ["triggeredBy", "triggerClass", "rung", "targetAccept", "nChains",
            "nSamples", "nAdapt", "nDraws", "rngSeed", "chainStartRadii", "c1Mode",
            "kinkWatch", "mapNStarts", "mapMaxIter"]),
    (name = "problem", kind = :text, level = :attempt, open = false, columns = String[]),
    (name = "map search", kind = :text, level = :attempt, open = false,
        columns = String[]),
    (name = "map search again", kind = :text, level = :attempt, open = false,
        columns = String[]),
    (name = "nuts", kind = :text, level = :attempt, open = false, columns = String[]),
    (name = "chains", kind = :table, level = :attempt, open = false,
        columns = CHAIN_COLUMNS),
    (name = "chain totals", kind = :scalars, level = :attempt, open = false,
        columns = ["chainsRun", "chainsPooled", "pooledDraws", "divergentDraws",
            "warmupDivergentDraws"]),
    (name = "posterior", kind = :text, level = :attempt, open = false,
        columns = String[]),
    (name = "bounds", kind = :table, level = :attempt, open = false,
        columns = ["coordinate", "median", "sd", "distanceSd", "shareNearBound"]),
    (name = "axes", kind = :text, level = :attempt, open = false, columns = String[]),
    (name = "correlation", kind = :table, level = :attempt, open = true,
        columns = ["parameter"]),
    (name = "residuals", kind = :scalars, level = :attempt, open = false,
        columns = ["residualSource", "residualCount", "durbinWatson", "runsCount",
            "runsExpected", "runsZ", "runsP"]),
    (name = "convergence", kind = :table, level = :attempt, open = false,
        columns = ["parameter", "rhat", "essBulk", "essTail", "sd", "mcse"]),
    (name = "gate", kind = :scalars, level = :attempt, open = false,
        columns = ["rhatMax", "essMin", "essTailMin", "nDivergent", "divergentShare",
            "gate"]),
    (name = "modes", kind = :scalars, level = :attempt, open = false,
        columns = ["modes", "modeWeights", "modeLogMass", "modeLogMassErr",
            "weightsUncertain", "rewhitenedNats"]),
    (name = "health", kind = :scalars, level = :attempt, open = false,
        columns = ["stepSizeInitial", "stepSizeReached", "leapfrogTotal",
            "leapfrogSampling", "leapfrogPerEss", "gradientEvals", "nonFiniteEvals",
            "curvatureSamples", "c1AtLowerBound", "c1AtUpperBound"]),
    (name = "c1 search", kind = :scalars, level = :attempt, open = false,
        columns = ["c1Solves", "c1BrentIterations", "c1BrentPerSolve", "c1ScanAtEdge",
            "c1WlsErrors"]),
    (name = "kink check", kind = :table, level = :attempt, open = false,
        columns = ["chain", "checks", "drawsExamined", "drawsTwoBasins", "firedAtDraw"],
    ),
    (name = "stage timings", kind = :table, level = :attempt, open = false,
        columns = ["stage", "seconds", "jit", "gc", "notes"]),
    (name = "outcome", kind = :scalars, level = :attempt, open = false,
        columns = ["stopped", "next"]),
    (name = "statistics error", kind = :text, level = :attempt, open = false,
        columns = String[]),
    (name = "attempts", kind = :table, level = :run, open = false,
        columns = ["attempt", "label", "outcome"]),
    (name = "result", kind = :scalars, level = :run, open = false,
        columns = ["attempts", "keptAttempt", "keptLabel", "keptBecause", "failed",
            "statisticsFlushes", "statisticsFlushSeconds"]),
]

# The entry of STAT_SECTIONS for a section name
# (`map search again 2` is `map search again`).
function _statSection(name::AbstractString)
    base = replace(name, r" \d+$" => "")
    i = findfirst(s -> s.name == base, STAT_SECTIONS)
    return i === nothing ? nothing : STAT_SECTIONS[i]
end

"""
    StatBuffer

The statistics of one run, in the order they were recorded: the lines not yet flushed
(`lines`, at most `cap` bytes), the scratch file the flushed ones went to (`spill`, made at
the first flush), and the bookkeeping of the attempts. One per run, shared by the threads
that record into it (every method takes `lock`).

# Fields
- `lock`: held by every method.
- `lines`, `bytes`, `cap`: the pending lines, their size and the flush size.
- `spill`: the scratch file (`nothing` until the first flush with something to write).
- `flushSeconds`, `nFlushes`: the time and number of the flushes (their cost is part of the
    timing table).
- `attempts`: the labels of the attempts started so far, in order.
- `pending`: the label, trigger, trigger class and rung the next attempt will carry (see
    [`statLabel!`](@ref)).
- `kept`, `keptWhy`: the attempt kept and why (the last [`statKeep!`](@ref)).
- `stage0`: the number of stages the run's timing log had when the current attempt began.
- `again`: how many `map search again` sections the current attempt has.
- `outcome`, `errors`: the `outcome` rows and `statistics error` lines of the current
    attempt, written when the attempt ends.
- `kink`: what the chains' kink watch did in the current attempt, a row per chain.
- `divergences`: one row per divergent draw of
    every attempt (see [`statDivergences`](@ref)).
- `c1base`: the c1 search tallies when the current attempt began.
"""
mutable struct StatBuffer
    const lock::ReentrantLock
    lines::Vector{String}
    bytes::Int
    cap::Int
    spill::Union{Nothing,String}
    flushSeconds::Float64
    nFlushes::Int
    attempts::Vector{String}
    pending::NamedTuple{(:label, :trigger, :class, :rung),NTuple{4,String}}
    kept::Int
    keptWhy::String
    stage0::Int
    again::Int
    outcome::Vector{Tuple{String,String}}
    errors::Vector{String}
    kink::Vector{NTuple{5,Int}}
    divergences::Vector{Any}
    c1base::Any
end

const _NO_PENDING = (label = "", trigger = "", class = "", rung = "")

StatBuffer(; cap::Integer = statisticsCap()) = StatBuffer(
    ReentrantLock(), String[], 0, cap, nothing, 0.0, 0, String[], _NO_PENDING, 0, "", 0,
    0,
    Tuple{String,String}[], String[], NTuple{5,Int}[], Any[], nothing,
)

"""
The [`StatBuffer`](@ref) of a run (made on the first call), kept in the run's stage log;
`nothing` for a run without a stage log, for which every `stat*` function does nothing.

# Returns
- `Union{Nothing,StatBuffer}`.

# Exceptions
- None.
"""
statBuffer(::Nothing) = nothing
function statBuffer(timing::StageLog)
    lock(timing.lock) do
        b = get(timing.info, "statistics", nothing)
        b isa StatBuffer && return b
        headroom = get(timing.info, "memoryHeadroom", MEMORY_HEADROOM)
        return timing.info["statistics"] = StatBuffer(; cap = statisticsCap(headroom))
    end
end

"""
Forgets what the buffer holds (and its scratch file) for the start of a new run on the
same stage log: a `runModel` call starts its statistics afresh.

# Returns
- `nothing`.

# Exceptions
- None.
"""
statReset!(::Nothing) = nothing
function statReset!(b::StatBuffer)
    lock(b.lock) do
        b.spill === nothing || rm(b.spill; force = true)
        b.spill = nothing
        empty!(b.lines)
        empty!(b.attempts)
        b.bytes = 0
        b.flushSeconds = 0.0
        b.nFlushes = 0
        b.pending = _NO_PENDING
        b.kept = 0
        b.keptWhy = ""
        b.stage0 = 0
        b.again = 0
        empty!(b.outcome)
        empty!(b.errors)
        empty!(b.kink)
        empty!(b.divergences)
        b.c1base = nothing
    end
    return nothing
end

"A value as a statistics cell: an integer as it is, a float to 6 significant figures."
_statCell(x::Integer) = string(x)
_statCell(x::Bool) = string(x)
_statCell(x::Real) =
    isfinite(x) ? string(round(x; sigdigits = 6)) : "unavailable (not finite: $x)"
_statCell(::Missing) = "unavailable"
_statCell(x::AbstractVector) = join(_statCell.(x), ", ")
_statCell(x) = replace(string(x), r"[\t\r\n]+" => " ")

# Appends one line; the caller holds the lock. Flushes when the cap is reached.
function _statPush!(b::StatBuffer, line::AbstractString)
    push!(b.lines, String(line))
    b.bytes += ncodeunits(line) + 1
    b.bytes ≥ b.cap && _statFlush!(b)
    return nothing
end

# Writes the pending lines to the scratch file
# (made on the first call), and counts the time.
function _statFlush!(b::StatBuffer)
    isempty(b.lines) && return nothing
    t = time_ns()
    if b.spill === nothing
        # in this process's folder of BAYSOL's one temporary root (`Platform.tmp_dir`)
        dir = mkpath(Platform.tmp_process_dir())
        path = joinpath(dir, basename(tempname()) * ".statistics")
        b.spill = path
        atexit() do                              # our own scratch file and folder
            rm(path; force = true)
            try
                rm(dir)                          # only while it is empty
            catch
            end
        end
    end
    open(b.spill, "a") do io
        foreach(l -> println(io, l), b.lines)
    end
    empty!(b.lines)
    b.bytes = 0
    b.nFlushes += 1
    b.flushSeconds += (time_ns() - t) / NS_PER_S
    return nothing
end

"""
Flushes the pending lines of the buffer to its scratch file: a phase boundary.

# Returns
- `nothing`.

# Exceptions
- `SystemError` if the scratch file cannot be written.
"""
statPhase!(::Nothing) = nothing
statPhase!(b::StatBuffer) = lock(() -> _statFlush!(b), b.lock)

# The heading line of a section, after the blank line that ends the one before. The caller
# holds the lock.
function _statHeading!(b::StatBuffer, name::AbstractString)
    _statPush!(b, "")
    _statPush!(b, "-- $name --")
    return nothing
end

"""
    statSection!(buf, name)

Opens the section `name`: a blank line, then `-- name --`. The rows, table or text lines
recorded next belong to it until the next section.

# Returns
- `nothing`.

# Exceptions
- None.
"""
statSection!(::Nothing, ::AbstractString) = nothing
statSection!(b::StatBuffer, name::AbstractString) =
    (lock(() -> _statHeading!(b, name), b.lock); nothing)

"""
    statRow!(buf, name, value)

Records the row `name`, spaces, a tab and the value (a name of at most 31 characters, so
the rows line up as the run log's do; a reader strips the spaces). A non-finite number is
written as `unavailable (not finite: ...)`, `missing` as `unavailable`: never as a zero.

# Returns
- `nothing`.

# Exceptions
- `ArgumentError` if `name` is longer than 31 characters.
"""
statRow!(::Nothing, ::AbstractString, value) = nothing
function statRow!(b::StatBuffer, name::AbstractString, value)
    length(name) < _STAT_NAME_WIDTH ||
        throw(ArgumentError("a statistics row name has at most 31 characters: $name"))
    lock(b.lock) do
        _statPush!(b, rpad(name, _STAT_NAME_WIDTH) * "\t" * _statCell(value))
    end
    return nothing
end

"""
Records that a value is not available, with the reason: `name`, tab, `unavailable: why`.

# Returns
- `nothing`.

# Exceptions
- As [`statRow!`](@ref).
"""
statUnavailable!(b, name::AbstractString, why::AbstractString) =
    statRow!(b, name, "unavailable: " * why)

"""
Records a line of text as it is (one item of a `text` section).

# Returns
- `nothing`.

# Exceptions
- None.
"""
statText!(::Nothing, ::AbstractString) = nothing
statText!(b::StatBuffer, text::AbstractString) =
    (lock(() -> _statPush!(b, text), b.lock); nothing)

"""
Records a table: a header line and a line for each row, the cells tab-separated, each
(but the last of a line) padded with spaces to 16 characters (a reader strips them).

# Returns
- `nothing`.

# Exceptions
- None.
"""
statTable!(::Nothing, header, rows) = nothing
function statTable!(b::StatBuffer, header, rows)
    line(cells) = join(
        (
            j < length(cells) ? rpad(c, _STAT_CELL_WIDTH) : c for
            (j, c) in enumerate(_statCell.(cells))
        ),
        "\t",
    )
    lock(b.lock) do
        _statPush!(b, line(header))
        foreach(r -> _statPush!(b, line(r)), rows)
    end
    return nothing
end

"""
Sets the label of the next attempt and what led to it: `trigger` (the text of the cause),
`class` (the failure class: `convergence`, `KinkDetected`, a ladder class) and `rung` (the
change applied). The next [`statAttempt!`](@ref) uses it and clears it; an attempt with no
label is the `"base run"`, with class and rung `none`.

# Returns
- `nothing`.

# Exceptions
- None.
"""
statLabel!(::Nothing, ::AbstractString, ::AbstractString = ""; kw...) = nothing
function statLabel!(b::StatBuffer, label::AbstractString, trigger::AbstractString = "";
    class::AbstractString = "", rung::AbstractString = "")
    lock(b.lock) do
        b.pending = (label = String(label), trigger = String(trigger),
            class = String(class), rung = String(rung))
    end
    return nothing
end

# Writes the `outcome` and `statistics error` sections of the attempt that ends; the
# caller holds the lock.
function _statEnd!(b::StatBuffer)
    if !isempty(b.outcome)
        _statHeading!(b, "outcome")
        for (n, v) in b.outcome
            _statPush!(b, rpad(n, _STAT_NAME_WIDTH) * "\t" * _statCell(v))
        end
        empty!(b.outcome)
    end
    if !isempty(b.errors)
        _statHeading!(b, "statistics error")
        foreach(e -> _statPush!(b, e), b.errors)
        empty!(b.errors)
    end
    return nothing
end

"""
Starts the block of an attempt (the end of the one before, a flush, then `--- attempt <k>:
<label> ---` and its `settings` section with the trigger rows `triggeredBy`, `triggerClass`
and `rung`). `stages` is the run's stage log, whose stage count marks where the attempt's
stage timings begin.

# Returns
- The attempt's number `k` (1 for the first).

# Exceptions
- None.
"""
statAttempt!(::Nothing, ::Any) = 0
function statAttempt!(b::StatBuffer, timing)
    lock(b.lock) do
        _statEnd!(b)
        _statFlush!(b)
        p = b.pending
        label = isempty(p.label) ? "base run" : p.label
        b.pending = _NO_PENDING
        push!(b.attempts, label)
        k = length(b.attempts)
        b.again = 0
        empty!(b.kink)
        _statPush!(b, "")
        _statPush!(b, "--- attempt $k: $label ---")
        _statHeading!(b, "settings")
        row(n, v) = _statPush!(b, rpad(n, _STAT_NAME_WIDTH) * "\t" * _statCell(v))
        isempty(p.trigger) || row("triggeredBy", p.trigger)
        row("triggerClass", isempty(p.class) ? "none" : p.class)
        row("rung", isempty(p.rung) ? "none" : p.rung)
        b.stage0 = timing === nothing ? 0 : length(timing.stages)
        b.c1base = nothing
        return k
    end
end

# Runs `f` and, if it throws, records the error as a line of the attempt's `statistics
# error` section instead: the statistics never fail a run.
function _safely(f, b::StatBuffer)
    try
        return f()
    catch err
        try
            msg = replace(first(sprint(showerror, err), 300), r"[\t\r\n]+" => " ")
            lock(() -> push!(b.errors, "statisticsError: " * msg), b.lock)
        catch
        end
        return nothing
    end
end

"""
Records the settings an attempt actually used (the sampler's, as `_infer` got them) as rows
of the attempt's `settings` section.

# Returns
- `nothing`.

# Exceptions
- None.
"""
statSettings!(::Nothing, ::Any...) = nothing
statSettings!(b::StatBuffer, args...) = _safely(() -> _statSettings!(b, args...), b)
function _statSettings!(
    b::StatBuffer, seed::Seed{<:Real,N}, nSamples, nAdapt, δ, base, nChains,
    options::SamplerOptions,
) where {N}
    statRow!(b, "targetAccept", δ)
    statRow!(b, "nChains", nChains)
    statRow!(b, "nSamples", nSamples)
    statRow!(b, "nAdapt", nAdapt)
    statRow!(b, "nDraws", nSamples - nAdapt)
    statRow!(b, "rngSeed", base)
    statRow!(b, "chainStartRadii", options.chainStartRadii)
    statRow!(b, "c1Mode", N == 4 ? "profiled" : "sampled (fifth parameter)")
    statRow!(b, "kinkWatch", options.watchKink)
    statRow!(b, "mapNStarts", options.mapNStarts)
    statRow!(b, "mapMaxIter", options.mapMaxIter)
    return nothing
end

"""
Records what a MAP search found, in the lines of `bysl fits diagnose`. The first search of
an attempt writes the `problem` section (the rule, the label, the size of the problem and
the supports) and then the `map search` section: the line of the search (seconds, starts,
modes, whether the sampler was whitened), `L-BFGS starts (z space):` with how each start
stopped (iterations, the stopping rules, the objective evaluations and the final gradient,
the optimizer's own record), the eigenvalues of the first-pass Hessian at the MAP and the
optima with the eigenvalues of their Hessian and their Laplace masses. A re-whitening is a
`map search again` section with `heading` as its first line and the same lines.

# Arguments
- `prob`: `(; pr, nQ, nAtoms, lMax)`, the priors and the
    size of the problem ([`statProblem`](@ref) of a seed);
    `sp`: the [`_SamplingSpace`](@ref) the search returned.
- `seconds`: how long the search took (measured by the run, not here).

# Returns
- `nothing`.

# Exceptions
- None.
"""
statMapSearch!(::Nothing, ::Any...) = nothing
statMapSearch!(b::StatBuffer, args...) = _safely(() -> _statMapSearch!(b, args...), b)
function _statMapSearch!(b::StatBuffer, prob, sp::_SamplingSpace, seconds::Real,
    heading::AbstractString = "")
    pr = prob.pr
    text(l) = statText!(b, l)
    if isempty(heading)
        label = lock(() -> isempty(b.attempts) ? "" : last(b.attempts), b.lock)
        statSection!(b, "problem")
        foreach(text,
            fmtDiagHeader(label, prob.nQ, prob.nAtoms, prob.lMax, EXCL_VOL_CORR_TOL))
        text(
            fmtDiagSupport(pr.δρ₃Prior.μ, pr.δρ₃Prior.μ + pr.δρ₃Prior.σ,
                pr.δρ₁Prior.μ, pr.δρ₁Prior.μ + pr.δρ₁Prior.σ),
        )
        statSection!(b, "map search")
    else
        n = lock(() -> b.again += 1, b.lock)
        statSection!(b, n == 1 ? "map search again" : "map search again $n")
        text(heading)
    end
    text(fmtDiagMap(seconds, sp.nOk, sp.nStarts, sp.nModes, sp.whitened))
    text("L-BFGS starts (z space):")
    for r in sp.starts
        text(
            fmtDiagStart(r.start, r.feasible, r.f, r.iters, r.gConverged, r.iterLimit,
                r.evals, r.gNorm),
        )
    end
    isempty(sp.optima) ? text("MAP Hessian eigenvalues: unavailable (no optimum)") :
    text(fmtDiagHessian(MAP_HESS_EIG_FLOOR, collect(first(sp.optima).λ)))
    modes = [
        (; o.f, ξ = Ξ(SVector{4}((sp.μ .+ sp.σ .* o.z)[1:4]), pr), λ = collect(o.λ),
            logMass = o.logmass) for o in sp.optima
    ]
    foreach(text, fmtDiagModes(modes))
    statPhase!(b)
    return nothing
end

"The priors and size of a seed, as [`statMapSearch!`](@ref) takes them."
statProblem(seed::Seed) = (; pr = seed.pr, nQ = length(seed.fw.qvals),
    nAtoms = seed.fw.nAtoms, lMax = seed.fw.lMax)

"""
Records what the chain watch of the kink check did in chain `k`: the checks it made, the
draws the last one examined, how many of them had two basins and the draw count at which it
fired (`0`: it did not fire). Written as the `kink check` section when the attempt's chains
are recorded ([`statChains!`](@ref)) or the attempt stops ([`statStopped!`](@ref)).

# Returns
- `nothing`.

# Exceptions
- None.
"""
statKink!(::Nothing, ::Integer, ::Integer, ::Integer, ::Integer, ::Integer) = nothing
function statKink!(b::StatBuffer, k::Integer, checks::Integer, looked::Integer,
    two::Integer, at::Integer)
    checks == 0 && return nothing
    lock(() -> push!(b.kink, (k, checks, looked, two, at)), b.lock)
    return nothing
end

# The `kink check` section from what the chains recorded (nothing if none watched).
function _statKinkSection!(b::StatBuffer)
    rows = lock(b.lock) do
        r = sort(b.kink)
        empty!(b.kink)
        r
    end
    isempty(rows) && return nothing
    statSection!(b, "kink check")
    statTable!(b, ["chain", "checks", "drawsExamined", "drawsTwoBasins", "firedAtDraw"],
        [[k, c, l, t, a == 0 ? "none" : string(a)] for (k, c, l, t, a) in rows])
    return nothing
end

"""
The divergent draws of the run, one row each, in the order the attempts recorded
them: a `NamedTuple` `(; attempt, chain, draw, phase, xi, logπ, dLogπ, steps, depth)`
with the draw's iteration within its chain, its `phase` (`warm-up` or `sampling`),
the first four coordinates of ξ, log π, log π minus the median log π of the chain's
sampling draws (of all its draws if it has none), the leapfrog steps and the tree
depth of the transition. The rows are the sampler's own per-draw records; they are
not in the log (the workbook's `divergences` sheet holds them).

# Returns
- `Vector{NamedTuple}`.

# Exceptions
- None.
"""
statDivergences(::Nothing) = NamedTuple[]
statDivergences(b::StatBuffer) = lock(() -> NamedTuple[r for r in b.divergences], b.lock)

# The divergent draws of every chain of the attempt, into the buffer's list.
function _statDivergences!(b::StatBuffer, runs, nAdapt::Integer)
    k = lock(() -> length(b.attempts), b.lock)
    rows = NamedTuple[]
    for r in runs
        (r.error === nothing && r.stats !== nothing) || continue
        st = r.stats
        ld = [s.log_density for s in st]
        post = ld[min(nAdapt+1, length(ld)):end]
        med = median(isempty(post) ? ld : post)
        for i in eachindex(st)
            st[i].numerical_error || continue
            push!(
                rows,
                (; attempt = k, chain = r.k, draw = i,
                    phase = i ≤ nAdapt ? "warm-up" : "sampling",
                    xi = Float64[r.ξ[i][j] for j in 1:min(4, length(r.ξ[i]))],
                    logπ = ld[i], dLogπ = ld[i] - med, steps = st[i].n_steps,
                    depth = st[i].tree_depth),
            )
        end
    end
    lock(() -> append!(b.divergences, rows), b.lock)
    return nothing
end

_skew(x) = (m = mean(x); s = std(x); mean(((x .- m) ./ s) .^ 3))

# The draws-based shape of the posterior along the whitened axes: for axis `a`, the
# draws whose w_a lies in a bin around `s` give the median of the excess of −log π over
# the mode's, less the Gaussian share (½ w_b²) of the other axes, over ½ w_a² (1 =
# Gaussian), and the second divided difference of the bins' medians (f''). `W` is N ×
# n, `dℓ = ℓπ(mode) − ℓπ(draw)`. A bin with fewer than `STAT_BIN_MIN` draws is `NaN`.
function _axisShape(W::AbstractMatrix, dℓ::AbstractVector, a::Integer)
    n = size(W, 2)
    wa = W[a, :]
    rest = [0.5 * (sum(abs2, @view W[:, i]) - wa[i]^2) for i in 1:n]
    g = dℓ .- rest                                   # ½ w_a² for a Gaussian target
    binMed(f, c, h) = (
        sel = findall(i -> abs(wa[i] - c) ≤ h, 1:n);
        length(sel) < STAT_BIN_MIN ? NaN : median(f.(sel))
    )
    ratio = [
        binMed(i -> g[i] / (0.5 * wa[i]^2), s, max(0.25, 0.1 * abs(s))) for
        s in DIAG_AXIS_S
    ]
    centres = -3.0:0.5:3.0
    xs = [
        (
            sel = findall(i -> abs(wa[i] - c) ≤ 0.25, 1:n);
            length(sel) < STAT_BIN_MIN ? NaN : median(wa[sel])
        ) for c in centres
    ]
    gs = [binMed(i -> g[i], c, 0.25) for c in centres]
    f2 = Float64[]
    at = Float64[]
    for j in 2:(length(centres)-1)
        x1, x2, x3 = xs[j-1], xs[j], xs[j+1]
        g1, g2, g3 = gs[j-1], gs[j], gs[j+1]
        all(isfinite, (x1, x2, x3, g1, g2, g3)) || continue
        push!(f2, 2 * ((g3 - g2) / (x3 - x2) - (g2 - g1) / (x2 - x1)) / (x3 - x1))
        push!(at, x2)
    end
    return (; ratio, f2, at)
end

# The tally of c1 draws at the bounds, per chain and overall, from the re-profiled c1.
function _c1AtBounds(ex, c, nAdapt)
    keep = findall(>(nAdapt), ex.rows[c])
    c1 = ex.c1[c][keep]
    return (; keep, c1)
end

# Wald-Wolfowitz runs test on the signs of `r`: (runs, expected, z, two-sided p).
function _runsTest(r::AbstractVector)
    s = r .> 0
    np = count(s)
    nm = length(s) - np
    (np == 0 || nm == 0) && return (; runs = 1, expected = NaN, z = NaN, p = NaN)
    runs = 1 + count(i -> s[i] != s[i-1], 2:length(s))
    μ = 2np * nm / (np + nm) + 1
    v = (μ - 1) * (μ - 2) / (np + nm - 1)
    z = v > 0 ? (runs - μ) / sqrt(v) : NaN
    return (; runs, expected = μ, z, p = 2 * ccdf(Normal(), abs(z)))
end

"""
Records the chains of one sampling pass in the layout of `bysl fits diagnose` and its
`chain_report`, as sections of the attempt's block (names and columns in
[`STAT_SECTIONS`](@ref)): `nuts` (the NUTS line, the mean leapfrog steps by warm-up
window, the mean acceptance), `chains` (a table, a row per chain: start, mode, kept
draws, divergent draws and their share in the sampling and in the warm-up, step size,
leapfrog steps, acceptance, mean log π, the spread of the energy error, the share of
trees at depth 10, BFMI, the share of draws with c1 at a bound, the gradient
evaluations and the non-finite ones), `chain totals`, `posterior` (sd, covariance
eigenvalues, skewness and ESS of the draws in the whitened coordinates, and log π at
the mode, the best and the median draw), `bounds`, `axes` (the sampled sd in z and,
along each whitened axis, the departure of the draws' log π from a Gaussian, the draws'
second differences and the jumps of their c1), `correlation` (of ξ), `residuals`
(Durbin-Watson and the runs test of the best draw's residuals), `convergence` (R̂, ESS,
sd and Monte Carlo standard error per parameter), `gate`, `modes`, `health` (step
sizes, leapfrog steps, the cost per effective sample, the non-finite evaluations, the
curvature bound, c1 at the bounds), `c1 search`, `kink check` and `stage timings`.

Everything is read from what the run holds: the per-draw statistics of the sampler (steps,
depth, acceptance, energy, energy error, divergence, step size, log density), the draws and
the counters of the chains, the c1 re-profile of the draws, the MAP search's records and
the gate's R̂ and ESS. Nothing is replayed or re-evaluated for the log. Where
`bysl fits diagnose` measures on a grid (axis scans, the local curvature, a second
Hessian pass) the log keeps its lines and columns, from the draws: the differences are in
`src/inference/README.md`. The curvature line is a lower bound of λ_max: the quotient
‖Δ∇ℓπ‖/‖Δw‖ of successive gradient evaluations, never above it. Gradient error from the c1
tolerance and the second Hessian pass are not measured. The averages are over the draws of
the chains the pool keeps. Divergent draws are not listed here: [`statDivergences`](@ref)
holds them.

# Arguments
- `pr`, `sp`: the priors of the seed and the sampling space of the pass.
- `runs`: the chains (`_ChainRun`, all of them), `d`: the run's
    [`ChainDiagnostics`](@ref), `names`: the parameter names, `nSamples`,
    `nAdapt`: the sizes of the pass, `δ` the target acceptance in percent
    and `base` the run's seed; `timing`: the run's stage log.
- `ex`: what the run holds besides the chains, `(; pk, rows, c1, curves, c1base, c1now,
    iObs, weights, cmin, cmax)`: the pooled chains' indices and kept rows, the c1 and the
    curves of the re-profile of those rows, the c1 search counters at the start and now,
    the observed intensities and weights, and the c1 bounds; or `nothing`, then the sections
    that need them say `unavailable`.

# Returns
- `nothing`.

# Exceptions
- None.
"""
statChains!(::Nothing, ::Any...) = nothing
statChains!(b::StatBuffer, args...) = _safely(() -> _statChains!(b, args...), b)
function _statChains!(b::StatBuffer, pr, sp::_SamplingSpace{N}, runs,
    d::ChainDiagnostics, names, nSamples::Integer, nAdapt::Integer, δ, base,
    timing, ex = nothing) where {N}
    part(f) = _safely(f, b)
    text(l) = statText!(b, l)
    usable(r) = r.error === nothing && r.stats !== nothing && length(r.stats) > nAdapt
    kept = [r for r in runs if usable(r) && d.pooled[r.k]]
    post(r) = (nAdapt+1):length(r.stats)
    ps = [s for r in kept for s in r.stats[post(r)]]
    pn = collect(String, names)
    length(pn) == N || (pn = ["p$i" for i in 1:N])
    nan(::Missing) = NaN
    nan(x) = x
    # the draws the posterior sections work on: ξ, whitened w, log π of the kept chains
    ξ = [x for r in kept for x in r.ξ[post(r)]]
    ld = [s.log_density for s in ps]
    tallies = [r.tally for r in kept]
    haveW = !isempty(kept) && all(!isnothing, tallies)
    W =
        haveW ? reduce(hcat, [t.ws[i] for (r, t) in zip(kept, tallies) for i in post(r)]) :
        zeros(N, 0)
    εReached = isempty(kept) ? NaN : mean(last(r.stats).step_size for r in kept)
    ε0s = filter(isfinite, [r.ε0 for r in kept])
    ε0 = isempty(ε0s) ? NaN : mean(ε0s)
    # which pooled chain index (into `ex`) belongs to chain k
    cIndex(k) = ex === nothing ? nothing : findfirst(==(k), ex.pk)

    part(() -> _statDivergences!(b, runs, nAdapt))

    part() do
        statSection!(b, "nuts")
        if isempty(ps)
            text("unavailable: no pooled draws after the warm-up")
            return nothing
        end
        steps = getproperty.(ps, :n_steps)
        depth = getproperty.(ps, :tree_depth)
        text(
            fmtDiagNuts(maximum(r.seconds for r in runs), ε0, εReached, mean(steps),
                mean(depth), mean(depth .>= 10), count(s -> s.numerical_error, ps)),
        )
        if all(r -> length(r.stats) == nSamples, kept)
            ns = [mean(r.stats[i].n_steps for r in kept) for i in 1:nSamples]
            text(fmtDiagWindows(ns, nSamples, nAdapt))
        else
            text("mean nSteps by window: unavailable (a chain has fewer iterations)")
        end
        text(
            fmtDiagAccept(mean(getproperty.(ps, :acceptance_rate)),
                mean(abs.(getproperty.(ps, :hamiltonian_energy_error)))),
        )
    end

    nPooled = 0
    nDivAll = 0
    nWarmDiv = 0
    part() do
        statSection!(b, "chains")
        rows = Vector{String}[]
        for r in runs
            k = r.k
            c = cIndex(k)
            tl = r.tally
            grads = tl === nothing ? missing : tl.nGrad
            bad = tl === nothing ? missing : tl.nNonFinite
            blank = (; k, start = d.startScale[k], mode = d.mode[k], pooled = d.pooled[k],
                nPost = 0, div = missing, warmDiv = missing, warmN = 0, ε = NaN,
                steps = NaN, accept = NaN, logπ = NaN, eSd = NaN, deep = NaN,
                bfmi = NaN, pin = NaN, grads, bad, note = "")
            if r.error !== nothing || r.stats === nothing
                push!(
                    rows,
                    fmtChainRow((; blank..., note = "chain stopped: " * d.reason[k])),
                )
                continue
            end
            st = r.stats
            nW = min(nAdapt, length(st))
            warmDiv = count(i -> st[i].numerical_error, 1:nW)
            if length(st) ≤ nAdapt || !d.pooled[k]
                push!(
                    rows,
                    fmtChainRow((; blank..., warmDiv, warmN = nW,
                        note = d.pooled[k] ? "no post-warm-up draws kept" :
                               "not pooled: " * d.reason[k])),
                )
                continue
            end
            pi = post(r)
            nd = count(i -> st[i].numerical_error, pi)
            nPooled += length(pi)
            nDivAll += nd
            nWarmDiv += warmDiv
            e = [st[i].hamiltonian_energy for i in pi]
            de = diff(e)
            bfmi =
                length(e) > 1 && sum(abs2, e .- mean(e)) > 0 ?
                sum(abs2, de) / sum(abs2, e .- mean(e)) : NaN
            pin = NaN
            if c !== nothing
                cc = _c1AtBounds(ex, c, nAdapt).c1
                isempty(cc) || (
                    pin = mean(
                        x ->
                            x ≤ ex.cmin + STAT_C1_PIN_TOL ||
                            x ≥ ex.cmax - STAT_C1_PIN_TOL,
                        cc,
                    )
                )
            end
            push!(
                rows,
                fmtChainRow((; k, start = d.startScale[k], mode = d.mode[k],
                    pooled = true, nPost = length(pi), div = nd, warmDiv, warmN = nW,
                    ε = mean(st[i].step_size for i in pi),
                    steps = mean(st[i].n_steps for i in pi),
                    accept = mean(st[i].acceptance_rate for i in pi),
                    logπ = mean(st[i].log_density for i in pi),
                    eSd = std(getproperty.(st[pi], :hamiltonian_energy_error)),
                    deep = mean(st[i].tree_depth ≥ 10 for i in pi), bfmi, pin, grads, bad,
                    note = "")),
            )
        end
        statTable!(b, CHAIN_COLUMNS, rows)
    end
    part() do
        statSection!(b, "chain totals")
        statRow!(b, "chainsRun", length(runs))
        statRow!(b, "chainsPooled", count(d.pooled))
        statRow!(b, "pooledDraws", nPooled)
        statRow!(b, "divergentDraws", nDivAll)
        statRow!(b, "warmupDivergentDraws", nWarmDiv)
    end
    part(() -> _statKinkSection!(b))

    # the draws in w: sd, covariance, skewness and ESS; log π at the mode, best and median
    part() do
        statSection!(b, "posterior")
        if !haveW || size(W, 2) < 2
            text("unavailable: no whitened draws of the pooled chains")
            return nothing
        end
        n = size(W, 2)
        text(fmtDiagPostW([std(W[i, :]) for i in 1:N]))
        cube = zeros(max(minimum(length.(post.(kept))), 0), length(kept), N)
        for (c, r) in enumerate(kept), (j, i) in enumerate(post(r))
            j ≤ size(cube, 1) || break
            for a in 1:N
                cube[j, c, a] = tallies[c].ws[i][a]
            end
        end
        essW = convergence(cube).ess
        text(fmtDiagCov(eigvals(Symmetric(cov(W'))), [_skew(W[i, :]) for i in 1:N], essW))
        text(fmtDiagEll(sp.logπ, maximum(ld), median(ld), N,
            quantile(Chisq(N), 0.5) / 2))
        Z = sp.ẑ .+ sp.S * W
        text(fmtDiagSdZ([std(Z[i, :]) for i in 1:N] ./ sqrt.(diag(sp.S * sp.S'))))
        return nothing
    end

    # the distance to the prior bounds (the first four coordinates; c1 when it is sampled)
    part() do
        statSection!(b, "bounds")
        bnd = Any[(0.0, Inf), (pr.δρ₁Prior.μ, pr.δρ₁Prior.μ + pr.δρ₁Prior.σ),
            (pr.δρ₂Prior.μ, pr.δρ₂Prior.μ + pr.δρ₂Prior.σ),
            (pr.δρ₃Prior.μ, pr.δρ₃Prior.μ + pr.δρ₃Prior.σ)]
        N > 4 && ex !== nothing && push!(bnd, (ex.cmin, ex.cmax))
        rows = Vector{Any}[]
        for j in 1:min(N, length(bnd))
            xs = isempty(ξ) ? Float64[] : [x[j] for x in ξ]
            if length(xs) < 2
                push!(rows, [pn[j], missing, missing, missing, missing])
                continue
            end
            lo, hi = bnd[j]
            sdj = std(xs)
            md = median(xs)
            push!(
                rows,
                [pn[j], md, sdj, sdj > 0 ? min(md - lo, hi - md) / sdj : NaN,
                    sdj > 0 ? mean(x -> min(x - lo, hi - x) ≤ 0.1sdj, xs) : NaN],
            )
        end
        statTable!(b, ["coordinate", "median", "sd", "distanceSd", "shareNearBound"], rows)
    end

    # the shape along the whitened axes, from the draws
    part() do
        statSection!(b, "axes")
        if !haveW || size(W, 2) < 2STAT_BIN_MIN
            text("unavailable: too few whitened draws of the pooled chains")
            return nothing
        end
        dℓ = sp.logπ .- ld
        text(fmtDiagAxesHeading())
        shapes = [_axisShape(W, dℓ, a) for a in 1:N]
        foreach(a -> text(fmtDiagAxis(a, shapes[a].ratio)), 1:N)
        # c1 along the axis: the re-profiled c1 of the draws that lie along it
        w1 = Dict{Int,Vector{Tuple{Float64,Float64}}}(a => [] for a in 1:N)
        if ex !== nothing && haveW
            for (c, r) in enumerate(kept)
                ci = cIndex(r.k)
                ci === nothing && continue
                for (j, i) in enumerate(ex.rows[ci])
                    i > nAdapt || continue
                    w = tallies[c].ws[i]
                    nw = sum(abs2, w)
                    for a in 1:N
                        abs2(w[a]) ≥ 0.5nw && push!(w1[a], (w[a], ex.c1[ci][j]))
                    end
                end
            end
        end
        for a in 1:N
            f2 = shapes[a].f2
            cs = sort(w1[a]; by = first)
            c1 = last.(cs)
            jumps =
                length(c1) < 2 ? -1 :
                count(j -> abs(c1[j] - c1[j-1]) > STAT_C1_JUMP, 2:length(c1))
            im = isempty(f2) ? 0 : argmax(f2)
            text(
                fmtDiagScan(a, NaN, isempty(f2) ? NaN : median(f2),
                    isempty(f2) ? NaN : f2[im], isempty(f2) ? NaN : shapes[a].at[im],
                    isempty(c1) ? NaN : minimum(c1), isempty(c1) ? NaN : maximum(c1), jumps,
                ),
            )
        end
        text(
            fmtDiagCurvature(
                isempty(kept) || !haveW ? [NaN, NaN, NaN] :
                (
                    λ = reduce(vcat, [t.curvature[t.fromPost:end] for t in tallies]);
                    isempty(λ) ? [NaN, NaN, NaN] : [minimum(λ), median(λ), maximum(λ)]
                ),
                (
                    λ = haveW ?
                        reduce(vcat, [t.curvature[t.fromPost:end] for t in tallies]) :
                        Float64[];
                    isempty(λ) ? [NaN, NaN] : 2 ./ sqrt.([maximum(λ), median(λ)])
                ),
                εReached),
        )
        return nothing
    end

    part() do
        statSection!(b, "correlation")
        if length(ξ) < 3
            statTable!(b, ["parameter"], [["unavailable: no pooled draws"]])
            return nothing
        end
        X = reduce(hcat, [collect(Float64, x) for x in ξ])'
        C = cor(X)
        statTable!(b, vcat("parameter", pn), [vcat(pn[i], C[i, :]) for i in 1:N])
    end

    part() do
        statSection!(b, "residuals")
        if ex === nothing || isempty(kept)
            statUnavailable!(b, "residualSource", "no re-profiled draws")
            return nothing
        end
        best = (ld = -Inf, c = 0, j = 0)
        for r in kept
            ci = cIndex(r.k)
            ci === nothing && continue
            for (j, i) in enumerate(ex.rows[ci])
                i > nAdapt || continue
                l = r.stats[i].log_density
                (!r.stats[i].numerical_error && l > best.ld) &&
                    (best = (ld = l, c = ci, j = j))
            end
        end
        if best.c == 0 || length(ex.iObs) != size(ex.curves[best.c], 1)
            statUnavailable!(b, "residualSource", "no re-profiled curve of a draw")
            return nothing
        end
        res = (ex.iObs .- ex.curves[best.c][:, best.j]) .* sqrt.(ex.weights)
        dw = sum(abs2, diff(res)) / sum(abs2, res)
        rt = _runsTest(res)
        statRow!(
            b,
            "residualSource",
            "the best sampled draw (log π " *
            _pf("%.4f", best.ld) * ")",
        )
        statRow!(b, "residualCount", length(res))
        statRow!(b, "durbinWatson", dw)
        statRow!(b, "runsCount", rt.runs)
        statRow!(b, "runsExpected", rt.expected)
        statRow!(b, "runsZ", rt.z)
        statRow!(b, "runsP", rt.p)
    end

    problems = String[]
    nDiv = count(s -> s.numerical_error, ps)
    part() do
        statSection!(b, "convergence")
        pnames = vcat(pn, "logDensity")
        length(pnames) == length(d.rhat) || (pnames = ["p$i" for i in eachindex(d.rhat)])
        sds = [
            isempty(ξ) ? NaN :
            (
                i ≤ N ? std([x[i] for x in ξ]) : (length(ld) > 1 ? std(ld) : NaN)
            ) for i in eachindex(d.rhat)
        ]
        statTable!(
            b, ["parameter", "rhat", "essBulk", "essTail", "sd", "mcse"],
            [
                [pnames[i], d.rhat[i], d.ess[i], d.essTail[i], sds[i],
                    sds[i] / sqrt(d.ess[i])] for i in eachindex(d.rhat)
            ],
        )
    end
    part() do
        share = isempty(ps) ? NaN : nDiv / length(ps)
        append!(problems, _convergenceProblems(d))
        isnan(share) || share < MAX_DIVERGENT_RATE ||
            push!(
                problems,
                "the divergent share, $(round(100share; digits = 3)) %, is " *
                "not below $(100MAX_DIVERGENT_RATE) %",
            )
        statSection!(b, "gate")
        statRow!(b, "rhatMax", _worstRhat(d))
        statRow!(b, "essMin", _worstEss(d.ess))
        statRow!(b, "essTailMin", _worstEss(d.essTail))
        statRow!(b, "nDivergent", nDiv)
        isnan(share) ?
        statUnavailable!(b, "divergentShare", "no pooled draws after warm-up") :
        statRow!(b, "divergentShare", share)
        statRow!(
            b,
            "gate",
            isempty(problems) ? "passed" : "failed: " * join(problems, "; "),
        )
    end
    part() do
        statSection!(b, "modes")
        statRow!(b, "modes", length(d.modeWeight))
        statRow!(b, "modeWeights", d.modeWeight)
        statRow!(b, "modeLogMass", d.modeLogmass)
        statRow!(b, "modeLogMassErr", d.modeErr)
        statRow!(b, "weightsUncertain", d.weightsUncertain)
        statRow!(b, "rewhitenedNats", d.rewhitened)
    end
    part() do
        statSection!(b, "health")
        nLfAll = sum(r -> r.stats === nothing ? 0 : sum(getproperty.(r.stats, :n_steps)),
            runs)
        nLfPost = isempty(ps) ? 0 : sum(getproperty.(ps, :n_steps))
        essMin = _worstEss(d.ess)
        statRow!(b, "stepSizeInitial", ε0)
        statRow!(b, "stepSizeReached", εReached)
        statRow!(b, "leapfrogTotal", nLfAll)
        statRow!(b, "leapfrogSampling", nLfPost)
        statRow!(
            b,
            "leapfrogPerEss",
            isfinite(essMin) && essMin > 0 ? nLfAll / essMin : NaN,
        )
        withT = [r.tally for r in runs if r.tally !== nothing]
        if isempty(withT)
            statUnavailable!(b, "gradientEvals", "the chains kept no tally")
            statUnavailable!(b, "nonFiniteEvals", "the chains kept no tally")
        else
            statRow!(b, "gradientEvals", sum(t -> t.nGrad, withT))
            statRow!(b, "nonFiniteEvals", sum(t -> t.nNonFinite, withT))
        end
        statRow!(b, "curvatureSamples",
            haveW ? sum(t -> length(t.curvature) - t.fromPost + 1, tallies) : missing)
        if ex === nothing
            statUnavailable!(b, "c1AtLowerBound", "no re-profiled draws")
            statUnavailable!(b, "c1AtUpperBound", "no re-profiled draws")
        else
            cs = reduce(vcat, [_c1AtBounds(ex, c, nAdapt).c1 for c in eachindex(ex.pk)];
                init = Float64[])
            statRow!(b, "c1AtLowerBound",
                isempty(cs) ? NaN : mean(x -> x ≤ ex.cmin + STAT_C1_PIN_TOL, cs))
            statRow!(b, "c1AtUpperBound",
                isempty(cs) ? NaN : mean(x -> x ≥ ex.cmax - STAT_C1_PIN_TOL, cs))
        end
    end
    part() do
        statSection!(b, "c1 search")
        if ex === nothing
            statUnavailable!(b, "c1Solves", "no counters")
            return nothing
        end
        c = (;
            (
                k => getproperty(ex.c1now, k) - getproperty(ex.c1base, k) for
                k in keys(ex.c1now)
            )...
        )
        statRow!(b, "c1Solves", c.solves)
        statRow!(b, "c1BrentIterations", c.brentIters)
        statRow!(b, "c1BrentPerSolve", c.solves > 0 ? c.brentIters / c.solves : NaN)
        statRow!(b, "c1ScanAtEdge", c.scanEdge)
        statRow!(b, "c1WlsErrors", c.wlsErrors)
    end
    part(() -> statStages!(b, timing))
    statPhase!(b)
    return nothing
end

"""
Records the stage timings of the attempt (the stages the run's timing log gained since
[`statAttempt!`](@ref)) as the `stage timings` section: name, seconds, JIT and GC seconds,
notes.

# Returns
- `nothing`.

# Exceptions
- None.
"""
statStages!(::Nothing, ::Any) = nothing
statStages!(::StatBuffer, ::Nothing) = nothing
function statStages!(b::StatBuffer, timing::StageLog)
    stages = lock(timing.lock) do
        timing.stages[(b.stage0+1):end]
    end
    statSection!(b, "stage timings")
    statTable!(
        b, ["stage", "seconds", "jit", "gc", "notes"],
        [["  "^s.depth * s.name, s.seconds, s.compile, s.gc, s.note] for s in stages],
    )
    return nothing
end

"""
Records how an attempt ended when it did not reach its gate (`KinkDetected`, an error): the
`stopped` row of its `outcome` section (the kink check's table is written first).

# Returns
- `nothing`.

# Exceptions
- None.
"""
statStopped!(::Nothing, ::AbstractString) = nothing
function statStopped!(b::StatBuffer, why::AbstractString)
    _safely(() -> _statKinkSection!(b), b)
    lock(() -> push!(b.outcome, ("stopped", String(why))), b.lock)
    return nothing
end

"""
Records what the run does next after an attempt: the `next` row of its `outcome` section.

# Returns
- `nothing`.

# Exceptions
- None.
"""
statNext!(::Nothing, ::AbstractString) = nothing
function statNext!(b::StatBuffer, what::AbstractString)
    lock(() -> push!(b.outcome, ("next", String(what))), b.lock)
    return nothing
end

"""
Names the attempt that is the result and why (the last call wins; an attempt number as
[`statAttempt!`](@ref) returned it).

# Returns
- `nothing`.

# Exceptions
- None.
"""
statKeep!(::Nothing, ::Integer, ::AbstractString) = nothing
function statKeep!(b::StatBuffer, k::Integer, why::AbstractString)
    lock(b.lock) do
        b.kept = k
        b.keptWhy = String(why)
    end
    return nothing
end

"The number of attempts the buffer has started."
statAttempts(::Nothing) = 0
statAttempts(b::StatBuffer) = lock(() -> length(b.attempts), b.lock)

"""
The text of the buffer, in order, for the run's section: every flushed line (the scratch
file is read back line by line), the end of the last attempt, then the `attempts` table
(each attempt, kept or dropped) and the `result` section (which attempt is the result and
why, or that none is: `failure`, and the cost of the statistics: flushes).

# Arguments
- `failure`: `nothing`, or the text of the error that ended the run.

# Returns
- `Vector{String}`: the lines.

# Exceptions
- `SystemError` if the scratch file cannot be read.
"""
function statLines(b::StatBuffer; failure::Union{Nothing,AbstractString} = nothing)
    lock(b.lock) do
        _statEnd!(b)
        _statFlush!(b)
        out = String[]
        b.spill === nothing || append!(out, eachline(b.spill))
        cell(v) = _statCell(v)
        push!(out, "", "-- attempts --")
        push!(
            out,
            join(vcat(rpad.(["attempt", "label"], _STAT_CELL_WIDTH), "outcome"), "\t"),
        )
        for (k, l) in enumerate(b.attempts)
            push!(
                out,
                join(
                    vcat(rpad.([cell(k), l], _STAT_CELL_WIDTH),
                        (
                            failure !== nothing && k == length(b.attempts) ? "failed" :
                            k == b.kept ? "kept" : "dropped"
                        )), "\t"),
            )
        end
        push!(out, "", "-- result --")
        row(n, v) = push!(out, rpad(n, _STAT_NAME_WIDTH) * "\t" * cell(v))
        row("attempts", length(b.attempts))
        if failure !== nothing
            row("keptAttempt", "none")
            row("failed", failure)
        elseif b.kept > 0
            row("keptAttempt", b.kept)
            row("keptLabel", b.attempts[b.kept])
            row("keptBecause", b.keptWhy)
        else
            row("keptAttempt", "unavailable: no attempt reported its outcome")
        end
        row("statisticsFlushes", b.nFlushes)
        row("statisticsFlushSeconds", b.flushSeconds)
        return out
    end
end

"""
    StatSection

One section of a statistics log as [`statParse`](@ref) reads it: the `attempt`
it belongs to (`0` for the run's own sections) and its `label`, its `name` and
`kind`, and its content: the `scalars` of a scalars section as `name => value`
strings, the `header` and `rows` of a table, the `text` lines of a text section.
"""
struct StatSection
    attempt::Int
    label::String
    name::String
    kind::Symbol
    scalars::Vector{Pair{String,String}}
    header::Vector{String}
    rows::Vector{Vector{String}}
    text::Vector{String}
end

"""
    statParse(lines) -> Vector{StatSection}

Reads the lines of a statistics log (the body of a run's section: what
[`statLines`](@ref) returns, or the lines of the file between its `=== run ===`
heading and the next) by the grammar: `--- attempt N: label ---` starts an attempt's
block, `-- name --` a section whose kind is that of [`STAT_SECTIONS`](@ref) (an
unknown name is read as text); a scalars row is `name`, spaces and a tab and the
value, a table is a tab-separated header and its rows, a text section keeps its
lines. The padding spaces of names and cells are stripped, blank lines are skipped.

# Returns
- `Vector{StatSection}`, in file order.

# Exceptions
- None.
"""
function statParse(lines)
    out = StatSection[]
    attempt = 0
    label = ""
    cur = nothing
    for line in lines
        m = match(r"^--- attempt (\d+): (.*) ---$", line)
        if m !== nothing
            attempt = parse(Int, m[1])
            label = String(m[2])
            cur = nothing
            continue
        end
        m = match(r"^-- (.+) --$", line)
        if m !== nothing
            def = _statSection(m[1])
            lvl = def === nothing ? :attempt : def.level
            cur = StatSection(lvl == :run ? 0 : attempt, lvl == :run ? "" : label,
                String(m[1]), def === nothing ? :text : def.kind, Pair{String,String}[],
                String[], Vector{String}[], String[])
            push!(out, cur)
            continue
        end
        (cur === nothing || isempty(strip(line))) && continue
        if cur.kind == :scalars
            i = findfirst('\t', line)
            i === nothing ? push!(cur.scalars, rstrip(line) => "") :
            push!(cur.scalars, rstrip(line[1:(i-1)]) => String(line[(i+1):end]))
        elseif cur.kind == :table
            cells = String[rstrip(c) for c in split(line, '\t')]
            isempty(cur.header) ? append!(cur.header, cells) : push!(cur.rows, cells)
        else
            push!(cur.text, String(line))
        end
    end
    return out
end
