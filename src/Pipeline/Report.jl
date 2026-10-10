# SPDX-License-Identifier: LGPL-2.1-or-later

# write_report: the text report of a run_model result, and its sections.

"""
The sampler diagnostics, written as the last lines of the report's `=== Run ===` section
(no header of their own): the sampler's iterations, mean acceptance, tree depth and steps,
E-BFMI, the cavity fraction of the hydration shell, whether the profiled c1 hit its bound,
and the share of divergent transitions. `map_params` is `nothing` when every draw diverged
(the MAP-based lines are then left out).
"""
function _write_diagnostics(io::IO, fit, divergence_rate::Real, map_params)
    stats  = fit.stats
    accept = getproperty.(stats, :acceptance_rate)
    depth  = getproperty.(stats, :tree_depth)
    nsteps = getproperty.(stats, :n_steps)
    H      = getproperty.(stats, :hamiltonian_energy)
    # E-BFMI: Stan's energy-based Bayesian Fraction of Missing Information,
    # diagnosing whether momentum resampling explores the Hamiltonian's
    # energy level sets adequately. Values below ~0.2-0.3 are the usual
    # "may be problematic, consider reparameterizing" threshold.
    # (per chain, since the chains' energies are not one sequence;
    # the worst chain is reported)
    ebfmi = minimum(
        (h = H[fit.chain .== c]; mean(diff(h) .^ 2) / var(h)) for c in unique(fit.chain)
    )
    @printf(io, "%-15s = %d\n", "iterations", length(stats))
    @printf(io, "%-15s = %.4f\n", "mean_accept", mean(accept))
    @printf(io, "%-15s = %.2f (max %d)\n", "tree_depth", mean(depth), maximum(depth))
    @printf(io, "%-15s = %.2f\n", "mean_n_steps", mean(nsteps))
    @printf(io, "%-15s = %.4f\n", "EBFMI", ebfmi)
    if map_params !== nothing && haskey(map_params, "cavity_shell_frac")
        @printf(io, "%-15s = %.4f\n", "cavity_frac", map_params["cavity_shell_frac"])
    end

    # c1 is profiled, not sampled with a prior, so this reports whether the
    # MAP draw's profiled c1 hit the physical bound in Inference's
    # EXCL_VOL_CORR_BOUNDS -- see Inference.excl_vol_saturation.
    excl_vol_sat = map_params === nothing ? 0.0 : get(map_params, "excl_vol_sat", 0.0)
    if excl_vol_sat == 0.0
        @printf(io, "%-15s = false\n", "excl_vol_sat")
    elseif excl_vol_sat > 0
        @printf(io, "%-15s = true, c1 -> +∞\n", "excl_vol_sat")
    else
        @printf(io, "%-15s = true, c1 -> -∞\n", "excl_vol_sat")
    end
    @printf(io, "%-15s = %.4f\n", "divergence_rate", divergence_rate)
    _write_chains(io, fit.diagnostics)
    println(io)
    return nothing
end

"""
The chain lines of the diagnostics: how many chains were pooled and why any was not,
the posterior modes the chains settled in with their mass shares (when there is more
than one; flagged when the shares are uncertain), and the worst rank-normalized split
R̂ and the smallest bulk and tail effective sample sizes over the four parameters and
the log density of the pooled draws, flagged when R̂ exceeds `Inference.RHAT_OK`.
"""
function _write_chains(io::IO, d::Inference.ChainDiagnostics)
    npool = count(d.pooled)
    @printf(io, "%-15s = %d pooled of %d\n", "chains", npool, d.n_chains)
    if length(d.mode_weight) > 1
        note =
            d.weights_uncertain ?
            "mass shares by bridge sampling are uncertain: the chains of the modes " *
            "that can matter are pooled as they came" :
            "mass shares by bridge sampling; the pooled draws carry them"
        @printf(io, "%-15s = %d (%s)\n", "modes", length(d.mode_weight), note)
        for m in eachindex(d.mode_weight)
            @printf(io, "%-15s = chains %s, share %.3f (log mass %+.2f ± %.2f)\n",
                "mode_$m",
                join(findall(==(m), d.mode), ","), d.mode_weight[m], d.mode_logmass[m],
                d.mode_err[m])
        end
    end
    for k in 1:d.n_chains
        d.pooled[k] || @printf(
            io,
            "%-15s = chain %d not pooled: %s\n",
            "chain_dropped",
            k,
            d.reason[k]
        )
    end
    d.rewhitened > 0 && @printf(
        io,
        "%-15s = %.1f nats (the chains found a better basin than the MAP search)\n",
        "rewhitened", d.rewhitened
    )
    rhat = filter(!isnan, d.rhat)
    if !isempty(rhat)
        flag =
            maximum(rhat) > Inference.RHAT_OK ?
            "  (> $(Inference.RHAT_OK): not converged)" : ""
        @printf(io, "%-15s = %.4f%s\n", "rhat_max", maximum(rhat), flag)
        @printf(io, "%-15s = %.0f\n", "ess_min", minimum(filter(!isnan, d.ess)))
        @printf(io, "%-15s = %.0f\n", "ess_tail_min", minimum(filter(!isnan, d.ess_tail)))
    end
    return nothing
