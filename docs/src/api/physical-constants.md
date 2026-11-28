# Physical constants

The module `BAYSOL.PhysicalConstants` (`physical-constants.jl` at the root of `src/`, next to `BAYSOL.jl` and `precompile.jl`; bound at the package root, `using BAYSOL.PhysicalConstants: AVOGADRO`). Every physical constant and unit conversion, defined once so it cannot drift between modules; other modules import by name (`using ..PhysicalConstants: AVOGADRO, WATER_MOLAR_MASS`).


| constant                                                                        | value                                                                              | used by                                     |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------- |
| `AVOGADRO`                                                                      | 6.02214076 × 10²³ mol⁻¹ (exact, 2019 SI)                                      | BulkElectronDensity, Inference              |
| `PLANCK_CONSTANT`, `SPEED_OF_LIGHT`, `ELEMENTARY_CHARGE`                        | exact 2019 SI values of h, c, e                                                    | `HC_EV_ANGSTROM`                            |
| `HC_EV_ANGSTROM`                                                                | h·c ≈ 12398.42 eV·Å; <br />`E = HC_EV_ANGSTROM / λ`                          | fitting scripts                             |
| `WATER_MOLAR_MASS`                                                              | 18.015268 g·mol⁻¹ (IAPWS-95)                                                    | BulkElectronDensity                         |
| `WATER_ELECTRONS`                                                               | 10                                                                                 | BulkElectronDensity                         |
| `WATER_DENSITY_UNCERTAINTY`                                                     | 0.02 kg·m⁻³ on the Kell density                                                 | BulkElectronDensity                         |
| `KELL_DENSITY_NUM`, `KELL_DENSITY_DEN`                                          | Kell (1975) coefficients, kg·m⁻³, 0–150 °C                                    | BulkElectronDensity                         |
| `ANGSTROM3_PER_LITER`, `CM3_PER_LITER`, `ANGSTROM_PER_METER`, `PM_PER_ANGSTROM` | 10²⁷, 10³, 10¹⁰, 100                                                          | BulkElectronDensity, Inference, AtomicRadii |
| `NM_INV_PER_ANGSTROM_INV`                                                       | 10 (an integer, so `q ./ NM_INV_PER_ANGSTROM_INV` is bit-identical to `q ./ 10`)   | fitting scripts                             |
| `UNIT_OF_δρ`                                                                  | 0.03 e·Å⁻³, CRYSOL's `--dro` unit                                              | Scattering, Inference                       |
| `NS_PER_S`, `MS_PER_S`                                                          | 10⁹, 10³                                                                         | Timing, Inference, Pipeline                 |
| `STANDARD_TEMPERATURE_C`                                                        | 25 °C (298.15 K); backs `PMV_REFERENCE_TEMPERATURE_C` and `DEFAULT_TEMPERATURE_C` | BulkElectronDensity, Inference              |


```@autodocs
Modules = [BAYSOL.PhysicalConstants]
```
