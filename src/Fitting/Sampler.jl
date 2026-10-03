# SPDX-License-Identifier: LGPL-2.1-or-later

using   AdvancedHMC: DenseEuclideanMetric, Hamiltonian, MassMatrixAdaptor,
        find_good_stepsize, Leapfrog, StanHMCAdaptor, StepSizeAdaptor, sample,
        HMCKernel, Trajectory, MultinomialTS, GeneralisedNoUTurn
using   FastClosures, StaticArrays, Distributions, ForwardDiff, DiffResults
using   SpecialFunctions: digamma, trigamma
using ..Scattering: forward, ForwardCache
using ..BAYSOL_Utils.Constants: DEFAULT_TEMPERATURE_C, DRO12_CONCENTRATION, DRO3_CONCENTRATION,
                                DEFAULT_TARGET_ACCEPT, NS_PER_S
using ..BAYSOL_Utils.Timing: StageLog, tick, tock!, fmt_count
using Printf: @sprintf

"""
$(TYPEDSIGNATURES)

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
$(TYPEDSIGNATURES)

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
$(TYPEDSIGNATURES)

Per-coordinate prior mean and standard deviation in θ-space, used by
[`_standardize`](@ref)/[`_destandardize`](@ref) to rescale θ before handing
it to AdvancedHMC.jl, and by [`prior_z_scores`](@ref).

All four are exact. a = ln ρₑ is Normal(μ_ln, σ_ln) under its LogNormal
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
    _standardize(θ::SVector{4,<:Real}, p::ξ_priors) -> SVector{4,<:Real}
    _destandardize(z::SVector{4,<:Real}, p::ξ_priors) -> SVector{4,<:Real}

Affine maps between θ-space and a prior-standardized z-space,
z = (θ - μ) / σ / its inverse θ = μ + σ·z, with (μ, σ) from
[`θ_prior_moments`](@ref).

θ's four coordinates have wildly different natural (prior) scales;
a step in one parameter is enough to send another to an unphysical region
and push the forward model to a flat curve (wls_fit's det(XᵀWX) ≤ 0 guard).

Sampling in z-space makes a generic O(1) kick ~1 prior-σ in
every coordinate uniformly (each z_i is standard-Normal under the
prior), so find_good_stepsize's very first candidate step does not overshoot.

The Jacobian of the map (|dθ/dz| = Πσ_i) is a z-independent
constant, so it's omitted from _logπ/the z-space wrapper around it.

# Arguments
- `θ/z::SVector{4,<:Real}`: as above.
- `p::ξ_priors`: supplies (μ, σ) via [`θ_prior_moments`](@ref).
"""
function _standardize(θ::SVector{4,<:Real}, p::ξ_priors)
    μ, σ = θ_prior_moments(p)
    return (θ .- μ) ./ σ
end

"Inverse of [`_standardize`](@ref); see its docstring for both directions."
function _destandardize(z::SVector{4,<:Real}, p::ξ_priors)
    μ, σ = θ_prior_moments(p)
    return μ .+ σ .* z
end

"""
$(TYPEDSIGNATURES)

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

"Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The
forward model produces a predicted curve y_model(q), but the data I_exp(q)
sits at some unknown overall scale scale and background offset
bkgrnd_corr, i.e. I_calc = scale·y_model + bkgrnd_corr. WLS.jl fits
(scale, bkgrnd_corr) in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by l:

- `l = PROFILE()`: treat (scale, bkgrnd_corr) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, bkgrnd_corr), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, bkgrnd_corr) [`wls_marg_ll`](@ref). 
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out. "
struct PROFILE<:LIKELIHOOD
    type::AbstractString
    PROFILE() = new("profile_log_likelihood")
end

"Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The
forward model produces a predicted curve y_model(q), but the data I_exp(q)
sits at some unknown overall scale scale and background offset
bkgrnd_corr, i.e. I_calc = scale·y_model + bkgrnd_corr. WLS.jl fits
(scale, bkgrnd_corr) in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by l:

- `l = PROFILE()`: treat (scale, bkgrnd_corr) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, bkgrnd_corr), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, bkgrnd_corr) [`wls_marg_ll`](@ref). 
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out. "
struct MARGINAL<:LIKELIHOOD
    type::AbstractString
    MARGINAL() = new("marginal_log_likelihood")
end

""" Returns the log likelhihoods """
__ll(fit::WLSFit, ::PROFILE)  = wls_prof_ll(fit)
__ll(fit::WLSFit, ::MARGINAL) = wls_marg_ll(fit)

"""
$(TYPEDSIGNATURES)

Log-likelihood of the data at a given ξ = (ρₑ, δρ₁, δρ₂, δρ₃). The
forward model produces a predicted curve y_model(q), but the data I_exp(q)
sits at some unknown overall scale scale and background offset
bkgrnd_corr, i.e. I_calc = scale·y_model + bkgrnd_corr. WLS.jl fits
(scale, bkgrnd_corr) in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by l:

