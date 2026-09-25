# SPDX-License-Identifier: LGPL-2.1-or-later

using ..BAYSOL_Utils.Constants: AVOGADRO
using ..PartialMolarVolumes: PartialMolarVolumes
using Distributions

"Solutes part of the buffer solution."
abstract type Solute end

"A protein in the buffer solution."
struct Protein <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"Non-biological molecules in the buffer solution."
struct NonBiological <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"DNA nucleotide in the buffer solution."
struct DNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

"RNA nucleotide in the buffer solution."
struct RNA <: Solute
    molarity::Float64
    molarity_uncertainty::Float64
    arg::String
end

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
    _ρₑ(pH::Real, σ_pH::Real, solutes::Vector{Solute}; t::Real=25.0)
        -> Tuple{Float64, Float64}

Bulk electron density of a solution at temperature t (°C), in e·Å⁻³.

The model is linear in solute concentration:

    ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)

with ϕ°j being the partial molar volume of solute j at infinite dilution
in cm³·mol⁻¹. Uncertainty is propagated to first order assuming independence:

    σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w²
        + Σ_j k_j² · σ_C_j²
        + Σ_j (C_j·ρ_w/1e3)² · σ_ϕ°_j²

where kj = NA·Zj/1e27 − ρw·ϕ°j/1e3.

# Arguments
- `pH::Real`: pH of the solution; forwarded to PartialMolarVolumes.ϕ° for Protein solutes.
- `σpH::Real`: standard uncertainty on pH, propagated through each Protein
    solute's titration term.
- `solutes::Vector{Solute}`: the  species in solution.

# Keywords
- `t::Real=25.0`: solution temperature in °C, forwarded to PartialMolarVolumes.ρₑw.
    **!!NOTE!!: as of this version, this should NOT be changed, since only water is temp dependent.**

# Returns
- `Tuple{Float64, Float64}`: (ρₑ, σρₑ), the bulk electron density and its
    propagated standard uncertainty, both in e·Å⁻³.

# Exceptions
- `DomainError`: thrown if any solute's molarityuncertainty < 0 or
    molarity ≤ 0.
- `ArgumentError`: thrown if a Protein's seq or a NonBiological's name is empty.
"""
function _ρₑ(
    pH::Real, 
    σ_pH::Real, 
    solutes::Vector{Solute}; 
    t::Real=25.0
)::Tuple{Float64, Float64}

    ρₑ_w, σ_w = PartialMolarVolumes.ρₑ_w(t)
    ρw_k = ρₑ_w * 1e-3   # ρ_w in units of e·Å⁻³ per cm³·mol⁻¹

    # Accumulators.
    # disp and Δμ are linear sums; the variance sums are per-solute
    # because k_j² cannot be factored out of the sum.
    disp     = 0.0   # Σ C_j·ϕ°_j / 1e3   → water displacement fraction
    Δμ       = 0.0   # Σ C_j·k_j          → mean shift from pure water
    var_conc = 0.0   # Σ k_j²·σ_C_j²
    var_vol  = 0.0   # Σ (C_j·ρ_w/1e3)²·σ_ϕ°_j²

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

        k_j = AVOGADRO * Z_j / 1e27 - ρw_k * ϕ°_j

        disp     += C_j * ϕ°_j / 1e3
        Δμ       += C_j * k_j
        var_conc += k_j^2 * σ_C_j^2
        var_vol  += (C_j * ρw_k)^2 * σ_ϕ°_j^2
    end

    var_water = (1.0 - disp)^2 * σ_w^2
    μ_total   = ρₑ_w + Δμ
    σ_total   = sqrt(var_water + var_conc + var_vol)

    return (μ_total, σ_total)
end

"""
    prior(pH::Real, σ_pH::Real, solutes::Vector{Solute}; t::Real=25.0)
        -> LogNormal{Float64}

Prior distribution for the bulk electron density ρₑ, as a LogNormal moment-matched
to the mean and standard deviation returned by ρₑ. 

Bulk electron density at temperature t (°C), in e·Å⁻³, is linear in solute concentration:

    ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)

with ϕ°j being the partial molar volume of solute j at infinite dilution
in cm³·mol⁻¹. Uncertainty is propagated to first order assuming independence:

    σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w²
        + Σ_j k_j² · σ_C_j²
        + Σ_j (C_j·ρ_w/1e3)² · σ_ϕ°_j²

where kj = NA·Zj/1e27 − ρw·ϕ°j/1e3.

Given μ = ρₑ, σ = √σ², the LogNormal(μln, σln) parameters are:

    σ_ln = √(ln(1 + σ²/μ²))
    μ_ln = ln(μ) − σ_ln²/2

# Arguments
- `pH::Real`: pH of the solution; forwarded to ρₑ.
- `σpH::Real`: standard uncertainty on pH; must be ≥ 0.
- `solutes::Vector{Solute}`: the Protein/NonBiological species in solution; must be non-empty.

# Keywords
- `t::Real=25.0`: solution temperature in °C, forwarded to ρₑ.
    **!!NOTE!!: as of this version, this should NOT be changed, since only water is temp dependent.**

# Returns
- `LogNormal{Float64}`: prior distribution over ρₑ .

# Exceptions
- `ArgumentError`: thrown if solutes is empty.
- `DomainError`: thrown if σpH < 0.
"""
function ρₑ_prior(
    pH::Real, 
    σ_pH::Real, 
    solutes::Vector{Solute}; 
    t::Real=25.0
)::LogNormal{Float64}

    if (length(solutes) == 0)
        throw(ArgumentError("solutes cannot be empty"))
    elseif (σ_pH < 0)
        throw(DomainError(σ_pH, "σ_pH must be ≥ 0"))
    end

    μ, σ = _ρₑ(pH, σ_pH, solutes; t=t)

    σ_ln = sqrt(log(1 + (σ / μ)^2))
    μ_ln = log(μ) - σ_ln^2 / 2

    return LogNormal(μ_ln, σ_ln)
end
