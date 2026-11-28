# SPDX-License-Identifier: LGPL-3.0-or-later

# ---------------------------------------------------------------------------
#          The summary sheets of the workbook (written by `results`)
# ---------------------------------------------------------------------------

# section and unit of each row of the `run` sheet (what a row means is in the TUI's
# `assets/data/column_descriptions.json`, group `runRows`, never in the workbook)
const _RUN_SECTIONS = ["model", "data", "sampler", "convergence", "output"]
const _RUN_INFO = Dict(
    "nAtoms" => ("model", "atoms"),
    "lmax" => ("model", ""),
    "dmax" => ("model", "Å"),
    "pmvFallbackUncert" => ("model", "cm³/mol"),
    "lmaxPinned" => ("model", ""),
    "memoryHeadroom" => ("model", "% of RAM"),
    "forwardBlocks" => ("model", "blocks"),
    "forwardBlockQ" => ("model", "q values"),
    "forwardBudgetGib" => ("model", "GiB"),
    "forwardEstGib" => ("model", "GiB"),
    "forwardPeakGib" => ("model", "GiB"),
    "addHydrogens" => ("model", ""),
    "structureModel" => ("model", ""),
    "qMin" => ("data", "Å⁻¹"),
    "qMax" => ("data", "Å⁻¹"),
    "sigmaScale" => ("data", ""),
    "nQInput" => ("data", "points"),
    "nQCropped" => ("data", "points"),
    "nQExcluded" => ("data", "points"),
    "cavityFrac" => ("model", ""),
    "exclVolSat" => ("model", ""),
    "c1Kink" => ("model", ""),
    "nQRaw" => ("data", "points"),
    "nQChi2" => ("data", "points"),
    "nQ" => ("data", "points"),
    "channels" => ("data", ""),
    "rebinChannels" => ("data", "bins"),
    "rebinMeasured" => ("data", "points"),
    "rebinFitted" => ("data", "points"),
    "rebinNonPositiveDropped" => ("data", "bins"),
    "nSamples" => ("sampler", "iterations"),
    "nAdapt" => ("sampler", "iterations"),
    "rngSeed" => ("sampler", ""),
    "iterations" => ("sampler", "draws"),
    "meanAccept" => ("sampler", ""),
    "treeDepthAvg" => ("sampler", ""),
    "treeDepthMax" => ("sampler", ""),
    "meanNSteps" => ("sampler", "steps"),
    "stepSize" => ("sampler", ""),
    "stepSizeMin" => ("sampler", ""),
    "ebfmi" => ("sampler", ""),
    "divergenceRate" => ("sampler", ""),
    "chainsPooled" => ("convergence", "chains"),
    "chainsRun" => ("convergence", "chains"),
    "rhatMax" => ("convergence", ""),
    "essMin" => ("convergence", "draws"),
    "essTailMin" => ("convergence", "draws"),
    "modes" => ("convergence", ""),
    "optima" => ("convergence", ""),
    "rewhitenedNats" => ("convergence", "nats"),
    "retryFirstRhat" => ("convergence", ""),
    "retryKept" => ("convergence", ""),
    "retryCount" => ("convergence", "runs"),
    "retryRungs" => ("convergence", "rungs"),
    "drawsRows" => ("output", "rows"),
    "quantileLoPct" => ("output", "%"),
    "quantileHiPct" => ("output", "%"),
)

# The per-run rows `attempt<k><Field>` of the run sheet (the LOG has them too, plus the
# text and seed fields: a sheet value is a number, and a 64-bit seed is not exact as one):
# field suffix, key of the statistics record and unit. Only the first `_RUN_ATTEMPTS_MAX`
# runs of the sampler get rows (the LOG has all of them).
const _RUN_ATTEMPT_FIELDS = (
    "Delta" => "delta", "NAdapt" => "nAdapt", "NDraws" => "nDraws", "Rhat" => "rhat",
    "Ess" => "ess", "Divergent" => "divergent", "Seconds" => "seconds",
)
const _RUN_ATTEMPT_UNITS = Dict(
    "Delta" => "%", "NAdapt" => "iterations", "NDraws" => "draws", "Rhat" => "",
    "Ess" => "draws", "Divergent" => "", "Seconds" => "s",
)
const _RUN_ATTEMPTS_MAX = 12

