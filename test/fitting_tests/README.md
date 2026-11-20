# Fitting tests

**Note:** Entries in `BAYSOL.BulkElectronDensity` without uncertainties use an uncertainty estimated from the mean of the available experimental uncertainties. As the table grows, this estimate may change slightly, so fit results may change.

End-to-end BAYSOL fits of 116 SASBDB entries: 56 with a single-structure reference fit to compare against (see "Which entries are benchmarks") and the replacement entries (see "Replacement entries"; a few have no reference fit); protein, DNA and RNA structures (see "Nucleic-acid entries" below). The Results table holds the runs that passed the convergence gate: load a structure, build its buffer, find the mode with a multi-start L-BFGS search and whiten around it, run the NUTS sampler over `ξ = (ρₑ, δρ₁, δρ₂, δρ₃)` with the excluded-volume correction `c1` profiled at every evaluation (to `EXCL_VOL_CORR_TOL` = 1e-8; see the Inference README for why that tight), and write the MAP/posterior report, the figures (`plots/`) and the data (`data/`)
next to the script. The fitted curve is the deposited SASBDB curve (q in Å⁻¹; the whole curve unless the script sets a `Q_MAX_FIT`, see "The q cut"), which `seedModel` bins to at least 12 bins per Shannon channel π/D (D: the diameter of the structure and its hydration shell; a precise curve gets finer bins, up to the point of being fitted as measured, so that the binning's worst-case bias stays under 0.3 of its smallest error bar) and from which it takes `lMax = ceil(qMax·D)`; the lMax and point counts below are those of the latest run, and each run's `run` sheet lists `dmax`, the channels, the `rebin` used and the points before and after binning. χ² is reported on the measured q grid (the binned fit's model interpolated onto it, over all measured points), the convention of FoXS's own χ², and so of the depositors' numbers (a reduced χ² with N − 3 degrees of freedom: scale, background and c1).

```
julia --project=test/fitting_tests test/fitting_tests/<ID>/<script>.jl
```

or, through the dev tool, which also lists the IDs and can run several (`bysl fits list`, `bysl fits run SASDMJ9 SASDTK5`, `bysl fits run` for all of them). To turn the figures' `.tex` files into PDF (or SVG, PNG): `bysl plots render test/fitting_tests --recursive`.

Every script calls `BAYSOL.results`, which always writes the run log and the statistics log, and each fit leaves, in its folder: the workbook `res*.xlsx` (the run's settings and sampler statistics, the MAP, the posterior quantiles, the curves, the histogram counts, every draw and every divergent transition (`divergences`), one sheet each; see the Pipeline README for the sheets) and a section in the folder's run log `<ID>.LOG` (one file for all the runs of the folder, tracked in git: the timings and what a benchmark needs, see "The run log" in the Pipeline README; the run's own statistics (every attempt, its settings, chains and gate) are in `statistics-<ID>.LOG`, same sections; the depositor's χ² is the `refChi2 = "…"` argument of the script's `results` call, printed as the `refChi2` row); in `plots/`, the figures as pgfplots `.tex` files (`res.tex` the fit, `res_residuals.tex`, one `res_hist_<parameter>.tex` for each of ρₑ, δρ₁, δρ₂, δρ₃, scale, background and c1 (`res_hist_rhoE.tex`, …, `res_hist_c1.tex`), and `res_comparison.tex` when the entry has a depositor curve to compare with). The same figures are printed in the terminal while the script runs. LaTeX is **not** run by default (it takes about a second per figure); to get PDFs pass `compile = true` to the `results` call, or run `bysl plots render test/fitting_tests/<ID>`, or `lualatex res.tex` in `plots/` (the `.tex` files are standalone documents). The time of the figures is in the log's timings, whose last two rows are `time.fit` and `time.plot`.

How to read the two logs, row by row, with a checklist for "did my fit work?", is in the "Reading the logs" section of the Pipeline README.

All fits use the `runModel` defaults: eight NUTS chains (more when the optima search starts chains at an optimum that carries mass), each of 1000 iterations (`BAYSOL.Pipeline.N_ADAPT + N_DRAWS`), the first 300 of them warm-up (step-size and mass-matrix adaptation) and discarded, leaving 700 draws per chain; a target acceptance of 95 %; and one longer rerun (2000 warm-up and 2000 draws, seeds derived from the run's own) when the worst within-mode R̂ is above 1.01. The `run` sheet of each fit has R̂, the effective sample sizes, the number of modes and, when it happened, the retry (a `modes` sheet lists the modes). The seed is 0. Each script defines `run_<id>(; nSamples, nAdapt, seed)` if you want to change these values; `nSamples` is the *total* iteration count, including the `nAdapt` warmup, and the scripts use these defaults. Each script also has a `seed_<id>(...)` that builds the `Seed` its `run_<id>` then samples. It only for the tools in `dev/`, which inspect a fit without running it; if you don't need extra tooling skip `seed_<id>`. The temperature is each entry's stated sample temperature (25 °C when none is given). Hydrogens are added with Pdb2pqr at the stated pH unless noted; for a nucleic acid they do not depend on the pH (see "Nucleic-acid entries").

**The q cut.** The default is no cut: `Q_MAX_FIT = Inf`, the whole deposited curve is fitted (only points with σ ≤ 0 are dropped by `fitSubset`; `seedModel` drops the non-positive bins). A finite `Q_MAX_FIT` is kept in two cases. (a) The data above it are demonstrably unusable, tested on the points above the cut with σ > 0: at least 20 of them, a median I/σ below 0.5, at least 25 % with I ≤ 0 and a median I/σ below 1 in the lowest-q quarter of them (a noise floor scatters about zero; a positive offset is a background problem, which the background term absorbs). (b) **The uncut fit diverges** (more than 0.1 % divergent transitions at any `δ`) **and a cut where the median I/σ falls to about 2 removes the divergences** (for example SASDWS5 with a cut at 0.4 Å⁻¹, SASDMA6 with a cut at 0.28 Å⁻¹ and SASDP74 with a cut at 0.25 Å⁻¹, where the strict gates failed on every rung at 0.3; the points above those cuts are noise-dominated but not yet at the 0.5 threshold of (a)). A cut can also do harm: SASDUU3 fails with one and is fitted uncut, and SASDM96 diverged 1.5 % cut at 0.3 Å⁻¹, 3.0 % at 0.27 and failed on ESS at 0.22, and passes uncut (0.07 %), because the cut leaves too few Shannon channels. So test both directions (uncut, and cut at I/σ ≈ 2) and keep what passes the gates. The depositor's q range, the run time and the model's reach are not reasons. Each script's comment at `Q_MAX_FIT` gives the measured numbers, and the audit of every script is in `notes/qcut-audit.md`.

Settings shared by every script live in `common.jl`, which each script includes: the sampler defaults (`N_SAMPLES`, `N_ADAPT`, `SAMPLER_SEED`), the default pH σ (`PH_METER_SIGMA` = 0.1) and macromolecule-molarity σ (`MOLARITY_REL_SIGMA` = 5 %), the nm⁻¹ → Å⁻¹ conversion and q-unit sanity check, the `.dat`/fit-file readers, (the figures are drawn by `BAYSOL.results`; its look is a `PlotStyle`, see the Pipeline README). Change them there, not in individual scripts. A script that deliberately differs keeps its own value inline, with a comment.

## Results

 The table is generated from the run logs (`bysl results table --update`), the depositor column from each run's `refChi2` row. Bold marks a parameter at a hard prior bound (δρ₁, δρ₂ ≤ 2; δρ₃ ∈ [−ρ̄ₑ/0.03, (`φ_max` − 1)·ρ̄ₑ/0.03] ≈ [−11.1, 2.8]), `c1` profiling saturation, or a chain with >5% divergent transitions. ″ repeats the line above: the models of one deposited fit share its depositor χ².

A run that does not pass the convergence gate (R̂ < 1.01 and bulk and tail ESS > 400 after the retry ladder) has no run log and is not in the table. Every statement below about R̂, divergences and parameters at bounds refers to the runs in the table.

<!-- results-table:begin (generated by bysl results table from the run logs; the depositor column is the refChi2 row of each run) -->
| Run | χ² (MAP) | depositor's χ² (method) | δρ₁ | δρ₂ | δρ₃ | c1 | divergences |
|---|---|---|---|---|---|---|---|
| SASD2P2 — | 0.904 | CRYSOL 0.899 | 0.15 | 0.58 | −2.72 | 1.142 | 0 |
| SASDA28 — | 0.578 | CRYSOL 1.13 | −0.01 | −0.48 | 0.07 | 1.254 | 0 |
| SASDA38 — | 0.959 | CRYSOL 1.51 | 0.68 | −2.70 | 2.69 | 1.189 | 0 |
| SASDA52 fit1 | 5.35 | CRYSOL 6.14 (the header Chi 2.48 is chi, not χ²) | 0.08 | 0.09 | **2.76** | 1.160 | 0 |
| SASDA58 — | 1.09 | CRYSOL 1.288 | 0.10 | 0.26 | 2.32 | 1.190 | 0.0 % |
| SASDAB6 — | 1.28 | CRYSOL 1.411 | 0.19 | −3.04 | −1.74 | 1.215 | 0 |
| SASDAC2 — | 1.36 | CRYSOL 1.452 | 0.19 | **1.95** | 1.50 | 1.193 | 0 |
| SASDAC9 — | 646 | FoXS 680.3 | −0.46 | −0.98 | −3.23 | 1.213 | 0 |
| SASDAH5 — | 1.47 | depositor 2.25 | **2.00** | **1.96** | −3.96 | 1.182 | 0 |
| SASDAK6 — | 1.36 | CRYSOL 2.048 | 0.51 | 0.54 | 2.00 | 1.119 | 0 |
| SASDAN8 — | 1.19 | CRYSOL 2.464 (header; 4.58 recomputed from the file with a free scale) | 0.07 | −3.93 | 2.55 | 1.245 | 0 |
| SASDAP8 — | 0.85 | CRYSOL 2.879 | 0.89 | −0.39 | −1.54 | **1.306 (saturated)** | 0 |
| SASDAQ2 — | 3.26 | CRYSOL 4.009 | 0.50 | −2.18 | −8.17 | 1.154 | 0 |
| SASDAX2 — | 0.674 | CRYSOL 0.668 (header Chi 0.816) | 0.15 | −0.10 | 0.80 | 1.140 | 0 |
| SASDB48 — | 1.26 | FoXS 2.4 | −0.97 | −0.98 | −10.77 | 1.211 | 0.0 % |
| SASDBZ2 — | 5.62 | CRYSOL 1.809 | 1.42 | **1.97** | **2.75** | 1.132 | 0 |
| SASDBZ5 — | 0.96 | CRYSOL 1.248 | −0.21 | 1.76 | −5.58 | 1.159 | 0 |
| SASDC36 fit1_model1 | 1.02 | CRYSOL 1.469 | 0.40 | −3.21 | −1.19 | 1.068 | 0 |
| SASDC36 fit2_model1 | 1.11 | SREFLEX 1.001 | −1.29 | −2.47 | −10.59 | 1.220 | 0.0 % |
| SASDC57 fit2 | **failed** |  | — | — | — | — | — |
| SASDC57 — | 1.14 | CRYSOL 1.059 | −0.87 | −0.61 | −10.32 | 1.238 | 0 |
| SASDCA3 fit3 | 1.54 | CRYSOL 1.643 | 0.54 | 0.67 | −0.56 | 1.164 | 0 |
| SASDCD8 — | 259 | CRYSOL 274.778 | −0.12 | −6.96 | **−11.16** | 1.261 | 0 |
| SASDCE8 — | 29 | CRYSOL 30.753 | −0.38 | **2.00** | −1.49 | 1.133 | 0 |
| SASDCF8 — | 19.6 | CRYSOL 7.441 | 0.07 | 1.05 | −2.93 | 1.155 | 0 |
| SASDCJ8 — | 17.5 | CRYSOL 29.490 | 1.09 | −3.82 | 0.55 | 1.140 | 0 |
| SASDCM5 — | 0.86 | CRYSOL 1.08 | 0.79 | 0.17 | −1.19 | 1.211 | 0 |
| SASDCQ2 — | 0.82 | MultiFoXS 1-state 0.85 | 0.56 | −0.50 | −6.75 | 1.162 | 0 |
| SASDCQ8 — | 1.04 | CRYSOL 1.055 | −1.18 | 0.57 | −4.21 | **1.314 (saturated)** | 0 |
| SASDCR9 — | 1.07 | CRYSOL 1.087 | −0.41 | −1.24 | −4.00 | 1.238 | 0.1 % |
| SASDD33 — | 0.994 | CRYSOL 1.007 | 0.21 | 0.59 | −0.69 | 1.179 | 0 |
| SASDD88 fit2_model1 | 0.993 | FoXS 4.50 | −0.08 | 1.43 | −0.37 | 1.229 | 0 |
| SASDD88 fit3_model1 | 0.866 | FoXS 2.79 | 0.32 | −2.78 | −6.34 | 1.216 | 0 |
| SASDDF7 — | 1.83 | CRYSOL 1.955 | −0.07 | 0.26 | −10.30 | 1.026 | 0 |
| SASDDG7 — | 1.39 | CRYSOL 1.659 | −0.69 | −0.58 | −9.44 | 1.279 | 0 |
| SASDDH7 — | 3.09 | CRYSOL 2.262 | 0.57 | −0.56 | 0.92 | 1.183 | 0 |
| SASDDH9 — | 0.791 | FoXS 0.889 | −0.44 | −5.15 | 1.76 | 1.260 | 0 |
| SASDDJ6 — | 2.43 | CRYSOL 3.664 | 0.80 | −1.01 | 0.39 | 1.161 | 0 |
| SASDDL3 — | 0.772 | CRYSOL 0.821 | 0.11 | 1.48 | −3.91 | 1.238 | 0.1 % |
| SASDDN6 — | 1.18 | CRYSOL 1.150 | 0.15 | 0.07 | 2.36 | 1.185 | 0 |
| SASDE27 — | 1.27 | CRYSOL 1.425 | −0.05 | 1.63 | 0.57 | 1.253 | 0 |
| SASDE35 — | 0.713 | FoXS 0.749 | 0.61 | 0.51 | −2.83 | 1.159 | 0.1 % |
| SASDE36 — | 10.7 | FoXS 2.821 | 0.11 | 1.91 | −9.64 | 1.139 | 0 |
| SASDEB5 — | 0.711 | CRYSOL 1.027 | −0.70 | 1.16 | −1.36 | 1.266 | 0 |
| SASDEC5 — | 0.898 | FoXS 0.951 | −0.67 | 1.17 | −5.54 | 1.240 | 0 |
| SASDEK4 — | 1.09 | CRYSOL 1.120 | 0.11 | −1.32 | −2.25 | 1.229 | 0 |
| SASDEL7 — | 2.61 | CRYSOL 3.155 | 1.17 | −1.45 | **2.77** | 1.162 | 0 |
| SASDEM3 — | 1.94 | CRYSOL 5.025 | 0.42 | −1.88 | 1.87 | 1.171 | 0 |
| SASDEP7 — | 0.995 | CRYSOL 1.123 | −0.16 | 1.66 | −5.17 | 1.251 | 0 |
| SASDEQ7 — | 0.763 | CRYSOL 1.001 | −0.05 | 0.43 | **2.75** | 1.257 | 0 |
| SASDES5 — | 0.858 | CRYSOL 1.399 | −0.01 | 1.26 | 1.81 | 1.243 | 0 |
| SASDEZ6 — | 3.08 | CRYSOL 4.792 | −0.00 | −0.77 | −10.90 | 1.242 | 0 |
| SASDF29 — | 1.17 | CRYSOL 1.167 | 0.06 | −0.14 | −4.26 | 1.189 | 0 |
| SASDF42 — | 1.33 | 2.10 | −0.67 | 0.99 | −5.80 | 1.240 | 0 |
| SASDF53 — | 0.98 | CRYSOL 1.275 | −0.75 | 1.10 | −7.41 | 1.239 | 0 |
| SASDF55 — | 1.5 | CRYSOL 1.857 | −0.70 | 0.97 | −10.29 | 1.252 | 0 |
| SASDF75 — | 1.18 | CRYSOL 1.815 | 0.26 | −0.94 | 2.01 | 1.177 | 0 |
| SASDF93 — | 1.21 | CRYSOL 1.678 | 0.29 | 0.54 | 0.06 | 1.136 | 0 |
| SASDF95 fit2 | 2.99 | CRYSOL 6.229 | 0.30 | −1.56 | **2.77** | 1.173 | 0 |
| SASDFC3 fit1 | 4.08 | FoXS 5.473 | −0.13 | 0.55 | −4.04 | 1.174 | 0 |
| SASDFD5 — | 1.38 | CRYSOL 1.545 | −0.96 | 1.02 | −10.79 | 1.223 | 0 |
| SASDFP8 — | 1.05 | FoXS 1.095 | 0.15 | 1.75 | 0.49 | 1.160 | 0.0 % |
| SASDFQ6 — | 2.97 | FoXS 4.034 | −0.30 | −6.90 | **2.71** | 1.241 | 0 |
| SASDFQ8 — | 1.22 | CRYSOL 1.332 | −0.49 | −1.73 | **2.77** | 1.296 | 0 |
| SASDFZ3 — | 0.321 | CRYSOL 0.623 | 0.62 | −0.65 | −0.75 | 1.172 | 0 |
| SASDG44 — | 0.342 | CRYSOL 0.795 | 0.66 | −2.16 | 1.52 | 1.185 | 0 |
| SASDG97 — | 1.62 | CRYSOL 2.201 | 1.68 | −7.10 | −7.18 | 1.036 | 0 |
| SASDGA5 — | 1.41 | CRYSOL 4.862 | 0.91 | −1.71 | 1.28 | 1.175 | 0 |
| SASDGA7 — | 1.13 | CRYSOL 1.160 | 0.74 | −0.08 | −3.18 | 1.147 | 0.1 % |
| SASDGD2 — | 1.02 | CRYSOL 1.075 | −0.22 | 1.52 | −5.97 | 1.230 | 0 |
| SASDGD6 — | 0.978 | CRYSOL 1.054 | 0.94 | 0.36 | −2.58 | 1.007 | 0.0 % |
| SASDGF3 — | 0.235 | CRYSOL 0.754 | 0.45 | −1.44 | −0.43 | 1.211 | 0 |
| SASDGG2 — | 0.992 | CRYSOL 1.032 | 0.49 | −2.09 | −1.72 | 1.190 | 0 |
| SASDGH2 — | 0.97 | CRYSOL 1.428 | 0.19 | 0.95 | −0.63 | 1.177 | 0 |
| SASDGK2 — | 1.01 | CRYSOL 1.074 | −0.30 | 0.87 | −0.85 | 1.242 | 0.1 % |
| SASDGL2 — | 11 | CRYSOL 3.382 | 0.62 | −0.99 | −3.08 | 1.149 | 0 |
| SASDH23 — | 0.789 | CRYSOL 0.743044 | 1.02 | −0.08 | −5.15 | 1.117 | 0 |
| SASDH64 — | 1.06 | CRYSOL 1.371 | 1.28 | −8.60 | 0.87 | 1.132 | 0 |
| SASDH94 — | 1.16 | CRYSOL 1.158 | 0.54 | −0.36 | **2.71** | 1.160 | 0 |
| SASDHM8 — | 0.992 | CRYSOL 1.003 | 0.42 | −0.88 | 1.99 | 1.161 | 0 |
| SASDHP7 — | 1.16 | CRYSOL 1.145 | 0.26 | −0.16 | −4.17 | 1.156 | 0 |
| SASDHT9 — | 1.16 | CRYSOL 2.295 | 1.52 | −1.98 | 2.33 | 1.203 | 0 |
| SASDHX2 — | 0.938 | FoXS 1.033 | −0.28 | 1.09 | −8.26 | 1.225 | 0 |
| SASDJ66 fit1 | 0.994 | CRYSOL 1.044 | −0.87 | 0.32 | −2.15 | **1.320 (saturated)** | 0.0 % |
| SASDJ75 fit1_model1 | 1.02 | CRYSOL 1.699 | −1.00 | 1.11 | −3.16 | 1.224 | 0 |
| SASDJ75 fit2_model1 | 1.28 | CRYSOL 1.252 | 0.06 | 0.52 | −1.49 | 1.203 | 0 |
| SASDJ92 — | 1.58 | CRYSOL 2.236 | 1.14 | −9.17 | **2.73** | **1.306 (saturated)** | 0 |
| SASDJB2 — | 0.714 | CRYSOL 0.867 | −0.50 | 1.71 | −9.03 | 1.248 | 0 |
| SASDJB6 — | 0.49 | CRYSOL 0.993 | 1.82 | −1.61 | 1.82 | 1.123 | 0 |
| SASDJC5 — | 1.64 | CRYSOL 1.619 | −1.13 | 0.33 | 0.26 | 1.295 | 0 |
| SASDJG5 — | 1.94 | CRYSOL 2.158 | 0.45 | −0.26 | **2.75** | 1.165 | 0 |
| SASDJJ4 — | 1.02 | CRYSOL 1.039 | 0.62 | −0.96 | −2.08 | 1.164 | 0 |
| SASDJL6 — | 1 | CRYSOL 1.021 | 0.36 | 0.73 | −0.85 | 1.158 | 0 |
| SASDJP5 — | 0.951 | CRYSOL 1.297 | 0.64 | −0.58 | −8.26 | 1.146 | 0 |
| SASDJQ7 — | 0.684 | CRYSOL 1.13 | −0.73 | 1.94 | −7.57 | 1.239 | 0 |
| SASDJR3 — | 1.11 | CRYSOL 1.156 | −0.43 | 1.58 | −1.17 | 1.215 | 0 |
| SASDJW5 — | 1.07 | CRYSOL 1.392 | 1.37 | −2.81 | −0.53 | 1.145 | 0 |
| SASDJX2 fit3 | 1.78 | CRYSOL 1.513 | 0.55 | −3.38 | −3.39 | 1.153 | 0 |
| SASDJX7 — | 1.49 | CRYSOL 1.666 | 0.72 | 1.17 | 0.66 | 1.158 | 0 |
| SASDJY2 — | 0.658 | CRYSOL 4.68 | 0.76 | −6.46 | 1.32 | 1.167 | 0 |
| SASDJZ2 fit1 | 1.09 | CRYSOL 1.654 | 0.52 | −1.61 | 1.71 | 1.186 | 0 |
| SASDJZ4 fit1 | 2.94 | FoXS 3.655 | 0.24 | −4.90 | −4.33 | 1.265 | 0 |
| SASDK36 — | 1.18 | CRYSOL 2.615 | −0.89 | −2.10 | −4.36 | **1.304 (saturated)** | 0 |
| SASDK74 — | 2.1 | CRYSOL 3.364 | **1.99** | −9.27 | 2.46 | 1.069 | 0 |
| SASDK94 fit1 | 2.83 | Pepsi-SAXS-style 5.635 (software not stated) | 0.65 | **2.00** | −1.74 | 1.163 | 0 |
| SASDKH2 — | 1.2 | CRYSOL 1.262 | 0.12 | −0.21 | 1.31 | 1.173 | 0 |
| SASDKJ4 — | 1.17 | CRYSOL 1.306 | 0.18 | 0.80 | −6.61 | 1.167 | 0 |
| SASDKQ8 — | 1.27 | CRYSOL 14.3 | 0.97 | −4.15 | 1.78 | 1.157 | 0 |
| SASDKS7 — | 1.16 | CRYSOL 1.127 | 0.22 | 1.04 | −0.56 | 1.165 | 0 |
| SASDKT6 — | 1.17 | CRYSOL 1.234 | 0.04 | −0.97 | −0.66 | 1.200 | 0 |
| SASDKT9 — | 0.728 | CRYSOL 0.91 | −2.45 | −0.48 | 1.62 | **1.314 (saturated)** | 0 |
| SASDKU3 — | 1.37 | CRYSOL 1.967 | −0.03 | **1.97** | 2.29 | 1.160 | 0 |
| SASDKV3 — | 0.654 | CRYSOL 0.834 | 0.58 | 1.30 | −0.47 | 1.180 | 0 |
| SASDKW3 — | 1.81 | CRYSOL 2.682 | 1.85 | 1.58 | −2.49 | 0.986 | 0 |
| SASDKY3 — | 1.17 | CRYSOL 1.197 | −0.41 | −1.16 | −3.08 | **1.315 (saturated)** | 0 |
| SASDKY7 — | 1.05 | CRYSOL 1.032 | 0.56 | 0.20 | 0.37 | 1.108 | 0.0 % |
| SASDL27 — | 0.837 | CRYSOL 1.096 | −0.06 | 1.94 | 2.58 | 1.245 | 0 |
| SASDL37 — | 1.18 | CRYSOL 1.184 | −0.30 | 1.56 | −9.68 | 1.248 | 0 |
| SASDLM3 — | 1.07 | CRYSOL 3.065 | 1.71 | −0.31 | 1.56 | 1.142 | 0 |
| SASDLP4 — | 1.04 | CRYSOL 1.06 | −0.00 | −4.01 | −9.37 | **1.320 (saturated)** | 0 |
| SASDLQ2 — | 0.801 | CRYSOL 0.867 | −0.04 | −0.43 | −1.39 | 1.204 | 0 |
| SASDLQ3 — | 0.859 | CRYSOL 0.918 | 0.14 | 1.38 | −1.74 | 1.177 | 0 |
| SASDLY8 — | 0.825 | CRYSOL 0.936 | 0.39 | −0.54 | −4.43 | 1.135 | 0 |
| SASDM36 — | 1.43 | CRYSOL 3.407 | 0.26 | −3.45 | 0.39 | 1.223 | 0 |
| SASDM63 — | 0.974 | CRYSOL 1.685 | −0.54 | −1.16 | −9.53 | 1.208 | 0 |
| SASDM76 — | 0.98 | CRYSOL 1.779 | −0.02 | −2.93 | −0.22 | 1.279 | 0 |
| SASDM82 — | 1.03 | CRYSOL 1.011 | 0.28 | −0.20 | −2.42 | 1.175 | 0 |
| SASDM86 — | 3.04 | CRYSOL 3.191 | 0.10 | 0.23 | −2.52 | 1.225 | 0 |
| SASDM96 — | 1.08 | CRYSOL 1.172 | −0.10 | −0.02 | −2.38 | 1.278 | 0 |
| SASDMA6 — | 2.29 | CRYSOL 3.003 | 0.18 | −8.17 | −10.02 | 1.166 | 0 |
| SASDMA9 — | 1.06 | CRYSOL 1.198 | −0.59 | 0.82 | −5.25 | 1.241 | 0 |
| SASDMB6 — | 1.95 | CRYSOL 2.332 | −0.29 | −0.38 | −2.82 | **1.320 (saturated)** | 0 |
| SASDMC6 — | 3.17 | CRYSOL 3.235 | −0.03 | 0.35 | −2.36 | 1.254 | 0.0 % |
| SASDMC9 — | 1.21 | CRYSOL 1.237 | −1.47 | −3.38 | −6.69 | 1.280 | 0 |
| SASDMD6 — | 2.01 | CRYSOL 2.049 | −0.22 | 0.12 | −2.93 | **1.319 (saturated)** | 0 |
| SASDME6 — | 1.81 | CRYSOL 3.04 | −0.15 | 0.20 | −10.95 | 1.272 | 0 |
| SASDMF6 — | 1.28 | CRYSOL 1.503 | −0.16 | 1.15 | −4.07 | 1.295 | 0 |
| SASDMG6 — | 0.964 | CRYSOL 1.854 | 0.02 | −0.57 | −1.85 | 1.279 | 0.0 % |
| SASDMG8 — | 0.952 | CRYSOL 1.651 | 0.44 | 0.60 | **2.72** | 1.195 | 0 |
| SASDMH6 — | 1.44 | CRYSOL 1.662 | −0.14 | 0.61 | −2.91 | 1.296 | 0 |
| SASDMJ6 — | 1.06 | CRYSOL 1.620 | −0.11 | 1.26 | −10.80 | 1.285 | 0 |
| SASDMJ9 — | 0.856 | CRYSOL 1.37 | −1.08 | **1.96** | −5.54 | 1.248 | 0 |
| SASDMK6 — | 1.02 | CRYSOL 1.187 | −0.15 | −0.51 | −4.90 | **1.320 (saturated)** | 0 |
| SASDMK9 — | 1.15 | CRYSOL 1.73186 | 0.76 | 1.60 | 2.69 | 1.178 | 0 |
| SASDML3 — | 1.4 | FoXS 1.624 | 0.05 | 0.02 | 0.94 | 1.188 | 0 |
| SASDML6 — | 1.83 | CRYSOL 8.758 | 0.02 | −1.70 | **−11.15** | 1.258 | 0 |
| SASDMM9 — | 0.996 | CRYSOL 1.169 | 0.42 | 0.32 | −0.03 | 1.163 | 0 |
| SASDMN6 — | 3 | CRYSOL 4.065 | −0.48 | −0.41 | −11.09 | 1.289 | 0 |
| SASDMS4 — | 1.16 | CRYSOL 2.969 | 1.63 | −7.49 | −10.37 | 1.179 | 0 |
| SASDMS6 — | 0.901 | CRYSOL 0.937 | −0.24 | 1.32 | −4.87 | 1.225 | 0.0 % |
| SASDMU4 — | 1.12 | CRYSOL 1.988 | −0.34 | 1.85 | −10.59 | **1.320 (saturated)** | 0 |
| SASDN32 — | 0.969 | FoXS 1.01 | 0.44 | −1.91 | 1.70 | 1.182 | 0 |
| SASDN75 — | 0.943 | CRYSOL 1.171 | −1.78 | 0.58 | −6.57 | 1.276 | 0 |
| SASDNF7 — | 1.26 | CRYSOL 1.29 | −0.67 | 1.33 | −8.82 | 1.242 | 0 |
| SASDNH7 fit1 | 5.18 | FoXS 16.465 | 1.23 | −2.11 | **2.71** | 1.209 | 0 |
| SASDNJ2 — | 4.31 | CRYSOL 4.549 | 0.21 | 0.05 | 1.25 | 1.161 | 0 |
| SASDNK7 fit1 | 1.02 | CRYSOL 1.391 | −0.29 | 0.82 | −3.48 | **1.306 (saturated)** | 0 |
| SASDNK8 — | 1.27 | CRYSOL 1.228 | 0.91 | 0.34 | −2.16 | 1.177 | 0.0 % |
| SASDNL8 — | 1.14 | CRYSOL 1.066 | 0.22 | 0.81 | −0.17 | 1.202 | 0 |
| SASDNP5 — | 1.09 | CRYSOL 1.535 | −0.40 | 1.68 | −4.23 | 1.239 | 0 |
| SASDNP7 fit1 | 20.9 | CRYSOL 29.579 | 0.61 | **2.00** | **2.80** | 1.191 | 0 |
| SASDNS2 — | 2.45 | CRYSOL 2.763 | 0.38 | −0.15 | 1.66 | 1.151 | 0 |
| SASDNW9 — | 0.979 | CRYSOL 0.993 | −0.06 | −0.75 | −0.83 | 1.229 | 0 |
| SASDP48 — | 16.9 | CRYSOL 59.5 | −0.04 | 0.72 | **2.77** | 1.218 | 0 |
| SASDP74 — | 1.03 | CRYSOL 1.271 | −0.16 | 0.23 | −8.46 | 1.265 | 0.0 % |
| SASDPD3 — | 2.16 | SASBDB fit 1.458 | −0.59 | −0.67 | 2.65 | 1.284 | 0 |
| SASDPG2 — | 1.01 | CRYSOL 1.007 | 1.32 | 1.11 | −2.63 | 1.037 | 0 |
| SASDPJ2 — | 0.938 | CRYSOL 0.968 | 0.51 | −3.47 | −2.41 | 1.043 | 0 |
| SASDPK2 — | 1.15 | CRYSOL 1.278 | 0.14 | 1.85 | −1.73 | 1.099 | 0 |
| SASDPL6 — | 1.2 | CRYSOL 1.189 | 0.74 | 1.94 | −2.90 | 1.138 | 0 |
| SASDPM6 — | 1.06 | CRYSOL 0.991 | 1.59 | 1.87 | −0.89 | 1.114 | 0 |
| SASDPN6 fit1 | 1.12 | Pepsi-SAXS 1.224 | 1.92 | 0.49 | −3.64 | 1.027 | 0 |
| SASDPP6 — | 1.31 | CRYSOL 1.280 | −0.21 | −0.03 | −3.02 | **1.319 (saturated)** | 0 |
| SASDPQ4 — | 22.1 | CRYSOL 40.756 | 0.31 | 0.94 | **2.80** | 1.167 | 0 |
| SASDPR4 — | 6.66 | CRYSOL 90.494 | 0.44 | −0.11 | 1.89 | 1.159 | 0 |
| SASDPU6 — | 1.36 | CRYSOL 1.265 (AMBER MD model) | 0.05 | −1.04 | 0.85 | 1.219 | 0 |
| SASDPV7 — | 0.966 | CRYSOL 1.05 | −0.23 | 1.04 | −4.15 | 1.230 | 0.0 % |
| SASDPW7 — | 0.798 | CRYSOL 0.894 | −0.26 | 1.13 | −5.99 | 1.231 | 0.0 % |
| SASDPZ8 — | 1.18 | CRYSOL 1.041 | −1.25 | −4.56 | −6.06 | **1.320 (saturated)** | 0 |
| SASDQ28 — | 1.48 | CRYSOL 1.056 | 0.49 | −0.52 | 2.55 | 1.154 | 0 |
| SASDQ59 — | 0.829 |  | 0.08 | −0.85 | −2.17 | 1.242 | 0 |
| SASDQ69 — | 0.972 | FoXS 1.10 | 0.78 | 0.24 | −2.94 | 1.157 | 0 |
| SASDQ98 — | 2 | CRYSOL 0.932 | 0.21 | −0.99 | −1.13 | 1.142 | 0 |
| SASDQS6 — | 0.996 | CRYSOL 1.119 | 0.36 | 1.65 | 1.39 | 1.161 | 0.1 % |
| SASDQT9 — | 1.44 | FoXS 9.306 | 0.00 | 0.51 | 1.00 | 1.216 | 0 |
| SASDR23 — | 0.0666 | CRYSOL 0.079 | 0.50 | 0.26 | −2.23 | **1.301 (saturated)** | 0 |
| SASDR99 — | 13.8 | 29.6 (MDFF model) | −0.20 | 1.80 | −2.02 | 1.221 | 0 |
| SASDRH8 — | 1.05 | CRYSOL 1.181 | 0.24 | −2.14 | −5.32 | 1.133 | 0.0 % |
| SASDRJ8 — | 0.00871 | CRYSOL 0.06 | 0.73 | −0.54 | −5.57 | 1.158 | 0 |
| SASDRN5 fit2_model1 | 1.75 | SREFLEX 3.04 | 0.30 | 0.81 | 2.69 | 1.187 | 0 |
| SASDRN5 fit3_model1 | 4.39 | CRYSOL 12.0 | −0.19 | −4.71 | −9.75 | 1.224 | 0 |
| SASDRQ8 — | 0.991 | CRYSOL 1.095 | −0.59 | −0.08 | −2.70 | 1.236 | 0.1 % |
| SASDRR8 fit2 | 1.25 | CRYSOL 1.347 | −0.03 | 1.25 | −0.70 | 1.188 | 0 |
| SASDRS2 — | 1.59 | CRYSOL 1.446 | 0.64 | −3.68 | −2.75 | 1.107 | 0 |
| SASDRT2 — | 0.047 | CRYSOL 0.054 | 0.51 | −0.14 | −2.77 | 1.255 | 0 |
| SASDRU2 — | 1.94 | CRYSOL 3.915 | 0.58 | −4.17 | −2.05 | 1.267 | 0 |
| SASDRV2 — | 0.0376 | CRYSOL 0.036 | 0.39 | 0.33 | −1.97 | 1.179 | 0 |
| SASDRX2 — | 0.0437 | CRYSOL 0.044 | 0.41 | 0.13 | −2.92 | 1.220 | 0 |
| SASDRX8 fit1 | 1.36 | CRYSOL 4.263 | −1.05 | −0.76 | −10.89 | 1.255 | 0 |
| SASDRX8 fit2 | 1.15 | CRYSOL 8.663 | −0.95 | 0.69 | −6.75 | 1.251 | 0 |
| SASDRY2 — | 2.33 | CRYSOL 2.334 | 1.07 | 0.27 | −2.77 | 1.052 | 0 |
| SASDRZ2 — | 2.05 | CRYSOL 2.08 | 0.91 | 0.11 | −2.77 | 1.119 | 0 |
| SASDRZ6 — | 1.11 | CRYSOL 1.088 | 0.94 | −1.55 | 2.33 | 1.041 | 0 |
| SASDSE7 — | 1.29 | CRYSOL 2.045 | −0.40 | 0.81 | −8.29 | 1.215 | 0 |
| SASDSF7 — | 1.17 | CRYSOL 1.229 | 1.16 | 0.10 | −1.97 | 1.158 | 0 |
| SASDSN8 — | 2.95 | CRYSOL 1.876 | 0.32 | 0.51 | −0.97 | 1.129 | 0 |
| SASDSP8 — | 46 | CRYSOL 69.336 | **1.99** | −1.81 | **2.72** | 0.989 | 0 |
| SASDSQ8 — | 47.7 | CRYSOL 63.691 | **1.99** | −0.74 | **2.75** | 0.971 | 0 |
| SASDSQ9 — | 1.11 | CRYSOL 1.216 | −0.71 | 0.96 | −4.62 | 1.252 | 0 |
| SASDSU8 — | 1.03 | CRYSOL 1.145 | 0.46 | −1.37 | 1.75 | 1.193 | 0 |
| SASDSW7 fit1 | 3.08 | Pepsi-SAXS 2.688 | 1.64 | −0.79 | 1.17 | **0.780 (saturated)** | 0 |
| SASDSX5 — | 1.16 | Pepsi-SAXS 1.28 | −0.03 | 0.47 | −6.20 | 1.187 | 0 |
| SASDT55 — | 0.982 | Pepsi-SAXS 1.03 | 0.52 | 1.14 | 0.34 | 1.199 | 0 |
| SASDT65 — | 1.08 |  | 1.08 | −2.61 | −3.53 | 1.223 | 0 |
| SASDTC5 — | 1.52 |  | −0.08 | 0.49 | −0.64 | 1.180 | 0 |
| SASDTK5 fit2_model1 | 0.894 | CRYSOL 1.14 | 0.65 | 1.81 | −6.53 | 1.177 | 0 |
| SASDTK5 fit3_model1 | 1.17 | CRYSOL 1.17 | 0.66 | 1.41 | 1.54 | 1.176 | 0 |
| SASDTK5 fit4_model1 | 3.42 | CRYSOL 5.22 | 0.57 | 1.83 | −10.93 | 1.194 | 0 |
| SASDTK5 fit5_model1 | 0.994 | CRYSOL 1.81 | −0.04 | −5.49 | 1.38 | 1.232 | 0 |
| SASDTK5 fit6_model1 | 0.883 | CRYSOL 1.03 | 0.57 | 1.28 | −1.94 | 1.176 | 0 |
| SASDTK5 fit7_model1 | 3.89 | CRYSOL 6.09 | 0.68 | −3.04 | −10.50 | 1.192 | 0 |
| SASDTR2 — | 1.76 | CRYSOL 2.133 | −1.00 | **1.97** | 2.59 | 1.269 | 0 |
| SASDTT2 — | 1.16 | CRYSOL 1.207 | −1.72 | 0.50 | −2.16 | **1.320 (saturated)** | 0 |
| SASDTT4 — | 1.46 | CRYSOL 1.409 | 0.43 | −0.54 | **2.78** | 1.158 | 0 |
| SASDTV4 — | 1.34 | CRYSOL 1.066 | 0.15 | −0.10 | −4.04 | 1.210 | 0 |
| SASDTW4 fit1 | 1.26 | CRYSOL 1.343 | −0.05 | −1.88 | −2.94 | 1.236 | 0 |
| SASDTX4 — | 0.974 | CRYSOL 1.037 | 0.09 | 0.55 | −5.77 | 1.216 | 0 |
| SASDU29 fit1 | 1.06 | Pepsi-SAXS-style 1.546 (software not stated) | −0.35 | −3.32 | 1.81 | 1.210 | 0 |
| SASDU78 — | 1.17 | CRYSOL 1.351 | 0.40 | −0.13 | 0.91 | 1.156 | 0 |
| SASDU89 — | 1.1 | CRYSOL 1.157 | −0.07 | −0.56 | −0.77 | 1.243 | 0 |
| SASDU98 — | 0.868 | CRYSOL 1.399 | 0.12 | −1.35 | 2.38 | 1.207 | 0.0 % |
| SASDUB4 — | 44 | CRYSOL 49.702 | 0.31 | 1.02 | **2.80** | 1.166 | 0 |
| SASDUC4 — | 26.7 | CRYSOL 652.4416 | 0.47 | −0.43 | 1.86 | 1.159 | 0 |
| SASDUP5 — | 1.09 | CRYSOL 2.433 | −0.03 | 1.49 | 0.56 | 1.145 | 0 |
| SASDUS8 — | 1.19 | FoXS 1.225 | −0.18 | −2.85 | −1.78 | 1.011 | 0 |
| SASDUT8 — | 0.943 | FoXS 1.134 | 1.31 | −0.64 | 1.74 | 0.983 | 0.0 % |
| SASDUU3 — | 1.1 | CRYSOL 1.112 | −1.03 | 1.43 | −2.33 | 1.218 | 0.0 % |
| SASDUU8 — | 1.05 | FoXS 1.106 | −0.29 | −1.32 | −7.75 | 1.075 | 0 |
| SASDUV3 — | 1 | CRYSOL 1.435 | −0.27 | −0.53 | −2.16 | 1.250 | 0 |
| SASDUW6 — | 1.03 | CRYSOL 1.065 | 0.37 | 0.64 | −2.68 | 1.067 | 0 |
| SASDUX3 fit1 | 0.911 | CRYSOL 2.314 | −0.16 | −0.91 | −0.80 | 1.237 | 0.0 % |
| SASDV25 fit2 | 1.14 | CRYSOL 0.958 | 0.93 | 1.87 | 1.76 | 1.111 | 0 |
| SASDV46 — | 1.35 | CRYSOL 1.742 | 0.60 | **1.95** | −10.28 | 1.224 | 0 |
| SASDV62 — | 1.11 | CRYSOL 1.098 | 0.22 | 0.39 | 1.38 | 1.171 | 0 |
| SASDV82 — | 0.97 |  | 0.15 | 0.73 | 0.19 | 1.179 | 0 |
| SASDV92 — | 1.18 |  | 0.22 | 0.60 | 1.38 | 1.186 | 0 |
| SASDV94 fit1 | 1.86 | CRYSOL 1.28 | **1.98** | −7.99 | 2.63 | 1.134 | 0 |
| SASDVA2 — | 1.17 |  | −0.06 | 0.52 | −2.07 | 1.212 | 0.1 % |
| SASDVB2 — | 1.12 |  | 0.25 | 0.98 | 1.11 | 1.186 | 0 |
| SASDVC2 — | 1.16 |  | 0.05 | 0.71 | −0.40 | 1.189 | 0 |
| SASDVC3 — | 4.89 | CRYSOL 4.742 | 0.32 | **1.98** | −2.74 | 1.187 | 0 |
| SASDVD2 — | 1.14 |  | 0.08 | −0.07 | 1.12 | 1.194 | 0 |
| SASDVE2 — | 2.17 |  | −0.53 | 0.34 | −10.47 | 1.195 | 0.1 % |
| SASDVE7 — | 1.13 |  | −0.45 | 0.58 | −2.81 | 1.206 | 0.0 % |
| SASDVG2 — | 1.9 | MultiFoXS 1-state 2.10 | 0.02 | 0.71 | −1.39 | 1.175 | 0 |
| SASDVG6 — | 2.71 | CRYSOL 2.404 | −0.10 | −1.44 | −4.06 | 1.212 | 0 |
| SASDVL8 — | 1.1 | CRYSOL 1.523 | −0.07 | 0.97 | −4.08 | 1.222 | 0.1 % |
| SASDVN2 fit1_model1 | 0.829 | MultiFoXS 1-state 0.81 | 0.24 | −0.01 | 0.60 | 1.169 | 0 |
| SASDVQ6 — | 1.65 | CRYSOL 1.502 | −0.18 | 0.43 | −1.83 | 1.231 | 0 |
| SASDVQ8 — | 0.948 | CRYSOL 1.094 | 0.26 | 0.26 | −2.48 | 1.195 | 0.0 % |
| SASDVQ9 — | 1.13 | CRYSOL 1.232 | 0.92 | −0.01 | −2.56 | 1.010 | 0 |
| SASDVR6 — | 1.11 | CRYSOL 1.152 | 0.08 | 1.90 | **2.75** | 1.232 | 0 |
| SASDVS8 — | 1.04 | CRYSOL 1.371 | −0.11 | 0.84 | −5.61 | 1.216 | 0.1 % |
| SASDVT5 — | 0.554 | CRYSOL 0.747 | 0.13 | −1.20 | −2.66 | 1.281 | 0 |
| SASDVT8 — | 1.31 | CRYSOL 1.884 | −0.23 | **1.96** | −1.99 | 1.220 | 0.1 % |
| SASDVU5 — | 0.776 | Pepsi-SAXS 2.613 | −1.32 | 1.86 | 2.42 | **0.780 (saturated)** | 0 |
| SASDVV4 fit1 | 0.899 | Pepsi-SAXS 0.876 | 1.52 | 1.52 | 1.29 | 0.947 | 0 |
| SASDVW3 — | 1.15 | CRYSOL 1.725 | 0.11 | −1.78 | −2.58 | 1.244 | 0 |
| SASDVW4 fit1 | 1.18 | CRYSOL 1.779 | 1.07 | 1.36 | 0.03 | 1.061 | 0 |
| SASDVX2 fit1 | 5.13 | Pepsi-SAXS 6.974 | 1.59 | −3.70 | −10.61 | 0.871 | 0 |
| SASDVX4 — | 5.97 | CRYSOL 5.915 | **1.96** | −1.24 | 1.86 | 1.052 | 0 |
| SASDVY2 — | 1.8 | CRYSOL 2.111 | **1.99** | −7.30 | −7.79 | 0.906 | 0 |
| SASDVY4 — | 9.85 | CRYSOL 11.624 | **1.97** | −3.55 | 1.74 | 1.091 | 0 |
| SASDW94 — | 0.944 | CRYSOL 1.054 | 0.21 | 1.09 | −3.73 | 1.199 | 0 |
| SASDWA4 — | 1.2 | CRYSOL 1.383 | 0.38 | −0.29 | 1.39 | 1.172 | 0 |
| SASDWB4 — | 1.35 | CRYSOL 1.452 | 0.16 | −0.90 | 1.04 | 1.199 | 0 |
| SASDWJ4 fit2 | 6.49 | Pepsi-SAXS 10.774 | **1.99** | **1.97** | 2.68 | 0.944 | 0 |
| SASDWM2 — | 0.994 | CRYSOL 1.734 | −0.02 | 0.43 | −0.96 | 1.228 | 0 |
| SASDWN5 — | 1.4 |  | 0.38 | 0.03 | −5.56 | 1.208 | 0 |
| SASDWP9 — | 1.04 | CRYSOL 1.084 | −0.10 | 0.09 | −5.69 | 1.210 | 0 |
| SASDWR5 — | 1.41 | CRYSOL 1.11 (SREFLEX model) | 0.98 | **1.99** | −4.73 | 1.141 | 0 |
| SASDWS5 — | 1.17 | CRYSOL 1.114 (CORAL mix model, with dummy residues) | 1.02 | 1.87 | −0.40 | 1.186 | 0 |
| SASDWT5 — | 1.12 | FoXS 1.151 | 0.28 | −1.02 | −7.18 | 1.175 | 0.0 % |
| SASDWW6 — | 1.17 | CRYSOL 1.22 | 0.58 | −3.10 | −3.29 | 1.222 | 0 |
| SASDWX6 — | 1.25 | CRYSOL 1.257 | 0.12 | −3.20 | −6.02 | 1.222 | 0 |
| SASDWY6 — | 1.04 | CRYSOL 1.058 | −0.15 | −1.51 | −5.00 | 1.217 | 0 |
| SASDWZ9 — | 0.538 | Pepsi-SAXS 0.62 | 0.26 | 1.57 | −0.60 | 1.278 | 0 |
| SASDX52 — | 0.288 | 0.70 (method unconfirmed) | −0.33 | −4.49 | −5.84 | 1.185 | 0.1 % |
| SASDX54 — | 0.883 | FoXS 0.879 | 0.21 | 0.40 | −0.40 | 1.091 | 0 |
| SASDX89 — | 0.631 | FoXS 0.616 | −0.28 | 0.18 | −1.75 | 1.229 | 0 |
| SASDXA7 — | 0.81 | FoXS 0.847 | 0.04 | −1.09 | −0.88 | 1.197 | 0 |
| SASDXC4 — | 1.19 |  | 0.20 | 1.42 | −5.42 | 1.150 | 0.0 % |
| SASDXC7 — | 0.825 | FoXS 0.976 | −0.04 | 1.51 | −2.92 | 1.188 | 0 |
| SASDXD9 — | 1.2 | CRYSOL 1.252 | 0.25 | 1.63 | 1.94 | **0.780 (saturated)** | 0 |
| SASDXF3 — | 23.9 |  | **1.99** | −2.32 | **2.73** | 1.178 | 0 |
| SASDXF8 — | 1.21 | FoXS 1.268 | 1.00 | 0.70 | 1.24 | 1.130 | 0.1 % |
| SASDXH2 — | 1.27 | CRYSOL 1.651 | 0.35 | 0.74 | 0.57 | 1.122 | 0 |
| SASDXH4 — | 4.95 | SREFLEX 1.073 | 1.19 | −1.13 | **2.78** | 1.220 | 0 |
| SASDXJ2 — | 3.47 | CRYSOL 2.804 | −0.00 | −2.19 | 1.26 | 1.223 | 0 |
| SASDXK4 — | 2.38 | CRYSOL 1.673 | 0.67 | 1.37 | **2.69** | 1.226 | 0 |
| SASDXW3 — | 6.25 | CRYSOL 6.112 | −0.68 | −6.20 | −7.33 | 1.239 | 0 |
| SASDXX4 — | 3.94 | CRYSOL 4.912 | −0.32 | 0.63 | **−11.14** | 1.236 | 0 |
| SASDXY4 — | 2.34 | CRYSOL 4.273 | −0.47 | −2.74 | −10.81 | 1.266 | 0 |
| SASDYM2 — | 0.291 | FoXS 0.286 (error bars overestimated) | 0.61 | 1.01 | −1.84 | 1.195 | 0 |
| SASDYV6 — | 1.52 | CRYSOL 2.101 | −0.29 | 1.94 | −8.14 | 1.216 | 0 |
| SASDYW6 fit2 | 2.75 | CRYSOL 3.74 | −0.11 | −1.54 | −6.39 | 1.198 | 0 |
| SASDZ78 — | 0.0252 | CRYSOL 0.026 | −0.11 | 0.40 | −3.25 | 1.228 | 0 |
| SASDZC6 — | 1.56 | FoXS 1.68 | −0.09 | 0.32 | −4.61 | 1.219 | 0 |
| SASDZD6 — | 2.21 | FoXS 5.271 | 0.45 | 0.99 | −6.76 | 1.247 | 0 |
| SASDZW5 — | 1.68 |  | 0.18 | 1.01 | −0.14 | 1.157 | 0 |
| SASDZZ9 fit1 | 13.8 | CRYSOL ≈ 34.5 | −0.47 | **1.99** | −5.54 | 1.231 | 0 |
<!-- results-table:end -->

**How to read these MAPs.**

- **The reported MAP is the best NUTS draw**, not the L-BFGS mode that seeds the sampler (their χ² agrees to 4-5 digits). Parameters the data barely constrain (δρ₃ on fits with almost no cavity beads, for one) move between reruns because the best of the several thousand pooled draws moves, with the χ² unchanged; judge those from the `quantiles2sigma` sheet of each `res*.xlsx`, not from this table.
- **Every run in the table passes the gates**: R̂ < 1.01, bulk and tail ESS > 400 and a divergent share below 0.1 %. A run that is still outside them after its retry ladder stops with `NotConvergedError` and writes no results.
- **Most other optima carry no mass, but not all.** The MAP search often reports 2-5 "modes", which is a count of distinct local optima, not of modes of the posterior. In most fits every optimum besides the best is tens to thousands of nats lower in log density and carries no mass. A fit with a second mode of real mass has it weighted in by bridge sampling. The report lists every mode and the optima that carry mass (the `modes` row of each run log and the `modes` sheet).
- **Many fits put δρ₃ at a bound** (bold in the table; upper ~+2.8, i.e. φ ≈ `φ_max`, lower −11.1 for empty cavities). The bound is usually reached together with a poor or mediocre χ²: the cavity contrast is absorbing model-data mismatch (wrong conformer, missing flexibility) rather than representing physical cavity hydration.
- **The split of the first two contrasts.** Refitting SASDMJ9 with one shared shell contrast (δρ₁ = δρ₂ = δρ₃, c1, scale and background still profiled) gives 1.07, and 1.07 with δρ₁ = δρ₂ and δρ₃ free, against 0.87 for the full model. A single contrast (as in CRYSOL) already reaches 1.07 on SASDMJ9, below CRYSOL's 1.37 on the same points, so most of that advantage is not the extra contrasts. On poorly fitting fits the independent concave-shell contrast δρ₂ does the work and often sits at its +2 bound, which is a sign of model misspecification, not a measurement of the hydration shell.

## Which entries are benchmarks

A fit stays in this suite only if the depositor's reference is a **single-structure** fit (CRYSOL, FoXS or Pepsi-SAXS on one model, or one SREFLEX or MD model), because only then BAYSOL's χ² and the depositor's describe the same thing. BAYSOL fits one rigid structure per run, and the χ² of a deposited ensemble or multi-state fit is the χ² of a *weighted mixture*: a single member is expected to be worse, so the two numbers cannot be compared.

Not in the suite:

- **Ensemble and multi-state references:** SASDBS6 (EOM), SASDEP6, SASDUN5 (OLIGOMER), SASDJ72, SASDMZ9, SASDQ79 (MultiFoXS), SASDG24 (EOM), SASDQE9 (AXES) and SASDMM3 (FoXS of a mixture of both models), and the multi-state fits of mixed entries: the OLIGOMER 3-state `fit1` of SASDLP4, the 2-state `fit3` of SASDCQ2, the 2- and 3-state fits of SASDVG2 and SASDVN2. What stays of those four entries is the single-structure fit: SASDLP4 `fit2` (CRYSOL, the dimer), SASDCQ2 `fit2` (MultiFoXS 1-state), SASDVG2 `fit1` and SASDVN2 `fit1` (MultiFoXS 1-state).
- **No reference fit at all:** SASDEM7 and SASDJ62 (SASDBA8's model is a fragment that pdb2pqr cannot complete).
- Two models of these entries serve as unit-test fixtures in `test/fixtures/molecules/`: `SASDG24-legacy-rna.pdb` (legacy RNA residue names, `test-legacy-nucleotides.jl`) and `3ODQ-hemoglobin.pdb` (four hemes, `test-ligands.jl`).
- SASDN32 and SASDZC6 have a deposited χ² (FoXS) but no reference curve to overlay. They stay, since the χ² values compare. SASDF42 and SASDX52 give a deposited χ² whose method the script does not name; they stay for now.

Alternative single models are different: SASDTK5 (six Fe-TPP-phen HasApf5 dimer geometries), SASDD88 (homology vs normal-mode model), SASDRN5 (AlphaFold vs SREFLEX-refined) and SASDZZ9 are competing hypotheses, each meant to explain the curve as an individual structure. There BAYSOL's ranking can be compared directly with the depositor's: it agrees on SASDTK5 (lambda-trans1, `fit6`, is best for both: 0.92 vs CRYSOL 1.03), on SASDRN5 (refined 2.85 < raw 7.18) and on SASDD88 (both models fit, the normal-mode model slightly better).

## Fixture archives

The deposited curves, structures and CRYSOL `.fit` files of the entries live in `test/fixtures/experiments/<ID>.7z` (unpacked on demand; a plain `<ID>/` folder exists only while an entry is being built) (7z, LZMA2, `-mx=9`, solid; entry paths start with `<ID>/`; 15.7 MB for all 122 entries against 126 MB as folders). `bysl fixtures pack` creates or refreshes the archives and then removes the plain folder (after a byte-for-byte check of the archive; `--keep-source` keeps it), and `bysl fits run <ID>` unpacks the entry into `$BAYSOL_FIXTURES` (default `_cache/experiments`) before the fit starts, outside its timing, and removes the copy when the fit is done (`--keep-fixtures` keeps it). Every script reads its fixtures through `fixtureDir("<ID>")` (`common.jl`): the unpacked folder if `BAYSOL_FIXTURES` points at one, else the plain folder in the repository, else an error that says to run `bysl fixtures unpack <ID>`. So a script also runs by hand: `bysl fixtures unpack SASDMJ9` and `BAYSOL_FIXTURES=_cache/experiments julia ...`. A new entry's folder is packed with `bysl fixtures pack <ID>`. The tool works on any archive set (`--set experiments|synthetic`, `--root DIR`, `bysl fixtures list`; see `dev/README.md`).

## Tools

Three scripts work on the results without rerunning a fit:

```
# sampler diagnostics on any fit: MAP starts, Hessian, step size and tree depth, gradient error, modes
bysl fits diagnose --report SASDTK5:fit3_model1
#   other parts: `--residuals` (whiteness of the residuals), `--chains` (every chain `infer` runs)

# compare results between git revisions / tags and the working tree (timing totals, χ² and parameter distributions)
bysl results compare v0.4.0                  # any revisions; the working tree is added last

# the Results table above: regenerate it, or check that it is current (exit 1 if not)
bysl results table --update
bysl results table --check
```

Cold-start and steady-state benchmarks (compile and precompile time reported apart from algorithmic time, measured from a
wiped cache state) live in `dev/` (see `dev/README.md`); `bysl results compare --bench new.json`
compares a run with the latest release's baseline in `test/baselines/` (or name two files). Benchmarks are only run with the repository owner's approval (`--approved`), because they need a quiet machine and AI agents tend not to check for one; see `test/utils/README.md`.

`bysl fits diagnose` builds the `Seed` a script would sample without fitting it (through the script's `seed_<id>()`, above); the diagnostics themselves are generic functions in `dev/src/seed-diagnostics.jl`, tested in `test/unit-tests/units/test-seed-diagnostics.jl`. `bysl results compare` reads the committed run log (`<ID>.LOG`) of each revision with `git show`, so no checkout is needed; the wall clock excludes PROPKA/pdb2pqr.

## Entry summary


| Entry   | System                                             | Notes                                                                                                  |
| --------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| SASDA52 | yeast ADH1 tetramer                                | assumed PBS recipe; beamline wavelength unit-slip corrected; CRYSOL overlay                            |
| SASDF42 | HSA + 2 somapacitan                                | HSA + two GH copies in one model; compared with the deposited fit (χ² 2.10; its header's 1.45 is χ) |
| SASDMJ9 | FCoV Nsp7                                          | the reference case validated against CRYSOL                                                            |
| SASDN32 | Sas20d2 + ligand                                   | 5 mM maltoheptaose, a solute that previously had no volume data                                        |
| SASDV94 | phospholipase C (PLC H) + chaperone PLC R2         | only the atomistic chains of a mixed atomistic/dummy-bead model; merged injections                     |
| SASDWZ9 | SERF1a                                             | NMR conformer; speciated phosphate buffer + azide; only Pepsi-SAXS comparison                          |
| SASDX52 | FadD5 dimer                                        | predicted dimer; q truncated at 0.17 Å⁻¹; reference χ² < 1 from an unconfirmed method             |
| SASDYW6 | Fba1 dimer                                         | AlphaFold3 model; 500 mM imidazole + NaCl (I ≈ 0.65 M); estimated PMSF volume                         |
| SASDZC6 | PDE6/GαT* complex                                 | six-chain, four-species complex; estimated udenafil volume; FoXS reference χ² 1.68                   |
| SASDZZ9 | NodB                                               | crystal model with a poor reference agreement (χ² ≈ 34.5)                                           |
| SASDCQ2 | Ca²⁺-calmodulin                                  | MultiFoXS 1-state `fit2` only (the 2-state `fit3` was removed: ensemble); 0.1 % NaN₃ + TCEP radiation protection |
| SASDD88 | M. tuberculosis LigA BRCT domain                   | two alternative models (Phyre2 homology, elNémo normal mode); paper/SASBDB buffer conflict            |
| SASDJY2 | EcoKMcrA N-terminal domain                         | single CRYSOL model; its chain failed in v0.2.0 (81 % divergent), healthy now                          |
| SASDKQ8 | ROSA de novo four-helix-bundle dimer               | single model; pre-hydrogenated; 5 % glycerol                                                           |
| SASDLP4 | SodA (superoxide dismutase)                        | CRYSOL dimer fit (`fit2`) only (the OLIGOMER `fit1` members were removed: ensemble); 50 mM HEPES only |
| SASDP48 | GRB2 N188D/N214D monomer                           | crystal monomer that fits poorly (deposited 59.5); pre-hydrogenated model (Pdb2pqr skipped)            |
| SASDR99 | AADC (DOPA decarboxylase) dimer                    | MDFF-refined dimer; chain IDs repaired from CHARMM segment IDs                                         |
| SASDRN5 | NURC1                                              | AlphaFold model raw vs SREFLEX-refined; 50 mM sodium phosphate + 5 % glycerol                          |
| SASDRS2 | collagen peptide Ac-(POG)₄-QG-(POG)₅-NH₂ trimer | HYP residues and ACE/NH₂ caps; the histidine buffer of the dropped SASDRW2 at pH 6.0 |
| SASDRJ8 | de novo enterobactin esterase Syn-F4 dimer         | 200 mM Arg-HCl (amino-acid additive) + 10 % glycerol; deposited CRYSOL χ² 0.06 (errors overestimated); model from 8H7D |
| SASDVN2 | S. aureus Eap34 (Eap domains 3-4, 24.1 kDa) | MultiFoXS 1-state `fit1` only (FoXS 0.81; the 2- and 3-state fits were removed: ensembles); the script's `BUFFER` switch: `:paper` (default: acetate pH 4.0, 100 mM Arg, 100 mM Glu, 300 mM NaCl, 1 % glycerol, from Mishra et al., JBC 2024) or `:sasbdb` (HEPES pH 7.4, 140 mM NaCl: the record) |
| SASDAX2 | *Z. mobilis* pyruvate decarboxylase tetramer       | PEG 1500 as a Polymer solute with citrate and glycerol (w/v assumed); no T or energy in SASBDB (assumed); depositor χ² 0.668 (header Chi 0.816 is χ) |
| SASDV62 | human hemoglobin (3ODQ) in 100 mM sodium phosphate, no PEG | control of the Hb-PEG series (J Phys Chem B 2024, DOI 10.1021/acs.jpcb.4c03003); CRYSOL fit2 overlay, depositor χ² 1.098; the four HEM groups are scattered (kept ligands), without hydrogens |
| SASDTK5 | HasApf5 + Fe-TPP-phen dimer                        | six alternative dimer geometries; CHES–KOH pH 9.5; pre-hydrogenated                                   |
| SASDVG2 | Eap + cathepsin-G tetramer                         | MultiFoXS 1-state `fit1` only (2- and 3-state removed: ensembles); models extracted from an ensemble file (`MODEL` ≠ 1) |
| SASDAC9 | Varkud satellite ribozyme dimer (G638A)            | two RNA chains with the same chain id; depositor FoXS χ² 680 kept as a stress test                   |
| SASDAN8 | mLBS1-2 viral terminal-repeat B-DNA duplex         | deoxy DNA with bare A/C/G/T names; depositor χ² 2.464 (header) vs 4.58 (file)                        |
| SASDB48 | ICP4N dimer + 19-bp IE3 DNA                        | protein written as HETATM records; mixed model                                                         |
| SASDCA3 | ZBTB38 zinc fingers + methylated 54-nt DNA         | mixed; Zn²⁺ as ATOM records; fit3 only                                                               |
| SASDCM5 | vaccinia E9 polymerase + 29-nt template-primer DNA | mixed; a modified nucleotide (DOC) and a dCTP ligand                                                   |
| SASDDF7 | armless mitochondrial tRNA-Arg (64 nt)             | RNA with 10 mM Mg²⁺; SEC-SAXS                                                                        |
| SASDF95 | PaHigA dimer + 32-bp DNA (two dimer copies)        | mixed; glycerol and PMSF in the buffer                                                                 |
| SASDJ66 | GATA-element duplex DNA (2 × 22 nt)               | DNA only; SEC-SAXS                                                                                     |
| SASDJZ2 | EcoKMcrA N-terminal domain + 12-bp DNA             | mixed; the model's DNA is homologous, not identical, to the measured one                               |
| SASDK36 | LC-18t ssDNA aptamer (35 nt)                       | PARKED: the buffer recipe is open                                                                      |
| SASDK94 | BusR (4 chains) + 46-bp dsDNA                      | mixed, the largest of the set; SEC-SAXS; c-di-AMP ligands kept (2BA, 88 atoms, no hydrogens)                                      |
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
| SASDRX8 | *A. fulgidus* Argonaute + AfAgo-N + 14-bp DNA duplex | mixed; fit1 model is protein only, fit2 adds DNA chains R and S (legacy names, 5'-phosphate `O3P`) |
| SASDHT9 | NanR dimer + 13-bp DNA duplex | mixed; CRYSOL 2.295; model NanR x2 (res. 32-249) + one 13-bp duplex of the 17-bp sample; DNA atoms have occupancy 0.00, plain T A C G names |
| SASDF29 | STAU1 dsRBD4 + 34-nt ARF1 RNA | mixed; NMR bundle of 20 MODELs (fits MODEL 1), no hydrogens, plain G C A U names, two HETATM HIS with a stray chain letter, no 5' phosphate; CRYSOL 1.167 |
| SASDVV4 | ST9 viral RNA (54 nt)                              | RNA only; SEC-SAXS                                                                                     |
| SASDVX2 | SARS-CoV-2 stem-loop 5 RNA (~148 nt)               | RNA only; the largest nucleic-acid-only model of the first batches                                     |
| SASDWJ4 | class V GTP-binding RNA aptamer (68 nt) + 2 GTP    | PARKED and OPEN: pdb2pqr aborts on the charge check at a chain end; GTP concentration unknown          |
| SASDWR5 | 37-nt stimulatory-element RNA                      | RNA only; SREFLEX model from an AlphaFold template; SEC-SAXS                                           |
| SASDYM2 | human prothrombin + NU172 DNA aptamer              | mixed; buffer text ends with a comma; error bars overestimated                                         |

## Replacement entries

Entries that cover exotic buffers, polymers, G-quadruplexes, large complexes, protein-nucleic acid complexes). Their scripts are wired (`refChi2` set as the last column says, "none" where SASBDB has no deposited fit and the script passes no `references`), but **none has been run yet**: no run log exists, so they are not in the Results table, which fills in from each folder's `<ID>.LOG` after `bysl results table --update`. The last column is the script's `refChi2` string, which becomes the table's depositor column. Per-entry notes (open buffer questions, paper checks) are in `notes/replacement-entries.md`.

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASD2P2 | chondroitin sulfate 8-mer (CHARMM "mix" model, 197 atoms, glycan ALONE, not a CXCL8 complex) in 50 mM sodium phosphate + 100 mM NaCl, pH 7.0, 5 °C | polysaccharide; CHARMM residue names 4ZB/VVB/6VB/SO3 collide with unrelated wwPDB components, harmless (ATOM records load by element) but the model's 77 hydrogens are dropped (`ADD_HYDROGENS = false`); Biochem J 2026 DOI 10.1042/BCJ20260348 (paper read: Suppl. Table 1 gives phosphate + NaCl, no MgCl2 for the free glycan); CRYSOL fit1 overlay, depositor χ² 0.899 (paper's own CRYSOL run: 0.922) | CRYSOL 0.899 |
| SASDA58 | pUL26N protease domain (pseudorabies virus), dimer | protein; PDB 4V07 dimer with Cl⁻ and Mg²⁺ ions; imidazole-rich buffer (Tris, 0.5 M NaCl, 0.25 M imidazole, 5 % glycerol, 50 mM urea, 0.2 M MgCl2; paper read: the 0.2 M MgCl2 series, 283 K, λ 1.24 Å), ionic strength about 1.2 M; CRYSOL 1.288 (header and REST agree); pH 7.5, 10 °C | CRYSOL 1.288 |
| SASDAB6 | Xylose isomerase (tetramer) in 50 % D2O | protein; CRYSOL 3.0 fit on the PDB 4E3V tetramer (12 056 records; 8 atoms with the residue name "d" are dropped by the loader); sulfate salts (200 mM Na2SO4, 50 mM K2SO4) and 50 % v/v D2O, 20 mM HEPES, 1 mM MgCl2, pH 7.0, 20 °C, λ 0.124 nm (the paper's values, which override SASBDB's pH 6.6, 10 °C, 0.12 nm); header "Chi:1.188" is a χ, χ² 1.411 (= REST) | CRYSOL 1.411 |
| SASDAC2 | Hen lysozyme at pH 3.8 (EMBL standard) | protein; PDB 1LYZ; 40 mM sodium acetate, pH 3.8, 10 °C (acetate 10.6 % ionised); header "Chi:1.205" is a χ, χ² 1.452 (= REST) | CRYSOL 1.452 |
| SASDAK6 | Xylose isomerase (tetramer) in PBS with 50 % glycerol | protein; "assembly" model built from PDB 1OAD (12 266 records, with its crystallisation ligands MPD, MRD, MQD, TRS, Mg, Mn); PBS plus 50 % v/v glycerol, pH 7.4, standard PBS recipe cited (CSHP 2006), temperature 25 °C assumed (default); header "Chi:1.431" is a χ, χ² 2.048 (= REST) | CRYSOL 2.048 |
| SASDAQ2 | bovine ubiquitin (1UBQ) in 40 mM sodium acetate, 150 mM NaCl, pH 5.5 | EMBL standard-protein curve extrapolated to zero concentration, 10 °C, no publication; CRYSOL fit1 overlay, depositor χ² 4.009; acetate/acetic acid split computed at pH 5.5, hydrogens added | CRYSOL 4.009 |
| SASDDG7 | armless mitochondrial tRNA-Ile (47 nt) | tRNA with 10 mM Mg²⁺; same paper and buffer as SASDDF7; SEC-SAXS | CRYSOL 1.659 |
| SASDDN6 | human Hsp70 (HSPA1A T204A) antiparallel dimer, MODELLER model with two ATP, 148 kDa, in 50 mM HEPES, 150 mM potassium acetate, 2 mM MgCl2, pH 7.5, 4 °C | 4 °C in-house curve (paper: 277 K, Cu Kα); HEPES/KOAc/MgCl2 buffer from SASBDB (the paper names the SAXS buffer only as "size exclusion buffer"); dimer separated from free ATP by SEC, so no ATP in the buffer; two ATP scattered; Mol Cell Proteomics 2019 DOI 10.1074/mcp.RA118.001044 (paper consulted); CRYSOL fit1 overlay, depositor χ² 1.150 | CRYSOL 1.150 |
| SASDEL7 | human glycine decarboxylase dimer (6I33, 190 kDa) in 10 mM Tris, 100 mM NaCl, 1 mM DTT, pH 7.5 | synchrotron (ESRF BM29) curve, I/σ ≈ 200 at low q; PLP, EDO and BCT ligands scattered; NO glycine in the buffer (no amino-acid-buffer coverage); no publication in SASBDB; CRYSOL fit1 overlay (3-column .fit), depositor χ² 3.155 | CRYSOL 3.155 |
| SASDFC3 | ATP citrate lyase tetramer (35 k heavy atoms), FoXS 5.473 | HEPES + Tris + citrate + CoA mixed buffer, jointly titrated Cl⁻; citrate salt form assumed | FoXS 5.473 |
| SASDGF3 | Zika virus xrRNA1 (72 nt paper / 68 SASBDB / 74 model), ModeRNA model | pure RNA with 5 mM Mg²⁺ in Tris-HCl; blank chain id, no element column; curve extrapolated to zero concentration | CRYSOL 0.754 |
| SASDGA5 | PupR CCSSD (24 kDa, 213 residues), crystal structure with 15 selenomethionines (MSE), in 25 mM HEPES, 400 mM LiCl, 10 % v/v glycerol, pH 7.5, 25 °C | SEC-SAXS (J Biol Chem 2020, DOI 10.1074/jbc.RA119.010697); CRYSOL fit2 only (fit1 MultiFoXS ensemble and fit3 DAMMIN not used); the high depositor χ² is a rigid-structure fit; Na⁺ counter-ion of HEPES (NaOH titrant) assumed; 25 °C is the paper's "ambient" with the SASBDB value; whole curve to 0.37 Å⁻¹ | CRYSOL 4.862 |
| SASDHX2 | Human DHDDS homodimer (MODELLER model, 5504 heavy atoms) in Tris-HCl, 150 mM NaCl, 20 mM 2-mercaptoethanol, 0.02 % Triton X-100, pH 7.5, 20 °C | Biomolecules 2019, DOI 10.3390/biom9110660; FoXS fit1; the Triton X-100 solute (Polymer row, derived volume) with the percentage taken as w/v; Tris concentration NOT stated by SASBDB or the paper (25 mM assumed, ±20 %); curve in nm⁻¹ converted | FoXS 1.033 |
| SASDJR3 | SaNsrF nucleotide-binding domain of an ABC transporter (TopModel homology model, 31 kDa), in 100 mM HEPES, 150 mM NaCl, 10 % glycerol, pH 8, 15 °C | absolute-scale merged in-house curve; HEPES + glycerol buffer; GASBOR fit1 skipped, CRYSOL fit2 on the TopModel model (amber HIE renamed HIS in a cleaned copy); Sci Rep 2020 DOI 10.1038/s41598-020-72237-7 (paper read twice: it names no SAXS buffer, so SASBDB's, the only statement, is used; glycerol v/v and HEPES/NaOH are conventions); depositor χ² 1.156 | CRYSOL 1.156 |
| SASDJZ4 | DNA-PK complex with DNA (45 k heavy atoms), FoXS/MultiFoXS 3.655 | protein + DNA, Tris-HCl, NaCl, glycerol, azide; deposited fit may be a multi-state fit | FoXS 3.655 |
| SASDKH2 | E2F1/DP1 + 15-bp DNA | protein-DNA; one GROMACS/PLUMED MD frame (with hydrogens, no water, 72 230 Å³ in the CRYSOL header), Amber DNA names; CRYSOL 1.262 (SASBDB, header and REST agree); Tris-HCl + NaCl + DTT, 20 °C, q ≤ 0.25 Å⁻¹ | CRYSOL 1.262 |
| SASDKY3 | VS ribozyme, 101 nt RNA (NMR-SAXS hybrid model) in MES, KCl, MgCl2 | NAR 2021, DOI 10.1093/nar/gkab963; CRYSOL fit1 overlay, depositor χ² 1.197 (header "Chi^2", recomputed 1.202); wavelength from SASBDB only, NaOH titrant of MES assumed | CRYSOL 1.197 |
| SASDL27 | N-Oct-3 POU domain + 24-bp rat CRH DNA | protein-DNA; atomic model with hydrogens, legacy DNA names (G C A T, O5*), 39 997 Å³ in the CRYSOL header; CRYSOL 1.096 (SASBDB, header and REST agree); 50 mM Tris, 0.4 M NaCl, 2 % glycerol, 2 mM DTT, 12 °C, q ≤ 0.3 Å⁻¹ | CRYSOL 1.096 |
| SASDL37 | N-Oct-3 POU domain + 24-bp human DR-alpha DNA | protein-DNA; atomic model with hydrogens, legacy DNA names (G C A T, O5*), 40 020 Å³ in the CRYSOL header; CRYSOL 1.184 (SASBDB, header and REST agree); 50 mM Tris, 0.4 M NaCl, 2 % glycerol, 2 mM DTT, 12 °C, q ≤ 0.3 Å⁻¹ | CRYSOL 1.184 |
| SASDM63 | RBM5 RRM1-ZnF1-RRM2 (I107T, C191G) + 12-nt `GGCU_12` RNA | protein-RNA; heavy-atom model with one Zn²⁺ (an ATOM record) and the RNA split over two chains, no hydrogens, 33 142 Å³ in the CRYSOL header; CRYSOL 1.685 (SASBDB, header and REST agree); 20 mM MES, 100 mM NaCl, 1 mM DTT, pH 6.5, 5 °C, X-ray energy 8.0405 keV | CRYSOL 1.685 |
| SASDM86 | c-KIT 2-tetrad G-quadruplex 6GH0 (22 nt), K+ buffer BPEK | model carries hydrogens and one K+ ion; same BPEK recipe as SASDM76 | CRYSOL 3.191 |
| SASDM96 | human telomere G-quadruplex 2GKU (24 nt), K+ buffer BPEK | the model carries hydrogens and two K+ ions; same BPEK recipe as SASDM76 | CRYSOL 1.172 |
| SASDMA6 | kRas promoter G-quadruplex 5I2V (22 nt), K+ buffer BPEK | model carries hydrogens and two K+ ions; same BPEK recipe as SASDM76 | CRYSOL 3.003 |
| SASDMB6 | WNT promoter G-quadruplex 6L92 (22 nt), K+ buffer BPEK | model carries hydrogens and two K+ ions; same BPEK recipe as SASDM76 | CRYSOL 2.332 |
| SASDMC6 | c-KIT parallel G-quadruplex 2KQG (21 nt), K+ buffer BPEK | model carries hydrogens and two K+ ions; same BPEK recipe as SASDM76 | CRYSOL 3.235 |
| SASDMM9 | RocR tetramer (REFMAC model, 4 Mg, one HEPES) in Tris, NaCl, imidazole, glycerol, DTT | J Bacteriol 2012, DOI 10.1128/JB.00560-12; CRYSOL fit1 overlay, depositor χ² 1.169 (header "Chi:1.081" is χ, = REST 1.168561); glycerol basis (v/v) and Tris/imidazole titrant (HCl) assumed, no temperature recorded (25 °C default); wild-type data against the R286W crystal model is the paper's own Fig. 3A comparison | CRYSOL 1.169 |
| SASDMS6 | NONO homodimer (5IFM chains K, L; 4186 heavy atoms) in 20 mM Tris-Cl, 250 mM KCl, 50 mM L-proline, 0.5 mM EDTA, pH 7.5, 4 °C | NAR 2022, DOI 10.1093/nar/gkab1216 (buffer and temperature from SASBDB only, paper not read); CRYSOL fit1; the proline-in-buffer entry; q ≤ 0.25 Å⁻¹ (noise floor above); Tris-HCl counter-ion | CRYSOL 0.937 |
| SASDMU4 | RXRα ligand-binding domain homodimer (3463 heavy atoms, 183 crystal waters dropped) in 20 mM Tris, 100 mM NaCl, 100 mM KCl, 5 % glycerol, 2 mM CHAPS, 5 mM DTT, pH 7.5, 10 °C | Biochemistry 2016, DOI 10.1021/acs.biochem.5b01122; CRYSOL fit1; header "Chi:1.410" is a χ and SASBDB's 1.988 is the χ² (1.410² = 1.988), so refChi2 is 1.988; the CHAPS volume is a 3D-RISM estimate; curve in nm⁻¹ converted; temperature from SASBDB only | CRYSOL 1.988 |
| SASDNJ2 | KaiABC complex A12B6C6 (778 kDa, 24 chains, SEC-SAXS) in phosphate, NaCl, MgCl2, EDTA, ATP, DTT, Arg, Gln | Commun Biol 2022, DOI 10.1038/s42003-022-03143-z; CRYSOL fit1 overlay, depositor χ² 4.549 (recomputed 4.62); SAXS buffer from SASBDB, not confirmed by the paper; model has no ATP | CRYSOL 4.549 |
| SASDNS2 | Native human haemoglobin in Ringer's lactate | protein with haems; PDB 2DN1 expanded to the biological tetramer with BIOMT operator 2; Ringer's lactate composition assumed (USP), pH 6.5, temperature not stated (25 °C assumed by owner decision); header 2.763 is the χ² (REST 7.634 is its square); three-column .fit | CRYSOL 2.763 |
| SASDNW9 | GRP78 nucleotide-binding domain (3IUC chain) in PBS pH 7.2 + 1.5 % glycerol | SEC-SAXS (Nat Commun 2024, DOI 10.1038/s41467-024-52478-0); CRYSOL fit1 overlay, depositor χ² 0.993 (header; REST 1.014); paper adds 1.5 % glycerol (v/v) to the buffer; PBS = CSHL standard recipe (cited, not given in paper/SASBDB); model has no ADP/Ca, hydrogens added | CRYSOL 0.993 |
| SASDP74 | AT-rich 12-bp dsDNA, 8A4I chains C,D (fit2 only) | Tris-HCl/NaCl, DNA only, heavy-atom model (no H); the deposited fit1 is a DAMMIN bead model, not used | CRYSOL 1.271 |
| SASDPZ8 | Gli-233 ssDNA aptamer (33 nt), Dulbecco PBS with Ca/Mg | GROMACS frame with hydrogens; buffer is the standard Dulbecco +Ca/Mg recipe, cited from supplier formulations (paper unreachable), measured at 4 °C | CRYSOL 1.041 |
| SASDQT9 | RAD51 F86E/A89E with BRC4 peptide (AlphaFold model) in HEPES, sodium sulfate, sucrose | Angew Chem 2023, DOI 10.1002/anie.202312517; FoXS fit1 overlay, depositor χ² 9.306; sucrose taken as 2 % w/v and NaOH titration assumed; model has its own hydrogens | FoXS 9.306 |
| SASDR23 | collagen peptide T3-785 (Ac-(POG)3-ITGARGLAGPOG-(POG)3-NH2) trimer | the type III collagen sequence near the MMP-1 cleavage site (peptide T3-785); the histidine buffer of SASDRS2 at pH 6.0, 20 °C; q ≤ 0.3 of a deposited range to 0.37 (the tail is noise floor) | CRYSOL 0.079 |
| SASDRR8 fit2 | Chloroplast FOF1-ATP synthase (39 k heavy atoms), CRYSOL 1.347 | HEPES-NaOH, NaCl, MgCl2; detergent tPCC-alpha-M 0.04 % missing from the solute table (omitted); sample may contain dimers | CRYSOL 1.347 |
| SASDRT2 | collagen peptide MBL-N (Ac-(POG)4-EPGQGLRG-(POG)3-NH2) trimer | the native MBL collagen-region sequence flanked by POG triplets; the histidine buffer of SASDRS2 at pH 6.0, 20 °C; q ≤ 0.3 of a deposited range to 0.37 (the tail is noise floor) | CRYSOL 0.054 |
| SASDRU2 | collagen peptide MBL-E (Ac-(POG)5-EOGQGLRG-(POG)3-NH2) trimer | the MBL sequence with Pro hydroxylated in the GLU triplet; the histidine buffer of SASDRS2 at pH 6.0, 20 °C; the whole deposited range to 0.37 | CRYSOL 3.915 |
| SASDRV2 | collagen peptide MBL-12 (Ac-(POG)5-EPGQGLRG-(POG)5-NH2) trimer | the MBL sequence flanked by five POG triplets on each side; the histidine buffer of SASDRS2 at pH 6.0, 20 °C; q ≤ 0.3 of a deposited range to 0.37 (the tail is noise floor) | CRYSOL 0.036 |
| SASDRX2 | collagen peptide (POG)13 (Ac-(POG)13-NH2) trimer | the 13-triplet (POG) control; the histidine buffer of SASDRS2 at pH 6.0, 20 °C; q ≤ 0.3 of a deposited range to 0.37 (the tail is noise floor) | CRYSOL 0.044 |
| SASDRY2 | collagen peptide (PPG)10 ((PPG)10 with unblocked ends) trimer | the hydroxyproline-free control; the histidine buffer of SASDRS2 at pH 6.0, 20 °C; the whole deposited range to 0.37 | CRYSOL 2.334 |
| SASDRZ2 | collagen peptide G>A (Ac-(POG)4-POA-(POG)5-NH2) trimer | the Gly-to-Ala substitution model; the histidine buffer of SASDRS2 at pH 6.0, 20 °C; the whole deposited curve fitted (q to 0.37 Å⁻¹, no cut) | CRYSOL 2.08 |
| SASDTW4 | 24-mer (PDB 3bve, 34 k heavy atoms), CRYSOL 1.343 | plain 20 mM Tris pH 8.0; sample construct (tag, mutations) differs from 3bve | CRYSOL 1.343 |
| SASDTX4 | rabbit G-actin (3HBT) with ATP, Ca²⁺ and sulfate ligands, in 5 mM Tris, 0.1 mM CaCl2, 1 mM NaN3, 0.2 mM ATP, pH 8.05 | small (42 kDa) noisy in-house curve to 0.18 Å⁻¹, 30 points I ≤ 0 dropped; scattered ATP/Ca²⁺/HIC/SO4 ligands; Tris-HCl counter-ion Cl⁻; BBRC 2023 DOI 10.1016/j.bbrc.2023.149340 (buffer, pH 8.05 and chi2 confirmed in the paper); CRYSOL fit1 overlay, depositor χ² 1.037 | CRYSOL 1.037 |
| SASDUP5 | M. smegmatis IMPDH octamer (model, protein only) with 10 mM ATP, in 50 mM HEPES pH 7.4, 200 mM KCl, 0.5 mM TCEP, 12 mM MgCl2 | Nat Commun 2024, DOI 10.1038/s41467-024-50933-6; buffer and ATP from the paper (Methods, Fig. 4f; SASBDB lists pH 7.5, 2 mM MgCl2 and no nucleotide); 20 °C from SASBDB; CRYSOL fit1 overlay, depositor χ² 2.433; ATP counter-ions not modelled; NaOH titration assumed | CRYSOL 2.433 |
| SASDUX3 | Actin filament fragment, 17 subunits (50 k heavy atoms), CRYSOL 2.314 | Tris-HCl, KCl, MgCl2, ATP, 2-mercaptoethanol at 10 °C; model fixed: ADP to HETATM, HMS to HIC, MTL(M) to Mg | CRYSOL 2.314 |
| SASDV25 | ST9 PK-mutant RNA (59 nt), RNAMasonry model, fit2 | pure RNA with no Mg²⁺ (Tris, NaCl, DTT, NaN3); SEC-SAXS; fit1 (PyMOL, chi2 125.7) not used | CRYSOL 0.958 |
| SASDV82 | human haemoglobin, 5 mg/ml, PEG-series member, model 3ODQ (4 HEM) | 100 mM sodium phosphate pH 7.0 with 5 % (w/v) PEG 600; no deposited fit, no reference curve | none |
| SASDV92 | human haemoglobin, 5 mg/ml, PEG-series member, model 3ODQ (4 HEM) | 100 mM sodium phosphate pH 7.0 with 10 % (w/v) PEG 600; no deposited fit, no reference curve | none |
| SASDVA2 | human haemoglobin, 5 mg/ml, PEG-series member, model 3ODQ (4 HEM) | 100 mM sodium phosphate pH 7.0 with 20 % (w/v) PEG 600; no deposited fit, no reference curve | none |
| SASDVB2 | human haemoglobin, 5 mg/ml, PEG-series member, model 3ODQ (4 HEM) | 100 mM sodium phosphate pH 7.0 with NO PEG ("1 week after SEC"; the SASBDB buffer field says 5 % PEG 2000 but the paper Table 1 and the .dat header show a PEG-free sample); no deposited fit, no reference curve | none |
| SASDVC2 | human haemoglobin, 5 mg/ml, PEG-series member, model 3ODQ (4 HEM) | 100 mM sodium phosphate pH 7.0 with 5 % (w/v) PEG 2000; no deposited fit, no reference curve | none |
| SASDVD2 | human haemoglobin, 5 mg/ml, PEG-series member, model 3ODQ (4 HEM) | 100 mM sodium phosphate pH 7.0 with 5 % (w/v) PEG 4000; no deposited fit, no reference curve | none |
| SASDVE2 | human haemoglobin, 5 mg/ml, PEG-series member, model 3ODQ (4 HEM) | 100 mM sodium phosphate pH 7.0 with 10 % (w/v) PEG 2000; no deposited fit, no reference curve | none |
| SASDVW4 | ST9 wild-type RNA (54 nt), PyMOL model | pure RNA with 1 mM Mg²⁺ and one Mg²⁺ ion in the model; same paper as SASDVV4 (10 mM Mg²⁺) | CRYSOL 1.779 |
| SASDWS5 | 2A protein-RNA pseudoknot complex (protein + 37 nt RNA) | CORAL "mix" model: its 29 dummy residues are removed (fixture keeps the original), so the fit lacks ~3 kDa of tails; glycerol and DTT in the buffer | CRYSOL 1.114 (CORAL mix model, with dummy residues) |
| SASDWT5 | BRC4 peptide bound to Δ97-RAD51 (AlphaFold model, 2170 heavy atoms) in 20 mM K2HPO4/KH2PO4, 100 mM NaCl, 200 mM Li2SO4, 1 mM DTT, 2 % sucrose, pH 8.0, 15 °C | Commun Biol 2026, DOI 10.1038/s42003-026-11218-4; FoXS fit1 (depositor range 0.013-0.238 Å⁻¹, the whole curve is fitted here); lithium sulfate and sucrose contrast entry; I = 0.76 M, above the Davies limit (the phosphate split barely changes); sucrose taken as w/v; temperature from SASBDB only | FoXS 1.151 |
| SASDWX6 | Apoferritin dynamic dimer of 24mers (2w0o-based, same model file as SASDWY6) in PBS with Ca, Mg | SASBDB only (no paper in the record); CRYSOL fit1 overlay, depositor χ² 1.257 (recomputed 1.256); phosphate cation assumed Na⁺ | CRYSOL 1.257 |
| SASDWY6 | Apoferritin dimer of 24mers (2w0o-based, 48 chains, 66,288 heavy atoms) in PBS with Ca, Mg | SASBDB only (no paper in the record); CRYSOL fit1 overlay, depositor χ² 1.058 (recomputed 1.057); model has altloc A/B records; phosphate cation assumed Na⁺ | CRYSOL 1.058 |

SASDF39, SASDMU7 and SASDPT4 were wired and dropped again (kept under `notes/dropped-entries/`). The seven haemoglobin/PEG entries (SASDV82 ... SASDVE2) have no deposited fit and no reference curve; they were listed under "No reference fit at all" above and are now deliberately back as buffer-physics entries (the PEG series). SASDGF3 is the xrRNA1 construct (the paper's data availability statement), not xrRNA2 as its script header says.

### Slice (31 entries: 7 + 7 protein, 17 nucleic acid; sources in `new-entries-*.md`)

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDF53 | Btk kinase domain (1K2P; 2087 heavy atoms) in 25 mM Tris, 300 mM NaCl, 1 mM TCEP, 5 % glycerol, pH 7.5, 20 C | Nat. Commun. 2020, DOI 10.1038/s41467-020-16128-5 (buffer read in the paper; it differs from SASBDB: 25 mM Tris/300 mM NaCl vs 20 mM/150 mM; temperature from SASBDB); CRYSOL fit2; the TCEP + glycerol Tris entry, BM29 0.992 A; Tris-HCl counter-ion | CRYSOL 1.275 (header Chi^2 1.275) |
| SASDGD2 | human IBA57 (6QE3; 2348 heavy atoms) in 50 mM Na phosphate, 150 mM NaCl, 5 mM DTT, 3 % glycerol, pH 7.0, 20 C | Sci. Rep. 2019, DOI 10.1038/s41598-019-55313-5 (buffer read in the paper, which adds 3 % v/v glycerol to the SASBDB buffer; temperature from SASBDB); CRYSOL fit1; the phosphate + DTT entry, P12 SEC-SAXS; the model carries hydrogens (re-placed by pdb2pqr) and 245 waters (dropped) | CRYSOL 1.075 (header Chi^2 1.075) |
| SASDJB2 | AgeI restriction endonuclease monomer (2089 heavy atoms) in 10 mM Tris-HCl, 150 mM NaCl, 5 mM CaCl2, pH 7.5, 20 C | NAR 2017, DOI 10.1093/nar/gkw1310 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit2, reference rescaled (the .fit is off the data scale); the Ca2+ Tris entry, P12 0.124 nm; Tris-HCl counter-ion | CRYSOL 0.867 (header Chi^2 0.867) |
| SASDC57 | human dUTPase homotrimer (2826 heavy atoms) in 50 mM HEPES, 300 mM NaCl, 5 mM MgCl2, pH 7.5, 20 C | Sci. Rep. 2018, DOI 10.1038/s41598-018-22145-8 (buffer and the 20 C batch temperature read in the paper; SASBDB gives 10 C); CRYSOL fit2, reference rescaled (the .fit is off the data scale); the Mg2+ HEPES entry, P12; 36 altloc atoms; HEPES-Na counter-ion | CRYSOL 1.059 (header Chi^2 1.059) |
| SASDJG5 | SARS-CoV-2 main protease dimer (6M03; 4734 heavy atoms) in 50 mM Tris-HCl, 1 mM DTT, 1 mM EDTA, pH 7.4, 6 C | Nat. Commun. 2020, DOI 10.1038/s41467-020-19662-4 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit1; the in-house Cu K-alpha source (8051 eV), curve in 1/A; q to 0.60 of a deposited fit to 0.50; Tris-HCl counter-ion | CRYSOL 2.158 (header Chi^2 2.158) |
| SASDGA7 | tbMORNdelta6 dimer (3174 heavy atoms) in 20 mM Tris-HCl, 200 mM NaCl, 2 % (w/v) glycerol, 0.5 mM DTT, pH 8.5, 20 C | PLoS ONE 2020, DOI 10.1371/journal.pone.0242677 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit1; the high-pH (8.5) Tris entry with w/v glycerol, P12; Tris-HCl counter-ion at a low acid fraction | CRYSOL 1.160 (header Chi^2 1.160) |
| SASDKJ4 | SARS-CoV-2 nsp7+nsp8 heterotetramer (4097 heavy atoms) in 50 mM Tris, 100 mM NaCl, 4 mM MgCl2, 4 mM DTT, pH 8.0, 20 C | Sci. Adv. 2021, DOI 10.1126/sciadv.abf1004 (buffer read in the paper and equal to SASBDB; temperature from SASBDB); CRYSOL fit1; four-chain complex, P12; q to 0.73 of a deposited fit to 0.50; Tris-HCl counter-ion | CRYSOL 1.306 (header Chi^2 1.306) |
| SASDN75 | SCO3201 TetR/AcrR-like regulator (S. coelicolor), homodimer, 5EFY chains C+D (2574 heavy atoms), in 20 mM Tris, 400 mM NaCl, 50 mM imidazole, 1 mM DTT, pH 8.5, 20 °C | protein; ESRF BM29; FEBS J 2022 DOI 10.1111/febs.16606 (paper read: buffer as SASBDB); Tris and imidazole share the HCl counter-ion (10.0 mM chloride, I about 0.41 M); whole curve to 0.497 Å⁻¹ (README q-cut rule not met); header and recomputed χ² agree | CRYSOL 1.171 |
| SASDNF7 | human CK2α, apo (PDB 3Q04, 328 residues, 3058 records) in 25 mM Tris, 500 mM NaCl, pH 8.5, 20 °C | protein; ESRF BM29; Front Mol Biosci 2022 DOI 10.3389/fmolb.2022.906390 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion; the model carries 3 SO4, 1 EDO and altlocs; CRYSOL fit1 overlay (fit2 DAMMIF not used) | CRYSOL 1.29 |
| SASDNK8 | NSD3 C-terminal construct (MDFF-refined RaptorX model, 2806 heavy atoms, no Zn) in 0.5 M NaCl, 20 mM Tris-HCl, 5 mM DTT, pH 8.5, 20 °C | protein; Diamond B21 SEC-SAXS; Front Mol Biosci 2024 DOI 10.3389/fmolb.2024.1191246 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion; MDFF model fitted to this curve; q cut 0.25 Å⁻¹ (README rule); CRYSOL fit1 overlay (fit2 DAMMIN not used) | CRYSOL 1.228 |
| SASDNL8 | NSD3 PWWP2-SET construct (MDFF-refined RaptorX model, 3033 heavy atoms, no Zn) in 0.5 M NaCl, 20 mM Tris-HCl, 5 mM DTT, pH 8.5, 20 °C | protein; Diamond B21 SEC-SAXS; same paper and buffer as SASDNK8 (DOI 10.3389/fmolb.2024.1191246); Tris-HCl chloride counter-ion; MDFF model fitted to this curve; whole curve to 0.232 Å⁻¹; CRYSOL fit1 overlay (fit2 DAMMIN not used) | CRYSOL 1.066 |
| SASDNP5 | human TEX12 coiled-coil tetramer (PDB 6HK8, 2444 records) in 20 mM Tris, 150 mM KCl, pH 8.0, 25 °C (assumed) | protein; Diamond B21 SEC-SAXS; Commun Biol 2022 DOI 10.1038/s42003-022-03886-9 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion; temperature not stated, 25 °C default; 12.4 keV from the paper; model has altlocs, partial hydrogens and reused chain ids; CRYSOL fit2 overlay (fit1 DAMMIF not used), depositor χ² 1.535 | CRYSOL 1.535 |
| SASDPV7 | SmTetX flavin monooxygenase (M154I/A283T, preliminary model of 8AQ8 with FAD, 2665 records) in 25 mM Bis-Tris, 150 mM NaCl, pH 6.5, 4 °C | protein; in-house Anton Paar SAXSpoint 2.0; Acta Cryst F 2023 DOI 10.1107/S2053230X23005381 (paper read: buffer as SASBDB); Bis-Tris-HCl chloride counter-ion; 4 °C; q cut 0.36 Å⁻¹ (README rule); depositor fit only to 0.150 Å⁻¹, so refChi2 is not like for like; CRYSOL fit1 overlay (fit2 DAMMIF not used) | CRYSOL 1.05 |
| SASDVR6 | human VPS26C (AlphaFold model, 297 residues, 2319 heavy atoms) in 50 mM Tris, 150 mM NaCl, 1 mM TCEP, pH 7.5, 25 °C | protein; Diamond B21 SEC-SAXS; EMBO Rep 2024 DOI 10.1038/s44319-024-00340-1 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion (42.9 mM); AlphaFold model; q cut 0.26 Å⁻¹ (README rule), refChi2 over the whole curve; CRYSOL fit1 overlay (3-column .fit; fit2 DAMMIN not used) | CRYSOL 1.152 |
| SASDKU3 | VS ribozyme II-III-VI junction J236 (RNA) | RNA alone; MES/KCl/5 mM Mg²⁺, 20 °C; cleaned model (RG5/RG3 -> G); data to 0.97 Å⁻¹, depositor fit to 0.30, whole curve fitted | CRYSOL 1.967 |
| SASDKV3 | VS ribozyme III-IV-V junction J345 (RNA) | as KU3 (RG5/RG3 -> G) | CRYSOL 0.834 |
| SASDKW3 | VS ribozyme stem-loop VI (RNA) | as KU3 (RG5/RC3 -> G/C) | CRYSOL 2.682 |
| SASDX54 | pre-miR-20a, 60 nt (RNA) | K-phosphate/NaCl/1 mM Mg²⁺, 22 °C (paper); FoXS fit, column 3; cleaned model (G5/C3) | FoXS 0.879 |
| SASDPL6 | SARS-CoV-2 5'-UTR SL2+3 (RNA) | K-phosphate pH 6.5/150 mM KCl/TCEP, 20 °C; q cut 0.70 Å⁻¹ | CRYSOL 1.189 |
| SASDPM6 | SARS-CoV-2 5'-UTR SL4 (RNA) | as PL6; SASBDB lists 1.61, the .fit gives 0.991 | CRYSOL 0.991 |
| SASDPP6 | SARS-CoV-2 5'-UTR Ext (RNA) | as PL6; SASBDB lists 1.412, the .fit gives 1.280 | CRYSOL 1.280 |
| SASDVX4 | ST9a xrRNA, 59 nt, 10 mM MgCl2 (RNA) | Tris/NaCl/DTT, 20 °C and 0.82 Å SASBDB-only; data to 1.9 Å⁻¹ | CRYSOL 5.915 |
| SASDVY4 | ST9a xrRNA, 59 nt, no Mg²⁺ (RNA) | as VX4 | CRYSOL 11.624 |
| SASDVC3 | SARS-CoV-2 5'-UTR SL5b (RNA) | K-phosphate pH 6.2/50 mM KCl, 20 °C (SASBDB only) | CRYSOL 4.742 |
| SASDVY2 | SARS-CoV-2 5'-UTR SL5a (RNA) | as VC3; q cut 0.70 Å⁻¹ | CRYSOL 2.111 |
| SASDMG6 | G-quadruplex DNA 5CMX (DNA) | BPEK K-phosphate/185 mM KCl/EDTA; buffer partly SASBDB | CRYSOL 1.854 |
| SASDME6 | G-quadruplex DNA 6NEB (DNA) | as MG6; HETATM nucleotides converted to ATOM | CRYSOL 3.04 |
| SASDMJ6 | G-quadruplex DNA cMyc-8 (DNA) | as MG6; cleaned model (DG5/DG3 -> DG, K+ -> K), unverified | CRYSOL 1.620 |
| SASDMK6 | G-quadruplex DNA cKit-8 (DNA) | as MJ6 | CRYSOL 1.187 |
| SASDML3 | TipsytheTRex repressor + 24-bp DNA | Tris/0.5 M NaCl, 20 °C (paper); FoXS on a BILBOMD model; HSD -> HIS | FoXS 1.624 |
| SASDJX2 fit3 | EcoKMcrA dimer + hemimethylated 12-bp DNA | Tris/200 mM KCl/EDTA/azide/DTT; 20 °C SASBDB-only | CRYSOL 1.513 |

### Slice (70 entries: slices C and D, proteins; SASDDJ6 wired later; sources in `new-entries-*.md`)

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDA28 | unnamed protein monomer (3124 heavy atoms) in 20 mM Tris 150mM NaCl 1mM EDTA, pH 7.2, 10 C | J Biol Chem 2015, DOI 10.1074/jbc.M115.669895 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.12 nm from SASBDB); CRYSOL fit1; EMBL P12; depositor: header Chi^2 1.062; SASBDB 1.13 | CRYSOL 1.13 |
| SASDA38 | TGA monomer (5419 heavy atoms) in 20 mM Tris 150mM NaCl 1mM EDTA, pH 7.2, 10 C | J Biol Chem 2015, DOI 10.1074/jbc.M115.669895 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.12 nm from SASBDB); CRYSOL fit1; EMBL P12; depositor: header Chi^2 1.228; SASBDB 1.51 | CRYSOL 1.51 |
| SASDBZ2 | FbaB decamer (24220 heavy atoms) in 50 mM Tris 10 mM NaCl, pH 7.5, 10 C | PLoS One 2016, DOI 10.1371/journal.pone.0156105 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.12 nm from SASBDB); CRYSOL fit2; EMBL P12; VERY LARGE (24220 heavy atoms, long run); q cut to the depositor's range 0.0187-0.2503 A-1 | CRYSOL 1.809 (header Chi^2 1.809) |
| SASDBZ5 | NPr monomer + Enzyme I-Ntr monomer (2641 heavy atoms) in 10 mM Tris 150 mM NaCl 0.5 mM EDTA, pH 7.5, 27 C | Structure 2016, DOI 10.1016/j.str.2016.10.007 (SASBDB metadata, paper not consulted; temperature 27 C and wavelength 0.154 nm from SASBDB); CRYSOL fit1; Rigaku BioSAXS-1000; depositor: header Chi^2 1.248 | CRYSOL 1.248 |
| SASDC36 `fit1_model1` | BCR-ABL p210 fusion protein monomer (1744 heavy atoms) in 25 mM Tris-HCl, 150 mM NaCl, 5% Glycerol, 1 mM DTT, pH 7.5, 20 C | Nat Commun 2017, DOI 10.1038/s41467-017-02313-6 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.124 nm from SASBDB); CRYSOL fit1 and SREFLEX fit2 (two runs); EMBL P12 | CRYSOL 1.469 |
| SASDC36 `fit2_model1` | BCR-ABL p210 fusion protein monomer (1744 heavy atoms) in 25 mM Tris-HCl, 150 mM NaCl, 5% Glycerol, 1 mM DTT, pH 7.5, 20 C | Nat Commun 2017, DOI 10.1038/s41467-017-02313-6 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.124 nm from SASBDB); CRYSOL fit1 and SREFLEX fit2 (two runs); EMBL P12 | SREFLEX 1.001 |
| SASDCQ8 | BSA monomer (4385 heavy atoms) in TRIS 50mM, pH 7.4, 20 C | no publication linked in SASBDB (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.124 nm from SASBDB); CRYSOL fit1; EMBL P12; depositor: header Chi^2 1.055 | CRYSOL 1.055 |
| SASDCR9 | DARPin D1 monomer + Kif2A monomer + alpha tubulin dimer + beta tubulin dimer (17769 heavy atoms) in HEPES 20 mM, MgCl2 1mM, NaCl 150mM, pH 7.2, 22 C | Nat Commun 2018, DOI 10.1038/s41467-018-05025-7 (SASBDB metadata, paper not consulted; temperature 22 C and wavelength 0.1267 nm from SASBDB); CRYSOL fit2; G1; VERY LARGE (17769 heavy atoms, long run); depositor: header Chi^2 1.087 | CRYSOL 1.087 |
| SASDD33 | MbcT hexamer + MbcA hexamer (13515 heavy atoms) in 100 mM HEPES, 100 mM NaCl, pH 7.5, 10 C | Mol Cell 2019, DOI 10.1016/j.molcel.2019.01.028 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.124 nm from SASBDB); CRYSOL fit1; EMBL P12; large (13515 heavy atoms); depositor: header Chi^2 1.007 | CRYSOL 1.007 |
| SASDDH7 | CitAP-BsLA dimer (5396 heavy atoms) in 10 mM glycine, 10 mM NaCl, 1 mM trisodium citrate, pH 10, 10 C | Sci Rep 2017, DOI 10.1038/srep42592 (buffer read in the paper, which gives 10 C and 10 mM glycine/10 mM NaCl; the 1 mM citrate of the "+ citrate" dataset and pH 10 from SASBDB, which says 20 C); CRYSOL fit2 (fit 1 is DAMMIF); BM29; glycine template, citrate as trisodium citrate | CRYSOL 2.262 |
| SASDDH9 | CrPRK dimer (5329 heavy atoms) in Tris-HCl 50 mM 150 mM KCl, pH 7.5, 4 C | Proc Natl Acad Sci U S A 2019, DOI 10.1073/pnas.1820639116 (SASBDB metadata, paper not consulted; temperature 4 C and wavelength 0.099 nm from SASBDB); FoXS fit1; BM29; depositor: header Chi^2 0.889; SASBDB 1.222 | FoXS 0.889 |
| SASDDJ6 | M. hassiacum SAM-dependent O-methyltransferase dimer (3598 heavy atoms, MODELLER model) in 20 mM bis-tris propane, 50 mM NaCl, 2 mM DTT, 5 % v/v glycerol, pH 7.5, 10 C | PNAS 2019, DOI 10.1073/pnas.1813450116 (not open access, SASBDB buffer); diprotic BTP written as three species rows (dication 4.708, cation 14.99, neutral 0.2994 mM, Cl⁻ 24.41 mM from the template engine at pH 7.5, I 0.079 M); the BTP species volumes are 3D-RISM estimates (a repeated RISM run was about 12 cm³/mol lower than their basis: owner to decide) and both pK are grade D; glycerol v/v assumed; CRYSOL fit1 covers q ≤ 0.30 of the data's 0.49 (not like for like); not yet run | CRYSOL 3.664 |
| SASDDL3 | RNase monomer (951 heavy atoms) in phosphate buffered saline (PBS), pH 7, 10 C | Biophys J 2018, DOI 10.1016/j.bpj.2018.04.018 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.124 nm from SASBDB); CRYSOL fit1; EMBL P12; depositor: header Chi^2 0.821 | CRYSOL 0.821 |
| SASDE27 | unnamed protein monomer (1473 heavy atoms) in 20 mM sodium phosphate, pH 7, 25 C | J Mol Biol 2018, DOI 10.1016/j.jmb.2018.12.005 (SASBDB metadata, paper not consulted; temperature 25 C and wavelength 0.1541 nm from SASBDB); CRYSOL fit1; Bruker Nanostar II; depositor: header Chi^2 1.425 | CRYSOL 1.425 |
| SASDE35 | OVA monomer (2955 heavy atoms) in PBS, pH 7.4, 23 C | J Appl Crystallogr 2018, DOI 10.1107/S1600576718014462 (SASBDB metadata, paper not consulted; temperature 23 C and wavelength 0.134 nm from SASBDB); FoXS fit1; Xenocs BioXolver L with MetalJet; depositor: header Chi^2 0.749 | FoXS 0.749 |
| SASDE36 | ATP-citrate synthase tetramer (31604 heavy atoms) in 20mM HEPES, 150mM NaCl, pH 7.2, 20 C | Nature 2019, DOI 10.1038/s41586-019-1095-5 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.124 nm from SASBDB); FoXS fit1; EMBL P12; VERY LARGE (31604 heavy atoms, long run); depositor: SASBDB 2.821; no header chi^2 | FoXS 2.821 |
| SASDEB5 | BSA monomer (4672 heavy atoms) in 50 mM HEPES, pH 7.5, 25 C | J Appl Crystallogr 2018, DOI 10.1107/S1600576718014462 (SASBDB metadata, paper not consulted; temperature 25 C and wavelength 0.134 nm from SASBDB); CRYSOL fit1; Xenocs BioXolver L with MetalJet; depositor: header Chi^2 1.027 | CRYSOL 1.027 |
| SASDEC5 | BSA dimer (9348 heavy atoms) in PBS, pH 7.4, 23 C | J Appl Crystallogr 2018, DOI 10.1107/S1600576718014462 (SASBDB metadata, paper not consulted; temperature 23 C and wavelength 0.134 nm from SASBDB); FoXS fit1; Xenocs BioXolver L with MetalJet; large (9348 heavy atoms); depositor: header Chi^2 0.951 | FoXS 0.951 |
| SASDEK4 | PmScsCΔN monomer (1376 heavy atoms) in 10mM HEPES, 150mM NaCl, pH 7.4, 10 C | Acta Crystallogr D Struct Biol 2019, DOI 10.1107/S2059798319000081 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.1033 nm from SASBDB); CRYSOL fit2; SAXS/WAXS; depositor: header Chi^2 1.120 | CRYSOL 1.120 |
| SASDEM3 | OXA-48 dimer (4119 heavy atoms) in 50 mM HEPES 50 mM K2SO4, pH 7, 25 C | FEBS J 2018, DOI 10.1111/febs.14643 (SASBDB metadata, paper not consulted; temperature 25 C and wavelength 0.09919 nm from SASBDB); CRYSOL fit1; BM29; depositor: header Chi^2 5.025 | CRYSOL 5.025 |
| SASDEP7 | FLNa3-5 P637Q monomer (2165 heavy atoms) in 20 mM Tris, 100 mM NaCl, 1 mM DTT, pH 8, 20 C | Structure 2018, DOI 10.1016/j.str.2018.09.007 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.1 nm from SASBDB); CRYSOL fit1; BM29; depositor: header Chi^2 1.123 | CRYSOL 1.123 |
| SASDEQ7 | FLNa3-5 monomer (2173 heavy atoms) in 20 mM Tris, 100 mM NaCl, 1 mM DTT, pH 8, 20 C | Structure 2018, DOI 10.1016/j.str.2018.09.007 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.1 nm from SASBDB); CRYSOL fit1; BM29; depositor: header Chi^2 1.001 | CRYSOL 1.001 |
| SASDES5 | mmNT-SRCR3 monomer (827 heavy atoms) in 25 mM HEPES, 0.1 M NaCl, pH 8, 20 C | Protein Sci 2019, DOI 10.1002/pro.3587 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.09919 nm from SASBDB); CRYSOL fit1; BM29; depositor: header Chi^2 1.399 | CRYSOL 1.399 |
| SASDEZ6 | unnamed protein dimer (2892 heavy atoms) in 20 mM sodium phosphate, pH 7, 25 C | J Mol Biol 2018, DOI 10.1016/j.jmb.2018.12.005 (SASBDB metadata, paper not consulted; temperature 25 C and wavelength 0.1541 nm from SASBDB); CRYSOL fit2; Bruker Nanostar II; depositor: header Chi^2 4.792 | CRYSOL 4.792 |
| SASDF55 | LukG monomer + LukH monomer + Fab monomer (7154 heavy atoms) in 20 mM Hepes, 300 mM NaCl, 1 mM MgCl2, pH 7.5, 10 C | Proc Natl Acad Sci U S A 2019, DOI 10.1073/pnas.1913690116 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.12 nm from SASBDB); CRYSOL fit1; EMBL P12; depositor: header Chi^2 1.857 | CRYSOL 1.857 |
| SASDF75 | Ric8a monomer (3562 heavy atoms) in 20 mM Tris, 150 mM KCl, 5 % glycerol, 1 mM TCEP, pH 8, 25 C | Nat Commun 2019, DOI 10.1038/s41467-019-11088-x (SASBDB metadata, paper not consulted; temperature 25 C and wavelength 0.1033 nm from SASBDB); CRYSOL fit1; BioCAT 18ID; depositor: header Chi^2 1.815 | CRYSOL 1.815 |
| SASDF93 | unnamed protein tetramer (9395 heavy atoms) in 50 mM Tris-HCl 50 mM NaCl, pH 7.4, 20 C | Journal of Structural Biology 2019, DOI 10.1016/j.jsb.2019.07.006 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.125 nm from SASBDB); CRYSOL fit1; BM29; large (9395 heavy atoms); depositor: header Chi^2 1.678 | CRYSOL 1.678 |
| SASDFD5 | TetR(D) dimer (3082 heavy atoms) in 50 mM Tris/HCl 150 mM NaCl 10 mM MgCl2, pH 8, 10 C | Biochim Biophys Acta Proteins Proteom 2020, DOI 10.1016/j.bbapap.2020.140404 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.124 nm from SASBDB); CRYSOL fit1; EMBL P12; depositor: header Chi^2 1.545 | CRYSOL 1.545 |
| SASDFP8 | CA2 monomer (2113 heavy atoms) in 50 mM HEPES, 150 mM NaCl, 2% v/v glycerol, pH 7, 20 C | Crystals 2020, DOI 10.3390/cryst10110975 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.123982 nm from SASBDB); FoXS fit2; EMBL P12; depositor: header Chi^2 1.095 | FoXS 1.095 |
| SASDFQ6 | unnamed protein dimer (1282 heavy atoms) in 10 mM Bis-Tris, 100 mM NaCl, pH 7.5, 10 C | Nat Commun 2020, DOI 10.1038/s41467-020-16724-5 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.103 nm from SASBDB); FoXS fit1; 12.3.1 (SIBYLS); depositor: header Chi^2 4.034; SASBDB 4.034 | FoXS 4.034 |
| SASDFQ8 | BSA monomer (4666 heavy atoms) in 50 mM HEPES, 150 mM NaCl, 2% v/v glycerol, pH 7, 20 C | Crystals 2020, DOI 10.3390/cryst10110975 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.123982 nm from SASBDB); CRYSOL fit2; EMBL P12; depositor: header Chi^2 1.332 | CRYSOL 1.332 |
| SASDFZ3 | YjhC dimer (5729 heavy atoms) in 20 mM Tris, 150 mM NaCl, 0.1 % (w/v) sodium azide, 5 % (v/v) glycerol, pH 8, 12 C | Proteins 2019, DOI 10.1002/prot.25846 (SASBDB metadata, paper not consulted; temperature 12 C and wavelength 0.10332 nm from SASBDB); CRYSOL fit1; SAXS/WAXS; depositor: header Chi^2 0.623 | CRYSOL 0.623 |
| SASDG44 | HAd3K adenovirus 3 fibre knob trimer, four chains (6376 heavy atoms) in 20 mM Tris-HCl, 150 mM NaCl, 3 mM CaCl2, pH 8, 20 C | Acta Cryst F 2019, DOI 10.1107/S2053230X19015784 (paper not open access, SASBDB buffer; the cell temperature 293.0 is kelvin = 20 C, owner); CRYSOL fit1; BM29; recomputed 0.794 | CRYSOL 0.795 |
| SASDG97 | tbMORNdelta1 dimer (5262 heavy atoms) in 20 mM Tris-HCl,  100 mM NaCl, pH 7.5, 20 C | PLoS One 2020, DOI 10.1371/journal.pone.0242677 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.099 nm from SASBDB); CRYSOL fit2; BM29; depositor: header Chi^2 2.201 | CRYSOL 2.201 |
| SASDGD6 | CuGE monomer (2882 heavy atoms) in 20 mM sodium acetate, pH 5, 21 C | Nat Commun 2020, DOI 10.1038/s41467-020-14833-9 (SASBDB metadata, paper not consulted; temperature 21 C and wavelength 0.154 nm from SASBDB); CRYSOL fit1; Xenocs BioXolver L with GeniX3D; depositor: header Chi^2 1.054 | CRYSOL 1.054 |
| SASDGG2 | IL11RA monomer (2294 heavy atoms) in 20 mM Tris, 150 mM NaCl, 0.2% sodium azide, pH 8.5, 20 C | Journal of Biological Chemistry 2020, DOI 10.1074/jbc.RA119.012351 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.1078 nm from SASBDB); CRYSOL fit1; SAXS/WAXS; depositor: header Chi^2 1.032 | CRYSOL 1.032 |
| SASDGH2 | IL11 monomer (1325 heavy atoms) in 20 mM Tris, 150 mM NaCl, 0.2% sodium azide, pH 8.5, 20 C | Journal of Biological Chemistry 2020, DOI 10.1074/jbc.RA119.012351 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.1078 nm from SASBDB); CRYSOL fit1; SAXS/WAXS; depositor: header Chi^2 1.428 | CRYSOL 1.428 |
| SASDGK2 | IL11RA monomer + IL11 monomer (3469 heavy atoms) in 20 mM Tris, 150 mM NaCl, 0.2% sodium azide, pH 8.5, 20 C | Journal of Biological Chemistry 2020, DOI 10.1074/jbc.RA119.012351 (SASBDB metadata, paper not consulted; temperature 20 C and wavelength 0.1078 nm from SASBDB); CRYSOL fit1; SAXS/WAXS; depositor: header Chi^2 1.074 | CRYSOL 1.074 |
| SASDGL2 | PaaZ hexamer (30564 heavy atoms) in 25 mM HEPES, 50 mM NaCl, pH 7.4, 10 C | Nat Commun 2019, DOI 10.1038/s41467-019-11931-1 (SASBDB metadata, paper not consulted; temperature 10 C and wavelength 0.103 nm from SASBDB); CRYSOL fit1; 12.3.1 (SIBYLS); VERY LARGE (30564 heavy atoms, long run); depositor: header Chi^2 3.382 | CRYSOL 3.382 |
| SASDH23 | Alpha domain of Ag43a (Escherichia coli) | 3477 heavy atoms; buffer from SASBDB | CRYSOL 0.743044 |
| SASDH64 | Myosin essential light chain (Plasmodium falciparum) | 588 heavy atoms; buffer from SASBDB | CRYSOL 1.371 |
| SASDH94 | Myosin essential light chain 2 (Toxoplasma gondii) | 1264 heavy atoms; buffer from SASBDB | CRYSOL 1.158 |
| SASDHM8 | Aquifex aeolicus McoA metaloxidase ∆328-352 evolved variant  (Aquifex aeolicus) | 5927 heavy atoms; buffer from SASBDB | CRYSOL 1.003 |
| SASDHP7 | Haloalkane dehalogenase variant DhaA115 -monomeric fraction (Rhodococcus rhodochrous) | 2453 heavy atoms; buffer from SASBDB | CRYSOL 1.145 |
| SASDJ75 `fit1_model1` | Piwi protein `AF_1318` (Archaeoglobus fulgidus) | 6964 heavy atoms; q cut 0.2; 2 runs (fit1, fit2); buffer from SASBDB | CRYSOL 1.699 |
| SASDJ75 `fit2_model1` | Piwi protein `AF_1318` (Archaeoglobus fulgidus) | 6964 heavy atoms; q cut 0.2; 2 runs (fit1, fit2); buffer from SASBDB | CRYSOL 1.252 |
| SASDJ92 | Extracellular matrix binding protein F-repeats (Staphylococcus epidermidis) | 4406 heavy atoms; buffer from SASBDB | CRYSOL 2.236 |
| SASDJB6 | gp11 encapsidation protein (Lactococcus phage Phi28) | 31240 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 0.993 |
| SASDJC5 | SUN domain-containing protein 1 (Homo sapiens) | 10562 heavy atoms; VERY LARGE; q cut 0.3; buffer from SASBDB | CRYSOL 1.619 |
| SASDJJ4 | Collagen alpha-3(VI) chain, N2 domain (Homo sapiens) | 1558 heavy atoms; buffer from SASBDB | CRYSOL 1.039 |
| SASDJL6 | Rod domain of α-actinin-2 (Homo sapiens) | 7860 heavy atoms; buffer from SASBDB | CRYSOL 1.021 |
| SASDJP5 | Tetanus toxin (Clostridium tetani) | 2447 heavy atoms; buffer from SASBDB | CRYSOL 1.297 |
| SASDJQ7 | Cathepsin Z (Homo sapiens) | 3816 heavy atoms; buffer from SASBDB | CRYSOL 1.13 |
| SASDJW5 | Plasminogen activator inhibitor 1 (Homo sapiens) | 4098 heavy atoms; q cut 0.5; buffer from SASBDB | CRYSOL 1.392 |
| SASDJX7 | Similar to Aedes aegypti 34 kDa salivary secreted protein 34 (Aedes albopictus) | 2424 heavy atoms; buffer from SASBDB | CRYSOL 1.666 |
| SASDK74 | Transcriptional repressor BusR `RCK_C` domain (Streptococcus agalactiae serotype III (strain NEM316)) | 1588 heavy atoms; buffer from SASBDB | CRYSOL 3.364 |
| SASDKS7 | HpcH/HpaI aldolase (Rhizorhabdus wittichii RW1) | 11304 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 1.127 |
| SASDKT6 | Replicase polyprotein 1ab (non-structural protein 14) (Severe acute respiratory syndrome coronavirus 2) | 4111 heavy atoms; T 25 C default; buffer from SASBDB | CRYSOL 1.234 |
| SASDKT9 | p450 cytochrome, putative (Moco carrier protein) (Rippkaea orientalis (strain PCC 8801)) | 4835 heavy atoms; buffer from SASBDB | CRYSOL 0.91 |
| SASDKY7 | Alpha-L-fucosidase (Paenibacillus thiaminolyticus (Bacillus thiaminolyticus)) | 22520 heavy atoms; VERY LARGE; q cut 0.2; buffer from SASBDB | CRYSOL 1.032 |
| SASDLM3 | Interleukin-6 receptor subunit beta (Homo sapiens) | 12014 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 3.065 |
| SASDLQ2 | L-lactate dehydrogenase (Plasmodium falciparum) | 9848 heavy atoms; VERY LARGE; T 25 C default; buffer from SASBDB | CRYSOL 0.867 |
| SASDLQ3 | Interleukin-11 (W168A) (Homo sapiens) | 1423 heavy atoms; buffer from SASBDB | CRYSOL 0.918 |
| SASDLY8 | Recombinant Mycobacterium tuberculosis H37Rv (Mycobacterium tuberculosis H37Rv) | 4564 heavy atoms; buffer from SASBDB | CRYSOL 0.936 |
| SASDM82 | Ubiquitin fold modifer 1 (Homo sapiens) | 658 heavy atoms; buffer from SASBDB | CRYSOL 1.011 |
| SASDMA9 | Diacetylchitobiose deacetylase (Thermococcus chitonophagus) | 13322 heavy atoms; VERY LARGE; buffer from SASBDB | CRYSOL 1.198 |
| SASDMC9 | Glycogen synthase kinase 3 (Plasmodium falciparum (isolate 3D7)) | 3628 heavy atoms; buffer from SASBDB | CRYSOL 1.237 |
| SASDMG8 | Non-POU domain-containing octamer-binding protein (Homo sapiens) | 4449 heavy atoms; buffer from SASBDB | CRYSOL 1.651 |
| SASDMK9 | Replicase polyprotein 1a (Severe acute respiratory syndrome-related coronavirus) | 2754 heavy atoms; T 25 C default; buffer from SASBDB | CRYSOL 1.73186 |
| SASDMS4 | Internalin B (Listeria monocytogenes serotype 1/2a (strain EGD / Mackaness)) | 2257 heavy atoms; T 25 C default; buffer from SASBDB | CRYSOL 2.969 |

