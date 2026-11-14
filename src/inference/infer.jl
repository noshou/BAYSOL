# SPDX-License-Identifier: LGPL-3.0-or-later

# Everything about a run: the chains it runs (where they start, which are pooled,
# the convergence statistics), the data it starts from (`Seed`, `seedSampler`),
# what it returns (`Inferred`), the entry point `infer`, and the NUTS chains
# themselves (starts, the sampler per chain, the re-profiled curves).

# ---------------------------------------------------------------------------
#   Chains: starts, pooling, convergence statistics
# ---------------------------------------------------------------------------

using MCMCDiagnosticTools: MCMCDiagnosticTools
using Statistics: mean

# ---------------------------------------------------------------------------
#   SamplerOptions: the settings of the chains, the MAP search and the harvest
# ---------------------------------------------------------------------------

"""
    SamplerOptions(; retryNAdapt, retryNDraws, chainStartRadii, ...)

The tunable settings of [`infer`](@ref) that are not its own arguments, gathered in one
immutable value that is passed down to where they are read, so every field has the type
of its setting and the sampler's code stays type-stable. Every keyword is named after its
constant and defaults to it, so `SamplerOptions()` is the sampler as it has always run.
[`runModel`](@ref BAYSOL.Pipeline.runModel) builds one from its keywords of the same
names, after the checks of `loadSettings`; the
constructor itself checks nothing.

# Fields
- `retryNAdapt::Int`, `retryNDraws::Int`: warm-up and post-warm-up iterations per chain
    of the rerun ([`RETRY_N_ADAPT`](@ref), [`RETRY_N_DRAWS`](@ref)).
- `chainStartRadii::Vector{Float64}`: [`CHAIN_START_RADII`](@ref).
- `optimumChainCap::Int`, `optimumMinChains::Int`, `optimumChainRadius::Float64`,
    `optimumChainFraction::Float64`: [`OPTIMUM_CHAIN_CAP`](@ref),
    [`OPTIMUM_MIN_CHAINS`](@ref), [`OPTIMUM_CHAIN_RADIUS`](@ref),
    [`OPTIMUM_CHAIN_FRACTION`](@ref).
- `mapMaxIter::Int`, `mapNStarts::Int`, `mapFSuccessive::Int`,
    `mapOptimaKept::Int`: [`MAP_MAX_ITER`](@ref), [`MAP_N_STARTS`](@ref),
    [`MAP_F_SUCCESSIVE`](@ref), [`MAP_OPTIMA_KEPT`](@ref).
- `mapJitterRadii::Vector{Float64}`, `mapJitterDirections::Int`,
    `mapJitterMaxOptima::Int`, `mapJitterWithinNats::Float64`:
    [`MAP_JITTER_RADII`](@ref), [`MAP_JITTER_DIRECTIONS`](@ref),
    [`MAP_JITTER_MAX_OPTIMA`](@ref), [`MAP_JITTER_WITHIN_NATS`](@ref).
- `basinRestartNats::Float64`: [`BASIN_RESTART_NATS`](@ref).
- `harvestCover::Int`, `harvestDivergent::Int`: [`HARVEST_COVER`](@ref),
    [`HARVEST_DIVERGENT`](@ref).

# Returns
- A `SamplerOptions` (the constructor converts each value to its field's type).

# Exceptions
- `MethodError`/`InexactError` if a value cannot be converted to its field's type.
"""
struct SamplerOptions
    retryNAdapt::Int
    retryNDraws::Int
    chainStartRadii::Vector{Float64}
    optimumChainCap::Int
    optimumMinChains::Int
    optimumChainRadius::Float64
    optimumChainFraction::Float64
    mapMaxIter::Int
    mapNStarts::Int
    mapFSuccessive::Int
    mapOptimaKept::Int
    mapJitterRadii::Vector{Float64}
    mapJitterDirections::Int
    mapJitterMaxOptima::Int
    mapJitterWithinNats::Float64
    basinRestartNats::Float64
    harvestCover::Int
    harvestDivergent::Int
end

function SamplerOptions(;
    retryNAdapt::Integer = RETRY_N_ADAPT,
    retryNDraws::Integer = RETRY_N_DRAWS,
    chainStartRadii = CHAIN_START_RADII,
    optimumChainCap::Integer = OPTIMUM_CHAIN_CAP,
    optimumMinChains::Integer = OPTIMUM_MIN_CHAINS,
    optimumChainRadius::Real = OPTIMUM_CHAIN_RADIUS,
    optimumChainFraction::Real = OPTIMUM_CHAIN_FRACTION,
    mapMaxIter::Integer = MAP_MAX_ITER,
    mapNStarts::Integer = MAP_N_STARTS,
    mapFSuccessive::Integer = MAP_F_SUCCESSIVE,
    mapOptimaKept::Integer = MAP_OPTIMA_KEPT,
    mapJitterRadii = MAP_JITTER_RADII,
    mapJitterDirections::Integer = MAP_JITTER_DIRECTIONS,
    mapJitterMaxOptima::Integer = MAP_JITTER_MAX_OPTIMA,
    mapJitterWithinNats::Real = MAP_JITTER_WITHIN_NATS,
    basinRestartNats::Real = BASIN_RESTART_NATS,
    harvestCover::Integer = HARVEST_COVER,
    harvestDivergent::Integer = HARVEST_DIVERGENT,
)
    return SamplerOptions(
        retryNAdapt, retryNDraws, collect(Float64, chainStartRadii),
        optimumChainCap, optimumMinChains, optimumChainRadius,
        optimumChainFraction, mapMaxIter, mapNStarts, mapFSuccessive,
        mapOptimaKept, collect(Float64, mapJitterRadii), mapJitterDirections,
        mapJitterMaxOptima, mapJitterWithinNats, basinRestartNats,
        harvestCover, harvestDivergent,
    )
end

"""
The nominal signed distance from the MAP, in posterior standard deviations, at which
chain `k` of `n` starts: a single chain at the MAP (0); with several, chains 1 and 2
both at the MAP (two independent chains of their own random streams from the same point:
independent effective sample size within the main mode and a baseline for R̂ there), and
chains 3 and up in mirrored pairs at the radii of [`CHAIN_START_RADII`](@ref) (the first
of a pair positive, the second negative: the same random direction, opposite sides).
`radii` replaces [`CHAIN_START_RADII`](@ref) (a non-empty vector or tuple).

# Returns
- `Float64`.

# Exceptions
- None.
"""
function chainRadius(
    k::Int, n::Int, radii::Union{AbstractVector{<:Real},Tuple} = CHAIN_START_RADII,
)::Float64
    (n == 1 || k ≤ 2) && return 0.0
    r = radii[min((k - 1) ÷ 2, length(radii))]
    return isodd(k) ? r : -r
end


