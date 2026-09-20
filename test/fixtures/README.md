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

## Structure fixtures (`structures/`)

Real, publicly-available PDB entries fetched from RCSB, used by
`test_structuresource.jl` to exercise `StructureSource`'s `LocalPathSource`
branch (both the `.pdb` passthrough and `.cif`/mmCIF conversion) against real
data across a genuine size range, and as the local half of cross-consistency
checks against live `PDBIDSource` fetches. Coordinate data from the PDB
carries no license restriction (unlike the papers in this repo's `sources/`
directory), so these are committed as ordinary version-controlled files, not
gitignored like the runtime `_cache/` scratch dir `StructureSource`/`Propka`
use.

| id     | file             | tier   | chains                                   | notes                                                  |
| ------ | ---------------- | ------ | ----------------------------------------- | ------------------------------------------------------- |
| `1CRN` | `1CRN-TEST.pdb`  | small  | A (46 res)                               | crambin                                                |
| `1UBQ` | `1UBQ-TEST.cif`  | small  | A (76 res)                               | ubiquitin                                              |
| `6PTI` | `6PTI-TEST.pdb`  | small  | A (57 res resolved)                      | BPTI                                                   |
| `1ZNI` | `1ZNI-TEST.cif`  | small  | A/C (21 res), B/D (30 res)               | insulin, 2 copies of the A/B dimer; small multi-chain  |
| `6LYZ` | `6LYZ-TEST.cif`  | medium | A (129 res)                              | hen egg-white lysozyme                                 |
| `7RSA` | `7RSA-TEST.pdb`  | medium | A (124 res)                              | ribonuclease A                                         |
| `1MBN` | `1MBN-TEST.cif`  | medium | A (153 res)                              | sperm whale myoglobin                                  |
| `4HHB` | `4HHB-TEST.pdb`  | large  | A/C (141 res), B/D (146 res)             | hemoglobin, 4 chains (2 alpha + 2 beta)                |
| `1FBI` | `1FBI-TEST.cif`  | large  | H/Q (221), L/P (214), X/Y (129)          | 2 Fab copies + lysozyme antigen, 6 chains, 8521 atoms  |
| `1IGT` | `1IGT-TEST.pdb`  | large  | A/C (214), B/D (437 unique, numbered to 474) | intact IgG2a, 4 chains, 10214 atoms                |

Filenames carry a `-TEST` suffix (distinct from the bare RCSB ID, e.g.
`1CRN-TEST.pdb` rather than `1CRN.pdb`) so `LocalPathSource`'s filename-stem
cache key can never plausibly collide with a real user's own local file or
`PDBIDSource` fetch of the same ID under the fail-loud collision policy in
`StructureSource.jl`.

`.pdb`/`.cif` are deliberately mixed (5 of each) so local resolution exercises
both of `LocalPathSource`'s branches. No real fixture with a genuine
multi-character author chain ID (`_atom_site.auth_asym_id`, the field
`StructureSource`/`BioStructures` actually key `chainid` on) was found within
the size range this batch targets -- that only shows up in assemblies with
dozens of chains (ribosomes, capsids), well past the "large-ish" ceiling; the
multi-char-chain failure path is covered by a synthetic fixture inline in
`test_structuresource.jl` instead.