end

"""
Writes a summary of a [`run_model`](@ref) result to io.

There is also a convenience overload `write_report(result; kwargs...)` that
defaults `io` to `stdout`; see its own one-line definition below.

# Arguments
- `io::IO`: where to write; omit for stdout.
- `result`: a [`run_model`](@ref) return value, (fit, divergencerate, map, curve).

# Keywords
-   `quantile_label::AbstractString=DEFAULT_QUANTILES`: the quantile range the report's
    `=== Quantiles ===` header names; pass the `quantiles` given to [`run_model`](@ref).
- `formfactorlog::Union{Nothing,AbstractVector{<:AbstractString}}=nothing`:
    the seed's `seed.fw.form_factor_log`.
- `n_atoms::Union{Nothing,Integer}=nothing`: the seed's `seed.fw.n_atoms`, printed
    as the `n_atoms` line of the `=== Run ===` section. Default nothing uses the
    count recorded in the run's timing log (none is printed if neither exists).

# Logged EBFMI vs. AdvancedHMC's logged EBFMIest

The "EBFMI" line in this report's "=== Run ===" section and the
EBFMIest AdvancedHMC.jl logs to the console during sampling use
the same formula (mean(diff(H).^2) / var(H), H = per-draw
Hamiltonian energy), but AdvancedHMC.jl's logs warmup draws which skews
its result.
"""
function write_report(
    io::IO, result;
    quantile_label::AbstractString = DEFAULT_QUANTILES,
    form_factor_log::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    n_atoms::Union{Nothing,Integer} = nothing,
)
    t_report = tick()
    fit, divergence_rate, map_result, quantile_result = result
    map_params = map_result === nothing ? nothing : first(map_result)

    _write_run_info(io, fit.timing; n_atoms = n_atoms)
    _write_diagnostics(io, fit, divergence_rate, map_params)

    if map_result === nothing
        println(io, "All draws diverged; no MAP/quantiles available.")
    else
        quantile_params, _ = quantile_result

        println(io, "=== MAP ===")
        for k in _REPORT_KEYS
            @printf(
                io,
                "%-14s = %+.6g\n",
                _REPORT_LABELS[k],
                map_params[k]
            )
        end

        println(io)
        println(io, "=== Quantiles ($quantile_label) ===")
        @printf(
            io, "%-16s %16s %16s %16s %16s\n",
            "param", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"
        )
        for k in _REPORT_KEYS
            q_lo, q_hi = quantile_params[k]["quantiles"]
            b_lo, b_hi = quantile_params[k]["bounds"]
            @printf(
                io,
                "%-16s %+16.6g %+16.6g %+16.6g %+16.6g\n",
                _REPORT_LABELS[k] * "_Q",
                q_lo,
                q_hi,
                b_lo,
                b_hi
            )
        end

        println(io)
        println(
            io,
            "=== Standard deviations from prior (θ-space z-score) ===",
        )
        @printf(
            io,
            "%-16s %16s %16s %16s\n",
            "param",
            "z_MAP",
            "z_quantile_lo",
            "z_quantile_hi"
        )
        for k in _PRIOR_KEYS
            haskey(map_params, "z_" * k) || continue
            z_map      = map_params["z_"*k]
            z_lo, z_hi = quantile_params[k]["z"]
            @printf(
                io,
                "%-16s %+16.6g %+16.6g %+16.6g\n",
                _REPORT_LABELS[k] * "_Z",
                z_map,
                z_lo,
                z_hi
            )
        end
    end

    if form_factor_log !== nothing && !isempty(form_factor_log)
        println(io)
        println(io, "=== Form-Factor Parsing Log ===")
        for line in form_factor_log
            println(io, line)
        end
    end

    _write_timing(io, fit.timing, t_report)
    return nothing
end

write_report(
    result;
    kwargs...,
) = write_report(stdout, result; kwargs...)

# ---------------------------------------------------------------------------
#                 The `=== Run ===` and `=== Timing ===` sections
# ---------------------------------------------------------------------------

