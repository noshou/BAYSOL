# SPDX-License-Identifier: LGPL-2.1-or-later

# The priors of the sampled vector ξ = (ρₑ, δρ₁, δρ₂, δρ₃) and the map between its
# bounded physical coordinates and the unconstrained θ the sampler works in: the bulk
# electron density from the buffer's solutes (DensityOfSolvent), the hydration-shell
# contrasts (DeltaRho), and the transform with its Jacobian (ParamTransform).

using Distributions
using StaticArrays
using LogExpFunctions: logit, logistic, loglogistic
using ..PhysicalConstants: UNIT_OF_δρ


"""
The number of sampled physical parameters ξ of `p`'s parameterization: 4 for
[`ξ_priors`](@ref) (ρₑ, δρ₁, δρ₂, δρ₃). The sampler, the MAP search, the
likelihood and the report are written for any `N`; only the prior-specific
pieces (the transform [`Θ`](@ref)/[`Ξ`](@ref), [`θ_prior_moments`](@ref),
the log-prior) know the parameterization, and a parameterization with more
parameters adds methods of this function and of those.
"""
nparams(::ξ_priors) = 4

"""
The report key of each coordinate of ξ for `p`, in ξ
order (the keys of `run_model`'s parameter dictionaries).
"""
param_keys(::ξ_priors) = ("slvnt_e_dns", "delta_rho_1", "delta_rho_2", "delta_rho_3")

# ---------------------------------------------------------------------------
#   Prior on the bulk electron density
# ---------------------------------------------------------------------------

"""
Prior distribution for the bulk electron density ρₑ, as a LogNormal
moment-matched to the mean and standard deviation returned by
[`BulkElectronDensity.ρₑ`](@ref BAYSOL.BulkElectronDensity.ρₑ) (see it
for the model, including how temperatures away from 25 °C are handled).

Given μ = ρₑ, σ = √σ², the LogNormal(μln, σln) parameters are:

    σ_ln = √(ln(1 + σ²/μ²))
    μ_ln = ln(μ) − σ_ln²/2

# Arguments
- `pH::Real`: pH of the solution; forwarded to `BulkElectronDensity.ρₑ`.
- `σ_pH::Real`: standard uncertainty on pH; must be ≥ 0.
- `solutes::Vector{Solute}`: the buffer's components, **excluding the measured
    macromolecule** (see [`Solute`](@ref)). Empty means pure water.

# Keywords
- `t::Real=DEFAULT_TEMPERATURE_C`: sample temperature
    in °C, forwarded to `BulkElectronDensity.ρₑ`.

# Returns
- `LogNormal{Float64}`: prior distribution over ρₑ.

# Exceptions
- `DomainError`: thrown if `σ_pH` < 0.
"""
function ρₑ_prior(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
)::LogNormal{Float64}

    σ_pH < 0 && throw(DomainError(σ_pH, "σ_pH must be ≥ 0"))

    μ, σ = BulkElectronDensity.ρₑ(pH, σ_pH, solutes; t = t)

    σ_ln = sqrt(log(1 + (σ / μ)^2))
    μ_ln = log(μ) - σ_ln^2 / 2

    return LogNormal(μ_ln, σ_ln)
end

# ---------------------------------------------------------------------------
#   Hydration-shell contrasts δρ₁, δρ₂, δρ₃
# ---------------------------------------------------------------------------

