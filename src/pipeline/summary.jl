# SPDX-License-Identifier: LGPL-3.0-or-later

# ---------------------------------------------------------------------------
#          The summary sheets of the workbook (written by `results`)
# ---------------------------------------------------------------------------

# section, unit and meaning of each row of the `run` sheet
const _RUN_SECTIONS = ["model", "data", "sampler", "convergence", "output"]
const _RUN_INFO = Dict(
    "nAtoms" => ("model", "atoms",
        "Atoms of the structure in the model, hydrogens included."),
    "lmax" => ("model", "",
        "Highest spherical-harmonic degree of the forward model."),
    "dmax" => ("model", "Å",
        "Diameter of the scatterer cloud (atoms and hydration beads), which " *
        "sets the Shannon channel width π/dmax."),
    "pmvFallbackUncert" => ("model", "cm³/mol",
        "Uncertainty given to a non-biological buffer solute whose row of the " *
        "partial-molar-volume table states none (the table's mean by default; " *
        "not recommended to change)."),
    "lmaxPinned" => ("model", "",
        "1 if the band limit lmax was pinned by the user instead of chosen from the " *
        "q range (present only then)."),
    "addHydrogens" => ("model", "",
        "0 if the hydrogens were not added by the pipeline (present only then)."),
    "structureModel" => ("model", "",
        "Which model of a multi-model structure was used (present when not the " *
        "first)."),
    "qMin" => ("data", "Å⁻¹",
        "Lowest q of the fitted range (present only when set)."),
    "qMax" => ("data", "Å⁻¹",
        "Highest q of the fitted range (present only when set)."),
    "sigmaScale" => ("data", "",
        "Factor the measured errors were multiplied by (present when not 1)."),
    "nQInput" => ("data", "points",
        "Measured points given, before qMin, qMax and the excluded ranges " *
        "(present only when some were left out)."),
    "nQCropped" => ("data", "points",
        "Points left out for lying outside qMin to qMax."),
    "nQExcluded" => ("data", "points",
        "Points left out for lying in an excluded range of q."),
    "cavityFrac" => ("model", "",
        "Share of the hydration shell classified as cavity at the MAP, 0 to " *
        "1."),
    "exclVolSat" => ("model", "",
        "Where the profiled excluded-volume correction c1 sits at the MAP: 0 " *
        "inside its bounds, 1 on the upper bound, -1 on the lower. A bound is " *
        "a warning."),
    "nQRaw" => ("data", "points",
        "Measured points before binning, after qMin, qMax and the excluded ranges.",
    ),
    "nQ" => ("data", "points",
        "Points fitted, after Shannon binning and dropping non-positive bins."),
    "channels" => ("data", "",
        "Shannon channels in the measured q range, qMax·dmax/π."),
    "rebinChannels" => ("data", "bins",
        "Bins per Shannon channel."),
    "rebinMeasured" => ("data", "points",
        "Measured points that went into the binning."),
    "rebinFitted" => ("data", "points",
        "Binned points that were fitted."),
    "rebinNonPositiveDropped" => ("data", "bins",
        "Bins dropped because their intensity was not positive."),
    "nSamples" => ("sampler", "iterations",
        "NUTS iterations of each chain, warm-up included."),
    "nAdapt" => ("sampler", "iterations",
        "Warm-up iterations of each chain."),
    "rngSeed" => ("sampler", "",
        "Random seed that reproduces the run."),
    "iterations" => ("sampler", "draws",
        "Posterior draws pooled from the chains that were used."),
    "meanAccept" => ("sampler", "",
        "Mean NUTS acceptance rate, which the step size is tuned to match its " *
        "target."),
    "treeDepthAvg" => ("sampler", "",
        "Mean depth of the NUTS trees."),
    "treeDepthMax" => ("sampler", "",
        "Deepest NUTS tree. A depth at the limit means a poorly scaled " *
        "posterior."),
    "meanNSteps" => ("sampler", "steps",
        "Mean leapfrog steps per iteration."),
    "ebfmi" => ("sampler", "",
        "Energy fraction of missing information of the worst chain. Below " *
        "about 0.3 the momentum resampling explores poorly."),
    "divergenceRate" => ("sampler", "",
        "Share of draws with a numerical divergence, 0 to 1. Above 0.01 treat " *
        "the quantiles with care."),
    "chainsPooled" => ("convergence", "chains",
        "Chains whose draws were pooled."),
    "chainsRun" => ("convergence", "chains",
        "Chains that were run."),
    "rhatMax" => ("convergence", "",
        "Worst split R-hat within a mode. Above 1.01 the chains have not " *
        "converged."),
    "essMin" => ("convergence", "draws",
        "Smallest bulk effective sample size over the parameters."),
    "essTailMin" => ("convergence", "draws",
        "Smallest tail effective sample size over the parameters."),
    "modes" => ("convergence", "",
        "Posterior modes the chains settled in (present only when more than " *
        "one)."),
    "optima" => ("convergence", "",
        "Local optima that carry posterior mass (present only when more than " *
        "one)."),
    "rewhitenedNats" => ("convergence", "nats",
        "By how much the first chains found a better basin than the MAP " *
        "search, after which the sampler was re-whitened there and the chains " *
        "rerun."),
    "retryFirstRhat" => ("convergence", "",
        "Worst R-hat of the first run, when the run was repeated because it " *
        "was above its limit."),
    "retryKept" => ("convergence", "",
        "1 if the draws of the repeated run were kept, 0 if the first run's."),
    "drawsRows" => ("output", "rows",
        "Rows of the draws sheet, one per posterior draw (chain, draw within the " *
        "chain, the parameters, the derived quantities and the sampler's flags of " *
        "the draw; units are in the column headers; `chi2FitGrid` is the reduced " *
        "chi2 on the fitted grid, the map sheet's chi2 is on the measured points).",
    ),
    "quantileLoPct" => ("output", "%",
        "Lower percentile of the interval in the quantiles sheet."),
    "quantileHiPct" => ("output", "%",
        "Upper percentile of the interval in the quantiles sheet."),
)

