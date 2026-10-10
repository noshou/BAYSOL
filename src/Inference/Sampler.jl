# SPDX-License-Identifier: LGPL-2.1-or-later

using   AdvancedHMC: DenseEuclideanMetric, Hamiltonian, MassMatrixAdaptor,
        find_good_stepsize, Leapfrog, StanHMCAdaptor, StepSizeAdaptor, sample,
        HMCKernel, Trajectory, MultinomialTS, GeneralisedNoUTurn
using   FastClosures, StaticArrays, Distributions, ForwardDiff, DiffResults
using   SpecialFunctions: digamma, trigamma
using ..Scattering: ForwardCache
using ..PhysicalConstants: NS_PER_S, MS_PER_S
using ..Timing: StageLog, tick, tock!, fmt_count
using Printf: @sprintf
using ..Parallel: tmap_items

"""
Generates physical prior distributions of ξ.

# Arguments
- `pH::Real`: pH of the solution; forwarded to PartialMolarVolumes.ϕ° for Protein solutes.
- `σ_pH::Real`: standard uncertainty on pH, propagated through each Protein
    solute's titration term.
- `solutes::Vector{Solute}`: the species in solution.

# Keywords
- `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`ρₑ_prior`](@ref).
- `κ_δρ₁₂::Real = κ_δρ₁₂`: concentration of the δρ₁/δρ₂ priors,
    forwarded to [`δρ_prior`](@ref).
- `κ_δρ₃::Real = κ_δρ₃`: concentration of the δρ₃ prior,
    forwarded to [`δρ_prior`](@ref).

# Returns
- `ξ_priors`: the priors. δρ₃'s bounds are fixed at the mean of the ρₑ prior.
"""
function _calc_ξ_priors(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
)::ξ_priors
    ρₑ = ρₑ_prior(pH, σ_pH, solutes; t=t)
    δρ₁, δρ₂, δρ₃ = δρ_prior(κ_δρ₁₂, κ_δρ₃, mean(ρₑ))
    return ξ_priors(ρₑ, δρ₁, δρ₂, δρ₃)
end

"""
Generates an initial physical parameter vector ξ₀, one draw from each prior.

# Arguments
- `p::ξ_priors`: the priors to draw from.

# Returns
- `ξ₀::SVector{4,<:Real} = (ρₑ, δρ₁, δρ₂, δρ₃)`.
"""
function _ξ₀(p::ξ_priors, rng::AbstractRNG = Random.default_rng())::SVector{4,<:Real}
    ρₑ = rand(rng, p.ρₑPrior)
    δρ₁ = rand(rng, p.δρ₁Prior)
    δρ₂ = rand(rng, p.δρ₂Prior)
    δρ₃ = rand(rng, p.δρ₃Prior)
    return SVector(ρₑ, δρ₁, δρ₂, δρ₃)
end

"""
Per-coordinate prior mean and standard deviation in θ-space, used by
[`_standardize`](@ref) and the [`_SamplingSpace`](@ref) map to rescale θ before
handing it to AdvancedHMC.jl, and by [`prior_z_scores`](@ref).

All four are exact. a = ln ρₑ is Normal(`μ_ln`, `σ_ln`) under its LogNormal
prior. For the other three coordinates, tₖ = logit(uₖ) with uₖ ~ Beta(α, β)
the prior's unit-interval variable (uₖ = (δρₖ + 10)/12 for δρ₁, δρ₂ and
u = (δρ₃ − L₃)/W₃ for δρ₃):

    E[t] = ψ(α) - ψ(β),    Var[t] = ψ₁(α) + ψ₁(β)

(ψ the digamma, ψ₁ the trigamma function).

# Arguments
- `p::ξ_priors`: the priors.

# Returns
- `(μ, σ)::Tuple{SVector{4,Float64},SVector{4,Float64}}`: per-coordinate
    θ-space prior mean and standard deviation.
"""
function θ_prior_moments(p::ξ_priors)::Tuple{SVector{4,Float64},SVector{4,Float64}}
    μ₁, σ₁ = _logit_moments(p.δρ₁Prior.ρ)
    μ₂, σ₂ = _logit_moments(p.δρ₂Prior.ρ)
    μ₃, σ₃ = _logit_moments(p.δρ₃Prior.ρ)
    μ = SVector(p.ρₑPrior.μ, μ₁, μ₂, μ₃)
    σ = SVector(p.ρₑPrior.σ, σ₁, σ₂, σ₃)
    return μ, σ
end

"Mean and standard deviation of logit(u), u ~ b: (ψ(α) - ψ(β), √(ψ₁(α) + ψ₁(β)))."
function _logit_moments(b::Beta)
    α, β = params(b)
    return digamma(α) - digamma(β), sqrt(trigamma(α) + trigamma(β))
end

