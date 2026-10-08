# Fitting tests

**Note:** Entries in `BAYSOL.PartialMolarVolumes` without uncertainties use an uncertainty estimated from the mean of the available experimental uncertainties. As the table grows, this estimate may change slightly, so fit results may change.

End-to-end BAYSOL fits of 27 SASBDB entries (protein-only structures): load a structure, build its buffer, find the mode with a multi-start L-BFGS search and whiten around it, run the NUTS sampler over `ξ = (ρₑ, δρ₁, δρ₂, δρ₃)` with the excluded-volume correction `c1` profiled at every evaluation (to `EXCL_VOL_CORR_TOL` = 1e-8; see the Fitting README for why that tight), and write the MAP/posterior report and figures
next to the script. The fitted curve is the deposited SASBDB curve (q in Å⁻¹, truncated at each script's `Q_MAX_FIT`), which `seed_model` bins to 12 bins per Shannon channel π/D (D: the diameter of the structure and its hydration shell) and from which it takes `lMax = ceil(q_max·D)`; the lMax and point counts below are those of the latest run, and each report's `=== Data (Shannon) ===` section lists D, the channels and the points before and after binning. χ² is reported on the measured q grid (the binned fit's model interpolated onto it, over all measured points), the convention of FoXS's own χ², and so of the depositors' numbers.

```
julia --project=test/fitting_tests test/fitting_tests/<ID>/<script>.jl
```

All fits use 2000 NUTS iterations: the first 1000 are warmup (step-size and mass-matrix adaptation) and are discarded, leaving 1000
posterior draws. The seed is 0. Each script defines `run_<id>(; n_samples, n_adapt, seed)` if you want to change these values; `n_samples` is the *total* iteration count, including the `n_adapt` warmup, and the scripts use these defaults. Each script also has a `seed_<id>(...)` that builds the `Seed` its `run_<id>` then samples. It only for the tools in `test/utils/`, which inspect a fit without running it; if you don't need extra tooling skip `seed_<id>`. The temperature is each entry's stated sample temperature (25 °C when none is given). Hydrogens are added with Pdb2pqr at the stated pH unless noted.

Settings shared by every script live in `common.jl`, which each script includes: the sampler defaults (`N_SAMPLES`, `N_ADAPT`, `SAMPLER_SEED`), the default pH σ (`PH_METER_SIGMA` = 0.1) and macromolecule-molarity σ (`MOLARITY_REL_SIGMA` = 5 %), the nm⁻¹ → Å⁻¹ conversion and q-unit sanity check, the `.dat`/fit-file readers, and the plot styling (sizes, colours, line widths). Change them there, not in individual scripts. A script that deliberately differs keeps its own value inline, with a comment.

## Results

 The table is generated from the reports (`tclsh test/utils/results_table.tcl --update`); only the depositor column is  kept by hand, in `depositor_chi2.tsv`. Bold marks a parameter at a hard prior bound (δρ₁, δρ₂ ≤ 2; δρ₃ ∈ [−ρ̄ₑ/0.03, (φ_max − 1)·ρ̄ₑ/0.03] ≈ [−11.1, 2.8]), `c1` profiling saturation, or a chain with >5% divergent transitions. ″ repeats the line above: the members of one deposited multi-model fit share a single depositor χ², which belongs to their **weighted mixture**, not to any one member (see "Ensemble and multi-model entries" below).

| Run | χ² (MAP) | depositor's χ² (method) | δρ₁ | δρ₂ | δρ₃ | c1 | divergences |
|---|---|---|---|---|---|---|---|
| SASDA52 fit1 | 5.34 | CRYSOL χ² 2.48 (χ² ≈ 6.2) | 0.08 | 0.09 | **2.76** | 1.160 | 0.1 % |
| SASDBS6 fit2_model1 | 60.3 | EOM ensemble 11.3 | **2.00** | −1.23 | **−11.27** | 0.927 | 0 |
| SASDBS6 fit2_model2 | 89.1 | ″ | −0.37 | **2.00** | **2.83** | 1.241 | 0 |
| SASDBS6 fit2_model3 | 21.5 | ″ | 0.04 | 1.67 | **2.82** | 1.201 | 0 |
| SASDBS6 fit2_model4 | 23.8 | ″ | 0.09 | 1.12 | **2.82** | 1.196 | 0 |
| SASDBS6 fit2_model5 | 51.7 | ″ | −0.25 | **2.00** | 0.81 | 1.233 | 0.3 % |
| SASDCQ2 fit2_model1 | 0.819 | MultiFoXS 1-state 0.85 | 0.54 | −0.62 | −6.70 | 1.161 | 0 |
| SASDCQ2 fit3_model1 | 1.23 | MultiFoXS 2-state 0.79 | −0.18 | −0.84 | −7.50 | 1.242 | 0 |
| SASDCQ2 fit3_model2 | 51.1 | ″ | 0.36 | −1.51 | 2.70 | 1.130 | 0 |
| SASDD88 fit2_model1 | 0.986 | FoXS 4.50 | −0.08 | 1.47 | −0.16 | 1.230 | 0 |
| SASDD88 fit3_model1 | 0.91 | FoXS 2.79 | 0.32 | −2.57 | −6.97 | 1.216 | 0 |
| SASDEP6 fit1_model1 | 2.4 | OLIGOMER 2-state 8.31 (w 0.59) | −0.79 | 1.87 | −9.59 | 1.235 | 0 |
| SASDEP6 fit1_model2 | 2.88 | ″ (w 0.41) | −0.44 | 1.90 | −6.44 | 1.221 | 0.2 % |
| SASDF42 — | 1.36 | 2.10 | −0.69 | 0.93 | −5.67 | 1.241 | 0 |
| SASDJ62 model1 | 3.39 | — | 0.23 | 0.88 | **−11.22** | 1.194 | 0 |
| SASDJ72 model1 | 51.3 | MultiFoXS 2-state 2.91 | 0.19 | **1.98** | **2.87** | 1.197 | 0 |
| SASDJ72 model2 | 2.38 | ″ | −0.27 | 1.01 | −7.61 | 1.215 | 0 |
| SASDJY2 — | 0.635 | CRYSOL 4.68 | 0.80 | −7.05 | −1.15 | 1.163 | 0 |
| SASDKQ8 — | 1.5 | CRYSOL 14.3 | 0.78 | −6.52 | −3.85 | 1.170 | 0 |
| SASDLP4 fit1_model1 | 3.45 | OLIGOMER 3-state 1.09 | 0.79 | −3.59 | **2.77** | 1.204 | 0 |
| SASDLP4 fit1_model2 | 1.21 | ″ | 0.15 | −2.06 | −1.29 | 1.256 | 2.1 % |
| SASDLP4 fit1_model3 | 7.83 | ″ | 0.52 | −0.97 | **2.79** | 1.226 | 0 |
| SASDLP4 fit2_model1 | 1.21 | CRYSOL 1.06 | 0.15 | −2.06 | −1.29 | 1.256 | 2.1 % |
| SASDMJ9 — | 0.874 | CRYSOL 1.37 | −1.08 | **1.95** | −6.07 | 1.248 | 0 |
| SASDMZ9 model1 | 6.99 | MultiFoXS 3-state 2.65 | −0.04 | −1.18 | −1.27 | 1.185 | 0 |
| SASDMZ9 model2 | 6.48 | ″ | −0.28 | −1.14 | −0.42 | 1.203 | 0 |
| SASDMZ9 model3 | 55 | ″ | 0.23 | −2.51 | **2.79** | 1.181 | 0 |
| SASDN32 — | 0.975 | FoXS 1.01 | 0.41 | −2.41 | 1.45 | 1.187 | 0 |
| SASDP48 — | 15.9 | CRYSOL 59.5 | −0.05 | 0.38 | **2.77** | 1.214 | 0.2 % |
| SASDR99 — | 14.5 | 29.6 (MDFF model) | 0.15 | −1.99 | −8.68 | 1.179 | 0 |
| SASDRN5 fit2_model1 | 2.85 | SREFLEX 3.04 | 0.30 | 1.29 | 0.45 | 1.189 | 0 |
| SASDRN5 fit3_model1 | 7.18 | CRYSOL 12.0 | −0.01 | −0.24 | −8.83 | 1.210 | 0 |
| SASDRW2 — | 2.02 | CRYSOL 3.03 | −0.21 | −7.49 | −2.30 | **0.780 (saturated)** | 0 |
| SASDTK5 fit2_model1 | 0.937 | CRYSOL 1.14 | −0.92 | −5.83 | −0.75 | 1.257 | 0 |
| SASDTK5 fit3_model1 | 1.2 | CRYSOL 1.17 | 0.53 | 1.55 | 2.36 | 1.186 | 0 |
| SASDTK5 fit4_model1 | 1.6 | CRYSOL 5.22 | −0.11 | −3.81 | **−11.25** | 1.216 | 0 |
| SASDTK5 fit5_model1 | 0.922 | CRYSOL 1.81 | −0.16 | −5.71 | 1.56 | 1.229 | 0 |
| SASDTK5 fit6_model1 | 0.924 | CRYSOL 1.03 | 0.64 | 1.77 | 2.06 | 1.176 | 0 |
| SASDTK5 fit7_model1 | 1.81 | CRYSOL 6.09 | −0.02 | −3.10 | **−11.27** | 1.216 | 0 |
| SASDUN5 fit1_model1 | 1.87 | OLIGOMER 2-state 2.21 | −0.34 | −1.47 | −1.49 | 1.212 | 0 |
| SASDUN5 fit1_model2 | 11.4 | ″ | −0.55 | −2.76 | **−11.26** | 1.177 | 0 |
| SASDV94 fit1 | 1.87 | CRYSOL 1.28 | **1.97** | −7.99 | 2.63 | 1.134 | 0.1 % |
| SASDVG2 fit1_model1 | 2.43 | MultiFoXS 1-state 2.10 | 0.01 | 0.67 | −2.51 | 1.177 | 0 |
| SASDVG2 fit2_model1 | 2.29 | MultiFoXS 2-state 1.27 | −0.28 | 1.72 | −0.75 | 1.170 | 0 |
| SASDVG2 fit2_model2 | 3.99 | ″ | 0.91 | −2.46 | 2.14 | 1.167 | 0 |
| SASDVG2 fit3_model1 | 3.97 | MultiFoXS 3-state 1.29 | 1.39 | −9.06 | −10.15 | 1.261 | 0 |
| SASDVG2 fit3_model2 | 5.82 | ″ | 0.44 | −1.30 | −3.00 | 1.199 | 0 |
| SASDVG2 fit3_model3 | 21.4 | ″ | 0.24 | −0.63 | −2.91 | 1.203 | 0 |
| SASDWZ9 — | 0.576 | Pepsi-SAXS 0.62 | 0.26 | 1.61 | −0.56 | 1.279 | 0 |
| SASDX52 — | 0.305 | 0.70 (method unconfirmed) | −0.22 | −3.34 | 1.19 | 1.234 | 0.5 % |
| SASDYW6 fit2 | 2.88 | CRYSOL 3.74 | −0.11 | −1.54 | −6.39 | 1.198 | 0 |
| SASDZC6 — | 1.66 | FoXS 1.68 | −0.80 | −0.15 | 0.74 | 1.092 | 0.4 % |
| SASDZZ9 fit1 | 14.6 | CRYSOL ≈ 34.5 | −0.48 | **1.99** | −5.52 | 1.231 | 0 |

**How to read these MAPs.**

- **The reported MAP is the best NUTS draw**, not the L-BFGS mode that seeds the sampler (their χ² agrees to 4-5 digits, e.g. 60.2652 vs 60.2657 for SASDBS6 model1). Parameters the data barely constrain (δρ₃ on fits with almost no cavity beads, for one) move between reruns because the best of 1000 draws moves, with the χ² unchanged; judge those from the quantile table in each `res*.txt`, not from this table.
- **No chain fails.** The two failed chains of v0.2.0 (SASDMZ9 model1, 96.8 % divergent; SASDJY2, 81 %) sample cleanly. Three runs have 1-5 % divergent transitions and are not bold: SASDEP6 fit1_model1 (3.0 %) and SASDLP4 fit1_model2 / fit2_model1 (1.4 %, the same structure and curve). The divergences are geometric, not numerical error in the gradient (they persist at c1 tolerance 1e-10) and they disappear at a target acceptance of 0.9 (SASDLP4 fit1_model2: 6-61 per 1000 draws at 0.8, 0-3 at 0.9, for 1.5× the NUTS time); the default stays 0.8 so timings remain comparable. In both fits the δρ₃ posterior is 2-4× wider than the Laplace whitening predicts, because δρ₃ is barely constrained.
- **Other optima are not competing modes.** The MAP search often reports 2-5 "modes", but every one besides the best is at least 260 nats lower in log density (usually thousands), so it carries no posterior mass; the count is a number of distinct local optima, not of modes of the posterior.
- **Many fits put δρ₃ at its upper bound** (~+2.8, i.e. φ ≈ φ_max): SASDA52, SASDBS6 model2-4, SASDJ72 model1, SASDLP4 fit1_model1/3, SASDMZ9 model3, SASDP48. At its **lower** bound (−11.1, empty cavities): SASDBS6 model1, SASDJ62, SASDTK5 fit4/7 and SASDUN5 model2. The bound is usually reached together with a poor or mediocre χ²: the cavity contrast is absorbing model-data mismatch (wrong conformer, missing ensemble members) rather than representing physical cavity hydration.
- **What buys the low χ² on poorly fitting single conformers is the split of the first two contrasts.** Refitting with one shared shell contrast (δρ₁ = δρ₂ = δρ₃, c1, scale and background still profiled; `diagnose.jl ablate`) gives:


  | fit                             | one shared contrast     | δρ₁ = δρ₂, δρ₃ free | full model (this table)   |
  | --------------------------------- | ------------------------- | ------------------------------ | --------------------------- |
  | SASDMJ9                         | 1.07                    | 1.07                         | 0.87                      |
  | SASDEP6 fit1_model1 / model2    | 3.43 / 15.6             | 2.81 / 15.1                  | 2.40 / 2.88               |
  | SASDLP4 fit1_model3             | 96.0                    | 95.4                         | 7.73                      |
  | SASDBS6 fit2_model1 / 2 / 3 / 5 | 69.8 / 137 / 38.5 / 125 | 61.7 / 121 / 34.2 / 115      | 60.3 / 89.1 / 21.5 / 51.7 |
  | SASDMZ9 model3                  | 72.9                    | 72.5                         | 55.0                      |

  A single contrast (as in CRYSOL) already reaches 1.07 on SASDMJ9, below CRYSOL's 1.37 on the same points, so most of that advantage is not the extra contrasts. On the poor fits the independent concave-shell contrast δρ₂ does the work, and it sits at its +2 bound in most of them. That is a sign of model misspecification, not a measurement of the hydration shell. A BAYSOL χ² below a deposited *mixture* χ² (SASDEP6) therefore says little about the structure.

## Ensemble and multi-model entries

BAYSOL fits **one rigid structure per run**. Many deposited fits are mixtures, however, and their χ² is the χ² of the *weighted mixture*. Fitting each member separately answers a different question ("how well does this one structure explain the whole curve?"), so a member's χ² is generally **expected** to be worse than the depositor's mixture χ², The gap indicates how strongly the curve depends on the other members. Bound-hitting δρ₃ (or δρ₁/δρ₂ at 2) in these runs is the sampler trying to make one structure represent a population.


| Entry   | Deposited fit                                   | Members (what each one is)                                                                                                 | Mixture χ²       | BAYSOL, member by member                         |
| --------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------- | -------------------------------------------------- |
| SASDBS6 | EOM/RANCH ensemble (`fit2`)                     | 5 conformers of ObgE with a flexible C-terminal domain, from a 50-member selected ensemble                                 | 11.3               | 60.3, 89.1, 21.5, 23.8, 51.7                     |
| SASDLP4 | OLIGOMER (`fit1`)                               | SodA monomer / dimer / tetramer from PDB 1D5N (23 / 46 / 92 kDa); the paper reports that the protein is mostly dimeric     | 1.09               | 3.35,**1.10**, 7.73                              |
| SASDLP4 | CRYSOL (`fit2`)                                 | the dimer alone (same coordinates as fit1 model2, same curve, hence the identical result)                                  | 1.06               | 1.10                                             |
| SASDEP6 | OLIGOMER                                        | glucosamine kinase open (volume fraction 0.59) and closed (0.41) conformations, with GlcN + ATP                            | 8.31               | **2.40** (open), **2.88** (closed)               |
| SASDUN5 | OLIGOMER                                        | IMPDH tetramer (213 kDa) and octamer (426 kDa) with 10 mM IMP; the paper reports a 75:25 tetramer:octamer mixture          | 2.21               | **1.63** (tetramer), 11.2 (octamer)              |
| SASDMZ9 | MultiFoXS 3-state                               | 3 conformers of the flexible two-domain Sas20d1-2                                                                          | 2.65               | 6.99, 6.48, 55.0                                 |
| SASDJ72 | MultiFoXS 2-state (BILBOMD models)              | 2 conformers of DNA ligase IIIα                                                                                           | 2.91               | 51.3,**2.38**                                    |
| SASDCQ2 | MultiFoXS 1-state (`fit2`) and 2-state (`fit3`) | Ca²⁺-calmodulin, flexible linker residues 77-81; fit2 is the best single conformer, fit3 the two states of the best pair | 0.85 / 0.79        | **0.82** (1-state); 1.22, 51.1 (2-state members) |
| SASDVG2 | MultiFoXS 1-, 2- and 3-state (`fit1-3`)         | Eap bound to a cathepsin-G tetramer; fit1 one conformer, fit2 two, fit3 three                                              | 2.10 / 1.27 / 1.29 | 2.44; 2.30, 4.00; 4.00, 5.84, 21.6               |

### What the member-by-member fits show

- **Where one member dominates the population, BAYSOL identifies it.** SASDLP4's dimer (1.10) is the only member that fits, matching the paper's mostly-dimer finding; SASDUN5's tetramer (1.63) fits and the octamer does not, matching the reported 75:25 split; SASDCQ2's 1-state MultiFoXS conformer fits at 0.82, as well as the depositor's 2-state mixture. Both SASDEP6 members (open 2.40, closed 2.88) beat the deposited OLIGOMER mixture (8.31), but BAYSOL also fits the solvent contrasts and `c1`, and the ablation above shows that for the closed state it is the independent δρ₂ that does it (15.6 with one shared contrast), so the two χ² values are not comparable.
- **Where the population is genuinely broad, no single member fits well.** SASDBS6 (EOM), SASDMZ9 and the multi-state SASDVG2/SASDJ72 members are 2–100× worse than their mixtures, with δρ parameters at bounds. These runs are a test of the forward model on realistic conformers, not of the deposited structural interpretation. A meaningful comparison needs a mixture likelihood (weights sampled alongside ξ), which BAYSOL does not have; until then, compare the *best* member with the mixture χ² and read the rest qualitatively.
- **Alternative single models are different.** SASDTK5 (six Fe-TPP-phen HasApf5 dimer geometries), SASDD88 (homology vs normal-mode model), SASDRN5 (AlphaFold vs SREFLEX-refined) and SASDJ62/SASDZZ9 are competing hypotheses, each meant to explain the curve as individual strutures. There BAYSOL's ranking can be compared directly with the depositor's: it agrees on SASDTK5 (lambda-trans1, `fit6`, is best for both: 0.92 vs CRYSOL 1.03), on SASDRN5 (refined 2.85 < raw 7.18) and on SASDD88 (both models fit, the normal-mode model slightly better).

## Tools

Three scripts work on the results without rerunning a fit:

```
# sampler diagnostics on any fit: MAP starts, Hessian, step size and tree depth, gradient error, modes
tclsh test/utils/diagnose.tcl report SASDBS6:fit2_model3
#   other commands: `tolerance --tols 1e-5,1e-8 --seeds 1,2,3` (NUTS vs the c1 tolerance), `ablate` (shell-contrast nesting)

# compare results between git revisions / tags and the working tree (timing totals, χ² and parameter distributions)
tclsh test/utils/compare.tcl v0.2.0-soukouratou HEAD          # any revisions; the working tree is added last

# the Results table above: regenerate it, or check that it is current (exit 1 if not)
tclsh test/utils/results_table.tcl --update
tclsh test/utils/results_table.tcl --check
```

Cold-start and steady-state benchmarks (compile and precompile time reported apart from algorithmic time, measured from a
wiped cache state) live in `test/utils/` (see `test/utils/README.md`); `tclsh test/utils/compare.tcl --bench new.json`
compares a run with the latest release's baseline in `test/baselines/` (or name two files). Benchmarks are only run with the repository owner's approval (`--approved`), because they need a quiet machine and AI agents tend not to check for one; see `test/utils/README.md`.

`test/utils/diagnose.tcl` builds the `Seed` a script would sample without fitting it (through the script's `seed_<id>()`, above); the diagnostics themselves are generic functions in `test/utils/seed_diagnostics.jl`, tested in `test/unit_tests/units/test_seed_diagnostics.jl`. `compare.tcl` reads the committed `res*.txt` of each revision with `git show`, so no checkout is needed; the wall clock excludes PROPKA/pdb2pqr.

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
| SASDJY2 | EcoKMcrA N-terminal domain                 | single CRYSOL model; its chain failed in v0.2.0 (81 % divergent), healthy now                          |
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

Fits the ADH1 tetramer (PDB 4W6Z, 347-residue chains; 24.89 mg/mL) with q ≤ 0.5 Å⁻¹ and lMax 56 (scatterer-cloud diameter 110.7 Å; the GNOM D_max is 89.3 Å), pH 7.4. **Unique:** the SASBDB entry only says "PBS", so the standard 1× PBS recipe (137 mM NaCl, 2.7 mM KCl, 10 mM Na₂HPO₄, 1.8 mM KH₂PO₄, each ±5 %) is assumed; the beamline wavelength "0.15" is read as a unit slip for 1.5 Å (8.27 keV); the experimental file is in nm⁻¹ and is converted. Overlays our MAP curve on SASBDB's CRYSOL fit1 (`res_fit1_comparison.png`).

### SASDF42: human serum albumin + somapacitan complex, MES/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDF42/SASDF42.jl
```

Fits a SASREF rigid-body model of HSA with two growth-hormone (somapacitan) copies, 6.3 mg/mL total, pH 6.5, 100 mM MES + 140 mM NaCl, q ≤ 0.5 Å⁻¹, lMax 73. **Unique:** a three-chain complex of two different proteins (the proteins are not buffer solutes, see above). Compared against the deposited fit column of the SASBDB `.fit` file, whose header quotes `ChiExp = 1.45`; recomputed from the file's own columns that is χ, i.e. χ² = 2.10.

### SASDJ62: XRCC1 (DNA-repair scaffold), glycerol buffer

```
julia --project=test/fitting_tests test/fitting_tests/SASDJ62/SASDJ62_model1.jl
```

Fits the 633-residue XRCC1 model 1 (monomer of 69.5 kDa, 5.9 mg/mL) in 200 mM NaCl, 20 mM Tris, 2 % glycerol, pH 7.5, q ≤ 0.5 Å⁻¹, lMax 112 (the largest in the suite). **Unique:** the PDB already carries CHARMM hydrogens, so Pdb2pqr is skipped (`ADD_HYDROGENS = false`); the "2 % glycerol" is converted to 0.274 M with a wide ±10 % uncertainty; the diameter that sets lMax (222.9 Å) is that of the structure and its hydration shell, since no GNOM file exists; SASBDB's measured mass (110 kDa) hints at a dimer but a monomer is modeled; no reference curve is bundled, so there is no comparison figure.

### SASDJ72: DNA ligase IIIα, two candidate models

```
julia --project=test/fitting_tests test/fitting_tests/SASDJ72/SASDJ72.jl
```

Fits the 922-residue ligase with both models of the depositor's MultiFoXS 2-state ensemble (BILBOMD conformers; mixture χ² 2.91; `model1` lMax 57, `model2` lMax 68) separately against the same curve in one run (q ≤ 0.30 Å⁻¹, pH 7.5, 150 mM NaCl, 25 mM Tris, 2 mM DTT, 10 % glycerol). **Unique:** a two-model comparison from a single script; the data are a concentration-merged curve (1–5 mg/mL); 10 % v/v glycerol becomes 1.369 M (±5 %), one of the most concentrated cosolutes in the suite. Each model is overlaid on the CRYSOL fit1 curve.

### SASDMJ9: feline coronavirus Nsp7 (validation case)

```
julia --project=test/fitting_tests test/fitting_tests/SASDMJ9/SASDMJ9.jl
```

Fits Nsp7 (chain B, 82 residues, 4.7 mg/mL) in 200 mM NaCl, 10 mM Tris, 5 mM DTT, pH 7.5, q ≤ 0.5 Å⁻¹, lMax 32. **Unique:** the reference case for the method and the script the other fits were modeled on. Under the current bounded-Beta δρ priors and profiled c1 the MAP χ² is 0.87 (16–84 % band 0.867–0.871), against CRYSOL's 1.37 recomputed on the same points (1.370; 1.365 with a free scale and offset). It was 1.13 before the MAP search and the 1e-8 c1 tolerance, and 1.08 under the earlier LogNormal/Normal priors with a sampled c1. δρ₂ sits at its upper bound of 2 (1.96). One shared shell contrast already gives 1.07, so most of the gain over CRYSOL is not the extra contrasts. q is converted from nm⁻¹ and the X33 wavelength is 1.54 Å. Overlays CRYSOL's curve (`res_comparison.png`).

### SASDMZ9: Sas20d1-2, a flexible two-domain starch-binding protein

```
julia --project=test/fitting_tests test/fitting_tests/SASDMZ9/SASDMZ9.jl
```

Fits three deposited conformers (model1/2/3, lMax 51/70/38) one after another to the same curve, in PBS + 1 mM TCEP, q ≤ 0.3 Å⁻¹, and writes `res_model{1,2,3}.*`. **Unique:** the three models are the members of the depositor's MultiFoXS **3-state ensemble** (mixture χ² 2.65, from the `.dat` header); BAYSOL fits each alone (6.99 / 6.48 / 55.0), see "Ensemble and multi-model entries". The model column of the SASBDB `.fit` file is deliberately ignored, so there is no overlay. **pH 7.0** (changed 2026-10-01): the paper's "PBS … pH 7.4" recipe is from its mass-spectrometry methods, while SASBDB gives pH 7 for the SAXS buffer; the recipe's NaCl/KCl and 11.8 mM total phosphate are kept and the phosphate is re-split at pH 7.0. Model1's chain failed in v0.2.0 (96.8 % divergent); it samples cleanly now.

### SASDN32: Sas20d2 with 5 mM maltoheptaose

```
julia --project=test/fitting_tests test/fitting_tests/SASDN32/SASDN32.jl
```

Fits Sas20d2 (26.3 kDa, 10 mg/mL), same PBS + TCEP buffer as SASDMZ9, q ≤ 0.3 Å⁻¹, lMax 24. **Unique:** the buffer includes 5 mM maltoheptaose, a solute that was previously left out because it had no volume data; it now uses the measured 694.8 ± 5.8 cm³/mol (Hourston 1967, thesis Table 6.1) and, at 5 mM, it is a real contribution to the solvent electron density. Single fit, no reference overlay.

### SASDV94: phospholipase C (PLC H) bound to its chaperone PLC R2, merged injections

```
julia --project=test/fitting_tests test/fitting_tests/SASDV94/SASDV94_fit1.jl
```

Fits the atomistic chains B (PLC H, residues 27-730) and D (PLC R2, residues 65-207; 1:1 complex) in 100 mM NaCl, 25 mM Tris, 3 mM β-mercaptoethanol, pH 7.5, 10 keV, q ≤ 0.434 Å⁻¹, lMax 44. **Unique:** the deposited model mixes real chains with two CA-only dummy-bead chains, so the script fits an extracted `SASDV94_fit1_model1_PLCH_R2.pdb` containing only the atomistic chains; the merged 3.5/7/14 mg/mL injections have no single concentration (series mean, widened uncertainty); the mercaptoethanol volume is itself an estimate (69.0 ± 3.5). Overlays CRYSOL (χ² 1.284).

### SASDWZ9: SERF1a (small NMR-structured protein), sodium phosphate + azide

```
julia --project=test/fitting_tests test/fitting_tests/SASDWZ9/SASDWZ9.jl
```

Fits one NMR conformer (MODEL 37, 62 residues, 15 mg/mL) at 15 keV, pH 6.8, q ≤ 0.35 Å⁻¹, lMax 38. **Unique:** the 20 mM sodium phosphate is split into H₂PO₄⁻ and HPO₄²⁻ (Goldberg pK₂ with a Davies correction, see "Buffers" above; HPO₄²⁻ fraction 0.43) and 0.02 % NaN₃ is added; it is the only fit compared against Pepsi-SAXS (not CRYSOL); its NaN₃ and NaH₂PO₄ entries have no stated uncertainty (table default is used).

### SASDX52: FadD5 (fatty acyl-CoA synthetase) dimer

```
julia --project=test/fitting_tests test/fitting_tests/SASDX52/SASDX52.jl
```

Fits an AlphaFold-derived, depositor-docked dimer (4 mg/mL) in 500 mM NaCl, 20 mM HEPES, 5 mM MgCl₂, 1 mM mercaptoethanol, pH 7.5, 13 keV, lMax 38. **Unique:** only the low-q region is fitted (q ≤ 0.17 Å⁻¹); the bundled reference curve has χ² = 0.699 (below 1) and its method is not confirmed to be CRYSOL, so the overlay is labelled "SASBDB fit1"; the model is predicted rather than experimentally determined.

### SASDYW6: fructose-bisphosphate aldolase (Fba1) dimer, imidazole buffer

```
julia --project=test/fitting_tests test/fitting_tests/SASDYW6/SASDYW6_fit2.jl
```

Fits the AlphaFold3 dimer (`fit2`; the GASBOR dummy-bead `fit1` is not fitted) at pH 8.5, 13.2 keV, q ≤ 0.25 Å⁻¹, lMax 26. **Unique:** the highest ionic strength in the suite (≈ 0.67 M): 500 mM NaCl, 500 mM imidazole (with ~23 mM Cl⁻ counter-ion) and 50 mM sodium phosphate speciated at pH 8.5; SASBDB's structured buffer field (Tris/NaCl, pH 8.0) conflicts with the entry's own description and is most likely copied from the sibling SASDYV6, so the entry description is used; 1 mM PMSF is included with an **estimated** volume (127.2 ± 5.0 cm³/mol, geometric estimate, not measured). Compared against the CRYSOL fit (χ² 3.737).

### SASDZC6: PDE6 / transducin-α* complex with udenafil

```
julia --project=test/fitting_tests test/fitting_tests/SASDZC6/SASDZC6.jl
```

Fits PDB 7JSN (PDE6α, PDE6β, 2 × PDE6γ, 2 × GαT*; 0.3 mg/mL PDE6) in 100 mM NaCl, 25 mM Tris, 2 mM MgCl₂, 2 % glycerol, pH 8.0, 11.3 keV (stated directly), q ≤ 0.3 Å⁻¹, lMax 53. **Unique:** a six-chain complex of four protein species (at pH 8.0 its chains' N-terminus pKas straddle the pH, so Pdb2pqr runs once per terminus-flag group and the chains are merged); the 3 µM udenafil inhibitor has no measured volume, so an **estimate** (399.6 ± 16.0 cm³/mol) is used; the bundled reference is FoXS (χ² 1.676) but it is not plotted here.

### SASDZZ9: NodB (chitooligosaccharide deacetylase), poorly matching crystal model

```
julia --project=test/fitting_tests test/fitting_tests/SASDZZ9/SASDZZ9_fit1.jl
```

Fits the 404-residue crystal-structure model (PDB 8YFP, monomer) in 100 mM NaCl, 20 mM Tris at a 0.137 nm wavelength, q ≤ 0.39 Å⁻¹, lMax 30. **Unique:** the deposited reference fit for this rigid model is poor (χ² ≈ 34.5) while an ab initio bead model gets ≈ 0.002 (not used), so the deposited structure does not describe the solution well. Overlays the CRYSOL fit1 curve.
