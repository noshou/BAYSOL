# SPDX-License-Identifier: LGPL-2.1-or-later

# Several NUTS chains per fit: which chains are pooled, and the convergence statistics (rank-normalized split R̂, bulk and tail ESS)
# of the pooled draws. `infer` (Sampler.jl) runs the chains and calls these.

using MCMCDiagnosticTools: MCMCDiagnosticTools
using Statistics: mean

"""
Number of NUTS chains [`infer`](@ref) runs by default: 8. Fixed, not the number of Julia threads: the number of threads only
decides how many chains run at the same time (two rounds on four cores), so the posterior never depends on the machine.
Where the chains start: [`chain_radius`](@ref).
"""
const DEFAULT_N_CHAINS = 8

"""
Distances from the MAP, in posterior standard deviations (the sampler's whitened coordinates, where the posterior is
≈ N(0, I)), at which the mirrored pairs of chains start: pair `p` (two chains) starts at `+r_p·u_p` and `-r_p·u_p` for a
random direction `u_p` on the sphere, so that along each direction both sides of the MAP are started from (the
posteriors are skewed against hard bounds, and the two sides differ). The typical distance of a draw from the MAP in
four dimensions is 2; the far starts are what finds second modes. Pairs beyond `length(CHAIN_START_RADII)` reuse the last
radius.
"""
const CHAIN_START_RADII = (4.0, 10.0, 20.0)

"""
The nominal signed distance from the MAP, in posterior standard deviations, at which chain `k` of `n` starts: a single chain
at the MAP (0); with several, chains 1 and 2 both at the MAP (two independent chains of their own random streams from the
same point: independent effective sample size within the main mode and a baseline for R̂ there), and chains 3 and up in
mirrored pairs at the radii of [`CHAIN_START_RADII`](@ref) (the first of a pair positive, the second negative: the same
random direction, opposite sides).

# Returns
- `Float64`.

# Exceptions
- None.
"""
function chain_radius(k::Int, n::Int)::Float64
    (n == 1 || k ≤ 2) && return 0.0
    r = CHAIN_START_RADII[min((k - 1) ÷ 2, length(CHAIN_START_RADII))]
    return isodd(k) ? r : -r
end

"""
Default `jitter_seed` of [`infer`](@ref): the jittered starts come from streams of this value (never of the run's
`rng_seed`), so they are the same in every run unless the caller changes it.
"""
const DEFAULT_JITTER_SEED = UInt64(0x6a697474657273)   # "jitters"

"""
A jittered start whose log π is not finite (or whose gradient is not) is pulled halfway back toward the MAP
at most this many times; if it never becomes usable the chain starts at the MAP and is marked as such.
"""
const CHAIN_JITTER_MAX_HALVINGS = 8

"""
If the best post-warm-up draw of the first round of chains beats log π at the MAP the sampler was whitened at by more
than this many nats, the MAP search missed a better basin (a draw of a four-parameter posterior sits about 1.7 nats below
its mode, so this is clear evidence): the sampler re-whitens at that draw's basin and runs the chains once more.
"""
const BASIN_RESTART_NATS = 2.0

"A chain is not pooled when more than this fraction of its post-warm-up transitions diverged."
const CHAIN_MAX_DIVERGENT = 0.5

"The rank-normalized split R̂ below which the pooled chains are reported as converged (Stan's recommendation)."
const RHAT_OK = 1.01

"""
Convergence statistics of the pooled chains' post-warm-up draws, from MCMCDiagnosticTools.jl (Vehtari et al., 2021): the
rank-normalized split R̂ (`rhat(kind = :rank)`: the larger of the value on the rank-normalized draws, which asks
whether the chains agree in location, and on the rank-normalized draws folded around the median, which asks whether they
agree in scale and tails), the bulk effective sample size (how many independent draws the centre of the distribution
is worth) and the tail effective sample size (the same for the 5 % and 95 % quantiles, which the report's intervals and
curve bands are made of). Every chain is split in halves first, so a chain that drifts shows up as two that disagree.

# Arguments
- `x::AbstractArray{<:Real,3}`: the draws, `draws × chains × quantities`.

# Returns
- `NamedTuple` `(rhat, ess, ess_tail)` of vectors with one entry per quantity; all `NaN` when a chain has fewer than 8
  draws (the statistics need at least 4 per half).

# Exceptions
- None.
"""
function convergence(x::AbstractArray{<:Real,3})
    n, _, q = size(x)
    n < 8 && return (rhat = fill(NaN, q), ess = fill(NaN, q), ess_tail = fill(NaN, q))
    return (rhat = vec(MCMCDiagnosticTools.rhat(x; kind = :rank)),
            ess = vec(MCMCDiagnosticTools.ess(x; kind = :bulk)),
            ess_tail = vec(MCMCDiagnosticTools.ess(x; kind = :tail)))
