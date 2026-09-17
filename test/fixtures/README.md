# Form-factor oracle fixtures

Reference values  from xraydb (Python/sqlite3 db)


| file       | rows | contents                                                                                                                                                                  |
| ------------ | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `f0.csv`   | 348  | `ion,s,f0` — 29 species (neutral atoms, cations, anions, the `cval`/`siva` valence states, Z up to 98) across `s = 0 … 6 Å⁻¹`                                        |
| `f1f2.csv` | 852  | `element,energy_eV,f1,f2` — 500 points at 1 eV spacing across the Fe K edge (6900–7400 eV), 160 more at 10 eV to 9000 eV, plus 12 elements H→U over 1.01 eV … 966 keV |

Shared test-geometry helpers (`.jl`, `include`d directly rather than parsed as data) also live here:


| file              | contents                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `geometry.jl`     | `sph(R, n)` — Fibonacci-sphere point set, used by `test_sasa.jl` and `test_hydrophobicity.jl` to build a sealed shell of atoms around an enclosed void                                                                                                                                                                                                                                                                                                   |
| `floatcompare.jl` | `close_(a, b; atol = 1.0e-9)` — tolerance float compare, used by `test_dns.jl`, `test_pmv.jl`, `test_deltarho.jl` and `test_hydrophobicity.jl` wherever `check_float`'s fixed `DEFAULT_ATOL` is too tight                                                                                                                                                                                                                                                |
| `sequences.jl`    | Real, cited protein/DNA/RNA sequences (`LYSOZYME`, `OXYTOCIN`, `INSULIN_A`/`INSULIN_B`, `GFP`, `M13_PRIMER`, `PUC19_FRAGMENT`, `TRNA_PHE`, `RRNA_5S`) shared across `test_dns.jl`/`test_pmv.jl` for exercising `Priors`/`DensityOfSolvent`/`PartialMolarVolumes` on real biological input. Not for cache-busting -- `fresh_seq`/`fresh_seq_dns` (still local to `test_pmv.jl`/`test_dns.jl`, deliberately not unified, see their own comments) cover that |