"""
Affine map from θ-space to a prior-standardized z-space, z = (θ - μ) / σ, with (μ, σ)
from [`θ_prior_moments`](@ref).

θ's four coordinates have wildly different natural (prior) scales. In z-space each
`z_i` is standard-Normal-like under the prior, so the MAP search's L-BFGS starts
(see [`_SamplingSpace`](@ref)) and its first Hessian probe step see O(1) scales in
every coordinate. NUTS itself samples a further whitened coordinate w,
z = ẑ + S·w; the inverse map back to θ is [`_θ_of_w`](@ref).

The Jacobian of the map (|dθ/dz| = `Πσ_i`) is a z-independent constant, so it is
omitted from the log-density in z (and w) space.

# Arguments
- `θ::SVector{N,<:Real}`: a θ-space point.
- `p::ξ_priors`: supplies (μ, σ) via [`θ_prior_moments`](@ref).

# Returns
- `SVector{N,<:Real}`: z.
"""
function _standardize(θ::SVector{N,<:Real}, p::ξ_priors) where {N}
    μ, σ = θ_prior_moments(p)
    return (θ .- μ) ./ σ
end

"""
How many prior standard deviations a physical-space point ξ = (ρₑ, δρ₁,
δρ₂, δρ₃) sits from its own prior p.

z = (θ - μ) / σ in θ-space, where θ = Θ(ξ, p) and (μ, σ) are the prior's
per-coordinate θ-space mean/std from [`θ_prior_moments`](@ref).

# Arguments
- `ξ::SVector{N,<:Real}`: the physical-space point to score.
- `p::ξ_priors`: supplies (μ, σ) via [`θ_prior_moments`](@ref).
"""
function prior_z_scores(ξ::SVector{N,<:Real}, p::ξ_priors)::SVector{N,Float64} where {N}
    θ, _ = Θ(ξ, p)
    μ, σ = θ_prior_moments(p)
    return (θ .- μ) ./ σ
end

"Dispatch tag selecting profile vs. marginal log-likelihood in [`_ll`](@ref)."
abstract type LIKELIHOOD end

"""
Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale scale and background offset
`bkgrnd_corr`, i.e. `I_calc` = scale·`y_model` + `bkgrnd_corr`. WLS.jl fits
(scale, `bkgrnd_corr`) in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by l:

- `l = PROFILE()`: treat (scale, `bkgrnd_corr`) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, `bkgrnd_corr`), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, `bkgrnd_corr`) [`wls_marg_ll`](@ref).
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"""
struct PROFILE<:LIKELIHOOD
    type::AbstractString
    PROFILE() = new("profile_log_likelihood")
end

"""
Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale scale and background offset
`bkgrnd_corr`, i.e. `I_calc` = scale·`y_model` + `bkgrnd_corr`. WLS.jl fits
(scale, `bkgrnd_corr`) in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by l:

- `l = PROFILE()`: treat (scale, `bkgrnd_corr`) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, `bkgrnd_corr`), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, `bkgrnd_corr`) [`wls_marg_ll`](@ref).
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"""
struct MARGINAL<:LIKELIHOOD
    type::AbstractString
    MARGINAL() = new("marginal_log_likelihood")
end

""" Returns the log-likelihood of a WLS fit under the given likelihood type. """
__ll(fit::WLSFit, ::PROFILE)  = wls_prof_ll(fit)
__ll(fit::WLSFit, ::MARGINAL) = wls_marg_ll(fit)

"""
Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale scale and background offset
`bkgrnd_corr`, i.e. `I_calc` = scale·`y_model` + `bkgrnd_corr`. WLS.jl fits
(scale, `bkgrnd_corr`) in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by l:

- `l = PROFILE()`: treat (scale, `bkgrnd_corr`) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, `bkgrnd_corr`), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, `bkgrnd_corr`) [`wls_marg_ll`](@ref).
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.

# Arguments
-   `wls::WLSData`: precomputed data-only weighted sums over (`I_exp`, `σ_exp`),
    from [`WLSData`](@ref); forwarded to [`profiled_corrs`](@ref).
-   `ξ::SVector{N,<:Real}`: the physical fit parameters, (ρₑ, δρ₁, δρ₂, δρ₃) for `N = 4`.
-   `fw::ForwardCache`: the structure's static cache, from
    [`BAYSOL.Scattering.forward_cache`](@ref).
-   `l::LIKELIHOOD`: `PROFILE()` or `MARGINAL()`, selecting which log-likelihood
    variant to return.

# Keywords
- `tab::Union{Nothing,_C1Tables} = nothing`, `c1_tol = EXCL_VOL_CORR_TOL`: forwarded to
    [`profiled_corrs`](@ref) as `tables`/`tol`.

# Returns
- `Real`: the log-likelihood, composing by addition with the log-prior terms.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{N,<:Real},
    fw::ForwardCache,
    l::LIKELIHOOD;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N}
    _, fit, _ = profiled_corrs(wls, ξ, fw; tables = tab, tol = c1_tol)
    return __ll(fit, l)
end

"""
[`_ll`](@ref) for the profile likelihood at a ForwardDiff dual ξ: the
value and the gradient with respect to ξ come from [`_profile_ll_grad`](@ref)
(analytic, no dual-number vectors through the forward model), and are
composed with the partials of ξ, so `ForwardDiff.gradient` of any
function of θ sees the exact chain rule. The marginal likelihood keeps
the generic path above.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{N,D},
    fw::ForwardCache,
    ::PROFILE;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N,D<:ForwardDiff.Dual{<:Any,Float64}}
    tb = tab === nothing ? _C1Tables(fw) : tab
    ll, g = _profile_ll_grad(wls, SVector{N,Float64}(ForwardDiff.value.(ξ)), fw, tb, c1_tol)
    parts = ntuple(
        j -> sum(ntuple(k -> g[k] * ForwardDiff.partials(ξ[k], j), Val(N))),
        Val(ForwardDiff.npartials(D))
    )
    return ForwardDiff.Dual{ForwardDiff.tagtype(D)}(
        ll,
        ForwardDiff.Partials(parts)
    )
