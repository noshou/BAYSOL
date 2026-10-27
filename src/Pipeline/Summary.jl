# SPDX-License-Identifier: LGPL-3.0-or-later

# ---------------------------------------------------------------------------
#          The summary sheets of the workbook (written by `results`)
# ---------------------------------------------------------------------------

# section, unit and meaning of each row of the `run` sheet
const _RUN_SECTIONS = ["model", "data", "sampler", "convergence", "output"]
const _RUN_INFO = Dict(
    "n_atoms" => ("model", "atoms",
        "Atoms of the structure in the model, hydrogens included."),
    "lmax" => ("model", "",
        "Highest spherical-harmonic degree of the forward model."),
    "dmax" => ("model", "Å",
        "Diameter of the scatterer cloud (atoms and hydration beads), which " *
        "sets the Shannon channel width π/dmax."),
    "cavity_frac" => ("model", "",
        "Share of the hydration shell classified as cavity at the MAP, 0 to " *
        "1."),
    "excl_vol_sat" => ("model", "",
        "Where the profiled excluded-volume correction c1 sits at the MAP: 0 " *
        "inside its bounds, 1 on the upper bound, -1 on the lower. A bound is " *
        "a warning."),
    "n_q_raw" => ("data", "points",
        "Measured points before binning."),
    "n_q" => ("data", "points",
        "Points fitted, after Shannon binning and dropping non-positive bins."),
    "channels" => ("data", "",
        "Shannon channels in the measured q range, q_max·dmax/π."),
    "rebin_channels" => ("data", "bins",
        "Bins per Shannon channel."),
    "rebin_measured" => ("data", "points",
        "Measured points that went into the binning."),
    "rebin_fitted" => ("data", "points",
        "Binned points that were fitted."),
    "rebin_non_positive_dropped" => ("data", "bins",
        "Bins dropped because their intensity was not positive."),
    "n_samples" => ("sampler", "iterations",
        "NUTS iterations of each chain, warm-up included."),
    "n_adapt" => ("sampler", "iterations",
        "Warm-up iterations of each chain."),
    "rng_seed" => ("sampler", "",
        "Random seed that reproduces the run."),
    "iterations" => ("sampler", "draws",
        "Posterior draws pooled from the chains that were used."),
    "mean_accept" => ("sampler", "",
        "Mean NUTS acceptance rate, which the step size is tuned to match its " *
        "target."),
    "tree_depth_avg" => ("sampler", "",
        "Mean depth of the NUTS trees."),
    "tree_depth_max" => ("sampler", "",
        "Deepest NUTS tree. A depth at the limit means a poorly scaled " *
        "posterior."),
    "mean_n_steps" => ("sampler", "steps",
        "Mean leapfrog steps per iteration."),
    "ebfmi" => ("sampler", "",
        "Energy fraction of missing information of the worst chain. Below " *
        "about 0.3 the momentum resampling explores poorly."),
    "divergence_rate" => ("sampler", "",
        "Share of draws with a numerical divergence, 0 to 1. Above 0.01 treat " *
        "the quantiles with care."),
    "chains_pooled" => ("convergence", "chains",
        "Chains whose draws were pooled."),
    "chains_run" => ("convergence", "chains",
        "Chains that were run."),
    "rhat_max" => ("convergence", "",
        "Worst split R-hat within a mode. Above 1.01 the chains have not " *
        "converged."),
    "ess_min" => ("convergence", "draws",
        "Smallest bulk effective sample size over the parameters."),
    "ess_tail_min" => ("convergence", "draws",
        "Smallest tail effective sample size over the parameters."),
    "modes" => ("convergence", "",
        "Posterior modes the chains settled in (present only when more than " *
        "one)."),
    "optima" => ("convergence", "",
        "Local optima that carry posterior mass (present only when more than " *
        "one)."),
    "rewhitened_nats" => ("convergence", "nats",
        "By how much the first chains found a better basin than the MAP " *
        "search, after which the sampler was re-whitened there and the chains " *
        "rerun."),
    "retry_first_rhat" => ("convergence", "",
        "Worst R-hat of the first run, when the run was repeated because it " *
        "was above its limit."),
    "retry_kept" => ("convergence", "",
        "1 if the draws of the repeated run were kept, 0 if the first run's."),
    "quantile_lo_pct" => ("output", "%",
        "Lower percentile of the interval in the quantiles sheet."),
    "quantile_hi_pct" => ("output", "%",
        "Upper percentile of the interval in the quantiles sheet."),
)

