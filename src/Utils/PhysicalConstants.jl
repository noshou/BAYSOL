# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Physical constants and units shared across the package, defined once so they cannot
drift between modules. Loaded first; every other module imports what it needs from
here (`using ..PhysicalConstants: AVOGADRO`).
"""
module PhysicalConstants

export  AVOGADRO, PLANCK_CONSTANT, SPEED_OF_LIGHT, ELEMENTARY_CHARGE, ANGSTROM_PER_METER,
        HC_EV_ANGSTROM, WATER_MOLAR_MASS, WATER_DENSITY_UNCERTAINTY, KELL_DENSITY_NUM,
        KELL_DENSITY_DEN, WATER_ELECTRONS, ANGSTROM3_PER_LITER, CM3_PER_LITER,
        PM_PER_ANGSTROM, NM_INV_PER_ANGSTROM_INV, UNIT_OF_δρ, NS_PER_S, MS_PER_S,
        STANDARD_TEMPERATURE_C, BACKBONE_ELECTRONS

"Avogadro constant, mol⁻¹ (CODATA, exact since the 2019 SI redefinition)."
const AVOGADRO = 6.02214076e23

"Planck constant h, J·s (exact since the 2019 SI redefinition)."
const PLANCK_CONSTANT = 6.62607015e-34

"Speed of light in vacuum c, m·s⁻¹ (exact)."
const SPEED_OF_LIGHT = 299_792_458

"Elementary charge e, C (exact since the 2019 SI redefinition)."
const ELEMENTARY_CHARGE = 1.602176634e-19

"Å per metre."
const ANGSTROM_PER_METER = 1e10

"""
h·c in eV·Å, from the exact SI values of h, c and e: ≈ 12398.41984. Photon energy
from wavelength: E (eV) = `HC_EV_ANGSTROM` / λ (Å).
"""
const HC_EV_ANGSTROM =
    PLANCK_CONSTANT * SPEED_OF_LIGHT / ELEMENTARY_CHARGE * ANGSTROM_PER_METER

"Molar mass of H₂O, g·mol⁻¹ (IAPWS-95 value)."
const WATER_MOLAR_MASS = 18.015268

"Absolute uncertainty on the Kell water density, kg·m⁻³
(≈ 20 ppm of ρ, nearly constant 0-150 °C)."
const WATER_DENSITY_UNCERTAINTY = 0.02

"""
Numerator coefficients (a₀, …, a₅) of the Kell equation (1975) for the mass density of
pure water at 1 atm, kg·m⁻³, valid 0–150 °C:

    ρ(t) = (a₀ + a₁t + a₂t² + a₃t³ + a₄t⁴ + a₅t⁵) / (1 + b·t), t in °C

with b = [`KELL_DENSITY_DEN`](@ref).
"""
const KELL_DENSITY_NUM = (
    999.83952,
    16.945176,
    -7.9870401e-3,
    -46.170461e-6,
    105.56302e-9,
    -280.54253e-12
)

"Denominator coefficient b of the Kell equation
(see [`KELL_DENSITY_NUM`](@ref)), °C⁻¹."
const KELL_DENSITY_DEN = 16.879850e-3

"Electrons per H₂O molecule (2 from H, 8 from O)."
const WATER_ELECTRONS = 10

"""
Peptide backbone unit (-CH2CONH-, neutral, C2H3NO) electron count:
2×C(6) + 3×H(1) + N(7) + O(8) = 30 e. Added once per residue on the
same basis as [`BACKBONE_PMV`](@ref BAYSOL.PartialMolarVolumes.BACKBONE_PMV);
Protein.json's `electron_count` field is a side-chain-only increment
relative to glycine.
"""
const BACKBONE_ELECTRONS = 30

"Å³ per litre: 1 L = 10⁻³ m³ = 10²⁷ Å³."
const ANGSTROM3_PER_LITER = 1e27

"cm³ per litre."
const CM3_PER_LITER = 1e3

"pm per Å (the bundled ionic-radius table is in pm)."
const PM_PER_ANGSTROM = 100.0

"""
nm⁻¹ per Å⁻¹ (1 Å⁻¹ = 10 nm⁻¹). A curve deposited in nm⁻¹ is
converted with `q ./ NM_INV_PER_ANGSTROM_INV`.
(An integer, so the division is bit-identical to `q ./ 10`.)
"""
const NM_INV_PER_ANGSTROM_INV = 10

"Shell-contrast unit in e·Å⁻³ (CRYSOL's --dro);
`ρ_k` = `UNIT_OF_δρ` * `δρ_k`."
const UNIT_OF_δρ = 0.03

"Nanoseconds per second: converts `time_ns()`
and Base's `*_time_ns()` counters to seconds."
const NS_PER_S = 1e9

"Milliseconds per second."
const MS_PER_S = 1e3

"""
Standard reference temperature, °C: 298.15 K,
the temperature standard-state data (e.g. the
bundled partial-molar-volume tables) are at.
"""
const STANDARD_TEMPERATURE_C = 25.0

end # module
