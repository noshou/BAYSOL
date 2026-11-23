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
The raw points the measured χ² sums over: those inside the fitted range, `q[1] ≤ qRaw ≤
q[end]` (the first and last bin centres). A raw point below the first fitted bin or above
the last is one the fit never used, and the model there is only an extrapolation, so
an unusable point (negative intensity with a large σ at the beam stop) would count
tens to hundreds of σ² against a model that was never fitted to it, and the χ² would
not be comparable with the depositor's, which covers the program's own range.

# Returns
- `BitVector`, one entry per raw point; `true` where the point enters the χ².
"""
function _chisqMask(sh::Shannon.ShannonInfo)::BitVector
    return (sh.qRaw .>= first(sh.q)) .& (sh.qRaw .<= last(sh.q))
end

"""
The reduced χ² of the model curve `y` (on the fitted grid of `sh`) against
the measured curve: `y` is interpolated onto the measured q points
([`Shannon.modelOnRaw`](@ref BAYSOL.Utils.Shannon.modelOnRaw)) and the
sum of squared normalized residuals over the raw points inside the fitted range
([`_chisqMask`](@ref)) is divided by their number less the three parameters fitted
to the curve by minimization (scale, background and the excluded-volume correction
c1). This is the χ² on the grid a program such as CRYSOL or FoXS evaluates,
whatever binning the fit used.
"""
function _chisqMeasured(sh::Shannon.ShannonInfo, y::AbstractVector{<:Real})::Float64
    use = _chisqMask(sh)
    r = ((sh.iRaw .- Shannon.modelOnRaw(sh, y)) ./ sh.σ_raw)[use]
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
    use = findall(_chisqMask(sh))
    M = Shannon.rawInterpolation(sh)[use, :]
    iUse = sh.iRaw[use]
    σUse = sh.σ_raw[use]
    nUse = length(use)
    out = Vector{Float64}(undef, size(curves, 2))
    block = max(1, 1_000_000 ÷ max(nUse, 1))
    for cols in Iterators.partition(axes(curves, 2), block)
        R = (iUse .- M * curves[:, cols]) ./ σUse
        out[cols] = vec(sum(abs2, R; dims = 1)) ./ (nUse - 3)
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
    rerun the sampler once, longer, always adapting again and from derived seeds, when
    the run does not count as converged (R̂ not below [`Inference.RHAT_OK`](@ref), an
    ESS not above [`Inference.ESS_MIN`](@ref), or either not computable); see
    [`Inference.infer`](@ref). If the run is still not converged, `runModel` throws
    [`Inference.NotConvergedError`](@ref) and nothing is reported. `retry = false`
    skips both the rerun and the error: the run is only flagged in its summary.
- `kinkFallback::Bool=true` (a developer switch, not a setting): when the profiled c1 has a
    kink and the sampled-c1 run then misses a gate, run the profiled four-parameter run
    once without the kink watch and keep it if it passes (LOG rows `c1KinkFallback`,
    `c1KinkProblems`).
- `ladder=LADDER` (the setting `LADDER`; needs `retry`): when a run does not converge
    after its retry and the fallback, the failure is classified from the failed
    attempt's own diagnostics (`stepCollapse`, `splitChains`, `divergent`,
    `structural`, `marginal` or `generic`, see [`LADDER`](@ref) and `_failureClass`)
    and the fit is rerun with the next rung of that class, which changes only the
    settings it names in `overrides` (`LADDER_OVERRIDABLE` lists what a rung may
    change); the reruns stop when one passes or the class has no unused rung left. A
    map from class to a list of `(name, overrides)` rungs (it replaces only the classes
    it names), a JSON text of it, the path of a JSON file, `true` (the default ladder),
    `false` or `"off"`. The winning rung, the class that triggered each rerun and every
    failed attempt are in the LOG rows `ladder`, `ladderClass`, `ladderAttempts`,
    `ladderRungs` and `ladderRung`. Only when no rung is left does `runModel` throw.
- `callerSet=nothing`: the names of the settings the caller set (a set of `Symbol`s, e.g.
    `Set([:RETRY_N_DRAWS])`). A rung never changes `CHAIN_START_RADII`, `RETRY_N_ADAPT` or
    `RETRY_N_DRAWS` when that name is in it, even if the value equals the default;
    `runProject` fills it from the keywords, the settings file and the model's own
    settings. With `nothing` a value still at its default counts as unset.
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
    kinkFallback::Bool = true,
    ladder = LADDER,
    callerSet::Union{Nothing,AbstractSet{Symbol}} = nothing,
)::Union{
    Tuple{Inference.Inferred,Float64,MAPResult,QuantileResult},
    Tuple{Inference.Inferred,Float64,Nothing,Nothing},
}
    kw = (;
        sigma,
        δ,
        rngSeed,
        nChains,
        retry,
        retryNAdapt,
        retryNDraws,
        chainStartRadii,
        optimumChainCap,
        optimumMinChains,
        optimumChainRadius,
        optimumChainFraction,
        mapMaxIter,
        mapNStarts,
        mapFSuccessive,
        mapOptimaKept,
        mapJitterRadii,
        mapJitterDirections,
        mapJitterMaxOptima,
        mapJitterWithinNats,
        basinRestartNats,
        harvestCover,
        harvestDivergent,
        kinkFallback,
        sampleC1 = false,
    )
    return _runLadder(
        seed, nSamples, nAdapt, kw, _checkedLadder(ladder); callerSet,
    )
end


# The settings of a rung, by the keyword of `runModel` that carries each (the rows of
# `SETTING_KEYWORDS` of `runModel`). `N_ADAPT` and `N_DRAWS` are the positional arguments
# (`nSamples = nAdapt + nDraws`); `RNG_SEED_STEP` and `SAMPLE_C1` are ladder-only keys.
const _RUNG_KEYWORD = Dict(
    r.setting => r.keyword for r in SETTING_KEYWORDS if r.entry === :runModel
)

# The settings a rung changes only when the caller did not set them (a script's own
# `retryNDraws = 8000` or `chainStartRadii` stays), with their defaults. Which settings the
# caller set is `callerSet` of `runModel` (names of settings; `runProject` passes it: the
# keywords, the settings file and the model's own settings). A direct caller of `runModel`
# that gives no `callerSet` is judged by the value: one left at its default is unset, so
# an explicit default looks unset there.
const _CALLER_FIRST = Dict(
    :CHAIN_START_RADII => Inference.CHAIN_START_RADII,
    :RETRY_N_ADAPT => Inference.RETRY_N_ADAPT,
    :RETRY_N_DRAWS => Inference.RETRY_N_DRAWS,
)

_sameValue(a, b) = a isa Union{Tuple,AbstractVector} ? Tuple(a) == Tuple(b) : a == b

# The thresholds that classify a failed attempt (`_failureClass`). They are heuristics
# read off the benchmark runs and the README fix ladder, not settings: the evidence for
# each, and what no run has checked, is in `src/inference/README.md`.

"""
The worst R̂ from which a failure counts as far from converged, not marginal: 1.05. The
README's marginal band is R̂ 1.01 to 1.05 (SASDMS6, SASDDG7 at 1.045 with a bulk ESS of
237), and the split-chain and collapsed-step cases it names sit well above it (SASDVA2 1.57
to 1.82).
"""
const LADDER_RHAT_FAR = 1.05

"""
The median adapted step size below which the step counts as collapsed: 0.01. The README
gives about 0.002 for a collapsed step (SASDMC6 before its fix, tree depth 10) against 0.1
to 0.3 for a healthy one; 0.01 is five times above the collapse and ten times below the
healthy step. Not yet checked against LOGs (the `stepSize` row is new).
"""
const LADDER_COLLAPSE_STEP = 0.01

"""
The mean tree depth that counts as at the limit (the sampler's maximum depth is 10): 8,
the supporting signal of a collapse when R̂ is far and no step size is known. Depth alone
is no collapse: SASDP74 passes its gates at a mean depth of 9.8.
"""
const LADDER_COLLAPSE_DEPTH = 8.0

"""
The divergent share from which divergences that survived a raised `TARGET_ACCEPT` count as
structural, not a step too large: 1 %. The README's structural entries (SASDWS5, SASDM96)
diverge at 1.3 % to 2 % at δ 95, 98 and 99; the near-gate failures of the 2026-11-18
validation (SASDGA7, SASDPV7, SASDVE2) were 0.1 % to 0.43 % and δ 99 cleared 14 of 15.
"""
const LADDER_STRUCTURAL_SHARE = 0.01

"""
The failure `summary` of an attempt as a map of what `_failureClass` reads: the fit's own
diagnostics after its warm-up (`rhat`, `ess` the smaller of the bulk and tail ESS,
`divergentShare`, `treeDepthAvg`, `treeDepthMax`, `meanNSteps`, `meanAccept`, `stepSize`
the median over the chains of the adapted step size, `stepSizeMin`, `modes`).

# Returns
- A `NamedTuple`, or `nothing` when the fit has no draws after the warm-up.

# Exceptions
- None.
"""
function _attemptSummary(fit::Inference.Inferred)
    d = fit.diagnostics
    kept = findall(>(d.nAdapt), fit.iteration)
    isempty(kept) && return nothing
    st = fit.stats[kept]
    steps = _chainStepSizes(st, fit.chain[kept])
    return (;
        rhat = Inference._worstRhat(d),
        ess = min(Inference._worstEss(d.ess), Inference._worstEss(d.essTail)),
        divergentShare = count(s -> s.numerical_error, st) / length(st),
        treeDepthAvg = mean(s -> s.tree_depth, st),
        treeDepthMax = maximum(s -> s.tree_depth, st),
        meanNSteps = mean(s -> s.n_steps, st),
        meanAccept = mean(s -> s.acceptance_rate, st),
        stepSize = median(steps),
        stepSizeMin = minimum(steps),
        modes = length(d.modeWeight),
    )
end

"""
The class of a failed attempt, from its `summary` (see `_attemptSummary`), in this order
(the c1 kink is handled inside the attempt and never gets here):

1. `:stepCollapse`: R̂ not below the gate and the median step size below
   `LADDER_COLLAPSE_STEP`, or R̂ at `LADDER_RHAT_FAR` and the mean tree depth at
   `LADDER_COLLAPSE_DEPTH`;
2. `:splitChains`: R̂ at `LADDER_RHAT_FAR`, more than one mode, an ESS not above the gate
   (and, by the order, no collapse);
3. `:divergent`: a divergent share at the gate (`MAX_DIVERGENT_RATE`) with R̂ below
   `LADDER_RHAT_FAR`; `:structural` instead when `deltaRaised` (an earlier rung of this
   walk raised `TARGET_ACCEPT`) and the share is at `LADDER_STRUCTURAL_SHARE`;
4. `:marginal`: R̂ below `LADDER_RHAT_FAR`, no divergence at the gate;
5. `:generic`: everything else, and an attempt without a summary.

# Returns
- The class as a `Symbol` of `LADDER_CLASSES`.

# Exceptions
- None.
"""
function _failureClass(summary; deltaRaised::Bool = false)
    summary === nothing && return :generic
    s = summary
    far = s.rhat >= LADDER_RHAT_FAR
    gate = s.rhat >= Inference.RHAT_OK
    collapsed = s.stepSize < LADDER_COLLAPSE_STEP
    deep = far && s.treeDepthAvg >= LADDER_COLLAPSE_DEPTH
    ((gate && collapsed) || deep) && return :stepCollapse
    far && s.modes > 1 && s.ess <= Inference.ESS_MIN && return :splitChains
    if s.divergentShare >= Inference.MAX_DIVERGENT_RATE && !far
        deltaRaised && s.divergentShare >= LADDER_STRUCTURAL_SHARE && return :structural
        return :divergent
    end
    far || return :marginal
    return :generic
end

"The name of a rung: its own, else its overrides as `KEY=value` words."
function _rungLabel(r)
    isempty(r.name) || return r.name
    return join(("$k=$(v)" for (k, v) in pairs(r.overrides)), " ")
end

"""
The ladder as one readable line (the LOG row `ladderRungs`): per failure class, its rungs
by name (`_rungLabel`), classes separated by ` | `, e.g.
`stepCollapse: delta 70, delta 35 | splitChains: starts (2,4,6), close starts + longer`.
The overrides of a rung are in the ladder definition (`LADDER`) and the attempts
that ran are in the rows `ladder` and `ladderAttempts`, so they are not repeated here.
"""
function _ladderText(ladder)::String
    return join(
        ("$class: " * join(_rungLabel.(rungs), ", ") for (class, rungs) in pairs(ladder)),
        " | ",
    )
end

"""
The arguments of `runModel` that the rung `rung` changes: the keywords `kw`, `nSamples`
and `nAdapt` of the caller, with the overrides of the rung applied. `CHAIN_START_RADII`,
`RETRY_N_ADAPT` and `RETRY_N_DRAWS` are applied only when the caller did not set that
setting (`_CALLER_FIRST`): its name is not in `callerSet`, or, when `callerSet` is
`nothing`, its value is still the default; `RNG_SEED_STEP` is added to
`rngSeed` (nothing when the seed is `nothing`, a fresh draw); `SAMPLE_C1` sets `sampleC1`.

# Returns
- `(kw, nSamples, nAdapt)`.
"""
function _applyRung(
    rung, kw::NamedTuple, nSamples::Int, nAdapt::Int; callerSet = nothing,
)
    draws = nSamples - nAdapt
    for (name, v) in pairs(rung.overrides)
        if name === :RNG_SEED_STEP
            kw.rngSeed === nothing || (kw = merge(kw, (; rngSeed = kw.rngSeed + v)))
        elseif name === :SAMPLE_C1
            kw = merge(kw, (; sampleC1 = v))
        elseif name === :N_ADAPT
            nAdapt = v
        elseif name === :N_DRAWS
            draws = v
        elseif haskey(_CALLER_FIRST, name)
            # the caller's own value wins: only a setting the caller did not set is replaced
            key = _RUNG_KEYWORD[name]
            unset =
                callerSet === nothing ? _sameValue(kw[key], _CALLER_FIRST[name]) :
                !(name in callerSet)
            unset && (kw = merge(kw, NamedTuple{(key,)}((v,))))
        else
            kw = merge(kw, NamedTuple{(_RUNG_KEYWORD[name],)}((v,)))
        end
    end
    return kw, nAdapt + draws, nAdapt
end

"""
Run `runner` (one attempt of [`runModel`](@ref), `_runModelOnce`) and, when the run does
not converge, walk the ladder `ladder` (a map from failure class to rungs, see
[`LADDER`](@ref)) before giving up: the failed attempt is classified (`_failureClass`)
and the next unused rung of that class is run; the class is taken anew from each failed
rerun, so the walk can change class. The walk ends when a rerun passes or the class the
last failure falls into has no unused rung left (every rung is used at most once, so it
always ends). A rung that would
change nothing for the caller's settings is skipped. Every attempt, the class that
triggered it, its settings and why it failed are in the run's timing info (LOG rows
`ladder`, `ladderClass`, `ladderAttempts`, `ladderRungs`, `ladderRung`); when no rung is
left a [`Inference.NotConvergedError`](@ref) is thrown, with the attempts listed and the
last attempt's summary. With the ladder off, or with `retry` off, the base run's error is
rethrown as it is.

