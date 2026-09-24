# Test fixtures

Fixtures are grouped by kind, one directory per kind:


| directory                                                    | contents                                                                   |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| [`form-factors/`](#form-factor-oracle-fixtures-form-factors) | X-ray form-factor oracle data (`f0.csv`, `f1f2.csv`) from `xraydb`         |
| [`functions/`](#shared-test-BAYSOL_Utils-functions)               | Shared`.jl` BAYSOL_Utils                                                        |
| [`molecules/`](#structure-fixtures-molecules)                | Real RCSB PDB/mmCIF structures, used by`StructureSource`/pipeline tests    |
| [`experiments/`](#sasbdb-experiment-fixtures-experiments)    | Real SASBDB entries (curve + fit + model + source paper), one dir per case |

## Form-factor oracle (`form-factors/`)

Reference values from xraydb (Python/sqlite3 db).


| file       | rows | contents                                                                                                                                                                  |
| ------------ | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `f0.csv`   | 348  | `ion,s,f0` — 29 species (neutral atoms, cations, anions, the `cval`/`siva` valence states, Z up to 98) across `s = 0 … 6 Å⁻¹`                                        |
| `f1f2.csv` | 852  | `element,energy_eV,f1,f2` — 500 points at 1 eV spacing across the Fe K edge (6900–7400 eV), 160 more at 10 eV to 9000 eV, plus 12 elements H→U over 1.01 eV … 966 keV |

Used by `test_formfactor.jl`.

## Shared test BAYSOL_Utils (`functions/`)

Shared test-geometry/data BAYSOL_Utils (`.jl`, `include`d directly).


| file              | contents                                                                                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `geometry.jl`     | `sph(R, n)` — Fibonacci-sphere point set, used by `test_sasa.jl` and `test_hydrophobicity.jl` to build a sealed shell of atoms around an enclosed void                                                   |
| `floatcompare.jl` | `close_(a, b; atol = 1.0e-9)`; tolerance float compare, used by `test_dns.jl`, `test_pmv.jl`, `test_deltarho.jl` and `test_hydrophobicity.jl` wherever `check_float`'s fixed `DEFAULT_ATOL` is too tight |
| `sequences.jl`    | Protein/DNA/RNA sequences.                                                                                                                                                                                |

### `sequences.jl` provenance


| constant         | accession                                          | citation (DOI)                                                                                                                                                       |
| ------------------ | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OXYTOCIN`       | UniProt P01178 (residues 3-11)                     | du Vigneaud et al. (1953)*J Am Chem Soc* 75:4879. [10.1021/ja01115a553](https://doi.org/10.1021/ja01115a553)                                                         |
| `INSULIN_A`      | UniProt P01308 (residues 90-110)                   | Bell, Pictet, Rutter, Cordell, Tischer & Goodman (1980)*Nature* 284:26. [10.1038/284026a0](https://doi.org/10.1038/284026a0)                                         |
| `INSULIN_B`      | UniProt P01308 (residues 25-54)                    | Bell, Pictet, Rutter, Cordell, Tischer & Goodman (1980)*Nature* 284:26. [10.1038/284026a0](https://doi.org/10.1038/284026a0)                                         |
| `LYSOZYME`       | UniProt P00698 (mature chain)                      | Canfield (1963)*J Biol Chem* 238:2698. [10.1016/S0021-9258(18)67888-3](https://doi.org/10.1016/S0021-9258(18)67888-3)                                                |
| `GFP`            | UniProt P42212 (mature chain)                      | Prasher, Eckenrode, Ward, Prendergast & Cormier (1992)*Gene* 111:229. [10.1016/0378-1119(92)90691-H](https://doi.org/10.1016/0378-1119(92)90691-H)                   |
| `M13_PRIMER`     | NEB/Thermo Fisher standard oligo                   | Messing (1983)*Methods Enzymol* 101:20. [10.1016/0076-6879(83)01005-8](https://doi.org/10.1016/0076-6879(83)01005-8)                                                 |
| `PUC19_FRAGMENT` | GenBank L09137.2 (positions 1-240)                 | N/A                                                                                                                                                                  |
| `TRNA_PHE`       | GtRNAdb,*S. cerevisiae* tRNA-Phe-GAA-1-1 (sacCer3) | Kim, Suddath, Quigley, McPherson, Sussman, Wang, Seeman & Rich (1974)*Science* 185:435. [10.1126/science.185.4149.435](https://doi.org/10.1126/science.185.4149.435) |
| `RRNA_5S`        | RNAcentral URS0000049E57 (*E. coli*)               | Brownlee, Sanger & Barrell (1968) *J Mol Biol* 34:379. [10.1016/0022-2836(68)90168-X](https://doi.org/10.1016/0022-2836(68)90168-X)                                 |

# Structure fixtures (`molecules/`)

PDB entries fetched from RCSB, used by `test_structuresource.jl` to exercise `StructureSource`'s `LocalPathSource` branch (both the `.pdb` passthrough and `.cif`/mmCIF conversion) against real data across a genuine size range, and as the local half of cross-consistency checks against live `PDBIDSource` fetches.


| id     | file            | tier   | chains                                       | notes                                                 | citation (DOI)                                                                                                                                                            |
| -------- | ----------------- | -------- | ---------------------------------------------- | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `1CRN` | `1CRN-TEST.pdb` | small  | A (46 res)                                   | crambin                                               | Teeter (1984)*PNAS* 81:6014. [10.1073/pnas.81.19.6014](https://doi.org/10.1073/pnas.81.19.6014)                                                                           |
| `1UBQ` | `1UBQ-TEST.cif` | small  | A (76 res)                                   | ubiquitin                                             | Vijay-Kumar, Bugg & Cook (1987)*J Mol Biol* 194:531. [10.1016/0022-2836(87)90679-6](https://doi.org/10.1016/0022-2836(87)90679-6)                                         |
| `6PTI` | `6PTI-TEST.pdb` | small  | A (57 res resolved)                          | BPTI                                                  | Wlodawer, Nachman, Gilliland, Gallagher & Woodward (1987)*J Mol Biol* 198:469. [10.1016/0022-2836(87)90294-4](https://doi.org/10.1016/0022-2836(87)90294-4)               |
| `1ZNI` | `1ZNI-TEST.cif` | small  | A/C (21 res), B/D (30 res)                   | insulin, 2 copies of the A/B dimer; small multi-chain | Bentley, Dodson, Dodson, Hodgkin & Mercola (1976)*Nature* 261:166. [10.1038/261166a0](https://doi.org/10.1038/261166a0)                                                   |
| `6LYZ` | `6LYZ-TEST.cif` | medium | A (129 res)                                  | hen egg-white lysozyme                                | Diamond (1974)*J Mol Biol* 82:371. [10.1016/0022-2836(74)90598-1](https://doi.org/10.1016/0022-2836(74)90598-1)                                                           |
| `7RSA` | `7RSA-TEST.pdb` | medium | A (124 res)                                  | ribonuclease A                                        | Wlodawer, Svensson, Sjölin & Gilliland (1988)*Biochemistry* 27:2705. [10.1021/bi00408a010](https://doi.org/10.1021/bi00408a010)                                          |
| `1MBN` | `1MBN-TEST.cif` | medium | A (153 res)                                  | sperm whale myoglobin                                 | Watson (1969)*Prog. Stereochem.* 4:299. No DOI (pre-DOI-era publication).                                                                                                 |
| `4HHB` | `4HHB-TEST.pdb` | large  | A/C (141 res), B/D (146 res)                 | hemoglobin, 4 chains (2 alpha + 2 beta)               | Fermi, Perutz, Shaanan & Fourme (1984)*J Mol Biol* 175:159. [10.1016/0022-2836(84)90472-8](https://doi.org/10.1016/0022-2836(84)90472-8)                                  |
| `1FBI` | `1FBI-TEST.cif` | large  | H/Q (221), L/P (214), X/Y (129)              | 2 Fab copies + lysozyme antigen, 6 chains, 8521 atoms | Lescar, Pellegrini, Souchon, Tello, Poljak, Peterson, Greene & Alzari (1995)*J Biol Chem* 270:18067. [10.1074/jbc.270.30.18067](https://doi.org/10.1074/jbc.270.30.18067) |
| `1IGT` | `1IGT-TEST.pdb` | large  | A/C (214), B/D (437 unique, numbered to 474) | intact IgG2a, 4 chains, 10214 atoms                   | Harris, Larson, Hasel & McPherson (1997)*Biochemistry* 36:1581. [10.1021/bi962514+](https://doi.org/10.1021/bi962514+)                                                    |

Filenames carry a `-TEST` suffix (distinct from the bare RCSB ID, e.g. `1CRN-TEST.pdb` rather than `1CRN.pdb`) so `LocalPathSource`'s filename-stem cache key can never X collide with a user's own local file.

## SASBDB experiment fixtures (`experiments/`)

 SASBDB entries, one directory per case, each holding (subset varies by
case): the experimental scattering curve (`experimental_data/`), the
deposited P(r) (`pddf/`), the depositors' own regularized fit(s)
(`<CASE>_fit*.fit`/`.fir`/`.dat`), the fitted/source model coordinates
(`<CASE>_fit*_model*.pdb`/`.cif`), and the source paper PDF.


| SASBDB id | source paper                                                                                                                                                                                                                                                                   | fitting test                            |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `SASDA52` | Raj, Ramaswamy & Plapp (2014)*Biochemistry* 53:5791, "Yeast Alcohol Dehydrogenase Structure and Catalysis". [10.1021/bi5006442](https://doi.org/10.1021/bi5006442) (standard-protein reference structure; not itself linked to a publication in SASBDB's own metadata)         |                                         |
| `SASDB62` | Simon, Huart, Temmerman, Vahokoski, Mertens, Komadina, Hoffmann, Yumerefendi, Svergun, Kursula, Schultz, McCarthy, Hart & Wilmanns (2016)*Structure* 24:851. [10.1016/j.str.2016.03.020](https://doi.org/10.1016/j.str.2016.03.020)                                            |                                         |
| `SASDF42` | Johansson, Nielsen, Demuth, Wiberg, Schjødt, Huang, Chen, Jensen, Petersen & Thygesen (2020)*Biochemistry* 59:1786. [10.1021/acs.biochem.0c00019](https://doi.org/10.1021/acs.biochem.0c00019)                                                                                |                                         |
| `SASDJ62` | Hammel, Rashid, Sverzhinsky, Pourfarjam, Tsai, Ellenberger, Pascal, Kim, Tainer & Tomkinson (2021)*Nucleic Acids Res* 49:306. [10.1093/nar/gkaa1188](https://doi.org/10.1093/nar/gkaa1188)                                                                                     |                                         |
| `SASDJ72` | Same as`SASDJ62` (different curve, "Merged" type). [10.1093/nar/gkaa1188](https://doi.org/10.1093/nar/gkaa1188)                                                                                                                                                                |                                         |
| `SASDMJ9` | Xiao, Ma, Restle, Shang, Svergun, Ponnusamy, Sczakiel & Hilgenfeld (2012)*J Virol* 86:3144, "Nonstructural Proteins 7 and 8 of Feline Coronavirus Form a 2:1 Heterotrimer...". [10.1128/JVI.06635-11](https://doi.org/10.1128/JVI.06635-11)                                    | `test/fitting_tests/SASDMJ9/SASDMJ9.jl` |
| `SASDMZ9` | Cerqueira, Photenhauer, Doden, Brown, Abdel-Hamid, Moraïs, Bayer, Wawrzak, Cann, Ridlon, Hopkins & Koropatkin (2022)*J Biol Chem* 298:101896. [10.1016/j.jbc.2022.101896](https://doi.org/10.1016/j.jbc.2022.101896)                                                          |                                         |
| `SASDN32` | Same as`SASDMZ9` (different curve). [10.1016/j.jbc.2022.101896](https://doi.org/10.1016/j.jbc.2022.101896)                                                                                                                                                                     |                                         |
| `SASDV94` | Sabharwal, Ge, Lunelli, Sae-Ueng, Jeffries, Chatziefthymiou, Srivastava, Tumeh, Geisler, Kolbe & Labahn (2023)*Protein Cell*, "Molecular virulence mechanism of phospholipase C from Pseudomonas aeruginosa". [10.1093/procel/pwag062](https://doi.org/10.1093/procel/pwag062) |                                         |
| `SASDWZ9` | Huang, Shih, Jeng, Chang, Lin & Malliavin (2026)*ACS Omega*, "pH Sensitivity of the SERF1a Conformational Ensemble". [10.1021/acsomega.5c07620](https://doi.org/10.1021/acsomega.5c07620)                                                                                      |                                         |
| `SASDX52` | Rahman, Dalwani & Venkatesan (2025)*Biochem Biophys Res Commun*, "Structural enzymological studies of ... FadD5 ... of Mycobacterium tuberculosis". [10.1016/j.bbrc.2025.151960](https://doi.org/10.1016/j.bbrc.2025.151960)                                                   |                                         |
| `SASDYW6` | Cuéllar-Cruz, Siliqi & Moreno (2026)*ACS Omega*, "Insights into the Solution Structure and Oligomeric State of Fructose-1,6-bisphosphate Aldolase and Pyruvate Kinase from Nakaseomyces glabratus". [10.1021/acsomega.6c06099](https://doi.org/10.1021/acsomega.6c06099)      |                                         |
| `SASDZC6` | "A highly dynamic active state for transducin-bound phosphodiesterase-6 in vertebrate phototransduction" -- bioRxiv preprint, accession`2026.04.01.715611` (`v3`). No DOI resolves yet as of writing; not linked to a publication in SASBDB's own metadata either.             |                                         |
| `SASDZZ9` | Pongnan, Robinson, Kamonsutthipaijit, Fukamizo & Suginta (2026)*Biophys Rep (N Y)*, "The oligomeric state of chitooligosaccharide deacetylase from ... Vibrio campbellii". [10.1016/j.bpr.2026.100275](https://doi.org/10.1016/j.bpr.2026.100275)                              |                                         |