end

"""
    ChainDiagnostics

What the chains of one [`infer`](@ref) call looked like.

# Fields
- `n_chains::Int`: chains run.
- `start_scale::Vector{Float64}`: per chain, the signed distance of its start from the MAP in posterior standard
    deviations (negative: the mirrored chain of a pair; 0: the MAP): the distance actually used, after any halving, see
    [`CHAIN_JITTER_MAX_HALVINGS`](@ref) and [`chain_radius`](@ref).
- `pooled::Vector{Bool}`: per chain, whether it was pooled.
- `reason::Vector{String}`: per chain, `"ok"` or why it was not pooled.
- `rhat::Vector{Float64}`: [`convergence`](@ref)'s R̂ over each mode's chains' post-warm-up draws (the worst of the modes
    that keep draws, see [`MODE_NEGLIGIBLE`](@ref)), one
    entry per coordinate of ξ followed by log π (with one chain in a mode it compares its two halves).
- `ess::Vector{Float64}`: the bulk effective sample size, same layout.
- `ess_tail::Vector{Float64}`: the tail effective sample size, same layout.
- `rewhitened::Float64`: 0, or the nats by which the first round of chains found a better basin than the MAP search
    ([`BASIN_RESTART_NATS`](@ref)): the sampler was then re-whitened there and the chains rerun, and these diagnostics are
    those of the second round.
- `mode::Vector{Int}`: per chain, the posterior mode it settled in (chains that agree, [`chain_modes`](@ref)); 0 for a
    chain that was not pooled.
- `mode_weight::Vector{Float64}`: per mode, its share of the posterior mass; the pooled draws carry these shares.
- `mode_logmass::Vector{Float64}`: per mode, the bridge-sampling estimate of log mass ([`bridge_logmass`](@ref)).
- `mode_err::Vector{Float64}`: per mode, its approximate standard error in nats.
- `weights_uncertain::Bool`: whether a bridge-sampling error was too large to apply the weights ([`weights_uncertain`](@ref)):
    the chains of the modes that can matter were then pooled as they came, and `mode_weight` is each mode's share of those
    chains (0 for a mode that is negligible even at its most optimistic estimate).
"""
struct ChainDiagnostics
    n_chains::Int
    start_scale::Vector{Float64}
    pooled::Vector{Bool}
    reason::Vector{String}
    rhat::Vector{Float64}
    ess::Vector{Float64}
    ess_tail::Vector{Float64}
    rewhitened::Float64
    mode::Vector{Int}
    mode_weight::Vector{Float64}
    mode_logmass::Vector{Float64}
    mode_err::Vector{Float64}
    weights_uncertain::Bool
end

"""
Which chains are pooled: every chain that ran, unless it failed or more than [`CHAIN_MAX_DIVERGENT`](@ref) of its
post-warm-up transitions diverged. (A chain in a poorer mode is not dropped for that: the modes are weighted by their
mass, see [`bridge_logmass`](@ref).) `div_rate[j]` is chain `j`'s divergent fraction and `error[j]` is `nothing` or why
the chain could not be run.

# Returns
- `(pooled::Vector{Bool}, reason::Vector{String})`, the reason being `"ok"` for a pooled chain.

# Exceptions
- None.
"""
function select_chains(div_rate::AbstractVector{<:Real}, error::AbstractVector)
    pooled = fill(true, length(error))
    reason = fill("ok", length(error))
    for j in eachindex(error)
        if error[j] !== nothing
            pooled[j] = false
            reason[j] = "sampler error: $(error[j])"
        elseif div_rate[j] > CHAIN_MAX_DIVERGENT
            pooled[j] = false
            reason[j] = "$(round(Int, 100 * div_rate[j])) % of transitions diverged"
        end
    end
    return pooled, reason
end
