# PhysicalConstants

Physical constants and units shared across the package, defined once (`PhysicalConstants.jl`)
so they cannot drift between modules. It is the first module loaded; every other module
imports what it needs by name:

```julia
# src/PartialMolarVolumes/PMV.jl
using ..PhysicalConstants: AVOGADRO, WATER_MOLAR_MASS
```

or, from outside the package, `using BAYSOL.PhysicalConstants: AVOGADRO`.

| constant | value | used by |
|---|---|---|
| `AVOGADRO` | 6.02214076 × 10²³ mol⁻¹ (exact, 2019 SI) | PartialMolarVolumes, Fitting |
| `PLANCK_CONSTANT`, `SPEED_OF_LIGHT`, `ELEMENTARY_CHARGE` | exact 2019 SI values of h, c, e | `HC_EV_ANGSTROM` |
| `HC_EV_ANGSTROM` | h·c ≈ 12398.42 eV·Å; E (eV) = `HC_EV_ANGSTROM` / λ (Å) | fitting scripts |
| `WATER_MOLAR_MASS` | 18.015268 g·mol⁻¹ (IAPWS-95) | PartialMolarVolumes |
| `WATER_ELECTRONS` | 10 | PartialMolarVolumes |
| `WATER_DENSITY_UNCERTAINTY` | 0.02 kg·m⁻³, absolute uncertainty on the Kell water density | PartialMolarVolumes |
| `KELL_DENSITY_NUM`, `KELL_DENSITY_DEN` | Kell (1975) coefficients: `ρ_w(t)` = Σ aₖtᵏ / (1 + b·t), kg·m⁻³, 0–150 °C | PartialMolarVolumes |
| `ANGSTROM3_PER_LITER`, `CM3_PER_LITER`, `ANGSTROM_PER_METER`, `PM_PER_ANGSTROM` | 10²⁷, 10³, 10¹⁰, 100 | PartialMolarVolumes, Fitting, AtomicRadii |
| `NM_INV_PER_ANGSTROM_INV` | 10 (an integer, so `q ./ NM_INV_PER_ANGSTROM_INV` is bit-identical to `q ./ 10`) | fitting scripts |
| `DRO_UNIT` | 0.03 e·Å⁻³, CRYSOL's --dro shell-contrast unit | Scattering, Fitting |
| `NS_PER_S`, `MS_PER_S` | 10⁹, 10³ | Timing, Fitting, Report |
| `STANDARD_TEMPERATURE_C` | 25 °C (298.15 K), the standard reference temperature; backs `PMV_REFERENCE_TEMPERATURE_C` and `DEFAULT_TEMPERATURE_C` so they cannot drift apart | PartialMolarVolumes, Fitting |

Every other tunable is a module-level constant in its owning module (see that module's README).
