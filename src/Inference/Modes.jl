# SPDX-License-Identifier: LGPL-2.1-or-later

# Several posterior modes: chains that settled in different modes are grouped, each
# mode's probability mass is estimated by bridge sampling, and the pooled draws are
# thinned to the modes' mass shares. NUTS chains do not jump between modes, so pooling
# them as they come would weight the modes by how many chains happened to start in each.

using ..Runtime: tmap_blocks
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
function chain_modes(cube::AbstractArray{<:Real,3})::Vector{Int}
    m = size(cube, 2)
    # all chains agree (the usual case): one mode, one call
    m == 1 || any(isnan, convergence(cube).rhat) ||
        all(≤(MODE_RHAT), convergence(cube).rhat) && return ones(Int, m)
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
`q[p] = ‖L⁻¹(W[p, :] − μ)‖²` for every row of `W` (`Linv` is
L⁻¹, lower triangular), vectorized across the rows: the columns
of `W` are contiguous, so every inner loop runs down a column.
"""
function _quadform!(q::AbstractVector{Float64}, t::AbstractVector{Float64},
    W::AbstractMatrix{Float64}, μ::Vector{Float64},
    Linv::Matrix{Float64})
    n, d = size(W)
    fill!(q, 0.0)
    for i in 1:d
        fill!(t, 0.0)
        for j in 1:i
            c = Linv[i, j]
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
of the mode (rows) with their log densities `logp_b`: a Gaussian proposal g is
fitted to the other half `Wa`, as many points are drawn from it as there are draws
in `Wb`, and Meng and Wong's optimal bridge iteration is run to its fixed point,

    r ← (N₁/N₂) Σⱼ lⱼ / (s₁lⱼ + s₂r)  /  Σᵢ 1 / (s₁lᵢ + s₂r),    l = p/g,

`i` over the draws, `j` over the proposal points, `s₁ = N₁/(N₁+N₂)`,
`s₂ = N₂/(N₁+N₂)`. The ratios are taken relative to the median draw ratio, so that the
sums stay in range. The densities at the proposal points are evaluated in parallel.

# Arguments
- `Wa`, `Wb::AbstractMatrix{Float64}`: the fitting half and
    the estimating half of the mode's draws, one draw per row.
- `logp_b::AbstractVector`: log π at the rows of `Wb`.
- `logp`: `w -> log π(w)`, called on a `Vector{Float64}`;
    a non-finite value counts as zero density.
- `rng::AbstractRNG`: the source of the proposal points.

# Returns
- `Float64`: the estimate of log Z (`NaN` if the proposal
    covariance is singular or a draw's density is `NaN`).

# Exceptions
- None.
"""
function _bridge_half(Wa::AbstractMatrix{Float64}, Wb::AbstractMatrix{Float64},
    logp_b::AbstractVector{<:Real}, logp,
    rng::AbstractRNG)::Float64
    n1, d = size(Wb)
    na = size(Wa, 1)
    any(isnan, logp_b) && return NaN
    # the proposal: the Gaussian of the fitting half
    μ = [sum(view(Wa, :, j)) / na for j in 1:d]
    X = Wa .- μ'
    Σ = (X' * X) ./ (na - 1)
    F = cholesky(Symmetric(Σ + 1e-10 * max(1.0, maximum(diag(Σ))) * one(Σ)); check = false)
    issuccess(F) || return NaN
    L = Matrix(F.L)
    Linv = Matrix(inv(LowerTriangular(L)))
    # log of the Gaussian's normalization
    c0 = sum(log, diag(L)) + d / 2 * log(2π)
    n2 = n1
    q = Vector{Float64}(undef, max(n1, n2))
    t = similar(q)
    # the log ratios l = log p − log g at the draws
    l1 = Vector{Float64}(undef, n1)
    _quadform!(view(q, 1:n1), view(t, 1:n1), Wb, μ, Linv)
    @inbounds @fastmath @simd for i in 1:n1
        l1[i] = logp_b[i] + q[i] / 2 + c0
    end
    # and at the proposal points
    Z = randn(rng, n2, d)
    P = Matrix{Float64}(undef, n2, d)
    _affine!(P, Z, μ, L)
    lp2 = Vector{Float64}(undef, n2)
    tmap_blocks(n2, 128) do blk
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
    _quadform!(view(q, 1:n2), view(t, 1:n2), P, μ, Linv)
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
[`_bridge_half`](@ref) twice, each half of the draws fitting the proposal
for the other, averaged. The difference of the two halves gives the error.

# Arguments
- `W::AbstractMatrix`: the mode's draws in the sampler's whitened coordinates, one draw per
  row, in sampling order (the halves are the first and the second half of the sequence).
- `logp_draws::AbstractVector`: log π at the rows of `W`.
- `logp`: `w -> log π(w)`.
- `rng::AbstractRNG`: the source of the proposal points.

# Returns
- `NamedTuple` `(logZ, err)`: the estimate of log Z and half the difference between
  the two halves' estimates (an approximate standard error of the mean, in nats).

# Exceptions
- None.
"""
function bridge_logmass(
    W::AbstractMatrix,
    logp_draws::AbstractVector,
    logp,
    rng::AbstractRNG,
)
    n = size(W, 1)
    h = n ÷ 2
    a = _bridge_half(
        view(W, 1:h, :),
        view(W, (h+1):n, :),
        view(logp_draws, (h+1):n),
        logp,
        rng,
    )
    b = _bridge_half(view(W, (h+1):n, :), view(W, 1:h, :), view(logp_draws, 1:h), logp, rng)
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
function mode_weights(logZ::AbstractVector{<:Real})::Vector{Float64}
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
- `logZ`, `err`: the log mass and its error of every mode ([`bridge_logmass`](@ref)).

# Returns
- `Bool`.

# Exceptions
- None.
"""
function weights_uncertain(logZ::AbstractVector{<:Real}, err::AbstractVector{<:Real})::Bool
    for m in eachindex(logZ)
        (isfinite(err[m]) && err[m] ≤ BRIDGE_MAX_ERR) && continue
        isfinite(logZ[m]) || continue
        for sgn in (-1, 1)
            lz = Float64.(logZ)
            lz[m] += sgn * (isfinite(err[m]) ? err[m] : 0.0)
            mode_weights(lz)[m] ≥ MODE_NEGLIGIBLE && return true
        end
    end
    return false
end

"""
The weights when the bridge-sampling errors are too large to apply the shares
([`weights_uncertain`](@ref)): a mode that is negligible even at its most
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
function uncertain_weights(
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
        mode_weights(lz)[m] ≥ MODE_NEGLIGIBLE
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
- `n_post::Int`: post-warm-up draws per chain.

# Returns
- `Vector{Int}`: draws kept per chain, per mode (at most `n_post`).

# Exceptions
- None.
"""
function draws_per_chain(
    weights::AbstractVector{<:Real},
    nchains::AbstractVector{<:Integer},
    n_post::Int,
)::Vector{Int}
    # share carried by one chain's whole run
    per_chain = weights ./ nchains
    live = weights .≥ MODE_NEGLIGIBLE
    top = maximum(per_chain[live]; init = 0.0)
    return [
        live[m] && top > 0 ? clamp(round(Int, n_post * per_chain[m] / top), 0, n_post) : 0
        for m in eachindex(weights)
    ]
end

"""
`n` indices evenly spread over `1:total` (the thinning of one chain's draws).

# Returns
- `Vector{Int}`, increasing; empty for `n = 0`.
"""
function even_indices(total::Int, n::Int)::Vector{Int}
    n ≤ 0 && return Int[]
    n ≥ total && return collect(1:total)
    return [clamp(round(Int, (i - 0.5) * total / n), 1, total) for i in 1:n]
end