"""
Convergence statistics of the pooled chains' post-warm-up draws, from MCMCDiagnosticTools.jl
(Vehtari et al., 2021): the rank-normalized split R̂ (`rhat(kind = :rank)`: the larger of
the value on the rank-normalized draws, which asks whether the chains agree in location, and
on the rank-normalized draws folded around the median, which asks whether they agree in
scale and tails), the bulk effective sample size (how many independent draws the centre of
the distribution is worth) and the tail effective sample size (the same for the 5% and 95%
quantiles, which the report's intervals and curve bands are made of). Every chain is split
in halves first, so a chain that drifts shows up as two that disagree.

# Arguments
- `x::AbstractArray{<:Real,3}`: the draws, `draws × chains × quantities`.

# Returns
    -   `NamedTuple` `(rhat, ess, essTail)` of vectors with one entry per quantity; all
        `NaN` when a chain has fewer than 8 draws (the stats need at least 4 per half).

# Exceptions
- None.
"""
function convergence(x::AbstractArray{<:Real,3})
    n, _, q = size(x)
    n < 8 && return (rhat = fill(NaN, q), ess = fill(NaN, q), essTail = fill(NaN, q))
    return (rhat = vec(MCMCDiagnosticTools.rhat(x; kind = :rank)),
        ess = vec(MCMCDiagnosticTools.ess(x; kind = :bulk)),
        essTail = vec(MCMCDiagnosticTools.ess(x; kind = :tail)))
end

"""
    OptimumReport

An optimum of the posterior that carries mass (a Laplace share of at least
[`OPTIMUM_MIN_SHARE`](@ref)), as [`infer`](@ref) found it: by the MAP search, by its
jittered starts, or by L-BFGS from the draws of the first round of chains.

# Fields
- `ξ::Vector{Float64}`: the optimum, in the sampled parameters (ρₑ, δρ₁, δρ₂, δρ₃).
- `logmass::Float64`, `share::Float64`: its Laplace log-mass and its share of the
    total over the optima with a mass.
- `chains::Int`: chains at it at the end (chains with at least
    [`OPTIMUM_CHAIN_FRACTION`](@ref) of their draws within [`OPTIMUM_CHAIN_RADIUS`](@ref)
    of it under its own Hessian).
- `started::Int`: of those, how many `infer` started there because fewer than
    [`OPTIMUM_MIN_CHAINS`](@ref) chains were.
"""
struct OptimumReport
    ξ::Vector{Float64}
    logmass::Float64
    share::Float64
    chains::Int
    started::Int
end

"""
    ChainDiagnostics

What the chains of one [`infer`](@ref) call looked like.

# Fields
- `nChains::Int`: chains run, those started at optima included (the last `nExtra`).
- `startScale::Vector{Float64}`: per chain, the signed distance of its start
    from the MAP in posterior standard deviations (negative: the mirrored chain
    of a pair; 0: the MAP): the distance actually used, after any halving, see
    [`CHAIN_JITTER_MAX_HALVINGS`](@ref) and [`chainRadius`](@ref).
- `pooled::Vector{Bool}`: per chain, whether it was pooled.
- `reason::Vector{String}`: per chain, `"ok"` or why it was not pooled.
- `rhat::Vector{Float64}`: [`convergence`](@ref)'s R̂ over each mode's
    chains' post-warm-up draws (the worst of the modes that keep draws,
    see [`MODE_NEGLIGIBLE`](@ref)), one entry per coordinate of ξ followed
    by log π (with one chain in a mode it compares its two halves).
- `ess::Vector{Float64}`: the bulk effective sample size, same layout.
- `essTail::Vector{Float64}`: the tail effective sample size, same layout.
- `rewhitened::Float64`: 0, or the nats by which the first round of chains
    found a better basin than the MAP search ([`BASIN_RESTART_NATS`](@ref)):
    the sampler was then re-whitened there and the chains rerun, and these
    diagnostics are those of the second round.
- `mode::Vector{Int}`: per chain, the posterior mode it settled in (chains
    that agree, [`chainModes`](@ref)); 0 for a chain that was not pooled.
- `modeWeight::Vector{Float64}`: per mode, its share of
    the posterior mass; the pooled draws carry these shares.
- `modeLogmass::Vector{Float64}`: per mode, the bridge-sampling
    estimate of log mass ([`bridgeLogmass`](@ref)).
- `modeErr::Vector{Float64}`: per mode, its approximate standard error in nats.
- `weightsUncertain::Bool`: whether a bridge-sampling error was too large to apply
    the weights ([`weightsUncertain`](@ref)): the chains of the modes that can matter
    were then pooled as they came, and `modeWeight` is each mode's share of those
    chains (0 for a mode that is negligible even at its most optimistic estimate).
- `nAdapt::Int`: warm-up iterations per chain of the run these draws come from (the
    caller's `nAdapt`, or [`RETRY_N_ADAPT`](@ref) when the rerun was kept).
- `firstRhat::Float64`: the worst R̂ of the first run when [`infer`](@ref) reran
    (see [`RHAT_OK`](@ref)); NaN when it did not.
- `retryKept::Bool`: whether the rerun's draws are the ones returned (false if there
    was no rerun, or the first run's R̂ was no worse).
- `nExtra::Int`: chains started at an optimum that carries mass but had fewer than
    [`OPTIMUM_MIN_CHAINS`](@ref) chains at it after the first round (they are the last
    `nExtra` chains; `startScale` is the distance of the optimum from the MAP).
- `optima::Vector{OptimumReport}`: the optima that carry mass, the best first.
"""
struct ChainDiagnostics
    nChains::Int
    startScale::Vector{Float64}
    pooled::Vector{Bool}
    reason::Vector{String}
    rhat::Vector{Float64}
    ess::Vector{Float64}
    essTail::Vector{Float64}
    rewhitened::Float64
    mode::Vector{Int}
    modeWeight::Vector{Float64}
    modeLogmass::Vector{Float64}
    modeErr::Vector{Float64}
    weightsUncertain::Bool
    nAdapt::Int
    firstRhat::Float64
    retryKept::Bool
    nExtra::Int
    optima::Vector{OptimumReport}
end

"""
The largest R̂ of `d`; `Inf` if there is none or any is NaN (an R̂ that could not be
computed counts as not converged), so that a run that could not be judged never beats one
that could.
"""
function _worstRhat(d::ChainDiagnostics)
    (isempty(d.rhat) || any(isnan, d.rhat)) && return Inf
    return maximum(d.rhat)
end

"""
The smallest of the effective sample sizes `v`; NaN if there are none or any is NaN (an ESS
that could not be computed counts as not converged).
"""
_worstEss(v::AbstractVector) = (isempty(v) || any(isnan, v)) ? NaN : minimum(v)

"""
Why a run does not count as converged, from its worst R̂, smallest bulk ESS and smallest
tail ESS: R̂ above [`RHAT_OK`](@ref) or not computable, or an ESS below [`ESS_MIN`](@ref) or
not computable. NaN means "could not be computed" and is never read as fine.

# Returns
- `Vector{String}`: one sentence per problem, empty for a converged run.
"""
function _convergenceProblems(rhat::Real, ess::Real, essTail::Real)
    out = String[]
    if !isfinite(rhat)
        push!(out, "R̂ could not be computed (too few draws, or a constant quantity)")
    elseif rhat > RHAT_OK
        push!(out, "the worst R̂, $(round(rhat; digits = 3)), is above $RHAT_OK")
    end
    for (name, v) in (("bulk", ess), ("tail", essTail))
        if isnan(v)
            push!(out, "the $name effective sample size could not be computed")
        elseif v < ESS_MIN
            essText = round(v; digits = 1)
            push!(out, "the smallest $name ESS, $essText, is below $ESS_MIN")
        end
    end
    return out