end

"""
Log prior density of ξ = (ρₑ, δρ₁, δρ₂, δρ₃) in ξ-space. The δρ `LocationScale`
priors carry their own -ln W terms.
"""
_lp(ξ::SVector{4,<:Real}, p::ξ_priors) =
    logpdf(p.ρₑPrior, ξ[1]) +
    logpdf(p.δρ₁Prior, ξ[2]) +
    logpdf(p.δρ₂Prior, ξ[3]) +
    logpdf(p.δρ₃Prior, ξ[4])

"""
By change of variables, a density trasnfromed from ξ-space into θ-space picks
up the Jacobian of ξ(θ):

    log π(θ) = log p(ξ(θ)) + log|det(∂ξ/∂θ)|

Every coordinate is reparameterized (see [`Θ`](@ref)):

    - ρₑ  = eᵃ
    - δρ₁ = -10 + 12·σ(t₁)
    - δρ₂ = -10 + 12·σ(t₂)
    - δρ₃ = L₃ + W₃·σ(t₃)

So ∂ξ/∂θ is diagonal, giving:

    log|det(∂ξ/∂θ)| = a + Σₖ [ln Wₖ + ln σ(tₖ) + ln(1 - σ(tₖ))] ([`logjac`](@ref))

with W₁ = W₂ = 12 and (L₃, W₃) the δρ₃ prior's location and scale.

log p(ξ(θ)) is the sum of the log-prior and log-likelihood:

    log p(ξ | data) = log p(ξ) + log p(data | ξ) = _lp(ξ, p) + _ll(wls, ξ, fw, l)

giving:

    log π(θ) = _lp(ξ(θ), p) + _ll(wls, ξ(θ), fw, l) + logjac(θ)

# Arguments
- `θ::SVector{N,<:Real}`: the current NUTS position, (a, t₁, t₂, t₃) for `N = 4`.
- `p::ξ_priors`: the physical priors, forwarded to [`_lp`](@ref).
- `wls::WLSData`: the precomputed data, forwarded to [`_ll`](@ref).
- `fw::ForwardCache`: the structure's geometry-only cache, forwarded to [`_ll`](@ref).
- `l::LIKELIHOOD`: PROFILE() or MARGINAL(), forwarded to [`_ll`](@ref).

# Keywords
- `tab`, `c1_tol`: forwarded to [`_ll`](@ref).

# Returns
- `Real`: log π(θ), up to the additive constant NUTS doesn't need.
"""
function _logπ(
    θ::SVector{N,<:Real},
    p::ξ_priors,
    wls::WLSData,
    fw::ForwardCache,
    l::LIKELIHOOD;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
) where {N}
    ξ = Ξ(θ, p)  # unconstrained θ-space -> physical ξ-space
    return _lp(ξ, p) + _ll(wls, ξ, fw, l; tab = tab, c1_tol = c1_tol) + logjac(θ, p)
end

"""
    Seed{T<:Real,N}

Everything [`infer`](@ref) needs to start a NUTS chain.

# Fields
-   `pr::ξ_priors`: the physical priors over ξ, from [`_calc_ξ_priors`](@ref).
-   `θ₀::SVector{N,T}`: one draw from pr ([`_ξ₀`](@ref)), reparameterized into
    unconstrained θ-space via [`Θ`](@ref); the first start of the MAP search.
-   `fw::ForwardCache`: the structure's geometry-only cache (the Gram matrix
    G(q), q-grid, and mean atomic radius), from `forward_cache`.
-   `wls::WLSData`: the measured intensity curve and its per-point standard
    errors, precomputed into [`WLSData`](@ref) once so the NUTS hot path
    (`_ll`/`_logπ`) never rebuilds the data-only weighted sums.
-   `timing::Union{Nothing,StageLog}`: the run's stage log, if timing is on;
    [`infer`](@ref) appends its stages and hands it on in the [`Inferred`](@ref).
-   `c1tab::_C1Tables`: the static c1-search tables for fw ([`_C1Tables`](@ref)), built
    once here and passed to every [`profiled_corrs`](@ref) call; read-only, so safe to
    share across threads.
-   `shannon::Union{Nothing,ShannonInfo}`: how the measured curve was reduced to the
    data `wls` holds (diameter, band limit, binning, raw data), when it came
    through [`Shannon.shannon_data`](@ref BAYSOL.Utils.Shannon.shannon_data);
    `nothing` otherwise.
"""
struct Seed{T<:Real,N}
    pr::ξ_priors
    θ₀::SVector{N,T}
    fw::ForwardCache
    wls::WLSData
    timing::Union{Nothing,StageLog}
    c1tab::_C1Tables
    shannon::Union{Nothing,ShannonInfo}
end

