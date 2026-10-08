# SPDX-License-Identifier: LGPL-2.1-or-later

# run_model: NUTS on a Seed, then the MAP draw and the posterior quantiles.

"""
Run NUTS on [`Fitting._logπ`](@ref) starting from seed, returning posterior
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

Before NUTS, [`Fitting.run_fitting`](@ref) finds the mode of the same log π with a multi-start
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
- `n_samples::Int64`: total number of NUTS iterations (including the
    `n_adapt` warm-up steps,.
- `n_adapt::Int64`: number of warm-up iterations spent adapting the step
    size and mass matrix before sampling proper.

# Keywords
- `quantiles::AbstractString=DEFAULT_QUANTILES`: the "<lo>-<hi>" empirical quantile
    range (integer percentages, 0 ≤ lo < hi ≤ 100) used to build
    [`QuantileResult`](@ref)'s "quantiles"/"bounds" entries, e.g. the
    default ("16-84") is a ±1σ-equivalent interval for a Normal. The special
    case "0-0" means *no* filtering.
- `l::LIKELIHOOD=PROFILE()`: PROFILE() or MARGINAL(), forwarded to
    [`Fitting._logπ`](@ref)/[`Fitting._ll`](@ref).
- `δ::Real=DEFAULT_TARGET_ACCEPT`: target acceptance rate as a percentage,
    (0, 100) exclusive (validated below); the default, `DEFAULT_TARGET_ACCEPT`,
    is Stan's usual 80%, used here too absent a specific reason to retarget it.

# Returns
A 4-tuple (fit, divergencerate, map, curve):

-   `fit::Fitting.FitResult`: the warm-up free posterior.
-   `divergence_rate::Float64`: fraction of fit's draws AdvancedHMC.jl
    flagged as numerically divergent, [0, 1].
-   `map/curve`: either both nothing or a [`MAPResult`](@ref)/[`QuantileResult`](@ref) pair.
"""
function run_model(
    seed::Fitting.Seed,
    n_samples::Int64,
    n_adapt::Int64;
    quantiles::AbstractString=DEFAULT_QUANTILES,
    l::Fitting.LIKELIHOOD=Fitting.PROFILE(),
    δ::Real=DEFAULT_TARGET_ACCEPT
)::Union{
    Tuple{Fitting.FitResult, Float64, MAPResult, QuantileResult},
    Tuple{Fitting.FitResult, Float64, Nothing, Nothing}
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
    fit_unfiltered = Fitting.run_fitting(seed, n_samples, n_adapt; l=l, δ=δ)
    t_post = Timing.tick()

    # filter-out warmup draws
    fit = Fitting.FitResult(
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
        # ξ = (ρₑ, δρ₁, δρ₂, δρ₃)
        # z_map: how many prior standard deviations (θ-space) the MAP draw
        # sits from its own prior, one entry per physical parameter.
        ξ_map = fit.samples[max_idx]
        z_map = Fitting.prior_z_scores(ξ_map, seed.pr)
        MAP_params = Dict{String, Float64}(
            "log_density"      => max_llh,
            "slvnt_e_dns"      => ξ_map[1],
            "delta_rho_1"      => ξ_map[2],
            "delta_rho_2"      => ξ_map[3],
            "delta_rho_3"      => ξ_map[4],
            "cavity_shell_frac" => Scattering.cavity_shell_fraction(seed.fw),
            "scale"         => fit.scale[max_idx],
            "bkgrnd_corr"   => fit.bkgrnd_corr[max_idx],
            "excl_vol_corr" => fit.c1[max_idx],
            "chisq_red"     => fit.chisq_red[max_idx],
            "z_slvnt_e_dns"   => z_map[1],
            "z_delta_rho_1"   => z_map[2],
            "z_delta_rho_2"   => z_map[3],
            "z_delta_rho_3"   => z_map[4],
        )
        # c1 is profiled (no prior), so saturation against its physical
        # bounds is checked once, here, on the single MAP value -- not per
        # posterior draw, since transient saturation during warmup is
        # expected (see EXCL_VOL_CORR_BOUNDS) and
        # not itself diagnostic.
        excl_vol_sat = Fitting.excl_vol_saturation(fit.c1[max_idx])
        MAP_params["excl_vol_sat"] = Float64(excl_vol_sat)
        if excl_vol_sat != 0
            @warn "excluded-volume correction c1 saturated at the $(excl_vol_sat > 0 ? "upper" : "lower") profiling bound" c1=fit.c1[max_idx]
        end
        # are the residuals white, as the likelihood assumes; and, when the curve was binned, the fit's
        # quality on the measured q grid, which is what a depositor's χ² refers to
        if seed.shannon !== nothing
            sh = seed.shannon
            y_map = fit.curves[:, max_idx]
            rs = Shannon.residual_structure((sh.I .- y_map) ./ sh.σ)
            MAP_params["resid_lag1"]   = rs.lag1
            MAP_params["resid_runs_z"] = rs.runs_z
            if sh.rebin > 0
                r_raw = (sh.I_raw .- Shannon.model_on_raw(sh, y_map)) ./ sh.σ_raw
                rs_raw = Shannon.residual_structure(r_raw)
                MAP_params["chisq_red_raw"]    = sum(abs2, r_raw) / (length(r_raw) - 2)
                MAP_params["resid_lag1_raw"]   = rs_raw.lag1
                MAP_params["resid_runs_z_raw"] = rs_raw.runs_z
            end
        end
        MAP_curve = hcat(seed.fw.qvals, fit.curves[:, max_idx])
        map =(MAP_params, MAP_curve)

        # filter out all divergent curves
        ll_filt      = getproperty.(fit.stats, :log_density)[filter]
        samples_filt = fit.samples[filter]
        scale_filt   = fit.scale[filter]
        bkgrnd_filt  = fit.bkgrnd_corr[filter]
        c1_filt      = fit.c1[filter]
        chisq_filt   = fit.chisq_red[filter]
        curves       = fit.curves[:, filter]

        # extract parameters from ξ = (ρₑ, δρ₁, δρ₂, δρ₃)
        ρₑ_filt  = getindex.(samples_filt, 1)
        δρ₁_filt = getindex.(samples_filt, 2)
        δρ₂_filt = getindex.(samples_filt, 3)
        δρ₃_filt = getindex.(samples_filt, 4)

        # calculate param quantiles
        ll_lo,  ll_hi        = quantile(ll_filt,     [q_1, q_2])
        δρ₁_lo, δρ₁_hi       = quantile(δρ₁_filt,    [q_1, q_2])
        δρ₂_lo, δρ₂_hi       = quantile(δρ₂_filt,    [q_1, q_2])
        δρ₃_lo, δρ₃_hi       = quantile(δρ₃_filt,    [q_1, q_2])
        ρₑ_lo,  ρₑ_hi        = quantile(ρₑ_filt,     [q_1, q_2])
        scale_lo, scale_hi   = quantile(scale_filt,  [q_1, q_2])
        bkgrnd_lo, bkgrnd_hi = quantile(bkgrnd_filt, [q_1, q_2])
        c1_lo, c1_hi         = quantile(c1_filt,     [q_1, q_2])
        chisq_lo, chisq_hi   = quantile(chisq_filt,  [q_1, q_2])
        z_lo = Fitting.prior_z_scores(SVector(ρₑ_lo, δρ₁_lo, δρ₂_lo, δρ₃_lo), seed.pr)
        z_hi = Fitting.prior_z_scores(SVector(ρₑ_hi, δρ₁_hi, δρ₂_hi, δρ₃_hi), seed.pr)

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
                "delta_rho_1"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ₁_lo, δρ₁_hi),
                    "bounds"      => map_bounds(δρ₁_lo, δρ₁_hi, δρ₁_filt),
                    "z"           => (z_lo[2], z_hi[2]),
                ),
                "delta_rho_2"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ₂_lo, δρ₂_hi),
                    "bounds"      => map_bounds(δρ₂_lo, δρ₂_hi, δρ₂_filt),
                    "z"           => (z_lo[3], z_hi[3]),
                ),
                "delta_rho_3"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ₃_lo, δρ₃_hi),
                    "bounds"      => map_bounds(δρ₃_lo, δρ₃_hi, δρ₃_filt),
                    "z"           => (z_lo[4], z_hi[4]),
                ),
                "slvnt_e_dns"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (ρₑ_lo, ρₑ_hi),
                    "bounds"      => map_bounds(ρₑ_lo, ρₑ_hi, ρₑ_filt),
                    "z"           => (z_lo[1], z_hi[1]),
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
