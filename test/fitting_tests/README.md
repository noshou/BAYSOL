# Fitting tests

**Note:** Entries in `BAYSOL.PartialMolarVolumes` without uncertainties use an uncertainty estimated from the mean of the available experimental uncertainties. As the table grows, this estimate may change slightly, so fit results may change.

End-to-end BAYSOL fits of 27 SASBDB entries (protein-only structures): load a structure, build its buffer, run the NUTS sampler over `ξ = (ρₑ, δρ₁, δρ₂, δρ₃)` with the excluded-volume correction `c1` profiled at every evaluation, and write the MAP/posterior report and figures
next to the script. The fitted curve is the deposited SASBDB curve (q in Å⁻¹, truncated at each script's `Q_MAX_FIT`).

```
julia --project=test/fitting_tests test/fitting_tests/<ID>/<script>.jl
```

All fits use 2000 NUTS iterations: the first 1000 are warmup (step-size and mass-matrix adaptation) and are discarded, leaving 1000
posterior draws. The seed is 0. Each script defines `run_<id>(; n_samples, n_adapt, seed)` if you want to change these values;
`n_samples` is the *total* iteration count, including the `n_adapt` warmup, and the scripts use these defaults. The temperature is each entry's stated sample temperature (25 °C when none is given). Hydrogens are added with Pdb2pqr at the stated pH unless noted. 

## Results

 Bold marks a parameter at a hard prior bound (δρ₁, δρ₂ ≤ 2; δρ₃ ∈ [−ρ̄ₑ/0.03, (φ_max − 1)·ρ̄ₑ/0.03] ≈ [−11.1, 2.8]), `c1` profiling saturation, or a chain with >5% divergent transitions. `"` repeats the line above: the members of one deposited multi-model fit share a single depositor χ², which belongs to their **weighted mixture**, not to any one member (see "Ensemble and multi-model entries" below).


| Run                 | χ² (MAP)             | depositor's χ² (method)      | δρ₁   | δρ₂   | δρ₃      | c1                    | divergences |
| --------------------- | ------------------------ | -------------------------------- | ---------- | ---------- | ------------- | ----------------------- | ------------- |
| SASDA52 fit1        | 5.25                   | CRYSOL χ² 2.48 (χ² ≈ 6.2) | 0.09     | 0.06     | **2.77**    | 1.162                 | 0           |
| SASDBS6 fit2_model1 | 61.2                   | EOM ensemble 11.3              | **1.99** | 0.16     | **−11.28** | 0.929                 | 0           |
| SASDBS6 fit2_model2 | 214                    | ″                             | **2.00** | **2.00** | **−11.25** | 1.009                 | 0           |
| SASDBS6 fit2_model3 | 21.9                   | ″                             | 0.04     | 1.72     | **2.82**    | 1.200                 | 0           |
| SASDBS6 fit2_model4 | 23.9                   | ″                             | 0.09     | 1.12     | **2.82**    | 1.196                 | 0           |
| SASDBS6 fit2_model5 | 215                    | ″                             | 1.84     | **2.00** | **2.82**    | **0.780 (saturated)** | 0           |
| SASDCQ2 fit2_model1 | 0.815                  | MultiFoXS 1-state 0.85         | 0.53     | −0.55   | −6.00      | 1.163                 | 0.1 %       |
| SASDCQ2 fit3_model1 | 2.59                   | MultiFoXS 2-state 0.79         | 0.87     | **1.97** | 2.15        | 1.161                 | 0           |
| SASDCQ2 fit3_model2 | 51.3                   | ″                             | 0.40     | −1.57   | 2.51        | 1.123                 | 0           |
| SASDD88 fit2_model1 | 1.02                   | FoXS 4.50                      | 0.38     | −4.58   | 2.04        | 1.194                 | 0           |
| SASDD88 fit3_model1 | 0.936                  | FoXS 2.79                      | 0.92     | −3.49   | 0.25        | 1.192                 | 0.5 %       |
| SASDEP6 fit1_model1 | 3.19                   | OLIGOMER 2-state 8.31 (w 0.59) | 0.71     | 1.32     | **2.79**    | 1.164                 | 0           |
| SASDEP6 fit1_model2 | 10.7                   | ″ (w 0.41)                    | 0.34     | −0.71   | **2.83**    | 1.197                 | 0           |
| SASDF42 —          | 1.36                   | 2.10                           | 0.21     | −0.21   | 1.11        | 1.177                 | 0           |
| SASDJ62 model1      | 3.45                   | —                             | 0.21     | 0.88     | **−11.21** | 1.195                 | 0           |
| SASDJ72 model1      | 52.3                   | MultiFoXS 2-state 2.91         | 0.20     | **1.98** | **2.87**    | 1.197                 | 0           |
| SASDJ72 model2      | 5.09                   | ″                             | 0.21     | 0.60     | **2.80**    | 1.147                 | 2.5 %       |
| SASDJY2 —          | **0.62 (chain stuck)** | CRYSOL 4.68                    | 0.48     | −5.78   | −4.62      | 1.173                 | **81.1 %**  |
| SASDKQ8 —          | 1.13                   | CRYSOL 14.3                    | 0.68     | −6.84   | −10.56     | 1.168                 | 0           |
| SASDLP4 fit1_model1 | 3.61                   | OLIGOMER 3-state 1.09          | 0.71     | −3.14   | **2.78**    | 1.206                 | 0           |
| SASDLP4 fit1_model2 | 1.18                   | ″                             | 0.30     | 1.66     | 2.43        | 1.079                 | 0           |
| SASDLP4 fit1_model3 | 5.92                   | ″                             | 0.51     | −0.67   | **2.79**    | 1.226                 | 0           |
| SASDLP4 fit2_model1 | 1.18                   | CRYSOL 1.06                    | 0.30     | 1.66     | 2.43        | 1.079                 | 0           |
| SASDMJ9 —          | 1.13                   | CRYSOL 1.37                    | **1.98** | −2.16   | −9.84      | 1.123                 | 0           |
| SASDMZ9 model1      | **11.9 (chain stuck)** | MultiFoXS 3-state 2.65         | 0.28     | −0.04   | 2.63        | 1.226                 | **96.8 %**  |
| SASDMZ9 model2      | 12.6                   | ″                             | 0.51     | 1.74     | 2.74        | 1.245                 | 0.1 %       |
| SASDMZ9 model3      | 67                     | ″                             | 0.06     | **2.00** | −1.21      | 1.271                 | 0           |
| SASDN32 —          | 0.902                  | FoXS 1.01                      | 0.37     | −2.45   | 1.39        | 1.190                 | 0           |
| SASDP48 —          | 40.5                   | CRYSOL 59.5                    | **1.98** | −8.44   | **2.77**    | 1.016                 | 0           |
| SASDR99 —          | 14.2                   | 29.6 (MDFF model)              | 0.12     | −2.20   | −9.68      | 1.176                 | 0           |
| SASDRN5 fit2_model1 | 2.84                   | SREFLEX 3.04                   | 0.30     | 1.22     | 0.78        | 1.188                 | 0.1 %       |
| SASDRN5 fit3_model1 | 13.9                   | CRYSOL 12.0                    | 0.07     | **2.00** | **2.85**    | 1.192                 | 0           |
| SASDRW2 —          | 2.02                   | CRYSOL 3.03                    | −0.23   | −7.39   | −2.31      | **0.780 (saturated)** | 0           |
| SASDTK5 fit2_model1 | 0.973                  | CRYSOL 1.14                    | 0.60     | 1.89     | 2.60        | 1.185                 | 0           |
| SASDTK5 fit3_model1 | 1.2                    | CRYSOL 1.17                    | 0.53     | 1.51     | 2.35        | 1.186                 | 0           |
| SASDTK5 fit4_model1 | 4.72                   | CRYSOL 5.22                    | 0.28     | **1.99** | **2.82**    | 1.205                 | 0           |
| SASDTK5 fit5_model1 | 1.53                   | CRYSOL 1.81                    | 0.45     | **1.97** | **2.78**    | 1.192                 | 0           |
| SASDTK5 fit6_model1 | 0.924                  | CRYSOL 1.03                    | 0.64     | 1.78     | 2.05        | 1.176                 | 0           |
| SASDTK5 fit7_model1 | 6.23                   | CRYSOL 6.09                    | 0.54     | **1.98** | **2.81**    | 1.200                 | 0           |
| SASDUN5 fit1_model1 | 1.85                   | OLIGOMER 2-state 2.21          | 1.05     | 1.77     | −0.39      | 1.182                 | 0           |
| SASDUN5 fit1_model2 | 15.3                   | ″                             | −0.31   | 0.96     | **−11.11** | 1.216                 | 0           |
| SASDV94 fit1        | 1.88                   | CRYSOL 1.28                    | 1.80     | −7.17   | 2.75        | 1.141                 | 0           |
| SASDVG2 fit1_model1 | 2.44                   | MultiFoXS 1-state 2.10         | 0.01     | 0.67     | −2.32      | 1.176                 | 0           |
| SASDVG2 fit2_model1 | 2.69                   | MultiFoXS 2-state 1.27         | 1.51     | −5.31   | −4.29      | **1.320 (saturated)** | 0           |
| SASDVG2 fit2_model2 | 4                      | ″                             | 0.89     | −2.35   | 1.75        | 1.168                 | 0           |
| SASDVG2 fit3_model1 | 6.77                   | MultiFoXS 3-state 1.29         | −0.10   | **2.00** | 2.26        | 1.202                 | 0           |
| SASDVG2 fit3_model2 | 5.98                   | ″                             | 0.46     | −1.38   | −2.68      | 1.198                 | 0           |
| SASDVG2 fit3_model3 | 24.4                   | ″                             | 0.29     | −0.82   | −1.92      | 1.202                 | 0           |
| SASDWZ9 —          | 0.589                  | Pepsi-SAXS 0.62                | 0.31     | −1.23   | −2.75      | 1.167                 | 0           |
| SASDX52 —          | 0.441                  | 0.70 (method unconfirmed)      | 0.81     | 1.63     | −6.21      | 1.074                 | 0.1 %       |
| SASDYW6 fit2        | 3.59                   | CRYSOL 3.74                    | 1.92     | 1.19     | **2.80**    | 1.206                 | 0           |
| SASDZC6 —          | 1.62                   | FoXS 1.68                      | 0.58     | −0.51   | −2.41      | **1.319 (saturated)** | 0           |
| SASDZZ9 fit1        | 19.8                   | CRYSOL ≈ 34.5                 | **1.99** | −0.83   | **2.78**    | 1.158                 | 0           |

**These MAPs are not all global, and not all chains are healthy.**

- **SASDMZ9 model1** (96.8 % divergent, EBFMI 0.0007) and **SASDJY2** (81 % divergent) are failed chains; their reported parameters are not reliable posterior summaries. For SASDMZ9 model1, the chain freezes in the δρ₃ ≈ upper-bound basin (φ ≈ φ_max), while a direct Nelder-Mead optimisation of the log posterior from the earlier result finds a much better mode (logπ 5518 vs 2717, χ² 6.50, every prior z-score within 1.3).
- **Many fits put δρ₃ at its upper bound** (~+2.8, i.e. φ ≈ φ_max): SASDA52, SASDBS6 model3-5, SASDEP6, SASDJ72, SASDLP4 model1/3, SASDMZ9 model2, SASDP48, SASDRN5 fit3, SASDTK5 fit4/5/7, SASDV94, SASDYW6, SASDZZ9. The bound is usually reached together with a poor or mediocre χ²: the cavity contrast is absorbing model-data mismatch (wrong conformer, missing ensemble members) rather than representing physical cavity hydration. On SASDZZ9 a 12-start Nelder-Mead search found a much better mode away from the bound (δρ₁ = −0.49, δρ₂ = 1.99, φ = 0.45; logπ −8655 vs −13134, χ² 14.65); the other bound-hitting fits have not been multi-start checked and should be treated as possibly local.
- δρ₃ at its **lower** bound (−11.1, empty cavities) appears in SASDBS6 model1/2, SASDJ62 and SASDUN5 model2.

## Ensemble and multi-model entries

BAYSOL fits **one rigid structure per run**. Many deposited fits are mixtures, however, and their χ² is the χ² of the *weighted mixture*. Fitting each member separately answers a different question ("how well does this one structure explain the whole curve?"), so a member's χ² is generally **expected** to be worse than the depositor's mixture χ², The gap indicates how strongly the curve depends on the other members. Bound-hitting δρ₃ (or δρ₁/δρ₂ at 2) in these runs is the sampler trying to make one structure represent a population.


| Entry   | Deposited fit                                   | Members (what each one is)                                                                                                 | Mixture χ²       | BAYSOL, member by member                         |
| --------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------- | -------------------------------------------------- |
| SASDBS6 | EOM/RANCH ensemble (`fit2`)                     | 5 conformers of ObgE with a flexible C-terminal domain, from a 50-member selected ensemble                                 | 11.3               | 61, 214, 21.9, 23.9, 215                         |
| SASDLP4 | OLIGOMER (`fit1`)                               | SodA monomer / dimer / tetramer from PDB 1D5N (23 / 46 / 92 kDa); the paper reports that the protein is mostly dimeric     | 1.09               | 3.61,**1.18**, 5.92                              |
| SASDLP4 | CRYSOL (`fit2`)                                 | the dimer alone (same coordinates as fit1 model2, same curve, hence the identical result)                                  | 1.06               | 1.18                                             |
| SASDEP6 | OLIGOMER                                        | glucosamine kinase open (volume fraction 0.59) and closed (0.41) conformations, with GlcN + ATP                            | 8.31               | **3.19** (open), 10.7 (closed)                   |
| SASDUN5 | OLIGOMER                                        | IMPDH tetramer (213 kDa) and octamer (426 kDa) with 10 mM IMP; the paper reports a 75:25 tetramer:octamer mixture          | 2.21               | **1.85** (tetramer), 15.3 (octamer)              |
| SASDMZ9 | MultiFoXS 3-state                               | 3 conformers of the flexible two-domain Sas20d1-2                                                                          | 2.65               | 11.9 (failed chain), 12.6, 67.0                  |
| SASDJ72 | MultiFoXS 2-state (BILBOMD models)              | 2 conformers of DNA ligase IIIα                                                                                           | 2.91               | 52.3,**5.09**                                    |
| SASDCQ2 | MultiFoXS 1-state (`fit2`) and 2-state (`fit3`) | Ca²⁺-calmodulin, flexible linker residues 77-81; fit2 is the best single conformer, fit3 the two states of the best pair | 0.85 / 0.79        | **0.82** (1-state); 2.59, 51.3 (2-state members) |
| SASDVG2 | MultiFoXS 1-, 2- and 3-state (`fit1-3`)         | Eap bound to a cathepsin-G tetramer; fit1 one conformer, fit2 two, fit3 three                                              | 2.10 / 1.27 / 1.29 | 2.44; 2.69, 4.00; 6.77, 5.98, 24.4               |

### What the member-by-member fits show

- **Where one member dominates the population, BAYSOL identifies it.** SASDLP4's dimer (1.18) is the only member that fits, matching the paper's mostly-dimer finding; SASDUN5's tetramer (1.85) fits and the octamer does not, matching the reported 75:25 split; SASDCQ2's 1-state MultiFoXS conformer fits at 0.82, as well as the depositor's 2-state mixture. SASDEP6's open state alone (3.19) even beats the deposited OLIGOMER mixture (8.31), but BAYSOL also fits the solvent contrasts and `c1`, so the two χ² values are not directly comparable.
- **Where the population is genuinely broad, no single member fits well.** SASDBS6 (EOM), SASDMZ9 and the multi-state SASDVG2/SASDJ72 members are 2–100× worse than their mixtures, with δρ parameters at bounds. These runs are a test of the forward model on realistic conformers, not of the deposited structural interpretation. A meaningful comparison needs a mixture likelihood (weights sampled alongside ξ), which BAYSOL does not have; until then, compare the *best* member with the mixture χ² and read the rest qualitatively.
- **Alternative single models are different.** SASDTK5 (six Fe-TPP-phen HasApf5 dimer geometries), SASDD88 (homology vs normal-mode model), SASDRN5 (AlphaFold vs SREFLEX-refined) and SASDJ62/SASDZZ9 are competing hypotheses, each meant to explain the curve as individual strutures. There BAYSOL's ranking can be compared directly with the depositor's: it agrees on SASDTK5 (lambda-trans1, `fit6`, is best for both: 0.92 vs CRYSOL 1.03), on SASDRN5 (refined 2.84 ≪ raw 13.9) and on SASDD88 (both models fit, the normal-mode model slightly better).

## Entry summary


| Entry   | Protein                                    | Notes                                                                                                  |
| --------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| SASDA52 | yeast ADH1 tetramer                        | assumed PBS recipe; beamline wavelength unit-slip corrected; CRYSOL overlay                            |
| SASDF42 | HSA + 2 somapacitan                        | HSA + two GH copies in one model; compared with the deposited fit (χ² 2.10; its header's 1.45 is χ) |
| SASDJ62 | XRCC1                                      | already-hydrogenated CHARMM model; glycerol converted from % v/v; no reference curve                   |
| SASDJ72 | DNA ligase IIIα                           | the two members of a MultiFoXS 2-state ensemble, fitted separately; concentration-merged data          |
| SASDMJ9 | FCoV Nsp7                                  | the reference case validated against CRYSOL                                                            |
| SASDMZ9 | Sas20d1-2 (flexible)                       | the three members of a MultiFoXS 3-state ensemble, fitted separately; SASBDB pH 7.0                    |
| SASDN32 | Sas20d2 + ligand                           | 5 mM maltoheptaose, a solute that previously had no volume data                                        |
| SASDV94 | phospholipase C (PLC H) + chaperone PLC R2 | only the atomistic chains of a mixed atomistic/dummy-bead model; merged injections                     |
| SASDWZ9 | SERF1a                                     | NMR conformer; speciated phosphate buffer + azide; only Pepsi-SAXS comparison                          |
| SASDX52 | FadD5 dimer                                | predicted dimer; q truncated at 0.17 Å⁻¹; reference χ² < 1 from an unconfirmed method             |
| SASDYW6 | Fba1 dimer                                 | AlphaFold3 model; 500 mM imidazole + NaCl (I ≈ 0.65 M); estimated PMSF volume                         |
| SASDZC6 | PDE6/GαT* complex                         | six-chain, four-species complex; estimated udenafil volume; FoXS reference χ² 1.68                   |
| SASDZZ9 | NodB                                       | crystal model with a poor reference agreement (χ² ≈ 34.5)                                           |
| SASDBS6 | ObgE (full length)                         | 5 members of an EOM ensemble (flexible C-terminal domain), fitted separately; 250 mM imidazole         |
| SASDCQ2 | Ca²⁺-calmodulin                          | MultiFoXS 1-state and 2-state members; 0.1 % NaN₃ + TCEP radiation protection                         |
| SASDD88 | M. tuberculosis LigA BRCT domain           | two alternative models (Phyre2 homology, elNémo normal mode); paper/SASBDB buffer conflict            |
| SASDEP6 | glucosamine kinase + GlcN + ATP            | OLIGOMER open/closed pair (0.59/0.41); 0.2 M D-glucosamine in the buffer                               |
| SASDJY2 | EcoKMcrA N-terminal domain                 | single CRYSOL model;**chain failed (81 % divergent)**                                                  |
| SASDKQ8 | ROSA de novo four-helix-bundle dimer       | single model; pre-hydrogenated; 5 % glycerol                                                           |
| SASDLP4 | SodA (superoxide dismutase)                | OLIGOMER monomer/dimer/tetramer + a CRYSOL dimer fit; 50 mM HEPES only                                 |
| SASDP48 | GRB2 N188D/N214D monomer                   | crystal monomer that fits poorly (deposited 59.5); pre-hydrogenated model (Pdb2pqr skipped)            |
| SASDR99 | AADC (DOPA decarboxylase) dimer            | MDFF-refined dimer; chain IDs repaired from CHARMM segment IDs                                         |
| SASDRN5 | NURC1                                      | AlphaFold model raw vs SREFLEX-refined; 50 mM sodium phosphate + 5 % glycerol                          |
| SASDRW2 | collagen peptide (POG)₁₀ trimer          | smallest structure in the suite (1059 atoms); histidine buffer at pH 6.0                               |
| SASDTK5 | HasApf5 + Fe-TPP-phen dimer                | six alternative dimer geometries; CHES–KOH pH 9.5; pre-hydrogenated                                   |
| SASDUN5 | M. smegmatis IMPDH                         | OLIGOMER tetramer/octamer with 10 mM IMP (+12 mM MgCl₂) in the buffer blank                           |
| SASDVG2 | Eap + cathepsin-G tetramer                 | MultiFoXS 1-, 2- and 3-state members; models extracted from an ensemble (`MODEL` ≠ 1)                 |

## Entries

### SASDA52: yeast alcohol dehydrogenase 1 (ADH1), PBS

```
julia --project=test/fitting_tests test/fitting_tests/SASDA52/SASDA52_fit1.jl
```

Fits the ADH1 tetramer (PDB 4W6Z, 347-residue chains; 24.89 mg/mL) with q ≤ 0.5 Å⁻¹ and lMax 45 (from the GNOM D_max of 89.3 Å), pH 7.4. **Unique:** the SASBDB entry only says "PBS", so the standard 1× PBS recipe (137 mM NaCl, 2.7 mM KCl, 10 mM Na₂HPO₄, 1.8 mM KH₂PO₄, each ±5 %) is assumed; the beamline wavelength "0.15" is read as a unit slip for 1.5 Å (8.27 keV); the experimental file is in nm⁻¹ and is converted. Overlays our MAP curve on SASBDB's CRYSOL fit1 (`res_fit1_comparison.png`).

### SASDF42: human serum albumin + somapacitan complex, MES/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDF42/SASDF42.jl
```

Fits a SASREF rigid-body model of HSA with two growth-hormone (somapacitan) copies, 6.3 mg/mL total, pH 6.5, 100 mM MES + 140 mM NaCl, q ≤ 0.5 Å⁻¹, lMax 70. **Unique:** a three-chain complex of two different proteins (the proteins are not buffer solutes, see above). Compared against the deposited fit column of the SASBDB `.fit` file, whose header quotes `ChiExp = 1.45`; recomputed from the file's own columns that is χ, i.e. χ² = 2.10.

### SASDJ62: XRCC1 (DNA-repair scaffold), glycerol buffer

```
julia --project=test/fitting_tests test/fitting_tests/SASDJ62/SASDJ62_model1.jl
```

Fits the 633-residue XRCC1 model 1 (monomer of 69.5 kDa, 5.9 mg/mL) in 200 mM NaCl, 20 mM Tris, 2 % glycerol, pH 7.5, q ≤ 0.5 Å⁻¹, lMax 107 (the largest in the suite). **Unique:** the PDB already carries CHARMM hydrogens, so Pdb2pqr is skipped (`ADD_HYDROGENS = false`); the "2 % glycerol" is converted to 0.274 M with a wide ±10 % uncertainty; D_max (212 Å) comes from the Cα hull because no GNOM file exists; SASBDB's measured mass (110 kDa) hints at a dimer but a monomer is modeled; no reference curve is bundled, so there is no comparison figure.

### SASDJ72: DNA ligase IIIα, two candidate models

```
julia --project=test/fitting_tests test/fitting_tests/SASDJ72/SASDJ72.jl
```

Fits the 922-residue ligase with both models of the depositor's MultiFoXS 2-state ensemble (BILBOMD conformers; mixture χ² 2.91; `model1` lMax 53, `model2` lMax 64) separately against the same curve in one run (q ≤ 0.30 Å⁻¹, pH 7.5, 150 mM NaCl, 25 mM Tris, 2 mM DTT, 10 % glycerol). **Unique:** a two-model comparison from a single script; the data are a concentration-merged curve (1–5 mg/mL); 10 % v/v glycerol becomes 1.369 M (±5 %), one of the most concentrated cosolutes in the suite. Each model is overlaid on the CRYSOL fit1 curve.

### SASDMJ9: feline coronavirus Nsp7 (validation case)

```
julia --project=test/fitting_tests test/fitting_tests/SASDMJ9/SASDMJ9.jl
```

Fits Nsp7 (chain B, 82 residues, 4.7 mg/mL) in 200 mM NaCl, 10 mM Tris, 5 mM DTT, pH 7.5, q ≤ 0.5 Å⁻¹, lMax 25. **Unique:** the reference case for the method and the script the other fits were modeled on. Under the current bounded-Beta δρ priors and profiled c1 the MAP χ² is 1.13 (16–84 % band 1.130–1.134), against CRYSOL's 1.37. It was 1.08 under the earlier LogNormal/Normal priors with a sampled c1. δρ₁ sits at its upper bound of 2. q is converted from nm⁻¹ and the X33 wavelength is 1.54 Å. Overlays CRYSOL's curve (`res_comparison.png`).

### SASDMZ9: Sas20d1-2, a flexible two-domain starch-binding protein

```
julia --project=test/fitting_tests test/fitting_tests/SASDMZ9/SASDMZ9.jl
```

Fits three deposited conformers (model1/2/3, lMax 48/68/35) one after another to the same curve, in PBS + 1 mM TCEP, q ≤ 0.3 Å⁻¹, and writes `res_model{1,2,3}.*`. **Unique:** the three models are the members of the depositor's MultiFoXS **3-state ensemble** (mixture χ² 2.65, from the `.dat` header); BAYSOL fits each alone (11.9 / 12.6 / 67.0), see "Ensemble and multi-model entries". The model column of the SASBDB `.fit` file is deliberately ignored, so there is no overlay. **pH 7.0** (changed 2026-10-01): the paper's "PBS … pH 7.4" recipe is from its mass-spectrometry methods, while SASBDB gives pH 7 for the SAXS buffer; the recipe's NaCl/KCl and 11.8 mM total phosphate are kept and the phosphate is re-split at pH 7.0. Model1's chain fails (96.8 % divergent).

### SASDN32: Sas20d2 with 5 mM maltoheptaose

```
julia --project=test/fitting_tests test/fitting_tests/SASDN32/SASDN32.jl
```

Fits Sas20d2 (26.3 kDa, 10 mg/mL), same PBS + TCEP buffer as SASDMZ9, q ≤ 0.3 Å⁻¹, lMax 22. **Unique:** the buffer includes 5 mM maltoheptaose, a solute that was previously left out because it had no volume data; it now uses the measured 694.8 ± 5.8 cm³/mol (Hourston 1967, thesis Table 6.1) and, at 5 mM, it is a real contribution to the solvent electron density. Single fit, no reference overlay.

### SASDV94: phospholipase C (PLC H) bound to its chaperone PLC R2, merged injections

```
julia --project=test/fitting_tests test/fitting_tests/SASDV94/SASDV94_fit1.jl
```

Fits the atomistic chains B (PLC H, residues 27-730) and D (PLC R2, residues 65-207; 1:1 complex) in 100 mM NaCl, 25 mM Tris, 3 mM β-mercaptoethanol, pH 7.5, 10 keV, q ≤ 0.434 Å⁻¹, lMax 39. **Unique:** the deposited model mixes real chains with two CA-only dummy-bead chains, so the script fits an extracted `SASDV94_fit1_model1_PLCH_R2.pdb` containing only the atomistic chains; the merged 3.5/7/14 mg/mL injections have no single concentration (series mean, widened uncertainty); the mercaptoethanol volume is itself an estimate (69.0 ± 3.5). Overlays CRYSOL (χ² 1.284).

### SASDWZ9: SERF1a (small NMR-structured protein), sodium phosphate + azide

```
julia --project=test/fitting_tests test/fitting_tests/SASDWZ9/SASDWZ9.jl
```

Fits one NMR conformer (MODEL 37, 62 residues, 15 mg/mL) at 15 keV, pH 6.8, q ≤ 0.35 Å⁻¹, lMax 35. **Unique:** the 20 mM sodium phosphate is split into H₂PO₄⁻ and HPO₄²⁻ (Goldberg pK₂ with a Davies correction, see "Buffers" above; HPO₄²⁻ fraction 0.43) and 0.02 % NaN₃ is added; it is the only fit compared against Pepsi-SAXS (not CRYSOL); its NaN₃ and NaH₂PO₄ entries have no stated uncertainty (table default is used).

### SASDX52: FadD5 (fatty acyl-CoA synthetase) dimer

```
julia --project=test/fitting_tests test/fitting_tests/SASDX52/SASDX52.jl
```

Fits an AlphaFold-derived, depositor-docked dimer (4 mg/mL) in 500 mM NaCl, 20 mM HEPES, 5 mM MgCl₂, 1 mM mercaptoethanol, pH 7.5, 13 keV, lMax 35. **Unique:** only the low-q region is fitted (q ≤ 0.17 Å⁻¹); the bundled reference curve has χ² = 0.699 (below 1) and its method is not confirmed to be CRYSOL, so the overlay is labelled "SASBDB fit1"; the model is predicted rather than experimentally determined.

### SASDYW6: fructose-bisphosphate aldolase (Fba1) dimer, imidazole buffer

```
julia --project=test/fitting_tests test/fitting_tests/SASDYW6/SASDYW6_fit2.jl
```

Fits the AlphaFold3 dimer (`fit2`; the GASBOR dummy-bead `fit1` is not fitted) at pH 8.5, 13.2 keV, q ≤ 0.25 Å⁻¹, lMax 24. **Unique:** the highest ionic strength in the suite (≈ 0.67 M): 500 mM NaCl, 500 mM imidazole (with ~23 mM Cl⁻ counter-ion) and 50 mM sodium phosphate speciated at pH 8.5; SASBDB's structured buffer field (Tris/NaCl, pH 8.0) conflicts with the entry's own description and is most likely copied from the sibling SASDYV6, so the entry description is used; 1 mM PMSF is included with an **estimated** volume (127.2 ± 5.0 cm³/mol, geometric estimate, not measured). Compared against the CRYSOL fit (χ² 3.737).

### SASDZC6: PDE6 / transducin-α* complex with udenafil

```
julia --project=test/fitting_tests test/fitting_tests/SASDZC6/SASDZC6.jl
```

Fits PDB 7JSN (PDE6α, PDE6β, 2 × PDE6γ, 2 × GαT*; 0.3 mg/mL PDE6) in 100 mM NaCl, 25 mM Tris, 2 mM MgCl₂, 2 % glycerol, pH 8.0, 11.3 keV (stated directly), q ≤ 0.3 Å⁻¹, lMax 49. **Unique:** a six-chain complex of four protein species (at pH 8.0 its chains' N-terminus pKas straddle the pH, so Pdb2pqr runs once per terminus-flag group and the chains are merged); the 3 µM udenafil inhibitor has no measured volume, so an **estimate** (399.6 ± 16.0 cm³/mol) is used; the bundled reference is FoXS (χ² 1.676) but it is not plotted here.

### SASDZZ9: NodB (chitooligosaccharide deacetylase), poorly matching crystal model

```
julia --project=test/fitting_tests test/fitting_tests/SASDZZ9/SASDZZ9_fit1.jl
```

Fits the 404-residue crystal-structure model (PDB 8YFP, monomer) in 100 mM NaCl, 20 mM Tris at a 0.137 nm wavelength, q ≤ 0.39 Å⁻¹, lMax 28. **Unique:** the deposited reference fit for this rigid model is poor (χ² ≈ 34.5) while an ab initio bead model gets ≈ 0.002 (not used), so the deposited structure does not describe the solution well. Overlays the CRYSOL fit1 curve.