"""
The `run` sheet: one row for each setting and statistic of the run, with the columns
`section | name | value | unit | meaning`. The `section` is `model`, `data`, `sampler`,
`convergence` or `output`, the rows are grouped by it, `value` is always a number (a flag is
0 or 1; `excl_vol_sat` is 0, +1 when `c1` sat on its upper bound and -1 on its lower one),
`unit` is empty for a pure number, and `meaning` says in words what the row is and, for a
check, what a worrying value is. `map_params` is `nothing` when every draw diverged (the
rows that depend on the MAP are then left out). A row whose source the run did not record
is left out. The rows are those of `_RUN_INFO`.
"""
function _run_sheet(fit, divergence_rate::Real, map_params, info::AbstractDict)
    keys_, vals = _run_rows(fit, divergence_rate, map_params, info)
    # grouped by section, in the order of the rows within it
    order = sortperm(
        keys_; by = k -> findfirst(==(_RUN_INFO[k][1]), _RUN_SECTIONS), alg = MergeSort)
    meta = [_RUN_INFO[keys_[i]] for i in order]
    return _sheet("run", ["section", "name", "value", "unit", "meaning"],
        first.(meta), keys_[order], vals[order],
        [isempty(m[2]) ? missing : m[2] for m in meta], last.(meta))
end

"""
The `(names, values)` of the rows of the run (see `_run_sheet`), in the order they are
found.
"""
function _run_rows(fit, divergence_rate::Real, map_params, info::AbstractDict)
    keys_ = String[]
    vals = Any[]
    add!(k, v) = (push!(keys_, k); push!(vals, v))
    for (k, source) in (
        ("n_atoms", "n_atoms"), ("lmax", "lMax"), ("n_q_raw", "n_q_raw"),
        ("n_q", "n_q"), ("n_samples", "n_samples"), ("n_adapt", "n_adapt"),
        ("rng_seed", "rng_seed"), ("quantile_lo_pct", "quantile_lo_pct"),
        ("quantile_hi_pct", "quantile_hi_pct"),
    )
        haskey(info, source) && add!(k, info[source])
    end
    if haskey(info, "D")
        add!("dmax", info["D"])
        add!("channels", info["n_channels"])
        add!("rebin_channels", info["rebin"])
        add!("rebin_measured", info["n_q_raw"])
        add!("rebin_fitted", info["n_q"])
        add!("rebin_non_positive_dropped", info["n_nonpositive"])
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
    add!("mean_accept", mean(getproperty.(stats, :acceptance_rate)))
    add!("tree_depth_avg", mean(depth))
    add!("tree_depth_max", maximum(depth))
    add!("mean_n_steps", mean(getproperty.(stats, :n_steps)))
    add!("ebfmi", ebfmi)
    if map_params !== nothing && haskey(map_params, "cavity_shell_frac")
        add!("cavity_frac", map_params["cavity_shell_frac"])
    end

    # c1 is profiled, not sampled, so this says whether the MAP draw's profiled c1 hit
    # the physical bound of Inference's EXCL_VOL_CORR_BOUNDS (Inference.excl_vol_saturation)
    add!("excl_vol_sat",
        map_params === nothing ? 0 : Int(sign(get(map_params, "excl_vol_sat", 0.0))))
    add!("divergence_rate", divergence_rate)

    d = fit.diagnostics
    add!("chains_pooled", count(d.pooled))
    add!("chains_run", d.n_chains)
    rhat = filter(!isnan, d.rhat)
    if !isempty(rhat)
        add!("rhat_max", maximum(rhat))
        add!("ess_min", minimum(filter(!isnan, d.ess)))
        add!("ess_tail_min", minimum(filter(!isnan, d.ess_tail)))
    end
    length(d.mode_weight) > 1 && add!("modes", length(d.mode_weight))
    (length(d.optima) > 1 || d.n_extra > 0) && add!("optima", length(d.optima))
    d.rewhitened > 0 && add!("rewhitened_nats", d.rewhitened)
    if !isnan(d.first_rhat)
        add!("retry_first_rhat", d.first_rhat)
        add!("retry_kept", d.retry_kept ? 1 : 0)
    end
    return keys_, vals
end

"""
The `modes` sheet, one row for each posterior mode the chains settled in (`nothing` when
there is only one): its `share` of the posterior mass by bridge sampling, the `log_mass`
and its `log_mass_err` (nats), the number of `chains` in it and `kept` (0 for a mode whose
share is below `Inference.MODE_NEGLIGIBLE`, which keeps no draws).
"""
function _modes_sheet(d::Inference.ChainDiagnostics)
    n = length(d.mode_weight)
    n > 1 || return nothing
    return _sheet("modes", ["mode", "share", "log_mass", "log_mass_err", "chains", "kept"],
        collect(1:n), d.mode_weight, d.mode_logmass, d.mode_err,
        [count(==(m), d.mode) for m in 1:n],
        Int.(d.mode_weight .≥ Inference.MODE_NEGLIGIBLE))
