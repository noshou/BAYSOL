# SPDX-License-Identifier: LGPL-2.1-or-later

using Distributions
using StaticArrays: SVector
using ..PhysicalConstants: DRO_UNIT

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
([`DRO_BOUNDS`](@ref)).

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
so the mode stays at [`DRO12_MODE`](@ref) if [`DRO_BOUNDS`](@ref) ever changes:

    m = (DRO12_MODE − X)/W,    α = 1 + m·κ,    β = 1 + (1 − m)·κ,    W = Y − X

# Arguments
- `κ::Real`: the concentration κ = α + β − 2 > 0 shared by both priors
    (default in the sampler: [`DRO12_CONCENTRATION`](@ref)).

# Returns
- `(δρ₁, δρ₂)::NTuple{2,BoundedBeta}`: two identical
    `LocationScale(-10, 12, Beta(1 + 11κ/12, 1 + κ/12))` priors on [-10, 2].

# Exceptions
- `DomainError`: κ ≤ 0.
"""
function _δρ₁₂_priors(κ::Real)::Tuple{BoundedBeta, BoundedBeta}
    if (κ <= 0)
        throw(DomainError(κ, "failed assertion: κ > 0"))
    end

    X = DRO_BOUNDS[1]
    W = DRO_BOUNDS[2] - DRO_BOUNDS[1]

    # mode of u that puts δρ's mode at DRO12_MODE (= 11/12 for CRYSOL's 1 on [-10, 2])
    m = (DRO12_MODE - X) / W
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

    DRO_UNIT·δρ₃    = (φ − 1)·ρₑ
                    = ρ_cavity − ρₑ.

Thus φ is a reparameterisation of the cavity beads' excess electron density over the bulk,
and δρ₃ is that excess in units of 0.03.

Because ρₑ appears in it, δρ₃ is not independent of the solvent density. By fixing ρₑ to ρ̄ₑ,
we get a fixed value for the bulk electron density. Since `ρ_cavity` ≥ 0, we require φ ≥ 0,
which gives the lower bound:

    δρ₃ ≥ −ρ̄ₑ/DRO_UNIT.

If we additionally impose an upper bound φ ≤ `φ_max`, then the corresponding upper bound is

    δρ₃ ≤ (φ_max − 1)·ρ̄ₑ/DRO_UNIT.

Therefore:

    δρ₃ ∈ [−ρ̄ₑ/DRO_UNIT, (φ_max − 1)·ρ̄ₑ/DRO_UNIT]

Let u ~ Beta(α, β), which gives u ∈ [0, 1]. To stretch it onto a new
interval [X, Y], scale by the width (Y-X) and shift by X. If X = −`ρ̄ₑ/DRO_UNIT`
and Y = (`φ_max` − 1)·`ρ̄ₑ/DRO_UNIT`:

    δρ₃ = X + (Y − X)·u  
        = −ρ̄ₑ/DRO_UNIT + ((φ_max − 1)·ρ̄ₑ/DRO_UNIT - −ρ̄ₑ/DRO_UNIT)·u 
        = ρ̄ₑ(φ_max·u - 1) / DRO_UNIT

If we want the mode of δρ₃ to equal 0 (CRYSOL3's defaults) we get:

    0 = ρ̄ₑ(φ_max·u - 1) / DRO_UNIT
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

σ²[δρ₃] = (`φ_max`·`ρ̄ₑ/DRO_UNIT`)²·σ²[u].

Thus κ controls the concentration of the prior while preserving its mode at δρ₃ = 0.

The sampler samples δρ₃ directly, with u = (δρ₃ − X)/(Y − X) ~ Beta(α, β) as above, on
these fixed bounds. Because ρ̄ₑ is fixed rather than the sampled ρₑ, φ = 1 + `DRO_UNIT`·δρ₃/ρₑ
can leave [0, `φ_max`] by the relative uncertainty of ρₑ, at most ~0.06% for the buffers
checked. φ is not a parameter; it is only the derivation of the bounds and the mode.

# Arguments
- `κ::Real`: the concentration κ = α + β − 2 > 0 (default in the sampler:
    [`DRO3_CONCENTRATION`](@ref)).
- `ρ̄ₑ::Real`: the bulk solvent electron density fixing the bounds, e·Å⁻³
    (the sampler passes the mean of [`ρₑ_prior`](@ref)).

# Returns
- `δρ₃::BoundedBeta`:
    `LocationScale(−ρ̄ₑ/DRO_UNIT, φ_max·ρ̄ₑ/DRO_UNIT, Beta(1 + κ/φ_max, 1 + (1 − 1/φ_max)·κ))`.

# Exceptions
- `DomainError`: κ ≤ 0 or ρ̄ₑ ≤ 0.
"""
function _δρ₃_prior(κ::Real, ρ̄ₑ::Real)::BoundedBeta
    if (κ <= 0)
        throw(DomainError(κ, "failed assertion: κ > 0"))
    elseif (ρ̄ₑ <= 0)
        throw(DomainError(ρ̄ₑ, "failed assertion: ρ̄ₑ > 0"))
    end

    X = -ρ̄ₑ / DRO_UNIT
    W = φ_max * ρ̄ₑ / DRO_UNIT

    α = 1 + κ/φ_max
    β = 1 + (1 - 1/φ_max) * κ
    u = Beta(α, β)

    return LocationScale(X, W, u)
end

"""
Priors on the three hydration-shell contrasts (δρ₁, δρ₂, δρ₃), in units of
[`DRO_UNIT`](@ref). Each is a Beta stretched onto a bounded
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
    [−`ρ̄ₑ/DRO_UNIT`, (`φ_max` − 1)·`ρ̄ₑ/DRO_UNIT`].

# Exceptions
- `DomainError`: `κ_δρ₁₂` ≤ 0, `κ_δρ₃` ≤ 0 or ρ̄ₑ ≤ 0.
"""
function δρ_prior(
    κ_δρ₁₂::Real,
    κ_δρ₃::Real,
    ρ̄ₑ::Real
)::Tuple{
    BoundedBeta,
    BoundedBeta,
    BoundedBeta
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
