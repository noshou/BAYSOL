# SPDX-License-Identifier: LGPL-2.1-or-later

using AdvancedHMC: DenseEuclideanMetric, Hamiltonian, MassMatrixAdaptor,
find_good_stepsize, Leapfrog, StanHMCAdaptor, StepSizeAdaptor, sample,
HMCKernel, Trajectory, MultinomialTS, GeneralisedNoUTurn

using FastClosures, StaticArrays, Distributions, ForwardDiff, DiffResults

using ..Scattering: forward, ForwardCache
using ..BayesolUtils.Constants: DEFAULT_TEMPERATURE_C, C1_PRIOR_MASS_PERCENT

"Physical prior distributions."
struct ξ_priors
    dnsPrior::LogNormal{Float64}
    δρ1Prior::LogNormal{Float64}
    δρ2Prior::Normal{Float64}
    δρ3Prior::Normal{Float64}
    c_1Prior::LogNormal{Float64}
end

"""
    _calc_ξ_priors(
        pH::Real,
        σ_pH::Real,
        solutes::Vector{Solute};
        t::Real = DEFAULT_TEMPERATURE_C,
        μ_χ::Real = 0,
        σ_χ::Real = 0.0,
        n::Real = C1_PRIOR_MASS_PERCENT
    ) -> ξ_priors

Generates physical prior distributions of `ξ`.

# Arguments
- `pH::Real`: pH of the solution; forwarded to `PartialMolarVolumes.ϕ°` for `Protein` solutes.
- `σ_pH::Real`: standard uncertainty on `pH`, propagated through each `Protein`
    solute's titration term.
- `solutes::Vector{Solute}`: the species in solution.

# Keywords
- `t::Real = DEFAULT_TEMPERATURE_C`: solution temperature in °C, forwarded to
    `PartialMolarVolumes.ρₑ_w`. **!!NOTE!!: as of this version, this should NOT
    be changed, since only water is temperature-dependent.**
- `μ_χ = 0.0`: mean, over cavity beads, of the screened-electrostatic potential χ
    (Debye-Hückel, aggregated from nearby phosphate / ionizable-side-chain
    charge sites), feeding δρ3's cavity-water contrast.
- `σ_χ = 0.0`: standard deviation, over cavity beads, of χ, feeding δρ3's
    cavity-water contrast.
- `n::Real = C1_PRIOR_MASS_PERCENT`: percentage `(0, 100]` of the prior mass required to
    fall within CRYSOL's bound `[0.96, 1.04]` around its default `c_1 = 1`. Higher `n`
    concentrates more mass near the default; lower `n` allows more spread — only
    change from the default if more spread is needed.
"""
function _calc_ξ_priors(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    μ_χ::Real = 0,
    σ_χ::Real = 0.0,
    n::Real = C1_PRIOR_MASS_PERCENT
)::ξ_priors
    dns = ρₑ_prior(pH, σ_pH, solutes; t=t)
    δρ1, δρ2, δρ3 = δρ_prior(; μ_χ=μ_χ, σ_χ=σ_χ)
    c_1 = c1_prior(n)
    return ξ_priors(dns, δρ1, δρ2, δρ3, c_1)
end

"""
    _ξ₀(p::ξ_priors) -> SVector{5,<:Real}

Generates intitial physical parameter vector ξ₀
"""
function _ξ₀(p::ξ_priors)::SVector{5,<:Real}
    dns = rand(p.dnsPrior)
    δρ1 = rand(p.δρ1Prior)
    δρ2 = rand(p.δρ2Prior)
    δρ3 = rand(p.δρ3Prior)
    c_1 = rand(p.c_1Prior)
    return SVector(dns, δρ1, δρ2, δρ3, c_1)
end

"""
    θ_prior_moments(p::ξ_priors) -> (μ::SVector{5}, σ::SVector{5})

Each θ-space coordinate is Normal under the prior: [`Θ`](@ref) sends a
LogNormal(μ,σ)-distributed `dns`/`δρ1`/`c_1` to its underlying Normal(μ,σ)
exactly (θ = ln ξ), and `δρ2`/`δρ3` are already Normal and pass through `Θ`
unchanged. So every one of `p`'s five component distributions carries a
`(μ, σ)` that is directly θ-space's own per-coordinate prior mean/std — no
separate derivation needed, just read `.μ`/`.σ` off each.

Used by [`_standardize`](@ref)/[`_destandardize`](@ref) to rescale θ before
handing it to `AdvancedHMC.jl`.
"""
function θ_prior_moments(p::ξ_priors)::Tuple{SVector{5,Float64},SVector{5,Float64}}
    μ = SVector(p.dnsPrior.μ, p.δρ1Prior.μ, p.δρ2Prior.μ, p.δρ3Prior.μ, p.c_1Prior.μ)
    σ = SVector(p.dnsPrior.σ, p.δρ1Prior.σ, p.δρ2Prior.σ, p.δρ3Prior.σ, p.c_1Prior.σ)
    return μ, σ
