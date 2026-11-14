# SPDX-License-Identifier: LGPL-3.0-or-later

# runModel: NUTS on a Seed, then the MAP draw and the posterior quantiles.

"""
The quantile levels of a run's interval and the label that names its sheet, from the
`sigma` given to [`runModel`](@ref); `nothing` means `VAL_SIGMA`. The levels are those a
Normal has at ±`sigma` σ.

# Returns
- `(pLo, pHi, label)`: the levels in [0, 1] and the label, `"<k>sigma"`.

# Exceptions
- `DomainError` if `sigma` is not a finite number above 0.
"""
function _sigmaSpec(sigma)
    k = sigma === nothing ? VAL_SIGMA : Float64(sigma)
    (isfinite(k) && k > 0) || throw(DomainError(k, "sigma must be a finite number above 0"))
    return cdf(Normal(), -k), cdf(Normal(), k), _sigmaLabel(k)
end

"The sheet label of a `sigma` interval: `2sigma`, `0.5sigma` (ASCII, as sheet names are)."
_sigmaLabel(k::Real) = (isinteger(k) ? string(Int(k)) : string(k)) * "sigma"

"""
The posterior band of the predicted curve at every q: for the draws `curves[q, :]`
of each q, the `pLo` and `pHi` empirical quantiles and the smallest and largest
draw inside them. Each q's draws are sorted once (on a contiguous copy, q's in
parallel), and the quantiles and the bounds both read the sorted draws.

# Arguments
- `qvals::AbstractVector`: the q grid.
- `curves::AbstractMatrix`: the predicted curves, `Q × draws`.
- `pLo`, `pHi`: the quantile levels in [0, 1].

# Returns
- `(quantiles, bounds)`: two `Q × 3` matrices with the columns (q, low, high).

# Exceptions
- `ErrorException` if no draw lies between the two quantiles of some q.
"""
function _curveBands(qvals::AbstractVector, curves::AbstractMatrix, pLo::Real, pHi::Real)
    Q, n = size(curves)
    draws = Matrix{Float64}(undef, n, Q)                      # one q per column, contiguous
    @inbounds for q in 1:Q, i in 1:n
        draws[i, q] = curves[q, i]
    end
    quantiles = Matrix{Float64}(undef, Q, 3)
    bounds = Matrix{Float64}(undef, Q, 3)
    tmapBlocks(Q, 32) do blk
        for q in blk
            col = view(draws, :, q)
            sort!(col)
            lo, hi = quantile(col, (pLo, pHi); sorted = true)
            firstIn, lastIn = searchsortedfirst(col, lo), searchsortedlast(col, hi)
            firstIn ≤ lastIn || error(
                "no posterior draw lies between the quantile bounds at q index $q ",
                "(are the draws non-finite?)",
            )
            quantiles[q, :] .= (qvals[q], lo, hi)
            bounds[q, :] .= (qvals[q], col[firstIn], col[lastIn])
        end
        nothing
    end
    return quantiles, bounds
end

"""
The reduced χ² of the model curve `y` (on the fitted grid of `sh`) against
the measured curve: `y` is interpolated onto the measured q points
([`Shannon.modelOnRaw`](@ref BAYSOL.Utils.Shannon.modelOnRaw)) and the
sum of squared normalized residuals is divided by the number of measured
points less the three parameters fitted to the curve by minimization (scale,
background and the excluded-volume correction c1). This is the χ² on the grid
a program such as CRYSOL or FoXS evaluates, whatever binning the fit used.
"""
function _chisqMeasured(sh::Shannon.ShannonInfo, y::AbstractVector{<:Real})::Float64
    r = (sh.iRaw .- Shannon.modelOnRaw(sh, y)) ./ sh.σ_raw
    return sum(abs2, r) / (length(r) - 3)
end

"""
[`_chisqMeasured`](@ref) of every column of `curves` (models on the fitted grid), in
one matrix product with [`Shannon.rawInterpolation`](@ref) instead of a spline per
column, in blocks of columns so that the measured-grid residuals stay small.

# Returns
- `Vector{Float64}`, one reduced χ² per column.
"""
function _chisqMeasuredAll(sh::Shannon.ShannonInfo, curves::AbstractMatrix{<:Real})
    M = Shannon.rawInterpolation(sh)
    nRaw = length(sh.iRaw)
    out = Vector{Float64}(undef, size(curves, 2))
    block = max(1, 1_000_000 ÷ max(nRaw, 1))
    for cols in Iterators.partition(axes(curves, 2), block)
        R = (sh.iRaw .- M * curves[:, cols]) ./ sh.σ_raw
        out[cols] = vec(sum(abs2, R; dims = 1)) ./ (nRaw - 3)
    end
    return out
