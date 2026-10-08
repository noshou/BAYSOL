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
- `κ_δρ₁₂::Real = DRO12_CONCENTRATION`: concentration of the δρ₁/δρ₂ priors,
    forwarded to [`δρ_prior`](@ref).
- `κ_δρ₃::Real = DRO3_CONCENTRATION`: concentration of the δρ₃ prior,
    forwarded to [`δρ_prior`](@ref).

# Returns
- `ξ_priors`: the priors. δρ₃'s bounds are fixed at the mean of the ρₑ prior.
"""
function _calc_ξ_priors(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    κ_δρ₁₂::Real = DRO12_CONCENTRATION,
    κ_δρ₃::Real = DRO3_CONCENTRATION,
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
function _ξ₀(p::ξ_priors)::SVector{4,<:Real}
    ρₑ = rand(p.ρₑPrior)
    δρ₁ = rand(p.δρ₁Prior)
    δρ₂ = rand(p.δρ₂Prior)
    δρ₃ = rand(p.δρ₃Prior)
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
- `θ::SVector{4,<:Real}`: a θ-space point.
- `p::ξ_priors`: supplies (μ, σ) via [`θ_prior_moments`](@ref).

# Returns
- `SVector{4,<:Real}`: z.
"""
function _standardize(θ::SVector{4,<:Real}, p::ξ_priors)
    μ, σ = θ_prior_moments(p)
    return (θ .- μ) ./ σ
end

"""
How many prior standard deviations a physical-space point ξ = (ρₑ, δρ₁,
δρ₂, δρ₃) sits from its own prior p.

z = (θ - μ) / σ in θ-space, where θ = Θ(ξ, p) and (μ, σ) are the prior's
per-coordinate θ-space mean/std from [`θ_prior_moments`](@ref).

# Arguments
- `ξ::SVector{4,<:Real}`: the physical-space point to score.
- `p::ξ_priors`: supplies (μ, σ) via [`θ_prior_moments`](@ref).
"""
function prior_z_scores(ξ::SVector{4,<:Real}, p::ξ_priors)::SVector{4,Float64}
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
- `wls::WLSData`: precomputed data-only weighted sums over (`I_exp`, `σ_exp`),
    from [`WLSData`](@ref); forwarded to [`profiled_corrs`](@ref).
- `ξ::SVector{4,<:Real}`: the physical fit parameters (ρₑ, δρ₁, δρ₂, δρ₃).
- `fw::ForwardCache`: the structure's static cache, from [`BAYSOL.Scattering.forward_cache`](@ref).
- `l::LIKELIHOOD`: `PROFILE()` or `MARGINAL()`, selecting which log-likelihood
    variant to return.

# Keywords
- `tab::Union{Nothing,_C1Tables} = nothing`, `c1_tol = EXCL_VOL_CORR_TOL`: forwarded to
    [`profiled_corrs`](@ref) as `tables`/`tol`.

# Returns
- `Real`: the log-likelihood, composing by addition with the log-prior terms.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{4,<:Real},
    fw::ForwardCache,
    l::LIKELIHOOD;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
)
    _, fit, _ = profiled_corrs(wls, ξ, fw; tables = tab, tol = c1_tol)
    return __ll(fit, l)
end

"""
[`_ll`](@ref) for the profile likelihood at a ForwardDiff dual ξ: the value and the gradient with respect to ξ
come from [`_profile_ll_grad`](@ref) (analytic, no dual-number vectors through the forward model), and are
composed with the partials of ξ, so `ForwardDiff.gradient` of any function of θ sees the exact chain rule.
The marginal likelihood keeps the generic path above.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{4,D},
    fw::ForwardCache,
    ::PROFILE;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
) where {D<:ForwardDiff.Dual{<:Any,Float64}}
    tb = tab === nothing ? _C1Tables(fw) : tab
    ll, g = _profile_ll_grad(wls, SVector{4,Float64}(ForwardDiff.value.(ξ)), fw, tb, c1_tol)
    N = ForwardDiff.npartials(D)
    parts = ntuple(j -> g[1] * ForwardDiff.partials(ξ[1], j) + g[2] * ForwardDiff.partials(ξ[2], j) +
                        g[3] * ForwardDiff.partials(ξ[3], j) + g[4] * ForwardDiff.partials(ξ[4], j), Val(N))
    return ForwardDiff.Dual{ForwardDiff.tagtype(D)}(ll, ForwardDiff.Partials(parts))
end

"""
Log prior density of ξ = (ρₑ, δρ₁, δρ₂, δρ₃) in ξ-space. The δρ `LocationScale`
priors carry their own -ln W terms.
"""
_lp(ξ::SVector{4,<:Real}, p::ξ_priors) =
    logpdf(p.ρₑPrior, ξ[1]) + logpdf(p.δρ₁Prior, ξ[2]) + logpdf(p.δρ₂Prior, ξ[3]) +
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

    log|det(∂ξ/∂θ)| = a + Σₖ [ln Wₖ + ln σ(tₖ) + ln(1 - σ(tₖ))]    ([`logjac`](@ref))

with W₁ = W₂ = 12 and (L₃, W₃) the δρ₃ prior's location and scale.

log p(ξ(θ)) is the sum of the log-prior and log-likelihood:

    log p(ξ | data) = log p(ξ) + log p(data | ξ) = _lp(ξ, p) + _ll(wls, ξ, fw, l)

giving:

    log π(θ) = _lp(ξ(θ), p) + _ll(wls, ξ(θ), fw, l) + logjac(θ)

# Arguments
- `θ::SVector{4,<:Real}`: the current NUTS position, (a, t₁, t₂, t₃).
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
    θ::SVector{4,<:Real},
    p::ξ_priors,
    wls::WLSData,
    fw::ForwardCache,
    l::LIKELIHOOD;
    tab::Union{Nothing,_C1Tables} = nothing,
    c1_tol::Float64 = EXCL_VOL_CORR_TOL,
)
    ξ = Ξ(θ, p)  # unconstrained θ-space -> physical ξ-space
    return _lp(ξ, p) + _ll(wls, ξ, fw, l; tab = tab, c1_tol = c1_tol) + logjac(θ, p)
end

"""
    Seed{T<:Real}

