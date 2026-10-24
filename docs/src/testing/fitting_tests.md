# Fitting tests

**Note:** Entries in `BAYSOL.BulkElectronDensity` without uncertainties use an uncertainty estimated from the mean of the available experimental uncertainties. As the table grows, this estimate may change slightly, so fit results may change.

End-to-end BAYSOL fits of 57 SASBDB entries: 27 protein-only structures (53 fits in the Results table) and 30 entries with DNA or RNA (16 nucleic acid only, 14 protein and nucleic acid; see "Nucleic-acid entries" below; fitted 2026-10-22, 31 more rows in the table): load a structure, build its buffer, find the mode with a multi-start L-BFGS search and whiten around it, run the NUTS sampler over `ξ = (ρₑ, δρ₁, δρ₂, δρ₃)` with the excluded-volume correction `c1` profiled at every evaluation (to `EXCL_VOL_CORR_TOL` = 1e-8; see the Inference README for why that tight), and write the MAP/posterior report and figures
next to the script. The fitted curve is the deposited SASBDB curve (q in Å⁻¹, truncated at each script's `Q_MAX_FIT`), which `seed_model` bins to at least 12 bins per Shannon channel π/D (D: the diameter of the structure and its hydration shell; a precise curve gets finer bins, up to the point of being fitted as measured, so that the binning's worst-case bias stays under 0.3 of its smallest error bar) and from which it takes `lMax = ceil(q_max·D)`; the lMax and point counts below are those of the latest run, and each report's `=== Run ===` block lists `Dₘₐₓ`, the channels, the `rebin` used and the points before and after binning. χ² is reported on the measured q grid (the binned fit's model interpolated onto it, over all measured points), the convention of FoXS's own χ², and so of the depositors' numbers (a reduced χ² with N − 3 degrees of freedom: scale, background and c1).

```
julia --project=test/fitting_tests test/fitting_tests/<ID>/<script>.jl
```