end

"""
    _standardize(θ::SVector{5,<:Real}, p::ξ_priors) -> SVector{5,<:Real}
    _destandardize(z::SVector{5,<:Real}, p::ξ_priors) -> SVector{5,<:Real}

Affine maps between θ-space and a prior-standardized `z`-space,
`z = (θ - μ) / σ` / its inverse `θ = μ + σ·z`, with `(μ, σ)` from
[`θ_prior_moments`](@ref).

# Why this exists: `find_good_stepsize`'s identity-mass-matrix blind spot

`θ`'s five coordinates have wildly different natural (prior) scales -- e.g.
`dns`'s prior σ is routinely 3-4 orders of magnitude tighter than `δρ1`'s,
since `dns` is pinned mostly by water's precisely-known bulk electron
density while `δρ1` carries a much looser structural prior.
`AdvancedHMC.jl`'s `find_good_stepsize` explores from an *identity* mass
matrix, before any mass-matrix adaptation has run, so a generic O(1)
momentum kick is ~1 prior-σ along `δρ1` but thousands of prior-σ along
`dns` -- routinely enough to send `dns` to an unphysical density contrast
and blow the forward model up to a flat curve (`wls_fit`'s
`det(XᵀWX) ≤ 0` guard) before step-size adaptation ever gets a chance to
shrink it, i.e. the fragility this was written to fix isn't bad luck, it's
`θ`-space's scale mismatch meeting an isotropic initial explorer.

Sampling in `z`-space instead makes a generic O(1) kick ~1 prior-σ in
*every* coordinate uniformly (each `z_i` is standard-Normal under the
prior), so `find_good_stepsize`'s very first candidate step is no longer
essentially guaranteed to overshoot `dns`. `DenseEuclideanMetric`
adaptation still learns any *residual* (posterior, not prior) curvature/
correlation on top of this once it starts -- this only fixes the
initialization step that runs before adaptation exists to fix it.

The Jacobian of this affine map (`|dθ/dz| = Πσ_i`) is a `z`-independent
constant, so it's omitted from `_logπ`/the z-space wrapper around it: an
additive constant to `log π` doesn't change gradients or Hamiltonian
*differences*, which is all `AdvancedHMC.jl` ever uses (same "up to the
additive constant NUTS doesn't need" already true of `_logπ` itself).

# Arguments
- `θ`/`z::SVector{5,<:Real}`: as above.
- `p::ξ_priors`: supplies `(μ, σ)` via [`θ_prior_moments`](@ref).
"""
function _standardize(θ::SVector{5,<:Real}, p::ξ_priors)
    μ, σ = θ_prior_moments(p)
    return (θ .- μ) ./ σ
end

function _destandardize(z::SVector{5,<:Real}, p::ξ_priors)
    μ, σ = θ_prior_moments(p)
    return μ .+ σ .* z
end

"""
    prior_z_scores(ξ::SVector{5,<:Real}, p::ξ_priors) -> SVector{5,Float64}

How many prior standard deviations a physical-space point `ξ = (dns, δρ1,
δρ2, δρ3, c1)` sits from its own prior `p`, one entry per coordinate:
`z = (θ - μ) / σ` in θ-space, where `θ = Θ(ξ)` and `(μ, σ)` are the prior's
own per-coordinate θ-space mean/std from [`θ_prior_moments`](@ref) -- the
same affine map [`_standardize`](@ref) uses internally for HMC, exposed here
as a reporting utility instead of kept private to the sampler.

Every `z_i` is, by construction, a standard-Normal variate under `p` alone
(see `θ_prior_moments`'s docstring for why every θ-coordinate is exactly
Normal under the prior), so this is a plain, general-purpose "how many
sigmas out" readout with no per-parameter special-casing needed. Used by
[`BayeSol.write_report`](@ref)'s "Standard deviations from prior" table, for
both the MAP draw and the reported quantile bounds.

# Arguments
- `ξ::SVector{5,<:Real}`: the physical-space point to score.
- `p::ξ_priors`: supplies `(μ, σ)` via [`θ_prior_moments`](@ref).
"""
function prior_z_scores(ξ::SVector{5,<:Real}, p::ξ_priors)::SVector{5,Float64}
    θ, _ = Θ(ξ)
    μ, σ = θ_prior_moments(p)
    return (θ .- μ) ./ σ