Everything [`run_fitting`](@ref) needs to start a NUTS chain.

# Fields
- `pr::ξ_priors`: the physical priors over ξ, from [`_calc_ξ_priors`](@ref).
- `θ₀::SVector{4,T}`: one draw from pr ([`_ξ₀`](@ref)), reparameterized into
    unconstrained θ-space via [`Θ`](@ref); the first start of the MAP search.
- `fw::ForwardCache`: the structure's geometry-only cache (the Gram matrix
    G(q), q-grid, and mean atomic radius), from `forward_cache`.
- `wls::WLSData`: the measured intensity curve and its per-point standard
    errors, precomputed into [`WLSData`](@ref) once so the NUTS hot path
    (`_ll`/`_logπ`) never rebuilds the data-only weighted sums.
- `timing::Union{Nothing,StageLog}`: the run's stage log, if timing is on;
    [`run_fitting`](@ref) appends its stages and hands it on in the [`FitResult`](@ref).
- `c1tab::_C1Tables`: the static c1-search tables for fw ([`_C1Tables`](@ref)), built
    once here and passed to every [`profiled_corrs`](@ref) call; read-only, so safe to
    share across threads.
- `shannon::Union{Nothing,ShannonInfo}`: how the measured curve was reduced to the data `wls` holds
    (diameter, band limit, binning, raw data), when it came through [`Shannon.shannon_data`](@ref BAYSOL.Utils.Shannon.shannon_data); `nothing` otherwise.