"""
The `(section, unit)` of a row of the run sheet: the entry of `_RUN_INFO`, or for
`attempt<k><Field>` the convergence section and the unit of the field.

# Returns
- A `Tuple{String,String}`, or `nothing` for a name that is no row.

# Exceptions
- None.
"""
function _runMeta(name::AbstractString)
    haskey(_RUN_INFO, name) && return _RUN_INFO[name]
    m = match(r"^attempt\d+([A-Za-z]+)$", name)
    m === nothing && return nothing
    unit = get(_RUN_ATTEMPT_UNITS, m.captures[1], nothing)
    return unit === nothing ? nothing : ("convergence", unit)
end

"""
The leapfrog step size each chain adapted to: the `step_size` of the chain's last draw (it
is fixed after the warm-up). `stats` and `chain` are the sampler statistics of the draws
and the chain of each.

# Returns
- A `Vector{Float64}`, one value for each chain.

# Exceptions
- None.
"""
function _chainStepSizes(stats, chain::AbstractVector)
    return Float64[stats[findlast(==(c), chain)].step_size for c in unique(chain)]
end

"""
The `run` sheet: one row for each setting and statistic of the run, with the columns
`section | name | value | unit`. The `section` is `model`, `data`, `sampler`, `convergence`
or `output`, the rows are grouped by it, `value` is always a number (a flag is 0 or 1,
`c1Kink` is 1 when c1 had a kink and was sampled instead of profiled; `exclVolSat` is 0, +1
when `c1` sat on its upper bound and -1 on its lower one), and `unit` is empty for a pure
number (no explanatory text is written to the workbook). `mapParams` is `nothing` when
every draw diverged (the rows that depend on the MAP are then left out). A row whose source
the run did not record is left out. The rows are those of `_RUN_INFO`. The data and
structure choices (`qMin`, `qMax`, `sigmaScale`, the points left out, `structureModel`,
`addHydrogens`, `lmaxPinned`) are rows only when they differ from the defaults.
"""
function _runSheet(fit, divergenceRate::Real, mapParams, info::AbstractDict)
    keys_, vals = _runRows(fit, divergenceRate, mapParams, info)
    # grouped by section, in the order of the rows within it
    order = sortperm(
        keys_; by = k -> findfirst(==(_runMeta(k)[1]), _RUN_SECTIONS), alg = MergeSort)
    meta = [_runMeta(keys_[i]) for i in order]
    return _sheet("run", ["section", "name", "value", "unit"],
        first.(meta), keys_[order], vals[order],
        [isempty(m[2]) ? missing : m[2] for m in meta])
end