end

"Dispatch tag selecting profile vs. marginal log-likelihood in [`_ll`](@ref)."
abstract type LIKELIHOOD end

"Log-likelihood of the data at a given `ξ = (dns, δρ1, δρ2, δρ3, c1)`. The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale `scale` and background offset
`bkgrnd_corr`, i.e. `I_calc = scale·y_model + bkgrnd_corr`. `WLS.jl` fits
`(scale, bkgrnd_corr)` in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by `l`:

- `l = PROFILE()`: treat `(scale, bkgrnd_corr)` as pinned at their best-fit
    values (a point estimate) — [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning `(scale, bkgrnd_corr)`, integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in `scale, bkgrnd_corr`) —
    [`wls_marg_ll`](@ref). This adds a
    correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"
struct PROFILE<:LIKELIHOOD  
    type::AbstractString
    PROFILE() = new("profile_log_likelihood")
end

"Log-likelihood of the data at a given `ξ = (dns, δρ1, δρ2, δρ3, c1)`. The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale `scale` and background offset
`bkgrnd_corr`, i.e. `I_calc = scale·y_model + bkgrnd_corr`. `WLS.jl` fits
`(scale, bkgrnd_corr)` in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by `l`:

- `l = PROFILE()`: treat `(scale, bkgrnd_corr)` as pinned at their best-fit
    values (a point estimate) — [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning `(scale, bkgrnd_corr)`, integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in `scale, bkgrnd_corr`) —
    [`wls_marg_ll`](@ref). This adds a
    correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"
struct MARGINAL<:LIKELIHOOD 
    type::AbstractString
    MARGINAL() = new("marginal_log_likelihood")
end

__ll(fit::WLSFit, ::PROFILE)  = wls_prof_ll(fit)
__ll(fit::WLSFit, ::MARGINAL) = wls_marg_ll(fit)

"""
    _ll(I_exp, σ_exp, ξ, fw, l::LIKELIHOOD) -> Real

Log-likelihood of the data at a given `ξ = (dns, δρ1, δρ2, δρ3, c1)`. The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale `scale` and background offset
`bkgrnd_corr`, i.e. `I_calc = scale·y_model + bkgrnd_corr`. `WLS.jl` fits
`(scale, bkgrnd_corr)` in closed form (2-parameter weighted linear
regression), and reports the resulting Gaussian log-likelihood two ways,
selected by `l`:

- `l = PROFILE()`: treat `(scale, bkgrnd_corr)` as pinned at their best-fit
    values (a point estimate) — [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning `(scale, bkgrnd_corr)`, integrate
    them out analytically under a flat prior (Gaussian integral in closed
    form since the problem is linear in `scale, bkgrnd_corr`) —
    [`wls_marg_ll`](@ref). This adds a
    correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.

# Arguments
- `I_exp::AbstractVector`, `σ_exp::AbstractVector`: measured intensity and
    per-point standard errors, forwarded to [`wls_fit`](@ref).
- `ξ::SVector{5,<:Real}`: the physical fit parameters `(dns, δρ1, δρ2, δρ3, c1)`.
- `fw::ForwardCache`: the structure's geometry-only cache, from [`BayeSol.Scattering.forward_cache`](@ref).
- `l::LIKELIHOOD`: `PROFILE()` or `MARGINAL()`, selecting which log-likelihood
    variant to return.

# Returns
- `Real`: the log-likelihood, composing by addition with the log-prior terms.
"""
function _ll(
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    ξ::SVector{5,<:Real},
    fw::ForwardCache,
    l::LIKELIHOOD
)

    # initialize scale and bkgrnd_corr to "no" normilization before WLS
    ŷ = forward(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4]), ξ[5])

    # compute wls fit
    fit = wls_fit(ŷ, I_exp, σ_exp)

    # compute profile log likelihood
    return __ll(fit, l)