"""
struct Seed{T<:Real}
    pr::ξ_priors
    θ₀::SVector{4,T}
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
- `κ_δρ₁₂::Real = DRO12_CONCENTRATION`, `κ_δρ₃::Real = DRO3_CONCENTRATION`:
    prior concentrations, forwarded to [`δρ_prior`](@ref).
- `timing::Union{Nothing,StageLog} = nothing`: stored in the returned `Seed`.
- `shannon::Union{Nothing,ShannonInfo} = nothing`: stored in the returned `Seed`.

# Returns
- `Seed`: priors, initial point, forward cache, and data.
"""
function seed_fitting(
    fw::ForwardCache,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    κ_δρ₁₂::Real = DRO12_CONCENTRATION,
    κ_δρ₃::Real = DRO3_CONCENTRATION,
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
    FitResult{S}

Return of [`run_fitting`](@ref)`/BAYSOL.run_model`: the posterior
draws of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one
(scale, `bkgrnd_corr`, c1) triple and predicted curve per draw, and
AdvancedHMC.jl's own per-iteration diagnostics.

# Fields
- `samples::Vector{SVector{4,Float64}}`: posterior draws of ξ, length `n_samples`.
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
- `likelihood::AbstractString`: the likelihood type
- `timing::Union{Nothing,StageLog}`: the run's stage log (from the `Seed`), if timing is on.
"""
struct FitResult{S}
    samples::Vector{SVector{4,Float64}}
    stats::Vector{S}
    scale::Vector{Float64}
    bkgrnd_corr::Vector{Float64}
    c1::Vector{Float64}
    chisq_red::Vector{Float64}
    curves::Matrix{Float64}
    likelihood::AbstractString
    timing::Union{Nothing,StageLog}
end

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

# Returns
A [`FitResult`](@ref). Includes the `n_adapt` warm-up draws; a caller that wants a
warmup-free posterior slices `n_adapt`+1:end (curves: [:, `n_adapt`+1:end])
out of every field itself.
"""
function run_fitting(
    seed::Seed,
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD=PROFILE(),
    δ::Real=DEFAULT_TARGET_ACCEPT
)::FitResult
    return with_gc_paused(() -> _run_fitting(seed, n_samples, n_adapt; l = l, δ = δ))
end

"""
The body of [`run_fitting`](@ref), run with the garbage collector paused (see [`with_gc_paused`](@ref
BAYSOL.Utils.GCPause.with_gc_paused)): the MAP objective, the NUTS gradient and the re-profile loop call
[`gc_checkpoint`](@ref BAYSOL.Utils.GCPause.gc_checkpoint), which collects once per byte budget.
"""
function _run_fitting(
    seed::Seed,
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD=PROFILE(),
    δ::Real=DEFAULT_TARGET_ACCEPT
)::FitResult

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
    sp = _sampling_space(seed, l)
    if seed.timing !== nothing
        seed.timing.info["map_modes"] = sp.n_modes
        tock!(seed.timing, :sampling, 1,
            "MAP search + whitening ($(sp.n_ok)/$(MAP_N_STARTS) starts, $(sp.n_modes) " *
            "mode$(sp.n_modes == 1 ? "" : "s")$(sp.whitened ? "" : ", not whitened"))",
            t_map)
    end

    t_setup = tick()

    # ℓπ: w ↦ log π(θ(w)), the value-only log-posterior in NUTS's coordinates w.
    ℓπ = @closure w -> _logπ(
        _θ_of_w(SVector{4,eltype(w)}(w...), sp),
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

    # DenseEuclideanMetric allows the adaptation to learn
    # correlations between parameters. Since we are only fitting
    # 4 or 5 params (once δρ4 lands) and they are highly coupled, it is
    # worth it here. After the whitening it starts (M⁻¹ = I) close to right.
    # sized from the parameter vector itself, so it follows θ when δρ4 widens it
    metric = DenseEuclideanMetric(length(seed.θ₀))

    # combines "potential energy" (ℓπ) and kinetic energy (from metric)
    hamiltonian = Hamiltonian(metric, ℓπ, ∂ℓπ∂w)

    # AdvancedHMC.jl's DiagEuclideanMetric/DenseEuclideanMetric store M⁻¹ as
    # a plain Vector/Matrix (Base.OneTo axes) and check axes(M⁻¹) against
    # axes(w)/axes(r); an SVector's SOneTo axes fail that check even though
    # the ranges match. Start from a plain Vector instead of an SVector
    # directly, at w₀ = 0, the MAP.
    w₀ = zeros(Float64, length(seed.θ₀))

    # HMC numerically integrates the Hamiltonian, so we need to
    # guess a good step size.
    init_step_size = find_good_stepsize(hamiltonian, w₀)

    # Leapfrog integration evaluates kinetic energy first, then
    # "skips over" that evaluated position to the next one for potential energy.
    # (Could be flipped, not sure). Very efficient!
    integrator = Leapfrog(init_step_size)

    # Initial step sizes are likely non-ideal, so sampler leanrs mass matrix/metric
    # and step size as it goes along.
    adaptor = StanHMCAdaptor(
        MassMatrixAdaptor(metric),
        StepSizeAdaptor(δ, integrator)
    )

    # the sampler in w-space
    kernel = HMCKernel(Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()))

    # do sampling
    tock!(seed.timing, :sampling, 1, "NUTS setup (Hamiltonian, step-size init)", t_setup)
    t_nuts = tick()
    samples, stats = sample(
        hamiltonian,
        kernel,
        w₀,
        n_samples,
        adaptor,
        n_adapt;
        progress=true
    )
    samples = [Ξ(_θ_of_w(SVector{4,Float64}(s...), sp), seed.pr) for s in samples]
    if seed.timing !== nothing
        n_lf = sum(getproperty.(stats, :n_steps))
        ms = MS_PER_S * (time_ns() - t_nuts[1]) / NS_PER_S / max(n_lf, 1)   # ms per leapfrog step
        seed.timing.info["leapfrog"] = n_lf
        tock!(seed.timing, :sampling, 1,
            @sprintf("NUTS  (%s iters, %s leapfrog, %.1f ms/step)", fmt_count(n_samples), fmt_count(n_lf), ms),
            t_nuts)
    end
    t_reprofile = tick()

    # scale/bkgrnd_corr are fit in closed form (wls_fit) and discarded on
    # every single ℓπ/gradient evaluation above.
    scale        = Vector{Float64}(undef, n_samples)
    bkgrnd_corr  = Vector{Float64}(undef, n_samples)
    c1           = Vector{Float64}(undef, n_samples)
    χ²           = Vector{Float64}(undef, n_samples)
    curves       = Matrix{Float64}(undef, length(seed.fw.qvals), n_samples)
    for (i, ξ) in enumerate(samples)
        gc_checkpoint()
        # re-profile c1 at each posterior draw so the reported curve/χ²
        # match what _ll actually evaluated at that ξ during sampling.
        ŷ, fit, c1_star = profiled_corrs(seed.wls, ξ, seed.fw; tables = seed.c1tab)
        scale[i]        = fit.scale
        bkgrnd_corr[i]  = fit.bkgrnd_corr
        c1[i]           = c1_star
        χ²[i]           = reduced_chi2(fit)
        curves[:, i]    = wls_predict(fit, ŷ)
    end

    tock!(seed.timing, :sampling, 1, "per-draw c1 re-profile + curves ($(n_samples) draws)", t_reprofile)
    return FitResult(samples, stats, scale, bkgrnd_corr, c1, χ², curves, l.type, seed.timing)

end