"""
The `(names, values)` of the rows of the run (see `_runSheet`), in the order they are
found.
"""
function _runRows(fit, divergenceRate::Real, mapParams, info::AbstractDict)
    keys_ = String[]
    vals = Any[]
    add!(k, v) = (push!(keys_, k); push!(vals, v))
    for (k, source) in (
        ("nAtoms", "nAtoms"), ("lmax", "lMax"), ("nQRaw", "nQRaw"),
        ("nQChi2", "nQChi2"), ("nQ", "nQ"), ("nSamples", "nSamples"),
        ("nAdapt", "nAdapt"),
        ("rngSeed", "rngSeed"), ("quantileLoPct", "quantileLoPct"),
        ("quantileHiPct", "quantileHiPct"),
        ("pmvFallbackUncert", "pmvFallbackUncert"), ("qMin", "qMin"),
        ("qMax", "qMax"), ("sigmaScale", "sigmaScale"), ("nQInput", "nQInput"),
        ("nQCropped", "nQCropped"), ("nQExcluded", "nQExcluded"),
        ("structureModel", "structureModel"), ("addHydrogens", "addHydrogens"),
        ("lmaxPinned", "lmaxPinned"), ("c1Kink", "c1Kink"),
        ("memoryHeadroom", "memoryHeadroom"), ("forwardBlocks", "forwardBlocks"),
        ("forwardBlockQ", "forwardBlockQ"), ("forwardBudgetGib", "forwardBudgetGib"),
        ("forwardEstGib", "forwardEstGib"), ("forwardPeakGib", "forwardPeakGib"),
    )
        # (a flag is a number in the sheet)
        haskey(info, source) &&
            add!(k, info[source] isa Bool ? Int(info[source]) : info[source])
    end
    if haskey(info, "D")
        add!("dmax", info["D"])
        add!("channels", info["nChannels"])
        add!("rebinChannels", info["rebin"])
        add!("rebinMeasured", info["nQRaw"])
        add!("rebinFitted", info["nQ"])
        add!("rebinNonPositiveDropped", info["nNonpositive"])
    end

    stats = fit.stats
    H = getproperty.(stats, :hamiltonian_energy)
    depth = getproperty.(stats, :tree_depth)

    # E-BFMI: Stan's energy-based Bayesian Fraction of Missing Information, which
    # diagnoses whether momentum resampling explores the Hamiltonian's energy level sets
    # adequately; below ~0.2-0.3 is the usual "may be problematic" threshold. It is
    # taken per chain (the chains' energies are not one sequence) and the worst chain is
    # reported.
    ebfmi = minimum(
        (h = H[fit.chain .== c]; mean(diff(h) .^ 2) / var(h)) for c in unique(fit.chain)
    )
    add!("iterations", length(stats))
    add!("drawsRows", length(fit.samples))
    add!("meanAccept", mean(getproperty.(stats, :acceptance_rate)))
    add!("treeDepthAvg", mean(depth))
    add!("treeDepthMax", maximum(depth))
    add!("meanNSteps", mean(getproperty.(stats, :n_steps)))
    # the step size each chain adapted to (fixed after the warm-up): the median and the
    # smallest, which tell a collapsed step (about 0.002) from a healthy one (0.1 to 0.3)
    steps = _chainStepSizes(stats, fit.chain)
    add!("stepSize", median(steps))
    add!("stepSizeMin", minimum(steps))
    add!("ebfmi", ebfmi)
    if mapParams !== nothing && haskey(mapParams, "cavityShellFrac")
        add!("cavityFrac", mapParams["cavityShellFrac"])
    end

    # for a profiled c1 (the default; `c1Kink` = 1 when its profile had
    # a kink and c1 was sampled instead, where it cannot leave its
    # bounds) this says whether the MAP draw's c1 hit the physical bound
    # of Inference's EXCL_VOL_CORR_BOUNDS (Inference.exclVolSaturation)
    add!("exclVolSat",
        mapParams === nothing ? 0 : Int(sign(get(mapParams, "exclVolSat", 0.0))))
    add!("divergenceRate", divergenceRate)

    d = fit.diagnostics
    add!("chainsPooled", count(d.pooled))
    add!("chainsRun", d.nChains)
    rhat = filter(!isnan, d.rhat)
    if !isempty(rhat)
        add!("rhatMax", maximum(rhat))
        add!("essMin", minimum(filter(!isnan, d.ess)))
        add!("essTailMin", minimum(filter(!isnan, d.essTail)))
    end
    length(d.modeWeight) > 1 && add!("modes", length(d.modeWeight))
    (length(d.optima) > 1 || d.nExtra > 0) && add!("optima", length(d.optima))
    d.rewhitened > 0 && add!("rewhitenedNats", d.rewhitened)
    if !isnan(d.firstRhat)
        add!("retryFirstRhat", d.firstRhat)
        add!("retryKept", d.retryKept ? 1 : 0)
    end
    _attemptRows!(add!, info; fields = _RUN_ATTEMPT_FIELDS, maxAttempts = _RUN_ATTEMPTS_MAX)
    return keys_, vals
end

"""
The `modes` sheet, one row for each posterior mode the chains settled in (`nothing` when
there is only one): its `share` of the posterior mass by bridge sampling, the `logMass`
and its `logMassErr` (nats), the number of `chains` in it and `kept` (0 for a mode whose
share is below `Inference.MODE_NEGLIGIBLE`, which keeps no draws).
"""
function _modesSheet(d::Inference.ChainDiagnostics)
    n = length(d.modeWeight)
    n > 1 || return nothing
    return _sheet("modes", ["mode", "share", "logMass", "logMassErr", "chains", "kept"],
        collect(1:n), d.modeWeight, d.modeLogmass, d.modeErr,
        [count(==(m), d.mode) for m in 1:n],
        Int.(d.modeWeight .≥ Inference.MODE_NEGLIGIBLE))
end

"""
The `optima` sheet, one row for each optimum that carries posterior mass (`nothing` unless
there is more than one or chains were added at one): its `share` of the Laplace mass, the
number of `chains` that ended there and how many of them `started` there.
"""
function _optimaSheet(d::Inference.ChainDiagnostics)
    (length(d.optima) > 1 || d.nExtra > 0) || return nothing
    return _sheet("optima", ["optimum", "share", "chains", "started"],
        collect(1:length(d.optima)), [o.share for o in d.optima],
        [o.chains for o in d.optima], [o.started for o in d.optima])
end

