# SPDX-License-Identifier: LGPL-2.1-or-later

using AdvancedHMC: DenseEuclideanMetric, Hamiltonian, MassMatrixAdaptor,
find_good_stepsize, Leapfrog, StanHMCAdaptor, StepSizeAdaptor, sample,
HMCKernel, Trajectory, MultinomialTS, GeneralisedNoUTurn

using FastClosures, StaticArrays, Distributions, ForwardDiff, DiffResults

using ..Scattering: forward, ForwardCache

"Physical prior distributions."
struct _ξ_priors
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
        t::Real = 25.0,
        μ_χ::Real = 0,
        σ_χ::Real = 0.0,
        n::Real = 95
    ) -> _ξ_priors

Generates physical prior distributions of `ξ`.

# Arguments
- `pH::Real`: pH of the solution; forwarded to `PartialMolarVolumes.ϕ°` for `Protein` solutes.
- `σ_pH::Real`: standard uncertainty on `pH`, propagated through each `Protein`
    solute's titration term.
- `solutes::Vector{Solute}`: the  species in solution.

# Keywords
- `t::Real=25.0`:   solution temperature in °C, forwarded to `PartialMolarVolumes.ρₑ_w`.
                    **!!NOTE!!: as of this version, this should NOT be changed, 
                    since only water is temp dependent.**
- `μ_χ`=0.0:        mean, over cavity beads, of the screened-electrostatic potential χ
                    (Debye-Hückel, aggregated from nearby phosphate / ionizable-side-chain
                    charge sites), feeding δρ3's cavity-water contrast.
- `σ_χ`=0.0:        standard deviation, over cavity beads, of χ, feeding δρ3's
                    cavity-water contrast.
- `n`:              percentage ((0, 100]) of the prior mass required to fall within
                    CRYSOL's bound `[0.96, 1.04]` around its default `c_1 = 1`. Higher `n`
                    concentrates more mass near the default; lower `n` allows more spread.
                    Defaulted to `n = 95`; only change if more spread is needed.

"""
function _calc_ξ_priors(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = 25.0,
    μ_χ::Real = 0,
    σ_χ::Real = 0.0,
    n::Real = 95
)::_ξ_priors
    dns = ρₑ_prior(pH, σ_pH, solutes; t=t)
    δρ1, δρ2, δρ3 = δρ_prior(; μ_χ=μ_χ, σ_χ=σ_χ)
    c_1 = c1_prior(n)
    return _ξ_priors(dns, δρ1, δρ2, δρ3, c_1)
end

"""
    _ξ₀(p::_ξ_priors) -> SVector{5,<:Real}

Generates intitial physical parameter vector ξ₀
"""
function _ξ₀(p::_ξ_priors)::SVector{5,<:Real}
    dns = rand(p.dnsPrior)
    δρ1 = rand(p.δρ1Prior)
    δρ2 = rand(p.δρ2Prior)
    δρ3 = rand(p.δρ3Prior)
    c_1 = rand(p.c_1Prior)
    return SVector(dns, δρ1, δρ2, δρ3, c_1)
end

"Dispatch tag selecting profile vs. marginal log-likelihood in [`_ll`](@ref)."
abstract type LIKELIHOOD end

"Log-likelihood of the data at a given `ξ = (dns, δρ1, δρ2, δρ3, c1)`. The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale `m` and background offset `c`, i.e.
`I_calc = m·y_model + c`. `WLS.jl` fits `(m, c)` in closed form (2-parameter
weighted linear regression), and reports the resulting Gaussian log-likelihood
two ways, selected by `l`:

- `l = PROFILE()`: treat `(m, c)` as pinned at their best-fit values (a point
    estimate) — [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning `(m, c)`, integrate them out
    analytically under a flat prior (Gaussian integral in closed form since
    the problem is linear in `m,c`) — [`wls_marg_ll`](@ref). This adds a
    correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"
struct PROFILE<:LIKELIHOOD  end

"Log-likelihood of the data at a given `ξ = (dns, δρ1, δρ2, δρ3, c1)`. The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale `m` and background offset `c`, i.e.
`I_calc = m·y_model + c`. `WLS.jl` fits `(m, c)` in closed form (2-parameter
weighted linear regression), and reports the resulting Gaussian log-likelihood
two ways, selected by `l`:

- `l = PROFILE()`: treat `(m, c)` as pinned at their best-fit values (a point
    estimate) — [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning `(m, c)`, integrate them out
    analytically under a flat prior (Gaussian integral in closed form since
    the problem is linear in `m,c`) — [`wls_marg_ll`](@ref). This adds a
    correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.
"
struct MARGINAL<:LIKELIHOOD end

__ll(fit::WLSFit, ::PROFILE)  = wls_prof_ll(fit)
__ll(fit::WLSFit, ::MARGINAL) = wls_marg_ll(fit)

"""
    _ll(I_exp, σ_exp, ξ, fw, l::LIKELIHOOD) -> Real