"""
The report's `=== Run ===` section: `n_atoms`, lMax, the measured and fitted point counts
and the NUTS sizes, then how the measured curve was reduced to the fitted one (the
scatterer cloud's maximum diameter `Dₘₐₓ`, the Shannon channels, the binning), as recorded
in the run's [`StageLog`](@ref BAYSOL.Runtime.StageLog). The sampler's diagnostics follow
directly, in the same section (no blank line, no header of their own). `n_atoms`, if given,
overrides the logged count. Writes nothing when there is neither a log nor an `n_atoms`.
"""
function _write_run_info(
    io::IO,
    log::Union{Nothing,StageLog};
    n_atoms::Union{Nothing,Integer} = nothing,
)
    info = log === nothing ? Dict{String,Any}() : copy(log.info)
    n_atoms === nothing || (info["n_atoms"] = n_atoms)
    isempty(info) && return nothing
    println(io, "=== Run ===")
    for k in ("n_atoms", "lMax", "n_q_raw", "n_q", "n_samples", "n_adapt", "rng_seed")
        haskey(info, k) && @printf(io, "%-15s = %d\n", k, info[k])
    end
    if haskey(info, "D")
        @printf(io, "%-15s = %.1f Å (atoms and hydration-shell beads)\n", "Dₘₐₓ", info["D"])
        @printf(io, "%-15s = %.1f (q range × D / π)\n", "channels", info["n_channels"])
        if info["rebin"] > 0
            @printf(io,
                "%-15s = %d per channel: %d measured → %d fitted points ",
                "rebin", info["rebin"], info["n_q_raw"], info["n_q"])
            @printf(io, "(%d non-positive dropped)\n", info["n_nonpositive"])
        else
            @printf(io,
                "%-15s = none: %d measured → %d fitted points (%d non-positive dropped)\n",
                "rebin", info["n_q_raw"], info["n_q"], info["n_nonpositive"])
        end
    end
    return nothing
end

"""
Seconds as the timing table prints them: two decimals, or, below 0.01 s, in
scientific notation with two significant figures (`3.0e-03`), so a stage that took
a few milliseconds is not shown as a block of zeros. Exactly 0 prints as `0`.
"""
_fmt_seconds(x::Real) =
    x == 0 ? "0" : abs(x) < 0.01 ? @sprintf("%.1e", x) : @sprintf("%.2f", x)

"""
The report's `=== Timing ===` section, written last. The wall clock runs from the
creation of `log` (the start of [`seed_model`](@ref)) to now, i.e. to the end of
the report. `t_report` is the [`tick`](@ref BAYSOL.Runtime.tick) taken when
[`write_report`](@ref) began, so the `report write` line is the time spent writing
every section before this one. Nothing is written when `log` is `nothing`.

Stages print in the order they were recorded, indented two spaces per depth, with
the group lines (static build, sampling) summing their depth-1 stages. The label
column is as wide as the longest label so the seconds column always lines up.
"""
function _write_timing(io::IO, log::Union{Nothing,StageLog}, t_report)
    log === nothing && return nothing
    report_s = (time_ns() - t_report[1]) / NS_PER_S
    report_c = (Base.cumulative_compile_time_ns()[1] - t_report[2]) / NS_PER_S
    total_c = (Base.cumulative_compile_time_ns()[1] - log.compile0) / NS_PER_S
    wall = (time_ns() - log.t0) / NS_PER_S
    st, st_c, st_g = stage_seconds(log, :static)
    sp, sp_c, sp_g = stage_seconds(log, :sampling)
    unacc = wall - st - sp - report_s
    # compile time not inside any stage: the first call of run_model, infer and
    # write_report compiles before their bodies (and so their stages) begin
    unacc_c = total_c - st_c - sp_c - report_c

    # (label, seconds, % of wall, JIT seconds); the
    # last two are nothing on plain stage lines
    rows = Tuple{String,Float64,Union{Nothing,Float64},Union{Nothing,Float64}}[]
    push!(rows, ("wall clock  (seed_model → end of report)", wall, 100.0, total_c))
    for (group, label, tot, comp) in
        ((:static, "static build", st, st_c), (:sampling, "sampling", sp, sp_c))
        push!(rows, ("  " * label, tot, 100 * tot / wall, comp))
        for stage in log.stages
            stage.group === group || continue
            name = stage.note == "" ? stage.name : rpad(stage.name, 22) * stage.note
            push!(rows, ("  "^(stage.depth + 1) * name, stage.seconds, nothing, nothing))
        end
    end
    push!(rows, ("  report write", report_s, nothing, nothing))
    push!(rows, ("  unaccounted", unacc, nothing, max(unacc_c, 0.0)))

    w = maximum(length(r[1]) for r in rows)
    println(io)
    @printf(io, "%-*s %10s %9s %8s\n", w, "=== Timing ===", "seconds", "% wall", "(JIT)")
    for (label, secs, pct, jit) in rows
        @printf(io, "%-*s %10s", w, label, _fmt_seconds(secs))
        pct === nothing || @printf(io, " %9.1f", pct)
        jit === nothing || @printf(io, " %8s", @sprintf("(%.1f)", jit))
        println(io)
    end
    @printf(io, "GC: %s s\n", _fmt_seconds(st_g + sp_g))
    return nothing
end
