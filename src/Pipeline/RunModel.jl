# SPDX-License-Identifier: LGPL-2.1-or-later

# run_model: NUTS on a Seed, then the MAP draw and the posterior quantiles.

"""
The reduced χ² of the model curve `y` (on the fitted grid of `sh`) against the measured curve: `y` is interpolated onto the
measured q points ([`Shannon.model_on_raw`](@ref BAYSOL.Utils.Shannon.model_on_raw)) and the sum of squared normalized
residuals is divided by the number of measured points less the three parameters fitted to the curve by minimization (scale,
background and the excluded-volume correction c1). This is the χ² on the grid a program such as CRYSOL or FoXS evaluates,
whatever binning the fit used.
"""
function _chisq_measured(sh::Shannon.ShannonInfo, y::AbstractVector{<:Real})::Float64
    r = (sh.I_raw .- Shannon.model_on_raw(sh, y)) ./ sh.σ_raw
    return sum(abs2, r) / (length(r) - 3)
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

Before NUTS, [`Inference.infer`](@ref) finds the mode of the same log π with a multi-start
L-BFGS search and takes a central-difference Hessian there. NUTS then samples coordinates w with
θ = μ + σ·(ẑ + S·w), in which the posterior is ≈ N(0, I) and the chain starts at the mode. The map
is affine, so the target distribution is unchanged; it only puts the adaptation below on the O(1)
scales Stan's defaults assume. c1 is profiled out at every evaluation, to `EXCL_VOL_CORR_TOL`.

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first `n_adapt` iterations,
StepSizeAdaptor tunes the leapfrog step size ε via dual-averaging so the
empirical acceptance rate converges to δ; too-small ε wastes computation
taking tiny steps, too-large ε causes leapfrog's discretization error (and
therefore the rejection rate) to blow up. A gradient that is inconsistent with the value
(a loosely profiled c1, see `EXCL_VOL_CORR_TOL`) has the same effect and is the usual cause of a
step size far below what the local curvature allows. MassMatrixAdaptor learns M (here the
full parameter covariance, since ρₑ/δρ are physically coupled through the
forward model) from the trajectory's sample covariance, starting from the identity in the
whitened coordinates.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `n_samples::Int64=DEFAULT_N_SAMPLES`: total number of NUTS iterations (including the
    `n_adapt` warm-up steps); the default is 1000.
- `n_adapt::Int64=DEFAULT_N_ADAPT`: number of warm-up iterations spent adapting the step
    size and mass matrix before sampling proper; the default is 300, leaving
    `DEFAULT_N_DRAWS` = 700 posterior draws.

# Keywords
- `quantiles::AbstractString=DEFAULT_QUANTILES`: the "<lo>-<hi>" empirical quantile
    range (integer percentages, 0 ≤ lo < hi ≤ 100) used to build
    [`QuantileResult`](@ref)'s "quantiles"/"bounds" entries, e.g. the
    default ("16-84") is a ±1σ-equivalent interval for a Normal. The special
    case "0-0" means *no* filtering.
- `l::LIKELIHOOD=PROFILE()`: PROFILE() or MARGINAL(), forwarded to
    [`Inference._logπ`](@ref)/[`Inference._ll`](@ref).
- `δ::Real=DEFAULT_TARGET_ACCEPT`: target acceptance rate as a percentage,
    (0, 100) exclusive (validated below); the default, `DEFAULT_TARGET_ACCEPT`,
    is Stan's usual 80%, used here too absent a specific reason to retarget it.

# Returns
A 4-tuple (fit, divergencerate, map, curve):

-   `fit::Inference.Inferred`: the warm-up free posterior.
-   `divergence_rate::Float64`: fraction of fit's draws AdvancedHMC.jl
    flagged as numerically divergent, [0, 1].