Log-likelihood of the data at a given `ξ = (dns, δρ1, δρ2, δρ3, c1)`. The
forward model produces a predicted curve `y_model(q)`, but the data `I_exp(q)`
sits at some unknown overall scale `m` and background offset `c`, i.e.
`I_calc = m·y_model + c`. `WLS.jl` fits `(m, c)` in closed form (2-parameter
weighted linear regression), and reports the resulting Gaussian log-likelihood
two ways, selected by `l`:

- `l = PROFILE()`: treat `(m, c)` as pinned at their best-fit values (a point
    estimate) — [`wls_prof_ll`](@ref):

        -½χ² - ½ Σln(σᵢ²) - ½n·ln(2π)

- `l = MARGINAL()`: instead of pinning `(m, c)`, integrate them out
    analytically under a flat prior (Gaussian integral in closed form since
    the problem is linear in `m,c`) — [`wls_marg_ll`](@ref). This adds a
    correction term:

        -½ln(det(XᵀWX))

    which lets uncertainty in scale/background flow into the posterior on the
    physical parameters, instead of freezing it out.

# Arguments
- `I_exp::AbstractVector`, `σ_exp::AbstractVector`: measured intensity and
    per-point standard errors, forwarded to [`wls_fit`](@ref).
- `ξ::SVector{5,<:Real}`: the physical fit parameters `(dns, δρ1, δρ2, δρ3, c1)`.
- `fw::ForwardCache`: the structure's geometry-only cache, from [`forward_cache`](@ref).
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

    # initialize m and c to "no" normilization before WLS
    ŷ = forward(fw, 1.0, 0.0, ξ[1], (ξ[2], ξ[3], ξ[4]), ξ[5])

    # compute wls fit
    fit = wls_fit(ŷ, I_exp, σ_exp)

    # compute profile log likelihood
    return __ll(fit, l)
end

""" log prior """
_lp(ξ::SVector{5,<:Real}, p::_ξ_priors) =
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

**Pure**, like [`Θ`](@ref)/[`Ξ`](@ref) — no mutation. `θ` is decoded to `ξ` via
[`Ξ`](@ref) rather than overwritten in place; see `Θ`'s docstring for why a
fresh value here is no more expensive than a mutating version would have
been, given what `AdvancedHMC.jl`/`ForwardDiff` actually hand this function
on every call.

# Arguments
- `θ::SVector{5,<:Real}`: the current NUTS position, `(a, b, δρ2, δρ3, c)`.
- `p::_ξ_priors`: the physical priors, forwarded to [`_lp`](@ref).
- `I_exp`, `σ_exp`: the data, forwarded to [`_ll`](@ref).
- `fw::ForwardCache`: the structure's geometry-only cache, forwarded to [`_ll`](@ref).
- `l::LIKELIHOOD`: `PROFILE()` or `MARGINAL()`, forwarded to [`_ll`](@ref).

