# Pipeline

The four entry points, re-bound by the package root as `BAYSOL.seed_model`, `BAYSOL.run_model`, `BAYSOL.plot_results` and `BAYSOL.write_timings`:

```julia
using BAYSOL
seed = BAYSOL.seed_model(src, energy, q, I, σ, pH, σ_pH, solutes) # rebin = 12 per Shannon channel, lMax from the structure
res  = BAYSOL.run_model(seed) # 300 warm-up + 700 draws; run_model(seed, n_samples, n_adapt) to change
BAYSOL.plot_results(res, seed; dir = "out") # terminal plots, pgfplots .tex, and the workbook out/res.xlsx; before write_timings, so its table has the plotting
BAYSOL.write_timings(res) # the timing table, also added to the workbook as the sheet `timings`
```


| File           | Contents                                                                                                                                                                                                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Pipeline.jl`  | the module: constants `DEFAULT_QUANTILES` (`"16-84"`), `DEFAULT_N_ADAPT` / `DEFAULT_N_DRAWS` / `DEFAULT_N_SAMPLES` (300 / 700 / 1000), the result types `MAPParams`, `MAPResult`, `QuantileBounds`, `QuantileParams`, `QuantileCurves`, `QuantileResult` (as `BAYSOL.Pipeline.MAPParams` etc.) |
| `SeedModel.jl` | `seed_model`                                                                                                                                                                                                                                                                                   |
| `RunModel.jl`  | `run_model`                                                                                                                                                                                                                                                                                    |
| `Plot.jl`      | `plot_results`, `PlotStyle`, `Reference` and the data the figures are drawn from (see "The figures")                                                                                                                                                                                           |
| `Summary.jl`   | the summary sheets of the workbook (`run`, `map`, `quantiles_<lo>-<hi>`, `stdev_from_prior`, `modes`, `optima`, `form_factor_log`) |
| `Timings.jl`   | `write_timings` and the timing table |

## The stages

`seed_model` (every step is a named stage of the `Runtime.StageLog`, cache hits marked):

1. resolve the structure (`MolecularStructure`), look its residue names up (`components`), run the `structure checks` (reused chain ids, duplicate atoms, dummy-like models) and choose the hydrogenation from the content (`classify`);
2. `Hydrogenator`: PROPKA unless the structure is a nucleic acid alone, then pdb2pqr (PARSE, or AMBER for a nucleic acid alone), with modified residues hydrogenated through their parent;
3. the solvent-accessible surface and the diameter `D` of the scatterer cloud (atoms **and** beads), `Utils.Shannon` binning of the curve to `rebin` bins per channel `π/D`, and `lMax = ⌈q_max D⌉`;
4. `Scattering.forward_cache` (the Gram matrix), the priors from the buffer `solutes` (`BulkElectronDensity.ρₑ`), and `Inference.seed_sampler`.

`run_model` calls `Inference.infer` (8 chains, MAP search, harvest, mode pooling, one R̂ retry), drops each chain's warm-up, picks the MAP draw (highest non-divergent `log π`) and computes the quantile intervals and bands. Its result holds everything the workbook reports; developer diagnostics live in the dev tools (`bb diagnose`).

## The figures

`plot_results(result, seed; dir, name = "res", references, style, preview = true, tex = true, tables = :xlsx, compile = false)` makes the fit (data with error bars, the posterior bounds band and quantile curves, the MAP curve; log axes), the residuals and the posterior histograms (ρₑ, δρ₁, δρ₂, δρ₃, scale, background, c1, each its own figure `<name>_hist_<parameter>` with the MAP marked), plus one comparison figure per `Reference(name, q, I; q_max)` (data, the reference curve and the MAP curve: the depositor's CRYSOL, FoXS, … fit). Every figure is prepared once as plain arrays (`_curve_data`, `_residual_data`, `_histogram_data`, `_comparison_data`) and drawn three ways:

- **in the terminal** (UnicodePlots, `preview = true`), printed to `io`; it needs nothing installed. It prints the fit (the data in orange and the MAP curve, as log₁₀ q against log₁₀ I(q)) and the residuals, both titled with the MAP's reduced χ²; the residuals are clipped to the 2–98 % range (the title counts the points outside); one orange histogram per parameter has its MAP value in the title. The bounds band and the reference curves are in the `.tex` only;
- **as a pgfplots `.tex`** (PGFPlotsX, `tex = true`): a standalone LaTeX document per figure, written without LaTeX. LaTeX is run only with `compile = true` (to `formats = (:pdf,)`, or `:png`/`:svg`, which also need poppler's `pdftocairo`/`pdftoppm`); a failed run is a warning and the `.tex` stays. It takes about a second per figure, which is why it is off by default;
- **as numbers** (`tables`): the workbook described below.

**The layout** of the output folder `dir`: the `.tex` files, and what `compile = true` or `bb render-plots` makes from them, are in `dir/plots/`; the workbook `<name>.xlsx` and the timing file `<name>_timings.txt` are in `dir`. `name` starts every file name, so several runs can share a folder (`res_fit1`, `res_fit2`). With `tables = :tsv` (or `:both`) every sheet is also a tab-separated file `dir/data/<name>_<sheet>.tsv`; `:none` writes no numbers. The subfolder names are `PLOT_SUBDIR` and `DATA_SUBDIR` in `Pipeline.jl`; a folder is created when something is written to it.

Colours, line widths, marker sizes, the histogram bins, figure sizes and the terminal plots' size are the fields of `PlotStyle` (`PlotStyle(; color_map = "#0000ff", lw_map = 2)`), each defaulting to the `PLOT_*` constant in `Pipeline.jl`; a colour is a name `Colors.parse` reads, a `"#rrggbb"` string or a `(colour, opacity)` tuple.

**The font** of the `.tex` figures is the `font` keyword of `plot_results` (or `PlotStyle(; font = ...)`): the name of any font that LuaLaTeX can find, a `("Text font", "Math font")` pair of `fontspec` names, or `nothing` for the LaTeX default. The default is the pair TeX Gyre PagellaX and TeX Gyre Pagella Math (`PLOT_FONT`; TeX Live packages `newpx` and `tex-gyre-math`). A single name is the text font and leaves the math font at Latin Modern Math; a pair sets both. `font_available("Name")` (also `BAYSOL.font_available`) asks the TeX Live installation, through `luaotfload-tool`, whether a name works and returns `true` or `false`; from the shell, `bb fonts "Name"` does the same and `bb fonts --list` lists every installed family. A font is loaded with `unicode-math`, so a figure with a font compiles only with `lualatex` or `xelatex` (`plot_results` and `bb render-plots` pick one; `pdflatex` cannot), and a font LuaLaTeX cannot find makes the LaTeX run fail with a warning that names it and keeps the `.tex`. With only `pdflatex` installed, use `font = nothing`. The terminal plots and the workbook do not depend on the font.

**The page** of a figure keeps a border of `PlotStyle`'s `border_pt` (8 pt) round it, so the last tick label, the legend and the axis title are not cut off at the right or top edge.

The time of each figure (its data, preview, `.tex`, LaTeX run; one stage for each histogram) and of the workbook is recorded as stages of the `plot` group of the run's timing log, which is why `plot_results` goes before `write_timings`.

## The workbook

`<name>.xlsx` holds every number of a run, one table to a sheet. Sheet and column names are plain ASCII (`rho_e`, `delta_rho_1`, `chi2`), the first row of a sheet names its columns, and every value is a number except the labels in the first column, `form_factor_log` and `timings`. The workbook opens in Excel, LibreOffice and Google Sheets and reads with `pandas.read_excel(path, sheet_name=None)`.

| Sheet | Columns | What it holds |
| --- | --- | --- |
| `run` | `key`, `value` | the run's settings and statistics, one per row (below) |
| `map` | `parameter`, `value` | the MAP draw: `log_density` (the log posterior density), `rho_e` (buffer electron density, e⁻/Å³), `delta_rho_1`, `delta_rho_2`, `delta_rho_3` (hydration-shell contrasts), `scale`, `bkgrnd_corr` (detector scale and background), `excl_vol_corr` (the profiled excluded-volume correction `c1`), `chi2` (reduced χ² **on the measured points**, `n_raw − 3` degrees of freedom: scale, background, `c1`; the grid CRYSOL and FoXS evaluate, whatever the binning) |
| `quantiles_<lo>-<hi>` | `parameter`, `quantile_lo`, `quantile_hi`, `bound_lo`, `bound_hi` | the same parameters: the posterior quantile pair (default `16-84`, the `quantiles` of `run_model`) and the extreme draws that lie inside it |
| `stdev_from_prior` | `parameter`, `z_map`, `z_quantile_lo`, `z_quantile_hi` | for the four parameters with a prior (`rho_e`, `delta_rho_1..3`): how many prior standard deviations (θ-space) the MAP value and the quantile pair lie from the prior mean |
| `modes` | `mode`, `share`, `log_mass`, `log_mass_err`, `chains`, `kept` | only when the chains settled in more than one posterior mode: each mode's share of the posterior mass by bridge sampling, its log mass and error (nats), its number of chains, and whether it keeps draws (`kept` is 0 for a share below 1e-4) |
| `optima` | `optimum`, `share`, `chains`, `started` | only when more than one local optimum carries mass: its share of the Laplace mass, the chains that ended there and how many of them started there |
| `form_factor_log` | `line` | text; only when form-factor parsing logged something |
| `timings` | `timings` | text; the lines of the timing file, added by `write_timings` |
| `data` | `q`, `I`, `sigma` | the curve the fit saw (Shannon-binned) |
| `model` | `q`, `I_map`, `quantile_lo`, `quantile_hi`, `bound_lo`, `bound_hi` | the MAP curve and the posterior quantile and bounds curves |
| `residuals` | `q`, `I`, `sigma`, `I_map`, `residual` | data, MAP curve and `(I − I_map)/sigma` |
| `hist_<parameter>` | `bin_lo`, `bin_hi`, `count` | the counts of one parameter's histogram (non-divergent draws), seven sheets |
| `draws` | `chain`, `iteration`, `divergent`, `rho_e`, `delta_rho_1..3`, `scale`, `bkgrnd_corr`, `c1`, `chisq_red` | every posterior draw; `divergent` is 1 for a divergent transition |
| `ref_<name>` | `q`, `I` | a reference curve given to `plot_results` |

**The `run` rows**, in order (a row is absent when the run did not record it):

- Sizes: `n_atoms` (atoms of the hydrogenated structure), `lmax` (highest spherical-harmonic degree of the scattering model), `n_q_raw` (measured points), `n_q` (points fitted after binning).
- Sampler settings: `n_samples` (NUTS iterations of each chain, warm-up included), `n_adapt` (the warm-up part), `rng_seed` (reproduces the run).
- Shannon binning: `dmax` (Å, the maximum diameter of the atoms and hydration-shell beads), `channels` (q range × `dmax` / π, the number of independent Shannon channels), `rebin_channels` (bins per channel; 0 when the curve was fitted as measured), `rebin_measured` and `rebin_fitted` (points before and after), `rebin_non_positive_dropped` (bins with a non-positive mean that were dropped).
- Sampler statistics: `iterations` (post-warm-up transitions of the pooled chains), `mean_accept` (mean acceptance rate; the target is `DEFAULT_TARGET_ACCEPT`), `tree_depth_avg` and `tree_depth_max`, `mean_n_steps` (leapfrog steps per iteration), `ebfmi` (energy-based fraction of missing information of the worst chain; below about 0.3 the momentum resampling explores poorly), `cavity_frac` (share of the hydration-shell volume carried by cavity beads; near 0 means `delta_rho_3` has no likelihood and its posterior is its prior), `excl_vol_sat` (0, +1 if `c1` sat on its upper bound at the MAP, −1 on its lower), `divergence_rate` (share of divergent transitions).
- Chains: `chains_pooled` (chains whose draws are kept) of `chains_run`, `rhat_max` (worst rank-normalized split R̂ over the four parameters and the log density; above 1.01 the chains have not converged), `ess_min` and `ess_tail_min` (smallest bulk and tail effective sample sizes), then, when they apply, `modes` and `optima` (their counts, with the sheets above), `rewhitened_nats` (log-density gain when the chains found a better basin than the MAP search) and `retry_first_rhat` with `retry_kept` (the first run's R̂ when it was rerun, and 1 if the rerun was kept).

## The timing table

`write_timings(io, result)` prints `<name>_timings.txt` and adds the same lines to the workbook as `timings`, so the two always agree. It lists the wall clock from the start of `seed_model` to the end of the call, with every stage's seconds, its share of the wall clock and its JIT compile time (the stages indent by depth; the `static build`, `sampling` and `plotting` groups sum their stages), a stage's note on lines of its own under it (80 columns), `report write`, `unaccounted` and `GC` time, and ends with two lines, `fit timing` (everything but the plotting) and `plot timing`, whose sum is the wall clock. Residual statistics (lag-1, runs z) are in no output; `bb diagnose --residuals ID` prints them. The fitting-test scripts under `test/fitting_tests/` are deliberately self-contained examples of these calls.
