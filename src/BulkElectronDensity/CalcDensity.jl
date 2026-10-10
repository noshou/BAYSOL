# SPDX-License-Identifier: LGPL-2.1-or-later

# The calculation: the electron density of water at the sample
# temperature, and the bulk electron density of the buffer with its
# propagated uncertainty (`ρₑ`, the module's one public function).

# ---------------------------------------------------------------------------
#   Water
# ---------------------------------------------------------------------------

"""
Mass density of pure water at temperature t (°C) and 1 atm, kg·m⁻³, from the Kell
equation (1975), valid 0–150 °C.
"""
_kell_density(t::Real)::Float64 =
    (
        KELL_DENSITY_NUM[1] + KELL_DENSITY_NUM[2]*t + KELL_DENSITY_NUM[3]*t^2
        + KELL_DENSITY_NUM[4]*t^3 + KELL_DENSITY_NUM[5]*t^4
        + KELL_DENSITY_NUM[6]*t^5
    ) / (1 + KELL_DENSITY_DEN*t)

"""
Electron density of pure water at temperature t (°C) and 1 atm, in e·Å⁻³.

Uses the Kell equation (1975) for mass density, valid 0–150 °C at 1 atm,
returns (ρₑ, uncertainty)
"""
function _ρₑ_w(t::Real)::Tuple{Float64,Float64}

    # temperature must be between 0 and 150
    if (t < 0 || t > 150)
        throw(DomainError(t, "temperature must be between 0°C and 150 °C"))
    end

    # look up in cache if memoized
    key = round(Int64, t * 1000)
    return @closure get!(_ρₑ_w_cache, key) do
        # density of water at 1 atm (Kell equation), kg·m⁻³
        ρ = _kell_density(t)

        # molar mass / density; ρ is kg·m⁻³ and the molar mass is g·mol⁻¹, so v is
        # in 10⁻³ m³·mol⁻¹ = L·mol⁻¹
        v = WATER_MOLAR_MASS / ρ

        # calculate electron density, e·Å⁻³
        ρ_e = (AVOGADRO * WATER_ELECTRONS) / (ANGSTROM3_PER_LITER * v)

        # relative uncertainty = WATER_DENSITY_UNCERTAINTY / ρ(t)   ≈ 2×10⁻⁵ (≈20 ppm)
        # absolute uncertainty on ρₑ_w(t) = ρₑ_w(t) × (WATER_DENSITY_UNCERTAINTY / ρ(t))
        (ρ_e, ρ_e * WATER_DENSITY_UNCERTAINTY / ρ)
    end
end

# ---------------------------------------------------------------------------
#   The bulk electron density of the buffer
# ---------------------------------------------------------------------------

""" `(Z, ϕ°, σ_ϕ°)` of a non-biological solute. """
function _ρₑ_i(s::NonBiological, ::Real, ::Real)::Tuple{Float64,Float64,Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = ϕ°(s.arg)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of a protein sequence. """
function _ρₑ_i(p::Protein, pH::Real, σ_pH::Real)::Tuple{Float64,Float64,Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = ϕ°(pH, p.arg; σ_pH)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of a DNA sequence. """
function _ρₑ_i(d::DNA, pH::Real, σ_pH::Real)::Tuple{Float64,Float64,Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = ϕ°(true, pH, d.arg; σ_pH)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of an RNA sequence. """
function _ρₑ_i(r::RNA, pH::Real, σ_pH::Real)::Tuple{Float64,Float64,Float64}
    Z_j, ϕ°_j, σ_ϕ°_j = ϕ°(false, pH, r.arg; σ_pH)
    return (Float64(Z_j), ϕ°_j, σ_ϕ°_j)
end


"""
Bulk electron density of the buffer at temperature t (°C), in e·Å⁻³.

The model is linear in solute concentration:

    ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)

with `ϕ°_j` the partial molar volume of solute j at infinite dilution in
cm³·mol⁻¹. Water's density `ρ_w(T)` is evaluated at t exactly. The `ϕ°_j` tables
are 25 °C values (`PMV_REFERENCE_TEMPERATURE_C`); away from 25 °C their
temperature drift is not modelled but folded into the uncertainty as

    σ_ϕ°_j,T = PMV_FRACTIONAL_EXPANSIBILITY · ϕ°_j · |t − 25|

added in quadrature to the tabulated `σ_ϕ°_j`. Uncertainty is propagated to first
order assuming independence:

    σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w²
        + Σ_j k_j² · σ_C_j²
        + Σ_j (C_j·ρ_w/1e3)² · (σ_ϕ°_j² + σ_ϕ°_j,T²)

where `k_j` = `N_A`·`Z_j/1e27` − `ρ_w`·`ϕ°_j/1e3`.

# Arguments
- `pH::Real`: pH of the solution; forwarded to ϕ° for Protein/DNA/RNA solutes.
- `σ_pH::Real`: standard uncertainty on pH, propagated through each titration term.
- `solutes::Vector{Solute}`: the buffer's components, **excluding the measured
    macromolecule** (see [`Solute`](@ref)). Empty means pure water.

# Keywords
- `t::Real=DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to `_ρₑ_w`.

# Returns
- `Tuple{Float64, Float64}`: (ρₑ, σρₑ), the bulk electron density and its
    propagated standard uncertainty, both in e·Å⁻³.

# Exceptions
- `DomainError`: thrown if any solute's `molarity_uncertainty` < 0 or
    molarity ≤ 0.
- `ArgumentError`: thrown if a solute's sequence/name is empty.
"""
function ρₑ(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
)::Tuple{Float64,Float64}

    ρₑ_w, σ_w = _ρₑ_w(t)
    ρw_k = ρₑ_w / CM3_PER_LITER   # ρ_w per cm³·mol⁻¹ of ϕ° at 1 mol·L⁻¹
    ΔT = abs(t - PMV_REFERENCE_TEMPERATURE_C)

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
        C_j = s.molarity
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
