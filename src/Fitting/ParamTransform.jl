# SPDX-License-Identifier: LGPL-2.1-or-later

using StaticArrays
using ..BAYSOL_Utils.Constants: DRO_BOUNDS
using LogExpFunctions: logit, logistic, loglogistic

"Lower end L and width W of the δρ₁/δρ₂ support [L, L + W] = [`DRO_BOUNDS`](@ref)."
const _DRO_L = DRO_BOUNDS[1]
const _DRO_W = DRO_BOUNDS[2] - DRO_BOUNDS[1]

"""
$(TYPEDSIGNATURES)

log|dx/dt| of the scaled-logistic map x = L + W·σ(t): log W + log σ(t) + log(1 - σ(t)),
written with `loglogistic` so it stays finite for any t.
"""
_t_logjac(t::Real, W::Real) = log(W) + loglogistic(t) + loglogistic(-t)

"""
$(TYPEDSIGNATURES)

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

with (L, L + W) = DRO_BOUNDS = (-10, 2), CRYSOL3's fitting limits, and (L₃, L₃ + W₃) the
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
    t₁ = logit((ξ[2] - _DRO_L) / _DRO_W)
    t₂ = logit((ξ[3] - _DRO_L) / _DRO_W)
    t₃ = logit((ξ[4] - p.δρ₃Prior.μ) / p.δρ₃Prior.σ)
    θ = SVector{4}(a, t₁, t₂, t₃)
    return θ, logjac(θ, p)
end

"""
$(TYPEDSIGNATURES)

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
        _DRO_L + _DRO_W * logistic(θ[2]),
        _DRO_L + _DRO_W * logistic(θ[3]),
        p.δρ₃Prior.μ + p.δρ₃Prior.σ * logistic(θ[4]),
    )
end

"""
$(TYPEDSIGNATURES)

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
    θ[1] + _t_logjac(θ[2], _DRO_W) + _t_logjac(θ[3], _DRO_W) + _t_logjac(θ[4], p.δρ₃Prior.σ)


"""
$(TYPEDSIGNATURES)

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
$(TYPEDSIGNATURES)

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