# Returns
- What `runModel` returns.

# Exceptions
- [`Inference.NotConvergedError`](@ref) when no rung is left.
"""
function _runLadder(
    seed, nSamples, nAdapt, kw::NamedTuple, ladder; runner = _runModelOnce,
    callerSet = nothing,
)
    active = kw.retry && any(!isempty, ladder)
    attempts = String[]
    classes = String[]
    sbuf = Inference.statBuffer(seed.timing)
    Inference.statReset!(sbuf)
    function record(label, e)
        push!(attempts, "$label: " * join(e.problems, "; "))
        Inference.statNext!(sbuf, "not converged at $label: " * join(e.problems, "; "))
        return nothing
    end
    err = nothing
    try
        res = runner(seed, nSamples, nAdapt; kw...)
        _noteLadder(seed, attempts, classes, "base", 0, ladder)
        return res
    catch e
        e isa Inference.NotConvergedError && active || rethrow()
        record("base", e)
        err = e
    end
    next = Dict(c => 1 for c in LADDER_CLASSES)
    deltaRaised = false
    reruns = 0
    while true
        class = _failureClass(err.summary; deltaRaised)
        rungs = ladder[class]
        # the next rung of the class that changes something for this caller
        rung = nothing
        applied = nothing
        while next[class] <= length(rungs) && rung === nothing
            r = rungs[next[class]]
            next[class] += 1
            a = _applyRung(r, kw, nSamples, nAdapt; callerSet)
            (a[1] == kw && a[2] == nSamples && a[3] == nAdapt) && continue
            rung, applied = r, a
        end
        rung === nothing && break
        kw2, n2, a2 = applied
        reruns += 1
        label = _rungLabel(rung)
        push!(classes, String(class))
        Inference.statLabel!(sbuf, "ladder rung " * label, "failure class " * String(class);
            class = String(class), rung = label)
        haskey(rung.overrides, :TARGET_ACCEPT) &&
            rung.overrides.TARGET_ACCEPT > kw.δ && (deltaRaised = true)
        @warn "not converged; ladder rung" class label
        try
            res = runner(seed, n2, a2; kw2...)
            _noteLadder(seed, attempts, classes, label, reruns, ladder)
            return res
        catch e
            e isa Inference.NotConvergedError || rethrow()
            record("$label [$class]", e)
            err = e
        end
    end
    _noteLadder(seed, attempts, classes, "failed", -1, ladder)
    throw(Inference.NotConvergedError(vcat(["ladder exhausted:"], attempts), err.summary))
end

function _noteLadder(seed, attempts, classes, outcome, rung, ladder)
    seed.timing === nothing && return nothing
    seed.timing.info["ladder"] = outcome
    seed.timing.info["ladderClass"] = join(classes, " | ")
    seed.timing.info["ladderAttempts"] = join(attempts, " | ")
    seed.timing.info["ladderRungs"] = _ladderText(ladder)
    seed.timing.info["ladderRung"] = rung
    return nothing
end

function _runModelOnce(
    seed::Inference.Seed,
    nSamples::Int64,
    nAdapt::Int64;
    sigma, δ, rngSeed, nChains, retry,
    retryNAdapt,
    retryNDraws,
    chainStartRadii,
    optimumChainCap,
    optimumMinChains,
    optimumChainRadius,
    optimumChainFraction,
    mapMaxIter,
    mapNStarts,
    mapFSuccessive,
    mapOptimaKept,
    mapJitterRadii,
    mapJitterDirections,
    mapJitterMaxOptima,
    mapJitterWithinNats,
    basinRestartNats,
    harvestCover,
    harvestDivergent,
    kinkFallback,
    sampleC1::Bool,
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
    # c1 is profiled; if that profile has a kink the run stops (`KinkDetected`, after the
    # warm-up) and c1 is sampled as a fifth parameter instead, the LOG row `c1Kink`
    seed.timing === nothing || (seed.timing.info["c1Kink"] = false)
    runInfer =
        s -> Inference.infer(s, nSamples, nAdapt; δ = δ, rngSeed = rngSeed,
            nChains = nChains, retry = retry, options = options)
    seed4 = seed
    sampledC1 = false
    if sampleC1        # a ladder rung (`SAMPLE_C1`): c1 is sampled from the start
        seed = Inference.sampleC1(seed)
        sampledC1 = true
        seed.timing === nothing || (seed.timing.info["c1Kink"] = true)
    end
    fitUnfiltered = try
        runInfer(seed)
    catch e
        e isa Inference.KinkDetected || rethrow()
        @warn "the profiled c1 has a kink; sampling c1 as a fifth parameter"
        sb = Inference.statBuffer(seed.timing)
        Inference.statStopped!(sb, "KinkDetected: the profiled c1 is kinked")
        Inference.statStages!(sb, seed.timing)
        Inference.statNext!(sb, "restart with c1 sampled as a fifth parameter")
        Inference.statLabel!(sb, "sampled-c1 restart", "KinkDetected";
            class = "kink", rung = "c1 sampled as a fifth parameter")
        seed = Inference.sampleC1(seed)
        sampledC1 = true
        seed.timing === nothing || (seed.timing.info["c1Kink"] = true)
        runInfer(seed)
    end
    # The kink detector can fire on a profile whose sampled-c1 run then misses a gate. If
    # the profiled (four-parameter) run, without the watch, passes them, it is the fit
    # (the kink is recorded in the LOG: `c1KinkFallback`, `c1KinkProblems`).
    gateProblems =
        f -> begin
            ps = Inference._convergenceProblems(f.diagnostics)
            kept = f.stats[findall(>(f.diagnostics.nAdapt), f.iteration)]
            nDiv = count(st -> st.numerical_error, kept)
            if !isempty(kept) && nDiv >= Inference.MAX_DIVERGENT_RATE * length(kept)
                push!(
                    ps,
                    "$(round(100 * nDiv / length(kept); digits = 2)) % of the " *
                    "transitions diverged",
                )
            end
            return ps
        end
    if retry && sampledC1 && kinkFallback
        problems = gateProblems(fitUnfiltered)
        if !isempty(problems)
            @warn "the sampled-c1 run missed its gates; trying the profiled run" problems
            plain = Inference.SamplerOptions(; ck..., watchKink = false)
            sb = Inference.statBuffer(seed.timing)
            Inference.statNext!(
                sb,
                "profiled run without the kink watch: " *
                join(problems, "; "),
            )
            Inference.statLabel!(
                sb, "profiled fallback", "the sampled-c1 run missed its gates";
                class = "convergence", rung = "profiled run without the kink watch",
            )
            alt = Inference.infer(seed4, nSamples, nAdapt; δ = δ, rngSeed = rngSeed,
                nChains = nChains, retry = retry, options = plain)
            if isempty(gateProblems(alt))
                fitUnfiltered = alt
                seed = seed4
                Inference.statKeep!(sb, Inference.statAttempts(sb),
                    "the profiled fallback passed the gates the sampled-c1 run missed")
                if seed.timing !== nothing
                    seed.timing.info["c1Kink"] = false
                    seed.timing.info["c1KinkFallback"] = true
                    seed.timing.info["c1KinkProblems"] = join(problems, "; ")
                end
            else
                seed.timing === nothing ||
                    (
                        seed.timing.info["c1KinkFallbackFailed"] =
                            join(gateProblems(alt), "; ")
                    )
            end
        end
    end
    if retry
        problems = Inference._convergenceProblems(fitUnfiltered.diagnostics)
        isempty(problems) ||
            throw(Inference.NotConvergedError(problems, _attemptSummary(fitUnfiltered)))
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
    if retry && diverged >= Inference.MAX_DIVERGENT_RATE * length(fit.stats)
        pct = round(100 * diverged / length(fit.stats); digits = 2)
        limit = 100 * Inference.MAX_DIVERGENT_RATE
        throw(
            Inference.NotConvergedError(
                ["$pct % of the transitions diverged, not below $limit %"],
                _attemptSummary(fitUnfiltered),
            ),
        )
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
        pkeys = Inference.paramKeys(seed.pr, length(ξ_map))
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