-   `map/curve`: either both nothing or a [`MAPResult`](@ref)/[`QuantileResult`](@ref) pair.
"""
function run_model(
    seed::Inference.Seed,
    n_samples::Int64=DEFAULT_N_SAMPLES,
    n_adapt::Int64=DEFAULT_N_ADAPT;
    quantiles::AbstractString=DEFAULT_QUANTILES,
    l::Inference.LIKELIHOOD=Inference.PROFILE(),
    δ::Real=DEFAULT_TARGET_ACCEPT
)::Union{
    Tuple{Inference.Inferred, Float64, MAPResult, QuantileResult},
    Tuple{Inference.Inferred, Float64, Nothing, Nothing}
}

    # parse quantiles
    q_regex = r"^(\d+)-(\d+)$"
    if !occursin(q_regex, quantiles)
        throw(DomainError(quantiles, "quantiles must be '<#>-<#>'"))
    else
        q_match = match(q_regex, quantiles)
        q_1 = parse(Int64, q_match.captures[1])
        q_2 = parse(Int64, q_match.captures[2])
        if ((q_1 ≥ q_2) || q_1 < 0 || q_1 > 100 || q_2 < 0 || q_2 > 100)
            # special case: "0-0" means no quantile filtering
            if !(q_1 == 0 && q_2 == 0)
                throw(DomainError((q_1, q_2), "invalid quantile range"))
            end
        end
    end
    q_1, q_2 = q_1 / 100, q_2 / 100

    # "0-0" means no quantile filtering: reuse the same quantile/map_bounds
    # machinery below with the full 0th-100th percentile range, which by
    # construction spans (and therefore filters out nothing from) the data.
    if q_1 == 0 && q_2 == 0
        q_1, q_2 = 0.0, 1.0
    end

    if seed.timing !== nothing
        seed.timing.info["n_atoms"]   = seed.fw.n_atoms
        seed.timing.info["lMax"]      = seed.fw.lMax
        seed.timing.info["n_q"]       = length(seed.fw.qvals)
        seed.timing.info["n_samples"] = n_samples
        seed.timing.info["n_adapt"]   = n_adapt
    end

    # calculate unfiltered fit
    fit_unfiltered = Inference.infer(seed, n_samples, n_adapt; l=l, δ=δ)
    t_post = Timing.tick()

    # filter-out warmup draws
    fit = Inference.Inferred(
        fit_unfiltered.samples[n_adapt+1:end],
        fit_unfiltered.stats[n_adapt+1:end],
        fit_unfiltered.scale[n_adapt+1:end],
        fit_unfiltered.bkgrnd_corr[n_adapt+1:end],
        fit_unfiltered.c1[n_adapt+1:end],
        fit_unfiltered.chisq_red[n_adapt+1:end],
        fit_unfiltered.curves[:, n_adapt+1:end],
        fit_unfiltered.likelihood,
        fit_unfiltered.timing
    )

    # The χ² every program compares is the reduced χ² on the measured points. For a Shannon-binned fit that is not the
    # fit's own (the fitted grid is the binned curve, whose smaller σ makes a smooth misfit count several times more),
    # so it is evaluated on the measured grid for every draw, from the curve interpolated onto it.
    binned = seed.shannon !== nothing && seed.shannon.rebin > 0
    chisq_meas = if binned
        sh_ = seed.shannon
        [_chisq_measured(sh_, view(fit.curves, :, j)) for j in axes(fit.curves, 2)]
    else
        fit.chisq_red
    end

    # Numerical instabilities can occur when the posterior has very
    # different curvature/scales across dimensions. Such samples are
    # flagged as divergent and excluded from MAP selection.
    filter  = trues(length(fit.stats))
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
        res = (fit, 1., nothing, nothing)
    else
        divergence_rate = diverged / length(fit.stats)

        # calculate MAP params + curves
        # ξ = (ρₑ, δρ₁, δρ₂, δρ₃) for the protein parameterization, see Inference.param_keys
        # z_map: how many prior standard deviations (θ-space) the MAP draw
        # sits from its own prior, one entry per physical parameter.
        ξ_map = fit.samples[max_idx]
        z_map = Inference.prior_z_scores(ξ_map, seed.pr)
        MAP_params = Dict{String, Float64}(
            "log_density"       => max_llh,
            "cavity_shell_frac" => Scattering.cavity_shell_fraction(seed.fw),
            "scale"             => fit.scale[max_idx],
            "bkgrnd_corr"       => fit.bkgrnd_corr[max_idx],
            "excl_vol_corr"     => fit.c1[max_idx],
            "chisq_red"         => chisq_meas[max_idx],
        )
        pkeys = Inference.param_keys(seed.pr)
        for (k, key) in enumerate(pkeys)
            MAP_params[key]        = ξ_map[k]
            MAP_params["z_" * key] = z_map[k]
        end
        # c1 is profiled (no prior), so saturation against its physical
        # bounds is checked once, here, on the single MAP value -- not per
        # posterior draw, since transient saturation during warmup is
        # expected (see EXCL_VOL_CORR_BOUNDS) and
        # not itself diagnostic.
        excl_vol_sat = Inference.excl_vol_saturation(fit.c1[max_idx])
        MAP_params["excl_vol_sat"] = Float64(excl_vol_sat)
        if excl_vol_sat != 0
            @warn "excluded-volume correction c1 saturated at the $(excl_vol_sat > 0 ? "upper" : "lower") profiling bound" c1=fit.c1[max_idx]
        end
        MAP_curve = hcat(seed.fw.qvals, fit.curves[:, max_idx])
        map =(MAP_params, MAP_curve)

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
        z_lo = Inference.prior_z_scores(SVector{N,Float64}(first.(ξ_q)), seed.pr)
        z_hi = Inference.prior_z_scores(SVector{N,Float64}(last.(ξ_q)), seed.pr)

        # calculate the quantiles of the remaining quantities
        ll_lo,  ll_hi        = quantile(ll_filt,     [q_1, q_2])
        scale_lo, scale_hi   = quantile(scale_filt,  [q_1, q_2])
        bkgrnd_lo, bkgrnd_hi = quantile(bkgrnd_filt, [q_1, q_2])
        c1_lo, c1_hi         = quantile(c1_filt,     [q_1, q_2])
        chisq_lo, chisq_hi   = quantile(chisq_filt,  [q_1, q_2])

        # returns a tuple of (low, high) bounds; fails loudly
        function map_bounds(lo, hi, x)
            filtered = (item for item in x if lo ≤ item ≤ hi)
            if (isempty(filtered))
                error("Illegal state: filtered cannot be empty!")
            end
            return extrema(filtered)
        end

        # dict of parameters
        params  = Dict{String, Dict{String, Tuple{Float64, Float64}}}(
                "log_density"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (ll_lo, ll_hi),
                    "bounds"      => map_bounds(ll_lo, ll_hi, ll_filt)
                ),
                "scale"           => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (scale_lo, scale_hi),
                    "bounds"      => map_bounds(scale_lo, scale_hi, scale_filt)
                ),
                "bkgrnd_corr"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (bkgrnd_lo, bkgrnd_hi),
                    "bounds"      => map_bounds(bkgrnd_lo, bkgrnd_hi, bkgrnd_filt)
                ),
                "excl_vol_corr"   => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (c1_lo, c1_hi),
                    "bounds"      => map_bounds(c1_lo, c1_hi, c1_filt)
                ),
                "chisq_red"       => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (chisq_lo, chisq_hi),
                    "bounds"      => map_bounds(chisq_lo, chisq_hi, chisq_filt)
                )
            )
        for (k, key) in enumerate(pkeys)
            lo, hi = ξ_q[k]
            params[key] = Dict{String, Tuple{Float64, Float64}}(
                "quantiles" => (lo, hi),
                "bounds"    => map_bounds(lo, hi, ξ_filt[k]),
                "z"         => (z_lo[k], z_hi[k]),
            )
        end

        # curve is Q x I_low(Q) x I_hi(Q)
        qvals = seed.fw.qvals
        Q = size(curves, 1)
        curve_quantiles = Matrix{Float64}(undef, Q, 3)
        curve_bounds    = Matrix{Float64}(undef, Q, 3)
        for q in 1:Q
            I = curves[q, :]

            I_lo, I_hi = quantile(I, [q_1, q_2])

            curve_quantiles[q, :] .= (qvals[q], I_lo, I_hi)
            curve_bounds[q, :]    .= (qvals[q], map_bounds(I_lo, I_hi, I)...)
        end

        curve = Dict{String, Matrix{Float64}}(
            "quantiles" => curve_quantiles,
            "bounds"    => curve_bounds
        )

        res = (fit, divergence_rate, map, (params, curve))
    end

    Timing.tock!(seed.timing, :sampling, 1, "MAP + quantiles", t_post)
    return res

end
