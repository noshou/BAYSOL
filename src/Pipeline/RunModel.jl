# SPDX-License-Identifier: LGPL-3.0-or-later

# run_model: NUTS on a Seed, then the MAP draw and the posterior quantiles.

"""
The quantile levels of a run's interval and the label that names its sheet, from the
`sigma` given to [`run_model`](@ref); `nothing` means `VAL_SIGMA`. The levels are those a
Normal has at ±`sigma` σ.

# Returns
- `(p_lo, p_hi, label)`: the levels in [0, 1] and the label, `"<k>sigma"`.

# Exceptions
- `DomainError` if `sigma` is not a finite number above 0.
"""
function _sigma_spec(sigma)
    k = sigma === nothing ? VAL_SIGMA : Float64(sigma)
    (isfinite(k) && k > 0) || throw(DomainError(k, "sigma must be a finite number above 0"))
    return cdf(Normal(), -k), cdf(Normal(), k), _sigma_label(k)
end

"The sheet label of a `sigma` interval: `2sigma`, `0.5sigma` (ASCII, as sheet names are)."
_sigma_label(k::Real) = (isinteger(k) ? string(Int(k)) : string(k)) * "sigma"

"""
The posterior band of the predicted curve at every q: for the draws `curves[q, :]`
of each q, the `p_lo` and `p_hi` empirical quantiles and the smallest and largest
draw inside them. Each q's draws are sorted once (on a contiguous copy, q's in
parallel), and the quantiles and the bounds both read the sorted draws.

# Arguments
- `qvals::AbstractVector`: the q grid.
- `curves::AbstractMatrix`: the predicted curves, `Q × draws`.
- `p_lo`, `p_hi`: the quantile levels in [0, 1].

# Returns
- `(quantiles, bounds)`: two `Q × 3` matrices with the columns (q, low, high).

# Exceptions
- `ErrorException` if no draw lies between the two quantiles of some q.
"""
function _curve_bands(qvals::AbstractVector, curves::AbstractMatrix, p_lo::Real, p_hi::Real)
    Q, n = size(curves)
    draws = Matrix{Float64}(undef, n, Q)                      # one q per column, contiguous
    @inbounds for q in 1:Q, i in 1:n
        draws[i, q] = curves[q, i]
    end
    quantiles = Matrix{Float64}(undef, Q, 3)
    bounds = Matrix{Float64}(undef, Q, 3)
    tmap_blocks(Q, 32) do blk
        for q in blk
            col = view(draws, :, q)
            sort!(col)
            lo, hi = quantile(col, (p_lo, p_hi); sorted = true)
            first_in, last_in = searchsortedfirst(col, lo), searchsortedlast(col, hi)
            first_in ≤ last_in || error(
                "no posterior draw lies between the quantile bounds at q index $q ",
                "(are the draws non-finite?)",
            )
            quantiles[q, :] .= (qvals[q], lo, hi)
            bounds[q, :] .= (qvals[q], col[first_in], col[last_in])
        end
        nothing
    end
    return quantiles, bounds
end

"""
The reduced χ² of the model curve `y` (on the fitted grid of `sh`) against
the measured curve: `y` is interpolated onto the measured q points
([`Shannon.model_on_raw`](@ref BAYSOL.Utils.Shannon.model_on_raw)) and the
sum of squared normalized residuals is divided by the number of measured
points less the three parameters fitted to the curve by minimization (scale,
background and the excluded-volume correction c1). This is the χ² on the grid
a program such as CRYSOL or FoXS evaluates, whatever binning the fit used.
"""
function _chisq_measured(sh::Shannon.ShannonInfo, y::AbstractVector{<:Real})::Float64
    r = (sh.I_raw .- Shannon.model_on_raw(sh, y)) ./ sh.σ_raw
    return sum(abs2, r) / (length(r) - 3)
end