### Slice (43 entries: slice E, proteins; sources in `new-entries-*.md`)

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDPW7 | FAD-dependent monooxygenase from Stenotrophomonas maltophilia, Stenotrophomonas maltophilia, 38.941 kDa monomer; 2665 heavy atoms; "25 mM Bis-Tris, 150 mM NaCl, 30 mM DTT", pH 6.5. | Ligand HETATM groups scattered with the protein; the model is a preliminary model of PDB 8AQ8 chain C with FAD; sibling of the wired SASDPV7; buffer from SASBDB only (paper not read); Bis-Tris constants are `verified: false` in `buffer_templates.json`. | CRYSOL 0.894 |
| SASDQ28 | USP14, Homo sapiens, 46.243 kDa monomer; 3235 heavy atoms; "20 mM HEPES, 150 mM NaCl, 2 mM TCEP", pH 7.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.056 |
| SASDQ59 | DpdA(D95A), Salmonella enterica subsp. enterica serovar Montevideo, 50.396 kDa monomer; 3540 heavy atoms; "100 mM KCl, 50 mM Tris pH 7.0, 1 mM DTT", pH 7.0. | Buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDQ98 | DPCD, Homo sapiens, 23.239 kDa monomer; 1634 heavy atoms; "25 mM Tris-HCl, 200 mM NaCl", pH 7.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 0.932 |
| SASDQS6 | GRP78-NBD + C-CDNF monomer (3420 heavy atoms) in PBS + 1.5 % glycerol, pH 7.2, 20 C | Nat Commun 2024, DOI 10.1038/s41467-024-52478-0 (paper: PBS + 1.5 % glycerol, pH 7.2; SASBDB says plain PBS; standard PBS recipe and glycerol v/v assumed); CRYSOL fit1; the deposited hydrogens are replaced by pdb2pqr | CRYSOL 1.119 |
| SASDRH8 | AstaPo1, Coelastrella astaxanthina, 21.606 kDa monomer; 1566 heavy atoms; "20 mM Tris- HCl, 150 mM NaCl", pH 7.6. | Buffer from SASBDB only (paper not read). | CRYSOL 1.181 |
| SASDRQ8 | BSA, Bos taurus, 66.432 kDa monomer; 4672 heavy atoms; "10 mM HEPES, 5 mM NaCl, 0.1 mM EDTA", pH 7.4. | Alternate locations in the model; buffer from SASBDB only (paper not read). | CRYSOL 1.095 |
| SASDRZ6 | THSD7A, Homo sapiens, 16.656 kDa monomer; 1164 heavy atoms; "25mM Tris, 150 mM NaCl, 5 mM NaNO3", pH 7.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.088 |
| SASDSE7 | CDIN1, Homo sapiens, 33.381 kDa dimer; 4548 heavy atoms; "20 mM Tris HCl, 150 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 2.045 |
| SASDSF7 | Codanin1, Homo sapiens, 24.961 kDa monomer; 1743 heavy atoms; "20 mM Tris HCl, 150 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.229 |
| SASDSN8 | Pro-Nivolumab, Lu02, None, 54.366 kDa monomer; 3822 heavy atoms; "20 mM Tris, 100 mM NaCl", pH 8.0. | Buffer from SASBDB only (paper not read). | CRYSOL 1.876 |
| SASDSQ9 | NanoLuc, Oplophorus gracilirostris, 20.365 kDa monomer; 1484 heavy atoms; "10 mM Tris-HCl, 50 mM NaCl", pH 7.5. | Alternate locations in the model; ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read). | CRYSOL 1.216 |
| SASDSU8 | Tha1, Mus musculus, 41.366 kDa tetramer; 11130 heavy atoms; "20 mM Tris, 150 mM NaCl, 1 mM EDTA, 1 mM DTT", pH 7.8. | Large structure (11130 heavy atoms); ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read). | CRYSOL 1.145 |
| SASDTC5 | Full-length E3 ubiquitin-protein ligase HACE1, Homo sapiens, 102.399 kDa dimer; 14374 heavy atoms; "50 mM HEPES, 50 mM NaCl, 5 mM DTT", pH 8.0. | Large structure (14374 heavy atoms); buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDTR2 | TuAsV 2A3, Turkey avisivirus, 13.349 kDa monomer; 936 heavy atoms; "20 mM citrate pH 5.4, 150 mM NaCl, 2 mM TCEP, 1% glycerol", pH 5.4. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature; glycerol percentage unit not stated, v/v assumed; citrate titrant not stated, Na-only charge balance assumed. | CRYSOL 2.133 |
| SASDTT2 | TuAsV 2A3, Turkey avisivirus, 13.349 kDa monomer; 936 heavy atoms; "20 mM HEPES, 150 mM NaCl, 2 mM TECP, 1% Glycerol", pH 7.4. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature; glycerol percentage unit not stated, v/v assumed. | CRYSOL 1.207 |
| SASDTT4 | SLDCP, Sphaerobacter thermophilus (strain DSM 20745 / S 6022), 12.105 kDa monomer; 840 heavy atoms; "20 mM Tris, 150 mM NaCl, 3% glycerol", pH 7.6. | Ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); glycerol percentage unit not stated, v/v assumed. | CRYSOL 1.409 |
| SASDTV4 | Fe8×FerSUMO, Helicobacter pylori (strain J99 / ATCC 700824), 31.469 kDa octamer; 17736 heavy atoms; "25 mM Tris, 150 mM NaCl", pH 7.4. | Large structure (17736 heavy atoms); AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.066 |
| SASDU78 | VFT2, Trypanosoma brucei, 42.755 kDa monomer; 2927 heavy atoms; "50 mM Tris-HCl, 500 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.351 |
| SASDU89 | ApoA-I, Homo sapiens, 21.567 kDa monomer; 1471 heavy atoms; "20 mM Tris, 150 mM NaCl, 0.1% sodium azide", pH 7.4. | Buffer from SASBDB only (paper not read). | CRYSOL 1.157 |
| SASDU98 | MBP, Escherichia coli (strain K12), 40.248 kDa dimer; 11730 heavy atoms; "50 mM Tris pH 7.5, 150 mM NaCl", pH 7.5. | Large structure (11730 heavy atoms); the SASBDB pH field is empty; the pH is the one in the buffer name; AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.399 |
| SASDUU3 | AOC3, Homo sapiens, 81.784 kDa dimer; 11885 heavy atoms; "137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8 mM KH2PO4", pH 7.4. | Large structure (11885 heavy atoms); ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature. | CRYSOL 1.112 |
| SASDUV3 | LrpA, Ligilactobacillus ruminis ATCC 25644, 48.969 kDa monomer; 3317 heavy atoms; "20 mM Tris, 150 mM NaCl", pH 8.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.435 |
| SASDUW6 | HpARI2, Heligmosomoides polygyrus, 25.998 kDa monomer; 1792 heavy atoms; "137 mM NaCl, 2.7 mM KCl, 10 mM phosphate buffer, 5% glycerol", pH 7.2. | Buffer from SASBDB only (paper not read); glycerol percentage unit not stated, v/v assumed. | CRYSOL 1.065 |
| SASDV46 | tau4RD domain, Homo sapiens, 13.7 kDa monomer; 1971 heavy atoms; "100 mM NaCl", pH 6.8. | Buffer from SASBDB only (paper not read); no buffering species: 100 mM NaCl only, the pH is the stated value. | CRYSOL 1.742 |
| SASDVE7 | SaIlvA, Staphylococcus aureus (strain USA300), 48.002 kDa hexamer; 19818 heavy atoms; "20 mM KPO4, 200 mM NaCl, 0.1 mM TCEP,", pH 7.5. | Large structure (19818 heavy atoms); buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDVG6 | NnhA, Mycobacterium sp. (strain JS330), 43.08 kDa hexamer; 19390 heavy atoms; "25 mM Tris-HCl, 150 mM NaCl, 5% (v/v) glycerol", pH 7.6. | Large structure (19390 heavy atoms); alternate locations in the model; ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature; glycerol percentage unit not stated, v/v assumed. | CRYSOL 2.404 |
| SASDVL8 | McGlcH, Mucor circinelloides, 44.696 kDa monomer; 3019 heavy atoms; "50 mM Tris, 150 mM NaCl", pH 7.1. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.523 |
| SASDVQ6 | VPS35L, Homo sapiens, 109.618 kDa monomer; 11455 heavy atoms; "50 mM Tris, 200 mM NaCl, 1 mM TCEP", pH 7.5. | Large structure (11455 heavy atoms); AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.502 |
| SASDVQ8 | PcGlc, Penicillium rubens (strain ATCC 28089 / DSM 1075 / NRRL 1951 / Wisconsin 54-1255), 42.461 kDa monomer; 2820 heavy atoms; "50 mM sodium citrate, 150 mM NaCl", pH 4.5. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); citrate titrant not stated, Na-only charge balance assumed. | CRYSOL 1.094 |
| SASDVQ9 | Full-length mature human mitochondrial ATP synthase subunit O, Homo sapiens, 20.875 kDa dimer; 2928 heavy atoms; "50 mM Na2HPO4, 300 mM NaCl", pH 7.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read); phosphate titrant not stated, HCl assumed. | CRYSOL 1.232 |
| SASDVS8 | AnRut glucosidase/rutinosidase monomer, deglycosylated (3359 heavy atoms) in McIlvaine (Na2HPO4/citric acid) buffer, pH 3.5, 20 C | no publication, SASBDB name and pH only; McIlvaine composition computed from the pH with the repo buffer model (58.4 mM phosphate, 70.8 mM citrate, 116.8 mM Na+; stock concentrations assumed); CRYSOL fit1 | CRYSOL 1.371 |
| SASDVT5 | MpARF3, Marchantia polymorpha, 45.502 kDa monomer; 3133 heavy atoms; "20 mM Tris-HCl, 150 mM NaCl, 1 mM DTT", pH 8.0. | Buffer from SASBDB only (paper not read). | CRYSOL 0.747 |
| SASDVT8 | AnRut glucosidase/rutinosidase dimer, glycosylated (6698 heavy atoms) in McIlvaine (Na2HPO4/citric acid) buffer, pH 3.5 | no publication, SASBDB name and pH only; McIlvaine composition computed from the pH with the repo buffer model (58.4 mM phosphate, 70.8 mM citrate, 116.8 mM Na+; stock concentrations assumed); CRYSOL fit1, recomputed 1.900; the depositor fit covers q to 0.15 1/A of the data's 0.40 (not like for like) | CRYSOL 1.884 |
| SASDVW3 | NlpI dimer + two MepS dimers, six chains (8870 heavy atoms) in 0.2 M Na/K phosphate, 2 mM 2-mercaptoethanol, pH 7.0, 10 C | Nat Commun 2024 (buffer the same in paper and SASBDB; the Na/K ratio is not stated, all Na assumed); CRYSOL fit1; 18 altloc records | CRYSOL 1.725 |
| SASDW94 | horse apoferritin 24-mer from AF4-SAXS (33552 heavy atoms) in PBS, pH 7.2, 20 C | J Synchrotron Rad 2025, DOI 10.1107/S1600577525003959 (the paper says only "PBS": standard PBS recipe assumed); CRYSOL fit1; VERY LARGE; model mass far from the sample mass; 144 altloc records | CRYSOL 1.054 |
| SASDWA4 | yeast alcohol dehydrogenase 1 tetramer from AF4-SAXS (10327 heavy atoms) in PBS + 1 % glycerol, pH 7.2 | paper and SASBDB give only "PBS, 1 % glycerol": standard PBS recipe (137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8 mM KH2PO4), glycerol v/v assumed; CRYSOL fit1, recomputed 1.382; large | CRYSOL 1.383 |
| SASDWB4 | sweet potato beta-amylase tetramer from AF4-SAXS (16288 heavy atoms) in PBS + 1 % glycerol, pH 7.2, 20 C | J Synchrotron Rad 2025, DOI 10.1107/S1600577525003959 (the paper says only "PBS", glycerol v/v assumed; standard PBS recipe); CRYSOL fit1; large; DTT and DOM ligand groups kept | CRYSOL 1.452 |
| SASDWM2 | PRT1, Arabidopsis thaliana, 45.936 kDa monomer; 3206 heavy atoms; "50 mM Tris-HCl, 150 mM NaCl, 1 mM TCEP, 2% w/v glycerol", pH 7.5. | AlphaFold prediction (no experimental structure); ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature. | CRYSOL 1.734 |
| SASDWN5 | DS6A, Mycobacterium phage DS6A, 43.458 kDa monomer; 3046 heavy atoms; "20 mM Tris, 150 mM NaCl and 1 mM DTT", pH 8.0. | Buffer from SASBDB only (paper not read). | — (no reference curve) |
| SASDWP9 | MDtxRGA G149, synthetic construct, 84.189 kDa monomer; 5926 heavy atoms; "20 mM MOPS, 250 mM KCl,", pH 7.0. | AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper not read). | CRYSOL 1.084 |
| SASDWW6 | Apoferritin dimer, Equus caballus, 19.846 kDa other; 66288 heavy atoms; "137 mM NaCl, 2.7 mM KCl, 10 mM phosphate buffer, 0.9 mM CaCl2, 0.5 mM MgCl2", pH 7.4. | VERY LARGE structure (66288 heavy atoms): expect a long run time; alternate locations in the model; buffer from SASBDB only (paper not read). | CRYSOL 1.22 |