end

"""
Run NUTS on [`Inference._logπ`](@ref) starting from seed, returning posterior
draws of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one
(scale, `bkgrndCorr`) pair and predicted curve per draw, and
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

δ is the target Metropolis acceptance rate. During the first `nAdapt` iterations,
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
- `nSamples::Int64=N_ADAPT + N_DRAWS`: total number of NUTS iterations (including the
    `nAdapt` warm-up steps); the default is 1000.
- `nAdapt::Int64=N_ADAPT`: number of warm-up iterations spent adapting the step
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
- `rngSeed::Union{Nothing,Integer}=Inference.RNG_SEED` (0):
    the run's random seed (see [`Inference.infer`](@ref)). To reproduce a fit exactly,
    pass the `rngSeed` row of its run log (or the `run` sheet); `nothing` picks
    a fresh one (so `Random.seed!` before the call also fixes the run). The default, 0,
    makes every run reproducible.

- `nChains::Int=Inference.N_CHAINS`: number of NUTS chains (8; chain
    1 at the MAP, the others at deterministic distances from it, in mirrored
    pairs); see [`Inference.infer`](@ref). The draws of the chains that did not
    fail are pooled, and the report gives the split R̂ and ESS of the pool.
- `retry::Bool=Inference.RETRY` (true; a CLI and developer switch, not a setting):
    rerun the sampler once, longer, always adapting again and from derived seeds, when the
    run does not count as converged (R̂ above [`Inference.RHAT_OK`](@ref), an ESS below
    [`Inference.ESS_MIN`](@ref), or either not computable); see
    [`Inference.infer`](@ref). If the run is still not converged, `runModel` throws
    [`Inference.NotConvergedError`](@ref) and nothing is reported. `retry = false` skips
    both the rerun and the error: the run is only flagged in its summary.
- `retryNAdapt::Integer=Inference.RETRY_N_ADAPT`, `retryNDraws::Integer=
    Inference.RETRY_N_DRAWS` (2000, 2000): warm-up and post-warm-up iterations per chain of
    the rerun.
- `chainStartRadii=Inference.CHAIN_START_RADII` ((4, 10, 20)): the distances from the
    MAP, in posterior standard deviations, at which the mirrored pairs of chains start;
    pairs beyond the list reuse the last radius.
- `optimumChainCap::Integer=Inference.OPTIMUM_CHAIN_CAP` (6),
    `optimumMinChains::Integer=Inference.OPTIMUM_MIN_CHAINS` (2),
    `optimumChainRadius::Real=Inference.OPTIMUM_CHAIN_RADIUS` (4),
    `optimumChainFraction::Real=Inference.OPTIMUM_CHAIN_FRACTION` (0.5): how many chains
    an optimum that carries mass should have, how many extra chains are started in all,
    and what counts as a chain being at an optimum (the share of its draws within the
    Mahalanobis radius).
- `mapMaxIter::Integer=Inference.MAP_MAX_ITER` (500), `mapNStarts::Integer=
    Inference.MAP_N_STARTS` (64), `mapFSuccessive::Integer=Inference.MAP_F_SUCCESSIVE`
    (3), `mapOptimaKept::Integer=Inference.MAP_OPTIMA_KEPT` (8): the MAP search's
    iteration cap and number of L-BFGS starts, the successive small decreases that end a
    start, and the optima kept for comparison by Laplace mass.
- `mapJitterRadii=Inference.MAP_JITTER_RADII` ((3, 6, 12)),
    `mapJitterDirections::Integer=Inference.MAP_JITTER_DIRECTIONS` (2),
    `mapJitterMaxOptima::Integer=Inference.MAP_JITTER_MAX_OPTIMA` (4),
    `mapJitterWithinNats::Real=Inference.MAP_JITTER_WITHIN_NATS` (15): the jittered
    starts around the optima found.
- `basinRestartNats::Real=Inference.BASIN_RESTART_NATS` (2): how far above the MAP a
    draw must be for the sampler to re-whiten at its basin.
- `harvestCover::Integer=Inference.HARVEST_COVER` (16),
    `harvestDivergent::Integer=Inference.HARVEST_DIVERGENT` (8): the draws, and divergent
    draws, from which L-BFGS looks for optima the search missed.

Every setting of `loadSettings` that the sampler depends on is a keyword here
(`nSamples` and `nAdapt` are the positional arguments): [`runKeywords`](@ref) and
[`runArguments`](@ref) turn the settings into them. The keywords from `retryNAdapt` on
are those of [`Inference.SamplerOptions`](@ref); they are checked as `loadSettings`
checks the setting of the same name (the keyword is the setting's name in lower case,
`MAP_N_STARTS` → `mapNStarts`) and a bad value throws the same
[`InvalidSettingsError`](@ref) lines.

# Returns
A 4-tuple (fit, divergencerate, map, curve):

-   `fit::Inference.Inferred`: the warm-up free
    posterior, the pooled chains' draws together.
-   `divergenceRate::Float64`: fraction of fit's draws AdvancedHMC.jl
    flagged as numerically divergent, [0, 1].
-   `map/curve`: either both nothing or a [`MAPResult`](@ref)/[`QuantileResult`](@ref) pair.

# Exceptions
- [`Inference.NotConvergedError`](@ref) if the run is not converged after its retry
    (`retry = true`): nothing is returned, so nothing can be reported.
- `DomainError` if `nAdapt < 1`, `nSamples ≤ nAdapt`, `sigma` is not a finite number
    above 0, or `δ` is not strictly inside (0, 100); `nChains < 1`.
- [`InvalidSettingsError`](@ref) if one of the keywords from `retryNAdapt` on is outside
    its limits (a count below its least, a radius at or below 0, a fraction outside (0, 1],
    a `chainStartRadii` or `mapJitterRadii` that is not three positive numbers).
"""
function runModel(
    seed::Inference.Seed,
    nSamples::Int64 = N_ADAPT + N_DRAWS,
    nAdapt::Int64 = N_ADAPT;
    sigma::Union{Nothing,Real} = nothing,
    δ::Real = TARGET_ACCEPT,
    rngSeed::Union{Nothing,Integer} = Inference.RNG_SEED,
    nChains::Int = Inference.N_CHAINS,
    retry::Bool = Inference.RETRY,
    retryNAdapt = Inference.RETRY_N_ADAPT,
    retryNDraws = Inference.RETRY_N_DRAWS,
    chainStartRadii = Inference.CHAIN_START_RADII,
    optimumChainCap = Inference.OPTIMUM_CHAIN_CAP,
    optimumMinChains = Inference.OPTIMUM_MIN_CHAINS,
    optimumChainRadius = Inference.OPTIMUM_CHAIN_RADIUS,
    optimumChainFraction = Inference.OPTIMUM_CHAIN_FRACTION,
    mapMaxIter = Inference.MAP_MAX_ITER,
    mapNStarts = Inference.MAP_N_STARTS,
    mapFSuccessive = Inference.MAP_F_SUCCESSIVE,
    mapOptimaKept = Inference.MAP_OPTIMA_KEPT,
    mapJitterRadii = Inference.MAP_JITTER_RADII,
    mapJitterDirections = Inference.MAP_JITTER_DIRECTIONS,
    mapJitterMaxOptima = Inference.MAP_JITTER_MAX_OPTIMA,
    mapJitterWithinNats = Inference.MAP_JITTER_WITHIN_NATS,
    basinRestartNats = Inference.BASIN_RESTART_NATS,
    harvestCover = Inference.HARVEST_COVER,
    harvestDivergent = Inference.HARVEST_DIVERGENT,
)::Union{
    Tuple{Inference.Inferred,Float64,MAPResult,QuantileResult},
    Tuple{Inference.Inferred,Float64,Nothing,Nothing},
}

    nAdapt ≥ 1 || throw(DomainError(nAdapt, "nAdapt must be at least 1"))
    nSamples > nAdapt ||
        throw(DomainError(nSamples, "nSamples must exceed nAdapt, to leave draws"))
    q1, q2, quantileLabel = _sigmaSpec(sigma)
    # the checks of loadSettings on the keywords that are settings of the sampler
    ck = _checkedKeywords(
        :runModel,
        (; retryNAdapt, retryNDraws, chainStartRadii, optimumChainCap,
            optimumMinChains, optimumChainRadius, optimumChainFraction,
            mapMaxIter, mapNStarts, mapFSuccessive, mapOptimaKept,
            mapJitterRadii, mapJitterDirections, mapJitterMaxOptima,
            mapJitterWithinNats, basinRestartNats, harvestCover,
            harvestDivergent),
    )
    options = Inference.SamplerOptions(; ck...)

    if seed.timing !== nothing
        seed.timing.info["nAtoms"]        = seed.fw.nAtoms
        seed.timing.info["lMax"]          = seed.fw.lMax
        seed.timing.info["nQ"]            = length(seed.fw.qvals)
        seed.timing.info["nSamples"]      = nSamples
        seed.timing.info["nAdapt"]        = nAdapt
        seed.timing.info["quantileLabel"] = quantileLabel
        seed.timing.info["quantileLoPct"] = 100 * q1
        seed.timing.info["quantileHiPct"] = 100 * q2
    end

    # calculate unfiltered fit
    fitUnfiltered =
        Inference.infer(seed, nSamples, nAdapt; δ = δ, rngSeed = rngSeed,
            nChains = nChains, retry = retry, options = options)
    if retry
        problems = Inference._convergenceProblems(fitUnfiltered.diagnostics)
        isempty(problems) || throw(Inference.NotConvergedError(problems))
    end
    tPost = tick()

    # filter-out the warm-up draws of every chain
    # (a rerun for R̂ has its own warm-up length)
    keep = findall(>(fitUnfiltered.diagnostics.nAdapt), fitUnfiltered.iteration)
    fit = Inference.Inferred(
        fitUnfiltered.samples[keep],
        fitUnfiltered.stats[keep],
        fitUnfiltered.scale[keep],
        fitUnfiltered.bkgrndCorr[keep],
        fitUnfiltered.c1[keep],
        fitUnfiltered.chisqRed[keep],
        fitUnfiltered.curves[:, keep],
        fitUnfiltered.chain[keep],
        fitUnfiltered.iteration[keep],
        fitUnfiltered.diagnostics,
        fitUnfiltered.timing,
    )

    # The χ² every program compares is the reduced χ² on the measured points. For a
    # Shannon-binned fit that is not the fit's own (the fitted grid is the binned curve,
    # whose smaller σ makes a smooth misfit count several times more), so it is evaluated
    # on the measured grid for every draw, from the curve interpolated onto it.
    binned = seed.shannon !== nothing && seed.shannon.rebin > 0
    chisqMeas = if binned
        sh_ = seed.shannon
        _chisqMeasuredAll(sh_, fit.curves)
    else
        fit.chisqRed
    end

    # Numerical instabilities can occur when the posterior has very
    # different curvature/scales across dimensions. Such samples are
    # flagged as divergent and excluded from MAP selection.
    filter = trues(length(fit.stats))
    maxLlh = -Inf
    maxIdx = 0
    diverged = 0
    @inbounds for i in 1:length(fit.stats)
        if fit.stats[i].numerical_error
            diverged += 1
            filter[i] = false
        elseif fit.stats[i].log_density > maxLlh
            maxLlh = fit.stats[i].log_density
            maxIdx = i
        end
    end
    if diverged == length(fit.stats)
        println("WARNING: all runs diverged; MAP and quantiles not run!")
        res = (fit, 1.0, nothing, nothing)
    else
        divergenceRate = diverged / length(fit.stats)

        # calculate MAP params + curves
        # ξ = (ρₑ, δρ₁, δρ₂, δρ₃) for the protein parameterization, see Inference.paramKeys
        # zMap: how many prior standard deviations (θ-space) the MAP draw
        # sits from its own prior, one entry per physical parameter.
        ξ_map = fit.samples[maxIdx]
        zMap = Inference.priorZScores(ξ_map, seed.pr)
        mapParams = Dict{String,Float64}(
            "logDensity"      => maxLlh,
            "cavityShellFrac" => Scattering.cavityShellFraction(seed.fw),
            "scale"           => fit.scale[maxIdx],
            "bkgrndCorr"      => fit.bkgrndCorr[maxIdx],
            "exclVolCorr"     => fit.c1[maxIdx],
            "chisqRed"        => chisqMeas[maxIdx],
        )
        pkeys = Inference.paramKeys(seed.pr)
        for (k, key) in enumerate(pkeys)
            mapParams[key] = ξ_map[k]
            mapParams["z"*uppercasefirst(key)] = zMap[k]
        end
        # c1 is profiled (no prior), so saturation against its physical
        # bounds is checked once, here, on the single MAP value -- not per
        # posterior draw, since transient saturation during warmup is
        # expected (see EXCL_VOL_CORR_BOUNDS) and
        # not itself diagnostic.
        exclVolSat = Inference.exclVolSaturation(
            fit.c1[maxIdx]; cmin = seed.c1tab.cmin, cmax = seed.c1tab.cmax,
        )
        mapParams["exclVolSat"] = Float64(exclVolSat)
        if exclVolSat != 0
            side = exclVolSat > 0 ? "upper" : "lower"
            @warn(
                "excluded-volume correction c1 saturated at the $side profiling bound",
                c1 = fit.c1[maxIdx],
            )
        end
        mapCurve = hcat(seed.fw.qvals, fit.curves[:, maxIdx])
        map = (mapParams, mapCurve)

        # filter out all divergent curves
        llFilt      = getproperty.(fit.stats, :log_density)[filter]
        samplesFilt = fit.samples[filter]
        scaleFilt   = fit.scale[filter]
        bkgrndFilt  = fit.bkgrndCorr[filter]
        c1Filt      = fit.c1[filter]
        chisqFilt   = chisqMeas[filter]
        curves      = fit.curves[:, filter]

        # per-parameter draws, quantiles and prior z-scores, one entry per coordinate of ξ
        ξ_filt = [getindex.(samplesFilt, k) for k in eachindex(pkeys)]
        ξ_q    = [quantile(v, [q1, q2]) for v in ξ_filt]
        N      = length(pkeys)
        zLo    = Inference.priorZScores(SVector{N,Float64}(first.(ξ_q)), seed.pr)
        zHi    = Inference.priorZScores(SVector{N,Float64}(last.(ξ_q)), seed.pr)

        # calculate the quantiles of the remaining quantities
        llLo, llHi         = quantile(llFilt, [q1, q2])
        scaleLo, scaleHi   = quantile(scaleFilt, [q1, q2])
        bkgrndLo, bkgrndHi = quantile(bkgrndFilt, [q1, q2])
        c1Lo, c1Hi         = quantile(c1Filt, [q1, q2])
        chisqLo, chisqHi   = quantile(chisqFilt, [q1, q2])

        # returns a tuple of (low, high) bounds; fails loudly
        function mapBounds(lo, hi, x)
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
            "logDensity" => Dict{String,Tuple{Float64,Float64}}(
                "quantiles" => (llLo, llHi),
                "bounds"    => mapBounds(llLo, llHi, llFilt),
            ),
            "scale" => Dict{String,Tuple{Float64,Float64}}(
                "quantiles" => (scaleLo, scaleHi),
                "bounds"    => mapBounds(scaleLo, scaleHi, scaleFilt),
            ),
            "bkgrndCorr" => Dict{String,Tuple{Float64,Float64}}(
                "quantiles" => (bkgrndLo, bkgrndHi),
                "bounds"    => mapBounds(bkgrndLo, bkgrndHi, bkgrndFilt),
            ),
            "exclVolCorr" => Dict{String,Tuple{Float64,Float64}}(
                "quantiles" => (c1Lo, c1Hi),
                "bounds"    => mapBounds(c1Lo, c1Hi, c1Filt),
            ),
            "chisqRed" => Dict{String,Tuple{Float64,Float64}}(
                "quantiles" => (chisqLo, chisqHi),
                "bounds"    => mapBounds(chisqLo, chisqHi, chisqFilt),
            ),
        )
        for (k, key) in enumerate(pkeys)
            lo, hi = ξ_q[k]
            params[key] = Dict{String,Tuple{Float64,Float64}}(
                "quantiles" => (lo, hi),
                "bounds"    => mapBounds(lo, hi, ξ_filt[k]),
                "z"         => (zLo[k], zHi[k]),
            )
        end

        # curve is Q x I_low(Q) x I_hi(Q)
        qvals = seed.fw.qvals
        curveQuantiles, curveBounds = _curveBands(qvals, curves, q1, q2)

        curve = Dict{String,Matrix{Float64}}(
            "quantiles" => curveQuantiles,
            "bounds"    => curveBounds,
        )

        res = (fit, divergenceRate, map, (params, curve))
    end

    tock!(seed.timing, :sampling, 1, "MAP + quantiles", tPost)
    return res

end