"""
The `map`, `quantiles_<interval>` and `stdevFromPrior` sheets (`[]` when every draw
diverged and there is no MAP):

- `map`: `parameter | value`, the MAP value of every reported quantity;
- `quantiles_<interval>`: `parameter | quantileLo | quantileHi | boundLo | boundHi`, the
    empirical quantile pair of each quantity and the extreme draws inside it;
- `stdevFromPrior`: `parameter | zMap | zQuantileLo | zQuantileHi`, for the four
    parameters with a prior, how many prior standard deviations (θ-space) the MAP value and
    the quantile pair lie from the prior mean.
"""
function _resultSheets(result, quantileLabel::AbstractString)
    _, _, mapResult, quantileResult = result
    (mapResult === nothing || quantileResult === nothing) && return Any[]
    mapParams, qparams = mapResult[1], quantileResult[1]
    keys_ = [k for k in _REPORT_KEYS if haskey(mapParams, k) && haskey(qparams, k)]
    col(f) = Any[f(k) for k in keys_]
    label(k) = _REPORT_LABELS[k]
    sheets = Any[
        _sheet("map", ["parameter", "value"], col(label), col(k -> mapParams[k])),
        _sheet("quantiles" * uppercasefirst(quantileLabel),
            ["parameter", "quantileLo", "quantileHi", "boundLo", "boundHi"],
            col(label),
            col(k -> qparams[k]["quantiles"][1]), col(k -> qparams[k]["quantiles"][2]),
            col(k -> qparams[k]["bounds"][1]), col(k -> qparams[k]["bounds"][2])),
    ]
    zkeys = [k for k in _PRIOR_KEYS if haskey(mapParams, "z" * uppercasefirst(k))]
    isempty(zkeys) || push!(sheets,
        _sheet("stdevFromPrior",
            ["parameter", "zMap", "zQuantileLo", "zQuantileHi"],
            Any[label(k) for k in zkeys],
            Any[mapParams["z"*uppercasefirst(k)] for k in zkeys],
            Any[qparams[k]["z"][1] for k in zkeys],
            Any[qparams[k]["z"][2] for k in zkeys]))
    return sheets
end

"""
The summary sheets of a run, in workbook order: `run`, `map`, `quantiles_<interval>`,
`stdevFromPrior`, then `modes` and `optima` when the run has them and
`formFactorLog` (one line of text to a row) when there is a log. The quantiles sheet
is named after the interval [`runModel`](@ref) logged (`2sigma`, else the default's);
`nAtoms`, if given, overrides the logged atom count.
"""
function _summarySheets(
    result;
    formFactorLog::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    nAtoms::Union{Nothing,Integer} = nothing,
)
    fit, divergenceRate, mapResult, _ = result
    info = fit.timing === nothing ? Dict{String,Any}() : copy(fit.timing.info)
    nAtoms === nothing || (info["nAtoms"] = nAtoms)
    mapParams = mapResult === nothing ? nothing : first(mapResult)
    sheets = Any[_runSheet(fit, divergenceRate, mapParams, info)]
    label = something(get(info, "quantileLabel", nothing), _sigmaLabel(VAL_SIGMA))
    append!(sheets, _resultSheets(result, label))
    for sh in (_modesSheet(fit.diagnostics), _optimaSheet(fit.diagnostics))
        sh === nothing || push!(sheets, sh)
    end
    if formFactorLog !== nothing && !isempty(formFactorLog)
        push!(
            sheets,
            _sheet("formFactorLog", ["line"], Any[String(l) for l in formFactorLog]),
        )
    end
    return sheets
end

# ---------------------------------------------------------------------------
#                    The summary printed in the terminal
# ---------------------------------------------------------------------------

"The names of the four sampled parameters in the terminal summary."
const _SUMMARY_LABELS = Dict(
    "slvntEDns" => "ρₑ", "deltaRho1" => "δρ₁", "deltaRho2" => "δρ₂",
    "deltaRho3" => "δρ₃",
)

"Share of divergent transitions above which the summary warns."
const _SUMMARY_MAX_DIVERGENT = 0.01

"`x` to four significant figures with a true minus sign."
_signed(x::Real) = replace(@sprintf("%.4g", x), "-" => "−")

"`(lo–hi)`, with spaces round the dash when a number is negative."
function _interval(lo::Real, hi::Real)
    return lo < 0 || hi < 0 ? "($(_signed(lo)) – $(_signed(hi)))" :
           "($(_signed(lo))–$(_signed(hi)))"
