# SPDX-License-Identifier: LGPL-2.1-or-later

using ..BAYSOL_Utils.Constants: AVOGADRO, ANGSTROM3_PER_LITER, CM3_PER_LITER, DEFAULT_TEMPERATURE_C, PMV_REFERENCE_TEMPERATURE_C, PMV_FRACTIONAL_EXPANSIBILITY
using ..PartialMolarVolumes: PartialMolarVolumes
using Distributions


""" Estimated bulk electron density for a non-biological solute. """
function _ρₑ_i(s::NonBiological, ::Real, ::Real)::Tuple{Float64, Float64, Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = PartialMolarVolumes.ϕ°(s.arg)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end

""" Estimated bulk electron density for a protein sequence. """
function _ρₑ_i(p::Protein, pH::Real, σ_pH::Real)::Tuple{Float64, Float64, Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = PartialMolarVolumes.ϕ°(pH, p.arg; σ_pH)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end

""" Estimated bulk electron density for a DNA sequence. """
function _ρₑ_i(d::DNA, pH::Real, σ_pH::Real)::Tuple{Float64, Float64, Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = PartialMolarVolumes.ϕ°(true, pH, d.arg; σ_pH)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end

""" Estimated bulk electron density for an RNA sequence. """
function _ρₑ_i(r::RNA, pH::Real, σ_pH::Real)::Tuple{Float64, Float64, Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = PartialMolarVolumes.ϕ°(false, pH, r.arg; σ_pH)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end


"""
$(TYPEDSIGNATURES)

Bulk electron density of the buffer at temperature t (°C), in e·Å⁻³.

The model is linear in solute concentration:

    ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)

with ϕ°_j the partial molar volume of solute j at infinite dilution in
cm³·mol⁻¹. Water's density ρ_w(T) is evaluated at t exactly. The ϕ°_j tables
are 25 °C values (PMV_REFERENCE_TEMPERATURE_C); away from 25 °C their
temperature drift is not modelled but folded into the uncertainty as

    σ_ϕ°_j,T = PMV_FRACTIONAL_EXPANSIBILITY · ϕ°_j · |t − 25|

added in quadrature to the tabulated σ_ϕ°_j. Uncertainty is propagated to first
order assuming independence:

    σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w²
        + Σ_j k_j² · σ_C_j²
        + Σ_j (C_j·ρ_w/1e3)² · (σ_ϕ°_j² + σ_ϕ°_j,T²)

where k_j = N_A·Z_j/1e27 − ρ_w·ϕ°_j/1e3.

# Arguments
- `pH::Real`: pH of the solution; forwarded to PartialMolarVolumes.ϕ° for Protein/DNA/RNA solutes.
- `σ_pH::Real`: standard uncertainty on pH, propagated through each titration term.
- `solutes::Vector{Solute}`: the buffer's components, **excluding the measured
    macromolecule** (see [`Solute`](@ref)). Empty means pure water.

# Keywords
- `t::Real=DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to PartialMolarVolumes.ρₑ_w.

# Returns
- `Tuple{Float64, Float64}`: (ρₑ, σρₑ), the bulk electron density and its
    propagated standard uncertainty, both in e·Å⁻³.

# Exceptions
- `DomainError`: thrown if any solute's molarity_uncertainty < 0 or
    molarity ≤ 0.
- `ArgumentError`: thrown if a solute's sequence/name is empty.
"""
function _ρₑ(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real=DEFAULT_TEMPERATURE_C
)::Tuple{Float64, Float64}

    ρₑ_w, σ_w = PartialMolarVolumes.ρₑ_w(t)
    ρw_k = ρₑ_w / CM3_PER_LITER   # ρ_w per cm³·mol⁻¹ of ϕ° at 1 mol·L⁻¹
    ΔT   = abs(t - PMV_REFERENCE_TEMPERATURE_C)

    # Accumulators.
    # disp and Δμ are linear sums; the variance sums are per-solute
    # because k_j² cannot be factored out of the sum.
    disp     = 0.0   # Σ C_j·ϕ°_j / 1e3   → water displacement fraction
    Δμ       = 0.0   # Σ C_j·k_j          → mean shift from pure water
    var_conc = 0.0   # Σ k_j²·σ_C_j²
    var_vol  = 0.0   # Σ (C_j·ρ_w/1e3)²·(σ_ϕ°_j² + σ_ϕ°_j,T²)

    for s in solutes
        if s.molarity_uncertainty < 0
            throw(DomainError(s.molarity_uncertainty, "Uncertainty must be ≥ 0"))
        elseif s.molarity ≤ 0
            throw(DomainError(s.molarity, "Molarity must be > 0"))
        elseif s.arg == ""
            throw(ArgumentError("Name or sequence cannot be empty"))
        end

        Z_j, ϕ°_j, σ_ϕ°_j = _ρₑ_i(s, pH, σ_pH)
        C_j   = s.molarity
        σ_C_j = s.molarity_uncertainty
        σ_T_j = PMV_FRACTIONAL_EXPANSIBILITY * abs(ϕ°_j) * ΔT

        k_j = AVOGADRO * Z_j / ANGSTROM3_PER_LITER - ρw_k * ϕ°_j

        disp     += C_j * ϕ°_j / CM3_PER_LITER
        Δμ       += C_j * k_j
        var_conc += k_j^2 * σ_C_j^2
        var_vol  += (C_j * ρw_k)^2 * (σ_ϕ°_j^2 + σ_T_j^2)
    end

    var_water = (1.0 - disp)^2 * σ_w^2
    μ_total   = ρₑ_w + Δμ
    σ_total   = sqrt(var_water + var_conc + var_vol)

    return (μ_total, σ_total)
end

"""
$(TYPEDSIGNATURES)

Prior distribution for the bulk electron density ρₑ, as a LogNormal moment-matched
to the mean and standard deviation returned by [`_ρₑ`](@ref) (see it for the
model, including how temperatures away from 25 °C are handled).

Given μ = ρₑ, σ = √σ², the LogNormal(μln, σln) parameters are:

    σ_ln = √(ln(1 + σ²/μ²))
    μ_ln = ln(μ) − σ_ln²/2

# Arguments
- `pH::Real`: pH of the solution; forwarded to _ρₑ.
- `σ_pH::Real`: standard uncertainty on pH; must be ≥ 0.
- `solutes::Vector{Solute}`: the buffer's components, **excluding the measured
    macromolecule** (see [`Solute`](@ref)). Empty means pure water.

# Keywords
- `t::Real=DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to _ρₑ.

# Returns
- `LogNormal{Float64}`: prior distribution over ρₑ.

# Exceptions
- `DomainError`: thrown if σ_pH < 0.
"""
function ρₑ_prior(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real=DEFAULT_TEMPERATURE_C
)::LogNormal{Float64}

    σ_pH < 0 && throw(DomainError(σ_pH, "σ_pH must be ≥ 0"))

    μ, σ = _ρₑ(pH, σ_pH, solutes; t=t)

    σ_ln = sqrt(log(1 + (σ / μ)^2))
    μ_ln = log(μ) - σ_ln^2 / 2

    return LogNormal(μ_ln, σ_ln)
end