- `l = PROFILE()`: treat (scale, bkgrnd_corr) as pinned at their best-fit
    values (a point estimate) [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning (scale, bkgrnd_corr), integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in scale, bkgrnd_corr) [`wls_marg_ll`](@ref). 
    This adds a correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.

# Arguments
- `wls::WLSData`: precomputed data-only weighted sums over (I_exp, σ_exp),
    from [`WLSData`](@ref); forwarded to [`profiled_corrs`](@ref).
- `ξ::SVector{4,<:Real}`: the physical fit parameters (ρₑ, δρ₁, δρ₂, δρ₃).
- `fw::ForwardCache`: the structure's static cache, from [`BAYSOL.Scattering.forward_cache`](@ref).
- `l::LIKELIHOOD`: `PROFILE()` or `MARGINAL()`, selecting which log-likelihood
    variant to return.

# Returns
- `Real`: the log-likelihood, composing by addition with the log-prior terms.
"""
function _ll(
    wls::WLSData,
    ξ::SVector{4,<:Real},
    fw::ForwardCache,
    l::LIKELIHOOD
)
    _, fit, _ = profiled_corrs(wls, ξ, fw)
    return __ll(fit, l)
end

"""
$(TYPEDSIGNATURES)

Log prior density of ξ = (ρₑ, δρ₁, δρ₂, δρ₃) in ξ-space. The δρ `LocationScale`
priors carry their own -ln W terms.
"""
_lp(ξ::SVector{4,<:Real}, p::ξ_priors) =
    logpdf(p.ρₑPrior, ξ[1]) + logpdf(p.δρ₁Prior, ξ[2]) + logpdf(p.δρ₂Prior, ξ[3]) +
    logpdf(p.δρ₃Prior, ξ[4])

"""
$(TYPEDSIGNATURES)

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

# Returns
- `Real`: log π(θ), up to the additive constant NUTS doesn't need.
"""
function _logπ(
    θ::SVector{4,<:Real},
    p::ξ_priors,
    wls::WLSData,
    fw::ForwardCache,
    l::LIKELIHOOD
)
    ξ = Ξ(θ, p)  # unconstrained θ-space -> physical ξ-space
    return _lp(ξ, p) + _ll(wls, ξ, fw, l) + logjac(θ, p)
end

"""
    Seed{T<:Real}

Everything [`run_fitting`](@ref) needs to start a NUTS chain.

# Fields
- `pr::ξ_priors`: the physical priors over ξ, from [`_calc_ξ_priors`](@ref).
- `ξ₀::SVector{4,T}`: one draw from pr, in physical ξ-space, from [`_ξ₀`](@ref).
- `θ₀::SVector{4,T}`: ξ₀ reparameterized into unconstrained θ-space via [`Θ`](@ref).
- `fw::ForwardCache`: the structure's geometry-only cache (the Gram matrix
    G(q), q-grid, and mean atomic radius), from forward_cache.
- `wls::WLSData`: the measured intensity curve and its per-point standard
    errors, precomputed into [`WLSData`](@ref) once so the NUTS hot path
    (`_ll`/`_logπ`) never rebuilds the data-only weighted sums.
- `timing::Union{Nothing,StageLog}`: the run's stage log, if timing is on;
    [`run_fitting`](@ref) appends its stages and hands it on in the [`FitResult`](@ref).
"""
struct Seed{T<:Real}
    pr::ξ_priors
    ξ₀::SVector{4,T}
    θ₀::SVector{4,T}
    fw::ForwardCache
    wls::WLSData
    timing::Union{Nothing,StageLog}
end

"""
$(TYPEDSIGNATURES)

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
)::Seed
    pr = _calc_ξ_priors(pH, σ_pH, solutes; t=t, κ_δρ₁₂=κ_δρ₁₂, κ_δρ₃=κ_δρ₃)
    ξ₀ = _ξ₀(pr)
    θ₀, _ = Θ(ξ₀, pr)
    wls = WLSData(I_exp, σ_exp)
    return Seed(pr, ξ₀, θ₀, fw, wls, timing)
end

