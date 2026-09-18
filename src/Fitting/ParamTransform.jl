# SPDX-License-Identifier: LGPL-2.1-or-later

using StaticArrays

"""

    ξ ∈ (0,∞) × (0,∞) × ℝ × ℝ × (0,∞)
    │
    │ Θ: ξ ⤇ θ
    │
    ▼
    θ ∈ ℝ⁵

Let the following parameters be:
    
    - dns ∈ (0,∞) be the mean bulk electron density displaced by solvent atoms
    - δρ1 ∈ (0,∞) be the change in electron density of convex water beads
    - δρ2 ∈ ℝ be the change in electron density of concave water beads 
    - δρ3 ∈ ℝ be the change in electron density of cavity water beads
    - c1 ∈ (0,∞) be the scaling factor for excluded volume

We therefore have the following parameter vector ξ:

    ξ ∈ (0,∞) × (0,∞) × ℝ × ℝ × (0,∞) = ⟨dns, δρ1, δρ2, δρ3, c1⟩

NUTS/HMC work best when the parameters are unconstrained in euclidean space.
Let `(a,b,c) ∈ ℝ` be some unconstrained variables. Define the following 
inverse bijection:

    dns = eᵃ
    δρ1 = eᵇ
    c1  = eᶜ

where  `(dns,δρ1,c1) > 0`, `a = ln(dns)`, `b = ln(δρ1)`, and `c = ln(c1)`.
δρ2, δρ3 carry through unchanged giving the θ-space parameter vector:

    θ = ⟨a, b, δρ2, δρ3, c⟩ ∈ ℝ⁵

Since the priors and likelihood are in ξ-space, we must transform them into
θ-space. HMC and the priors' `logpdf` both work in ln-density, so
this is done in ln form:

    ln(p(θ))    = ln(p(ξ(θ))) + ln(|det(∂ξ/∂θ)|)
                = ln(p(ξ(θ))) + ln(eᵃ⁺ᵇ⁺ᶜ)
                = ln(p(ξ(θ))) + a + b + c

# Arguments
-   `ξ::MVector{5,<:Real}` = `(dns, δρ1, δρ2, δρ3, c1)`: the physical fit
    parameters, in ξ-space. `dns`, `δρ1`, `c1` must be `> 0`; `δρ2`, `δρ3` are unrestricted.
    Overwritten in place with `θ` = `(a, b, δρ2, δρ3, c)`.

# Returns
- `corr::Real` = `a + b + c` = `ln|det(∂ξ/∂θ)|`: the log-Jacobian correction

"""
function Θ!(ξ::MVector{5,<:Real})
    a = log(ξ[1])
    b = log(ξ[2])
    c = log(ξ[5])
    ξ[1] = a
    ξ[2] = b
    ξ[5] = c
    return a + b + c
end

"""
    θ ∈ ℝ⁵
    │
    │ Ξ: θ ⤇ ξ 
    │
    ▼
    ξ ∈ (0,∞) × (0,∞) × ℝ × ℝ × (0,∞)

Inverse of [`Θ!`](@ref): θ-space (unconstrained ℝ⁵) back to ξ-space, the
physical fit parameters `forward`/the priors are defined over.

# Arguments
- `θ::MVector{5,<:Real}` = `(a, b, δρ2, δρ3, c)`: unconstrained ℝ⁵.
    Overwritten in place with `ξ` = `(dns, δρ1, δρ2, δρ3, c1)`.

# Returns
- `nothing`

"""
function Ξ!(θ::MVector{5,<:Real})
    θ[1] = exp(θ[1])
    θ[2] = exp(θ[2])
    θ[5] = exp(θ[5])
    return nothing
end