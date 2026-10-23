# Test fixtures

Data fixtures are grouped by kind, one directory per kind:


| directory                                                    | contents                                                                   |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| [`form-factors/`](#form-factor-oracle-fixtures-form-factors) | X-ray form-factor oracle data (`f0.csv`, `f1f2.csv`) from `xraydb`         |
| [`molecules/`](#structure-fixtures-molecules)                | Real RCSB PDB/mmCIF structures (10 protein, 6 nucleic-acid or mixed ones), used by `StructureSource`/pipeline tests |
| [`components/`](#component-dictionary-fixtures-components)   | Three wwPDB Chemical Component Dictionary files, for the component-lookup tests |
| [`experiments/`](#sasbdb-experiment-fixtures-experiments)    | Real SASBDB entries (curve + fit + model + source paper), one dir per case; 57 entries: 27 protein-only and 30 with DNA or RNA (16 nucleic acid only, 14 protein and nucleic acid) |

## Form-factor oracle (`form-factors/`)

Reference values from xraydb (Python/sqlite3 db).


| file       | rows | contents                                                                                                                                                                  |
| ------------ | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `f0.csv`   | 348  | `ion,s,f0` — 29 species (neutral atoms, cations, anions, the `cval`/`siva` valence states, Z up to 98) across `s = 0 … 6 Å⁻¹`                                        |
| `f1f2.csv` | 852  | `element,energy_eV,f1,f2` — 500 points at 1 eV spacing across the Fe K edge (6900–7400 eV), 160 more at 10 eV to 9000 eV, plus 12 elements H→U over 1.01 eV … 966 keV |

Used by `test_formfactor.jl`.

## Shared test helpers

The unit tests `include` three shared helpers. `geometry.jl` and `floatcompare.jl` are code, not data, so they live in `test/utils/`; `sequences.jl` is a data corpus and lives in `molecules/`.


| file              | contents                                                                                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `utils/geometry.jl`     | `sph(R, n)` — Fibonacci-sphere point set, used by `test_sasa.jl` to build a sealed shell of atoms around an enclosed void                                                   |
| `utils/floatcompare.jl` | `close_(a, b; atol = 1.0e-9)`; tolerance float compare, used by `test_dns.jl`, `test_bulkelectrondensity.jl`, `test_deltarho.jl`, `test_paramtransform.jl`, `test_sampler.jl`, `test_profiledcorrs.jl`, `test_protonation.jl`, `test_integration.jl` and `test_structuresource.jl` |
| `molecules/sequences.jl`    | Protein/DNA/RNA sequences, used by `test_dns.jl` and `test_bulkelectrondensity.jl`.                                                                                                                                                                                |

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
| `1BNA` | `1BNA-TEST.pdb` | small  | A/B (12 nt each)                             | B-DNA dodecamer (Dickerson-Drew), standard residues only, 80 waters | Drew, Wing, Takano, Broka, Tanaka, Itakura & Dickerson (1981)*PNAS* 78:2179. [10.1073/pnas.78.4.2179](https://doi.org/10.1073/pnas.78.4.2179) |
| `1RNA` | `1RNA-TEST.pdb` | small  | A/B (14 nt each)                             | A-form RNA helix, A and U only, 91 waters | Dock-Bregeon, Chevrier, Podjarny, Johnson, de Bear, Gough, Gilham & Moras (1989)*J Mol Biol* 209:459. [10.1016/0022-2836(89)90010-7](https://doi.org/10.1016/0022-2836(89)90010-7) |
| `1SDR` | `1SDR-TEST.pdb` | small  | A, B, C, D (12 nt each; two duplexes)        | RNA dodecamer with the four standard bases (E. coli Shine-Dalgarno sequence), 39 waters | Schindelin, Zhang, Bald, Fürste, Erdmann & Heinemann (1995)*J Mol Biol* 249:595. [10.1006/jmbi.1995.0321](https://doi.org/10.1006/jmbi.1995.0321) |
| `246D` | `246D-TEST.pdb` | small  | A, B (8 nt each)                             | RNA with one 3'-terminal deoxy-C (a DNA/RNA chimera) and two Na⁺ ions (HETATM) | Wahl, Ban, Sekharudu, Ramakrishnan & Sundaralingam (1996)*Acta Crystallogr D* 52:655. [10.1107/S0907444996000248](https://doi.org/10.1107/S0907444996000248) |
| `1EHZ` | `1EHZ-TEST.pdb`, `1EHZ-TEST.cif` | medium | A (76 nt, plus the ions)                     | yeast tRNA-Phe: 14 modified residues of 11 types (HETATM), Mg²⁺ and Mn²⁺ ions, 160 waters; the same entry as .pdb and as mmCIF, to exercise both loader paths | Shi & Moore (2000)*RNA* 6:1091. [10.1017/S1355838200000364](https://doi.org/10.1017/S1355838200000364) |
| `3HDD` | `3HDD-TEST.pdb` | medium | A/B (homeodomain, 55 and 56 res), C/D (DNA, 21 nt each) | engrailed homeodomain-DNA complex: the mixed protein and DNA case | Fraenkel, Rould, Chambers & Pabo (1998)*J Mol Biol* 284:351. [10.1006/jmbi.1998.2147](https://doi.org/10.1006/jmbi.1998.2147) |

Filenames carry a `-TEST` suffix (distinct from the bare RCSB ID, e.g. `1CRN-TEST.pdb` rather than `1CRN.pdb`) so `LocalPathSource`'s filename-stem cache key can never collide with a user's own local file.

## Component dictionary fixtures (`components/`)

Three files of the wwPDB Chemical Component Dictionary, one mmCIF per component, downloaded unmodified on 2026-10-15 from `https://files.rcsb.org/ligands/download/<ID>.cif`. The bundled table `src/MolecularStructure/components.tsv` already holds all three ids, so `test_componentcache.jl` and `test_nucleotide_seed.jl` rewrite the residue id inside the file to one that is not in the table and serve it through the injectable download hook (`MolecularStructure._COMPONENT_DOWNLOAD`) or put it in the cache, then check what `component` returns against the table row.


| file      | component                                                          | role in the tests                                                                 |
| ----------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `PSU.cif` | PSU, pseudouridine-5'-monophosphate (`RNA LINKING`, parent U, `C9 H13 N2 O9 P`) | the cached or downloaded component of a modified nucleotide                      |
| `5MC.cif` | 5MC, 5-methylcytidine-5'-monophosphate (`RNA LINKING`, parent C)   | the same, as the fake download served by the hook                                |
| `ATP.cif` | ATP, adenosine-5'-triphosphate (`NON-POLYMER`)                     | a ligand that is not a nucleotide                                                |

No other new data files serve the nucleic-acid tests: their inputs are the fixtures of `molecules/` (1BNA, 1RNA, 1SDR, 246D, 1EHZ, 3HDD) and the SASDT55 and SASDG24 models in `experiments/`, cut or rewritten at run time.

## SASBDB experiment fixtures (`experiments/`)

 57 SASBDB entries (27 protein-only, 16 nucleic acid only and 14 protein-nucleic acid mixtures), one directory per case, each holding (subset varies by
case): the experimental scattering curve (`experimental_data/`), the
deposited P(r) (`pddf/`), the depositors' own regularized fit(s)
(`<CASE>_fit*.fit`/`.fir`/`.dat`), the fitted/source model coordinates
(`<CASE>_fit*_model*.pdb`/`.cif`), and a small `README.txt` naming the
source paper and its DOI. The publishers' PDFs are not kept in the repository (they were 85 MB, and
redistribution terms vary); fetch a paper from its DOI, which is also in the table below. The 30 nucleic-acid entries have not been fitted yet (see the fitting-test README); the depositor fit file keeps the number of the SASBDB fit it belongs to (`fit1`, `fit2` or `fit3`), whatever the script is called.


| SASBDB id | source paper                                                                                                                                                                                                                                                                   | fitting test                            |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `SASDA52` | Raj, Ramaswamy & Plapp (2014)*Biochemistry* 53:5791, "Yeast Alcohol Dehydrogenase Structure and Catalysis". [10.1021/bi5006442](https://doi.org/10.1021/bi5006442) (standard-protein reference structure; not itself linked to a publication in SASBDB's own metadata) | `test/fitting_tests/SASDA52/SASDA52_fit1.jl` |
| `SASDAC9` | Suslov NB et al. (2015 Nov) Nat Chem Biol, "Crystal structure of the Varkud satellite ribozyme.". [10.1038/nchembio.1929](https://doi.org/10.1038/nchembio.1929) | `test/fitting_tests/SASDAC9/SASDAC9.jl` |
| `SASDAN8` | Ponnusamy R et al. (2015 Nov 16) Nucleic Acids Res, "KSHV but not MHV-68 LANA induces a strong bend upon binding to terminal repeat viral DNA.". [10.1093/nar/gkv987](https://doi.org/10.1093/nar/gkv987) | `test/fitting_tests/SASDAN8/SASDAN8.jl` |
| `SASDB48` | Tunnicliffe RB et al. (2017 Jul 27) Nucleic Acids Res, "The herpes viral transcription factor ICP4 forms a novel DNA recognition complex.". [10.1093/nar/gkx419](https://doi.org/10.1093/nar/gkx419) | `test/fitting_tests/SASDB48/SASDB48.jl` |
| `SASDBS6` | Gkekas S, Singh RK, Shkumatov AV, et al., J Biol Chem (2017). [10.1074/jbc.M116.761809](https://doi.org/10.1074/jbc.M116.761809) | `test/fitting_tests/SASDBS6/SASDBS6.jl` |
| `SASDCA3` | Pozner A et al. (2018 Feb 2) J Mol Biol, "The C-Terminal Zinc Fingers of ZBTB38 are Novel Selective Readers of DNA Methylation.". [10.1016/j.jmb.2017.12.014](https://doi.org/10.1016/j.jmb.2017.12.014) | `test/fitting_tests/SASDCA3/SASDCA3_fit3.jl` |
| `SASDCM5` | Tarbouriech N et al. (2017 Nov 13) Nat Commun, "The vaccinia virus DNA polymerase structure provides insights into the mode of processivity factor binding.". [10.1038/s41467-017-01542-z](https://doi.org/10.1038/s41467-017-01542-z) | `test/fitting_tests/SASDCM5/SASDCM5.jl` |
| `SASDCQ2` | Trewhella J, Duff AP, Durand D, et al., Acta Crystallogr D Struct Biol (2017). [10.1107/S2059798317011597](https://doi.org/10.1107/S2059798317011597) | `test/fitting_tests/SASDCQ2/SASDCQ2.jl` |
| `SASDD88` | Khanam T, Afsar M, Shukla A, et al., Nucleic Acids Res (2020). [10.1093/nar/gkaa188](https://doi.org/10.1093/nar/gkaa188) | `test/fitting_tests/SASDD88/SASDD88.jl` |
| `SASDDF7` | Jühling T et al. (2018 Jul 9) Nucleic Acids Res, "Small but large enough: structural properties of armless mitochondrial tRNAs from the nematode Romanomermis culicivorax.". [10.1093/nar/gky593](https://doi.org/10.1093/nar/gky593) | `test/fitting_tests/SASDDF7/SASDDF7.jl` |
| `SASDEP6` | Manso JA, Nunes-Costa D, Macedo-Ribeiro S, et al., MBio (2019). [10.1128/mBio.00239-19](https://doi.org/10.1128/mBio.00239-19) | `test/fitting_tests/SASDEP6/SASDEP6.jl` |
| `SASDF42` | Johansson, Nielsen, Demuth, Wiberg, Schjødt, Huang, Chen, Jensen, Petersen & Thygesen (2020)*Biochemistry* 59:1786. [10.1021/acs.biochem.0c00019](https://doi.org/10.1021/acs.biochem.0c00019) | `test/fitting_tests/SASDF42/SASDF42.jl` |
| `SASDF95` | Liu Y et al. (2020 Jan 22) Frontiers in Microbiology, "Structural Insights Into the Transcriptional Regulation of HigBA Toxin–Antitoxin System by Antitoxin HigA in Pseudomonas aeruginosa". [10.3389/fmicb.2019.03158](https://doi.org/10.3389/fmicb.2019.03158) | `test/fitting_tests/SASDF95/SASDF95_fit2.jl` |
| `SASDG24` | Zhang Y et al. (2019 Nov 5) EMBO Rep, "Long non-coding subgenomic flavivirus RNAs have extended 3D structures and are flexible in solution.". [10.15252/embr.201847016](https://doi.org/10.15252/embr.201847016) | `test/fitting_tests/SASDG24/SASDG24.jl` |
| `SASDH39` | Golovinas E et al. (2021 Feb 25) Sci Rep, "Prokaryotic Argonaute from Archaeoglobus fulgidus interacts with DNA as a homodimer.". [10.1038/s41598-021-83889-4](https://doi.org/10.1038/s41598-021-83889-4) | `test/fitting_tests/SASDH39/SASDH39_fit1.jl` |
| `SASDJ62` | Hammel, Rashid, Sverzhinsky, Pourfarjam, Tsai, Ellenberger, Pascal, Kim, Tainer & Tomkinson (2021)*Nucleic Acids Res* 49:306. [10.1093/nar/gkaa1188](https://doi.org/10.1093/nar/gkaa1188) | `test/fitting_tests/SASDJ62/SASDJ62_model1.jl` |
| `SASDJ66` | Miele AE et al. (2021 Jan 4) Eur Biophys J, "Biophysical characterization of the complex between the iron-responsive transcription factor Fep1 and DNA.". [10.1007/s00249-020-01489-y](https://doi.org/10.1007/s00249-020-01489-y) | `test/fitting_tests/SASDJ66/SASDJ66_fit1.jl` |
| `SASDJ72` | Same as`SASDJ62` (different curve, "Merged" type). [10.1093/nar/gkaa1188](https://doi.org/10.1093/nar/gkaa1188) | `test/fitting_tests/SASDJ72/SASDJ72.jl` |
| `SASDJY2` | Czapinska H, Kowalska M, Zagorskaite E, et al., Nucleic Acids Res (2018). [10.1093/nar/gky731](https://doi.org/10.1093/nar/gky731) | `test/fitting_tests/SASDJY2/SASDJY2.jl` |
| `SASDJZ2` | Czapinska H et al. (2018 Oct 12) Nucleic Acids Res, "Activity and structure of EcoKMcrA.". [10.1093/nar/gky731](https://doi.org/10.1093/nar/gky731) | `test/fitting_tests/SASDJZ2/SASDJZ2_fit1.jl` |
| `SASDK36` | Morozov D et al. (2021 Jul) Molecular Therapy - Nucleic Acids, "The Role of Small-Angle X-Ray Scattering and Molecular Simulations in 3D Structure Elucidation of a DNA Aptamer Against Lung Cancer". [10.1016/j.omtn.2021.07.015](https://doi.org/10.1016/j.omtn.2021.07.015) | `test/fitting_tests/SASDK36/SASDK36.jl` |
| `SASDK94` | Bandera AM et al. (2021 Aug 25) Nucleic Acids Res, "BusR senses bipartite DNA binding motifs by a unique molecular ruler architecture.". [10.1093/nar/gkab736](https://doi.org/10.1093/nar/gkab736) | `test/fitting_tests/SASDK94/SASDK94_fit1.jl` |
| `SASDKQ8` | Irumagawa S, Kobayashi K, Saito Y, et al., Sci Rep (2021). [10.1038/s41598-021-86952-2](https://doi.org/10.1038/s41598-021-86952-2) | `test/fitting_tests/SASDKQ8/SASDKQ8.jl` |
| `SASDLP4` | Marciano S, Dey D, Listov D, et al., Chemical Science (2022). [10.1039/D2SC02794A](https://doi.org/10.1039/D2SC02794A) | `test/fitting_tests/SASDLP4/SASDLP4.jl` |
| `SASDM76` | Monsen RC et al. (2022 Mar 23) Nucleic Acids Res, "Long promoter sequences form higher-order G-quadruplexes: an integrative structural biology study of c-Myc, k-Ras and c-Kit promoter sequences.". [10.1093/nar/gkac182](https://doi.org/10.1093/nar/gkac182) | `test/fitting_tests/SASDM76/SASDM76.jl` |
| `SASDMJ9` | Xiao, Ma, Restle, Shang, Svergun, Ponnusamy, Sczakiel & Hilgenfeld (2012)*J Virol* 86:4444, "Nonstructural Proteins 7 and 8 of Feline Coronavirus Form a 2:1 Heterotrimer...". [10.1128/JVI.06635-11](https://doi.org/10.1128/JVI.06635-11) | `test/fitting_tests/SASDMJ9/SASDMJ9.jl` |
| `SASDMZ9` | Cerqueira, Photenhauer, Doden, Brown, Abdel-Hamid, Moraïs, Bayer, Wawrzak, Cann, Ridlon, Hopkins & Koropatkin (2022)*J Biol Chem* 298:101896. [10.1016/j.jbc.2022.101896](https://doi.org/10.1016/j.jbc.2022.101896) | `test/fitting_tests/SASDMZ9/SASDMZ9.jl` |
| `SASDN32` | Same as`SASDMZ9` (different curve). [10.1016/j.jbc.2022.101896](https://doi.org/10.1016/j.jbc.2022.101896) | `test/fitting_tests/SASDN32/SASDN32.jl` |
| `SASDNH7` | Montaño SP et al. (2022 Sep 14) Nucleic Acids Res, "Structural basis for topological regulation of Tn3 resolvase.". [10.1093/nar/gkac733](https://doi.org/10.1093/nar/gkac733) The depositor's fit file is not served by the SASBDB API (404); `SASDNH7_fit1.fit` was fetched from `https://www.sasbdb.org/media/fitting_files/SASDNH7_fit1.fit`. | `test/fitting_tests/SASDNH7/SASDNH7_fit1.jl` |
| `SASDNK7` | Miyauchi K et al. (2022 May) Data in Brief, "Small-angle X-ray scattering data of a guanine-rich DNA derived from the promoter region of c-MYC gene in solution". [10.1016/j.dib.2022.108285](https://doi.org/10.1016/j.dib.2022.108285) | `test/fitting_tests/SASDNK7/SASDNK7_fit1.jl` |
| `SASDNP7` | Gabel F et al. (2022 Sep 1) Acta Crystallogr D Struct Biol, "Medical contrast agents as promising tools for biomacromolecular SAXS experiments.". [10.1107/S2059798322007392](https://doi.org/10.1107/S2059798322007392) | `test/fitting_tests/SASDNP7/SASDNP7_fit1.jl` |
| `SASDP48` | Sandouk A, Xu Z, Baruah S, et al., Sci Rep (2023). [10.1038/s41598-023-30562-7](https://doi.org/10.1038/s41598-023-30562-7) | `test/fitting_tests/SASDP48/SASDP48.jl` |
| `SASDPN6` | Korn SM et al. (2023 Jun 7) Nat Commun, "The preference signature of the SARS-CoV-2 Nucleocapsid NTD for its 5'-genomic RNA elements.". [10.1038/s41467-023-38882-y](https://doi.org/10.1038/s41467-023-38882-y) | `test/fitting_tests/SASDPN6/SASDPN6_fit1.jl` |
| `SASDPU6` | Monsen RC et al. (2023 Jan 30) Nucleic Acids Res, "Structure of a 28.5 kDa duplex-embedded G-quadruplex system resolved to 7.4 Å resolution with cryo-EM.". [10.1093/nar/gkad014](https://doi.org/10.1093/nar/gkad014) | `test/fitting_tests/SASDPU6/SASDPU6.jl` |
| `SASDQ69` | Gedara SH et al. (2023 Mar 17) Nucleic Acids Res, "7-Deazaguanines in DNA: functional and structural elucidation of a DNA modification system.". [10.1093/nar/gkad141](https://doi.org/10.1093/nar/gkad141) | `test/fitting_tests/SASDQ69/SASDQ69.jl` |
| `SASDR99` | Bisello G, Ribeiro R, Perduca M, et al., Protein Science (2023). [10.1002/pro.4732](https://doi.org/10.1002/pro.4732) | `test/fitting_tests/SASDR99/SASDR99.jl` |
| `SASDRN5` | Fernandes R, Ostendorp A, Ostendorp S, et al., Sci Rep (2023). [10.1038/s41598-023-36426-4](https://doi.org/10.1038/s41598-023-36426-4) | `test/fitting_tests/SASDRN5/SASDRN5.jl` |
| `SASDRW2` | Iqbal H, Fung KW, Gor J, et al., J Biol Chem (2023). [10.1016/j.jbc.2022.102799](https://doi.org/10.1016/j.jbc.2022.102799) | `test/fitting_tests/SASDRW2/SASDRW2.jl` |
| `SASDSW7` | Escobar C et al. (2023 Nov) Journal of Molecular Biology, "Solution structure of poly(UG) RNA". [10.1016/j.jmb.2023.168340](https://doi.org/10.1016/j.jmb.2023.168340) | `test/fitting_tests/SASDSW7/SASDSW7_fit1.jl` |
| `SASDSX5` | (authors not linked in SASBDB) "BCL7 proteins, novel subunits of the mammalian SWI/SNF complex, bind the nucleosome core particle". **No DOI is recorded in SASBDB** (no publication or preprint is linked; parked until the owner decides what to cite). | `test/fitting_tests/SASDSX5/SASDSX5.jl` |
| `SASDT55` | Woltz R et al. (2024 Jan 24) None, "The NS1 protein of influenza B virus binds 5’-triphosphorylated dsRNA to suppress RIG-I activation and the host antiviral response". [10.1101/2023.09.25.559316](https://doi.org/10.1101/2023.09.25.559316) | `test/fitting_tests/SASDT55/SASDT55.jl` |
| `SASDTK5` | Inaba H, Shisaka Y, Ariyasu S, et al., RSC Advances (2024). [10.1039/D4RA01042F](https://doi.org/10.1039/D4RA01042F) | `test/fitting_tests/SASDTK5/SASDTK5.jl` |
| `SASDU29` | Srivastava D et al. (2024 Jul) Structure, "Molecular basis of CRX/DNA recognition and stoichiometry at the Ret4 response element". [10.1016/j.str.2024.07.004](https://doi.org/10.1016/j.str.2024.07.004) | `test/fitting_tests/SASDU29/SASDU29_fit1.jl` |
| `SASDUN5` | Bulvas O, Knejzlík Z, Sýs J, et al., Nature Communications (2024). [10.1038/s41467-024-50933-6](https://doi.org/10.1038/s41467-024-50933-6) | `test/fitting_tests/SASDUN5/SASDUN5.jl` |
| `SASDV94` | Sabharwal, Ge, Lunelli, Sae-Ueng, Jeffries, Chatziefthymiou, Srivastava, Tumeh, Geisler, Kolbe & Labahn (2023)*Protein Cell*, "Molecular virulence mechanism of phospholipase C from Pseudomonas aeruginosa". [10.1093/procel/pwag062](https://doi.org/10.1093/procel/pwag062) | `test/fitting_tests/SASDV94/SASDV94_fit1.jl` |
| `SASDVG2` | Mishra N, Gido CD, Herdendorf TJ, et al., J Biol Chem (2024). [10.1016/j.jbc.2024.107627](https://doi.org/10.1016/j.jbc.2024.107627) | `test/fitting_tests/SASDVG2/SASDVG2.jl` |
| `SASDVU5` | Crespo I et al. (2025 Mar 7) Structure, "The structure and function of the DNA binding domain of class B MpARF2 share more traits with class A AtARF5 than to that of class B AtARF1.". [10.1016/j.str.2025.02.006](https://doi.org/10.1016/j.str.2025.02.006) | `test/fitting_tests/SASDVU5/SASDVU5.jl` |
| `SASDVV4` | Gezelle JG et al. (2025 Aug 27) Nucleic Acids Res, "A conserved viral RNA fold enables nuclease resistance across kingdoms of life.". [10.1093/nar/gkaf840](https://doi.org/10.1093/nar/gkaf840) | `test/fitting_tests/SASDVV4/SASDVV4_fit1.jl` |
| `SASDVX2` | Mertinkus KR et al. (2024 Nov 6) J Am Chem Soc, "Dissecting the Conformational Heterogeneity of Stem-Loop Substructures of the Fifth Element in the 5'-Untranslated Region of SARS-CoV-2.". [10.1021/jacs.4c08406](https://doi.org/10.1021/jacs.4c08406) | `test/fitting_tests/SASDVX2/SASDVX2_fit1.jl` |
| `SASDWJ4` | Stafflinger H et al. (2025 Nov 26) Nucleic Acids Res, "Crystal structure of the class V GTP-binding RNA aptamer bound to its ligand: GTP recognition by a topologically complex intermolecular G-quadruplex.". [10.1093/nar/gkaf1315](https://doi.org/10.1093/nar/gkaf1315) | `test/fitting_tests/SASDWJ4/SASDWJ4_fit2.jl` |
| `SASDWR5` | Betts J et al. (2026 Aug) Molecular Cell, "A protein-dependent riboswitch activates ribosomal frameshifting in cardioviruses". [10.1016/j.molcel.2026.07.036](https://doi.org/10.1016/j.molcel.2026.07.036) | `test/fitting_tests/SASDWR5/SASDWR5.jl` |
| `SASDWZ9` | Huang, Shih, Jeng, Chang, Lin & Malliavin (2026)*ACS Omega*, "pH Sensitivity of the SERF1a Conformational Ensemble". [10.1021/acsomega.5c07620](https://doi.org/10.1021/acsomega.5c07620) | `test/fitting_tests/SASDWZ9/SASDWZ9.jl` |
| `SASDX52` | Rahman, Dalwani & Venkatesan (2025)*Biochem Biophys Res Commun*, "Structural enzymological studies of ... FadD5 ... of Mycobacterium tuberculosis". [10.1016/j.bbrc.2025.151960](https://doi.org/10.1016/j.bbrc.2025.151960) | `test/fitting_tests/SASDX52/SASDX52.jl` |
| `SASDYM2` | Troisi R et al. (2026 Jul 23) Mol Ther, "Prothrombin recognition and conformational modulation by anti-thrombin anticoagulant aptamers.". [10.1016/j.ymthe.2026.07.042](https://doi.org/10.1016/j.ymthe.2026.07.042) | `test/fitting_tests/SASDYM2/SASDYM2.jl` |
| `SASDYW6` | Cuéllar-Cruz, Siliqi & Moreno (2026)*ACS Omega*, "Insights into the Solution Structure and Oligomeric State of Fructose-1,6-bisphosphate Aldolase and Pyruvate Kinase from Nakaseomyces glabratus". [10.1021/acsomega.6c06099](https://doi.org/10.1021/acsomega.6c06099) | `test/fitting_tests/SASDYW6/SASDYW6_fit2.jl` |
| `SASDZC6` | "A highly dynamic active state for transducin-bound phosphodiesterase-6 in vertebrate phototransduction" -- bioRxiv preprint, accession`2026.04.01.715611` (`v3`). The DOI printed on the preprint is [10.64898/2026.04.01.715611](https://doi.org/10.64898/2026.04.01.715611) (it may not resolve yet); not linked to a publication in SASBDB's own metadata either. | `test/fitting_tests/SASDZC6/SASDZC6.jl` |
| `SASDZZ9` | Pongnan, Robinson, Kamonsutthipaijit, Fukamizo & Suginta (2026)*Biophys Rep (N Y)*, "The oligomeric state of chitooligosaccharide deacetylase from ... Vibrio campbellii". [10.1016/j.bpr.2026.100275](https://doi.org/10.1016/j.bpr.2026.100275) | `test/fitting_tests/SASDZZ9/SASDZZ9_fit1.jl` |