"""
Prior distributions for δρ₁ and δρ₂, the changes in bulk solvent electron density at the
surface for convex and concave beads respectively.

From the CRYSOL3 manual:

    "The default parameters of the contrasts for the three types of water beads
    are 1, 1, 0 in relative units (where 1 corresponds to dro = 0.03 e/A3)"

    "The limits during the fitting are -10 to 2, where negative value corresponds
    to the space in fact inaccessible to water and therefore indirectly contributing
    to the total excluded volume"

CRYSOL limits all three bead contrasts to −10 ≤ c ≤ 2 in units of 0.03
([`BOUNDS_δρ₁₂`](@ref)).

At ρₑ = 0.334 that's ρ₁ ∈ [0.034, 0.394]: from nearly empty to 18% denser than bulk.
δρ₁ and δρ₂ use these limits. δρ₃ uses the physical bounds of the cavity occupancy
instead (see [`_δρ₃_prior`](@ref)).

Let u ~ Beta(α, β), which gives u ∈ [0, 1]. To stretch it onto a new interval [X, Y],
scale by the width (Y-X) and shift by X. If X = -10 and Y = 2:

    δρ  = X + (Y − X)·u
        = -10 + (2 - (-10))·u
        = -10 + 12·u

If we want the mode of δρ to equal 1 (CRYSOL3's defaults) we get:

    1  = -10 + 12·u
    11 = 12·u
    u  = 11/12

Which means the distribution must have a mode of 11/12.

The mode of a beta distribution is:

    m = (α - 1) / (α + β - 2)

Let m be the mode. For a constant c = (α + β) > 2 we have:

    α = m(c - 2) + 1
    β = (1 - m)(c - 2) + 1

Substituting m = 11/12:


    α = 11c/12 - 5/6
    β = c/12 + 5/6


The concentration is parameterised directly by:

    κ = c - 2

so that:

    α = 1 + 11κ/12
    β = 1 + κ/12


where κ > 0.

The variance of the beta distribution is:

    σ²[u] = αβ / (c²(c + 1))

and therefore:

    σ²[u] = (1 + 11κ/12)(1 + κ/12) / ((κ + 2)²(κ + 3))

The corresponding variance of δρ is:

    σ²[δρ] = 144σ²[u]

Thus κ controls the concentration of the prior while preserving its mode at δρ = 1.

The code computes the general form from the constants rather than the literals above,
so the mode stays at [`MODE_δρ₁₂`](@ref) if [`BOUNDS_δρ₁₂`](@ref) ever changes:

    m = (MODE_δρ₁₂ − X)/W,    α = 1 + m·κ,    β = 1 + (1 − m)·κ,    W = Y − X

# Arguments
- `κ::Real`: the concentration κ = α + β − 2 > 0 shared by both priors
    (default in the sampler: [`κ_δρ₁₂`](@ref)).

# Returns
- `(δρ₁, δρ₂)::NTuple{2,BoundedBeta}`: two identical
    `LocationScale(-10, 12, Beta(1 + 11κ/12, 1 + κ/12))` priors on [-10, 2].

# Exceptions
- `DomainError`: κ ≤ 0.
"""
function _δρ₁₂_priors(κ::Real)::Tuple{BoundedBeta,BoundedBeta}
    if (κ <= 0)
        throw(DomainError(κ, "failed assertion: κ > 0"))
    end

    X = BOUNDS_δρ₁₂[1]
    W = BOUNDS_δρ₁₂[2] - BOUNDS_δρ₁₂[1]

    # mode of u that puts δρ's mode at MODE_δρ₁₂ (= 11/12 for CRYSOL's 1 on [-10, 2])
    m = (MODE_δρ₁₂ - X) / W
    α = 1 + m * κ
    β = 1 + (1 - m) * κ
    u = Beta(α, β)

    return (LocationScale(X, W, u), LocationScale(X, W, u))
end


