# SPDX-License-Identifier: LGPL-3.0-or-later

# Several posterior modes: chains that settled in different modes are grouped, each
# mode's probability mass is estimated by bridge sampling, and the pooled draws are
# thinned to the modes' mass shares. NUTS chains do not jump between modes, so pooling
# them as they come would weight the modes by how many chains happened to start in each.

using ..Runtime: tmapBlocks
using LinearAlgebra: LowerTriangular, cholesky, diag, inv, issuccess, Symmetric
using LogExpFunctions: logsumexp
using Random: AbstractRNG
using Statistics: median


"""
Groups the chains into modes. `cube` is `draws × chains × quantities`
(the parameters and log π, after the warm-up). Two chains are linked
when their pairwise R̂ ([`convergence`](@ref)) is at most
[`MODE_RHAT`](@ref); a mode is a connected group of linked chains.

# Returns
- `Vector{Int}`: the mode of every chain, numbered
    in order of the first chain that belongs to it.

# Exceptions
- None.
"""
function chainModes(cube::AbstractArray{<:Real,3})::Vector{Int}
    m = size(cube, 2)
    # (no shortcut for "the R̂ of all chains is below the limit": one chain far from nine
    # others only raises the rank-normalized R̂ to about the limit, so it would be pooled)
    m == 1 && return ones(Int, m)
    mode = zeros(Int, m)
    nmodes = 0
    for start in 1:m
        mode[start] == 0 || continue
        nmodes += 1
        stack = [start]
        mode[start] = nmodes
        while !isempty(stack)
            a = pop!(stack)
            for b in 1:m
                mode[b] == 0 || continue
                r = convergence(view(cube, :, [a, b], :)).rhat
                # a pair is linked when every quantity agrees;
                # NaN (too few draws) counts as agreeing
                if all(x -> isnan(x) || x ≤ MODE_RHAT, r)
                    mode[b] = nmodes
                    push!(stack, b)
                end
            end
        end
    end
    return mode
end

"""
`q[p] = ‖L⁻¹(W[p, :] − μ)‖²` for every row of `W` (`linv` is
L⁻¹, lower triangular), vectorized across the rows: the columns
of `W` are contiguous, so every inner loop runs down a column.
"""
function _quadform!(q::AbstractVector{Float64}, t::AbstractVector{Float64},
    W::AbstractMatrix{Float64}, μ::Vector{Float64},
    linv::Matrix{Float64})
    n, d = size(W)
    fill!(q, 0.0)
    for i in 1:d
        fill!(t, 0.0)
        for j in 1:i
            c = linv[i, j]
            m = μ[j]
            @inbounds @fastmath @simd for p in 1:n
                t[p] += c * (W[p, j] - m)
            end
        end
        @inbounds @fastmath @simd for p in 1:n
            q[p] += t[p] * t[p]
        end
    end
    return q
end

"""
`P[p, :] = μ + L·Z[p, :]` for every row (points of N(μ, LLᵀ)
from standard normal rows), vectorized across the rows.
"""
function _affine!(
    P::Matrix{Float64},
    Z::Matrix{Float64},
    μ::Vector{Float64},
    L::Matrix{Float64},
)
    n, d = size(Z)
    for i in 1:d
        m = μ[i]
        @inbounds @simd for p in 1:n
            P[p, i] = m
        end
        for j in 1:i
            c = L[i, j]
            @inbounds @fastmath @simd for p in 1:n
                P[p, i] += c * Z[p, j]
            end
        end
    end
    return P
end

"""
Exponentials of the log ratios `l` relative to `shift`, clamped to ±`BRIDGE_CLAMP`
in the exponent so that no sum can overflow and no infinity reaches the
`@fastmath` loops (a zero density, `l = -Inf`, becomes the smallest weight).
"""
function _weights(l::Vector{Float64}, shift::Float64)
    w = similar(l)
    @inbounds for p in eachindex(l)
        x = l[p] - shift
        w[p] = exp(isnan(x) ? -BRIDGE_CLAMP : clamp(x, -BRIDGE_CLAMP, BRIDGE_CLAMP))
    end
    return w
end