end

"A path as the user would type it: relative to the working directory when that is shorter."
function _shown(path::AbstractString)
    rel = relpath(path)
    return length(rel) < length(path) ? rel : String(path)
end

"""
The lines of the terminal summary of a [`runModel`](@ref) result (see
[`printSummary`](@ref)): the verdict (reduced χ², the four sampled parameters with their
quantile pair, one per row), the checks in words with a note for each that failed, where
the results and figures went (what [`results`](@ref) recorded in the run's timing log),
and the wall clock as the last line.
"""
function _summaryLines(result)
    fit, divergenceRate, mapResult, quantileResult = result
    log = fit.timing
    info = log === nothing ? Dict{String,Any}() : log.info
    lines = String[]
    notes = String[]
    if mapResult === nothing || quantileResult === nothing
        push!(
            lines,
            "Fit finished: every draw diverged, so there is no MAP and no quantiles",
        )
    else
        mp, qp = mapResult[1], quantileResult[1]
        push!(lines,
            @sprintf("Fit finished: reduced χ² = %.2f on the measured points",
                mp["chisqRed"]))
        # one parameter per row, so a line never outgrows an 80-column terminal
        for k in _PRIOR_KEYS
            push!(lines,
                "  $(rpad(_SUMMARY_LABELS[k], 3))  $(_signed(mp[k]))  " *
                _interval(qp[k]["quantiles"]...))
        end
        get(mp, "exclVolSat", 0.0) == 0.0 || push!(notes,
            "c1 (excluded volume) sits on its bound")
    end

    d = fit.diagnostics
    checks = String[]
    problems = Inference._convergenceProblems(d)
    if isempty(problems)
        push!(checks, @sprintf("converged (R̂ %.3f)", Inference._worstRhat(d)))
    else
        push!(checks, "NOT converged:")
        append!(checks, "  " .* problems)
        push!(notes, "chains not converged: run longer first")
    end
    push!(checks,
        divergenceRate == 0 ? "no divergent transitions" :
        @sprintf("%.1f %% divergent transitions", 100 * divergenceRate))
    divergenceRate > _SUMMARY_MAX_DIVERGENT && push!(notes,
        "over 1 % of transitions diverged: take care")
    push!(checks, "$(count(d.pooled)) of $(d.nChains) chains used")
    length(d.modeWeight) > 1 && push!(notes,
        "$(length(d.modeWeight)) posterior modes (see the modes sheet)")
    # the first check follows `Checks:`, the others line up under it
    push!(lines, "  Checks:  " * first(checks))
    for c in checks[2:end]
        push!(lines, "           " * c)
    end
    for n in notes
        push!(lines, "  Note: " * n)
    end

    for (key, label, tail) in
        (("workbook", "Results", ""), ("plots", "Figures", "/"), ("log", "Log", ""))
        haskey(info, key) &&
            push!(lines, "  $(rpad(label * ":", 8)) $(_shown(info[key]))$tail")
    end
    log === nothing ||
        push!(lines, @sprintf("Wall clock: %.1f s", (time_ns() - log.t0) / NS_PER_S))
    return lines
end

"""
Prints the summary of a [`runModel`](@ref) result to `io` (stdout by default), the last
thing a run says:

```
Fit finished: reduced χ² = 0.87 on the measured points
  ρₑ   0.3362  (0.3361–0.3362)
  δρ₁  −1.06  (−1.15 – −1.03)
  δρ₂  …
  δρ₃  …
  Checks:  converged (R̂ 1.002)
           no divergent transitions
           8 of 8 chains used
  Results: out/res.xlsx
  Figures: out/plots/
  Log:     out/out.LOG
Wall clock: 141.3 s
```

The χ² is the reduced χ² of the MAP on the measured points. Each of `ρₑ`, `δρ₁`,
`δρ₂` and `δρ₃` is shown as its MAP value with the quantile pair of the run (the
`sigma` of [`runModel`](@ref)) in brackets. Every line is short (a parameter, a check
or a file per row) so it fits an 80-column terminal. A check that fails adds a `Note:`
line in words (chains not converged, over 1 % divergent transitions, `c1` on its bound,
several posterior modes). The paths are the ones [`results`](@ref) wrote, so call this
last; the line for a file that was not written is left out.

# Returns
- `nothing`.
"""
function printSummary(io::IO, result)
    foreach(l -> println(io, l), _summaryLines(result))
    return nothing
end

printSummary(result) = printSummary(stdout, result)