"""
Prior distribution for the change in solvent density in cavities, δρ₃.

"Cavity" is a SASA classification. In SASA.jl, a shell point is CAVITY if it
is an enclosed void the probe can't escape from. The other two classes are
CONVEX and CONCAVE surface beads. Let φ be the density of the water sitting in
enclosed cavities, as a fraction of bulk water:

    φ = ρ_cavity/ρₑ.

where:

    - φ = 1 is bulk-density water.
    - φ = 0 is an empty void.

The forward model builds a contrast vector v = [1, −dns·`g_ex(c1)`, ρ₁, ρ₂, ρ₃] and computes

    I = scale·vᵀG(q)v + bkg

The cavity-bead contrast ρ₃ is the excess electron density relative to bulk:

    UNIT_OF_δρ·δρ₃    = (φ − 1)·ρₑ
                    = ρ_cavity − ρₑ.

Thus φ is a reparameterisation of the cavity beads' excess electron density over the bulk,
and δρ₃ is that excess in units of 0.03.

Because ρₑ appears in it, δρ₃ is not independent of the solvent density.
By fixing ρₑ to ρ̄ₑ, we get a fixed value for the bulk electron density.
Since `ρ_cavity` ≥ 0, we require φ ≥ 0, which gives the lower bound:

    δρ₃ ≥ −ρ̄ₑ/UNIT_OF_δρ.

If we additionally impose an upper bound φ ≤ `φ_max`, then the corresponding upper bound is

    δρ₃ ≤ (φ_max − 1)·ρ̄ₑ/UNIT_OF_δρ.

Therefore:

    δρ₃ ∈ [−ρ̄ₑ/UNIT_OF_δρ, (φ_max − 1)·ρ̄ₑ/UNIT_OF_δρ]

Let u ~ Beta(α, β), which gives u ∈ [0, 1]. To stretch it onto a new
interval [X, Y], scale by the width (Y-X) and shift by X. If X = −`ρ̄ₑ/UNIT_OF_δρ`
and Y = (`φ_max` − 1)·`ρ̄ₑ/UNIT_OF_δρ`:

    δρ₃ = X + (Y − X)·u
        = −ρ̄ₑ/UNIT_OF_δρ + ((φ_max − 1)·ρ̄ₑ/UNIT_OF_δρ - −ρ̄ₑ/UNIT_OF_δρ)·u
        = ρ̄ₑ(φ_max·u - 1) / UNIT_OF_δρ

If we want the mode of δρ₃ to equal 0 (CRYSOL3's defaults) we get:

    0 = ρ̄ₑ(φ_max·u - 1) / UNIT_OF_δρ
    0 = φ_max·u - 1
    u = φ_max⁻¹

Which means the distribution must have a mode of `φ_max`⁻¹.

The mode of a beta distribution is:

    m = (α - 1) / (α + β - 2)

Let m be the mode. For a constant c = (α + β) > 2 we have:

    α = m(c - 2) + 1
    β = (1 - m)(c - 2) + 1

Substituting m = `φ_max`⁻¹:

    α = (c - 2)/φ_max + 1
    β = (2 - c)/φ_max + c - 1

Rather than fixing the variance directly, parameterise the concentration as:

    κ = c - 2

where κ > 0. Then:

    α = 1 + κ/φ_max
    β = 1 + (1 - φ_max⁻¹)·κ

The variance of the beta distribution is:

    σ²[u] = αβ / (c²(c + 1))

and therefore:

    σ²[u] = (1 + κ/φ_max)(1 + (1 - φ_max⁻¹)·κ) / ((κ + 2)²(κ + 3))

The corresponding variance of δρ₃ is:

σ²[δρ₃] = (`φ_max`·`ρ̄ₑ/UNIT_OF_δρ`)²·σ²[u].

Thus κ controls the concentration of the prior while preserving its mode at δρ₃ = 0.

The sampler samples δρ₃ directly, with u = (δρ₃ − X)/(Y − X) ~ Beta(α, β) as above, on these
fixed bounds. Because ρ̄ₑ is fixed rather than the sampled ρₑ, φ = 1 + `UNIT_OF_δρ`·δρ₃/ρₑ
can leave [0, `φ_max`] by the relative uncertainty of ρₑ, at most ~0.06% for the buffers
checked. φ is not a parameter; it is only the derivation of the bounds and the mode.

# Arguments
- `κ::Real`: the concentration κ = α + β − 2 > 0 (default in the sampler:
    [`κ_δρ₃`](@ref)).
- `ρ̄ₑ::Real`: the bulk solvent electron density fixing the bounds, e·Å⁻³
    (the sampler passes the mean of [`ρₑ_prior`](@ref)).

# Returns
- `δρ₃::BoundedBeta`:
    `LocationScale(−ρ̄ₑ/UNIT_OF_δρ, φ_max·ρ̄ₑ/UNIT_OF_δρ,
    Beta(1 + κ/φ_max, 1 + (1 − 1/φ_max)·κ))`.

# Exceptions
- `DomainError`: κ ≤ 0 or ρ̄ₑ ≤ 0.
"""
function _δρ₃_prior(κ::Real, ρ̄ₑ::Real)::BoundedBeta
    if (κ <= 0)
        throw(DomainError(κ, "failed assertion: κ > 0"))
    elseif (ρ̄ₑ <= 0)
        throw(DomainError(ρ̄ₑ, "failed assertion: ρ̄ₑ > 0"))
    end

    X = -ρ̄ₑ / UNIT_OF_δρ
    W = φ_max * ρ̄ₑ / UNIT_OF_δρ

    α = 1 + κ/φ_max
    β = 1 + (1 - 1/φ_max) * κ
    u = Beta(α, β)

    return LocationScale(X, W, u)