All fits use the `run_model` defaults: eight NUTS chains (more when the optima search starts chains at an optimum that carries mass), each of 1000 iterations (`BAYSOL.Pipeline.DEFAULT_N_SAMPLES`), the first 300 of them warm-up (step-size and mass-matrix adaptation) and discarded, leaving 700 draws per chain; a target acceptance of 95 %; and one longer rerun (2000 warm-up and 2000 draws, seeds derived from the run's own) when the worst within-mode R̂ is above 1.01. The report of each fit prints R̂, the effective sample sizes, the modes and, when it happened, the retry. The seed is 0. Each script defines `run_<id>(; n_samples, n_adapt, seed)` if you want to change these values; `n_samples` is the *total* iteration count, including the `n_adapt` warmup, and the scripts use these defaults. Each script also has a `seed_<id>(...)` that builds the `Seed` its `run_<id>` then samples. It only for the tools in `dev/`, which inspect a fit without running it; if you don't need extra tooling skip `seed_<id>`. The temperature is each entry's stated sample temperature (25 °C when none is given). Hydrogens are added with Pdb2pqr at the stated pH unless noted; for a nucleic acid they do not depend on the pH (see "Nucleic-acid entries").

Settings shared by every script live in `common.jl`, which each script includes: the sampler defaults (`N_SAMPLES`, `N_ADAPT`, `SAMPLER_SEED`), the default pH σ (`PH_METER_SIGMA` = 0.1) and macromolecule-molarity σ (`MOLARITY_REL_SIGMA` = 5 %), the nm⁻¹ → Å⁻¹ conversion and q-unit sanity check, the `.dat`/fit-file readers, and the plot styling (sizes, colours, line widths). Change them there, not in individual scripts. A script that deliberately differs keeps its own value inline, with a comment.

## Results

 The table is generated from the reports (`bb results-table --update`); only the depositor column is  kept by hand, in `depositor_chi2.tsv`. Bold marks a parameter at a hard prior bound (δρ₁, δρ₂ ≤ 2; δρ₃ ∈ [−ρ̄ₑ/0.03, (φ_max − 1)·ρ̄ₑ/0.03] ≈ [−11.1, 2.8]), `c1` profiling saturation, or a chain with >5% divergent transitions. ″ repeats the line above: the members of one deposited multi-model fit share a single depositor χ², which belongs to their **weighted mixture**, not to any one member (see "Ensemble and multi-model entries" below).

**The 30 nucleic-acid entries were fitted on 2026-10-22** and have rows in the table below (their depositor values are in `depositor_chi2.tsv`; the table is regenerated with `bb results-table --update`). Every statement below about the 53 fits, their R̂, divergences and parameters at bounds refers to the 27 protein entries.



| Run                 | χ² (MAP) | depositor's χ² (method)                                              | δρ₁   | δρ₂   | δρ₃      | c1                    | divergences |
| --------------------- | ------------ | ------------------------------------------------------------------------ | ---------- | ---------- | ------------- | ----------------------- | ------------- |
| SASDA52 fit1        | 5.34       | CRYSOL χ² 2.48 (χ² ≈ 6.2)                                         | 0.08     | 0.09     | **2.76**    | 1.160                 | 0           |
| SASDAC9 —          | 163        | FoXS 680.3                                                             | −0.36   | −1.08   | −6.43      | 1.234                 | 0           |
| SASDAN8 —          | 1.2        | CRYSOL 2.464 (header; 4.58 recomputed from the file with a free scale) | 0.07     | −3.93   | 2.51        | 1.245                 | 0           |
| SASDB48 —          | 1.27       | FoXS 2.4                                                               | −0.97   | −0.97   | −10.77     | 1.211                 | 0           |
| SASDBS6 fit2_model1 | 60.4       | EOM ensemble 11.3                                                      | **2.00** | −1.28   | **−11.27** | 0.927                 | 0           |
| SASDBS6 fit2_model2 | 89.3       | ″                                                                     | −0.37   | **2.00** | **2.83**    | 1.241                 | 0           |
| SASDBS6 fit2_model3 | 21.5       | ″                                                                     | 0.04     | 1.67     | **2.82**    | 1.201                 | 0           |
| SASDBS6 fit2_model4 | 23.9       | ″                                                                     | 0.09     | 1.12     | **2.82**    | 1.196                 | 0           |
| SASDBS6 fit2_model5 | 51.8       | ″                                                                     | −0.25   | **2.00** | 0.82        | 1.233                 | 0           |
| SASDCA3 fit3        | 1.5        | CRYSOL 1.643                                                           | −0.66   | −0.52   | −9.86      | 1.263                 | 0           |
| SASDCM5 —          | 0.901      | CRYSOL 1.08                                                            | 0.93     | 0.25     | 0.64        | 1.214                 | 0           |
| SASDCQ2 fit2_model1 | 0.821      | MultiFoXS 1-state 0.85                                                 | 0.51     | −0.59   | −6.53      | 1.164                 | 0           |
| SASDCQ2 fit3_model1 | 1.23       | MultiFoXS 2-state 0.79                                                 | −0.19   | −0.84   | −8.08      | 1.242                 | 0           |
| SASDCQ2 fit3_model2 | 51.2       | ″                                                                     | 0.36     | −1.52   | 2.68        | 1.129                 | 0           |
| SASDD88 fit2_model1 | 0.989      | FoXS 4.50                                                              | −0.08   | 1.43     | −0.37      | 1.229                 | 0           |
| SASDD88 fit3_model1 | 0.912      | FoXS 2.79                                                              | 0.32     | −2.78   | −6.34      | 1.215                 | 0           |
| SASDDF7 —          | 1.81       | CRYSOL 1.955                                                           | −0.18   | 0.28     | −5.31      | **0.780 (saturated)** | 0           |
| SASDEP6 fit1_model1 | 2.4        | OLIGOMER 2-state 8.31 (w 0.59)                                         | −0.79   | 1.87     | −9.62      | 1.236                 | 0.0 %       |
| SASDEP6 fit1_model2 | 2.88       | ″ (w 0.41)                                                            | −0.44   | 1.88     | −6.35      | 1.221                 | 0           |
| SASDF42 —          | 1.36       | 2.10                                                                   | −0.69   | 0.92     | −5.58      | 1.242                 | 0           |
| SASDF95 fit2        | 2.53       | CRYSOL 6.229                                                           | 0.34     | −1.40   | **2.77**    | 1.177                 | 0           |
| SASDG24 —          | 13.1       | EOM ensemble 0.35 (2.49 recomputed from the file)                      | 0.25     | −1.03   | **2.75**    | 1.293                 | 0           |
| SASDH39 fit1        | 1.05       | CRYSOL 7.686                                                           | −0.03   | 1.91     | −5.12      | 1.200                 | 0           |
| SASDJ62 model1      | 3.39       | —                                                                     | 0.23     | 0.88     | **−11.21** | 1.193                 | 0           |
| SASDJ66 fit1        | 1          | CRYSOL 1.044                                                           | −0.87   | −0.06   | −2.44      | **1.320 (saturated)** | 0.3 %       |
| SASDJ72 model1      | 51.3       | MultiFoXS 2-state 2.91                                                 | 0.19     | **1.98** | **2.87**    | 1.205                 | 0           |
| SASDJ72 model2      | 2.38       | ″                                                                     | −0.26   | 1.00     | −7.53      | 1.216                 | 0           |
| SASDJY2 —          | 0.636      | CRYSOL 4.68                                                            | 0.79     | −7.06   | −2.01      | 1.162                 | 0           |
| SASDJZ2 fit1        | 1.17       | CRYSOL 1.654                                                           | 0.48     | −2.23   | −7.13      | 1.182                 | 0           |
| SASDK36 —          | 1.19       | CRYSOL 2.615                                                           | −0.88   | −2.06   | −4.80      | **1.303 (saturated)** | 0           |
| SASDK94 fit1        | 3.85       | Pepsi-SAXS-style 5.635 (software not stated)                           | 0.41     | **2.00** | −4.40      | 1.157                 | 0           |
| SASDKQ8 —          | 1.51       | CRYSOL 14.3                                                            | 0.77     | −6.37   | −3.29      | 1.171                 | 0           |
| SASDLP4 fit1_model1 | 3.46       | OLIGOMER 3-state 1.09                                                  | 0.78     | −3.59   | **2.78**    | 1.204                 | 0           |
| SASDLP4 fit1_model2 | 1.21       | ″                                                                     | 0.16     | −2.01   | −0.86      | 1.254                 | 0           |
| SASDLP4 fit1_model3 | 7.84       | ″                                                                     | 0.52     | −0.96   | **2.79**    | 1.226                 | 0           |
| SASDLP4 fit2_model1 | 1.21       | CRYSOL 1.06                                                            | 0.16     | −2.01   | −0.86      | 1.254                 | 0           |
| SASDM76 —          | 1.04       | CRYSOL 1.779                                                           | 0.06     | −3.01   | −0.92      | 1.277                 | 0.4 %       |
| SASDMJ9 —          | 0.874      | CRYSOL 1.37                                                            | −1.08   | **1.95** | −5.49      | 1.248                 | 0           |
| SASDMZ9 model1      | 7          | MultiFoXS 3-state 2.65                                                 | −0.04   | −1.18   | −1.27      | 1.185                 | 0           |
| SASDMZ9 model2      | 6.49       | ″                                                                     | −0.28   | −1.14   | −0.41      | 1.203                 | 0           |
| SASDMZ9 model3      | 55         | ″                                                                     | 0.23     | −2.51   | **2.79**    | 1.181                 | 0           |
| SASDN32 —          | 0.975      | FoXS 1.01                                                              | 0.40     | −2.50   | 1.56        | 1.187                 | 0           |
| SASDNH7 fit1        | 8.64       | FoXS 16.465                                                            | −1.63   | **1.99** | 2.65        | 1.222                 | 0           |
| SASDNK7 fit1        | 0.994      | CRYSOL 1.391                                                           | −0.13   | 0.57     | −6.38      | 1.297                 | 0           |
| SASDNP7 fit1        | 28.1       | CRYSOL 29.579                                                          | 0.31     | **2.00** | **2.80**    | 1.156                 | 0           |
| SASDP48 —          | 15.9       | CRYSOL 59.5                                                            | −0.05   | 0.38     | **2.78**    | 1.214                 | 0           |
| SASDPN6 fit1        | 1.29       | Pepsi-SAXS 1.224                                                       | −0.86   | −2.35   | −2.00      | **1.320 (saturated)** | 0           |
| SASDPU6 —          | 1.38       | CRYSOL 1.265 (AMBER MD model)                                          | 0.05     | −0.99   | 1.08        | 1.221                 | 0           |
| SASDQ69 —          | 0.936      | FoXS 1.10                                                              | 0.91     | 0.42     | −3.26      | 1.149                 | 0.1 %       |
| SASDR99 —          | 14.5       | 29.6 (MDFF model)                                                      | 0.15     | −1.99   | −8.70      | 1.179                 | 0           |
| SASDRN5 fit2_model1 | 2.85       | SREFLEX 3.04                                                           | 0.31     | 1.28     | 0.71        | 1.189                 | 0           |
| SASDRN5 fit3_model1 | 7.18       | CRYSOL 12.0                                                            | −0.01   | −0.24   | −8.94      | 1.211                 | 0           |
| SASDRW2 —          | 2.02       | CRYSOL 3.03                                                            | −0.21   | −7.43   | −2.36      | **0.780 (saturated)** | 0           |
| SASDSW7 fit1        | 2.49       | Pepsi-SAXS 2.688                                                       | −0.38   | 0.33     | −9.77      | **1.311 (saturated)** | 0           |
| SASDSX5 —          | 1.16       | Pepsi-SAXS 1.28                                                        | −0.02   | 0.48     | −6.15      | 1.187                 | 0           |
| SASDT55 —          | 0.985      | Pepsi-SAXS 1.03                                                        | 0.41     | −0.04   | 0.10        | 1.181                 | 0           |
| SASDTK5 fit2_model1 | 0.941      | CRYSOL 1.14                                                            | −0.92   | −5.65   | −1.83      | 1.256                 | 0           |
| SASDTK5 fit3_model1 | 1.2        | CRYSOL 1.17                                                            | 0.53     | 1.53     | 2.31        | 1.186                 | 0           |
| SASDTK5 fit4_model1 | 1.61       | CRYSOL 5.22                                                            | −0.11   | −3.78   | **−11.24** | 1.216                 | 0           |
| SASDTK5 fit5_model1 | 0.926      | CRYSOL 1.81                                                            | −0.17   | −5.59   | 1.15        | 1.228                 | 0           |
| SASDTK5 fit6_model1 | 0.926      | CRYSOL 1.03                                                            | 0.64     | 1.75     | 2.18        | 1.177                 | 0           |
| SASDTK5 fit7_model1 | 1.81       | CRYSOL 6.09                                                            | −0.02   | −3.12   | **−11.27** | 1.216                 | 0           |
| SASDU29 fit1        | 1.05       | Pepsi-SAXS-style 1.546 (software not stated)                           | −0.35   | −3.48   | 1.87        | 1.209                 | 0           |
| SASDUN5 fit1_model1 | 1.87       | OLIGOMER 2-state 2.21                                                  | −0.36   | −1.50   | −1.54      | 1.213                 | 0           |
| SASDUN5 fit1_model2 | 11.4       | ″                                                                     | −0.55   | −2.75   | **−11.25** | 1.177                 | 0           |
| SASDV94 fit1        | 1.87       | CRYSOL 1.28                                                            | **1.98** | −7.99   | 2.64        | 1.134                 | 0           |
| SASDVG2 fit1_model1 | 2.44       | MultiFoXS 1-state 2.10                                                 | 0.00     | 0.69     | −2.55      | 1.177                 | 0           |
| SASDVG2 fit2_model1 | 2.3        | MultiFoXS 2-state 1.27                                                 | −0.28   | 1.70     | −0.74      | 1.171                 | 0.1 %       |
| SASDVG2 fit2_model2 | 4          | ″                                                                     | 0.91     | −2.44   | 2.15        | 1.167                 | 0           |
| SASDVG2 fit3_model1 | 3.98       | MultiFoXS 3-state 1.29                                                 | 1.39     | −9.06   | −10.28     | 1.261                 | 0           |
| SASDVG2 fit3_model2 | 5.83       | ″                                                                     | 0.44     | −1.29   | −3.00      | 1.199                 | 0           |
| SASDVG2 fit3_model3 | 21.4       | ″                                                                     | 0.24     | −0.63   | −2.92      | 1.203                 | 0           |
| SASDVU5 —          | 1.1        | Pepsi-SAXS 2.613                                                       | −1.33   | 1.85     | 2.48        | **0.780 (saturated)** | 0           |
| SASDVV4 fit1        | 0.425      | Pepsi-SAXS 0.876                                                       | −0.53   | −2.69   | −3.83      | 1.258                 | 0.4 %       |
| SASDVX2 fit1        | 8.63       | Pepsi-SAXS 6.974                                                       | 1.60     | −3.73   | −10.57     | 0.867                 | 0           |
| SASDWJ4 fit2        | 15.7       | Pepsi-SAXS 10.774                                                      | 1.13     | 1.94     | **−11.08** | 1.143                 | 0           |
| SASDWR5 —          | 1.43       | CRYSOL 1.11 (SREFLEX model)                                            | 0.82     | 1.72     | −11.04     | 1.135                 | 0           |
| SASDWZ9 —          | 0.58       | Pepsi-SAXS 0.62                                                        | 0.24     | 1.52     | −0.12      | 1.278                 | 0           |
| SASDX52 —          | 0.306      | 0.70 (method unconfirmed)                                              | −0.21   | −3.30   | 1.04        | 1.232                 | 0.9 %       |
| SASDYM2 —          | 0.291      | FoXS 0.286 (error bars overestimated)                                  | 0.63     | 0.90     | −1.24      | 1.195                 | 0           |
| SASDYW6 fit2        | 2.88       | CRYSOL 3.74                                                            | −0.11   | −1.53   | −6.41      | 1.198                 | 0           |
| SASDZC6 —          | 1.66       | FoXS 1.68                                                              | −0.81   | −0.19   | 0.60        | 1.091                 | 0           |
| SASDZZ9 fit1        | 14.6       | CRYSOL ≈ 34.5                                                         | −0.48   | **1.99** | −5.50      | 1.231                 | 0           |


**How to read these MAPs.**

- **The reported MAP is the best NUTS draw**, not the L-BFGS mode that seeds the sampler (their χ² agrees to 4-5 digits, e.g. 60.2652 vs 60.2657 for SASDBS6 model1). Parameters the data barely constrain (δρ₃ on fits with almost no cavity beads, for one) move between reruns because the best of the several thousand pooled draws moves, with the χ² unchanged; judge those from the quantile table in each `res*.txt`, not from this table.
- **No chain fails, no fit has more than 1 % divergent transitions, and all 53 fits reach R̂ ≤ 1.01** (worst 1.0063; the retry fires on eight fits, SASDEP6 ×2, SASDLP4 ×2, SASDN32, SASDRN5, SASDVG2 and SASDWZ9, and every rerun is kept). The two failed chains of v0.2.0 (SASDMZ9 model1, 96.8 % divergent; SASDJY2, 81 %) sample cleanly, and the target acceptance of 95 % removed the 1-3 % divergences that SASDEP6 `fit1_model1` (3.0 %) and SASDLP4 `fit1_model2` / `fit2_model1` (1.4 %, the same structure and curve) had at 80 %. Eight fits still have a few divergent draws (1 to 2 out of several thousand, and 7 for SASDX52, the largest). The divergences are geometric, not numerical error in the gradient (they persisted at c1 tolerance 1e-10), and on the barely constrained fits the δρ₃ posterior is 2-4× wider than the Laplace whitening predicts.
- **Most other optima carry no mass, but not all.** The MAP search often reports 2-5 "modes", which is a count of distinct local optima, not of modes of the posterior. In most fits every optimum besides the best is tens to thousands of nats lower in log density and carries no mass (seven reports list a second mode with a share below 1e-4 that keeps no draws). Five fits are different: SASDKQ8 (0.96 / 0.04), SASDN32 (0.95 / 0.05), SASDWZ9 (0.84 / 0.16) and SASDZC6 (0.81 / 0.19) have a second mode with real mass that is weighted in by bridge sampling, and SASDX52 has a third optimum with about 4 % of the Laplace mass that no random start reaches (the optima search finds it from the chains' draws; a validation run, removed, is in git history under `test/validation/optima_recall/`). The report lists every mode and the optima that carry mass.
- **Many fits put δρ₃ at its upper bound** (~+2.8, i.e. φ ≈ φ_max): SASDA52, SASDBS6 model2-4, SASDJ72 model1, SASDLP4 `fit1_model1`/3, SASDMZ9 model3, SASDP48. At its **lower** bound (−11.1, empty cavities): SASDBS6 model1, SASDJ62, SASDTK5 fit4/7 and SASDUN5 model2. The bound is usually reached together with a poor or mediocre χ²: the cavity contrast is absorbing model-data mismatch (wrong conformer, missing ensemble members) rather than representing physical cavity hydration.
- **What buys the low χ² on poorly fitting single conformers is the split of the first two contrasts.** Refitting with one shared shell contrast (δρ₁ = δρ₂ = δρ₃, c1, scale and background still profiled; computed with the ablation part that `bb diagnose` had until it was settled, now in git history) gives:


  | fit                             | one shared contrast     | δρ₁ = δρ₂, δρ₃ free | full model (this table)   |
  | --------------------------------- | ------------------------- | ------------------------------ | --------------------------- |
  | SASDMJ9                         | 1.07                    | 1.07                         | 0.87                      |
  | SASDEP6 fit1_model1 / model2    | 3.43 / 15.6             | 2.81 / 15.1                  | 2.40 / 2.88               |
  | SASDLP4 fit1_model3             | 96.0                    | 95.4                         | 7.84                      |
  | SASDBS6 fit2_model1 / 2 / 3 / 5 | 69.8 / 137 / 38.5 / 125 | 61.7 / 121 / 34.2 / 115      | 60.4 / 89.3 / 21.5 / 51.8 |
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

- **Where one member dominates the population, BAYSOL identifies it.** SASDLP4's dimer (1.10) is the only member that fits, matching the paper's mostly-dimer finding; SASDUN5's tetramer (1.63) fits and the octamer does not, matching the reported 75:25 split; SASDCQ2's 1-state MultiFoXS conformer fits at 0.82, as well as the depositor's 2-state mixture. Both SASDEP6 members (open 2.40, closed 2.88) beat the deposited OLIGOMER mixture (8.31), but BAYSOL also fits the solvent contrasts and `c1`, and the ablation above shows that for the closed state it is the independent δρ₂ that does it (15.6 with one shared contrast), so the two χ² values are not comparable.
- **Where the population is genuinely broad, no single member fits well.** SASDBS6 (EOM), SASDMZ9 and the multi-state SASDVG2/SASDJ72 members are 2–100× worse than their mixtures, with δρ parameters at bounds. These runs are a test of the forward model on realistic conformers, not of the deposited structural interpretation. A meaningful comparison needs a mixture likelihood (weights sampled alongside ξ), which BAYSOL does not have; until then, compare the *best* member with the mixture χ² and read the rest qualitatively.
- **Alternative single models are different.** SASDTK5 (six Fe-TPP-phen HasApf5 dimer geometries), SASDD88 (homology vs normal-mode model), SASDRN5 (AlphaFold vs SREFLEX-refined) and SASDJ62/SASDZZ9 are competing hypotheses, each meant to explain the curve as individual strutures. There BAYSOL's ranking can be compared directly with the depositor's: it agrees on SASDTK5 (lambda-trans1, `fit6`, is best for both: 0.92 vs CRYSOL 1.03), on SASDRN5 (refined 2.85 < raw 7.18) and on SASDD88 (both models fit, the normal-mode model slightly better).

## Tools

Three scripts work on the results without rerunning a fit:

```
# sampler diagnostics on any fit: MAP starts, Hessian, step size and tree depth, gradient error, modes
bb diagnose --report SASDBS6:fit2_model3
#   other parts: `--residuals` (whiteness of the residuals), `--chains` (every chain `infer` runs)

# compare results between git revisions / tags and the working tree (timing totals, χ² and parameter distributions)
bb compare v0.2.0-soukouratou HEAD          # any revisions; the working tree is added last

# the Results table above: regenerate it, or check that it is current (exit 1 if not)
bb results-table --update
bb results-table --check
```

Cold-start and steady-state benchmarks (compile and precompile time reported apart from algorithmic time, measured from a
wiped cache state) live in `dev/` (see `dev/README.md`); `bb compare --bench new.json`
compares a run with the latest release's baseline in `test/baselines/` (or name two files). Benchmarks are only run with the repository owner's approval (`--approved`), because they need a quiet machine and AI agents tend not to check for one; see `test/utils/README.md`.

`dev/diagnose.clj` builds the `Seed` a script would sample without fitting it (through the script's `seed_<id>()`, above); the diagnostics themselves are generic functions in `dev/seed_diagnostics.jl`, tested in `test/unit_tests/units/test_seed_diagnostics.jl`. `compare.clj` reads the committed `res*.txt` of each revision with `git show`, so no checkout is needed; the wall clock excludes PROPKA/pdb2pqr.

## Entry summary


| Entry   | System                                             | Notes                                                                                                  |
| --------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| SASDA52 | yeast ADH1 tetramer                                | assumed PBS recipe; beamline wavelength unit-slip corrected; CRYSOL overlay                            |
| SASDF42 | HSA + 2 somapacitan                                | HSA + two GH copies in one model; compared with the deposited fit (χ² 2.10; its header's 1.45 is χ) |
| SASDJ62 | XRCC1                                              | already-hydrogenated CHARMM model; glycerol converted from % v/v; no reference curve                   |
| SASDJ72 | DNA ligase IIIα                                   | the two members of a MultiFoXS 2-state ensemble, fitted separately; concentration-merged data          |
| SASDMJ9 | FCoV Nsp7                                          | the reference case validated against CRYSOL                                                            |
| SASDMZ9 | Sas20d1-2 (flexible)                               | the three members of a MultiFoXS 3-state ensemble, fitted separately; SASBDB pH 7.0                    |
| SASDN32 | Sas20d2 + ligand                                   | 5 mM maltoheptaose, a solute that previously had no volume data                                        |
| SASDV94 | phospholipase C (PLC H) + chaperone PLC R2         | only the atomistic chains of a mixed atomistic/dummy-bead model; merged injections                     |
| SASDWZ9 | SERF1a                                             | NMR conformer; speciated phosphate buffer + azide; only Pepsi-SAXS comparison                          |
| SASDX52 | FadD5 dimer                                        | predicted dimer; q truncated at 0.17 Å⁻¹; reference χ² < 1 from an unconfirmed method             |
| SASDYW6 | Fba1 dimer                                         | AlphaFold3 model; 500 mM imidazole + NaCl (I ≈ 0.65 M); estimated PMSF volume                         |
| SASDZC6 | PDE6/GαT* complex                                 | six-chain, four-species complex; estimated udenafil volume; FoXS reference χ² 1.68                   |
| SASDZZ9 | NodB                                               | crystal model with a poor reference agreement (χ² ≈ 34.5)                                           |
| SASDBS6 | ObgE (full length)                                 | 5 members of an EOM ensemble (flexible C-terminal domain), fitted separately; 250 mM imidazole         |
| SASDCQ2 | Ca²⁺-calmodulin                                  | MultiFoXS 1-state and 2-state members; 0.1 % NaN₃ + TCEP radiation protection                         |
| SASDD88 | M. tuberculosis LigA BRCT domain                   | two alternative models (Phyre2 homology, elNémo normal mode); paper/SASBDB buffer conflict            |
| SASDEP6 | glucosamine kinase + GlcN + ATP                    | OLIGOMER open/closed pair (0.59/0.41); 0.2 M D-glucosamine in the buffer                               |
| SASDJY2 | EcoKMcrA N-terminal domain                         | single CRYSOL model; its chain failed in v0.2.0 (81 % divergent), healthy now                          |
| SASDKQ8 | ROSA de novo four-helix-bundle dimer               | single model; pre-hydrogenated; 5 % glycerol                                                           |
| SASDLP4 | SodA (superoxide dismutase)                        | OLIGOMER monomer/dimer/tetramer + a CRYSOL dimer fit; 50 mM HEPES only                                 |
| SASDP48 | GRB2 N188D/N214D monomer                           | crystal monomer that fits poorly (deposited 59.5); pre-hydrogenated model (Pdb2pqr skipped)            |
| SASDR99 | AADC (DOPA decarboxylase) dimer                    | MDFF-refined dimer; chain IDs repaired from CHARMM segment IDs                                         |
| SASDRN5 | NURC1                                              | AlphaFold model raw vs SREFLEX-refined; 50 mM sodium phosphate + 5 % glycerol                          |
| SASDRW2 | collagen peptide (POG)₁₀ trimer                  | smallest structure in the suite (1059 atoms); histidine buffer at pH 6.0                               |
| SASDTK5 | HasApf5 + Fe-TPP-phen dimer                        | six alternative dimer geometries; CHES–KOH pH 9.5; pre-hydrogenated                                   |
| SASDUN5 | M. smegmatis IMPDH                                 | OLIGOMER tetramer/octamer with 10 mM IMP (+12 mM MgCl₂) in the buffer blank                           |
| SASDVG2 | Eap + cathepsin-G tetramer                         | MultiFoXS 1-, 2- and 3-state members; models extracted from an ensemble (`MODEL` ≠ 1)                 |
| SASDAC9 | Varkud satellite ribozyme dimer (G638A)            | two RNA chains with the same chain id; depositor FoXS χ² 680 kept as a stress test                   |
| SASDAN8 | mLBS1-2 viral terminal-repeat B-DNA duplex         | deoxy DNA with bare A/C/G/T names; depositor χ² 2.464 (header) vs 4.58 (file)                        |
| SASDB48 | ICP4N dimer + 19-bp IE3 DNA                        | protein written as HETATM records; mixed model                                                         |
| SASDCA3 | ZBTB38 zinc fingers + methylated 54-nt DNA         | mixed; Zn²⁺ as ATOM records; fit3 only                                                               |
| SASDCM5 | vaccinia E9 polymerase + 29-nt template-primer DNA | mixed; a modified nucleotide (DOC) and a dCTP ligand                                                   |
| SASDDF7 | armless mitochondrial tRNA-Arg (64 nt)             | RNA with 10 mM Mg²⁺; SEC-SAXS                                                                        |
| SASDF95 | PaHigA dimer + 32-bp DNA (two dimer copies)        | mixed; glycerol and PMSF in the buffer                                                                 |
| SASDG24 | Dengue-2 subgenomic flavivirus RNA (423 nt)        | legacy residue names; depositor curve is an EOM ensemble; the largest RNA                              |
| SASDH39 | A. fulgidus Argonaute dimer + 14-mer DNA duplex    | mixed; DNA written with RNA letters; 160 selenomethionines                                             |
| SASDJ66 | GATA-element duplex DNA (2 × 22 nt)               | DNA only; SEC-SAXS                                                                                     |
| SASDJZ2 | EcoKMcrA N-terminal domain + 12-bp DNA             | mixed; the model's DNA is homologous, not identical, to the measured one                               |
| SASDK36 | LC-18t ssDNA aptamer (35 nt)                       | PARKED: the buffer recipe is open                                                                      |
| SASDK94 | BusR (4 chains) + 46-bp dsDNA                      | mixed, the largest of the set; SEC-SAXS; c-di-AMP ligands dropped                                      |
| SASDM76 | 201D G-quadruplex DNA (28 nt)                      | the smallest nucleic-acid entry; the model carries hydrogens                                           |
| SASDNH7 | Tn3 resolvase dimer + 52-bp site II DNA            | mixed; FoXS file fetched from the media URL; poor depositor fit                                        |
| SASDNK7 | c-MYC Pu22 G-quadruplex DNA (22 nt)                | DNA only; the model carries hydrogens and two K⁺ HETATM                                               |
| SASDNP7 | aIF2 γ/α + tRNA with GDPNP                       | OPEN: pdb2pqr aborts on the charge check at a chain end; modified bases, selenomethionines             |
| SASDPN6 | SARS-CoV-2 stem-loop 4 RNA (69 nt)                 | RNA only; the model carries builder hydrogens                                                          |
| SASDPU6 | duplex-embedded G-quadruplex DNA (46 nt)           | DNA only; AMBER MD model with hydrogens and K⁺ named `K+`; SEC-SAXS                                   |
| SASDQ69 | 28-bp B-DNA duplex                                 | DNA only; the model carries hydrogens; SEC-SAXS                                                        |
| SASDSW7 | (GU)12 RNA (24 nt)                                 | RNA only; infinite-dilution curve; the model carries hydrogens                                         |
| SASDSX5 | nucleosome core particle, 145 bp Widom 601 DNA     | PARKED: no publication or DOI in SASBDB; the largest mixed model                                       |
| SASDT55 | influenza B NS1-CTD* + 24-nt 5'ppp hairpin RNA     | mixed; legacy residue names                                                                            |
| SASDU29 | 2:1 CRX homeodomain : Ret4 DNA complex             | mixed; the fit file is on a different scale than the .dat                                              |
| SASDVU5 | MpARF3 DNA-binding domain + 2 × 20-nt DNA         | mixed; ANISOU records; SASBDB cautions on Dmax                                                         |
| SASDVV4 | ST9 viral RNA (54 nt)                              | RNA only; SEC-SAXS                                                                                     |
| SASDVX2 | SARS-CoV-2 stem-loop 5 RNA (~148 nt)               | RNA only; the largest nucleic-acid-only model of the first batches                                     |
| SASDWJ4 | class V GTP-binding RNA aptamer (68 nt) + 2 GTP    | PARKED and OPEN: pdb2pqr aborts on the charge check at a chain end; GTP concentration unknown          |
| SASDWR5 | 37-nt stimulatory-element RNA                      | RNA only; SREFLEX model from an AlphaFold template; SEC-SAXS                                           |
| SASDYM2 | human prothrombin + NU172 DNA aptamer              | mixed; buffer text ends with a comma; error bars overestimated                                         |

## Entries

### SASDA52: yeast alcohol dehydrogenase 1 (ADH1), PBS

```
julia --project=test/fitting_tests test/fitting_tests/SASDA52/SASDA52_fit1.jl
```

Fits the ADH1 tetramer (PDB 4W6Z, 347-residue chains; 24.89 mg/mL) with q ≤ 0.5 Å⁻¹ and lMax 56 (scatterer-cloud diameter 110.7 Å; the GNOM `D_max` is 89.3 Å), pH 7.4. **Unique:** the SASBDB entry only says "PBS", so the standard 1× PBS recipe (137 mM NaCl, 2.7 mM KCl, 10 mM Na₂HPO₄, 1.8 mM KH₂PO₄, each ±5 %) is assumed; the beamline wavelength "0.15" is read as a unit slip for 1.5 Å (8.27 keV); the experimental file is in nm⁻¹ and is converted. Overlays our MAP curve on SASBDB's CRYSOL fit1 (`res_fit1_comparison.png`).

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

## Nucleic-acid entries

Thirty entries with a DNA or RNA in the structure, to learn whether the existing four-parameter model fits nucleic acids at all. They differ from the protein entries in these ways:

- **Model types.** 16 are nucleic acid only (DNA duplexes and G-quadruplexes, structured RNAs, an MD frame of an aptamer), 14 are protein with DNA or RNA (a nucleosome, protein-DNA and protein-RNA complexes). Some models are crystal or NMR structures, others MD frames, HADDOCK/SASREF rigid-body models, RNAMasonry or SREFLEX models; 11 carry their own hydrogens, which pdb2pqr rebuilds (`ADD_HYDROGENS` stays `true`, unlike SASDP48 and SASDJ62, whose protein hydrogen names pdb2pqr rejects). The B-factors of several MD models are all 0.00: BAYSOL never reads B-factors or occupancy, so that is not a defect.
- **Hydrogenation routes** (`BAYSOL.seed_model` chooses them from the residue names; the details are in the Hydrogenator README). A nucleic acid alone goes through pdb2pqr with AMBER and no PROPKA run (nucleic-acid hydrogens do not depend on pH); a protein-DNA or protein-RNA model keeps PARSE and PROPKA (the terminus flags need PARSE). Modified nucleotides (`DOC` in SASDCM5, `PSU 4SU 5MU H2U OMC` in SASDNP7) are hydrogenated through their base by relabelling and restoring the names, an approximation that does not place hydrogens which exist only in the modification; a modified residue with no known base gets none. Legacy names (`ADE GUA CYT URI`: SASDG24, SASDT55), plain letters for DNA (`A C G T`: SASDAN8, SASDH39) and reused chain ids (SASDAC9) are repaired in the copy pdb2pqr sees, and heavy atoms pdb2pqr drops (the 5' phosphorus) are restored. Waters, ions and ligands that are neither nucleotides nor peptide-linking amino acids are not part of the model; modified amino acids written as HETATM (SASDH39's selenomethionines, SASDB48's protein) are kept and hydrogenated through their parent (Hydrogenator README).
- **Buffers.** Nucleotides are taken as the user supplied them; the buffer is entered as for the proteins, and the measured macromolecule is never a solute. Several recipes need an assumed titrant (NaOH for a Good's buffer, HCl for Tris), stated in each section.
- **Depositor comparisons are less uniform than for the proteins.** Some fit files are not on the data's scale (SASDAN8, SASDG24, SASDWJ4, SASDU29), carry a different χ² in the header than the file reproduces (SASDAN8: 2.464 vs 4.58; SASDG24: 0.35 vs 2.49; SASDK94: 5.820 vs 5.635 of the entry), or come from an ensemble (SASDG24, EOM). SASDAC9's depositor χ² of 680 is kept on purpose as a stress test.
- **Open items.** SASDK36, SASDWJ4 and SASDSX5 are parked by the owner (buffer and citation questions). A modified base with no known base gets no hydrogens. A nucleic chain that starts or ends with a non-nucleotide (SASDNP7's aminoacyl MET, SASDWJ4's 5' GTP) runs those ends under chain ids of their own in the temporary pdb2pqr copy (`Hydrogenator/ChainEnds.jl`), which is what lets pdb2pqr's terminal patches apply.
- **Known buffer omissions.** BAYSOL does not guess missing acids, bases or counter-ions; the user is responsible for the recipe. A script that knows its recipe is incomplete says so: a `# BUFFER OMISSIONS` comment block, a `const BUFFER_OMISSIONS = String[...]` after `SOLUTES` and a `@warn` on every run and seed build. The table below gives the effect on the buffer electron density in percent of water (estimates, from the audit of the solute tables); since 2026-10 every component is in the tables (GDPNP and D₂O are now modelled, see their entries below); free GTP of SASDWJ4 is still left out because its concentration is not stated. "Tris-HCl" (or Tris at a pH) is modelled as Tris plus HCl at the molarity derived from Goldberg's pK with a Davies correction; no Tris-HCl salt is added and the extra hydrogen of the salt reading is accepted (owner decision), so it is a convention, not an omission. Glycerol has two uncertainty conventions: the 5 % v/v recipes of SASDKQ8, SASDRN5, SASDTK5 and SASDF95 use 0.6846 M with σ 2 %, most new entries use 5 % relative; neither is an error.
- **Stale results after the 2026-10 solute-table update.** SASDUN5 (IMP 179.9 → 210.7 cm³/mol, about −0.031 % in ρₑ at 10 mM), SASDNP7 (GDPNP now modelled, +0.026 %) and SASDCA3 (D₂O now modelled, −0.042 %) have a different buffer prior than the one their stored `res*.txt`/`.png` outputs were fitted with; the numbers in this README for them are from the old prior until they are re-run. No fit was run for the update.
- **Diagnose tools.** `dev/fit_seed.jl` takes the reference curve's name from the script's (`SASDWJ4_fit2.jl` reads `SASDWJ4_fit2.fit`; a script without a `_fit` suffix is fit1), so SASDG24 and SASDK36, whose scripts carry no suffix but whose `.fit` is fit2, get no reference in `bb diagnose`, and SASDAC9 and SASDB48 have no `.fit` file; SASDNP7's file has three columns, not the four it expects.


| Entry   | Known omission                                                                                        | Effect on ρₑ of the buffer                    |
| --------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| SASDT55 | arginine 50 mM, anion unknown                                                                         | +0.074 % if Cl⁻; +0.060 to +0.087 % if acetate |
| SASDT55 | acid or base setting pH 5.5 not stated, no titrant ion                                                | < 0.006 %                                       |
| SASDK36 | PBS phosphate and K⁺, concentration unknown                                                          | +0.114 % (standard PBS recipe)                  |
| SASDK36 | Na⁺ 146 mM taken wholly as NaCl                                                                      | approximation, not quantified                   |
| SASDWJ4 | free GTP, concentration unknown (GTP is in the tables: measured tetrasodium salt, 290 ± 22 cm³/mol) | +0.026 % per mM                                 |
| SASDYM2 | component after the comma ending the recipe                                                           | 0.002 to 0.015 % per mM                         |
| SASDJZ2 | EDTA 0.1 mM, cations not stated (tetra-anion)                                                         | up to +0.0004 % as Na⁺                         |

Not marked (below 0.005 % or a settled convention): TCEP taken as neutral (SASDCA3, PN6, U29; up to 0.003 %), Na⁺ against K⁺ as the titrant (SASDSW7, WR5), the EDTA stand-in (SASDM76, PU6), the phosphate splits (SASDPN6, VX2).

Run labels in the table are those of the `res*.txt` the scripts write: `<ID> —` for a script that writes `res.txt`, `<ID> fit1` (or `fit2`, `fit3`) for the others.

### SASDAC9: Varkud satellite ribozyme dimer, Tris/KCl/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDAC9/SASDAC9.jl
```

Fits the Varkud satellite ribozyme dimer (G638A mutant, 120.3 kDa; 12092 atoms including 4026 hydrogens, GDP, 10 Mg²⁺, 10 K⁺ and 22 waters in the deposited model) in 25 mM KCl, 10 mM Tris, 5 mM MgCl₂, pH 7.5, 12.0 keV, q ≤ 0.3 Å⁻¹. The temperature is not recorded (the package default, 25 °C, is used) and the .dat is in nm⁻¹. Tris counter-ion: Cl⁻ 8.46 mM (fraction 0.846, I ≈ 0.048 M); MgCl₂ ±2 %. **Unique:** the depositor's FoXS fit is poor (χ² 680.3), and the entry is **kept on purpose as a stress test** (the table row will show what BAYSOL makes of a model that its own depositor cannot fit). The deposited model labels both 186-nt RNA chains `A` (separated by TER, with overlapping residue numbers; chain `B` holds only ions, waters and ligands). The first seed build failed on that (BioStructures: two atoms with the same alternative location); the pipeline now gives the second chain a free chain id in the copy it hands to pdb2pqr (`MolecularStructure.sanitized_copy`), and `test_structure_checks.jl` hydrogenates this very model (11996 atoms after the AMBER run, 4028 hydrogens). The seed build of the script itself has not been repeated since that change: the load check before the fits does it. Overlays the depositor's FoXS curve (`SASDAC9_fit2.dat`).

### SASDAN8: mLBS1-2 viral terminal-repeat DNA, Tris/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDAN8/SASDAN8.jl
```

Fits the free mLBS1-2 B-DNA duplex (30 kDa, 2044 heavy atoms, chains A and B; up to 5 mg/mL) in 150 mM NaCl, 10 mM Tris, pH 7.6, 10 °C, 10.3 keV, q ≤ 0.3 Å⁻¹. Tris counter-ion Cl⁻ 8.26 mM (fraction 0.826, I ≈ 0.158 M); the .dat is in nm⁻¹. **Unique:** pure DNA, but written with the bare residue names `A C G T`, which pdb2pqr (PARSE) reads as RNA: at the first seed build it added a 2'-OH to every `A`, `C` and `G` and no hydrogen to the thymines. The pipeline now relabels a residue named `A C G U` that has no `O2'` as DNA in the copy it hands to pdb2pqr (the plain-letter rule of the Hydrogenator README: 2044 atoms plus 1111 hydrogens, none on an `O2'`). **Depositor comparison:** the 3-column CRYSOL file is not on the data's scale, so it is rescaled for the overlay; its header χ² (2.464, the value SASBDB records) is not reproduced by the file (4.58 after rescaling with a free scale), and the overlay shows the file value. All B-factors of the model are 0.00 (a molecular-dynamics model), which is not a defect: BAYSOL never reads them.

### SASDB48: HSV-1 ICP4N dimer on IE3 DNA, HEPES/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDB48/SASDB48.jl
```

Fits the rigid-body model of the ICP4N dimer on the 19-bp IE3 DNA (chains G, H protein and C, D DNA; 3735 atoms, 60.3 kDa) in 20 mM HEPES, 150 mM NaCl, pH 7.4, 20 °C, 12.4 keV, q ≤ 0.25 Å⁻¹ (the data stop at 0.251). HEPES titrated with NaOH: Na⁺ 9.08 mM (I ≈ 0.159 M). **Unique:** the protein residues are written as HETATM records in the deposited model, which the loader keeps because they are peptide-linking amino acids (`polymer_selector`; the raw loader count rose from 773 to 3735 atoms with that selector, the pipeline result of 7041 atoms with 3306 hydrogens did not change); the depositor's file `SASDB48_fit1.dat` has the model in column 3 and σ in column 4. Overlays the FoXS fit (χ² 2.4; recomputed from the file 2.407).

### SASDCA3: ZBTB38 zinc fingers / methylated DNA complex, Tris/TCEP/azide

```
julia --project=test/fitting_tests test/fitting_tests/SASDCA3/SASDCA3_fit3.jl
```

Fits the HADDOCK/SASREF model (`fit3`; fit1 and fit2 are not bundled) of ZBTB38 (1006-1153) bound to the 54-nt methylated CZ38BS duplex (34.0 kDa) in 10 mM Tris, 1 mM TCEP, 0.05 % NaN₃, 10 % D₂O, pH 6.8, 22 °C, 8.05 keV (0.154 nm), q ≤ 0.3 Å⁻¹. **Unique:** mixed protein + DNA with five zincs written as ATOM records (`ZN`, `ZN2`) and DNA residue names `G C A T`; the .dat is in nm⁻¹ and desmeared (absolute scale); the buffer has no salt but the azide, so the ionic strength is very low (Cl⁻ from Tris-HCl, fraction 0.963); 10 % D₂O has no table entry and is treated as H₂O (the X-ray effect is negligible); the DNA methylation is not in the model. Seed build: `mixed: PARSE, titration propka`, 24 residue names all in the table, 3997 atoms from the 2299 of the file. Overlays CRYSOL fit3 (χ² 1.643).

**D₂O:** 10 % v/v is modelled as a solute (5.514 M ± 5 %, ϕ° 18.132 cm³/mol), which changes ρₑ by −0.042 % against treating it as H₂O. The stored fit3 results predate this and are stale.

### SASDCM5: vaccinia E9 polymerase + template-primer DNA, Tris/NaCl/DTT

```
julia --project=test/fitting_tests test/fitting_tests/SASDCM5/SASDCM5.jl
```

Fits the E9 exo⁻ polymerase (1010 residues) bound to a 29-nt template-primer hairpin DNA (126.2 kDa; SEC-SAXS) in 100 mM NaCl, 20 mM Tris-HCl, 4 mM DTT, pH 7.0, 20 °C, 12.5 keV, q ≤ 0.25 Å⁻¹ (the depositor's CRYSOL curve ends there). Tris counter-ion Cl⁻ 19.0 mM (fraction 0.949, I ≈ 0.119 M); the .dat is in nm⁻¹. **Unique:** a mixed protein-DNA model (8838 heavy atoms, chains A, P, T) with a modified nucleotide (`DOC`, 2',3'-dideoxy-C, HETATM), hydrogenated through its parent DC (12 hydrogens placed, 14 in the free component's formula), a dCTP ligand (`DCP`, 28 heavy atoms, HETATM), 89 waters and one Ca²⁺. **Open:** `DCP` is not a nucleotide (the table has it as a non-polymer), so it receives no hydrogens and is not reported by the modified-nucleotide note; the loader drops it from the model. Seed build: 17137 atoms, lMax 28. Overlays CRYSOL (χ² 1.08).

### SASDDF7: armless mitochondrial tRNA-Arg, HEPES/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDDF7/SASDDF7.jl
```

Fits the armless mitochondrial tRNA-Arg of *Romanomermis culicivorax* (64 nt, 13.4 kDa, single chain; 6 mg/mL SEC-SAXS) in 50 mM HEPES-NaOH, 10 mM MgCl₂, pH 7.4, 15 °C (the SEC elution temperature), 12.0 keV, q ≤ 0.4 Å⁻¹ (the depositor's fit stops there; the data reach 0.61 Å⁻¹ and are noisy beyond). HEPES titrated with NaOH (stated): Na⁺ = 0.435 of the concentration; MgCl₂ ±1 %. **Unique:** a small RNA with a divalent counter-ion in the buffer. Seed build: 880 deposited atoms, 1326 with hydrogens, 132 binned points. Overlays CRYSOL fit1 (χ² 1.955).

### SASDF95: HigA-DNA complex (P. aeruginosa), Tris/NaCl/glycerol

```
julia --project=test/fitting_tests test/fitting_tests/SASDF95/SASDF95_fit2.jl
```

Fits the PaHigA-DNA complex (HigA on a 32-bp DNA duplex; chains A, B, E, F protein and C, D DNA; 4073 atoms, 42.5 kDa, merged 1-5 mg/mL curve) in 20 mM Tris, 300 mM NaCl, 5 % v/v glycerol, 1 mM PMSF, pH 8.0, 23 °C, 12.04 keV (0.103 nm), q ≤ 0.3 Å⁻¹. **Unique:** four protein chains (two dimer copies) plus a DNA duplex in one model; glycerol (0.685 M, as in SASDJ62/SASDJ72) and PMSF (our own estimated table entry, as in SASDYW6) in the buffer; Tris-HCl counter-ion estimated (Cl⁻ 0.661 of 20 mM at pH 8.0, I ≈ 0.313 M); the SEC-like merged curve has 3 non-positive points of 844. The seed build gives 7607 atoms; pdb2pqr dropped 2 `H5T` hydrogens (restored phosphorus) and added 4 heavy atoms, which are kept and warned about. Overlays CRYSOL fit2 (χ² 6.229).

### SASDG24: Dengue sfRNA (423 nt), Tris/NaCl/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDG24/SASDG24.jl
```

Fits one deposited atomistic model of the 423-nt Dengue-2 subgenomic flavivirus RNA (136.9 kDa; 12366 atoms including 3305 hydrogens, blank chain id) in 100 mM NaCl, 20 mM Tris-HCl, 5 mM MgCl₂, pH 7.5, 25 °C, 14.0 keV, q ≤ 0.25 Å⁻¹. **Unique:** the largest RNA of the set; the residues carry the legacy names `GUA ADE URI CYT`, which the wwPDB uses for the free bases, so the pipeline recognises them by the backbone rule of the Hydrogenator README (423 residues; the rule is implemented as the owner approved it (see the Hydrogenator README)), and pdb2pqr then places the hydrogens correctly (13637 atoms: 9061 heavy and 4576 hydrogens). **Depositor comparison:** the depositor's curve is an EOM ensemble fit (50 ensembles), not this model's; the recorded χ² is 0.35 (fit-file header and SASBDB), 2.49 when recomputed from the file with the rescaled column 3. The .dat has a q = 0 row and two σ = 0 rows, which are dropped; the model's chain id is blank (pdb2pqr writes `A`). All B-factors of the model are 0.00, which is not a defect.

### SASDH39: Argonaute-DNA complex (A. fulgidus), Tris/MgCl₂/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDH39/SASDH39_fit1.jl
```

Fits the *A. fulgidus* Argonaute dimer with a 14-mer DNA duplex (chains A-F; 7282 atoms, 110.4 kDa, SEC-SAXS) in 20 mM Tris-HCl pH 7.5, 5 mM MgCl₂, 150 mM NaCl, 2 mM DTT, 20 °C, 10 keV (0.123981 nm), q ≤ 0.3 Å⁻¹ (the depositor's cut; the .dat, in nm⁻¹, reaches 0.73 Å⁻¹). Tris counter-ion Cl⁻ 17.2 mM (I ≈ 0.182 M). **Unique:** the nucleic part is only 19 residues, named `A C G U` although SASBDB types the sample DNA and the residues have no `O2'`; at the first seed build nothing relabelled them and pdb2pqr treated them as RNA, whereas the plain-letter rule of the Hydrogenator README now relabels them as DNA in the pdb2pqr copy (to be confirmed by the load check). Also 160 MSE (selenomethionine) HETATM atoms, which the loader now keeps and hydrogenates through MET (selenium run as SD, then restored: loaded atoms 13927 → 14270 with 160 MSE atoms and 183 hydrogens; before, they were dropped silently), 57 waters and 2 Mg²⁺, and a SEC-SAXS curve with 242 non-positive points. Seed build (before the MSE change): 13927 atoms. Overlays CRYSOL fit1 (χ² 7.686).

### SASDJ66: GATA element duplex DNA (Fep1 promoter), MOPS/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDJ66/SASDJ66_fit1.jl
```

Fits the 24-bp-class GATA duplex (chains Q and R, 22 nt each, from PDB 4L62; 13.7 kDa, SEC-SAXS, at most 1.35 mg/mL) in 50 mM MOPS, 50 mM NaCl, pH 7.0, 20 °C, 12.4 keV (0.09999 nm), q ≤ 0.45 Å⁻¹ (the data reach 0.49 Å⁻¹ with a noisy tail). **Unique:** DNA-only entry (no protein), non-`A` chain ids, a SEC-SAXS curve with 151 non-positive points (the fit uses every point; the plots hide them); MOPS titrated with NaOH (Good's buffer convention), Na⁺ = 0.4285 of 50 mM, estimated from Goldberg's pK (7.184) with a ΔH from memory of the table; the paper is not open access, so only SASBDB's metadata were used. The model has no hydrogens (895 heavy atoms; 1401 atoms after pdb2pqr). Overlays CRYSOL (χ² 1.044).

### SASDJZ2: EcoKMcrA N-terminal domain with hemimethylated 12-bp DNA, Tris/KCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDJZ2/SASDJZ2_fit1.jl
```

Fits the EcoKMcrA N-terminal domain bound to a 12-bp oligoduplex (chain A protein, chains G, H DNA; 1876 atoms, 28.1 kDa, 1.14 mg/mL) in 20 mM Tris-HCl pH 7.5, 200 mM KCl, 0.1 mM EDTA, 0.01 % NaN₃, 1 mM DTT, 20 °C, 9999 eV (0.124 nm), q ≤ 0.3 Å⁻¹. Same buffer as the sister entry SASDJY2 (Cl⁻ 17.2 mM, I ≈ 0.217 M). **Unique:** the .dat is in nm⁻¹ with 54 non-positive points; SASBDB notes that the DNA of the model is homologous, not identical in sequence, to the measured DNA. Seed build: 3523 atoms; pdb2pqr added 1 heavy atom (kept, warned about). Overlays CRYSOL fit1 (χ² 1.654).

**Known buffer omission:** EDTA 0.1 mM, cations not stated, the tetra-anion is modelled (est. up to +0.0004 % as Na⁺).

### SASDK36: LC-18t DNA aptamer, PBS-like buffer (PARKED, buffer open)

```
julia --project=test/fitting_tests test/fitting_tests/SASDK36/SASDK36.jl
```

**Parked by the owner (buffer and citation questions to be settled; do not treat the setup as final).** Fits a GROMACS MD frame of the 35-nt ssDNA aptamer LC-18t (chain X, 10.8 kDa, 1109 atoms) at pH 7.4, 20 °C, 10.3 keV, q ≤ 0.30 Å⁻¹. **Unique:** SASBDB says only "phosphate-buffered saline"; the paper states Na⁺ 146 mM and Mg²⁺ 0.5 mM, taken here as NaCl and MgCl₂ (phosphate and K⁺ are left out, no counter-ion). The .dat is in nm⁻¹ (merged curve, 50 trailer lines). The seed build gives 1116 atoms from the 1109 of the file. Overlays CRYSOL fit2 (χ² 2.615).

**Known buffer omissions:** PBS phosphate and K⁺, concentration unknown (est. +0.114 % for the standard PBS recipe); the 146 mM Na⁺ is taken wholly as NaCl though part may be phosphate sodium.

### SASDK94: BusR-dsDNA complex, HEPES/NaCl/glycerol

```
julia --project=test/fitting_tests test/fitting_tests/SASDK94/SASDK94_fit1.jl
```

Fits the BusR-DNA model (protein chains A-D and DNA strands E, F; 152 kDa; 8371 atoms in the file, 8283 expected after the loader drops two cyclic-di-AMP HETATM residues, `2BA`, which the component table has as a non-polymer) in 20 mM HEPES, 100 mM NaCl, 3 % v/v glycerol, pH 6.5, 20 °C, 10 keV (0.123981 nm), q ≤ 0.3 Å⁻¹ (data to 0.60). HEPES titrated with NaOH: Na⁺ 1.84 mM (9 % deprotonated at pH 6.5); glycerol 0.411 M ±5 %. **Unique:** the largest mixed entry (4 protein chains + 2 DNA strands), SEC-SAXS in nm⁻¹ with a flat σ noise floor above 0.25 Å⁻¹; the c-di-AMP is in the model but not in the buffer text. Seed build: 15822 atoms. **Depositor comparison:** the fit file header gives χ² 5.820 (the entry records 5.635) and recomputing it over q ≤ 0.3 alone gives 10.1; the software is not stated (the header columns "Convex/Concave/Inner" are those of SASDU29's file, which looks like Pepsi-SAXS), so the overlay is labelled "SASBDB fit1".

### SASDM76: 201D G-quadruplex DNA, BPEK buffer

```
julia --project=test/fitting_tests test/fitting_tests/SASDM76/SASDM76.jl
```

Fits the 28-nt G-quadruplex 201D (8.9 kDa; 914 atoms including 322 hydrogens and 3 K⁺) in 185 mM KCl, 6 mM Na₂HPO₄, 2 mM NaH₂PO₄, 1 mM Na₂EDTA, pH 7.2, 22 °C, 12.0 keV, q ≤ 0.3 Å⁻¹. **Unique:** the smallest nucleic-acid entry (lMax 13); the phosphate species are used as stated (no titrant counter-ion; the stated 3:1 split would not give pH 7.2 and is not corrected); Na₂EDTA is entered as the `H2EDTA` table row plus 2 mM Na⁺. `ADD_HYDROGENS` stays `true`: pdb2pqr replaced the 322 deposited hydrogens by its own 324 (913 atoms in the model, the 3 K⁺ kept). Overlays CRYSOL (χ² 1.779).

### SASDNH7: Tn3 resolvase-site II DNA complex, Tris/NaCl/MgCl₂/glycerol

```
julia --project=test/fitting_tests test/fitting_tests/SASDNH7/SASDNH7_fit1.jl
```

Fits the resolvase dimer on the 52-bp site II DNA (protein chains C, D and DNA strands Y, Z; 75 kDa; 4980 atoms, no hydrogens) in 25 mM Tris, 150 mM NaCl, 10 mM MgCl₂, 1 % v/v glycerol, pH 7.5, 22 °C, 12.04 keV (0.103 nm), q ≤ 0.15 Å⁻¹ (data to 0.48; 437 of 1374 points are ≤ 0, none below 0.22 Å⁻¹). Tris-HCl counter-ion Cl⁻ 21.5 mM (I ≈ 0.201 M). **Unique:** the depositor's fit file is not served by the SASBDB API (404) and was fetched from the media URL `https://www.sasbdb.org/media/fitting_files/SASDNH7_fit1.fit`. It is a FoXS profile (3 `#` header lines, 559 rows, q 0.0083-0.1997 Å⁻¹) whose I_exp column equals the deposited .dat (ratio 1.0 ± 6e-8) and whose χ² (16.465, recomputed 16.4653, 21.5 over q ≤ 0.15) is the entry's depositor value; its column 4 is the final scaled model and is overlaid unchanged. Seed build: 9124 atoms; 2 `H5T` hydrogens removed with the restored phosphorus, 2 heavy atoms added by pdb2pqr (kept, warned about). Overlays the FoXS fit (a poor depositor fit).

### SASDNK7: c-MYC Pu22 G-quadruplex DNA, Tris/KCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDNK7/SASDNK7_fit1.jl
```

Fits the 22-nt MYC22-G14T/G23T G-quadruplex (PDB 1XAV-derived, 7.1 kDa, 1.8 mg/mL) in 50 mM Tris, 30 mM KCl, pH 8.0, 25 °C, 8.27 keV (0.15 nm), q ≤ 0.5 Å⁻¹. **Unique:** the .dat has a 212-line comment header (`skipstart = 212`) and 54 non-positive points; the model carries 249 hydrogens and two K⁺ ions as HETATM residues `K` (kept as ions: 718 atoms before and after pdb2pqr); Tris-HCl counter-ion estimated (Cl⁻ 0.639 of 50 mM, I ≈ 0.062 M). `ADD_HYDROGENS` stays `true` although the model has hydrogens (as for SASDWZ9). Overlays CRYSOL (χ² 1.391).

### SASDNP7: aIF2-GDPNP-tRNA complex, MOPS/NaCl/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDNP7/SASDNP7_fit1.jl
```

Fits the aIF2 γ/α-tRNA model (chains A, B, D; 5693 atoms; GNP, Mg²⁺, 7 selenomethionines and five modified tRNA bases PSU, 4SU, 5MU, H2U, OMC as HETATM) at 1.65 mg/mL in 10 mM MOPS-NaOH pH 6.7, 200 mM NaCl, 5 mM MgCl₂, 1 mM GDPNP, 15 °C, 12.4 keV (0.1 nm as recorded), q ≤ 0.3 Å⁻¹. MOPS titrated with NaOH: Na⁺ 2.88 mM (A⁻ fraction 0.288). **Unique:** modified nucleotides in a mixed model (to be hydrogenated through their parent bases); the curve is the one without Gd-HPDO3A; GDPNP is not in the solute tables and is left out; a poor depositor fit (CRYSOL χ² 29.6) with a 3-column fit file (q, I_exp, I_fit). **Open, not resolved:** the seed build fails. pdb2pqr aborts on its charge-integrality check ("Residue RG D 2 has non-integer charge: -0.34"; the total it then reports was -66.34 and is -71.34 now that the loader keeps the modified amino acids, 7 more atoms), the residue named in the message is not the cause: chain D is an aminoacylated tRNA (G2 ... A76 followed by MET101), so pdb2pqr's 3' patch never applies and the 5' patch alone leaves a fractional charge (deleting MET D 101 makes pdb2pqr succeed). Remedy (a chain id of its own for the terminal non-nucleic residue in the temporary pdb2pqr copy, heavy atoms always from the user's file): approved in principle by the owner, not implemented. This entry cannot be fitted until then.

**GDPNP:** 1 mM is modelled as the tetrasodium salt (3D-RISM estimate anchored on the measured GTP tetrasodium, 288.8 ± 22 cm³/mol), +0.026 % in ρₑ; the real cations are not stated. Stored results predate this and are stale.

### SASDPN6: SARS-CoV-2 5'-genomic stem-loop 4 RNA, potassium phosphate/KCl/TCEP

```
julia --project=test/fitting_tests test/fitting_tests/SASDPN6/SASDPN6_fit1.jl
```

Fits the RNAMasonry model of the 69-nt stem-loop 4 with AU extension (chain A, 22.1 kDa; 2191 atoms, of which 731 are the builder's hydrogens named H01-H12) in 25 mM potassium phosphate, 150 mM KCl, 2 mM TCEP, pH 6.5, 20 °C, 10 keV (0.124 nm), q ≤ 0.3 Å⁻¹ (data to 0.74). Potassium phosphate split as for SASDVX2 (KH₂PO₄ 17.0 mM, K₂HPO₄ 8.0 mM, HPO₄²⁻ fraction 0.320); TCEP taken neutral, no counter-ion. **Unique:** a SEC-SAXS RNA-only entry whose deposited model already carries hydrogens; `ADD_HYDROGENS` stays `true`, as for SASDT55 and SASDWZ9 (SASDP48 and SASDJ62 use `false` only because pdb2pqr aborts on their PDB-v2 protein hydrogen names), and pdb2pqr accepted the builder's names (2929 atoms: 1460 heavy plus 1469 hydrogens). The 5' end has a phosphate whose `OP2` has the element column `O1-`. Overlays the Pepsi-SAXS fit (χ² 1.224; the file header says 1.143).

### SASDPU6: duplex-G4-duplex DNA, phosphate/EDTA/KCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDPU6/SASDPU6.jl
```

Fits the 46-nt duplex-embedded G-quadruplex DNA (28.6 kDa; an AMBER MD model with 1055 hydrogens and two K⁺ ions, blank chain id; 6.6 mg/mL SEC-SAXS) in 6 mM Na₂HPO₄, 2 mM NaH₂PO₄, 1 mM Na₂EDTA, 185 mM KCl, pH 7.2, 25 °C, 12.0 keV (0.1033 nm), q ≤ 0.3 Å⁻¹ (data to 0.347). **Unique:** the Na₂EDTA is the `H2EDTA` table row plus two Na⁺; the phosphate amounts are taken as stated (no titrant counter-ion). The ions have the PDB-v2 residue name `K+` (the wwPDB id is `K`): the first seed build stopped at the component lookup (`ComponentError: couldn't look up residue "K+"`); the lookup now takes a name that cannot be a wwPDB id as an unknown, non-nucleotide residue without a network access (MolecularStructure README), which the load check has to confirm for this script. Overlays CRYSOL fit1 (χ² 1.265, an AMBER MD model).

### SASDQ69: 28 bp double-stranded DNA, KCl/Tris

```
julia --project=test/fitting_tests test/fitting_tests/SASDQ69/SASDQ69.jl
```

Fits the GROMACS model of a 28-bp B-DNA duplex (chains A and B, 17.3 kDa, 1772 atoms) in 100 mM KCl, 50 mM Tris, 1 mM DTT, pH 7.0, 24.9 °C, 12.4 keV, q ≤ 0.30 Å⁻¹. **Unique:** a nucleic-acid-only entry (no PROPKA run); the model already carries 630 hydrogens, which pdb2pqr rebuilds to the same count (1772 atoms); an in-line SEC-SAXS curve with 81 non-positive points; Tris-HCl counter-ion Cl⁻ 47.5 mM computed as in SASDMJ9. All B-factors of the model are 0.00 (not a defect). Overlays the depositor's FoXS fit (χ² 1.100; recomputed 1.082 for q ≤ 0.3).

### SASDSW7: poly(UG) RNA, HEPES/KCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDSW7/SASDSW7_fit1.jl
```

Fits the (GU)12 RNA (24 nt, 7.8 kDa; XPLOR-NIH model, 767 atoms with 254 hydrogens) in 20 mM HEPES, 150 mM KCl, pH 7.0, 22 °C, 13.3 keV (0.0932 nm), q ≤ 0.5 Å⁻¹ (the curve reaches 0.88 Å⁻¹). **Unique:** the curve is the concentration series (0.26 to 1.6 mg/mL) extrapolated to infinite dilution; HEPES titrated with NaOH is assumed (Na⁺ 0.2482 of the concentration) although the buffer is potassium based (open point, the effect is a few mM); `ADD_HYDROGENS` stays `true` despite the model's own hydrogens (as for SASDWZ9). All B-factors of the model are 0.00 (not a defect). Overlays the depositor's Pepsi-SAXS fit (χ² 2.688).

### SASDSX5: nucleosome core particle (Widom 601), Tris/KCl/DTT (PARKED)

```
julia --project=test/fitting_tests test/fitting_tests/SASDSX5/SASDSX5.jl
```

**Parked by the owner (SASBDB records no publication or DOI; the paper to cite and whether its buffer matches SASBDB's remain open).** Fits the nucleosome core particle (Xenopus histone octamer and 145-bp Widom 601 DNA, 13579 heavy atoms, chains A-J, 198.7 kDa; SEC-SAXS) in 50 mM KCl, 20 mM Tris-HCl, 1 mM DTT, pH 8.0, 15 °C, 12.4 keV (1.0 Å), q ≤ 0.3 Å⁻¹, from SASBDB's metadata only (Tris-HCl counter-ion Cl⁻ 12.8 mM, I ≈ 0.063 M). **Unique:** the largest mixed model of the set (25051 atoms after hydrogenation, lMax 62; the seed build took 108 s, 104 s of them in pdb2pqr). Overlays the Pepsi-SAXS fit (χ² 1.28).

### SASDT55: influenza B NS1-CTD with 5'-triphosphorylated hairpin RNA, ammonium acetate/NaCl/CaCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDT55/SASDT55.jl
```

Fits the HADDOCK model of NS1B-CTD* (15.9 kDa) bound to the 24-nt 5'ppp hairpin RNA (chains A, B; 2173 atoms, 532 hydrogens) in 40 mM ammonium acetate pH 5.5, 225 mM NaCl, 5 mM CaCl₂, 0.02 % NaN₃, 50 mM arginine, 20 °C, 12 keV (stated), q ≤ 0.25 Å⁻¹ (data to 0.30). **Unique:** the RNA carries legacy residue names (`GUA ADE URI CYT`, and `GTP` for the triphosphate end), recognised by the backbone rule of the Hydrogenator README (the rule is implemented as the owner approved it (see the Hydrogenator README); `test_legacy_nucleotides.jl` runs pdb2pqr on this model); arginine and ammonium acetate are neutral table entries with no counter-ion (the pH adjuster is unknown). Seed build: 3027 atoms. Overlays the depositor's Pepsi-SAXS fit (χ² 1.026; recomputed 0.995).

**Known buffer omissions** (`BUFFER_OMISSIONS`, warned on every run): arginine 50 mM, anion unknown (est. +0.074 % if Cl⁻, +0.060 to +0.087 % if acetate); the acid or base that sets pH 5.5 is not stated, no titrant ion modelled (est. < 0.006 %).

### SASDU29: CRX homeodomain / Ret4 DNA complex, Tris/KCl/glycerol/TCEP

```
julia --project=test/fitting_tests test/fitting_tests/SASDU29/SASDU29_fit1.jl
```

Fits the 2:1 CRX homeodomain : Ret4 DNA complex (chains A, B protein, E, F the two 20-nt strands; 31.9 kDa; SEC-SAXS) in 20 mM Tris, 150 mM KCl, 5 % glycerol, 1 mM TCEP, pH 7.5, 22 °C, 12.0 keV (0.1033 nm), q ≤ 0.3 Å⁻¹. **Unique:** 6 glycerol HETATM atoms (`GOL`) in the model are not nucleotides and are dropped; the .dat is SASBDB's display copy scaled by 1e7 while the .fit file is unscaled, so the reference curve is multiplied by `FIT_FILE_SCALE` = 1e7 (the fit is scale-free); 5 % v/v glycerol is 0.685 M (±5 %); Tris-HCl counter-ion Cl⁻ fraction 0.857. Seed build: 3449 atoms. Overlay labelled "SASBDB fit1" (the depositor's software is not stated; header χ² 1.546).

### SASDVU5: MpARF3 DNA-binding domain + DNA, Tris/NaCl/DTT

```
julia --project=test/fitting_tests test/fitting_tests/SASDVU5/SASDVU5.jl
```

Fits a SwissModel-based model of the MpARF3 DNA-binding domain (chain A) with its two 20-mer DNA strands (chains C, D; 57.9 kDa; 3.5 mg/mL) in 20 mM Tris-HCl, 150 mM NaCl, 1 mM DTT, pH 8.0, 20 °C, 12.4 keV (0.1 nm), q ≤ 0.3 Å⁻¹. **Unique:** a protein-DNA model; the experimental file is in nm⁻¹; SASBDB cautions that Dmax appears underestimated; the model carries ANISOU records (they did not hurt the seed build: 3988 atoms deposited, 7495 with hydrogens). Overlays the Pepsi-SAXS fit (χ² 2.613), which stops at 0.5 Å⁻¹.

### SASDVV4: ST9 viral RNA (54 nt), Tris/NaCl/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDVV4/SASDVV4_fit1.jl
```

Fits the 54-nt ST9 RNA (chain A, one Mg²⁺ HETATM, no hydrogens in the model) from an in-line SEC-SAXS run (3 mg/mL injection) in 50 mM Tris pH 7.5 (from the buffer name; the SASBDB field is empty), 100 mM NaCl, 1 mM DTT, 10 mM MgCl₂, 0.0002 % NaN₃, 20 °C, 15.1 keV (0.082 nm), q ≤ 0.3 Å⁻¹. Tris-HCl counter-ion Cl⁻ 42.9 mM. **Unique:** the first nucleic-acid-only script written; the .dat runs to 3.19 Å⁻¹, beyond the q-unit sanity range, so only q ≤ 0.5 is sanity-checked (the fit stops at 0.3); the Pepsi-SAXS fit file stops at 1.48 Å⁻¹. Seed build: 1773 atoms (the RNA with hydrogens and the Mg²⁺), `nucleic: PARSE, titration none` at the time of writing (the pipeline now chooses AMBER for a nucleic acid alone). Overlays Pepsi-SAXS (χ² 0.876).

### SASDVX2: SARS-CoV-2 5'-UTR stem-loop 5 RNA (~148 nt), potassium phosphate/KCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDVX2/SASDVX2_fit1.jl
```

Fits the PyMOL-built all-atom model (3078 atoms, no hydrogens) of the 48.3 kDa stem-loop 5 RNA at 1.0 mg/mL in 25 mM potassium phosphate, 50 mM KCl, pH 6.2, 10 °C, 10 keV, q ≤ 0.3 Å⁻¹. The phosphate is split into KH₂PO₄ 20.85 mM / K₂HPO₄ 4.15 mM (HPO₄²⁻ fraction 0.166, I ≈ 0.083 M; the potassium phosphates in the tables are derived values, see the BulkElectronDensity README). **Unique:** a poor depositor fit (Pepsi-SAXS χ² 6.97); the entry also exists in Mg²⁺ variants, this curve is the plain 50 mM KCl sample (named in the .dat header). Seed build: 4634 atoms, 182 binned points. Overlays the Pepsi-SAXS fit.

### SASDWJ4: class V GTP-binding RNA aptamer + GTP (crystal model), Bis-Tris/KCl/MgCl₂ (PARKED)

```
julia --project=test/fitting_tests test/fitting_tests/SASDWJ4/SASDWJ4_fit2.jl
```

**Parked by the owner (the GTP concentration and the buffer are open) and not buildable yet.** Fits the crystal structure of the 68-nt aptamer with two GTP, K⁺ and Mn²⁺ ions (HETATM; deposited with 745 hydrogens) at 6 mg/mL in 50 mM Bis-Tris, 50 mM KCl, 2 mM MgCl₂, pH 6.5, 20 °C, 10 keV, q ≤ 0.3 Å⁻¹. Bis-Tris pK 6.484 and ΔH 28.4 kJ/mol come from a secondary calculator page (Goldberg's table was not read), HCl as titrant (Cl⁻ 28.9 mM). **Unique:** the free-GTP concentration is not stated and GTP is not in the solute tables, so it is not a solute; the Pepsi-SAXS fit file is divided by the concentration (6.0) and rescaled onto the data for the overlay (χ² 10.774). **Open, not resolved:** the seed build fails. pdb2pqr aborts on its charge-integrality check ("Residue RC A 68 has non-integer charge: -0.66", "-66.66 deviates by 0.34 from integral") not at the residue the message names: chain A begins with a 5' GTP ligand (HETATM), so pdb2pqr's 5' patch never applies and the 3' patch alone leaves a fractional charge (deleting the leading GTP makes it succeed). Remedy (a chain id of its own for the terminal non-nucleic residue in the temporary pdb2pqr copy): approved in principle by the owner, not implemented. Setting `ADD_HYDROGENS = false` would avoid the run but was not applied.

**Known buffer omission:** free GTP, concentration unknown (GTP is in the tables now; est. +0.026 % per mM as the tetrasodium salt).

### SASDWR5: stimulatory element RNA, HEPES/KCl/glycerol

```
julia --project=test/fitting_tests test/fitting_tests/SASDWR5/SASDWR5.jl
```

Fits the 37-nt stimulatory-element RNA (11.8 kDa, SREFLEX model from an AlphaFold template, 7.1 mg/mL SEC-SAXS) in 20 mM HEPES, 400 mM KCl, 2 % v/v glycerol, 1 mM DTT, pH 7.4 (from the buffer text; the SASBDB field is empty), 20 °C, 10.0 keV, q ≤ 0.5 Å⁻¹ (the depositor's fit ends there). HEPES is assumed titrated with NaOH (Na⁺ 0.463 of the concentration); 2 % glycerol becomes 0.274 M (±5 %); the .dat is in nm⁻¹. **Unique:** RNA-only entry; the entry's Coot model (`fit3`, χ 13.95) is not fitted. Seed build: 782 heavy atoms, 1184 atoms with hydrogens. Overlays CRYSOL fit1 (χ² 1.11).

### SASDYM2: prothrombin + NU172 aptamer, Tris/PBS-like/CaCl₂/glycerol

```
julia --project=test/fitting_tests test/fitting_tests/SASDYM2/SASDYM2.jl
```

Fits a MultiFoXS-derived model of human prothrombin (chain A) with the G-quadruplex-forming DNA aptamer NU172 (chain E; 80.2 kDa; 0.22 mg/mL) in 10 mM Tris-HCl, 137 mM NaCl, 2.7 mM KCl, 5 mM CaCl₂, 1 % v/v glycerol, pH 7.4, 20 °C, 13.05 keV (0.095 nm read as the B21 wavelength), q ≤ 0.3 Å⁻¹. **Unique:** a protein-DNA model; the deposited buffer text ends with a comma (a component may be missing, none is guessed); 380 non-positive points (handled by the binning); the deposited FoXS χ² 0.286 means the error bars are overestimated. Seed build: 9787 atoms from the 5128 deposited. Overlays the FoXS fit.

**Known buffer omission:** the component after the comma that ends the recipe is unknown (est. 0.002 to 0.015 % per mM).