"""
Runs initial seeding for the sampler.

# Arguments
- `fw::ForwardCache`: Cache of the forward model
- `I_exp::AbstractVector`: Experimental intensity curve
- `σ_exp::AbstractVector`: Per-q standard deviation
- `pH::Real`: pH of the solution; forwarded to PartialMolarVolumes.ϕ° for
    Protein solutes.
- `σ_pH::Real`: standard uncertainty on pH, propagated through each Protein
    solute's titration term.
- `solutes::Vector{Solute}`: the species in solution.

# Keywords
- `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`ρₑ_prior`](@ref).
- `κ_δρ₁₂::Real = κ_δρ₁₂`, `κ_δρ₃::Real = κ_δρ₃`:
    prior concentrations, forwarded to [`δρ_prior`](@ref).
- `timing::Union{Nothing,StageLog} = nothing`: stored in the returned `Seed`.
- `shannon::Union{Nothing,ShannonInfo} = nothing`: stored in the returned `Seed`.

# Returns
- `Seed`: priors, initial point, forward cache, and data.
"""
function seed_sampler(
    fw::ForwardCache,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    κ_δρ₁₂::Real = κ_δρ₁₂,
    κ_δρ₃::Real = κ_δρ₃,
    timing::Union{Nothing,StageLog} = nothing,
    shannon::Union{Nothing,ShannonInfo} = nothing,
)::Seed
    pr = _calc_ξ_priors(pH, σ_pH, solutes; t=t, κ_δρ₁₂=κ_δρ₁₂, κ_δρ₃=κ_δρ₃)
    ξ₀ = _ξ₀(pr)
    θ₀, _ = Θ(ξ₀, pr)
    wls = WLSData(I_exp, σ_exp)
    return Seed(pr, θ₀, fw, wls, timing, _C1Tables(fw), shannon)
end

"""
    Inferred{S,N}

The result of [`infer`](@ref) (and, minus the warm-up draws, of `BAYSOL.run_model`): the posterior
draws of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one
(scale, `bkgrnd_corr`, c1) triple and predicted curve per draw, and
AdvancedHMC.jl's own per-iteration diagnostics.

# Fields
- `samples::Vector{SVector{N,Float64}}`: posterior draws of ξ, `n_samples` per pooled chain.
- `stats::Vector{S}`: AdvancedHMC.jl's per-iteration diagnostics, matching
    samples index-for-index.
- `scale::Vector{Float64}`: the WLS estimate of the scale correction at samples[i].
- `bkgrnd_corr::Vector{Float64}`: the WLS estimate of the background correction at samples[i].
- `c1::Vector{Float64}`: the profiled excluded-volume correction
    ([`profiled_corrs`](@ref)) at samples[i]. Profiled, not sampled -- it
    has no prior and therefore no z-score, unlike `samples`.
- `chisq_red::Vector{Float64}`:  the reduced χ² of the WLS estimate
- `curves::Matrix{Float64}, (Q, n_samples)`: the detector-scale predicted
    curve `I_calc(q)` = scale[i]·`y_model(q)` + `bkgrnd_corr[i]` for each
    samples[i], column-matching `scale/bkgrnd_corr`, with the model `y_model` the
    five-species contraction v(q)ᵀ G(q) v(q) at samples[i] and c1[i].
- `chain::Vector{Int}`: the chain each draw comes from (only the pooled chains are kept, see
    [`ChainDiagnostics`](@ref)); the draws are stored chain after chain.
- `iteration::Vector{Int}`: the draw's iteration within its chain, 1 to `n_samples` (the first `n_adapt` are warm-up).
- `diagnostics::ChainDiagnostics`: which chains were pooled and why not, the start scale of each, and the split R̂ and
    ESS of the pooled post-warm-up draws.
- `likelihood::AbstractString`: the likelihood type
- `timing::Union{Nothing,StageLog}`: the run's stage log (from the `Seed`), if timing is on.
"""
struct Inferred{S,N}
    samples::Vector{SVector{N,Float64}}
    stats::Vector{S}
    scale::Vector{Float64}
    bkgrnd_corr::Vector{Float64}
    c1::Vector{Float64}
    chisq_red::Vector{Float64}
    curves::Matrix{Float64}
    chain::Vector{Int}
    iteration::Vector{Int}
    diagnostics::ChainDiagnostics
    likelihood::AbstractString
    timing::Union{Nothing,StageLog}
end

"Purpose tags of [`Parallel.stream`](@ref BAYSOL.Runtime.Parallel.stream): which use of randomness a stream is for."
const _RNG_MAP_STARTS = 1
const _RNG_NUTS       = 2
const _RNG_JITTER     = 3
const _RNG_BRIDGE     = 4