end

""" log prior """
_lp(ξ::SVector{5,<:Real}, p::ξ_priors) =
    logpdf(p.dnsPrior, ξ[1]) + logpdf(p.δρ1Prior, ξ[2]) + logpdf(p.δρ2Prior, ξ[3]) +
    logpdf(p.δρ3Prior, ξ[4]) + logpdf(p.c_1Prior, ξ[5])

"""
    _logπ(θ, p, I_exp, σ_exp, fw, l::LIKELIHOOD) -> Real

By change of variables, a density transported from ξ-space into θ-space picks
up the Jacobian of `ξ(θ)`:

    log π(θ) = log p(ξ(θ)) + log|det(∂ξ/∂θ)|

Only three of the five coordinates are reparameterized;
`dns = eᵃ, δρ1 = eᵇ, c1 = eᶜ`, with `δρ2, δρ3` carried
through unchanged. So `∂ξ/∂θ` is diagonal with entries `(eᵃ, eᵇ, 1, 1, eᶜ)` giving:

    log|det(∂ξ/∂θ)| = a + b + c = θ[1] + θ[2] + θ[5]

`log p(ξ(θ))` is the sum of the log-prior and log-likelihood:

    log p(ξ | data) = log p(ξ) + log p(data | ξ) = _lp(ξ, p) + _ll(I_exp, σ_exp, ξ, fw, l)

giving:

    log π(θ) = _lp(ξ(θ), p) + _ll(I_exp, σ_exp, ξ(θ), fw, l) + (θ[1] + θ[2] + θ[5])

# Arguments
- `θ::SVector{5,<:Real}`: the current NUTS position, `(a, b, δρ2, δρ3, c)`.
- `p::ξ_priors`: the physical priors, forwarded to [`_lp`](@ref).
- `I_exp`, `σ_exp`: the data, forwarded to [`_ll`](@ref).
- `fw::ForwardCache`: the structure's geometry-only cache, forwarded to [`_ll`](@ref).
- `l::LIKELIHOOD`: `PROFILE()` or `MARGINAL()`, forwarded to [`_ll`](@ref).

# Returns
- `Real`: `log π(θ)`, up to the additive constant NUTS doesn't need.
"""
function _logπ(
    θ::SVector{5,<:Real},
    p::ξ_priors,
    I_exp,
    σ_exp,
    fw::ForwardCache,
    l::LIKELIHOOD
)
    corr = θ[1] + θ[2] + θ[5] # Jacobian correction
    ξ = Ξ(θ)  # unconstrained θ-space -> physical ξ-space
    return _lp(ξ, p) + _ll(I_exp, σ_exp, ξ, fw, l) + corr
end

"""
    Seed{T<:Real, V<:AbstractVector}

Everything [`run_fitting`](@ref) needs to start a NUTS chain.

# Fields
- `pr::ξ_priors`: the physical priors over `ξ`, from [`_calc_ξ_priors`](@ref).
- `ξ₀::SVector{5,T}`: one draw from `pr`, in physical ξ-space, from [`_ξ₀`](@ref).
- `θ₀::SVector{5,T}`: `ξ₀` reparameterized into unconstrained θ-space via [`Θ`](@ref).
- `fw::ForwardCache`: the structure's geometry-only cache (the Gram matrix
    `G(q)`, q-grid, and mean atomic radius), from `forward_cache`.
- `ex::Tuple{V,V}`: `(I_exp, σ_exp)`, the measured intensity curve and its
    per-point standard errors.
"""
struct Seed{T<:Real, V<:AbstractVector}
    pr::ξ_priors
    ξ₀::SVector{5,T}
    θ₀::SVector{5,T}
    fw::ForwardCache
    ex::Tuple{V,V}
end