"""
One bridge-sampling estimate of log Z, `Z = ∫ exp(logp(w)) dw`, from the draws `Wb`
of the mode (rows) with their log densities `logpB`: a Gaussian proposal g is
fitted to the other half `Wa`, as many points are drawn from it as there are draws
in `Wb`, and Meng and Wong's optimal bridge iteration is run to its fixed point,

    r ← (N₁/N₂) Σⱼ lⱼ / (s₁lⱼ + s₂r)  /  Σᵢ 1 / (s₁lᵢ + s₂r),    l = p/g,

`i` over the draws, `j` over the proposal points, `s₁ = N₁/(N₁+N₂)`,
`s₂ = N₂/(N₁+N₂)`. The ratios are taken relative to the median draw ratio, so that the
sums stay in range. The densities at the proposal points are evaluated in parallel.

# Arguments
- `Wa`, `Wb::AbstractMatrix{Float64}`: the fitting half and
    the estimating half of the mode's draws, one draw per row.
- `logpB::AbstractVector`: log π at the rows of `Wb`.
- `logp`: `w -> log π(w)`, called on a `Vector{Float64}`;
    a non-finite value counts as zero density.
- `rng::AbstractRNG`: the source of the proposal points.

# Returns
- `Float64`: the estimate of log Z (`NaN` if the proposal
    covariance is singular or a draw's density is `NaN`).

# Exceptions
- None.
"""
function _bridgeHalf(wa::AbstractMatrix{Float64}, wb::AbstractMatrix{Float64},
    logpB::AbstractVector{<:Real}, logp,
    rng::AbstractRNG)::Float64
    n1, d = size(wb)
    na = size(wa, 1)
    any(isnan, logpB) && return NaN
    # the proposal: the Gaussian of the fitting half
    μ = [sum(view(wa, :, j)) / na for j in 1:d]
    X = wa .- μ'
    Σ = (X' * X) ./ (na - 1)
    F = cholesky(Symmetric(Σ + 1e-10 * max(1.0, maximum(diag(Σ))) * one(Σ)); check = false)
    issuccess(F) || return NaN
    L = Matrix(F.L)
    linv = Matrix(inv(LowerTriangular(L)))
    # log of the Gaussian's normalization
    c0 = sum(log, diag(L)) + d / 2 * LOG_TWO_PI
    n2 = n1
    q = Vector{Float64}(undef, max(n1, n2))
    t = similar(q)

    # the log ratios l = log p − log g at the draws
    l1 = Vector{Float64}(undef, n1)
    _quadform!(view(q, 1:n1), view(t, 1:n1), wb, μ, linv)
    @inbounds @fastmath @simd for i in 1:n1
        l1[i] = logpB[i] + q[i] / 2 + c0
    end
    # and at the proposal points
    Z = randn(rng, n2, d)
    P = Matrix{Float64}(undef, n2, d)
    _affine!(P, Z, μ, L)
    lp2 = Vector{Float64}(undef, n2)
    tmapBlocks(n2, 128) do blk
        w = Vector{Float64}(undef, d)
        for p in blk
            for i in 1:d
                w[i] = P[p, i]
            end
            v = logp(w)
            lp2[p] = isfinite(v) ? v : -Inf
        end
        nothing
    end
    _quadform!(view(q, 1:n2), view(t, 1:n2), P, μ, linv)
    l2 = Vector{Float64}(undef, n2)
    @inbounds for p in 1:n2
        # −Inf stays −Inf, handled by _weights
        l2[p] = lp2[p] + q[p] / 2 + c0
    end
    # the fixed point, in the scale of the median draw ratio
    shift = median(l1)
    e1 = _weights(l1, shift)
    e2 = _weights(l2, shift)
    s1 = n1 / (n1 + n2)
    s2 = n2 / (n1 + n2)
    r = 1.0
    for _ in 1:BRIDGE_MAX_ITER
        num = 0.0
        den = 0.0
        @inbounds @fastmath @simd for p in 1:n2
            num += e2[p] / (s1 * e2[p] + s2 * r)
        end
        @inbounds @fastmath @simd for i in 1:n1
            den += 1 / (s1 * e1[i] + s2 * r)
        end
        new = (n1 / n2) * num / den
        (isfinite(new) && new > 0) || return NaN
        done = abs(log(new) - log(r)) < BRIDGE_TOL
        r = new
        done && break
    end
    return log(r) + shift
end

"""
Bridge-sampling estimate of the log mass of one mode from its draws:
[`_bridgeHalf`](@ref) twice, each half of the draws fitting the proposal
for the other, averaged. The difference of the two halves gives the error.

# Arguments
-  `W::AbstractMatrix`: the mode's draws in the sampler's whitened coordinates, one draw per
    row, in sampling order (the halves are the first and the second half of the sequence).
-  `logpDraws::AbstractVector`: log π at the rows of `W`.
-  `logp`: `w -> log π(w)`.
-  `rng::AbstractRNG`: the source of the proposal points.

# Returns
-   `NamedTuple` `(logZ, err)`: the estimate of log Z and half the difference between
    the two halves' estimates (an approximate standard error of the mean, in nats).

# Exceptions
- None.
"""
function bridgeLogmass(
    W::AbstractMatrix,
    logpDraws::AbstractVector,
    logp,
    rng::AbstractRNG,
)
    n = size(W, 1)
    h = n ÷ 2
    a = _bridgeHalf(
        view(W, 1:h, :),
        view(W, (h+1):n, :),
        view(logpDraws, (h+1):n),
        logp,
        rng,
    )
    b = _bridgeHalf(view(W, (h+1):n, :), view(W, 1:h, :), view(logpDraws, 1:h), logp, rng)
    return (logZ = (a + b) / 2, err = abs(a - b) / 2)
end

"""
The mass shares of the modes from their log masses: `softmax(logZ)`,
with a mode whose log mass is not finite given zero share.

# Returns
- `Vector{Float64}` summing to 1.

# Exceptions
- None.
"""
function modeWeights(logZ::AbstractVector{<:Real})::Vector{Float64}
    lz = [isfinite(x) ? Float64(x) : -Inf for x in logZ]
    all(==(-Inf), lz) && return fill(1 / length(lz), length(lz))
    w = exp.(lz .- logsumexp(lz))
    return w ./ sum(w)
end

"""
Whether the mode weights cannot be trusted: some mode's log mass has a
bridge-sampling error above [`BRIDGE_MAX_ERR`](@ref) and that error matters,
i.e. the mode's share would be at least [`MODE_NEGLIGIBLE`](@ref) at the log
mass moved up or down by the error. (A mode whose share stays negligible
even at its optimistic estimate cannot change the pool, whatever its error.)

# Arguments
- `logZ`, `err`: the log mass and its error of every mode ([`bridgeLogmass`](@ref)).

# Returns
- `Bool`.

# Exceptions
- None.
"""
function weightsUncertain(logZ::AbstractVector{<:Real}, err::AbstractVector{<:Real})::Bool
    for m in eachindex(logZ)
        (isfinite(err[m]) && err[m] ≤ BRIDGE_MAX_ERR) && continue
        isfinite(logZ[m]) || continue
        for sgn in (-1, 1)
            lz = Float64.(logZ)
            lz[m] += sgn * (isfinite(err[m]) ? err[m] : 0.0)
            modeWeights(lz)[m] ≥ MODE_NEGLIGIBLE && return true
        end
    end
    return false
end

"""
The weights when the bridge-sampling errors are too large to apply the shares
([`weightsUncertain`](@ref)): a mode that is negligible even at its most
optimistic estimate (its log mass raised by its error, every other lowered by
theirs) has weight 0, and the others are weighted by their chain counts, i.e.
the chains of the modes that can matter are pooled as they came.

# Arguments
- `logZ`, `err`: the log mass and its error of every mode.
- `nchains::AbstractVector{Int}`: the chains of every mode.

# Returns
- `Vector{Float64}` summing to 1.

# Exceptions
- None.
"""
function uncertainWeights(
    logZ::AbstractVector{<:Real},
    err::AbstractVector{<:Real},
    nchains::AbstractVector{<:Integer},
)::Vector{Float64}
    e = [isfinite(x) ? Float64(x) : 0.0 for x in err]
    live = map(eachindex(logZ)) do m
        lz = [
            i == m ? Float64(logZ[i]) + e[i] : Float64(logZ[i]) - e[i] for
            i in eachindex(logZ)
        ]
        modeWeights(lz)[m] ≥ MODE_NEGLIGIBLE
    end
    any(live) || (live = trues(length(logZ)))
    w = Float64.(nchains) .* live
    return w ./ sum(w)
end

"""
How many post-warm-up draws per chain each mode keeps so that the pooled draws
carry the modes' mass shares, without repeating a draw: the mode that is most
under-represented by its chain count keeps all its draws and the others are
thinned (evenly) to its share. A mode below [`MODE_NEGLIGIBLE`](@ref) keeps none.

# Arguments
- `weights::AbstractVector`: the mass share of every mode.
- `nchains::AbstractVector{Int}`: the chains of every mode.
- `nPost::Int`: post-warm-up draws per chain.

# Returns
- `Vector{Int}`: draws kept per chain, per mode (at most `nPost`).

# Exceptions
- None.
"""
function drawsPerChain(
    weights::AbstractVector{<:Real},
    nchains::AbstractVector{<:Integer},
    nPost::Int,
)::Vector{Int}
    # share carried by one chain's whole run
    perChain = weights ./ nchains
    live = weights .≥ MODE_NEGLIGIBLE
    top = maximum(perChain[live]; init = 0.0)
    return [
        live[m] && top > 0 ? clamp(round(Int, nPost * perChain[m] / top), 0, nPost) : 0
        for m in eachindex(weights)
    ]
end

"""
`n` indices evenly spread over `1:total` (the thinning of one chain's draws).

# Returns
- `Vector{Int}`, increasing; empty for `n = 0`.
"""
function evenIndices(total::Int, n::Int)::Vector{Int}
    n ≤ 0 && return Int[]
    n ≥ total && return collect(1:total)
    return [clamp(round(Int, (i - 0.5) * total / n), 1, total) for i in 1:n]
end

# ---------------------------------------------------------------------------
#   Chain diagnostics: what a run reports, the convergence gates, why a run fails
# ---------------------------------------------------------------------------

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
Why a run does not count as converged, from its worst R̂, smallest
bulk ESS and smallest tail ESS: R̂ not below [`RHAT_OK`](@ref) or not
computable, or an ESS not above [`ESS_MIN`](@ref) or not computable.
NaN means "could not be computed" and is never read as fine.

# Returns
- `Vector{String}`: one sentence per problem, empty for a converged run.
"""
function _convergenceProblems(rhat::Real, ess::Real, essTail::Real)
    out = String[]
    if !isfinite(rhat)
        push!(out, "R̂ could not be computed (too few draws, or a constant quantity)")
    elseif rhat >= RHAT_OK
        push!(out, "the worst R̂, $(round(rhat; digits = 3)), is not below $RHAT_OK")
    end
    for (name, v) in (("bulk", ess), ("tail", essTail))
        if isnan(v)
            push!(out, "the $name effective sample size could not be computed")
        elseif v <= ESS_MIN
            essText = round(v; digits = 1)
            push!(out, "the smallest $name ESS, $essText, is not above $ESS_MIN")
        end
    end
    return out
end

function _convergenceProblems(d::ChainDiagnostics)
    return _convergenceProblems(_worstRhat(d), _worstEss(d.ess), _worstEss(d.essTail))
end

"""
Thrown by [`infer`](@ref) when the profiled c1 of a four-parameter run is kinked
([`_c1Kinked`](@ref), asked after warm-up): the profile switches between basins, NUTS
cannot sample it, and the run stops at once. [`runModel`](@ref BAYSOL.Pipeline.runModel)
catches it and samples c1 as a fifth parameter instead.
"""
struct KinkDetected <: Exception end

Base.showerror(io::IO, ::KinkDetected) =
    print(io, "KinkDetected: the profiled c1 has a kink, c1 has to be sampled")

"""
Thrown by [`runModel`](@ref BAYSOL.Pipeline.runModel) when a run is still not converged
after its retry: a fit that did not converge has nothing worth reporting, so no result is
returned and no report is written.

# Fields
- `problems::Vector{String}`: why the run does not count as converged.
- `summary::Union{Nothing,NamedTuple}`: the failed attempt's own diagnostics (what
  `runModel` classifies the failure from: worst R̂, smallest ESS, divergent share, tree
  depth, step size, modes), `nothing` when it has none. `NotConvergedError(problems)`
  leaves it out.
"""
struct NotConvergedError <: Exception
    problems::Vector{String}
    summary::Union{Nothing,NamedTuple}
end

NotConvergedError(problems::Vector{String}) = NotConvergedError(problems, nothing)

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