end

"""
Priors on the three hydration-shell contrasts (δρ₁, δρ₂, δρ₃), in units of
[`UNIT_OF_δρ`](@ref). Each is a Beta stretched onto a bounded
interval with its mode at CRYSOL3's default (1, 1, 0). See [`_δρ₁₂_priors`](@ref) and
[`_δρ₃_prior`](@ref) for the derivations.

# Arguments
- `κ_δρ₁₂::Real`: concentration κ > 0 of the convex/concave (δρ₁/δρ₂) priors.
- `κ_δρ₃::Real`: concentration κ > 0 of the cavity (δρ₃) prior.
- `ρ̄ₑ::Real`: bulk solvent electron density fixing δρ₃'s bounds, e·Å⁻³.

# Returns
- `δρ₁::BoundedBeta`: convex-bead contrast prior on [-10, 2].
- `δρ₂::BoundedBeta`: concave-bead contrast prior on [-10, 2].
- `δρ₃::BoundedBeta`: cavity-bead contrast prior on
    [−`ρ̄ₑ/UNIT_OF_δρ`, (`φ_max` − 1)·`ρ̄ₑ/UNIT_OF_δρ`].

# Exceptions
- `DomainError`: `κ_δρ₁₂` ≤ 0, `κ_δρ₃` ≤ 0 or ρ̄ₑ ≤ 0.
"""
function δρ_prior(
    κ_δρ₁₂::Real,
    κ_δρ₃::Real,
    ρ̄ₑ::Real,
)::Tuple{
    BoundedBeta,
    BoundedBeta,
    BoundedBeta,
}
    δρ₁_prior, δρ₂_prior = _δρ₁₂_priors(κ_δρ₁₂)
    (δρ₁_prior, δρ₂_prior, _δρ₃_prior(κ_δρ₃, ρ̄ₑ))
end

# TODO: after validating w/ CRYSOL on proteins, move on to fitting w/ nucleotides.

# """
#     δρprior(z, I, σI, ξ, σξ) -> (δρ₁, δρ₂, δρ₃, δρ4)

# Nucleotide variant: δρ₁, δρ₂, δρ₃ as in the protein variant, plus δρ4 for
# cation condensation around the phosphate backbone (Manning theory).

# # Arguments
# - z:   total counterion valence.
# - I:   total ionic strength.
# - σI: uncertainty in ionic strength.
# - ξ:   Manning linear charge density parameter.
# - σξ: uncertainty in ξ.

# # Returns
# - δρ₁::LogNormal: convex-bead contrast (fixed prior).
# - δρ₂::Normal: concave-bead contrast (fixed prior).
# - δρ₃::Beta: cavity-bead contrast (fixed prior).
# - δρ4::LogNormal: condensed-cation-layer contrast, derived from z, I, σI, ξ, σξ.
# """
# function δρ_prior(
#     z::Real,
#     I::Real,
#     σ_I::Real,
#     ξ::Real,
#     σ_ξ::Real
# )::Tuple{LogNormal, Normal, Beta, LogNormal}
# end

# ---------------------------------------------------------------------------
#   Parameter transform and Jacobian
# ---------------------------------------------------------------------------

"""
log|dx/dt| of the scaled-logistic map x = L + W·σ(t): log W + log σ(t) + log(1 - σ(t)),
written with `loglogistic` so it stays finite for any t.
"""
_t_logjac(t::Real, W::Real) = log(W) + loglogistic(t) + loglogistic(-t)