"""
Run NUTS on [`_logπ`](@ref) starting from seed, returning posterior draws
of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one (scale,
`bkgrnd_corr`) pair per draw (see # Returns below), and AdvancedHMC.jl's
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

Before NUTS, [`_sampling_space`](@ref) runs multi-start L-BFGS on the same log π
to find its mode, takes a central-difference Hessian there, and NUTS then samples
w with θ = μ + σ·(ẑ + S·w), in which the posterior is ≈ N(0, I) and the chain
starts at the mode. The map is affine, so the target is unchanged; it only puts
Stan's adaptation (identity starting metric, covariance shrunk toward 1e-3·I) on
the O(1) scales it assumes, instead of posteriors up to ~10⁴ times narrower
than the prior along some directions.

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first `n_adapt` iterations,
StepSizeAdaptor tunes the leapfrog step size ε via dual-averaging so the
empirical acceptance rate converges to δ; too-small ε wastes computation
taking tiny steps, too-large ε causes leapfrog's discretization error (and
therefore the rejection rate) to blow up. A gradient that is inconsistent with the value
(a loosely profiled c1, see [`EXCL_VOL_CORR_TOL`](@ref)) has the same effect and shows up as a
step size far below what the local curvature allows. MassMatrixAdaptor learns M (here the
full parameter covariance, since ρₑ/δρ are physically coupled through the
forward model) from the trajectory's sample covariance.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `n_samples::Int64`: total number of NUTS iterations.
- `n_adapt::Int64`: number of warm-up iterations spent adapting the step
                        size and mass matrix before sampling proper.

# Keywords
- `l::LIKELIHOOD=PROFILE()`: PROFILE() or MARGINAL(), forwarded to
                                [`_logπ`](@ref)/[`_ll`](@ref).
- `δ::Real=DEFAULT_TARGET_ACCEPT`: target acceptance rate as a percentage,
                                (0, 100) exclusive; the default,
                                [`DEFAULT_TARGET_ACCEPT`](@ref), is Stan's usual 80%.
- `n_chains::Int=DEFAULT_N_CHAINS`: number of NUTS chains ([`DEFAULT_N_CHAINS`](@ref) = 8, whatever the number of
                                Julia threads; the threads only decide how many run at once). Chain 1 starts at the MAP,
                                the others at deterministic distances from it ([`chain_radius`](@ref)). Each chain
                                adapts on its own; chains that did not fail are pooled, the modes they settled in weighted
                                by their mass (see [`bridge_logmass`](@ref)). With `n_chains = 1` the run is the
                                single-chain run of earlier versions.
- `jitter_seed::Integer=DEFAULT_JITTER_SEED`: seed of the jittered starts, separate from `rng_seed`: the same
                                `jitter_seed` gives the same starts whatever the `rng_seed` or the thread count.
- `rng_seed::Union{Nothing,Integer}=nothing`: the run's random seed. Every random draw of the run (the extra
                                MAP starts, the NUTS chain) comes from a stream derived from it by the draw's
                                index, so the same `rng_seed` reproduces the run exactly, whatever the number of
                                Julia threads. `nothing` draws a fresh one from the default RNG (so `Random.seed!`
                                before the call also fixes it); it is printed in the report's `=== Run ===` section.

# Returns
An [`Inferred`](@ref) of the pooled chains, chain after chain. Includes the `n_adapt` warm-up draws of each chain;
a caller that wants a warm-up-free posterior drops the draws with `iteration ≤ n_adapt` out of every field itself.

# Exceptions
- `DomainError` for `n_chains < 1`, `δ` outside (0, 100) or `n_adapt ≥ n_samples`.
- The first chain's error if no chain could be run.
"""
function infer(
    seed::Seed,
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD=PROFILE(),
    δ::Real=DEFAULT_TARGET_ACCEPT,
    rng_seed::Union{Nothing,Integer}=nothing,
    n_chains::Int=DEFAULT_N_CHAINS,
    jitter_seed::Integer=DEFAULT_JITTER_SEED
)::Inferred
    n_chains ≥ 1 || throw(DomainError(n_chains, "n_chains must be ≥ 1"))
    base = rng_seed === nothing ? draw_base() : (rng_seed % UInt64)
    return with_gc_paused(() -> _infer(seed, n_samples, n_adapt; l = l, δ = δ, base = base,
                                       n_chains = n_chains, jitter_base = jitter_seed % UInt64))
end