end

"""
The `optima` sheet, one row for each optimum that carries posterior mass (`nothing` unless
there is more than one or chains were added at one): its `share` of the Laplace mass, the
number of `chains` that ended there and how many of them `started` there.
"""
function _optima_sheet(d::Inference.ChainDiagnostics)
    (length(d.optima) > 1 || d.n_extra > 0) || return nothing
    return _sheet("optima", ["optimum", "share", "chains", "started"],
        collect(1:length(d.optima)), [o.share for o in d.optima],
        [o.chains for o in d.optima], [o.started for o in d.optima])
end

"""
The `map`, `quantiles_<interval>` and `stdev_from_prior` sheets (`[]` when every draw
diverged and there is no MAP):

- `map`: `parameter | value`, the MAP value of every reported quantity;
- `quantiles_<interval>`: `parameter | quantile_lo | quantile_hi | bound_lo | bound_hi`, the
    empirical quantile pair of each quantity and the extreme draws inside it;
- `stdev_from_prior`: `parameter | z_map | z_quantile_lo | z_quantile_hi`, for the four
    parameters with a prior, how many prior standard deviations (θ-space) the MAP value and
    the quantile pair lie from the prior mean.
"""
function _result_sheets(result, quantile_label::AbstractString)
    _, _, map_result, quantile_result = result
    (map_result === nothing || quantile_result === nothing) && return Any[]
    map_params, qparams = map_result[1], quantile_result[1]
    keys_ = [k for k in _REPORT_KEYS if haskey(map_params, k) && haskey(qparams, k)]
    col(f) = Any[f(k) for k in keys_]
    label(k) = _REPORT_LABELS[k]
    sheets = Any[
        _sheet("map", ["parameter", "value"], col(label), col(k -> map_params[k])),
        _sheet("quantiles_" * quantile_label,
            ["parameter", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"],
            col(label),
            col(k -> qparams[k]["quantiles"][1]), col(k -> qparams[k]["quantiles"][2]),
            col(k -> qparams[k]["bounds"][1]), col(k -> qparams[k]["bounds"][2])),
    ]
    zkeys = [k for k in _PRIOR_KEYS if haskey(map_params, "z_" * k)]
    isempty(zkeys) || push!(sheets,
        _sheet("stdev_from_prior",
            ["parameter", "z_map", "z_quantile_lo", "z_quantile_hi"],
            Any[label(k) for k in zkeys], Any[map_params["z_"*k] for k in zkeys],
            Any[qparams[k]["z"][1] for k in zkeys],
            Any[qparams[k]["z"][2] for k in zkeys]))
    return sheets
end

"""
The summary sheets of a run, in workbook order: `run`, `map`, `quantiles_<interval>`,
`stdev_from_prior`, then `modes` and `optima` when the run has them and
`form_factor_log` (one line of text to a row) when there is a log. `quantile_label`
names the quantiles sheet (`nothing`: the label [`run_model`](@ref) logged, else the
default's); `n_atoms`, if given, overrides the logged atom
count.
"""
function _summary_sheets(
    result;
    quantile_label::Union{Nothing,AbstractString} = nothing,
    form_factor_log::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    n_atoms::Union{Nothing,Integer} = nothing,
)
    fit, divergence_rate, map_result, _ = result
    info = fit.timing === nothing ? Dict{String,Any}() : copy(fit.timing.info)
    n_atoms === nothing || (info["n_atoms"] = n_atoms)
    map_params = map_result === nothing ? nothing : first(map_result)
    sheets = Any[_run_sheet(fit, divergence_rate, map_params, info)]
    label = something(
        quantile_label,
        get(info, "quantile_label", nothing),
        _sigma_label(DEFAULT_SIGMA),
    )
    append!(sheets, _result_sheets(result, label))
    for sh in (_modes_sheet(fit.diagnostics), _optima_sheet(fit.diagnostics))
        sh === nothing || push!(sheets, sh)
    end
    if form_factor_log !== nothing && !isempty(form_factor_log)
        push!(
            sheets,
            _sheet("form_factor_log", ["line"], Any[String(l) for l in form_factor_log]),
        )
    end
    return sheets
end

# ---------------------------------------------------------------------------
#                    The summary printed in the terminal
# ---------------------------------------------------------------------------

"The names of the four sampled parameters in the terminal summary."
const _SUMMARY_LABELS = Dict(
    "slvnt_e_dns" => "ρₑ", "delta_rho_1" => "δρ₁", "delta_rho_2" => "δρ₂",
    "delta_rho_3" => "δρ₃",
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
The lines of the terminal summary of a [`run_model`](@ref) result (see
[`print_summary`](@ref)): the verdict (reduced χ², the four sampled parameters with their
quantile pair), the checks in words with a note for each that failed, where the results,
figures went (what [`results`](@ref) recorded
in the run's timing log), and the wall clock as the last line.
"""
function _summary_lines(result)
    fit, divergence_rate, map_result, quantile_result = result
    log = fit.timing
    info = log === nothing ? Dict{String,Any}() : log.info
    lines = String[]
    notes = String[]
    if map_result === nothing || quantile_result === nothing
        push!(
            lines,
            "Fit finished: every draw diverged, so there is no MAP and no quantiles",
        )
    else
        mp, qp = map_result[1], quantile_result[1]
        push!(lines,
            @sprintf("Fit finished: reduced χ² = %.2f on the measured points",
                mp["chisq_red"]))
        push!(lines,
            "  " * join(
                [
                    "$(_SUMMARY_LABELS[k]) = $(_signed(mp[k])) " *
                    _interval(qp[k]["quantiles"]...) for k in _PRIOR_KEYS
                ],
                "    "))
        get(mp, "excl_vol_sat", 0.0) == 0.0 || push!(notes,
            "the excluded-volume correction c1 sits on its bound")
    end

    d = fit.diagnostics
    checks = String[]
    rhat = filter(!isnan, d.rhat)
    if !isempty(rhat)
        r = maximum(rhat)
        if r > Inference.RHAT_OK
            push!(checks, @sprintf("NOT converged (R̂ %.3f > %g)", r, Inference.RHAT_OK))
            push!(
                notes,
                "the chains did not converge; run longer before trusting the quantiles",
            )
        else
            push!(checks, @sprintf("converged (R̂ %.3f)", r))
        end
    end
    push!(checks,
        divergence_rate == 0 ? "no divergent transitions" :
        @sprintf("%.1f %% divergent transitions", 100 * divergence_rate))
    divergence_rate > _SUMMARY_MAX_DIVERGENT && push!(notes,
        "more than 1 % of the transitions diverged; treat the quantiles with care")
    push!(checks, "$(count(d.pooled)) of $(d.n_chains) chains used")
    length(d.mode_weight) > 1 && push!(notes,
        "the posterior has $(length(d.mode_weight)) modes (see the modes sheet)")
    push!(lines, "  Checks: " * join(checks, ", "))
    for n in notes
        push!(lines, "  Note: " * n)
    end

    files = String[]
    for (key, label, tail) in
        (("workbook", "Results", ""), ("plots", "Figures", "/"), ("log", "Log", ""))
        haskey(info, key) && push!(files, "$label: $(_shown(info[key]))$tail")
    end
    isempty(files) || push!(lines, "  " * join(files, "    "))
    log === nothing ||
        push!(lines, @sprintf("Wall clock: %.1f s", (time_ns() - log.t0) / NS_PER_S))
    return lines
end

"""
Prints the summary of a [`run_model`](@ref) result to `io` (stdout by default), the last
thing a run says:

```
Fit finished: reduced χ² = 0.87 on the measured points
ρₑ = 0.3362 (0.3361–0.3362)    δρ₁ = −1.06 (−1.15 – −1.03)    δρ₂ = …    δρ₃ = …
Checks: converged (R̂ 1.002), no divergent transitions, 8 of 8 chains used
Results: out/res.xlsx    Figures: out/plots/    Log: out/out.LOG
Wall clock: 141.3 s
```

The χ² is the reduced χ² of the MAP on the measured points. Each of `ρₑ`, `δρ₁`,
`δρ₂` and `δρ₃` is shown as its MAP value with the quantile pair of the run (the
`sigma` or `quantiles` of [`run_model`](@ref)) in brackets. A check that fails adds a
`Note:` line in words (chains not converged, more than 1 % divergent transitions,
`c1` on its bound, several posterior modes). The paths are the ones [`results`](@ref)
wrote, so call this last; the line for a file that was not written is left out.

# Returns
- `nothing`.
"""
function print_summary(io::IO, result)
    foreach(l -> println(io, l), _summary_lines(result))
    return nothing
end

print_summary(result) = print_summary(stdout, result)