### Slice (19 entries: slice F, nucleic acids; sources in `new-entries-*.md`)

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDAH5 | Hfq hexamer + DsrA RNA complex (4193 heavy atoms) in 50 mM bicine, 100 mM NaCl, 250 mM KCl, pH 8.8, 35 C | NAR 2012, DOI 10.1093/nar/gks510 (paper and SASBDB disagree: the paper's bicine buffer is followed, SASBDB says Tris/DTT pH 7.5); the .fit (software not stated; header ChiExp 1.50 = sqrt 2.25) is the reference; the depositor fit covers q to 0.30 1/A of the data's 0.60 (not like for like); EMBL X33 | depositor 2.25 |
| SASDAP8 | kLBS1-2 viral terminal-repeat DNA, 38 bp (2522 heavy atoms) in 11.1 mM Tris pH 7.6, 55.5 mM NaCl, 5.5 mM MgCl2, 20 C | NAR 2015, DOI 10.1093/nar/gkv987 (the paper has no SAXS buffer: its annealing buffer is used; 20 C and 0.9 A from its Table 3, SASBDB says only "Tris", no T, 0.93 A); cleaned model (GUA/CYT/THY/ADE -> DG/DC/DT/DA, original kept); CRYSOL fit1 (not recomputed: no sigma column); BM29 | CRYSOL 2.879 |
| SASDM36 | c-Myc12 promoter G-quadruplex (DNA) | BPEK K-phosphate pH 7.2/185 mM KCl/1 mM EDTA, SASBDB cell 25 °C (flagged); cleaned model (DG5/DG3 -> DG, K+ style); recomputed 3.494 | CRYSOL 3.407 |
| SASDMD6 | 2LBY G-quadruplex, 19 nt (DNA) | as M36, 22 °C; recomputed 1.930 | CRYSOL 2.049 |
| SASDMF6 | 1XAV G-quadruplex, 22 nt (DNA) | as MD6; recomputed 1.521 | CRYSOL 1.503 |
| SASDMH6 | 2M27 G-quadruplex, 22 nt (DNA) | as MD6; recomputed 1.609 | CRYSOL 1.662 |
| SASDML6 | kRas-8 promoter G-quadruplex (DNA) | as M36 (22 °C); recomputed 9.005 | CRYSOL 8.758 |
| SASDMN6 | cKit-12 promoter G-quadruplex (DNA) | as M36 (22 °C); recomputed 4.126 | CRYSOL 4.065 |
| SASDPD3 | ESS2p HIV-1 splice-site regulatory RNA | 20 mM Bis-Tris pH 6.2/20 mM NaCl; T and wavelength unstated (25 °C, 1.033 Å flagged); cleaned model (G5/C3 -> G/C); depositor fit covers 693 of 1257 points (from q = 0.0146 Å⁻¹) | SASBDB fit 1.458 |
| SASDPG2 | NOX-E36 Spiegelmer (L-RNA, modelled as D-RNA) | 20 mM HEPES pH 7.52, SASBDB cell 5.8 °C (flagged), no salt listed; q in nm⁻¹; depositor χ² matches the .fit's own error column (1.20 against the .dat errors) | CRYSOL 1.007 |
| SASDPJ2 | NOX-A12 Spiegelmer variant 1 (L-RNA as D-RNA) | as PG2 (0.984 against the .dat errors) | CRYSOL 0.968 |
| SASDPK2 | NOX-A12 Spiegelmer variant 2 (L-RNA as D-RNA) | as PG2; depositor χ² NOT reproducible from the .dat (32.1 against the .dat errors) | CRYSOL 1.278 |
| SASDSP8 | apo-D43 RNA device (PD-1) | 10 mM Bis-Tris pH 6.8/100 mM KCl/1 mM MgCl₂, 20 °C, 0.8202 Å (SASBDB only); cryo-EM model with missing residues, hence the large depositor χ² | CRYSOL 69.336 |
| SASDSQ8 | holo-D43 RNA device (PD-1) with the ligand TAC (tetracycline) | as SP8 (owner's SI: 10 mM Bis-Tris pH 6.8/100 mM KCl/1 mM MgCl₂, 20 °C, 0.8202 Å); TAC (53 HETATM atoms) in the model only, not in the buffer; cryo-EM model with missing residues, large depositor χ² | CRYSOL 63.691 |
| SASDT65 | influenza B NS1-CTD with double-stranded RNA (2426 heavy atoms) in 40 mM NH4OAc pH 5.5, 450 mM NaCl, 5 mM CaCl2, 0.02 % NaN3, 50 mM arginine, 4 C | bioRxiv 2023.09.25.559316 (preprint not retrievable, SASBDB buffer); NaN3 read as w/v, arginine as a neutral row; FoXS fit1 (SASBDB 2.742) kept in the fixture but wired without reference curve and without refChi2 | none (see the Notes) |
| SASDUS8 | DIS-C RNA | 50 mM K-phosphate pH 7.5/Mg²⁺/NaCl, 20 °C (SASBDB only); FoXS column 3; model is RNAMasonry/AlphaFold3 and SAXS-restrained, so the fit is not independent; heavy-atom model | FoXS 1.225 |
| SASDUT8 | DIS-Gk RNA | as US8 | FoXS 1.134 |
| SASDUU8 | DIS-C/DIS-Gk RNA:RNA complex | as US8 | FoXS 1.106 |
| SASDXD9 | mascRNA (RNA) | HEPES-NaOH/NaCl/10 mM MgCl₂, "150 NaCl" unit assumed mM, 25 °C (SASBDB only); q = 0 nan row dropped by `fitSubset` | CRYSOL 1.252 |

### Slice (16 entries: slice F, proteins; sources in `new-entries-*.md`)

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDX89 | Arabidopsis AMY3 catalytic domain, AlphaFold | 100 mM K-phosphate pH 7.4, 10 °C; the model is mmCIF (fixture is `.cif`) | FoXS 0.616 |
| SASDXA7 | hCS-MDH2 metabolon, 6 chains | Tris/NaCl/EDTA pH 7.5; T and wavelength unstated (25 °C, 1.127 Å flagged); 16107 heavy atoms (+16439 H in the file) | FoXS 0.847 |
| SASDXC4 | Pex8 + Pex5-CTD complex (SASREF model 2; 10103 heavy atoms) in 50 mM HEPES, 150 mM NaCl, 3 % v/v glycerol, pH 7.5 | bioRxiv 2025.08.30.673231 (preprint not retrievable, SASBDB buffer); model 1 of fit 1 is empty, model 2 used; CRYSOL fit1 (SASBDB 1.093) kept in the fixture but wired without reference curve and without refChi2; q cut 0.679 1/A by the README rule | none (see the Notes) |
| SASDXC7 | E. histolytica ASF1 complex, AlphaFold, 3 chains | 20 mM Tris pH 7.5/150 mM NaCl/2 mM BME, 20 °C; q in nm⁻¹; wavelength "0.9794" read as Å (flagged) | FoXS 0.976 |
| SASDXF3 | h-OGA dimer, AlphaFold model (protein) | Tris/NaCl/TCEP, SASBDB only, wavelength "1.34" read as Å (flagged); the .fit does not reproduce its header (5.3 against 0.828), so no reference curve | none (header 0.8276) |
| SASDXF8 | LILRB3 + beta antigen C protein, FoXSDock | 20 mM HEPES pH 7.4/140 mM NaCl; T and wavelength unstated (flagged as XA7); 11257 heavy atoms | FoXS 1.268 |
| SASDXH2 | eEF1A2 monomer (3547 heavy atoms) in 25 mM Tris-HCl, 150 mM NaCl, 6 mM 2-mercaptoethanol, 20 % glycerol, 0.01 mM GDP, pH 7.5, 20 C | Nucleic Acids Res 2025 (the SAXS section has no buffer: SASBDB buffer; glycerol read as w/v, flagged; GDP as gdp(2-)); CRYSOL fit1, recomputed 1.635 | CRYSOL 1.651 |
| SASDXH4 | IgE + profilin (protein complex), SREFLEX | 20 mM Tris pH 8.4/50 mM NaCl, 20 °C; q in nm⁻¹; 12882 heavy atoms | SREFLEX 1.073 |
| SASDXJ2 | eEF1A1 dimer (7044 heavy atoms) in 25 mM Tris-HCl, 150 mM NaCl, 6 mM 2-mercaptoethanol, 20 % glycerol, 0.01 mM GDP, pH 7.5, 20 C | Nucleic Acids Res 2025 (as SASDXH2: SASBDB buffer, glycerol w/v flagged, GDP as gdp(2-)); CRYSOL fit1, recomputed 2.777; hydrogens of the deposited model replaced by pdb2pqr | CRYSOL 2.804 |
| SASDXK4 | IgE (protein), Chimera model | as XH4; the DAMMIF fit 1 unused; 10971 heavy atoms | CRYSOL 1.673 |
| SASDXX4 | Serratia marcescens PgaB monomer (5184 heavy atoms) in PBS, pH 7.4, 20 C | no publication in SASBDB (thesis); standard PBS recipe (137 / 2.7 / 10 / 1.8 mM); AlphaFold model; CRYSOL fit1, recomputed 4.906; the depositor fit covers q to 0.43 1/A of the data's 0.50 (not like for like) | CRYSOL 4.912 |
| SASDXY4 | Serratia marcescens truncated PgaB monomer (4889 heavy atoms) in PBS, pH 7.4, 20 C | as SASDXX4; CRYSOL fit1, recomputed 4.267 | CRYSOL 4.273 |
| SASDYV6 | pyruvate kinase monomer, AlphaFold | 20 mM Tris-HCl pH 8.0/300 mM NaCl, 15 °C; monomer model of a protein whose oligomeric state is the paper subject | CRYSOL 2.101 |
| SASDZ78 | vaccinia K4 endonuclease octamer | 20 mM Tris pH 7.5/150 mM NaCl/0.5 mM TCEP, 20 °C; 27005 heavy atoms; the depositor χ² is tiny because the deposited errors exceed the intensities | CRYSOL 0.026 |
| SASDZD6 | transducin-bound PDE6 (7JSN), six chains plus GTP/35G/VDN/Zn/Mg | 25 mM Tris pH 8.0/100 mM NaCl/2 mM MgCl₂/2 % glycerol (v/v assumed), 4 °C; 19438 heavy atoms; FoXS column 3; no publication listed | FoXS 5.271 |
| SASDZW5 | OaaC condensation domain dimer from Coprococcus eutactus (7582 heavy atoms) in 10 mM HEPES, 50 mM NaCl, 0.2 mM TCEP, pH 7.5, 11 C | bioRxiv 2026.04.24.720670 (preprint not retrievable, SASBDB buffer); q is in 1/A (Guinier Rg 32.6 A against 30.9 A of the model) and the curve runs to 2.099 1/A, so the whole curve is fitted with the `Q_SANITY_RANGE` of common.jl widened to the form-factor table limit; DENSS fit (SASBDB 1.215), so no reference curve and no refChi2 | none (see the Notes) |

### Synthetic entries (`test/synthetic_tests/SYN-*`)

34 synthetic entries (no measured curve, no fit) pair a small PDB host (1CRN, 1UBQ, 6LYZ protein; 1BNA DNA; 1EHZ RNA) with an invented, flagged buffer (salts, sugars, denaturants, polymers, proteins/DNA/RNA as solutes). Each script writes `<ID>.profile.tsv` (q = 0.01 to 0.5 Å⁻¹) and `<ID>.solvent.txt` (solvent electron density, σ, composition) for the Pepsi-SAXS / CRYSOL / FoXS benchmark; fixtures are in `test/fixtures/synthetic/<ID>/`. They have no `refChi2`, no `results` call and no LOG, so they never enter the Results table; `bysl fits run SYN-<ID>` runs one (and `bysl fits list` names them), but `--bench`, `--report`, `--table` and `--fixme` only apply to the fitting tests.

## Entries

### SASDA52: yeast alcohol dehydrogenase 1 (ADH1), PBS

```
julia --project=test/fitting_tests test/fitting_tests/SASDA52/SASDA52_fit1.jl
```

Fits the ADH1 tetramer (PDB 4W6Z, 347-residue chains; 24.89 mg/mL) with q ≤ 0.5 Å⁻¹ and lMax 56 (scatterer-cloud diameter 110.7 Å; the GNOM `D_max` is 89.3 Å), pH 7.4. **Unique:** the SASBDB entry only says "PBS", so the standard 1× PBS recipe (137 mM NaCl, 2.7 mM KCl, 10 mM Na₂HPO₄, 1.8 mM KH₂PO₄, each ±5 %) is assumed; the beamline wavelength "0.15" is read as a unit slip for 1.5 Å (8.27 keV); the experimental file is in nm⁻¹ and is converted. Overlays our MAP curve on SASBDB's CRYSOL fit1 (`res_fit1_comparison.tex`).

### SASDF42: human serum albumin + somapacitan complex, MES/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDF42/SASDF42.jl
```

Fits a SASREF rigid-body model of HSA with two growth-hormone (somapacitan) copies, 6.3 mg/mL total, pH 6.5, 100 mM MES + 140 mM NaCl, q ≤ 0.5 Å⁻¹, lMax 73. **Unique:** a three-chain complex of two different proteins (the proteins are not buffer solutes, see above). Compared against the deposited fit column of the SASBDB `.fit` file, whose header quotes `ChiExp = 1.45`; recomputed from the file's own columns that is χ, i.e. χ² = 2.10.

### SASDMJ9: feline coronavirus Nsp7 (validation case)

```
julia --project=test/fitting_tests test/fitting_tests/SASDMJ9/SASDMJ9.jl
```

Fits Nsp7 (chain B, 82 residues, 4.7 mg/mL) in 200 mM NaCl, 10 mM Tris, 5 mM DTT, pH 7.5, q ≤ 0.5 Å⁻¹, lMax 32. **Unique:** the reference case for the method and the script the other fits were modeled on. Under the current bounded-Beta δρ priors and profiled c1 the MAP χ² is 0.87 (16–84 % band 0.867–0.871), against CRYSOL's 1.37 recomputed on the same points (1.370; 1.365 with a free scale and offset). It was 1.13 before the MAP search and the 1e-8 c1 tolerance, and 1.08 under the earlier LogNormal/Normal priors with a sampled c1. δρ₂ sits at its upper bound of 2 (1.96). One shared shell contrast already gives 1.07, so most of the gain over CRYSOL is not the extra contrasts. q is converted from nm⁻¹ and the X33 wavelength is 1.54 Å. Overlays CRYSOL's curve (`res_comparison.tex`).

### SASDN32: Sas20d2 with 5 mM maltoheptaose

```
julia --project=test/fitting_tests test/fitting_tests/SASDN32/SASDN32.jl
```

Fits Sas20d2 (26.3 kDa, 10 mg/mL), PBS + TCEP buffer, q ≤ 0.3 Å⁻¹, lMax 24. **Unique:** the buffer includes 5 mM maltoheptaose, a solute that was previously left out because it had no volume data; it now uses the measured 694.8 ± 5.8 cm³/mol (Hourston 1967, thesis Table 6.1) and, at 5 mM, it is a real contribution to the solvent electron density. Single fit, no reference overlay.

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

The entries with a DNA or RNA in the structure (32 now; the first thirty were added to learn whether the existing four-parameter model fits nucleic acids at all) differ from the protein entries in these ways:

- **Model types.** 15 are nucleic acid only (DNA duplexes and G-quadruplexes, structured RNAs, an MD frame of an aptamer), 14 are protein with DNA or RNA (a nucleosome, protein-DNA and protein-RNA complexes). Some models are crystal or NMR structures, others MD frames, HADDOCK/SASREF rigid-body models, RNAMasonry or SREFLEX models; 11 carry their own hydrogens, which pdb2pqr rebuilds (`ADD_HYDROGENS` stays `true`, unlike SASDP48, whose protein hydrogen names pdb2pqr rejects). The B-factors of several MD models are all 0.00: BAYSOL never reads B-factors or occupancy, so that is not a defect.
- **Hydrogenation routes** (`BAYSOL.seedModel` chooses them from the residue names; the details are in the Hydrogenator README). A nucleic acid alone goes through pdb2pqr with AMBER and no PROPKA run (nucleic-acid hydrogens do not depend on pH); a protein-DNA or protein-RNA model keeps PARSE and PROPKA (the terminus flags need PARSE). Modified nucleotides (`DOC` in SASDCM5, `PSU 4SU 5MU H2U OMC` in SASDNP7) are hydrogenated through their base by relabelling and restoring the names, an approximation that does not place hydrogens which exist only in the modification; a modified residue with no known base gets none. Legacy names (`ADE GUA CYT URI`: SASDT55), plain letters for DNA (`A C G T`: SASDAN8, SASDH39) and reused chain ids (SASDAC9) are repaired in the copy pdb2pqr sees, and heavy atoms pdb2pqr drops (the 5' phosphorus) are restored. Waters are not part of the model, and ligands, ions included, are kept as heavy atoms without hydrogens when the component table gives them a known composition (`KEEP_LIGANDS`, heme, GTP, Mg and K ions, sugars); modified amino acids written as HETATM (SASDH39's selenomethionines, SASDB48's protein) are kept and hydrogenated through their parent (Hydrogenator README).
- **Buffers.** Nucleotides are taken as the user supplied them; the buffer is entered as for the proteins, and the measured macromolecule is never a solute. Several recipes need an assumed titrant (NaOH for a Good's buffer, HCl for Tris), stated in each section.
- **Depositor comparisons are less uniform than for the proteins.** Some fit files are not on the data's scale (SASDAN8, SASDWJ4, SASDU29), carry a different χ² in the header than the file reproduces (SASDAN8: 2.464 vs 4.58; SASDK94: 5.820 vs 5.635 of the entry). SASDAC9's depositor χ² of 680 is kept on purpose as a stress test.
- **Open items.** SASDK36, SASDWJ4 and SASDSX5 are parked by the owner (buffer and citation questions). A modified base with no known base gets no hydrogens. A nucleic chain that starts or ends with a non-nucleotide (SASDNP7's aminoacyl MET, SASDWJ4's 5' GTP) runs those ends under chain ids of their own in the temporary pdb2pqr copy (`hydrogenator/chain-ends.jl`), which is what lets pdb2pqr's terminal patches apply.
- **Known buffer omissions.** BAYSOL does not guess missing acids, bases or counter-ions; the user is responsible for the recipe. A script that knows its recipe is incomplete says so: a `# BUFFER OMISSIONS` comment block, a `const BUFFER_OMISSIONS = String[...]` after `SOLUTES` and a `@warn` on every run and seed build. The table below gives the effect on the buffer electron density in percent of water (estimates, from the audit of the solute tables); every component is in the tables (GDPNP and D₂O are modelled, see their entries below); free GTP of SASDWJ4 is still left out because its concentration is not stated. "Tris-HCl" (or Tris at a pH) is modelled as Tris plus HCl at the molarity derived from Goldberg's pK with a Davies correction; no Tris-HCl salt is added and the extra hydrogen of the salt reading is accepted (owner decision), so it is a convention, not an omission. Glycerol has two uncertainty conventions: the 5 % v/v recipes of SASDKQ8, SASDRN5, SASDTK5 and SASDF95 use 0.6846 M with σ 2 %, most new entries use 5 % relative; neither is an error.
- **Diagnose tools.** `dev/src/fit-seed.jl` takes the reference curve's name from the script's (`SASDWJ4_fit2.jl` reads `SASDWJ4_fit2.fit`; a script without a `_fit` suffix is fit1), so SASDK36, whose script carries no suffix but whose `.fit` is fit2, gets no reference in `bysl fits diagnose`, and SASDAC9 and SASDB48 have no `.fit` file; SASDNP7's file has three columns, not the four it expects.


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

Run labels in the table are the sections of the run logs: `<ID> —` for a script that writes `res.xlsx` (the section is named after the folder), `<ID> fit1` (or `fit2`, `fit3`, `model1`, …) for the others (`res_fit1.xlsx`).

### SASDAC9: Varkud satellite ribozyme dimer, Tris/KCl/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDAC9/SASDAC9.jl
```

Fits the Varkud satellite ribozyme dimer (G638A mutant, 120.3 kDa; 12092 atoms including 4026 hydrogens, GDP, 10 Mg²⁺, 10 K⁺ and 22 waters in the deposited model) in 25 mM KCl, 10 mM Tris, 5 mM MgCl₂, pH 7.5, 12.0 keV, q ≤ 0.3 Å⁻¹. The temperature is not recorded (the package default, 25 °C, is used) and the .dat is in nm⁻¹. Tris counter-ion: Cl⁻ 8.46 mM (fraction 0.846, I ≈ 0.048 M); MgCl₂ ±2 %. **Unique:** the depositor's FoXS fit is poor (χ² 680.3), and the entry is **kept on purpose as a stress test** (the table row will show what BAYSOL makes of a model that its own depositor cannot fit). The deposited model labels both 186-nt RNA chains `A` (separated by TER, with overlapping residue numbers; chain `B` holds only ions, waters and ligands). The first seed build failed on that (BioStructures: two atoms with the same alternative location); the pipeline now gives the second chain a free chain id in the copy it hands to pdb2pqr (`MolecularStructure.sanitizedCopy`), and `test_struct_chk.jl` hydrogenates this very model (11996 atoms of the polymer after the AMBER run, 4028 hydrogens; 12084 with the ligands the loader keeps). Overlays the depositor's FoXS curve (`SASDAC9_fit2.dat`).

### SASDAN8: mLBS1-2 viral terminal-repeat DNA, Tris/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDAN8/SASDAN8.jl
```

Fits the free mLBS1-2 B-DNA duplex (30 kDa, 2044 heavy atoms, chains A and B; up to 5 mg/mL) in 150 mM NaCl, 10 mM Tris, pH 7.6, 10 °C, 10.3 keV, q ≤ 0.3 Å⁻¹. Tris counter-ion Cl⁻ 8.26 mM (fraction 0.826, I ≈ 0.158 M); the .dat is in nm⁻¹. **Unique:** pure DNA, but written with the bare residue names `A C G T`, which pdb2pqr (PARSE) reads as RNA: at the first seed build it added a 2'-OH to every `A`, `C` and `G` and no hydrogen to the thymines. The pipeline now relabels a residue named `A C G U` that has no `O2'` as DNA in the copy it hands to pdb2pqr (the plain-letter rule of the Hydrogenator README: 2044 atoms plus 1111 hydrogens, none on an `O2'`). **Depositor comparison:** the 3-column CRYSOL file is not on the data's scale, so it is rescaled for the overlay; its header χ² (2.464, the value SASBDB records) is not reproduced by the file (4.58 after rescaling with a free scale), and the overlay shows the file value. All B-factors of the model are 0.00 (a molecular-dynamics model), which is not a defect: BAYSOL never reads them.

### SASDB48: HSV-1 ICP4N dimer on IE3 DNA, HEPES/NaCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDB48/SASDB48.jl
```

Fits the rigid-body model of the ICP4N dimer on the 19-bp IE3 DNA (chains G, H protein and C, D DNA; 3735 atoms, 60.3 kDa) in 20 mM HEPES, 150 mM NaCl, pH 7.4, 20 °C, 12.4 keV, q ≤ 0.25 Å⁻¹ (the data stop at 0.251). HEPES titrated with NaOH: Na⁺ 9.08 mM (I ≈ 0.159 M). **Unique:** the protein residues are written as HETATM records in the deposited model, which the loader keeps because they are peptide-linking amino acids (`polymerSelector`; the raw loader count rose from 773 to 3735 atoms with that selector, the pipeline result of 7041 atoms with 3306 hydrogens did not change); the depositor's file `SASDB48_fit1.dat` has the model in column 3 and σ in column 4. Overlays the FoXS fit (χ² 2.4; recomputed from the file 2.407).

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

Fits the E9 exo⁻ polymerase (1010 residues) bound to a 29-nt template-primer hairpin DNA (126.2 kDa; SEC-SAXS) in 100 mM NaCl, 20 mM Tris-HCl, 4 mM DTT, pH 7.0, 20 °C, 12.5 keV, q ≤ 0.25 Å⁻¹ (the depositor's CRYSOL curve ends there). Tris counter-ion Cl⁻ 19.0 mM (fraction 0.949, I ≈ 0.119 M); the .dat is in nm⁻¹. **Unique:** a mixed protein-DNA model (8838 heavy atoms, chains A, P, T) with a modified nucleotide (`DOC`, 2',3'-dideoxy-C, HETATM), hydrogenated through its parent DC (12 hydrogens placed, 14 in the free component's formula), a dCTP ligand (`DCP`, 28 heavy atoms, HETATM), 89 waters and one Ca²⁺. **Open:** `DCP` is not a nucleotide (the table has it as a non-polymer), so it receives no hydrogens and is not reported by the modified-nucleotide note; the loader now keeps it (28 heavy atoms, no hydrogens). Overlays CRYSOL (χ² 1.08).

### SASDDF7: armless mitochondrial tRNA-Arg, HEPES/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDDF7/SASDDF7.jl
```

Fits the armless mitochondrial tRNA-Arg of *Romanomermis culicivorax* (64 nt, 13.4 kDa, single chain; 6 mg/mL SEC-SAXS) in 50 mM HEPES-NaOH, 10 mM MgCl₂, pH 7.4, 15 °C (the SEC elution temperature), 12.0 keV, q ≤ 0.4 Å⁻¹ (the depositor's fit stops there; the data reach 0.61 Å⁻¹ and are noisy beyond). HEPES titrated with NaOH (stated): Na⁺ = 0.435 of the concentration; MgCl₂ ±1 %. **Unique:** a small RNA with a divalent counter-ion in the buffer. Seed build: 880 deposited atoms, 1326 with hydrogens, 132 binned points. Overlays CRYSOL fit1 (χ² 1.955).

### SASDF95: HigA-DNA complex (P. aeruginosa), Tris/NaCl/glycerol

```
julia --project=test/fitting_tests test/fitting_tests/SASDF95/SASDF95_fit2.jl
```

Fits the PaHigA-DNA complex (HigA on a 32-bp DNA duplex; chains A, B, E, F protein and C, D DNA; 4073 atoms, 42.5 kDa, merged 1-5 mg/mL curve) in 20 mM Tris, 300 mM NaCl, 5 % v/v glycerol, 1 mM PMSF, pH 8.0, 23 °C, 12.04 keV (0.103 nm), q ≤ 0.3 Å⁻¹. **Unique:** four protein chains (two dimer copies) plus a DNA duplex in one model; glycerol (0.685 M) and PMSF (our own estimated table entry, as in SASDYW6) in the buffer; Tris-HCl counter-ion estimated (Cl⁻ 0.661 of 20 mM at pH 8.0, I ≈ 0.313 M); the SEC-like merged curve has 3 non-positive points of 844. The seed build gives 7607 atoms; pdb2pqr dropped 2 `H5T` hydrogens (restored phosphorus) and added 4 heavy atoms, which are kept and warned about. Overlays CRYSOL fit2 (χ² 6.229).

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

Fits the BusR-DNA model (protein chains A-D and DNA strands E, F; 152 kDa; 8371 atoms in the file, including two cyclic-di-AMP HETATM residues, `2BA`, with no hydrogens on them) in 20 mM HEPES, 100 mM NaCl, 3 % v/v glycerol, pH 6.5, 20 °C, 10 keV (0.123981 nm), q ≤ 0.3 Å⁻¹ (data to 0.60). HEPES titrated with NaOH: Na⁺ 1.84 mM (9 % deprotonated at pH 6.5); glycerol 0.411 M ±5 %. **Unique:** the largest mixed entry (4 protein chains + 2 DNA strands), SEC-SAXS in nm⁻¹ with a flat σ noise floor above 0.25 Å⁻¹; the c-di-AMP is in the model but not in the buffer text. **Depositor comparison:** the fit file header gives χ² 5.820 (the entry records 5.635) and recomputing it over q ≤ 0.3 alone gives 10.1; the software is not stated (the header columns "Convex/Concave/Inner" are those of SASDU29's file, which looks like Pepsi-SAXS), so the overlay is labelled "SASBDB fit1".

### SASDM76: 201D G-quadruplex DNA, BPEK buffer

```
julia --project=test/fitting_tests test/fitting_tests/SASDM76/SASDM76.jl
```

Fits the 28-nt G-quadruplex 201D (8.9 kDa; 914 atoms including 322 hydrogens and 3 K⁺) in 185 mM KCl, 6 mM Na₂HPO₄, 2 mM NaH₂PO₄, 1 mM Na₂EDTA, pH 7.2, 22 °C, 12.0 keV, q ≤ 0.3 Å⁻¹. **Unique:** the smallest nucleic-acid entry (lMax 13); the phosphate species are used as stated (no titrant counter-ion; the stated 3:1 split would not give pH 7.2 and is not corrected); Na₂EDTA is entered as the `H2EDTA` table row plus 2 mM Na⁺. `ADD_HYDROGENS` stays `true`: pdb2pqr replaced the 322 deposited hydrogens by its own 324 (913 atoms in the model, the 3 K⁺ kept). Overlays CRYSOL (χ² 1.779).

### SASDNH7: Tn3 resolvase-site II DNA complex, Tris/NaCl/MgCl₂/glycerol

```
julia --project=test/fitting_tests test/fitting_tests/SASDNH7/SASDNH7_fit1.jl
```

Fits the resolvase dimer on the 52-bp site II DNA (protein chains C, D and DNA strands Y, Z; 75 kDa; 4980 atoms, no hydrogens) in 25 mM Tris, 150 mM NaCl, 10 mM MgCl₂, 1 % v/v glycerol, pH 7.5, 22 °C, 12.04 keV (0.103 nm), q ≤ 0.15 Å⁻¹ (data to 0.48; 437 of 1374 points are ≤ 0, none below 0.22 Å⁻¹). Tris-HCl counter-ion Cl⁻ 21.5 mM (I ≈ 0.201 M). **Unique:** the depositor's fit file is not served by the SASBDB API (404) and was fetched from the media URL `https://www.sasbdb.org/media/fitting_files/SASDNH7_fit1.fit`. It is a FoXS profile (3 `#` header lines, 559 rows, q 0.0083-0.1997 Å⁻¹) whose `I_exp` column equals the deposited .dat (ratio 1.0 ± 6e-8) and whose χ² (16.465, recomputed 16.4653, 21.5 over q ≤ 0.15) is the entry's depositor value; its column 4 is the final scaled model and is overlaid unchanged. Seed build: 9124 atoms; 2 `H5T` hydrogens removed with the restored phosphorus, 2 heavy atoms added by pdb2pqr (kept, warned about). Overlays the FoXS fit (a poor depositor fit).

### SASDNK7: c-MYC Pu22 G-quadruplex DNA, Tris/KCl

```
julia --project=test/fitting_tests test/fitting_tests/SASDNK7/SASDNK7_fit1.jl
```

Fits the 22-nt MYC22-G14T/G23T G-quadruplex (PDB 1XAV-derived, 7.1 kDa, 1.8 mg/mL) in 50 mM Tris, 30 mM KCl, pH 8.0, 25 °C, 8.27 keV (0.15 nm), q ≤ 0.5 Å⁻¹. **Unique:** the .dat has a 212-line comment header (`skipstart = 212`) and 54 non-positive points; the model carries 249 hydrogens and two K⁺ ions as HETATM residues `K` (kept as ions: 718 atoms before and after pdb2pqr); Tris-HCl counter-ion estimated (Cl⁻ 0.639 of 50 mM, I ≈ 0.062 M). `ADD_HYDROGENS` stays `true` although the model has hydrogens (as for SASDWZ9). Overlays CRYSOL (χ² 1.391).

### SASDNP7: aIF2-GDPNP-tRNA complex, MOPS/NaCl/MgCl₂

```
julia --project=test/fitting_tests test/fitting_tests/SASDNP7/SASDNP7_fit1.jl
```

Fits the aIF2 γ/α-tRNA model (chains A, B, D; 5693 atoms; GNP, Mg²⁺, 7 selenomethionines and five modified tRNA bases PSU, 4SU, 5MU, H2U, OMC as HETATM) at 1.65 mg/mL in 10 mM MOPS-NaOH pH 6.7, 200 mM NaCl, 5 mM MgCl₂, 1 mM GDPNP, 15 °C, 12.4 keV (0.1 nm as recorded), q ≤ 0.3 Å⁻¹. MOPS titrated with NaOH: Na⁺ 2.88 mM (A⁻ fraction 0.288). **Unique:** modified nucleotides in a mixed model (to be hydrogenated through their parent bases); the curve is the one without Gd-HPDO3A; GDPNP is not in the solute tables and is left out; a poor depositor fit (CRYSOL χ² 29.6) with a 3-column fit file (q, `I_exp`, `I_fit`). **Open, not resolved:** the seed build fails. pdb2pqr aborts on its charge-integrality check ("Residue RG D 2 has non-integer charge: -0.34"; the total it then reports was -66.34 and is -71.34 now that the loader keeps the modified amino acids, 7 more atoms), the residue named in the message is not the cause: chain D is an aminoacylated tRNA (G2 ... A76 followed by MET101), so pdb2pqr's 3' patch never applies and the 5' patch alone leaves a fractional charge (deleting MET D 101 makes pdb2pqr succeed). Remedy (a chain id of its own for the terminal non-nucleic residue in the temporary pdb2pqr copy, heavy atoms always from the user's file): approved in principle by the owner, not implemented. This entry cannot be fitted until then.

**GDPNP:** 1 mM is modelled as the tetrasodium salt (3D-RISM estimate anchored on the measured GTP tetrasodium, 288.8 ± 22 cm³/mol), +0.026 % in ρₑ; the real cations are not stated. Stored results predate this and are stale.

### SASDPN6: SARS-CoV-2 5'-genomic stem-loop 4 RNA, potassium phosphate/KCl/TCEP

```
julia --project=test/fitting_tests test/fitting_tests/SASDPN6/SASDPN6_fit1.jl
```

Fits the RNAMasonry model of the 69-nt stem-loop 4 with AU extension (chain A, 22.1 kDa; 2191 atoms, of which 731 are the builder's hydrogens named H01-H12) in 25 mM potassium phosphate, 150 mM KCl, 2 mM TCEP, pH 6.5, 20 °C, 10 keV (0.124 nm), q ≤ 0.3 Å⁻¹ (data to 0.74). Potassium phosphate split as for SASDVX2 (KH₂PO₄ 17.0 mM, K₂HPO₄ 8.0 mM, HPO₄²⁻ fraction 0.320); TCEP taken neutral, no counter-ion. **Unique:** a SEC-SAXS RNA-only entry whose deposited model already carries hydrogens; `ADD_HYDROGENS` stays `true`, as for SASDT55 and SASDWZ9 (SASDP48 uses `false` only because pdb2pqr aborts on its PDB-v2 protein hydrogen names), and pdb2pqr accepted the builder's names (2929 atoms: 1460 heavy plus 1469 hydrogens). The 5' end has a phosphate whose `OP2` has the element column `O1-`. Overlays the Pepsi-SAXS fit (χ² 1.224; the file header says 1.143).

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

Fits the HADDOCK model of NS1B-CTD* (15.9 kDa) bound to the 24-nt 5'ppp hairpin RNA (chains A, B; 2173 atoms, 532 hydrogens) in 40 mM ammonium acetate pH 5.5, 225 mM NaCl, 5 mM CaCl₂, 0.02 % NaN₃, 50 mM arginine, 20 °C, 12 keV (stated), q ≤ 0.25 Å⁻¹ (data to 0.30). **Unique:** the RNA carries legacy residue names (`GUA ADE URI CYT`, and `GTP` for the triphosphate end), recognised by the backbone rule of the Hydrogenator README (the rule is implemented as the owner approved it (see the Hydrogenator README); `test-legacy-nucleotides.jl` runs pdb2pqr on this model); arginine and ammonium acetate are neutral table entries with no counter-ion (the pH adjuster is unknown). Seed build: 3027 atoms. Overlays the depositor's Pepsi-SAXS fit (χ² 1.026; recomputed 0.995).

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