# Returns
- `Real`: `log π(θ)`, up to the additive constant NUTS doesn't need.
"""
function _logπ(
    θ::SVector{5,<:Real},
    p::_ξ_priors,
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

Everything [`run_fitting`](@ref) needs to start a NUTS chain, built once by
[`seed_fitting`](@ref) and reused across calls to `run_fitting` (e.g. with different
`n_samples`/`l`/`δ`, without redrawing the initial point or rebuilding the
priors each time).

# Fields
- `pr::_ξ_priors`: the physical priors over `ξ`, from [`_calc_ξ_priors`](@ref).
- `ξ₀::SVector{5,T}`: one draw from `pr`, in physical ξ-space, from [`_ξ₀`](@ref).
- `θ₀::SVector{5,T}`: `ξ₀` reparameterized into unconstrained θ-space via
    [`Θ`](@ref) — the actual starting position handed to `AdvancedHMC.sample`.
- `fw::ForwardCache`: the structure's geometry-only cache (the Gram matrix
    `G(q)`, q-grid, and mean atomic radius), from `forward_cache`.
- `ex::Tuple{V,V}`: `(I_exp, σ_exp)`, the measured intensity curve and its
    per-point standard errors.
"""
struct Seed{T<:Real, V<:AbstractVector}
    pr::_ξ_priors
    ξ₀::SVector{5,T}
    θ₀::SVector{5,T}
    fw::ForwardCache
    ex::Tuple{V,V}
end

""" 
runs initial seeding for sampler 

# Arguments
- `fw::ForwardCache`: Cache of the forward model
- `I_exp::AbstractVector`: Experimental intensity curve
- `σ_exp::AbstractVector`: Per-q standard deviation
- `pH::Real`: pH of the solution; forwarded to `PartialMolarVolumes.ϕ°` for `Protein` solutes.
- `σ_pH::Real`: standard uncertainty on `pH`, propagated through each `Protein`
    solute's titration term.
- `solutes::Vector{Solute}`: the  species in solution.

# Keywords
- `t::Real=25.0`:   solution temperature in °C, forwarded to `PartialMolarVolumes.ρₑ_w`.
                    **!!NOTE!!: as of this version, this should NOT be changed, 
                    since only water is temp dependent.**
- `μ_χ`=0.0:        mean, over cavity beads, of the screened-electrostatic potential χ
                    (Debye-Hückel, aggregated from nearby phosphate / ionizable-side-chain
                    charge sites), feeding δρ3's cavity-water contrast.
- `σ_χ`=0.0:        standard deviation, over cavity beads, of χ, feeding δρ3's
                    cavity-water contrast.
- `n`:              percentage ((0, 100]) of the prior mass required to fall within
                    CRYSOL's bound `[0.96, 1.04]` around its default `c_1 = 1`. Higher `n`
                    concentrates more mass near the default; lower `n` allows more spread.
                    Defaulted to `n = 95`; only change if more spread is needed.
"""
function seed_fitting(
    fw::ForwardCache,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = 25.0,
    μ_χ::Real = 0,
    σ_χ::Real = 0.0,
    n::Real = 95
)::Seed
    pr = _calc_ξ_priors(pH, σ_pH, solutes; t=t, μ_χ=μ_χ, σ_χ=σ_χ, n=n)
    ξ₀ = _ξ₀(pr)
    θ₀, _ = Θ(ξ₀)
    ex = (I_exp, σ_exp)
    return Seed(pr, ξ₀, θ₀, fw, ex)
end