end

function _convergenceProblems(d::ChainDiagnostics)
    return _convergenceProblems(_worstRhat(d), _worstEss(d.ess), _worstEss(d.essTail))
end

"""
Thrown by [`runModel`](@ref BAYSOL.Pipeline.runModel) when a run is still not converged
after its retry: a fit that did not converge has nothing worth reporting, so no result is
returned and no report is written.

# Fields
- `problems::Vector{String}`: why the run does not count as converged.
"""
struct NotConvergedError <: Exception
    problems::Vector{String}
end

function Base.showerror(io::IO, e::NotConvergedError)
    print(io, "NotConvergedError: the run did not converge: ", join(e.problems, "; "), ".")
end

"""
Which chains are pooled: every chain that ran, unless it failed or more than
[`CHAIN_MAX_DIVERGENT`](@ref) of its post-warm-up transitions diverged. (A
chain in a poorer mode is not dropped for that: the modes are weighted by their
mass, see [`bridgeLogmass`](@ref).) `divRate[j]` is chain `j`'s divergent
fraction and `error[j]` is `nothing` or why the chain could not be run.

# Returns
- `(pooled::Vector{Bool}, reason::Vector{String})`,
    the reason being `"ok"` for a pooled chain.

# Exceptions
- None.
"""
function selectChains(divRate::AbstractVector{<:Real}, error::AbstractVector)
    pooled = fill(true, length(error))
    reason = fill("ok", length(error))
    for j in eachindex(error)
        if error[j] !== nothing
            pooled[j] = false
            reason[j] = "sampler error: $(error[j])"
        elseif divRate[j] > CHAIN_MAX_DIVERGENT
            pooled[j] = false
            reason[j] = "$(round(Int, 100 * divRate[j])) % of transitions diverged"
        end
    end
    return pooled, reason
end

# ---------------------------------------------------------------------------
#   Seed and Inferred
# ---------------------------------------------------------------------------


"""
Runs initial seeding for the sampler.

# Arguments
- `fw::ForwardCache`: Cache of the forward model
- `I_exp::AbstractVector`: Experimental intensity curve
- `σ_exp::AbstractVector`: Per-q standard deviation
- `pH::Real`: pH of the solution; forwarded to `BulkElectronDensity.ρₑ` for
    Protein solutes.
- `σ_pH::Real`: standard uncertainty on pH, propagated through each Protein
    solute's titration term.
- `solutes::Vector{Solute}`: the species in solution.

# Keywords
- `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`ρₑ_prior`](@ref).
- `κ_δρ₁₂::Real = κ_δρ₁₂`, `κ_δρ₃::Real = κ_δρ₃`:
    prior concentrations, forwarded to [`δρ_prior`](@ref).
- `pmvFallbackUncert::Real = PMV_FALLBACK_UNCERT`: uncertainty, cm³ mol⁻¹, of a
    non-biological solute whose table row states none, forwarded to [`ρₑ_prior`](@ref).
- `bounds_δρ₁₂::NTuple{2,<:Real} = BOUNDS_δρ₁₂`, `mode_δρ₁₂::Real = MODE_δρ₁₂`,
    `φ_max::Real = φ_max`: the δρ₁/δρ₂ support and mode and the cavity-occupancy bound,
    forwarded to [`δρ_prior`](@ref).
- `exclVolCorrBounds::NTuple{2,<:Real} = EXCL_VOL_CORR_BOUNDS`,
    `exclVolCorrEps::Real = EXCL_VOL_CORR_EPS`: the c1 bounds and the search's padding
    and grid step, for the `c1tab` of the `Seed`.
- `timing::Union{Nothing,StageLog} = nothing`: stored in the returned `Seed`.
- `shannon::Union{Nothing,ShannonInfo} = nothing`: stored in the returned `Seed`.

# Returns
- `Seed`: priors, initial point, forward cache, and data. The initial point is drawn from a
    stream of [`RNG_SEED`](@ref), not the global RNG, so a seed is the same every time.
"""
function seedSampler(
    fw::ForwardCache,
    iExp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
    pmvFallbackUncert::Real = PMV_FALLBACK_UNCERT,
    bounds_δρ₁₂::NTuple{2,<:Real} = BOUNDS_δρ₁₂,
    mode_δρ₁₂::Real = MODE_δρ₁₂,
    φ_max::Real = φ_max,
    exclVolCorrBounds::NTuple{2,<:Real} = EXCL_VOL_CORR_BOUNDS,
    exclVolCorrEps::Real = EXCL_VOL_CORR_EPS,
    timing::Union{Nothing,StageLog} = nothing,
    shannon::Union{Nothing,ShannonInfo} = nothing,
)::Seed
    pr = _calc_ξ_priors(
        pH, σ_pH, solutes;
        t = t, κ_δρ₁₂ = κ_δρ₁₂, κ_δρ₃ = κ_δρ₃,
        pmvFallbackUncert = pmvFallbackUncert,
        bounds_δρ₁₂ = bounds_δρ₁₂, mode_δρ₁₂ = mode_δρ₁₂, φ_max = φ_max,
    )
    ξ₀ = _ξ₀(pr, stream(RNG_SEED % UInt64, _RNG_INITIAL_POINT, 0))
    θ₀, _ = Θ(ξ₀, pr)
    wls = WLSData(iExp, σ_exp)
    c1tab = _C1Tables(
        fw; cmin = Float64(exclVolCorrBounds[1]),
        cmax = Float64(exclVolCorrBounds[2]),
        eps = Float64(exclVolCorrEps),
    )
    return Seed(pr, θ₀, fw, wls, timing, c1tab, shannon)
end

"""
    Inferred{S,N}

The result of [`infer`](@ref) (and, minus the warm-up draws, of
`BAYSOL.runModel`): the posterior draws of the physical parameters ξ =
(ρₑ, δρ₁, δρ₂, δρ₃), one (scale, `bkgrndCorr`, c1) triple and predicted
curve per draw, and AdvancedHMC.jl's own per-iteration diagnostics.

# Fields
- `samples::Vector{SVector{N,Float64}}`: posterior draws of ξ, `nSamples` per pooled chain.
- `stats::Vector{S}`: AdvancedHMC.jl's per-iteration diagnostics, matching
    samples index-for-index.
- `scale::Vector{Float64}`: the WLS estimate of the scale correction at samples[i].
- `bkgrndCorr::Vector{Float64}`: the WLS estimate
    of the background correction at samples[i].
- `c1::Vector{Float64}`: the profiled excluded-volume correction
    ([`profiledCorrs`](@ref)) at samples[i]. Profiled, not sampled -- it
    has no prior and therefore no z-score, unlike `samples`.
- `chisqRed::Vector{Float64}`:  the reduced χ² of the WLS estimate
- `curves::Matrix{Float64}, (Q, nSamples)`: the detector-scale predicted
    curve `I_calc(q)` = scale[i]·`yModel(q)` + `bkgrndCorr[i]` for each
    samples[i], column-matching `scale/bkgrndCorr`, with the model `yModel` the
    five-species contraction v(q)ᵀ G(q) v(q) at samples[i] and c1[i].
- `chain::Vector{Int}`: the chain each draw comes from (only the pooled chains are kept, see
    [`ChainDiagnostics`](@ref)); the draws are stored chain after chain.
- `iteration::Vector{Int}`: the draw's iteration within its
    chain, 1 to `nSamples` (the first `nAdapt` are warm-up).
- `diagnostics::ChainDiagnostics`: which chains were pooled and why not, the
    start scale of each, and the split R̂ and ESS of the pooled post-warm-up draws.
- `timing::Union{Nothing,StageLog}`: the run's stage log (from the `Seed`), if timing is on.
"""
struct Inferred{S,N}
    samples::Vector{SVector{N,Float64}}
    stats::Vector{S}
    scale::Vector{Float64}
    bkgrndCorr::Vector{Float64}
    c1::Vector{Float64}
    chisqRed::Vector{Float64}
    curves::Matrix{Float64}
    chain::Vector{Int}
    iteration::Vector{Int}
    diagnostics::ChainDiagnostics
    timing::Union{Nothing,StageLog}
