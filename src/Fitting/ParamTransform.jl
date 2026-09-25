# SPDX-License-Identifier: LGPL-2.1-or-later

using StaticArrays

"""

    ξ ∈ (0,∞) × (0,∞) × ℝ × ℝ × (0,∞)
    │
    │ Θ: ξ ⤇ (θ, corr)
    │
    ▼
    θ ∈ ℝ⁵

Let the following parameters be:

    - dns ∈ (0,∞) be the mean bulk electron density displaced by solvent atoms
    - δρ1 ∈ (0,∞) be the change in electron density of convex water beads
    - δρ2 ∈ ℝ be the change in electron density of concave water beads
    - δρ3 ∈ ℝ be the change in electron density of cavity water beads
    - c_1 ∈ (0,∞) be the scaling factor for excluded volume

We therefore have the following parameter vector ξ:

    ξ ∈ (0,∞) × (0,∞) × ℝ × ℝ × (0,∞) = ⟨dns, δρ1, δρ2, δρ3, c1⟩

NUTS/HMC work best when the parameters are unconstrained in euclidean space.
Let (a,b,c) ∈ ℝ be some unconstrained variables. Define the following
inverse bijection:

    dns = eᵃ
    δρ1 = eᵇ
    c_1 = eᶜ

where  (dns,δρ1,c_1) > 0, a = ln(dns), b = ln(δρ1), and c = ln(c_1).
δρ2, δρ3 carry through unchanged giving the θ-space parameter vector:

    θ = ⟨a, b, δρ2, δρ3, c⟩ ∈ ℝ⁵

Since the priors and likelihood are in ξ-space, we must transform them into
θ-space. HMC and the priors' logpdf both work in ln-density, so
this is done in ln form:

    ln(p(θ))    = ln(p(ξ(θ))) + ln(|det(∂ξ/∂θ)|)
                = ln(p(ξ(θ))) + ln(eᵃ⁺ᵇ⁺ᶜ)
                = ln(p(ξ(θ))) + a + b + c
# Arguments
- `ξ::SVector{5,<:Real} = (dns, δρ1, δρ2, δρ3, c_1)`: the physical fit
    parameters, in ξ-space. dns, δρ1, c_1 must be > 0; δρ2, δρ3 are unrestricted.

# Returns
- `θ::SVector{5,<:Real} = (a, b, δρ2, δρ3, c)`: the unconstrained ℝ⁵ point.
- `corr::Real = a + b + c = ln|det(∂ξ/∂θ)|`: the log-Jacobian correction

"""
function Θ(ξ::SVector{5,<:Real})
    a = log(ξ[1])
    b = log(ξ[2])
    c = log(ξ[5])
    θ = SVector{5}(a, b, ξ[3], ξ[4], c)
    return θ, a + b + c
end

"""
    θ ∈ ℝ⁵
    │
    │ Ξ: θ ⤇ ξ
    │
    ▼
    ξ ∈ (0,∞) × (0,∞) × ℝ × ℝ × (0,∞)

Inverse of [`Θ`](@ref): θ-space (unconstrained ℝ⁵) back to ξ-space.

# Arguments
- `θ::SVector{5,<:Real} = (a, b, δρ2, δρ3, c)`: unconstrained ℝ⁵.

# Returns
- `ξ::SVector{5,<:Real} = (dns, δρ1, δρ2, δρ3, c_1)`

"""
function Ξ(θ::SVector{5,<:Real})
    return SVector{5}(exp(θ[1]), exp(θ[2]), θ[3], θ[4], exp(θ[5]))
end