"""
Runs initial seeding for sampler. `seed_fitting` is deliberately a thin,
structure-agnostic step: it takes the physical priors' `(μ_χ, σ_χ)` as plain
numbers, same as `_calc_ξ_priors` does, rather than computing them itself from
a `Molecule`/`Residues`/pKa records. Building `Ionization` and calling
`protein_cavity_electrostatics` is the caller's job (e.g. an orchestration
function that already has the structure in hand) — `seed_fitting` only turns
already-known priors and experimental data into a `Seed`.

# Arguments
- `fw::ForwardCache`: Cache of the forward model
- `I_exp::AbstractVector`: Experimental intensity curve
- `σ_exp::AbstractVector`: Per-q standard deviation
- `pH::Real`: pH of the solution; forwarded to `PartialMolarVolumes.ϕ°` for
    `Protein` solutes.
- `σ_pH::Real`: standard uncertainty on `pH`, propagated through each `Protein`
    solute's titration term.
- `solutes::Vector{Solute}`: the species in solution.

# Keywords
- `t::Real = DEFAULT_TEMPERATURE_C`: solution temperature in °C, forwarded to
    `PartialMolarVolumes.ρₑ_w`. **!!NOTE!!: as of this version, this should NOT
    be changed, since only water is temperature-dependent.**
- `μ_χ::Real = 0`, `σ_χ::Real = 0.0`: mean/standard deviation, over cavity beads,
    of the screened-electrostatic potential χ, feeding δρ3's cavity-water
    contrast — forwarded straight to `_calc_ξ_priors`. Compute these with
    `protein_cavity_electrostatics` beforehand if the structure has real
    ionizable charge sites; left at `0`/`0.0` otherwise.
- `n::Real = C1_PRIOR_MASS_PERCENT`: percentage `(0, 100]` of the prior mass required to
    fall within CRYSOL's bound `[0.96, 1.04]` around its default `c_1 = 1`. Higher `n`
    concentrates more mass near the default; lower `n` allows more spread — only
    change from the default if more spread is needed.
"""
function seed_fitting(
    fw::ForwardCache,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    μ_χ::Real = 0,
    σ_χ::Real = 0.0,
    n::Real = C1_PRIOR_MASS_PERCENT,
)::Seed
    pr = _calc_ξ_priors(pH, σ_pH, solutes; t=t, μ_χ=μ_χ, σ_χ=σ_χ, n=n)
    ξ₀ = _ξ₀(pr)
    θ₀, _ = Θ(ξ₀)
    ex = (I_exp, σ_exp)
    return Seed(pr, ξ₀, θ₀, fw, ex)
end

"""
    FitResult{S}

Typed return of [`run_fitting`](@ref)/`BayeSol.run_model`: the posterior
draws of the physical parameters `ξ = (dns, δρ1, δρ2, δρ3, c1)`, one
`(scale, bkgrnd_corr)` pair and predicted curve per draw, and
`AdvancedHMC.jl`'s own per-iteration diagnostics.

# Fields
- `samples::Vector{SVector{5,Float64}}`: posterior draws of `ξ`, length `n_samples`.
- `stats::Vector{S}`: `AdvancedHMC.jl`'s per-iteration diagnostics, matching
    `samples` index-for-index.
- `scale::Vector{Float64}`: the WLS estimate of the scale correction at samples[i].
-  `bkgrnd_corr::Vector{Float64}`: the WLS estimate of the background correction at samples[i].
- `chisq_red::Vector{Float64}`:  the reduced χ² of the WLS estimate 
- `curves::Matrix{Float64}`, `(Q, n_samples)`: the detector-scale predicted
    curve `I_calc(q) = scale[i]·y_model(q) + bkgrnd_corr[i]` for each
    `samples[i]`, column-matching `scale`/`bkgrnd_corr`. Equivalently
    `curves[:, i] == forward(seed.fw, scale[i], bkgrnd_corr[i], samples[i][1],
    (samples[i][2], samples[i][3], samples[i][4]), samples[i][5])`.
- `likelihood::AbstractString`: the likelihood type
"""
struct FitResult{S}
    samples::Vector{SVector{5,Float64}}
    stats::Vector{S}
    scale::Vector{Float64}
    bkgrnd_corr::Vector{Float64}
    chisq_red::Vector{Float64}
    curves::Matrix{Float64}
    likelihood::AbstractString
end