"""
    run_fitting(seed::Seed, n_samples::Int64, n_adapt::Int64; l::LIKELIHOOD=PROFILE(), δ::Real=80)
        -> (samples, stats)

Run NUTS on [`_logπ`](@ref) starting from `seed`, returning posterior draws
of the physical parameters `ξ = (dns, δρ1, δρ2, δρ3, c1)`.

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
- `seed::Seed`: priors, initial point, forward cache, and data.
- `n_samples::Int64`: total number of NUTS iterations (including the
    `n_adapt` warm-up steps, which are kept unless `drop_warmup` is set).
- `n_adapt::Int64`: number of warm-up iterations spent adapting the step
    size and mass matrix before sampling proper.

# Keywords
- `l::LIKELIHOOD=PROFILE()`: `PROFILE()` or `MARGINAL()`, forwarded to
    [`_logπ`](@ref)/[`_ll`](@ref).
- `δ::Real=80`: target acceptance rate as a percentage, `(0, 100)` exclusive
    (validated below); Stan's usual default of 80% is used here too absent a
    specific reason to retarget it.

# Returns
- `samples`: a `Vector` of posterior draws, **already decoded back to physical
    ξ-space** (`(dns, δρ1, δρ2, δρ3, c1)`) via [`Ξ`](@ref) — NUTS itself only
    ever sees θ-space, but callers of `run_fitting` want physical units.
- `stats`: per-iteration `NamedTuple`s from `AdvancedHMC.jl` (acceptance rate,
    divergence flags, tree depth, etc.), one per entry of `samples`.
"""
function run_fitting(
    seed::Seed,
    n_samples::Int64,
    n_adapt::Int64;
    l::LIKELIHOOD=PROFILE(),
    δ::Real=80
)

    if δ <= 0 || δ >= 100
        throw(DomainError(δ, "0 < δ < 100"))
    end
    δ = δ / 100

    # ℓπ: θ ↦ log π(θ), the value-only log-posterior (_logπ closed over the
    # data/priors/cache/likelihood-choice fixed for this run). AdvancedHMC.jl
    # hands this a plain-axed AbstractVector (Base.OneTo, not StaticArrays'
    # SOneTo), which _logπ's SVector{5,<:Real} signature can't dispatch on
    # directly, so re-wrap it into an SVector first (same idiom as
    # test_paramtransform.jl's AD-differentiability tests).
    ℓπ = @closure θ -> _logπ(SVector{5,eltype(θ)}(θ...), seed.pr, seed.ex[1], seed.ex[2], seed.fw, l)

    # ∂ℓπ∂θ: θ ↦ (log π(θ), ∇log π(θ)), computed in one ForwardDiff pass —
    # this is what AdvancedHMC's leapfrog integrator actually calls every step.
    ∂ℓπ∂θ = @closure θ -> begin
        result = DiffResults.GradientResult(θ)
        ForwardDiff.gradient!(result, ℓπ, θ)
        (DiffResults.value(result), DiffResults.gradient(result))
    end

    # DenseEuclideanMetric allows the adaptation to learn 
    # correlations between parameters. Since we are only fitting
    # 5 or 6 params and they are highly coupled, it is worth it here.
    metric = DenseEuclideanMetric(5)
    
    # combines "potential energy" (ℓπ) and kinetic energy (from metric)
    hamiltonian = Hamiltonian(metric, ℓπ, ∂ℓπ∂θ)

    # AdvancedHMC.jl's DiagEuclideanMetric/DenseEuclideanMetric store M⁻¹ as
    # a plain Vector/Matrix (Base.OneTo axes) and check axes(M⁻¹) against
    # axes(θ)/axes(r); an SVector's SOneTo axes fail that check even though
    # the ranges match. Start from a plain Vector instead of seed.θ₀ itself.
    θ₀ = Vector(seed.θ₀)

    # HMC numerically integrates the Hamiltonian, so we need to
    # guess a good step size.
    init_step_size = find_good_stepsize(hamiltonian, θ₀)
    
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
    
    # the sampler in θ-space
    kernel = HMCKernel(Trajectory{MultinomialTS}(integrator, GeneralisedNoUTurn()))

    # do sampling
    samples, stats = sample(
        hamiltonian,
        kernel,
        θ₀,
        n_samples,
        adaptor,
        n_adapt;
        progress=true
    )
    samples = [Ξ(SVector{5,Float64}(s...)) for s in samples]
    return (samples, stats)

end
