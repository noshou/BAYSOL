# SPDX-License-Identifier: LGPL-2.1-or-later

# write_report: the text report of a run_model result.

"Order the physical/derived parameters are reported in, by [`write_report`](@ref)."
const _REPORT_KEYS = [
    "log_density", "slvnt_e_dns", "delta_rho_1", "delta_rho_2",
    "delta_rho_3", "scale", "bkgrnd_corr", "excl_vol_corr", "chisq_red",
]

"The 4 physical parameters that carry a prior."
const _PRIOR_KEYS = [
    "slvnt_e_dns", "delta_rho_1", "delta_rho_2", "delta_rho_3",
]

"Display labels for [`write_report`](@ref)'s text output."
const _REPORT_LABELS = Dict{String, String}(
    "log_density"   => "log_density",
    "slvnt_e_dns"   => "ρₑ",
    "delta_rho_1"   => "δρ₁",
    "delta_rho_2"   => "δρ₂",
    "delta_rho_3"   => "δρ₃",
    "scale"         => "scale",
    "bkgrnd_corr"   => "bkgrnd_corr",
    "excl_vol_corr" => "excl_vol_corr",
    "chisq_red"     => "χ²",
)

"""
The report's `=== Diagnostics ===` block, right after the run block: the sampler's iterations, mean acceptance, tree depth
and steps, E-BFMI, the cavity fraction of the hydration shell, whether the profiled c1 hit its bound, and the share of
divergent transitions. `map_params` is `nothing` when every draw diverged (the MAP-based lines are then left out).
"""
function _write_diagnostics(io::IO, fit, divergence_rate::Real, map_params)
    println(io, "=== Diagnostics ===")
    stats  = fit.stats
    accept = getproperty.(stats, :acceptance_rate)
    depth  = getproperty.(stats, :tree_depth)
    nsteps = getproperty.(stats, :n_steps)
    H      = getproperty.(stats, :hamiltonian_energy)
    # E-BFMI: Stan's energy-based Bayesian Fraction of Missing Information,
    # diagnosing whether momentum resampling explores the Hamiltonian's
    # energy level sets adequately. Values below ~0.2-0.3 are the usual
    # "may be problematic, consider reparameterizing" threshold.
    ebfmi = mean(diff(H) .^ 2) / var(H)
    @printf(io, "%-14s = %d\n", "iterations", length(stats))
    @printf(io, "%-14s = %.4f\n", "mean_accept", mean(accept))
    @printf(io, "%-14s = %.2f (max %d)\n", "tree_depth", mean(depth), maximum(depth))
    @printf(io, "%-14s = %.2f\n", "mean_n_steps", mean(nsteps))
    @printf(io, "%-14s = %.4f\n", "EBFMI", ebfmi)
    if map_params !== nothing && haskey(map_params, "cavity_shell_frac")
        @printf(io, "%-14s = %.4f\n", "cavity_frac", map_params["cavity_shell_frac"])
    end

    # c1 is profiled, not sampled with a prior, so this reports whether the
    # MAP draw's profiled c1 hit the physical bound in Inference's
    # EXCL_VOL_CORR_BOUNDS -- see Inference.excl_vol_saturation.
    excl_vol_sat = map_params === nothing ? 0.0 : get(map_params, "excl_vol_sat", 0.0)
    if excl_vol_sat == 0.0
        @printf(io, "%-14s = false\n", "excl_vol_sat")
    elseif excl_vol_sat > 0
        @printf(io, "%-14s = true, c1 -> +∞\n", "excl_vol_sat")
    else
        @printf(io, "%-14s = true, c1 -> -∞\n", "excl_vol_sat")
    end
    @printf(io, "%-14s = %.4f\n", "divergence_rate", divergence_rate)
    println(io)
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

The "EBFMI" line in this report's "=== Diagnostics ===" block and the
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
    t_report = Timing.tick()
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
            @printf(io, "%-14s = %+.6g\n", _REPORT_LABELS[k], map_params[k])
        end

        println(io)
        println(io, "=== Quantiles ($quantile_label) ===")
        @printf(
            io, "%-14s %16s %16s %16s %16s\n",
            "param", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"
        )
        for k in _REPORT_KEYS
            q_lo, q_hi = quantile_params[k]["quantiles"]
            b_lo, b_hi = quantile_params[k]["bounds"]
            @printf(io, "%-14s %+16.6g %+16.6g %+16.6g %+16.6g\n", _REPORT_LABELS[k], q_lo, q_hi, b_lo, b_hi)
        end

        println(io)
        println(io, "=== Standard deviations from prior (θ-space z-score) ===")
        @printf(io, "%-14s %16s %16s %16s\n", "param", "z_MAP", "z_quantile_lo", "z_quantile_hi")
        for k in _PRIOR_KEYS
            haskey(map_params, "z_" * k) || continue
            z_map           = map_params["z_" * k]
            z_lo, z_hi      = quantile_params[k]["z"]
            @printf(io, "%-14s %+16.6g %+16.6g %+16.6g\n", _REPORT_LABELS[k], z_map, z_lo, z_hi)
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

write_report(result; kwargs...) = write_report(stdout, result; kwargs...)