"""
    run_fitting(
        seed::Seed,
        n_samples::Int64,
        n_adapt::Int64;
        l::LIKELIHOOD=PROFILE(),
        δ::Real=80
    ) -> FitResult

Run NUTS on [`_logπ`](@ref) starting from `seed`, returning posterior draws
of the physical parameters `ξ = (dns, δρ1, δρ2, δρ3, c1)`, one `(scale,
bkgrnd_corr)` pair per draw (see `# Returns` below), and `AdvancedHMC.jl`'s
own per-iteration diagnostics.

# The Hamiltonian

HMC adds an auxiliary momentum `r ~ N(0, M)` (`M` the mass matrix) and defines 
a Hamiltonian:

    H(θ, r) = -log π(θ) + ½ rᵀM⁻¹r

with potential energy as the negative log-posterior, and Gaussian kinetic energy. 
Leapfrog integration simulates the system's dynamics forward in time,
alternating half-steps in `r` with full steps in `θ`:

    r ← r - (ε/2)·∇[-log π(θ)]
    θ ← θ + ε·M⁻¹r
    r ← r - (ε/2)·∇[-log π(θ)]

which needs `∇[log π(θ)]` at every step.

Because energy is conserved, leapfrog proposes long, correlated jumps through
parameter space far more cheaply than random-walk Metropolis. NUTS removes the
need to hand-pick a trajectory length: it grows the leapfrog trajectory by
doubling a binary tree of steps, forward and backward in time, until the trajectory
starts to double back on itself (a "U-turn"), then samples from the valid part of that tree.

# Step-size adaptation

`δ` is the target Metropolis acceptance rate. During the first `n_adapt` iterations,
`StepSizeAdaptor` tunes the leapfrog step size `ε` via dual-averaging so the
empirical acceptance rate converges to `δ`; too-small `ε` wastes computation
taking tiny steps, too-large `ε` causes leapfrog's discretization error (and
therefore the rejection rate) to blow up. `MassMatrixAdaptor` learns `M` (here the 
full parameter covariance, since `dns`/`δρ`/`c1` are physically coupled through the 
forward model) from the trajectory's sample covariance.

# Arguments
- `seed::Seed`:         priors, initial point, forward cache, and data.
- `n_samples::Int64`:   total number of NUTS iterations.
- `n_adapt::Int64`:     number of warm-up iterations spent adapting the step
                        size and mass matrix before sampling proper.

# Keywords
- `l::LIKELIHOOD=PROFILE()`:    `PROFILE()` or `MARGINAL()`, forwarded to
                                [`_logπ`](@ref)/[`_ll`](@ref).
- `δ::Real=80`:                 target acceptance rate as a percentage, `(0, 100)` exclusive; 
                                Stan's usual default of 80% is used.

# Returns
A [`FitResult`](@ref). Includes the `n_adapt` warm-up draws; a caller that wants a
warmup-free posterior slices `n_adapt+1:end` (`curves`: `[:, n_adapt+1:end]`)
out of every field itself.
"""
function run_fitting(
    seed::Seed,
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD=PROFILE(),
    δ::Real=80
)::FitResult

    if δ <= 0 || δ >= 100
        throw(DomainError(δ, "0 < δ < 100"))
    end
    δ = δ / 100

    if n_adapt >= n_samples 
        throw(DomainError((n_adapt, n_samples), "n_adapt must be < n_samples"))
    end

    # ℓπ: z ↦ log π(θ(z)), the value-only log-posterior in prior-standardized z-space.
    ℓπ = @closure z -> _logπ(
        _destandardize(SVector{5,eltype(z)}(z...), seed.pr),
        seed.pr,
        seed.ex[1],
        seed.ex[2],
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
    # 5 or 6 params and they are highly coupled, it is worth it here.
    metric = DenseEuclideanMetric(5)

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
    samples, stats = sample(
        hamiltonian,
        kernel,
        z₀,
        n_samples,
        adaptor,
        n_adapt;
        progress=true
    )
    samples = [Ξ(_destandardize(SVector{5,Float64}(s...), seed.pr)) for s in samples]

    # scale/bkgrnd_corr are fit in closed form (wls_fit) and discarded on
    # every single ℓπ/gradient evaluation above.
    scale        = Vector{Float64}(undef, n_samples)
    bkgrnd_corr  = Vector{Float64}(undef, n_samples)
    χ²           = Vector{Float64}(undef, n_samples) 
    curves       = Matrix{Float64}(undef, length(seed.fw.qvals), n_samples)
    I_exp, σ_exp = seed.ex
    for (i, ξ) in enumerate(samples)
        ŷ              = forward(seed.fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4]), ξ[5])
        fit            = wls_fit(ŷ, I_exp, σ_exp)
        scale[i]       = fit.scale
        bkgrnd_corr[i] = fit.bkgrnd_corr
        χ²[i]          = reduced_chi2(fit)
        curves[:, i]   = wls_predict(fit, ŷ)
    end
    
    return FitResult(samples, stats, scale, bkgrnd_corr, χ², curves, l.type)

end