"""
[`_chisq_measured`](@ref) of every column of `curves` (models on the fitted grid), in
one matrix product with [`Shannon.raw_interpolation`](@ref) instead of a spline per
column, in blocks of columns so that the measured-grid residuals stay small.

# Returns
- `Vector{Float64}`, one reduced χ² per column.
"""
function _chisq_measured_all(sh::Shannon.ShannonInfo, curves::AbstractMatrix{<:Real})
    M = Shannon.raw_interpolation(sh)
    n_raw = length(sh.I_raw)
    out = Vector{Float64}(undef, size(curves, 2))
    block = max(1, 1_000_000 ÷ max(n_raw, 1))
    for cols in Iterators.partition(axes(curves, 2), block)
        R = (sh.I_raw .- M * curves[:, cols]) ./ sh.σ_raw
        out[cols] = vec(sum(abs2, R; dims = 1)) ./ (n_raw - 3)
    end
    return out
end

"""
Run NUTS on [`Inference._logπ`](@ref) starting from seed, returning posterior
draws of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one
(scale, `bkgrnd_corr`) pair and predicted curve per draw, and
AdvancedHMC.jl's diagnostics.

# The Hamiltonian

HMC adds an auxiliary momentum r ~ N(0, M) (M the mass matrix) and defines
a Hamiltonian:

    H(θ, r) = -log π(θ) + ½ rᵀM⁻¹r

with potential energy as the negative log-posterior, and Gaussian kinetic energy.
Leapfrog integration simulates the system's dynamics forward in time,
alternating half-steps in r with full steps in θ:

    r ← r - (ε/2)·∇[-log π(θ)]
    θ ← θ + ε·M⁻¹r
    r ← r - (ε/2)·∇[-log π(θ)]

which needs ∇[log π(θ)] at every step.

Because energy is conserved, leapfrog proposes long, correlated jumps through
parameter space far more cheaply than random-walk Metropolis. NUTS removes the
need to hand-pick a trajectory length: it grows the leapfrog trajectory by
doubling a binary tree of steps, forward and backward in time, until the trajectory
starts to double back on itself (a U-turn), then samples from the valid part of that tree.

# MAP search and whitening

Before NUTS, [`Inference.infer`](@ref) finds the mode of the same log π with a
multi-start L-BFGS search and takes a central-difference Hessian there. NUTS then
samples coordinates w with θ = μ + σ·(ẑ + S·w), in which the posterior is ≈ N(0,
I) and the chain starts at the mode. The map is affine, so the target distribution
is unchanged; it only puts the adaptation below on the O(1) scales Stan's defaults
assume. c1 is profiled out at every evaluation, to `EXCL_VOL_CORR_TOL`.

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first `n_adapt` iterations,
StepSizeAdaptor tunes the leapfrog step size ε via dual-averaging so the empirical
acceptance rate converges to δ; too-small ε wastes computation taking tiny steps,
too-large ε causes leapfrog's discretization error (and therefore the rejection rate) to
blow up. A gradient that is inconsistent with the value (a loosely profiled c1, see
`EXCL_VOL_CORR_TOL`) has the same effect and is the usual cause of a step size far below
what the local curvature allows. MassMatrixAdaptor learns M (here the full parameter
covariance, since ρₑ/δρ are physically coupled through the forward model) from the
trajectory's sample covariance, starting from the identity in the whitened coordinates.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `n_samples::Int64=N_ADAPT + N_DRAWS`: total number of NUTS iterations (including the
    `n_adapt` warm-up steps); the default is 1000.
- `n_adapt::Int64=N_ADAPT`: number of warm-up iterations spent adapting the step
    size and mass matrix before sampling proper; the default is 300, leaving
    `N_DRAWS` = 700 posterior draws.

# Keywords
- `sigma::Union{Nothing,Real}=nothing`: the half-width, in σ, of the interval of
    [`QuantileResult`](@ref)'s "quantiles"/"bounds" entries: the empirical quantiles of
    the draws at the percentiles a Normal has at ±`sigma` σ (`2` gives 2.28 – 97.72, `1`
    gives 15.87 – 84.13, `0.5` gives 30.85 – 69.15), any finite `sigma > 0` (there is no
    upper limit: beyond about 3σ the quantiles of a few thousand draws rest on a handful
    of draws). The interval is that of the draws, not a Normal fitted to them, and the
    percentiles used are in the `run` sheet. `nothing` means `VAL_SIGMA` (2).
- `δ::Real=TARGET_ACCEPT`: target acceptance rate as a percentage,
    (0, 100) exclusive (validated below); the default, `TARGET_ACCEPT`,
    is 95%.
- `rng_seed::Union{Nothing,Integer}=Inference.RNG_SEED` (0):
    the run's random seed (see [`Inference.infer`](@ref)). To reproduce a fit exactly,
    pass the `rng_seed` row of its run log (or the `run` sheet); `nothing` picks
    a fresh one (so `Random.seed!` before the call also fixes the run). The default, 0,
    makes every run reproducible.

- `n_chains::Int=Inference.N_CHAINS`: number of NUTS chains (8; chain
    1 at the MAP, the others at deterministic distances from it, in mirrored
    pairs); see [`Inference.infer`](@ref). The draws of the chains that did not
    fail are pooled, and the report gives the split R̂ and ESS of the pool.
- `retry::Bool=Inference.RETRY` (true; a CLI and developer switch, not a setting):
    rerun the sampler once, longer, always adapting again and from derived seeds, when the
    run does not count as converged (R̂ above [`Inference.RHAT_OK`](@ref), an ESS below
    [`Inference.ESS_MIN`](@ref), or either not computable); see
    [`Inference.infer`](@ref). If the run is still not converged, `run_model` throws
    [`Inference.NotConvergedError`](@ref) and nothing is reported. `retry = false` skips
    both the rerun and the error: the run is only flagged in its summary.
- `retry_n_adapt::Integer=Inference.RETRY_N_ADAPT`, `retry_n_draws::Integer=
    Inference.RETRY_N_DRAWS` (2000, 2000): warm-up and post-warm-up iterations per chain of
    the rerun.
- `chain_start_radii=Inference.CHAIN_START_RADII` ((4, 10, 20)): the distances from the
    MAP, in posterior standard deviations, at which the mirrored pairs of chains start;
    pairs beyond the list reuse the last radius.
- `optimum_chain_cap::Integer=Inference.OPTIMUM_CHAIN_CAP` (6),
    `optimum_min_chains::Integer=Inference.OPTIMUM_MIN_CHAINS` (2),
    `optimum_chain_radius::Real=Inference.OPTIMUM_CHAIN_RADIUS` (4),
    `optimum_chain_fraction::Real=Inference.OPTIMUM_CHAIN_FRACTION` (0.5): how many chains
    an optimum that carries mass should have, how many extra chains are started in all,
    and what counts as a chain being at an optimum (the share of its draws within the
    Mahalanobis radius).
- `map_max_iter::Integer=Inference.MAP_MAX_ITER` (500), `map_n_starts::Integer=
    Inference.MAP_N_STARTS` (64), `map_f_successive::Integer=Inference.MAP_F_SUCCESSIVE`
    (3), `map_optima_kept::Integer=Inference.MAP_OPTIMA_KEPT` (8): the MAP search's
    iteration cap and number of L-BFGS starts, the successive small decreases that end a
    start, and the optima kept for comparison by Laplace mass.
- `map_jitter_radii=Inference.MAP_JITTER_RADII` ((3, 6, 12)),
    `map_jitter_directions::Integer=Inference.MAP_JITTER_DIRECTIONS` (2),
    `map_jitter_max_optima::Integer=Inference.MAP_JITTER_MAX_OPTIMA` (4),
    `map_jitter_within_nats::Real=Inference.MAP_JITTER_WITHIN_NATS` (15): the jittered
    starts around the optima found.
- `basin_restart_nats::Real=Inference.BASIN_RESTART_NATS` (2): how far above the MAP a
    draw must be for the sampler to re-whiten at its basin.
- `harvest_cover::Integer=Inference.HARVEST_COVER` (16),
    `harvest_divergent::Integer=Inference.HARVEST_DIVERGENT` (8): the draws, and divergent
    draws, from which L-BFGS looks for optima the search missed.

Every setting of `load_settings` that the sampler depends on is a keyword here
(`n_samples` and `n_adapt` are the positional arguments): [`run_keywords`](@ref) and
[`run_arguments`](@ref) turn the settings into them. The keywords from `retry_n_adapt` on
are those of [`Inference.SamplerOptions`](@ref); they are checked as `load_settings`
checks the setting of the same name (the keyword is the setting's name in lower case,
`MAP_N_STARTS` → `map_n_starts`) and a bad value throws the same
[`InvalidSettingsError`](@ref) lines.

# Returns
A 4-tuple (fit, divergencerate, map, curve):

-   `fit::Inference.Inferred`: the warm-up free
    posterior, the pooled chains' draws together.
-   `divergence_rate::Float64`: fraction of fit's draws AdvancedHMC.jl
    flagged as numerically divergent, [0, 1].
-   `map/curve`: either both nothing or a [`MAPResult`](@ref)/[`QuantileResult`](@ref) pair.

# Exceptions
- [`Inference.NotConvergedError`](@ref) if the run is not converged after its retry
    (`retry = true`): nothing is returned, so nothing can be reported.
- `DomainError` if `n_adapt < 1`, `n_samples ≤ n_adapt`, `sigma` is not a finite number
    above 0, or `δ` is not strictly inside (0, 100); `n_chains < 1`.
- [`InvalidSettingsError`](@ref) if one of the keywords from `retry_n_adapt` on is outside
    its limits (a count below its least, a radius at or below 0, a fraction outside (0, 1],
    a `chain_start_radii` or `map_jitter_radii` that is not three positive numbers).
"""
function run_model(
    seed::Inference.Seed,
    n_samples::Int64 = N_ADAPT + N_DRAWS,
    n_adapt::Int64 = N_ADAPT;
    sigma::Union{Nothing,Real} = nothing,
    δ::Real = TARGET_ACCEPT,
    rng_seed::Union{Nothing,Integer} = Inference.RNG_SEED,
    n_chains::Int = Inference.N_CHAINS,
    retry::Bool = Inference.RETRY,
    retry_n_adapt = Inference.RETRY_N_ADAPT,
    retry_n_draws = Inference.RETRY_N_DRAWS,
    chain_start_radii = Inference.CHAIN_START_RADII,
    optimum_chain_cap = Inference.OPTIMUM_CHAIN_CAP,
    optimum_min_chains = Inference.OPTIMUM_MIN_CHAINS,
    optimum_chain_radius = Inference.OPTIMUM_CHAIN_RADIUS,
    optimum_chain_fraction = Inference.OPTIMUM_CHAIN_FRACTION,
    map_max_iter = Inference.MAP_MAX_ITER,
    map_n_starts = Inference.MAP_N_STARTS,
    map_f_successive = Inference.MAP_F_SUCCESSIVE,
    map_optima_kept = Inference.MAP_OPTIMA_KEPT,
    map_jitter_radii = Inference.MAP_JITTER_RADII,
    map_jitter_directions = Inference.MAP_JITTER_DIRECTIONS,
    map_jitter_max_optima = Inference.MAP_JITTER_MAX_OPTIMA,
    map_jitter_within_nats = Inference.MAP_JITTER_WITHIN_NATS,
    basin_restart_nats = Inference.BASIN_RESTART_NATS,
    harvest_cover = Inference.HARVEST_COVER,
    harvest_divergent = Inference.HARVEST_DIVERGENT,
)::Union{
    Tuple{Inference.Inferred,Float64,MAPResult,QuantileResult},
    Tuple{Inference.Inferred,Float64,Nothing,Nothing},
}

    n_adapt ≥ 1 || throw(DomainError(n_adapt, "n_adapt must be at least 1"))
    n_samples > n_adapt ||
        throw(DomainError(n_samples, "n_samples must exceed n_adapt, to leave draws"))
    q_1, q_2, quantile_label = _sigma_spec(sigma)
    # the checks of load_settings on the keywords that are settings of the sampler
    ck = _checked_keywords(
        :run_model,
        (; retry_n_adapt, retry_n_draws, chain_start_radii, optimum_chain_cap,
            optimum_min_chains, optimum_chain_radius, optimum_chain_fraction,
            map_max_iter, map_n_starts, map_f_successive, map_optima_kept,
            map_jitter_radii, map_jitter_directions, map_jitter_max_optima,
            map_jitter_within_nats, basin_restart_nats, harvest_cover,
            harvest_divergent),
    )
    options = Inference.SamplerOptions(; ck...)

    if seed.timing !== nothing
        seed.timing.info["n_atoms"]         = seed.fw.n_atoms
        seed.timing.info["lMax"]            = seed.fw.lMax
        seed.timing.info["n_q"]             = length(seed.fw.qvals)
        seed.timing.info["n_samples"]       = n_samples
        seed.timing.info["n_adapt"]         = n_adapt
        seed.timing.info["quantile_label"]  = quantile_label
        seed.timing.info["quantile_lo_pct"] = 100 * q_1
        seed.timing.info["quantile_hi_pct"] = 100 * q_2
    end

    # calculate unfiltered fit
    fit_unfiltered =
        Inference.infer(seed, n_samples, n_adapt; δ = δ, rng_seed = rng_seed,
            n_chains = n_chains, retry = retry, options = options)
    if retry
        problems = Inference._convergence_problems(fit_unfiltered.diagnostics)
        isempty(problems) || throw(Inference.NotConvergedError(problems))
    end
    t_post = tick()

    # filter-out the warm-up draws of every chain
    # (a rerun for R̂ has its own warm-up length)
    keep = findall(>(fit_unfiltered.diagnostics.n_adapt), fit_unfiltered.iteration)
    fit = Inference.Inferred(
        fit_unfiltered.samples[keep],
        fit_unfiltered.stats[keep],
        fit_unfiltered.scale[keep],
        fit_unfiltered.bkgrnd_corr[keep],
        fit_unfiltered.c1[keep],
        fit_unfiltered.chisq_red[keep],
        fit_unfiltered.curves[:, keep],
        fit_unfiltered.chain[keep],
        fit_unfiltered.iteration[keep],
        fit_unfiltered.diagnostics,
        fit_unfiltered.timing,
    )

    # The χ² every program compares is the reduced χ² on the measured points. For a
    # Shannon-binned fit that is not the fit's own (the fitted grid is the binned curve,
    # whose smaller σ makes a smooth misfit count several times more), so it is evaluated
    # on the measured grid for every draw, from the curve interpolated onto it.
    binned = seed.shannon !== nothing && seed.shannon.rebin > 0
    chisq_meas = if binned
        sh_ = seed.shannon
        _chisq_measured_all(sh_, fit.curves)
    else
        fit.chisq_red
    end

    # Numerical instabilities can occur when the posterior has very
    # different curvature/scales across dimensions. Such samples are
    # flagged as divergent and excluded from MAP selection.
    filter = trues(length(fit.stats))
    max_llh = -Inf
    max_idx = 0
    diverged = 0
    @inbounds for i in 1:length(fit.stats)
        if fit.stats[i].numerical_error
            diverged += 1
            filter[i] = false
        elseif fit.stats[i].log_density > max_llh
            max_llh = fit.stats[i].log_density
            max_idx = i
        end
    end
    if diverged == length(fit.stats)
        println("WARNING: all runs diverged; MAP and quantiles not run!")
        res = (fit, 1.0, nothing, nothing)
    else
        divergence_rate = diverged / length(fit.stats)

        # calculate MAP params + curves
        # ξ = (ρₑ, δρ₁, δρ₂, δρ₃) for the protein parameterization, see Inference.param_keys
        # z_map: how many prior standard deviations (θ-space) the MAP draw
        # sits from its own prior, one entry per physical parameter.
        ξ_map = fit.samples[max_idx]
        z_map = Inference.prior_z_scores(ξ_map, seed.pr)
        MAP_params = Dict{String,Float64}(
            "log_density"       => max_llh,
            "cavity_shell_frac" => Scattering.cavity_shell_fraction(seed.fw),
            "scale"             => fit.scale[max_idx],
            "bkgrnd_corr"       => fit.bkgrnd_corr[max_idx],
            "excl_vol_corr"     => fit.c1[max_idx],
            "chisq_red"         => chisq_meas[max_idx],
        )
        pkeys = Inference.param_keys(seed.pr)
        for (k, key) in enumerate(pkeys)
            MAP_params[key]      = ξ_map[k]
            MAP_params["z_"*key] = z_map[k]
        end
        # c1 is profiled (no prior), so saturation against its physical
        # bounds is checked once, here, on the single MAP value -- not per
        # posterior draw, since transient saturation during warmup is
        # expected (see EXCL_VOL_CORR_BOUNDS) and
        # not itself diagnostic.
        excl_vol_sat = Inference.excl_vol_saturation(
            fit.c1[max_idx]; cmin = seed.c1tab.cmin, cmax = seed.c1tab.cmax,
        )
        MAP_params["excl_vol_sat"] = Float64(excl_vol_sat)
        if excl_vol_sat != 0
            side = excl_vol_sat > 0 ? "upper" : "lower"
            @warn(
                "excluded-volume correction c1 saturated at the $side profiling bound",
                c1 = fit.c1[max_idx],
            )
        end
        MAP_curve = hcat(seed.fw.qvals, fit.curves[:, max_idx])
        map = (MAP_params, MAP_curve)

        # filter out all divergent curves
        ll_filt      = getproperty.(fit.stats, :log_density)[filter]
        samples_filt = fit.samples[filter]
        scale_filt   = fit.scale[filter]
        bkgrnd_filt  = fit.bkgrnd_corr[filter]
        c1_filt      = fit.c1[filter]
        chisq_filt   = chisq_meas[filter]
        curves       = fit.curves[:, filter]

        # per-parameter draws, quantiles and prior z-scores, one entry per coordinate of ξ
        ξ_filt = [getindex.(samples_filt, k) for k in eachindex(pkeys)]
        ξ_q    = [quantile(v, [q_1, q_2]) for v in ξ_filt]
        N      = length(pkeys)
        z_lo   = Inference.prior_z_scores(SVector{N,Float64}(first.(ξ_q)), seed.pr)
        z_hi   = Inference.prior_z_scores(SVector{N,Float64}(last.(ξ_q)), seed.pr)

        # calculate the quantiles of the remaining quantities
        ll_lo, ll_hi         = quantile(ll_filt, [q_1, q_2])
        scale_lo, scale_hi   = quantile(scale_filt, [q_1, q_2])
        bkgrnd_lo, bkgrnd_hi = quantile(bkgrnd_filt, [q_1, q_2])
        c1_lo, c1_hi         = quantile(c1_filt, [q_1, q_2])
        chisq_lo, chisq_hi   = quantile(chisq_filt, [q_1, q_2])

        # returns a tuple of (low, high) bounds; fails loudly
        function map_bounds(lo, hi, x)
            filtered = (item for item in x if lo ≤ item ≤ hi)
            if (isempty(filtered))
                error(
                    "no value lies between the bounds $lo and $hi, so the interval ",
                    "is empty ",
                    "(are the draws non-finite?)",
                )
            end
            return extrema(filtered)
        end

        # dict of parameters
        params = Dict{String,Dict{String,Tuple{Float64,Float64}}}(
            "log_density"   => Dict{String,Tuple{Float64,Float64}}(
            "quantiles" => (ll_lo, ll_hi),
            "bounds"    => map_bounds(ll_lo, ll_hi, ll_filt)
    ),
            "scale"         => Dict{String,Tuple{Float64,Float64}}(
            "quantiles" => (scale_lo, scale_hi),
            "bounds"    => map_bounds(scale_lo, scale_hi, scale_filt)
    ),
            "bkgrnd_corr"   => Dict{String,Tuple{Float64,Float64}}(
            "quantiles" => (bkgrnd_lo, bkgrnd_hi),
            "bounds"    => map_bounds(bkgrnd_lo, bkgrnd_hi, bkgrnd_filt)
    ),
            "excl_vol_corr" => Dict{String,Tuple{Float64,Float64}}(
            "quantiles" => (c1_lo, c1_hi),
            "bounds"    => map_bounds(c1_lo, c1_hi, c1_filt)
    ),
            "chisq_red"     => Dict{String,Tuple{Float64,Float64}}(
            "quantiles" => (chisq_lo, chisq_hi),
            "bounds"    => map_bounds(chisq_lo, chisq_hi, chisq_filt)
    ),
        )
        for (k, key) in enumerate(pkeys)
            lo, hi = ξ_q[k]
            params[key] = Dict{String,Tuple{Float64,Float64}}(
                "quantiles" => (lo, hi),
                "bounds"    => map_bounds(lo, hi, ξ_filt[k]),
                "z"         => (z_lo[k], z_hi[k]),
            )
        end

        # curve is Q x I_low(Q) x I_hi(Q)
        qvals = seed.fw.qvals
        curve_quantiles, curve_bounds = _curve_bands(qvals, curves, q_1, q_2)

        curve = Dict{String,Matrix{Float64}}(
            "quantiles" => curve_quantiles,
            "bounds"    => curve_bounds,
        )

        res = (fit, divergence_rate, map, (params, curve))
    end

    tock!(seed.timing, :sampling, 1, "MAP + quantiles", t_post)
    return res

end
