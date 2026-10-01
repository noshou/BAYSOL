# Test fixtures

Fixtures are grouped by kind, one directory per kind:


| directory                                                    | contents                                                                   |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| [`form-factors/`](#form-factor-oracle-fixtures-form-factors) | X-ray form-factor oracle data (`f0.csv`, `f1f2.csv`) from `xraydb`         |
| [`functions/`](#shared-test-helpers-functions)               | Shared test helper `.jl` files (`include`d directly)                                                        |
| [`molecules/`](#structure-fixtures-molecules)                | Real RCSB PDB/mmCIF structures, used by`StructureSource`/pipeline tests    |
| [`experiments/`](#sasbdb-experiment-fixtures-experiments)    | Real SASBDB entries (curve + fit + model + source paper), one dir per case; 27 entries, all protein-only (no nucleic-acid fixture yet) |

## Form-factor oracle (`form-factors/`)

Reference values from xraydb (Python/sqlite3 db).


| file       | rows | contents                                                                                                                                                                  |
| ------------ | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `f0.csv`   | 348  | `ion,s,f0` — 29 species (neutral atoms, cations, anions, the `cval`/`siva` valence states, Z up to 98) across `s = 0 … 6 Å⁻¹`                                        |
| `f1f2.csv` | 852  | `element,energy_eV,f1,f2` — 500 points at 1 eV spacing across the Fe K edge (6900–7400 eV), 160 more at 10 eV to 9000 eV, plus 12 elements H→U over 1.01 eV … 966 keV |

Used by `test_formfactor.jl`.

## Shared test helpers (`functions/`)

Shared test-geometry/data helpers (`.jl`, `include`d directly).


| file              | contents                                                                                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `geometry.jl`     | `sph(R, n)` — Fibonacci-sphere point set, used by `test_sasa.jl` to build a sealed shell of atoms around an enclosed void                                                   |
| `floatcompare.jl` | `close_(a, b; atol = 1.0e-9)`; tolerance float compare, used by `test_dns.jl`, `test_pmv.jl`, `test_deltarho.jl`, `test_paramtransform.jl`, `test_sampler.jl`, `test_profiledcorrs.jl`, `test_protonation.jl`, `test_integration.jl` and `test_structuresource.jl` wherever `check_float`'s fixed `DEFAULT_ATOL` is too tight |
| `sequences.jl`    | Protein/DNA/RNA sequences, used by `test_dns.jl` and `test_pmv.jl`.                                                                                                                                                                                |

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

Filenames carry a `-TEST` suffix (distinct from the bare RCSB ID, e.g. `1CRN-TEST.pdb` rather than `1CRN.pdb`) so `LocalPathSource`'s filename-stem cache key can never collide with a user's own local file.

## SASBDB experiment fixtures (`experiments/`)

 SASBDB entries, one directory per case, each holding (subset varies by
case): the experimental scattering curve (`experimental_data/`), the
deposited P(r) (`pddf/`), the depositors' own regularized fit(s)
(`<CASE>_fit*.fit`/`.fir`/`.dat`), the fitted/source model coordinates
(`<CASE>_fit*_model*.pdb`/`.cif`), and the source paper PDF when its
license allows redistribution (every bundled PDF is open access: CC BY,
CC BY-NC(-ND) or ACS AuthorChoice; SASDCQ2's IUCr PDF carries an Open
Access badge but prints no license, so check it on the IUCr page). SASDMJ9's paper is not open access, so
only its DOI is given.


| SASBDB id | source paper                                                                                                                                                                                                                                                                   | fitting test                            |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `SASDA52` | Raj, Ramaswamy & Plapp (2014)*Biochemistry* 53:5791, "Yeast Alcohol Dehydrogenase Structure and Catalysis". [10.1021/bi5006442](https://doi.org/10.1021/bi5006442) (standard-protein reference structure; not itself linked to a publication in SASBDB's own metadata) | `test/fitting_tests/SASDA52/SASDA52_fit1.jl` |
| `SASDBS6` | Gkekas S, Singh RK, Shkumatov AV, et al., J Biol Chem (2017). [10.1074/jbc.M116.761809](https://doi.org/10.1074/jbc.M116.761809) | `test/fitting_tests/SASDBS6/SASDBS6.jl` |
| `SASDCQ2` | Trewhella J, Duff AP, Durand D, et al., Acta Crystallogr D Struct Biol (2017). [10.1107/S2059798317011597](https://doi.org/10.1107/S2059798317011597) | `test/fitting_tests/SASDCQ2/SASDCQ2.jl` |
| `SASDD88` | Khanam T, Afsar M, Shukla A, et al., Nucleic Acids Res (2020). [10.1093/nar/gkaa188](https://doi.org/10.1093/nar/gkaa188) | `test/fitting_tests/SASDD88/SASDD88.jl` |
| `SASDEP6` | Manso JA, Nunes-Costa D, Macedo-Ribeiro S, et al., MBio (2019). [10.1128/mBio.00239-19](https://doi.org/10.1128/mBio.00239-19) | `test/fitting_tests/SASDEP6/SASDEP6.jl` |
| `SASDF42` | Johansson, Nielsen, Demuth, Wiberg, Schjødt, Huang, Chen, Jensen, Petersen & Thygesen (2020)*Biochemistry* 59:1786. [10.1021/acs.biochem.0c00019](https://doi.org/10.1021/acs.biochem.0c00019) | `test/fitting_tests/SASDF42/SASDF42.jl` |
| `SASDJ62` | Hammel, Rashid, Sverzhinsky, Pourfarjam, Tsai, Ellenberger, Pascal, Kim, Tainer & Tomkinson (2021)*Nucleic Acids Res* 49:306. [10.1093/nar/gkaa1188](https://doi.org/10.1093/nar/gkaa1188) | `test/fitting_tests/SASDJ62/SASDJ62_model1.jl` |
| `SASDJ72` | Same as`SASDJ62` (different curve, "Merged" type). [10.1093/nar/gkaa1188](https://doi.org/10.1093/nar/gkaa1188) | `test/fitting_tests/SASDJ72/SASDJ72.jl` |
| `SASDJY2` | Czapinska H, Kowalska M, Zagorskaite E, et al., Nucleic Acids Res (2018). [10.1093/nar/gky731](https://doi.org/10.1093/nar/gky731) | `test/fitting_tests/SASDJY2/SASDJY2.jl` |
| `SASDKQ8` | Irumagawa S, Kobayashi K, Saito Y, et al., Sci Rep (2021). [10.1038/s41598-021-86952-2](https://doi.org/10.1038/s41598-021-86952-2) | `test/fitting_tests/SASDKQ8/SASDKQ8.jl` |
| `SASDLP4` | Marciano S, Dey D, Listov D, et al., Chemical Science (2022). [10.1039/D2SC02794A](https://doi.org/10.1039/D2SC02794A) | `test/fitting_tests/SASDLP4/SASDLP4.jl` |
| `SASDMJ9` | Xiao, Ma, Restle, Shang, Svergun, Ponnusamy, Sczakiel & Hilgenfeld (2012)*J Virol* 86:4444, "Nonstructural Proteins 7 and 8 of Feline Coronavirus Form a 2:1 Heterotrimer...". [10.1128/JVI.06635-11](https://doi.org/10.1128/JVI.06635-11) | `test/fitting_tests/SASDMJ9/SASDMJ9.jl` |
| `SASDMZ9` | Cerqueira, Photenhauer, Doden, Brown, Abdel-Hamid, Moraïs, Bayer, Wawrzak, Cann, Ridlon, Hopkins & Koropatkin (2022)*J Biol Chem* 298:101896. [10.1016/j.jbc.2022.101896](https://doi.org/10.1016/j.jbc.2022.101896) | `test/fitting_tests/SASDMZ9/SASDMZ9.jl` |
| `SASDN32` | Same as`SASDMZ9` (different curve). [10.1016/j.jbc.2022.101896](https://doi.org/10.1016/j.jbc.2022.101896) | `test/fitting_tests/SASDN32/SASDN32.jl` |
| `SASDP48` | Sandouk A, Xu Z, Baruah S, et al., Sci Rep (2023). [10.1038/s41598-023-30562-7](https://doi.org/10.1038/s41598-023-30562-7) | `test/fitting_tests/SASDP48/SASDP48.jl` |
| `SASDR99` | Bisello G, Ribeiro R, Perduca M, et al., Protein Science (2023). [10.1002/pro.4732](https://doi.org/10.1002/pro.4732) | `test/fitting_tests/SASDR99/SASDR99.jl` |
| `SASDRN5` | Fernandes R, Ostendorp A, Ostendorp S, et al., Sci Rep (2023). [10.1038/s41598-023-36426-4](https://doi.org/10.1038/s41598-023-36426-4) | `test/fitting_tests/SASDRN5/SASDRN5.jl` |
| `SASDRW2` | Iqbal H, Fung KW, Gor J, et al., J Biol Chem (2023). [10.1016/j.jbc.2022.102799](https://doi.org/10.1016/j.jbc.2022.102799) | `test/fitting_tests/SASDRW2/SASDRW2.jl` |
| `SASDTK5` | Inaba H, Shisaka Y, Ariyasu S, et al., RSC Advances (2024). [10.1039/D4RA01042F](https://doi.org/10.1039/D4RA01042F) | `test/fitting_tests/SASDTK5/SASDTK5.jl` |
| `SASDUN5` | Bulvas O, Knejzlík Z, Sýs J, et al., Nature Communications (2024). [10.1038/s41467-024-50933-6](https://doi.org/10.1038/s41467-024-50933-6) | `test/fitting_tests/SASDUN5/SASDUN5.jl` |
| `SASDV94` | Sabharwal, Ge, Lunelli, Sae-Ueng, Jeffries, Chatziefthymiou, Srivastava, Tumeh, Geisler, Kolbe & Labahn (2023)*Protein Cell*, "Molecular virulence mechanism of phospholipase C from Pseudomonas aeruginosa". [10.1093/procel/pwag062](https://doi.org/10.1093/procel/pwag062) | `test/fitting_tests/SASDV94/SASDV94_fit1.jl` |
| `SASDVG2` | Mishra N, Gido CD, Herdendorf TJ, et al., J Biol Chem (2024). [10.1016/j.jbc.2024.107627](https://doi.org/10.1016/j.jbc.2024.107627) | `test/fitting_tests/SASDVG2/SASDVG2.jl` |
| `SASDWZ9` | Huang, Shih, Jeng, Chang, Lin & Malliavin (2026)*ACS Omega*, "pH Sensitivity of the SERF1a Conformational Ensemble". [10.1021/acsomega.5c07620](https://doi.org/10.1021/acsomega.5c07620) | `test/fitting_tests/SASDWZ9/SASDWZ9.jl` |
| `SASDX52` | Rahman, Dalwani & Venkatesan (2025)*Biochem Biophys Res Commun*, "Structural enzymological studies of ... FadD5 ... of Mycobacterium tuberculosis". [10.1016/j.bbrc.2025.151960](https://doi.org/10.1016/j.bbrc.2025.151960) | `test/fitting_tests/SASDX52/SASDX52.jl` |
| `SASDYW6` | Cuéllar-Cruz, Siliqi & Moreno (2026)*ACS Omega*, "Insights into the Solution Structure and Oligomeric State of Fructose-1,6-bisphosphate Aldolase and Pyruvate Kinase from Nakaseomyces glabratus". [10.1021/acsomega.6c06099](https://doi.org/10.1021/acsomega.6c06099) | `test/fitting_tests/SASDYW6/SASDYW6_fit2.jl` |
| `SASDZC6` | "A highly dynamic active state for transducin-bound phosphodiesterase-6 in vertebrate phototransduction" -- bioRxiv preprint, accession`2026.04.01.715611` (`v3`). No DOI resolves yet as of writing; not linked to a publication in SASBDB's own metadata either. | `test/fitting_tests/SASDZC6/SASDZC6.jl` |
| `SASDZZ9` | Pongnan, Robinson, Kamonsutthipaijit, Fukamizo & Suginta (2026)*Biophys Rep (N Y)*, "The oligomeric state of chitooligosaccharide deacetylase from ... Vibrio campbellii". [10.1016/j.bpr.2026.100275](https://doi.org/10.1016/j.bpr.2026.100275) | `test/fitting_tests/SASDZZ9/SASDZZ9_fit1.jl` |