"""
    FitResult{S}

Return of [`run_fitting`](@ref)/BAYSOL.run_model: the posterior
draws of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one
(scale, bkgrnd_corr, c1) triple and predicted curve per draw, and
AdvancedHMC.jl's own per-iteration diagnostics.

# Fields
- `samples::Vector{SVector{4,Float64}}`: posterior draws of ξ, length n_samples.
- `stats::Vector{S}`: AdvancedHMC.jl's per-iteration diagnostics, matching
    samples index-for-index.
- `scale::Vector{Float64}`: the WLS estimate of the scale correction at samples[i].
- `bkgrnd_corr::Vector{Float64}`: the WLS estimate of the background correction at samples[i].
- `c1::Vector{Float64}`: the profiled excluded-volume correction
    ([`profiled_corrs`](@ref)) at samples[i]. Profiled, not sampled -- it
    has no prior and therefore no z-score, unlike `samples`.
- `chisq_red::Vector{Float64}`:  the reduced χ² of the WLS estimate
- `curves::Matrix{Float64}, (Q, n_samples)`: the detector-scale predicted
    curve I_calc(q) = scale[i]·y_model(q) + bkgrnd_corr[i] for each
    samples[i], column-matching scale/bkgrnd_corr. Equivalently
    curves[:, i] == forward(seed.fw, scale[i], bkgrnd_corr[i], samples[i][1],
    samples[i][2:4], c1[i]).
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
$(TYPEDSIGNATURES)

Run NUTS on [`_logπ`](@ref) starting from seed, returning posterior draws
of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one (scale,
bkgrnd_corr) pair per draw (see # Returns below), and AdvancedHMC.jl's
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

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first n_adapt iterations,
StepSizeAdaptor tunes the leapfrog step size ε via dual-averaging so the
empirical acceptance rate converges to δ; too-small ε wastes computation
taking tiny steps, too-large ε causes leapfrog's discretization error (and
therefore the rejection rate) to blow up. MassMatrixAdaptor learns M (here the
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
A [`FitResult`](@ref). Includes the n_adapt warm-up draws; a caller that wants a
warmup-free posterior slices n_adapt+1:end (curves: [:, n_adapt+1:end])
out of every field itself.
"""
function run_fitting(
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

    t_setup = tick()

    # ℓπ: z ↦ log π(θ(z)), the value-only log-posterior in prior-standardized z-space.
    ℓπ = @closure z -> _logπ(
        _destandardize(SVector{4,eltype(z)}(z...), seed.pr),
        seed.pr,
        seed.wls,
        seed.fw, l
    )

    # ∂ℓπ∂z: z ↦ (log π(θ(z)), ∇_z log π(θ(z))), computed in one ForwardDiff pass.
    ∂ℓπ∂z = @closure z -> begin
        result = DiffResults.GradientResult(z)
        ForwardDiff.gradient!(result, ℓπ, z)
        (DiffResults.value(result), DiffResults.gradient(result))
    end

    # DenseEuclideanMetric allows the adaptation to learn
    # correlations between parameters. Since we are only fitting
    # 4 or 5 params (once δρ4 lands) and they are highly coupled, it is
    # worth it here.
    # sized from the parameter vector itself, so it follows θ when δρ4 widens it
    metric = DenseEuclideanMetric(length(seed.θ₀))

    # combines "potential energy" (ℓπ) and kinetic energy (from metric)
    hamiltonian = Hamiltonian(metric, ℓπ, ∂ℓπ∂z)

    # AdvancedHMC.jl's DiagEuclideanMetric/DenseEuclideanMetric store M⁻¹ as
    # a plain Vector/Matrix (Base.OneTo axes) and check axes(M⁻¹) against
    # axes(z)/axes(r); an SVector's SOneTo axes fail that check even though
    # the ranges match. Start from a plain Vector instead of an SVector
    # directly, at z₀ = _standardize(seed.θ₀, seed.pr).
    z₀ = Vector(_standardize(seed.θ₀, seed.pr))

    # HMC numerically integrates the Hamiltonian, so we need to
    # guess a good step size.
    init_step_size = find_good_stepsize(hamiltonian, z₀)

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

    # the sampler in z-space
    kernel = HMCKernel(Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()))

    # do sampling
    tock!(seed.timing, :sampling, 1, "NUTS setup (Hamiltonian, step-size init)", t_setup)
    t_nuts = tick()
    samples, stats = sample(
        hamiltonian,
        kernel,
        z₀,
        n_samples,
        adaptor,
        n_adapt;
        progress=true
    )
    samples = [Ξ(_destandardize(SVector{4,Float64}(s...), seed.pr), seed.pr) for s in samples]
    if seed.timing !== nothing
        n_lf = sum(getproperty.(stats, :n_steps))
        ms = 1e3 * (time_ns() - t_nuts[1]) / NS_PER_S / max(n_lf, 1)   # ms per leapfrog step
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
        # re-profile c1 at each posterior draw so the reported curve/χ²
        # match what _ll actually evaluated at that ξ during sampling.
        ŷ, fit, c1_star = profiled_corrs(seed.wls, ξ, seed.fw)
        scale[i]        = fit.scale
        bkgrnd_corr[i]  = fit.bkgrnd_corr
        c1[i]           = c1_star
        χ²[i]           = reduced_chi2(fit)
        curves[:, i]    = wls_predict(fit, ŷ)
    end

    tock!(seed.timing, :sampling, 1, "per-draw c1 re-profile + curves ($(n_samples) draws)", t_reprofile)
    return FitResult(samples, stats, scale, bkgrnd_corr, c1, χ², curves, l.type, seed.timing)

end