"""
    ξ ∈ (0,∞) × (-10,2) × (-10,2) × (L₃,L₃+W₃)
    │
    │ Θ: ξ ⤇ (θ, corr)
    │
    ▼
    θ ∈ ℝ⁴

Let the following parameters be:

    - ρₑ ∈ (0,∞)        the bulk electron density of the solvent
    - δρ₁ ∈ (L, L + W)  the contrast of convex water beads
    - δρ₂ ∈ (L, L + W)  the contrast of concave water beads
    - δρ₃ ∈ (L₃, L₃ + W₃)  the contrast of cavity water beads

with (L, L + W) = `BOUNDS_δρ₁₂` = (-10, 2), CRYSOL3's fitting limits, and (L₃, L₃ + W₃) the
support of the δρ₃ prior (the `LocationScale`'s μ and σ; [`_δρ₃_prior`](@ref)).

We therefore have the following parameter vector ξ:

    ξ = ⟨ρₑ, δρ₁, δρ₂, δρ₃⟩

NUTS/HMC work best when the parameters are unconstrained in euclidean space. Let:

    σ(t) = 1/(1 + e⁻ᵗ)

and define the following inverse bijection:

    ρₑ  = eᵃ
    δρ₁ = L + W·σ(t₁)
    δρ₂ = L + W·σ(t₂)
    δρ₃ = L₃ + W₃·σ(t₃),

giving the θ-space parameter vector:

    θ = ⟨a, t₁, t₂, t₃⟩ ∈ ℝ⁴

Since the priors and likelihood are in ξ-space, we transform to θ-space:

    ln(p(θ))    = ln(p(ξ(θ))) + ln(|det(∂ξ/∂θ)|)
                = ln(p(ξ(θ))) + a + Σₖ [ln Wₖ + ln σ(tₖ) + ln(1 - σ(tₖ))]

with W₁ = W₂ = W. δρ₁, δρ₂ and δρ₃ all have Beta priors stretched
onto their intervals, so each one's prior-plus-Jacobian term in θ-space is
α ln σ(tₖ) + β ln(1 - σ(tₖ)) − ln B(α, β). The ln Wₖ terms cancel, and the
result is log-concave in tₖ.

# Arguments
- `ξ::SVector{4,<:Real} = (ρₑ, δρ₁, δρ₂, δρ₃)`: the physical fit
    parameters, in ξ-space. ρₑ > 0; δρ₁, δρ₂ ∈ (-10, 2); δρ₃ ∈ (L₃, L₃ + W₃).
- `p::ξ_priors`: supplies (L₃, W₃) = (`p.δρ₃Prior.μ`, `p.δρ₃Prior.σ`).

# Returns
- `θ::SVector{4,<:Real} = (a, t₁, t₂, t₃)`: the unconstrained ℝ⁴ vector.
- `corr::Real = ln|det(∂ξ/∂θ)|`: the log-Jacobian correction.

# Exceptions
- `DomainError`: ξ lies outside the domain above.
"""
function Θ(ξ::SVector{4,<:Real}, p::ξ_priors)
    a  = log(ξ[1])
    t₁ = logit((ξ[2] - LOWER_BOUND_δρ₁₂) / WIDTH_δρ₁₂)
    t₂ = logit((ξ[3] - LOWER_BOUND_δρ₁₂) / WIDTH_δρ₁₂)
    t₃ = logit((ξ[4] - p.δρ₃Prior.μ) / p.δρ₃Prior.σ)
    θ  = SVector{4}(a, t₁, t₂, t₃)
    return θ, logjac(θ, p)
end

