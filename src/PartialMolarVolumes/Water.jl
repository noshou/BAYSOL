# SPDX-License-Identifier: LGPL-2.1-or-later

#----------------------------------------------------------
#               Water Bulk Electron Density
#----------------------------------------------------------

"Memoized water electron bulk density"
const _ρₑ_w_cache = KeyedCache{Int64, Tuple{Float64, Float64}}()

"""
Mass density of pure water at temperature t (°C) and 1 atm, kg·m⁻³, from the Kell
equation (1975), valid 0–150 °C.
"""
_kell_density(t::Real)::Float64 =
    (   KELL_DENSITY_NUM[1] + KELL_DENSITY_NUM[2]*t + KELL_DENSITY_NUM[3]*t^2
        + KELL_DENSITY_NUM[4]*t^3 + KELL_DENSITY_NUM[5]*t^4
        + KELL_DENSITY_NUM[6]*t^5
    ) / (1 + KELL_DENSITY_DEN*t)

"""
Electron density of pure water at temperature t (°C) and 1 atm, in e·Å⁻³.

Uses the Kell equation (1975) for mass density, valid 0–150 °C at 1 atm,
returns (ρₑ, uncertainty)
"""
function ρₑ_w(t::Real)::Tuple{Float64, Float64}

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
        ρₑ_w = (AVOGADRO * WATER_ELECTRONS) / (ANGSTROM3_PER_LITER * v)

        # relative uncertainty = WATER_DENSITY_UNCERTAINTY / ρ(t)   ≈ 2×10⁻⁵ (≈20 ppm)
        # absolute uncertainty on ρₑ_w(t) = ρₑ_w(t) × (WATER_DENSITY_UNCERTAINTY / ρ(t))
        (ρₑ_w, ρₑ_w * WATER_DENSITY_UNCERTAINTY / ρ)
    end
end