end

# ---------------------------------------------------------------------------
#   infer
# ---------------------------------------------------------------------------


"""
Run NUTS on [`_logπ`](@ref) starting from seed, returning posterior draws
of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one (scale,
`bkgrndCorr`) pair per draw (see # Returns below), and AdvancedHMC.jl's
own per-iteration diagnostics.

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
starts to double back on itself (a "U-turn"), then samples from the valid part of that tree.

# MAP search and whitening

Before NUTS, [`_samplingSpace`](@ref) runs multi-start L-BFGS on the same log π
to find its mode, takes a central-difference Hessian there, and NUTS then samples
w with θ = μ + σ·(ẑ + S·w), in which the posterior is ≈ N(0, I) and the chain
starts at the mode. The map is affine, so the target is unchanged; it only puts
Stan's adaptation (identity starting metric, covariance shrunk toward 1e-3·I) on
the O(1) scales it assumes, instead of posteriors up to ~10⁴ times narrower
than the prior along some directions.

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first `nAdapt` iterations,
StepSizeAdaptor tunes the leapfrog step size ε via dual-averaging so the empirical
acceptance rate converges to δ; too-small ε wastes computation taking tiny steps,
too-large ε causes leapfrog's discretization error (and therefore the rejection
rate) to blow up. A gradient that is inconsistent with the value (a loosely
profiled c1, see [`EXCL_VOL_CORR_TOL`](@ref)) has the same effect and shows up as
a step size far below what the local curvature allows. MassMatrixAdaptor learns M
(here the full parameter covariance, since ρₑ/δρ are physically coupled through
the forward model) from the trajectory's sample covariance.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `nSamples::Int64`: total number of NUTS iterations.
- `nAdapt::Int64`: number of warm-up iterations spent adapting the step
                        size and mass matrix before sampling proper.

# Keywords
- `δ::Real=TARGET_ACCEPT`: target acceptance rate as a percentage,
                                (0, 100) exclusive; the default,
                                [`TARGET_ACCEPT`](@ref), is 95%.
- `nChains::Int=N_CHAINS`: number of NUTS chains
                                ([`N_CHAINS`](@ref) = 8, whatever the number of
                                Julia threads; the threads only decide how many run at
                                once). Chain 1 starts at the MAP, the others at
                                deterministic distances from it ([`chainRadius`](@ref)).
                                Each chain adapts on its own; chains that did not fail
                                are pooled, the modes they settled in weighted by their
                                mass (see [`bridgeLogmass`](@ref)). With `nChains = 1`
                                the run is the single-chain run of earlier versions.
- `retry::Bool=RETRY` (true): when the run does not count as converged (worst R̂ above
    [`RHAT_OK`](@ref), an ESS below [`ESS_MIN`](@ref), or either not computable), sample
                                once more with [`RETRY_N_ADAPT`](@ref) warm-up and
                                [`RETRY_N_DRAWS`](@ref) post-warm-up iterations per chain,
                                from `rngSeed` offset deterministically
                                ([`RETRY_SEED_OFFSET`](@ref)), and keep the run with the
                                smaller worst R̂. The same seeds always give the same
                                result, retried or not. `diagnostics.firstRhat` and
                                `retryKept` record what happened. The rerun always
                                adapts again, however long the first run was.
- `rngSeed::Union{Nothing,Integer}=RNG_SEED` (0): the run's
                                random seed. Every random draw of the run (the extra MAP
                                starts, the NUTS chain) comes from a stream derived from
                                it by the draw's index, so the same `rngSeed` reproduces
                                the run exactly, whatever the number of Julia threads.
                                `nothing` draws a fresh one from the default RNG (so
                                `Random.seed!` before the call also fixes it). It is
                                the `rngSeed` row of the run log and the `run` sheet.
- `options::SamplerOptions = SamplerOptions()`: the rerun's length, the chain starts, the
                                MAP search, its jitter, the harvest and the basin
                                restart (see [`SamplerOptions`](@ref)); the defaults are
                                the constants of `params.jl`.

# Returns
An [`Inferred`](@ref) of the pooled chains, chain after chain. Includes the
`nAdapt` warm-up draws of each chain; a caller that wants a warm-up-free
posterior drops the draws with `iteration ≤ nAdapt` out of every field itself.

# Exceptions
- `DomainError` for `nChains < 1`, `δ` outside (0, 100) or `nAdapt ≥ nSamples`.
- The first chain's error if no chain could be run.
"""
function infer(
    seed::Seed,
    nSamples::Int64,
    nAdapt::Int64;
    δ::Real = TARGET_ACCEPT,
    rngSeed::Union{Nothing,Integer} = RNG_SEED,
    nChains::Int = N_CHAINS,
    retry::Bool = RETRY,
    options::SamplerOptions = SamplerOptions(),
)::Inferred
    nChains ≥ 1 || throw(DomainError(nChains, "nChains must be ≥ 1"))
    base = rngSeed === nothing ? drawBase() : (rngSeed % UInt64)
    go =
        (ns, na, b) -> withGcPaused(
            () -> _infer(
                seed, ns, na; δ = δ, base = b, nChains = nChains,
                options = options,
            ),
        )
    r1 = go(nSamples, nAdapt, base)
    worst = _worstRhat(r1.diagnostics)
    _retryNeeded(r1.diagnostics, retry) || return r1

    # R̂ above the limit: once more, longer, from streams and jitter directions derived
    # from the seeds (a different draw of the starts too, since a bad R̂ can be seed luck)
    info = seed.timing === nothing ? nothing : copy(seed.timing.info)
    r2 = go(
        options.retryNAdapt + options.retryNDraws, options.retryNAdapt,
        _retrySeed(base),
    )
    kept =
        isempty(_convergenceProblems(r2.diagnostics)) ||
        _worstRhat(r2.diagnostics) ≤ worst
    best = kept ? r2 : r1
    if seed.timing !== nothing
        # what the report says about the run is that of the kept attempt, with the
        # caller's seed (the rerun's is derived from it)
        kept || merge!(seed.timing.info, info)
        seed.timing.info["rngSeed"] = base
        seed.timing.info["nAdapt"] = best.diagnostics.nAdapt
        seed.timing.info["nSamples"] =
            best.diagnostics.nAdapt + (kept ? options.retryNDraws : nSamples - nAdapt)
    end
    d = best.diagnostics
    return Inferred(best.samples, best.stats, best.scale, best.bkgrndCorr, best.c1,
        best.chisqRed, best.curves, best.chain, best.iteration,
        ChainDiagnostics(d.nChains, d.startScale, d.pooled, d.reason, d.rhat, d.ess,
            d.essTail, d.rewhitened, d.mode, d.modeWeight, d.modeLogmass, d.modeErr,
            d.weightsUncertain, d.nAdapt, worst, kept, d.nExtra, d.optima),
        best.timing)