"""
The body of [`infer`](@ref), run with the garbage collector paused
(see [`with_gc_paused`](@ref BAYSOL.Runtime.GCPause.with_gc_paused)): the MAP
objective, the NUTS gradient and the re-profile loop call
[`gc_checkpoint`](@ref BAYSOL.Runtime.GCPause.gc_checkpoint),
which collects once per byte budget.
"""
function _infer(
    seed::Seed{<:Real,N},
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD=PROFILE(),
    δ::Real=DEFAULT_TARGET_ACCEPT,
    base::UInt64=draw_base(),
    n_chains::Int=DEFAULT_N_CHAINS,
    jitter_base::UInt64=DEFAULT_JITTER_SEED
)::Inferred where {N}

    if δ ≤ 0 || δ ≥ 100
        throw(DomainError(δ, "δ must satisfy: 0 < δ < 100"))
    end
    δ = δ / 100

    if n_adapt ≥ n_samples
        throw(DomainError((n_adapt, n_samples), "n_adapt must be < n_samples"))
    end

    # MAP search + Laplace whitening (MAP.jl): NUTS samples w, θ = μ + σ·(ẑ + S·w),
    # in which the posterior is ≈ N(0, I) and the chain starts at the MAP.
    t_map = tick()
    seed.timing === nothing || (seed.timing.info["rng_seed"] = base)
    sp = _sampling_space(seed, l; base = base)
    if seed.timing !== nothing
        seed.timing.info["map_modes"] = sp.n_modes
        tock!(seed.timing, :sampling, 1,
            "MAP search + whitening ($(sp.n_ok)/$(MAP_N_STARTS) starts, $(sp.n_modes) " *
            "mode$(sp.n_modes == 1 ? "" : "s")$(sp.whitened ? "" : ", not whitened"))",
            t_map)
    end

    # the chains; if their best draw beats the MAP the sampler was whitened at, the MAP search missed a better basin:
    # re-whiten there (L-BFGS from that draw, the heaviest basin wins) and run the chains once more
    post = n_adapt+1:n_samples
    chains = _run_chains(seed, l, sp, n_samples, n_adapt, δ, base, jitter_base, n_chains)
    rewhitened = 0.0
    best = _best_draw(chains.runs, post)
    if best.ld > sp.logπ + BASIN_RESTART_NATS
        t_re = tick()
        z_best = _standardize(Θ(best.ξ, seed.pr)[1], seed.pr)
        sp2 = _sampling_space(seed, l; base = base, extra_starts = [z_best])
        tock!(seed.timing, :sampling, 1,
              @sprintf("re-whitening: a chain found a basin %.1f nats above the MAP", best.ld - sp.logπ), t_re)
        if sp2.logπ > sp.logπ
            rewhitened = sp2.logπ - sp.logπ
            sp = sp2
            chains = _run_chains(seed, l, sp, n_samples, n_adapt, δ, base, jitter_base, n_chains)
        end
    end
    runs, starts, t_nuts = chains.runs, chains.starts, chains.t_nuts
    n_lf = sum(r -> r.stats === nothing ? 0 : sum(getproperty.(r.stats, :n_steps)), runs)

    # which chains are pooled (every chain that ran and did not mostly diverge)
    ran = [r.error === nothing for r in runs]
    any(ran) || throw(first(r.error for r in runs))   # no chain ran: the error is the caller's to see
    ld = zeros(length(post), n_chains)
    div_rate = zeros(n_chains)
    for r in runs
        r.error === nothing || continue
        ld[:, r.k] = getproperty.(r.stats[post], :log_density)
        div_rate[r.k] = mean(getproperty.(r.stats[post], :numerical_error))
    end
    pooled, reason = select_chains(div_rate, [r.error === nothing ? nothing : sprint(showerror, r.error) for r in runs])
    if !any(pooled)
        # every chain that ran was rejected (e.g. all diverged): pool them all so the caller's own all-diverged
        # handling applies, as with a single chain
        for k in findall(ran)
            pooled[k] = true
            reason[k] = reason[k] * " (no chain passed: pooled anyway)"
        end
    end
    pk = findall(pooled)

    if seed.timing !== nothing
        seed.timing.info["n_chains"]        = n_chains
        seed.timing.info["n_chains_pooled"] = length(pk)
        seed.timing.info["leapfrog"]        = n_lf
        ms = MS_PER_S * sum(r -> r.seconds, runs) / max(n_lf, 1)   # chain-seconds per leapfrog step
        tock!(seed.timing, :sampling, 1,
            @sprintf(
                "NUTS  (%s iters, %s leapfrog, %.3f ms/step)",
                fmt_count(n_chains * n_samples),
                fmt_count(n_lf),
                ms
            ),
            t_nuts)
    end

    # draws × chains × (ξ₁…ξ_N, log π) of the pooled chains, after the warm-up
    cube = Array{Float64,3}(undef, length(post), length(pk), N + 1)
    for (c, k) in enumerate(pk)
        for i in 1:N
            cube[:, c, i] = getindex.(runs[k].ξ[post], i)
        end
        cube[:, c, N+1] = ld[:, k]
    end

    # The modes the chains settled in, their mass and the draws each keeps. NUTS chains do not jump between modes, so
    # chains pooled as they come would weight the modes by how many started in each: the mass of each mode is
    # estimated by bridge sampling (from its chains' draws and the density), and the draws are thinned to those shares.
    t_modes = tick()
    mode_of = chain_modes(cube)
    M = maximum(mode_of)
    logZ = zeros(M)
    err = zeros(M)
    if M > 1
        ℓπ = _value_target(seed, l, sp)
        for m in 1:M
            cs = findall(==(m), mode_of)
            W = reduce(vcat, (_draws_w(seed, sp, runs[pk[c]].ξ[post]) for c in cs))
            logZ[m], err[m] = bridge_logmass(W, reduce(vcat, (ld[:, pk[c]] for c in cs)), ℓπ,
                                              stream(base, _RNG_BRIDGE, m))
        end
    end
    chains_in = [count(==(m), mode_of) for m in 1:M]
    uncertain = M > 1 && weights_uncertain(logZ, err)
    # an error too large to determine the shares: the chains of the modes that can matter are pooled as they came, the
    # modes that are negligible even at their most optimistic estimate are dropped (and the report says so)
    weights = M == 1 ? [1.0] : uncertain ? uncertain_weights(logZ, err, chains_in) : mode_weights(logZ)
    keep = uncertain ? [w > 0 ? length(post) : 0 for w in weights] : draws_per_chain(weights, chains_in, length(post))
    if M > 1 && seed.timing !== nothing
        tock!(seed.timing, :sampling, 1,
              @sprintf("%d posterior modes: mass by bridge sampling%s", M, uncertain ? " (weights uncertain, not applied)" : ""),
              t_modes)
    end

    # the rows each pooled chain contributes: its warm-up rows, and the post-warm-up rows its mode keeps
    rows = [vcat(1:n_adapt, n_adapt .+ even_indices(length(post), keep[mode_of[c]])) for c in eachindex(pk)]

    t_reprofile = tick()
    # scale/bkgrnd_corr are fit in closed form (wls_fit) and discarded on
    # every single ℓπ/gradient evaluation above; re-profile c1 at each posterior draw so the reported
    # curve/χ² match what _ll actually evaluated at that ξ during sampling.
    reprof = tmap_items(c -> _reprofile(seed, runs[pk[c]].ξ[rows[c]]), eachindex(pk))
    tock!(
        seed.timing,
        :sampling,
        1,
        "per-draw c1 re-profile + curves ($(sum(length, rows)) draws)",
        t_reprofile
    )

    # convergence of the chains of each mode (between modes they differ by construction); the worst mode is reported.
    # A mode below MODE_NEGLIGIBLE keeps no draws, so what its chains did is not part of the posterior: not diagnosed.
    live = [m for m in 1:M if weights[m] ≥ MODE_NEGLIGIBLE]
    cvs = [convergence(cube[:, findall(==(m), mode_of), :]) for m in (isempty(live) ? (1:M) : live)]
    # (NaN entries, from modes too short to judge, are left out; NaN if nothing is left)
    worst(f, init) = [(v = filter(!isnan, getindex.(getproperty.(cvs, init), q)); isempty(v) ? NaN : f(v)) for q in 1:N+1]
    diag = ChainDiagnostics(n_chains, [starts[k][2] for k in 1:n_chains], pooled, reason,
                            worst(maximum, :rhat), worst(minimum, :ess), worst(minimum, :ess_tail),
                            rewhitened, [k in pk ? mode_of[findfirst(==(k), pk)] : 0 for k in 1:n_chains],
                            weights, logZ, err, uncertain)

    return Inferred(
        reduce(vcat, (runs[pk[c]].ξ[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (runs[pk[c]].stats[rows[c]] for c in eachindex(pk))),
        reduce(vcat, (r.scale for r in reprof)),
        reduce(vcat, (r.bkgrnd_corr for r in reprof)),
        reduce(vcat, (r.c1 for r in reprof)),
        reduce(vcat, (r.χ² for r in reprof)),
        reduce(hcat, (r.curves for r in reprof)),
        reduce(vcat, (fill(pk[c], length(rows[c])) for c in eachindex(pk))),
        reduce(vcat, (rows[c] for c in eachindex(pk))),
        diag,
        l.type,
        seed.timing
    )
end

"""
The draws `ξs` in NUTS's whitened coordinates, one draw per row.

# Returns
- `Matrix{Float64}`, `length(ξs) × N`.
"""
function _draws_w(seed::Seed{<:Real,N}, sp, ξs::AbstractVector) where {N}
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
ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates w (the target the chains sample and bridge
sampling integrates).
"""
function _value_target(seed::Seed{<:Real,N}, l::LIKELIHOOD, sp) where {N}
    return w -> _logπ(_θ_of_w(SVector{N,eltype(w)}(w...), sp), seed.pr, seed.wls, seed.fw, l; tab = seed.c1tab)
end

"""
Runs the `n_chains` NUTS chains on the whitened target of `sp`, one task each, from their starts ([`_chain_start`](@ref)).
`δ` is the target acceptance as a fraction. Every chain has its own metric, Hamiltonian, adaptor and random stream (the
stream belongs to the chain index, not to the thread that happens to run it) and shares only the read-only seed.

# Returns
- `NamedTuple` `(runs, starts, t_nuts)`: the [`_ChainRun`](@ref)s in chain order, the starts and the timer started when
  the chains began.
"""
function _run_chains(seed::Seed{<:Real,N}, l::LIKELIHOOD, sp, n_samples::Int64, n_adapt::Int64, δ::Real,
                     base::UInt64, jitter_base::UInt64, n_chains::Int) where {N}
    t_setup = tick()

    # ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates w.
    ℓπ = @closure w -> _logπ(
        _θ_of_w(SVector{N,eltype(w)}(w...), sp),
        seed.pr,
        seed.wls,
        seed.fw, l;
        tab = seed.c1tab,
    )

    # ∂ℓπ∂w: w ↦ (log π(θ(w)), ∇_w log π(θ(w))), computed in one ForwardDiff pass.
    ∂ℓπ∂w = @closure w -> begin
        gc_checkpoint()
        result = DiffResults.GradientResult(w)
        ForwardDiff.gradient!(result, ℓπ, w)
        (DiffResults.value(result), DiffResults.gradient(result))
    end

    # The starts: mirrored jittered pairs, or the MAP for a single chain (deterministically, see `_chain_start`).
    # Chosen serially and up front, so neither the starts nor which chain gets which depend on the threads.
    starts = [_chain_start(k, n_chains, N, ℓπ, ∂ℓπ∂w, jitter_base) for k in 1:n_chains]
    show_progress = n_chains == 1   # concurrent progress bars would overwrite each other

    # One NUTS chain. Every chain has its own metric, Hamiltonian, adaptor and random stream (the stream belongs to
    # the chain index, not to the thread that happens to run it), and shares only the read-only seed.
    run_chain = k -> begin
        w₀, _ = starts[k]
        t0 = time_ns()
        try
            # DenseEuclideanMetric allows the adaptation to learn
            # correlations between parameters. Since we are only fitting
            # a handful of params and they are highly coupled, it is
            # worth it here. After the whitening it starts (M⁻¹ = I) close to right.
            metric = DenseEuclideanMetric(N)

            # combines "potential energy" (ℓπ) and kinetic energy (from metric)
            hamiltonian = Hamiltonian(metric, ℓπ, ∂ℓπ∂w)

            # the chain's own stream: the step-size search and the sampler both draw from it
            rng = stream(base, _RNG_NUTS, k)

            # HMC numerically integrates the Hamiltonian, so we need to guess a good step size.
            init_step_size = find_good_stepsize(rng, hamiltonian, copy(w₀))

            # Leapfrog integration evaluates kinetic energy first, then
            # "skips over" that evaluated position to the next one for potential energy.
            integrator = Leapfrog(init_step_size)

            # Initial step sizes are likely non-ideal, so sampler learns mass matrix/metric
            # and step size as it goes along.
            adaptor = StanHMCAdaptor(
                MassMatrixAdaptor(metric),
                StepSizeAdaptor(δ, integrator)
            )

            # the sampler in w-space
            kernel = HMCKernel(Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()))

            ws, stats = sample(
                rng,
                hamiltonian,
                kernel,
                copy(w₀),
                n_samples,
                adaptor,
                n_adapt;
                progress = show_progress,
                verbose = show_progress
            )
            ξs = [Ξ(_θ_of_w(SVector{N,Float64}(s...), sp), seed.pr) for s in ws]
            return _ChainRun(k, ξs, stats, nothing, (time_ns() - t0) / NS_PER_S)
        catch e
            e isa InterruptException && rethrow()
            return _ChainRun(k, SVector{N,Float64}[], nothing, e, (time_ns() - t0) / NS_PER_S)
        end
    end

    tock!(seed.timing, :sampling, 1, "NUTS setup (starts, Hamiltonian)", t_setup)
    t_nuts = tick()
    runs = tmap_items(run_chain, 1:n_chains)
    return (runs = runs, starts = starts, t_nuts = t_nuts)
end

"""
The highest post-warm-up log density among the non-divergent draws of the chains that ran, and its ξ.

# Returns
- `NamedTuple` `(ld, ξ)`; `ld = -Inf` if there is no such draw.
"""
function _best_draw(runs, post)
    best = (ld = -Inf, ξ = nothing)
    for r in runs
        r.error === nothing || continue
        for i in post
            st = r.stats[i]
            st.numerical_error || st.log_density <= best.ld || (best = (ld = st.log_density, ξ = r.ξ[i]))
        end
    end
    return best
end

"What one NUTS chain returned: its draws and diagnostics, or the error that stopped it (then `stats` is `nothing`)."
struct _ChainRun{N,S}
    k::Int
    ξ::Vector{SVector{N,Float64}}
    stats::S
    error::Union{Nothing,Exception}
    seconds::Float64
end

"""
Start of chain `k` of `n` in NUTS's whitened coordinates w, with its signed distance from the MAP in posterior standard
deviations ([`chain_radius`](@ref)). The start is `r·u` for a direction `u` on the unit sphere: a single chain, and chain 1,
at the MAP (`w = 0`); chain 2 also at the MAP (its own random stream makes it an independent chain); chains 3 and up in mirrored pairs,
chains `2p+1` and `2p+2` at `+r_p·u_p` and `-r_p·u_p`. The directions come from streams of `jitter_base`
([`DEFAULT_JITTER_SEED`](@ref) unless the caller gave a `jitter_seed`; never the run's `rng_seed`). A start where log π or
its gradient is not finite is pulled halfway back toward the MAP, up to [`CHAIN_JITTER_MAX_HALVINGS`](@ref) times, and the
distance returned is the one used; a start that never becomes usable is the MAP itself (0).

# Returns
- `(w₀::Vector{Float64}, r::Float64)`.
"""
function _chain_start(k::Int, n::Int, N::Int, ℓπ, ∂ℓπ∂w, jitter_base::UInt64)
    r = chain_radius(k, n)
    r == 0 && return zeros(N), 0.0
    z = randn(stream(jitter_base, _RNG_JITTER, (k - 1) ÷ 2), N)
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
The (scale, `bkgrnd_corr`, c1, reduced χ², curve) of every draw `ξs`, c1 re-profiled at each.

# Returns
- `NamedTuple` of `Vector`s `scale`, `bkgrnd_corr`, `c1`, `χ²` and the matrix `curves` (Q × draws).
"""
function _reprofile(seed::Seed, ξs::AbstractVector)
    n = length(ξs)
    scale        = Vector{Float64}(undef, n)
    bkgrnd_corr  = Vector{Float64}(undef, n)
    c1           = Vector{Float64}(undef, n)
    χ²           = Vector{Float64}(undef, n)
    curves       = Matrix{Float64}(undef, length(seed.fw.qvals), n)
    for (i, ξ) in enumerate(ξs)
        gc_checkpoint()
        ŷ, fit, c1_star = profiled_corrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
        scale[i]        = fit.scale
        bkgrnd_corr[i]  = fit.bkgrnd_corr
        c1[i]           = c1_star
        χ²[i]           = reduced_chi2(fit)
        curves[:, i]    = wls_predict(fit, ŷ)
    end
    return (; scale, bkgrnd_corr, c1, χ², curves)
end