"""
The `run` sheet: one row for each setting and statistic of the run, with the columns
`section | name | value | unit | meaning`. The `section` is `model`, `data`, `sampler`,
`convergence` or `output`, the rows are grouped by it, `value` is always a number (a flag is
0 or 1; `exclVolSat` is 0, +1 when `c1` sat on its upper bound and -1 on its lower one),
`unit` is empty for a pure number, and `meaning` says in words what the row is and, for a
check, what a worrying value is. `mapParams` is `nothing` when every draw diverged (the
rows that depend on the MAP are then left out). A row whose source the run did not record
is left out. The rows are those of `_RUN_INFO`. The data and structure choices (`qMin`,
`qMax`, `sigmaScale`, the points left out, `structureModel`, `addHydrogens`,
`lmaxPinned`) are rows only when they differ from the defaults.
"""
function _runSheet(fit, divergenceRate::Real, mapParams, info::AbstractDict)
    keys_, vals = _runRows(fit, divergenceRate, mapParams, info)
    # grouped by section, in the order of the rows within it
    order = sortperm(
        keys_; by = k -> findfirst(==(_RUN_INFO[k][1]), _RUN_SECTIONS), alg = MergeSort)
    meta = [_RUN_INFO[keys_[i]] for i in order]
    return _sheet("run", ["section", "name", "value", "unit", "meaning"],
        first.(meta), keys_[order], vals[order],
        [isempty(m[2]) ? missing : m[2] for m in meta], last.(meta))
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
        ("nQ", "nQ"), ("nSamples", "nSamples"), ("nAdapt", "nAdapt"),
        ("rngSeed", "rngSeed"), ("quantileLoPct", "quantileLoPct"),
        ("quantileHiPct", "quantileHiPct"),
        ("pmvFallbackUncert", "pmvFallbackUncert"), ("qMin", "qMin"),
        ("qMax", "qMax"), ("sigmaScale", "sigmaScale"), ("nQInput", "nQInput"),
        ("nQCropped", "nQCropped"), ("nQExcluded", "nQExcluded"),
        ("structureModel", "structureModel"), ("addHydrogens", "addHydrogens"),
        ("lmaxPinned", "lmaxPinned"),
    )
        haskey(info, source) && add!(k, info[source])
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
    add!("ebfmi", ebfmi)
    if mapParams !== nothing && haskey(mapParams, "cavityShellFrac")
        add!("cavityFrac", mapParams["cavityShellFrac"])
    end

    # c1 is profiled, not sampled, so this says whether the MAP draw's profiled c1 hit
    # the physical bound of Inference's EXCL_VOL_CORR_BOUNDS (Inference.exclVolSaturation)
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