end

"""
The `base` of the rerun [`infer`](@ref) does when the run is not converged,
derived from the run's own by [`RETRY_SEED_OFFSET`](@ref).
"""
_retrySeed(base::UInt64) = (base + RETRY_SEED_OFFSET) * 0x9e3779b97f4a7c15

"""
Whether [`infer`](@ref) reruns: `retry` is on and the run does not count as converged
(R̂ above [`RHAT_OK`](@ref) or not computable, or an ESS below [`ESS_MIN`](@ref) or not
computable). The rerun always adapts again, whatever the length of the run.
"""
function _retryNeeded(d::ChainDiagnostics, retry::Bool)
    return retry && !isempty(_convergenceProblems(d))
end

"""
The body of [`infer`](@ref), run with the garbage collector paused
(see [`withGcPaused`](@ref BAYSOL.Runtime.withGcPaused)): the MAP
objective, the NUTS gradient and the re-profile loop call
[`gcCheckpoint`](@ref BAYSOL.Runtime.gcCheckpoint),
which collects once per byte budget.
"""
function _infer(
    seed::Seed{<:Real,N},
    nSamples::Int64,
    nAdapt::Int64;
    δ::Real = TARGET_ACCEPT,
    base::UInt64 = drawBase(),
    nChains::Int = N_CHAINS,
    options::SamplerOptions = SamplerOptions(),
)::Inferred where {N}

    if δ ≤ 0 || δ ≥ 100
        throw(DomainError(δ, "δ must satisfy: 0 < δ < 100"))
    end
    δ = δ / 100

    if nAdapt ≥ nSamples
        throw(DomainError((nAdapt, nSamples), "nAdapt must be < nSamples"))
    end

    # MAP search + Laplace whitening (map.jl): NUTS samples w, θ = μ + σ·(ẑ + S·w),
    # in which the posterior is ≈ N(0, I) and the chain starts at the MAP.
    tMap = tick()
    seed.timing === nothing || (seed.timing.info["rngSeed"] = base)
    sp = _samplingSpace(seed; base = base, options = options)
    if seed.timing !== nothing
        seed.timing.info["mapModes"] = sp.nModes
        tock!(seed.timing, :sampling, 1,
            "MAP search + whitening ($(sp.nOk)/$(sp.nStarts) starts, $(sp.nModes) " *
            "mode$(sp.nModes == 1 ? "" : "s")$(sp.whitened ? "" : ", not whitened"))",
            tMap)
    end

    # the chains; if their best draw beats the MAP the sampler was whitened
    # at, the MAP search missed a better basin: re-whiten there (L-BFGS
    # from that draw, the heaviest basin wins) and run the chains once more
    post = (nAdapt+1):nSamples
    chains = _runChains(
        seed, sp, nSamples, nAdapt, δ, base, nChains; options = options,
    )
    rewhitened = 0.0
    best = _bestDraw(chains.runs, post)
    if best.ld > sp.logπ + options.basinRestartNats
        tRe = tick()
        zBest = _standardize(Θ(best.ξ, seed.pr)[1], seed.pr)
        sp2 = _samplingSpace(
            seed; base = base, extraStarts = [zBest], options = options,
        )
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "re-whitening: a chain found a basin %.1f nats above the MAP",
                best.ld - sp.logπ
            ), tRe)
        if sp2.logπ > sp.logπ
            rewhitened = sp2.logπ - sp.logπ
            sp = sp2
            chains = _runChains(
                seed, sp, nSamples, nAdapt, δ, base, nChains; options = options,
            )
        end
    end
    tNuts = chains.tNuts

    # optima the chains visited that the search did not report, and chains for the ones that
    # carry mass but have too few chains at them (their draws could not get their weight)
    tH = tick()
    ext = _withOptimaChains(
        seed, sp, chains.runs, chains.starts, post, nSamples, nAdapt, δ, base,
        nChains; options = options,
    )
    runs, starts, nExtra = ext.runs, ext.starts, ext.nExtra
    nTotal = length(runs)
    optimaReport = ext.optimaReport
    if seed.timing !== nothing
        seed.timing.info["optima"] = count(o -> o.share ≥ OPTIMUM_MIN_SHARE, optimaReport)
        tock!(seed.timing, :sampling, 1,
            "optima from the draws, $nExtra extra chain$(nExtra == 1 ? "" : "s")", tH)
    end
    nLf = sum(r -> r.stats === nothing ? 0 : sum(getproperty.(r.stats, :n_steps)), runs)

    # which chains are pooled (every chain that ran and did not mostly diverge)
    ran = [r.error === nothing for r in runs]
    # no chain ran: the error is the caller's to see
    any(ran) || throw(first(r.error for r in runs))
    ld = zeros(length(post), nTotal)
    divRate = zeros(nTotal)
    for r in runs
        r.error === nothing || continue
        ld[:, r.k] = getproperty.(r.stats[post], :log_density)
        divRate[r.k] = mean(getproperty.(r.stats[post], :numerical_error))
    end
    pooled, reason = selectChains(
        divRate,
        [r.error === nothing ? nothing : sprint(showerror, r.error) for r in runs],
    )
    if !any(pooled)
        # every chain that ran was rejected (e.g. all diverged): pool them all so
        # the caller's own all-diverged handling applies, as with a single chain
        for k in findall(ran)
            pooled[k] = true
            reason[k] = reason[k] * " (no chain passed: pooled anyway)"
        end
    end
    pk = findall(pooled)

    if seed.timing !== nothing
        seed.timing.info["nChains"] = nTotal
        seed.timing.info["nChainsPooled"] = length(pk)
        seed.timing.info["leapfrog"] = nLf
        # chain-seconds per leapfrog step
        ms = MS_PER_S * sum(r -> r.seconds, runs) / max(nLf, 1)
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "NUTS  (%s iters, %s leapfrog, %.3f ms/step)",
                fmtCount(nTotal * nSamples),
                fmtCount(nLf),
                ms
            ),
            tNuts)
    end

    # draws × chains × (ξ₁…ξ_N, log π) of the pooled chains, after the warm-up
    cube = Array{Float64,3}(undef, length(post), length(pk), N + 1)
    for (c, k) in enumerate(pk)
        for i in 1:N
            cube[:, c, i] = getindex.(runs[k].ξ[post], i)
        end
        cube[:, c, N+1] = ld[:, k]
    end

    # The modes the chains settled in, their mass and the draws each keeps. NUTS chains do
    # not jump between modes, so chains pooled as they come would weight the modes by how
    # many started in each: the mass of each mode is estimated by bridge sampling (from
    # its chains' draws and the density), and the draws are thinned to those shares.
    tModes = tick()
    modeOf = chainModes(cube)
    M = maximum(modeOf)
    logZ = zeros(M)
    err = zeros(M)
    if M > 1
        ℓπ = _valueTarget(seed, sp)
        for m in 1:M
            cs = findall(==(m), modeOf)
            W = reduce(vcat, (_drawsW(seed, sp, runs[pk[c]].ξ[post]) for c in cs))
            logZ[m], err[m] =
                bridgeLogmass(W, reduce(vcat, (ld[:, pk[c]] for c in cs)), ℓπ,
                    stream(base, _RNG_BRIDGE, m))
        end
    end
    chainsIn = [count(==(m), modeOf) for m in 1:M]
    uncertain = M > 1 && weightsUncertain(logZ, err)
    # an error too large to determine the shares: the chains of the modes that
    # can matter are pooled as they came, the modes that are negligible even
    # at their most optimistic estimate are dropped (and the report says so)
    weights =
        M == 1 ? [1.0] :
        uncertain ? uncertainWeights(logZ, err, chainsIn) : modeWeights(logZ)
    keep =
        uncertain ? [w > 0 ? length(post) : 0 for w in weights] :
        drawsPerChain(weights, chainsIn, length(post))
    if M > 1 && seed.timing !== nothing
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "%d posterior modes: mass by bridge sampling%s",
                M,
                uncertain ? " (weights uncertain, not applied)" : ""
            ),
            tModes)
    end

    # the rows each pooled chain contributes: its warm-up
    # rows, and the post-warm-up rows its mode keeps
    rows = [
        vcat(1:nAdapt, nAdapt .+ evenIndices(length(post), keep[modeOf[c]])) for
        c in eachindex(pk)
    ]

    tReprofile = tick()
    # scale/bkgrndCorr are fit in closed form (wlsFit) and discarded on every single
    # ℓπ/gradient evaluation above; re-profile c1 at each posterior draw so the
    # reported curve/χ² match what _ll actually evaluated at that ξ during sampling.
    reprof = tmapItems(c -> _reprofile(seed, runs[pk[c]].ξ[rows[c]]), eachindex(pk))
    tock!(
        seed.timing,
        :sampling,
        1,
        "per-draw c1 re-profile + curves ($(sum(length, rows)) draws)",
        tReprofile,
    )

    # convergence of the chains of each mode (between modes they differ by
    # construction); the worst mode is reported. A mode below MODE_NEGLIGIBLE keeps
    # no draws, so what its chains did is not part of the posterior: not diagnosed.
    live = [m for m in 1:M if weights[m] ≥ MODE_NEGLIGIBLE]
    cvs = [
        convergence(cube[:, findall(==(m), modeOf), :]) for
        m in (isempty(live) ? (1:M) : live)
    ]
    # (NaN entries, from modes too short to judge, are left out; NaN if nothing is left)
    worst(f, init) = [
        (
            v = filter(!isnan, getindex.(getproperty.(cvs, init), q));
            isempty(v) ? NaN : f(v)
        ) for q in 1:(N+1)
    ]
    diag = ChainDiagnostics(nTotal, [starts[k][2] for k in 1:nTotal], pooled, reason,
        worst(maximum, :rhat), worst(minimum, :ess), worst(minimum, :essTail),
        rewhitened, [k in pk ? modeOf[findfirst(==(k), pk)] : 0 for k in 1:nTotal],
        weights, logZ, err, uncertain, nAdapt, NaN, false, nExtra, optimaReport)

    return Inferred(
        reduce(vcat, (runs[pk[c]].ξ[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (runs[pk[c]].stats[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (r.scale for r in reprof)),
        reduce(vcat, (r.bkgrndCorr for r in reprof)),
        reduce(vcat, (r.c1 for r in reprof)),
        reduce(vcat, (r.χ² for r in reprof)),
        reduce(hcat, (r.curves for r in reprof)),
        reduce(vcat, (fill(pk[c], length(rows[c])) for c in eachindex(pk))),
        reduce(vcat, (rows[c] for c in eachindex(pk))),
        diag,
        seed.timing,
    )
end

# ---------------------------------------------------------------------------
#   Optima beyond the MAP search: shares, chains at them, chains started at them
# ---------------------------------------------------------------------------

"""
The Laplace share of every optimum: `exp(logmass)` over the sum over those that have
one; 0 for an optimum with none (`NaN`).
"""
function _optimumShares(optima)
    lm = [o.logmass for o in optima]
    ok = filter(!isnan, lm)
    isempty(ok) && return zeros(length(optima))
    top = maximum(ok)
    tot = sum(exp(x - top) for x in ok)
    return [isnan(x) ? 0.0 : exp(x - top) / tot for x in lm]
end

"""
How many of the chains, whose post-warm-up draws are the rows of `wsRows` (whitened
coordinates of `sp`), are at the optimum `o`: at least [`OPTIMUM_CHAIN_FRACTION`](@ref) of
a chain's draws lie within [`OPTIMUM_CHAIN_RADIUS`](@ref) of it in the Mahalanobis distance
of the Hessian there. 0 for an optimum without a positive definite Hessian. `radius` and
`fraction` replace the two constants.
"""
function _chainsAt(
    o, sp, wsRows;
    radius::Real = OPTIMUM_CHAIN_RADIUS, fraction::Real = OPTIMUM_CHAIN_FRACTION,
)
    all(>(0), o.λ) || return 0
    H = o.V * (o.λ .* o.V')
    return count(wsRows) do W
        size(W, 1) == 0 && return false
        inside = count(axes(W, 1)) do i
            d = sp.ẑ + sp.S * typeof(sp.ẑ)(@view W[i, :]) - o.z
            d' * H * d ≤ radius^2
        end
        inside ≥ fraction * size(W, 1)
    end
end

"""
The first round of chains `runs` (with their `starts`), extended: L-BFGS from their draws
for optima the MAP search did not report ([`_optimaAndExtraChains`](@ref)), then the
chains that optima carrying mass are missing, run and appended (none for `nChains == 1`,
which is a single chain). Also the [`OptimumReport`](@ref)s of the optima that carry mass.

# Returns
- `NamedTuple` `(runs, starts, nExtra, optimaReport)`.
"""
function _withOptimaChains(seed::Seed{<:Real,N}, sp, runs, starts, post,
    nSamples, nAdapt, δ, base, nChains;
    options::SamplerOptions = SamplerOptions()) where {N}
    opt = _optimaAndExtraChains(seed, sp, runs, post; options = options)
    if nChains > 1 && !isempty(opt.extraW)
        ex = _runExtraChains(
            seed, sp, nSamples, nAdapt, δ, base, opt.extraW, length(runs),
        )
        allRuns = vcat(runs, ex.runs)
        wsRows = vcat(
            opt.wsRows,
            [_drawsW(seed, sp, r.ξ[post]) for r in ex.runs if r.error === nothing],
        )
        report = _optimumReports(
            seed, sp, opt.optima, wsRows, opt.owner[ex.keep]; options = options,
        )
        return (runs = allRuns, starts = vcat(starts, ex.starts),
            nExtra = length(ex.runs),
            optimaReport = report)
    end
    report = _optimumReports(seed, sp, opt.optima, opt.wsRows, Int[]; options = options)
    return (runs = runs, starts = starts, nExtra = 0, optimaReport = report)
end

"""
After the first round of chains: the optima known (the MAP search's and those found by
L-BFGS from the chains' draws, [`_harvestOptima`](@ref)), and the whitened starts of the
chains that optima carrying mass ([`OPTIMUM_MIN_SHARE`](@ref)) are missing: up to
[`OPTIMUM_MIN_CHAINS`](@ref) chains at each, [`OPTIMUM_CHAIN_CAP`](@ref) in all,
the heaviest optimum first.

# Returns
- `(optima, extraW, owner, wsRows)`: the optima, the starts and, for each
    start, the index in `optima` of the optimum it is at, and the whitened
    post-warm-up draws of each chain (one matrix per chain that ran).
"""
function _optimaAndExtraChains(
    seed::Seed{<:Real,N},
    sp,
    runs,
    post;
    options::SamplerOptions = SamplerOptions(),
) where {N}
    ran = [r for r in runs if r.error === nothing]
    isempty(ran) && return (
        optima = sp.optima, extraW = Vector{Float64}[], owner = Int[],
        wsRows = Matrix{Float64}[],
    )
    wsRows = [_drawsW(seed, sp, r.ξ[post]) for r in ran]
    ld = reduce(vcat, [getproperty.(r.stats[post], :log_density) for r in ran])
    dv = reduce(vcat, [getproperty.(r.stats[post], :numerical_error) for r in ran])
    optima, _ = _harvestOptima(
        seed, sp, reduce(vcat, wsRows), ld, Vector{Bool}(dv); options = options,
    )
    shares = _optimumShares(optima)
    extraW = Vector{Float64}[]
    owner = Int[]
    for i in sortperm(shares; rev = true)
        shares[i] ≥ OPTIMUM_MIN_SHARE || break
        need =
            options.optimumMinChains - _chainsAt(
                optima[i], sp, wsRows;
                radius = options.optimumChainRadius,
                fraction = options.optimumChainFraction,
            )
        need > 0 || continue
        w = Vector(sp.S \ (optima[i].z - sp.ẑ))
        for _ in 1:need
            length(extraW) < options.optimumChainCap || break
            push!(extraW, w)
            push!(owner, i)
        end
    end
    return (optima = optima, extraW = extraW, owner = owner, wsRows = wsRows)
end

"""
The [`OptimumReport`](@ref)s of the optima that carry mass, the best first,
with the chains at each after all the chains have run (`wsRows`: the
whitened post-warm-up draws of each chain that ran); `owners` lists, for
each chain started at an optimum, the index in `optima` of that optimum.
"""
function _optimumReports(
    seed::Seed{<:Real,N}, sp, optima, wsRows, owners;
    options::SamplerOptions = SamplerOptions(),
) where {N}
    shares = _optimumShares(optima)
    out = OptimumReport[]
    for i in sortperm(shares; rev = true)
        shares[i] ≥ OPTIMUM_MIN_SHARE || break
        push!(
            out,
            OptimumReport(
                Vector(Ξ(sp.μ .+ sp.σ .* optima[i].z, seed.pr)), optima[i].logmass,
                shares[i],
                _chainsAt(
                    optima[i], sp, wsRows;
                    radius = options.optimumChainRadius,
                    fraction = options.optimumChainFraction,
                ),
                count(==(i), owners),
            ),
        )
    end
    return out
end

# ---------------------------------------------------------------------------
#   Running the NUTS chains: starts, the sampler per chain, the re-profiled curves
# ---------------------------------------------------------------------------

"""
The draws `ξs` in NUTS's whitened coordinates, one draw per row.

# Returns
- `Matrix{Float64}`, `length(ξs) × N`.
"""
function _drawsW(seed::Seed{<:Real,N}, sp, ξs::AbstractVector) where {N}
    W = Matrix{Float64}(undef, length(ξs), N)
    @inbounds for (i, ξ) in enumerate(ξs)
        w = _w_of_θ(Θ(ξ, seed.pr)[1], sp)
        for j in 1:N
            W[i, j] = w[j]
        end
    end
    return W
end

"""
ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates
w (the target the chains sample and bridge sampling integrates).
"""
function _valueTarget(seed::Seed{<:Real,N}, sp) where {N}
    return w -> _logπ(
        _θ_of_w(SVector{N,eltype(w)}(w...), sp),
        seed.pr,
        seed.wls,
        seed.fw;
        tab = seed.c1tab,
    )
end

"""
The pieces shared by every NUTS chain on the whitened target of `sp`: ℓπ (value),
∂ℓπ∂w (value and gradient, one ForwardDiff pass) and `runChain(k, w₀)`, which runs chain
`k` from the whitened start `w₀` with its own metric, Hamiltonian, adaptor and random
stream (the stream belongs to the chain index, not to the thread that happens to run it)
and shares only the read-only seed.

# Returns
- `(ℓπ, ∂ℓπ∂w, runChain)`; `runChain` returns a [`_ChainRun`](@ref).
"""
function _chainRunner(seed::Seed{<:Real,N}, sp, nSamples::Int64,
    nAdapt::Int64, δ::Real, base::UInt64, showProgress::Bool) where {N}
    # ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates w.
    ℓπ = @closure w -> _logπ(
        _θ_of_w(SVector{N,eltype(w)}(w...), sp),
        seed.pr,
        seed.wls,
        seed.fw;
        tab = seed.c1tab,
    )

    # ∂ℓπ∂w: w ↦ (log π(θ(w)), ∇_w log π(θ(w))), computed in one ForwardDiff pass.
    ∂ℓπ∂w = @closure w -> begin
        gcCheckpoint()
        result = DiffResults.GradientResult(w)
        ForwardDiff.gradient!(result, ℓπ, w)
        (DiffResults.value(result), DiffResults.gradient(result))
    end

    # One NUTS chain. Every chain has its own metric, Hamiltonian, adaptor
    # and random stream (the stream belongs to the chain index, not to the
    # thread that happens to run it), and shares only the read-only seed.
    runChain =
        (k, w₀) -> begin
            t0 = time_ns()
            try
                # DenseEuclideanMetric allows the adaptation to learn
                # correlations between parameters. Since we are only fitting
                # a handful of params and they are highly coupled, it is
                # worth it here. After the whitening it starts (M⁻¹ = I) close to right.
                metric = DenseEuclideanMetric(N)

                # combines "potential energy" (ℓπ) and kinetic energy (from metric)
                hamiltonian = Hamiltonian(metric, ℓπ, ∂ℓπ∂w)

                # the chain's own stream: the step-size
                # search and the sampler both draw from it
                rng = stream(base, _RNG_NUTS, k)

                # HMC numerically integrates the Hamiltonian,
                # so we need to guess a good step size.
                initStepSize = find_good_stepsize(rng, hamiltonian, copy(w₀))

                # Leapfrog integration evaluates kinetic energy first, then
                # "skips over" that evaluated position to the next one for potential energy.
                integrator = Leapfrog(initStepSize)

                # Initial step sizes are likely non-ideal, so sampler
                # learns mass matrix/metric and step size as it goes along.
                adaptor = StanHMCAdaptor(
                    MassMatrixAdaptor(metric),
                    StepSizeAdaptor(δ, integrator),
                )

                # the sampler in w-space
                kernel = HMCKernel(
                    Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()),
                )

                ws, stats = sample(
                    rng,
                    hamiltonian,
                    kernel,
                    copy(w₀),
                    nSamples,
                    adaptor,
                    nAdapt;
                    progress = showProgress,
                    verbose = showProgress,
                )
                ξs = [Ξ(_θ_of_w(SVector{N,Float64}(s...), sp), seed.pr) for s in ws]
                return _ChainRun(k, ξs, stats, nothing, (time_ns() - t0) / NS_PER_S)
            catch e
                e isa InterruptException && rethrow()
                return _ChainRun(
                    k,
                    SVector{N,Float64}[],
                    nothing,
                    e,
                    (time_ns() - t0) / NS_PER_S,
                )
            end
        end

    return ℓπ, ∂ℓπ∂w, runChain
end

"""
Runs the `nChains` NUTS chains on the whitened target of `sp`, one task each, from their
starts ([`_chainStart`](@ref)). `δ` is the target acceptance as a fraction. Every chain
has its own metric, Hamiltonian, adaptor and random stream (the stream belongs to the
chain index, not to the thread that happens to run it) and shares only the read-only seed.

# Returns
-   `NamedTuple` `(runs, starts, tNuts)`: the [`_ChainRun`](@ref)s in
    chain order, the starts and the timer started when the chains began.
"""
function _runChains(seed::Seed{<:Real,N}, sp, nSamples::Int64,
    nAdapt::Int64, δ::Real,
    base::UInt64, nChains::Int; options::SamplerOptions = SamplerOptions()) where {N}
    tSetup = tick()
    # (concurrent progress bars would overwrite each other)
    ℓπ, ∂ℓπ∂w, runChain =
        _chainRunner(seed, sp, nSamples, nAdapt, δ, base, nChains == 1)

    # The starts: mirrored jittered pairs, or the MAP for a single chain
    # (deterministically, see `_chainStart`). Chosen serially and up front,
    # so neither the starts nor which chain gets which depend on the threads.
    starts = [
        _chainStart(k, nChains, N, ℓπ, ∂ℓπ∂w, base, options.chainStartRadii)
        for k in 1:nChains
    ]

    tock!(seed.timing, :sampling, 1, "NUTS setup (starts, Hamiltonian)", tSetup)
    tNuts = tick()
    runs = tmapItems(k -> runChain(k, starts[k][1]), 1:nChains)
    return (runs = runs, starts = starts, tNuts = tNuts)
end

"""
Runs one NUTS chain at each of the whitened starts `wStarts`, as chains `k0 + 1`,
`k0 + 2`, … (their streams belong to those indices). A start where log π or its gradient
is not finite is dropped.

# Returns
-   `NamedTuple` `(runs, starts, keep)`: the [`_ChainRun`](@ref)s, their `(w₀, distance
    from the MAP)` and the positions in `wStarts` that were run.
"""
function _runExtraChains(seed::Seed{<:Real,N}, sp, nSamples::Int64,
    nAdapt::Int64, δ::Real, base::UInt64, wStarts::AbstractVector, k0::Int) where {N}
    ℓπ, ∂ℓπ∂w, runChain = _chainRunner(seed, sp, nSamples, nAdapt, δ, base, false)
    keep = filter(eachindex(wStarts)) do i
        try
            v, g = ∂ℓπ∂w(wStarts[i])
            isfinite(v) && all(isfinite, g)
        catch e
            e isa InterruptException && rethrow()
            false
        end
    end
    runs = tmapItems(i -> runChain(k0 + findfirst(==(i), keep), wStarts[i]), keep)
    starts = [(wStarts[i], sqrt(sum(abs2, wStarts[i]))) for i in keep]
    return (runs = runs, starts = starts, keep = keep)
end

"""
The highest post-warm-up log density among the
non-divergent draws of the chains that ran, and its ξ.

# Returns
- `NamedTuple` `(ld, ξ)`; `ld = -Inf` if there is no such draw.
"""
function _bestDraw(runs, post)
    best = (ld = -Inf, ξ = nothing)
    for r in runs
        r.error === nothing || continue
        for i in post
            st = r.stats[i]
            st.numerical_error || st.log_density <= best.ld ||
                (best = (ld = st.log_density, ξ = r.ξ[i]))
        end
    end
    return best
end

"""
What one NUTS chain returned: its draws and diagnostics,
or the error that stopped it (then `stats` is `nothing`).
"""
struct _ChainRun{N,S}
    k::Int
    ξ::Vector{SVector{N,Float64}}
    stats::S
    error::Union{Nothing,Exception}
    seconds::Float64
end

"""
Start of chain `k` of `n` in NUTS's whitened coordinates w, with its signed distance
from the MAP in posterior standard deviations ([`chainRadius`](@ref)). The start is
`r·u` for a direction `u` on the unit sphere: a single chain, and chain 1, at the MAP
(`w = 0`); chain 2 also at the MAP (its own random stream makes it an independent
chain); chains 3 and up in mirrored pairs, chains `2p+1` and `2p+2` at `+r_p·u_p` and
`-r_p·u_p`. The directions come from streams of the run's `base` (its
`rngSeed`), under their own purpose tag. A start where log π or its gradient is not
finite is pulled halfway back toward the MAP, up to [`CHAIN_JITTER_MAX_HALVINGS`](@ref)
times, and the distance returned is the one used; a start that never becomes usable is the
MAP itself (0).

# Returns
- `(w₀::Vector{Float64}, r::Float64)`.
"""
function _chainStart(
    k::Int, n::Int, N::Int, ℓπ, ∂ℓπ∂w, base::UInt64,
    radii::Union{AbstractVector{<:Real},Tuple} = CHAIN_START_RADII,
)
    r = chainRadius(k, n, radii)
    r == 0 && return zeros(N), 0.0
    z = randn(stream(base, _RNG_JITTER, (k - 1) ÷ 2), N)
    u = z ./ sqrt(sum(abs2, z))
    for _ in 0:CHAIN_JITTER_MAX_HALVINGS
        w = r .* u
        usable = try
            v, g = ∂ℓπ∂w(w)
            isfinite(v) && all(isfinite, g)
        catch e
            e isa InterruptException && rethrow()
            false
        end
        usable && return w, r
        r /= 2
    end
    return zeros(N), 0.0
end

"""
The (scale, `bkgrndCorr`, c1, reduced χ², curve)
of every draw `ξs`, c1 re-profiled at each.

# Returns
- `NamedTuple` of `Vector`s `scale`, `bkgrndCorr`,
    `c1`, `χ²` and the matrix `curves` (Q × draws).
"""
function _reprofile(seed::Seed, ξs::AbstractVector)
    n = length(ξs)
    scale = Vector{Float64}(undef, n)
    bkgrndCorr = Vector{Float64}(undef, n)
    c1 = Vector{Float64}(undef, n)
    χ² = Vector{Float64}(undef, n)
    curves = Matrix{Float64}(undef, length(seed.fw.qvals), n)
    for (i, ξ) in enumerate(ξs)
        gcCheckpoint()
        ŷ, fit, c1Star = profiledCorrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
        scale[i]       = fit.scale
        bkgrndCorr[i]  = fit.bkgrndCorr
        c1[i]          = c1Star
        χ²[i]          = reducedChi2(fit)
        curves[:, i]   = wlsPredict(fit, ŷ)
    end
    return (; scale, bkgrndCorr, c1, χ², curves)
end