"""
    θ ∈ ℝ⁴
    │
    │ Ξ: θ ⤇ ξ
    │
    ▼
    ξ ∈ (0,∞) × (-10,2) × (-10,2) × (L₃,L₃+W₃)

Inverse of [`Θ`](@ref): θ-space (unconstrained ℝ⁴) back to ξ-space.

# Arguments
- `θ::SVector{4,<:Real} = (a, t₁, t₂, t₃)`: unconstrained ℝ⁴.
- `p::ξ_priors`: supplies (L₃, W₃), as in [`Θ`](@ref).

# Returns
- `ξ::SVector{4,<:Real} = (ρₑ, δρ₁, δρ₂, δρ₃)`
"""
function Ξ(θ::SVector{4,<:Real}, p::ξ_priors)
    return SVector{4}(
        exp(θ[1]),
        LOWER_BOUND_δρ₁₂ + WIDTH_δρ₁₂ * logistic(θ[2]),
        LOWER_BOUND_δρ₁₂ + WIDTH_δρ₁₂ * logistic(θ[3]),
        p.δρ₃Prior.μ + p.δρ₃Prior.σ * logistic(θ[4]),
    )
end

"""
ln|det(∂ξ/∂θ)| of [`Ξ`](@ref) at θ, the Jacobian correction [`_logπ`](@ref)
adds; identical to the `corr` [`Θ`](@ref) returns for ξ = Ξ(θ):

    a + Σₖ [ln Wₖ + ln σ(tₖ) + ln(1 - σ(tₖ))]

# Arguments
- `θ::SVector{4,<:Real} = (a, t₁, t₂, t₃)`.
- `p::ξ_priors`: supplies W₃ = `p.δρ₃Prior.σ`.

# Returns
- `Real`: the log-Jacobian.
"""
logjac(θ::SVector{4,<:Real}, p::ξ_priors) =
    θ[1] + _t_logjac(θ[2], WIDTH_δρ₁₂) + _t_logjac(θ[3], WIDTH_δρ₁₂) +
    _t_logjac(θ[4], p.δρ₃Prior.σ)


"""
    ξ ∈ (0,∞) × (-10,2) × (-10,2) × (L₃,L₃+W₃) × (0,∞)
    │
    │ Θ: ξ ⤇ (θ, corr)
    │
    ▼
    θ ∈ ℝ⁵

Nucleotide variant (not wired into the sampler yet): as the 4-parameter
[`Θ`](@ref), plus δρ4 ∈ (0,∞), the condensed-counterion contrast, mapped
by δρ4 = eᶜ:

    θ = ⟨a, t₁, t₂, t₃, c⟩ ∈ ℝ⁵
    ln|det(∂ξ/∂θ)| = logjac(θ[1:4]) + c

# Arguments
- `ξ::SVector{5,<:Real} = (ρₑ, δρ₁, δρ₂, δρ₃, δρ4)`.

# Returns
- `θ::SVector{5,<:Real} = (a, t₁, t₂, t₃, c)`.
- `corr::Real = ln|det(∂ξ/∂θ)|`.
"""
function Θ(ξ::SVector{5,<:Real}, p::ξ_priors)
    θ₄, corr₄ = Θ(SVector{4}(ξ[1], ξ[2], ξ[3], ξ[4]), p)
    c = log(ξ[5])
    return SVector{5}(θ₄..., c), corr₄ + c
end

"""
    θ ∈ ℝ⁵
    │
    │ Ξ: θ ⤇ ξ
    │
    ▼
    ξ ∈ (0,∞) × (-10,2) × (-10,2) × (L₃,L₃+W₃) × (0,∞)

Inverse of the 5-parameter [`Θ`](@ref).

# Arguments
- `θ::SVector{5,<:Real} = (a, t₁, t₂, t₃, c)`.

# Returns
- `ξ::SVector{5,<:Real} = (ρₑ, δρ₁, δρ₂, δρ₃, δρ4)`
"""
function Ξ(θ::SVector{5,<:Real}, p::ξ_priors)
    return SVector{5}(Ξ(SVector{4}(θ[1], θ[2], θ[3], θ[4]), p)..., exp(θ[5]))
end

# ---------------------------------------------------------------------------
#   The priors of ξ, their moments and z-scores
# ---------------------------------------------------------------------------

"""
Generates physical prior distributions of ξ.

# Arguments
- `pH::Real`: pH of the solution; forwarded to
    `BulkElectronDensity.ρₑ` (it drives the Protein/DNA/RNA solutes).
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
    ρₑ = ρₑ_prior(pH, σ_pH, solutes; t = t)
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
