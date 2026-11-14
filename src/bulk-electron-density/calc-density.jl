# SPDX-License-Identifier: LGPL-3.0-or-later

# The electron density of water at the sample
# temperature, and the bulk electron density of the buffer with its
# propagated uncertainty (`ρₑ`, the module's one public function).

# ---------------------------------------------------------------------------
#   Water
# ---------------------------------------------------------------------------

"""
Mass density of pure water at temperature t (°C) and 1 atm, kg·m⁻³, from the Kell
equation (1975), valid 0–150 °C.
"""
_kellDensity(t::Real)::Float64 =
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
        throw(DomainError(t, "temperature must be between 0 and 150 °C"))
    end

    # look up in cache if memoized
    key = round(Int64, t * 1000)
    return @closure get!(_ρₑ_w_cache, key) do
        # density of water at 1 atm (Kell equation), kg·m⁻³
        ρ = _kellDensity(t)

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
function _ρₑ_i(
    s::NonBiological,
    ::Real,
    ::Real,
    fallback_σ::Real,
)::Tuple{Float64,Float64,Float64}
    zJ, ϕ°_j, σ_ϕ°_j = ϕ°(s.arg; fallback_σ)
    return (Float64(zJ), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of a polymer, detergent or oligomer (at this pH for peptides). """
function _ρₑ_i(
    p::Polymer,
    pH::Real,
    σ_pH::Real,
    ::Real,
)::Tuple{Float64,Float64,Float64}
    zJ, ϕ°_j, σ_ϕ°_j = _polymer_ϕ°(p.arg, pH, σ_pH)
    return (Float64(zJ), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of a protein sequence. """
function _ρₑ_i(
    p::Protein,
    pH::Real,
    σ_pH::Real,
    ::Real,
)::Tuple{Float64,Float64,Float64}
    zJ, ϕ°_j, σ_ϕ°_j = ϕ°(pH, p.arg; σ_pH)
    return (Float64(zJ), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of a DNA sequence. """
function _ρₑ_i(
    d::DNA,
    pH::Real,
    σ_pH::Real,
    ::Real,
)::Tuple{Float64,Float64,Float64}
    zJ, ϕ°_j, σ_ϕ°_j = ϕ°(true, pH, d.arg; σ_pH)
    return (Float64(zJ), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of an RNA sequence. """
function _ρₑ_i(
    r::RNA,
    pH::Real,
    σ_pH::Real,
    ::Real,
)::Tuple{Float64,Float64,Float64}
    zJ, ϕ°_j, σ_ϕ°_j = ϕ°(false, pH, r.arg; σ_pH)
    return (Float64(zJ), ϕ°_j, σ_ϕ°_j)
end

""" `(Z, ϕ°, σ_ϕ°)` of a custom non-biological solute; no `σ_ϕ°` gets the fallback. """
function _ρₑ_i(
    s::CustomNonBio,
    ::Real,
    ::Real,
    fallback_σ::Real,
)::Tuple{Float64,Float64,Float64}
    return (Float64(s.Z), s.ϕ°, s.σ_ϕ° === nothing ? Float64(fallback_σ) : s.σ_ϕ°)
end

"""
`(Z, ϕ°, σ_ϕ°)` of a custom polymer (the model of the built-in chain families, see
[`CustomPolymer`](@ref)).

# Exceptions
`ArgumentError` when the chain has fewer than 2 units in all.
"""
function _ρₑ_i(
    s::CustomPolymer,
    ::Real,
    ::Real,
    ::Real,
)::Tuple{Float64,Float64,Float64}
    total = sum(s.n)
    total >= 2 || throw(
        ArgumentError(
            "$(s.arg) with $total units: too short, use CustomNonBio for a single solute",
        ),
    )
    ϕ°_j = s.v0 + sum(s.slope .* s.n)
    zJ = round(Int64, s.zEnds + sum(s.zUnit .* s.n))
    # a chain whose uncertainties are all unstated gets the polymer-grade rule
    if s.σ_ends === nothing && all(isnothing, s.σ_unit)
        σ = POLYMER_UNKNOWN_REL_UNC * abs(ϕ°_j)
    else
        terms = [
            u === nothing ? POLYMER_UNKNOWN_REL_UNC * abs(m * k) : u * k for
            (u, m, k) in zip(s.σ_unit, s.slope, s.n)
        ]
        σ = sqrt(sum(abs2, terms) + (s.σ_ends === nothing ? 0.0 : s.σ_ends)^2)
    end
    return (Float64(zJ), ϕ°_j, σ)
end

"""
Check the numbers of a custom solute (nothing to check for the other types).

# Returns
- `nothing`.

# Exceptions
- `DomainError`: `Z`/`zUnit` not above 0, `ϕ°`, `v0` or `slope` not finite, `n` not
    finite or below 0, `zEnds` below 0, or a given `σ_ϕ°`/`σ_unit`/`σ_ends` not finite and
    at least 0.
- `ArgumentError`: a `CustomPolymer` with no kind of unit, more than
    `CUSTOM_POLYMER_MAX_UNITS` or vectors of different lengths.
"""
_checkCustom(::Solute) = nothing

function _checkCustom(s::CustomNonBio)
    s.Z > 0 || throw(DomainError(s.Z, "a custom solute's electron count must be above 0"))
    isfinite(s.ϕ°) || throw(DomainError(s.ϕ°, "a custom solute's ϕ° must be finite"))
    _check_σ(s.σ_ϕ°, "σ_ϕ°")
end

function _checkCustom(s::CustomPolymer)
    k = length(s.n)
    (1 <= k <= CUSTOM_POLYMER_MAX_UNITS) || throw(
        ArgumentError(
            "a custom polymer has 1 to $CUSTOM_POLYMER_MAX_UNITS kinds of unit, got $k",
        ),
    )
    (length(s.zUnit) == k && length(s.slope) == k && length(s.σ_unit) == k) || throw(
        ArgumentError(
            "a custom polymer's n, Z_unit, slope and σ_unit must be the same length",
        ),
    )
    for (i, Z) in enumerate(s.zUnit)
        Z > 0 || throw(DomainError(Z, "a custom polymer's Z_unit[$i] must be above 0"))
    end
    for (i, v) in enumerate(s.n)
        (isfinite(v) && v >= 0) ||
            throw(DomainError(v, "a custom polymer's n[$i] must be finite and at least 0"))
    end
    for (v, nm) in ((s.v0, "v0"),)
        isfinite(v) || throw(DomainError(v, "a custom polymer's $nm must be finite"))
    end
    for (i, v) in enumerate(s.slope)
        isfinite(v) || throw(DomainError(v, "a custom polymer's slope[$i] must be finite"))
    end
    s.zEnds >= 0 ||
        throw(DomainError(s.zEnds, "a custom polymer's Z_ends must be at least 0"))
    for (i, u) in enumerate(s.σ_unit)
        _check_σ(u, "σ_unit[$i]")
    end
    _check_σ(s.σ_ends, "σ_ends")
end

_check_σ(::Nothing, ::String) = nothing
function _check_σ(σ::Float64, name::String)
    isfinite(σ) && σ >= 0 ||
        throw(DomainError(σ, "a custom solute's $name must be finite and at least 0"))
    return nothing
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

where `kJ` = `N_A`·`Z_j/1e27` − `ρ_w`·`ϕ°_j/1e3`.

# Arguments
- `pH::Real`: pH of the solution; forwarded to ϕ° for Protein/DNA/RNA solutes.
- `σ_pH::Real`: standard uncertainty on pH, propagated through each titration term.
- `solutes::Vector{Solute}`: the buffer's components (`Protein`, `NonBiological`,
    `Polymer`, `DNA`, `RNA`, `CustomNonBio`, `CustomPolymer`), **excluding the measured
    macromolecule** (see [`Solute`](@ref)). Empty means pure water.

# Keywords
- `t::Real=DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to `_ρₑ_w`.
- `pmvFallbackUncert::Real=NONBIO_MEAN_UNCERTAINTY`: the uncertainty, cm³·mol⁻¹, of a
    non-biological solute (a table row or a `CustomNonBio`) that states none.
    Must be finite and above 0.

# Returns
- `Tuple{Float64, Float64}`: (ρₑ, σρₑ), the bulk electron density and its
    propagated standard uncertainty, both in e·Å⁻³.

# Exceptions
- `DomainError`: thrown if any solute's `molarityUncertainty` < 0 or
    molarity ≤ 0, if `pmvFallbackUncert` is not finite and above 0, or if a
    `CustomNonBio`/`CustomPolymer` has a number outside its range (see its docstring).
- `ArgumentError`: thrown if a solute's sequence/name is empty, or a `CustomPolymer` has
    fewer than 2 units in all or an unusable list of unit kinds.
"""
function ρₑ(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
    pmvFallbackUncert::Real = NONBIO_MEAN_UNCERTAINTY,
)::Tuple{Float64,Float64}

    isfinite(pmvFallbackUncert) && pmvFallbackUncert > 0 || throw(
        DomainError(
            pmvFallbackUncert,
            "the fallback PMV uncertainty must be finite and above 0",
        ),
    )

    ρₑ_w, σ_w = _ρₑ_w(t)
    ρw_k = ρₑ_w / CM3_PER_LITER   # ρ_w per cm³·mol⁻¹ of ϕ° at 1 mol·L⁻¹
    ΔT = abs(t - PMV_REFERENCE_TEMPERATURE_C)

    # Accumulators.
    # disp and Δμ are linear sums; the variance sums are per-solute
    # because k_j² cannot be factored out of the sum.
    disp    = 0.0   # Σ C_j·ϕ°_j / 1e3   → water displacement fraction
    Δμ      = 0.0   # Σ C_j·kJ          → mean shift from pure water
    varConc = 0.0   # Σ k_j²·σ_C_j²
    varVol  = 0.0   # Σ (C_j·ρ_w/1e3)²·(σ_ϕ°_j² + σ_ϕ°_j,T²)

    for s in solutes
        if s.molarityUncertainty < 0
            throw(
                DomainError(
                    s.molarityUncertainty,
                    "a solute's molarity uncertainty must not be negative",
                ),
            )
        elseif s.molarity ≤ 0
            throw(DomainError(s.molarity, "a solute's molarity must be above 0"))
        elseif s.arg == ""
            throw(ArgumentError("a solute's name or sequence cannot be empty"))
        end

        _checkCustom(s)
        zJ, ϕ°_j, σ_ϕ°_j = _ρₑ_i(s, pH, σ_pH, pmvFallbackUncert)
        cJ = s.molarity
        σ_C_j = s.molarityUncertainty
        σ_T_j = PMV_FRACTIONAL_EXPANSIBILITY * abs(ϕ°_j) * ΔT

        kJ = AVOGADRO * zJ / ANGSTROM3_PER_LITER - ρw_k * ϕ°_j

        disp    += cJ * ϕ°_j / CM3_PER_LITER
        Δμ      += cJ * kJ
        varConc += kJ^2 * σ_C_j^2
        varVol  += (cJ * ρw_k)^2 * (σ_ϕ°_j^2 + σ_T_j^2)
    end

    varWater = (1.0 - disp)^2 * σ_w^2
    μ_total = ρₑ_w + Δμ
    σ_total = sqrt(varWater + varConc + varVol)

    return (μ_total, σ_total)
end
