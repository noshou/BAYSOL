# Pipeline

The four entry points, re-bound by the package root as `BAYSOL.seedModel`, `BAYSOL.runModel`, `BAYSOL.results`, `BAYSOL.writeLog` and `BAYSOL.printSummary` (and, for the models of one measured curve on one figure, `BAYSOL.compareResults`):

```julia
using BAYSOL
seed = BAYSOL.seedModel(src, energy, q, I, σ, pH, σ_pH, solutes) # rebin = 12 per Shannon channel, lMax from the structure
res  = BAYSOL.runModel(seed) # 300 warm-up + 700 draws; runModel(seed, nSamples, nAdapt) to change
BAYSOL.results(res, seed; dir = "out") # terminal plots, pgfplots .tex, and the workbook out/res.xlsx and always the statistics out/statistics-out.LOG and the run log out/out.LOG (written last)
BAYSOL.writeLog(res) # the run log out/out.LOG (what `results` does last)
BAYSOL.printSummary(res) # what a run says at the end: one parameter, check or file per row, every line under 80 columns
```

A fitting-test script that throws (`NotConvergedError` after the retry, or anything else) leaves no result to log, so `bysl fits run` starts each script through the internal `BAYSOL.Pipeline._runLogged`: it writes the run's section as `status` `failed`, `errorType`, `error` (one line), the setup facts and the timing so far, and the machine, with no fit rows, then rethrows. The section replaces that run's earlier one. A script run directly with `julia script.jl` writes no such section.


| File           | Contents                                                                                                                                                                                                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `params.jl`    | every tunable constant of the module: the data and structure settings `Q_MIN`, `Q_MAX`, `SIGMA_SCALE`, `EXCLUDE_Q`, `LMAX`, `CHAINS`, `MODEL`, `ADD_HYDROGENS`, `VAL_SIGMA` (2; any `sigma > 0` is accepted), `N_ADAPT` / `N_DRAWS` (300 / 700; the total is their sum), `TABLE_SIGFIGS`, `FIGURES_TEX` / `FIGURES_COMPILE` / `FIGURES_FORMATS` / `FIGURES_DIR` / `FIGURES_COMPILER` (the `tex`, `compile`, `formats`, `plotDir` and `latexCompiler` defaults of `results`), `PLOT_COMPARE` (the comparison switch of the interface's `runProject`), `PLOT_TUI_SIZES` (the sizes of the terminal plots a `:tui` run also writes) and the `PLOT_*` defaults of `PlotStyle`, the comparison's `PLOT_COMPARE_COLOURS`, `PLOT_COMPARE_MARKERS` and `PLOT_LW_COMPARE` among them |
| `pipeline.jl`  | the module: the result types `MAPParams`, `MAPResult`, `QuantileBounds`, `QuantileParams`, `QuantileCurves`, `QuantileResult` (as `BAYSOL.Pipeline.MAPParams` etc.) |
| `seed-model.jl` | `seedModel`                                                                                                                                                                                                                                                                                   |
| `run-model.jl`  | `runModel`                                                                                                                                                                                                                                                                                    |
| `results.jl`   | `results`, `PlotStyle`, `Reference` and the data the figures are drawn from (see "The figures"); the figures' sheets (`data`, `model`, `residuals`, `hist_*`, `ref_*`)                                                                                                                                                                                           |
| `compare.jl`   | `compareResults` (the combined comparison figure and its `.tsv` table, see "The comparison figure") and the reader of a project's `reference-fit/` folder |
| `tables.jl`    | the sheet structure and the writers: the workbook and the `draws` sheet |
| `log.jl`       | `writeLog`, the run log `<folder>.LOG`, and the timing table it is made from (how to read it: "Reading the logs" below) |
| `summary.jl`   | the summary sheets of the workbook (`run`, `map`, `quantiles_<interval>`, `stdevFromPrior`, `modes`, `optima`, `formFactorLog`) and `printSummary` |

## The stages

`seedModel` (every step is a named stage of the `Runtime.StageLog`, cache hits marked):

1. resolve the structure (`MolecularStructure`), look its residue names up (`components`), run the `structure checks` (reused chain ids, duplicate atoms, dummy-like models) and choose the hydrogenation from the content (`classify`);
2. `Hydrogenator`: PROPKA unless the structure is a nucleic acid alone, then pdb2pqr (PARSE, or AMBER for a nucleic acid alone), with modified residues hydrogenated through their parent;
3. the solvent-accessible surface and the diameter `D` of the scatterer cloud (atoms **and** beads), `Shannon` binning of the curve to `rebin` bins per channel `π/D`, and `lMax = ⌈qMax D⌉`;
4. `Scattering.forwardCache` (the Gram matrix), the priors from the buffer `solutes` (`BulkElectronDensity.ρₑ`), and `Inference.seedSampler`.

`runModel` calls `Inference.infer` (8 chains, MAP search, harvest, mode pooling, one retry when R̂ or ESS says the run is not converged), throws `NotConvergedError` (and so reports nothing) if it is still not converged after the retry, drops each chain's warm-up, picks the MAP draw (highest non-divergent `log π`) and computes the quantile intervals and bands. Its result holds everything the workbook reports; developer diagnostics live in the dev tools (`bysl fits diagnose`).

## The figures

`results(result, seed; dir, name = "res", references, style, font, preview = true, io, tex = true, compile = false, formats, refChi2)` makes the fit (data with error bars, the posterior bounds band and quantile curves, the MAP curve; log axes), the residuals and the posterior histograms (ρₑ, δρ₁, δρ₂, δρ₃, scale, background, c1, each its own figure `<name>_hist_<parameter>` with the MAP marked), plus one comparison figure per `Reference(name, q, I; qMax)` (data, the reference curve and the MAP curve: the depositor's CRYSOL, FoXS, … fit). Every figure is prepared once as plain arrays (`_curveData`, `_residualData`, `_histogramData`, `_comparisonData`) and drawn three ways:

- **in the terminal** (UnicodePlots, `preview = true`), printed to `io`; it needs nothing installed. It prints the fit (the MAP curve alone, as log₁₀ q against log₁₀ I(q): the data points would bury it in a plot a few dozen cells wide; they are in the residuals, the `.tex` and the workbook) and the residuals, both titled with the MAP's reduced χ²; the residuals are clipped to the 2–98 % range (the title counts the points outside); one orange histogram per parameter has its MAP value in the title. The bounds band and the reference curves are in the `.tex` only;
- **as a pgfplots `.tex`** (PGFPlotsX, `tex = true`): a standalone LaTeX document per figure, written without LaTeX. LaTeX is run only with `compile = true` (to `formats = (:pdf,)`, or `:png`/`:svg`, which also need poppler's `pdftocairo`/`pdftoppm`); a failed run is a warning and the `.tex` stays. It takes about a second per figure, which is why it is off by default;
- **as numbers**: the workbook described below, always written, and so are the statistics log and the run log.

**The layout** of the output folder `dir`: the `.tex` files, and what `compile = true` or `bysl plots render` makes from them, are in `dir/plots/`; the workbook `<name>.xlsx` is in `dir`, and so is the run log `<folder name>.LOG` (below), one file for the folder with a section for each run. `name` starts every file name, so several runs can share a folder (`res_fit1`, `res_fit2`). The subfolder name is `PLOT_SUBDIR` in `pipeline.jl` (a fixed constant, not a setting); a folder is created when something is written to it.

Colours, line widths, marker sizes, the histogram bins, one figure size (`sizeCm`, 16 × 11 cm: it fits the text width of A4 and US Letter) and the terminal plots' size are the fields of `PlotStyle` (`PlotStyle(; colorMap = "#0000ff", lwMap = 2)`), each defaulting to the `PLOT_*` constant in `params.jl`; a colour is a name from the list of colour names (see "Colour names and their licences" below; any case), a code (`#rgb`, `#rrggbb`, `rgb(r, g, b)`, `hsl(h, s%, l%)` or `cmyk(c%, m%, y%, k%)`, each read as written and rounded once to 8 bits) or a `(colour, opacity)` tuple. One resolver, `colourRgb`, reads them all (an `ArgumentError` for anything else), so a saved setting is the text the user typed; `colour_names` lists the names and `colourNotations` writes a colour in each notation, with digits enough to read back as the same 8-bit value (tested for every name; the terminal interface has the same maths and both read `test/fixtures/colours/notations.json`).

**The font** of the `.tex` figures is the `font` keyword of `results` (or `PlotStyle(; font = ...)`): the name of any font that LuaLaTeX can find, a `("Text font", "Math font")` pair of `fontspec` names, or `nothing` for the LaTeX default. The default is the pair TeX Gyre PagellaX and TeX Gyre Pagella Math (`PLOT_TEXT_FONT` and `PLOT_MATH_FONT`, which make the pair `PLOT_FONT`; TeX Live packages `newpx` and `tex-gyre-math`). A single name is the text font and leaves the math font at Latin Modern Math; a pair sets both. `fontAvailable("Name")` (also `BAYSOL.fontAvailable`) asks the TeX Live installation, through `luaotfload-tool`, whether a name works and returns `true` or `false`; from the shell, `bysl plots fonts "Name"` does the same and `bysl plots fonts --list` lists every installed family. A font is loaded with `unicode-math`, so a figure with a font compiles only with `lualatex` or `xelatex` (`results` and `bysl plots render` pick one; `pdflatex` cannot), and a font LuaLaTeX cannot find makes the LaTeX run fail with a warning that names it and keeps the `.tex`. With only `pdflatex` installed, use `font = nothing`. The terminal plots and the workbook do not depend on the font.

**The look** of the `.tex` figures: a bold axis box (`lwAxis`, `colorAxis`, black by default); ticks pointing inward on all four sides, major and minor (`colorTick`, black by default; `lwTick` and `lwMinorTick`, `tickLengthCm`, `minorTicks` between two major ones of a linear axis; a log axis keeps its own); the x tick labels slanted (`xtickAngle`, 45° by default) and hung on bent ticks, each tick leaving the axis straight (`tickStubPt`) and then bending (`tickElbowPt`) towards its label, which pgfplots cannot do itself, so they are drawn as TikZ (and each plot is clipped on its own, `clip mode=individual`, for them to show outside the axis); the y labels padded from the axis (`tickLabelPadPt`) and the x labels from their tick (`xtickLabelPadPt`); the log axes of the fit and comparison figures start and end exactly where the data do; legends in `\footnotesize`. Each histogram has a boxed legend in the top corner over its long tail with the **MAP** (the solid line, in the MAP colour) and **μ** (the dotted line: the middle of the tallest bin, the most sampled part of the posterior), each with its value to enough digits to tell a bin from its neighbour. Every one of these is a `PlotStyle` field defaulting to a `PLOT_*` constant.

**The unit of q** in the figures and the workbook is the `qUnit` field of `PlotStyle` (the `PLOT_Q_UNIT` setting, a choice of `"Å⁻¹"`, the default, or `"nm⁻¹"`; the factors are `Q_UNIT_FACTORS`): the terminal plots, the `.tex` figures, the comparison table and every q column of the workbook (headed `q`, or `qNm` in nm⁻¹) are written in it. The fit, the data and the LOG always stay in Å⁻¹; the unit only scales what is displayed or saved for reading.

**The page** of a figure keeps a border of `PlotStyle`'s `borderPt` (8 pt) round it, so the last tick label, the legend and the axis title are not cut off at the right or top edge.

The time of each figure (its data, preview, `.tex`, LaTeX run; one stage for each histogram) and of the workbook is recorded as stages of the `plot` group of the run's timing log, which is why `results` calls `writeLog` last.

## The comparison figure

`compareResults(fits, data; names, references, dir, name = "res", style, font, preview = true, io, tex = true, compile = false, formats, tableSigfigs)` puts **one figure** together for the results of several models of the same measured curve: the measured points with their error bars (`data = (q, I, σ)`, the curve as measured, not each model's own Shannon-binned one), the fitted (MAP) curve of **every model** and every `Reference` (the depositor's fit, CRYSOL, FoXS, ...), on log axes like the other I(q) figures. `fits` are the results of `runModel` (a vector, one per model; a result without a MAP curve is left out with a warning), `names` their names (`model1`, `model2`, ... by default; they label the legend and the columns and must differ). `runProject` calls it after its model loop (below); a script can call it with the results it holds.

- **Colours and markers are assigned, not chosen per curve.** The `k`-th model is drawn in the `k`-th colour of `style.colorsCompare` (the setting `PLOT_COMPARE_COLOURS`, default the colour-blind-safe Okabe-Ito set of eight) in a line of `lwCompare` pt (`PLOT_LW_COMPARE`), and starts again at the first colour after the last. The terminal interface offers `PLOT_COMPARE_COLOURS` on its sheets only for a project with more than one model, and its project has ONE reference curve, which `runProject` hands to every model and to this figure. Every reference is a dashed line of the one reference colour (`colorReference`, `PLOT_COLOUR_REFERENCE`) carrying the `k`-th marker of `style.markersCompare` (`PLOT_COMPARE_MARKERS`: pgfplots mark names, any of `PLOT_MARKER_NAMES`, cycling too), so the references are told apart by their markers; a dense curve carries about 14 marks (`mark repeat`). The measured points keep `colorData` and the error bars their own look.
- **The band.** With one model the posterior bounds band of the single-model figure is drawn in that model's colour (`colorBand`'s opacity); with several models the bands would hide each other and are left out, the MAP curves only.
- **The terminal plot** (`preview = true`, printed to `io`) shows the data, each reference as its marker and each model's MAP curve in its colour (with its reduced χ² in the legend), as log₁₀ q against log₁₀ I(q). The `.tex` (`plots/<name>_compare.tex`, compiled only with `compile = true`) has everything.
- **The table** `<name>_compare.tsv` (a tab-separated text file, so that it compresses, unlike a workbook; no `legend` sheet: the colours, markers and line widths are the settings') lets the figure be redrawn in any program: a header line, then `q (A^-1)`, `I_measured (a.u.)`, `sigma (a.u.)` of the measured curve as given, one column `fit_<model> (a.u.)` for each model and `ref_<name> (a.u.)` for each reference, each interpolated linearly onto the measured q (empty where the curve does not reach, exact where it lies on that grid).

The settings are `PLOT_COMPARE` (the switch of `runProject`, the keyword `plotCompare`, default `true`), and the style's `PLOT_COMPARE_COLOURS` (`colorsCompare`: kind `colours`, an ordered, non-empty list of colour names or codes), `PLOT_COMPARE_MARKERS` (`markersCompare`: kind `markers`, an ordered, non-empty list of marker names) and `PLOT_LW_COMPARE` (`lwCompare`, at least 0). `PlotStyle`'s two lists are tuples of `Symbol`s (`PlotStyle(; colorsCompare = (:red, Symbol("#0072B2")))`). With the switch off, or without references, nothing else changes: the single-model figures and workbooks are what they were.

## The workbook

`<name>.xlsx` holds every number of a run, one table to a sheet. Sheet and column names are plain ASCII (`rhoE`, `deltaRho1`, `chi2`), the first row of a sheet names its columns, and every value is a number (a statistic that could not be computed, such as the E-BFMI of a very short chain, is an empty cell, since a spreadsheet has no `NaN`) except the labels in the first column and the text of `formFactorLog`. Every column is as wide as its longest text (up to 80 characters, then wrapped) and the header row is bold. Numbers carry `TABLE_SIGFIGS` (`params.jl`; 17 by default, every bit of a `Float64`) significant figures. The workbook opens in Excel, LibreOffice and Google Sheets and reads with `pandas.read_excel(path, sheet_name=None)`.

| Sheet | Columns | What it holds |
| --- | --- | --- |
| `run` | `section`, `name`, `value`, `unit` | the run's settings and statistics, one per row, grouped by `section` (`model`, `data`, `sampler`, `convergence`, `output`); the workbook holds numbers only, what each row means is described below (the terminal interface shows it on its status line) |
| `map` | `parameter`, `value` | the MAP draw: `logDensity` (the log posterior density), `rhoE` (buffer electron density, e⁻/Å³), `deltaRho1`, `deltaRho2`, `deltaRho3` (hydration-shell contrasts), `scale`, `bkgrndCorr` (detector scale and background), `exclVolCorr` (the profiled excluded-volume correction `c1`), `chi2` (reduced χ² **on the measured points**, `nRaw − 3` degrees of freedom: scale, background, `c1`; the grid CRYSOL and FoXS evaluate, whatever the binning) |
| `quantiles_<interval>` | `parameter`, `quantileLo`, `quantileHi`, `boundLo`, `boundHi` | the same parameters: the posterior quantile pair (default `2sigma`, the 2.28 and 97.72 percentiles; `runModel(seed; sigma = 1)` changes it, and the `run` sheet gives the percentiles as `quantileLoPct` and `quantileHiPct`) and the extreme draws that lie inside it |
| `stdevFromPrior` | `parameter`, `zMap`, `zQuantileLo`, `zQuantileHi` | for the four parameters with a prior (`rhoE`, `deltaRho1..3`): how many prior standard deviations (θ-space) the MAP value and the quantile pair lie from the prior mean |
| `modes` | `mode`, `share`, `logMass`, `logMassErr`, `chains`, `kept` | only when the chains settled in more than one posterior mode: each mode's share of the posterior mass by bridge sampling, its log mass and error (nats), its number of chains, and whether it keeps draws (`kept` is 0 for a share below 1e-4) |
| `optima` | `optimum`, `share`, `chains`, `started` | only when more than one local optimum carries mass: its share of the Laplace mass, the chains that ended there and how many of them started there |
| `formFactorLog` | `line` | text; only when form-factor parsing logged something |
| `data` | `q`, `I`, `sigma` | the curve the fit saw (Shannon-binned) |
| `model` | `q`, `iMap`, `quantileLo`, `quantileHi`, `boundLo`, `boundHi` | the MAP curve and the posterior quantile and bounds curves |
| `residuals` | `q`, `I`, `sigma`, `iMap`, `residual` | data, MAP curve and `(I − I_map)/sigma` |
| `hist_<parameter>` | `binLo`, `binHi`, `count` | the counts of one parameter's histogram (non-divergent draws), seven sheets |
| `draws` | `chain`, `draw`, `rhoE (e-/A^3)`, `deltaRho1..3 (0.03 e-/A^3)`, `scale`, `bkgrndCorr (a.u.)`, `exclVolCorr (c1)`, `chi2FitGrid`, `logDensity`, `divergent`, `treeDepth`, `nSteps`, `stepSize`, `acceptanceRate` | one tidy table, a row for each posterior draw of the pooled chains (frozen header, units in the header text): `draw` counts from 1 within its chain (the NUTS iteration is `nAdapt` + `draw`); the four sampled parameters; the quantities derived from each draw that the result already holds (nothing is recomputed: `chi2FitGrid` is the reduced χ² on the fitted, Shannon-binned grid, where `map`'s `chi2` is on the measured points); the sampler's flags of the draw (`divergent` is 1 for a divergent transition; a flag the statistics do not carry has no column). The `run` sheet's `drawsRows` row counts the rows |
| `ref_<name>` | `q`, `I` | a reference curve given to `results` |

**The `run` rows**, in order (a row is absent when the run did not record it):

- Sizes: `nAtoms` (atoms of the hydrogenated structure), `lmax` (highest spherical-harmonic degree of the scattering model), `nQRaw` (measured points), `nQChi2` (the measured points inside the fitted range, `q[1] ≤ q ≤ q[end]` of the fitted grid, that the reported χ² sums over, with `nQChi2 - 3` degrees of freedom: a point below the first fitted bin or above the last is not scored), `nQ` (points fitted after binning).
- Sampler settings: `nSamples` (NUTS iterations of each chain, warm-up included), `nAdapt` (the warm-up part), `rngSeed` (0 unless changed; the same seed reproduces the run), `quantileLoPct` and `quantileHiPct` (the percentiles of the interval that `sigma` asked for). `pmvFallbackUncert` (cm³ mol⁻¹, the uncertainty given to a non-biological buffer solute whose table row states none; the setting `PMV_FALLBACK_UNCERT`, not recommended to change).
- Shannon binning: `dmax` (Å, the maximum diameter of the atoms and hydration-shell beads), `channels` (q range × `dmax` / π, the number of independent Shannon channels), `rebinChannels` (bins per channel; 0 when the curve was fitted as measured), `rebinMeasured` and `rebinFitted` (points before and after), `rebinNonPositiveDropped` (bins with a non-positive mean that were dropped).
- Sampler statistics: `iterations` (post-warm-up transitions of the pooled chains), `meanAccept` (mean acceptance rate; the target is `TARGET_ACCEPT`), `treeDepthAvg` and `treeDepthMax`, `meanNSteps` (leapfrog steps per iteration), `stepSize` and `stepSizeMin` (median and minimum of the pooled chains' adapted step size; a value near 0.002 against 0.1 to 0.3 is a collapsed adaptation, the `stepCollapse` class of the retry ladder), `ebfmi` (energy-based fraction of missing information of the worst chain; below about 0.3 the momentum resampling explores poorly), `cavityFrac` (share of the hydration-shell volume carried by cavity beads; near 0 means `deltaRho3` has no likelihood and its posterior is its prior), `exclVolSat` (0, +1 if `c1` sat on its upper bound at the MAP, −1 on its lower), `divergenceRate` (share of divergent transitions).
- Retry trail: `retryCount`, `retryRungs` and the rows `attempt<k>...` of every sampler run (trigger class, seed, δ, iterations, R̂, ESS, divergent share, seconds); a log without them is read as before. The workbook's `run` sheet carries `retryCount`, `retryRungs` and the numeric `attempt<k>` rows (`Delta`, `NAdapt`, `NDraws`, `Rhat`, `Ess`, `Divergent`, `Seconds`) of the first 12 runs (`_RUN_ATTEMPTS_MAX`); `Class`, `Label` and `Seed` (text, and a 64-bit number) and runs beyond 12 are in the LOG only. The TUI describes `attempt<k><Field>` by the sentence of `attempt<Field>`.
- Retry ladder: `ladder` (whether it ran), `ladderClass` (the failure class of the last failed attempt), `ladderAttempts`, `ladderRungs` (JSON) and `ladderRung` (0 the base run, `i` a rung, -1 none); see the inference README, "The retry ladder".
- Output: `quantileLoPct` and `quantileHiPct` (above) and `drawsRows` (the rows of the `draws` sheet; the units of its columns are in their headers).
- Chains: `chainsPooled` (chains whose draws are kept) of `chainsRun`, `rhatMax` (worst rank-normalized split R̂ over the four parameters and the log density; 1.01 or above, the chains have not converged), `essMin` and `essTailMin` (smallest bulk and tail effective sample sizes; 400 or below, or not computable, the run counts as not converged too), then, when they apply, `modes` and `optima` (their counts, with the sheets above), `rewhitenedNats` (log-density gain when the chains found a better basin than the MAP search) and `retryFirstRhat` with `retryKept` (the first run's R̂ when it was rerun, and 1 if the rerun was kept).

## The run log

The section "Reading the logs (a guide)" below explains how to read this file and the statistics log, with a worked example and a checklist, and the two "Reference" sections after it list every row.

`writeLog(result; refChi2)` writes the run log: the file `<folder name>.LOG` of the output folder, **one file for the folder with a section for each run** (`=== fit3 ===`, named after the workbook, the folder's own name for `res.xlsx`); a second call replaces the run's own section. `results` always calls it last (there is no switch). The `report write` row of the timing table covers the building of the text; the final write of the file is after the table was formatted and in no row (a file cannot contain the time of its own last write, a few milliseconds). The statistics are written before it, so their time is the `statistics` row of the `plotting` group. It is what a benchmark needs and no more. The first line, `datetime`, stamps the last write (day, 24-hour time, offset from UTC). A section is, in this order: **the run** as flat rows `name`, spaces, a tab, `value` (the cells are padded with spaces to a multiple of 8 and followed by one tab, so the columns line up at any tab width and a line still splits on its tabs): BAYSOL `revision` (with `-dirty` when tracked files have uncommitted changes, so that a run is tied to a commit only when the tree is clean), the `julia` version, the `baysol` version with its release name (`v0.3.0-wʋsg_n_yɩɩda`: the `version` and the `release_name` keys of `Project.toml`, changed together at a release), the `refChi2` (the depositor's χ² with its method, if given), the kind of `structure` and the pdb2pqr cache, the conditions it was given (`temperatureC`, `ph`, `sigmaPh`, `energyEv`), the atoms, the model and data sizes, the sampler's settings and the seed, the fit (the reduced `chi2` on the measured points, the MAP of `rhoE`, `deltaRho1..3`, `scale`, `bkgrndCorr` and `c1`, their `z_` scores from the prior, whether `c1` sits on a bound) and the sampler's health (`divergenceRate`, `nDivergent`, `rhatMax`, `essMin`, `essTailMin`, `ebfmi`, acceptance, tree depth, leapfrog steps and ms/step, the chains, `modes`, `optima`, a retry or a re-whitening); **`--- timing ---`**, the timing table as the reports always showed it, for a person to read: the stages indented by level, with seconds, `% wall`, `(JIT)` and `(GC)` on every row and a `notes` column at the end of the row (short, on the same line, without brackets: what the stage's name carried, such as the NUTS iterations and leapfrog steps or the MAP search's starts, and its own note, such as `cache hit`), the wall clock first (it starts with the process, Linux; elsewhere with the load of BAYSOL, the `startup` being the time before `seedModel`), the `plotting` group, `report write` and `unaccounted`, then `GC:` (the process's total) and the two halves of the wall clock, `fit timing` (everything but the plotting) and `plot timing`; and last **`--- machine ---`** (`machine.os`, cpu and its clock, cores, Julia threads, memory, the load and the free memory when the run started, the free memory at the write and the process's peak resident set). A number that could not be computed (an E-BFMI of 0/0) has no row. `refChi2` is given to `results` as `refChi2 = "CRYSOL 1.37"`. Residual statistics (lag-1, runs z) are in no output; `bysl fits diagnose --residuals ID` prints them. The fitting-test scripts under `test/fitting_tests/` are deliberately self-contained examples of these calls.

The workbook has a `divergences` sheet (one row for each divergent transition of every attempt: attempt, chain, draw, phase, the four parameters, log density, its distance from the chain median, leapfrog steps, tree depth; header only if none). A run that fails after divergent transitions still writes its workbook with the `run` (`status`, `errorType`, `error`) and `divergences` sheets; a failed write is a `workbookError` row of the run log, and the run's own error is rethrown. `writeStatistics(result)` writes `statistics-<folder name>.LOG`, next to the run log, with the same `=== <run> ===` sections (a rerun replaces its own section, in one rewrite) and the same flat `name`, tab, `value` rows. `results` always writes it, before the run log. It is the **exact statistics of what the run did**, recorded by `Inference` as each phase finished (`Inference.StatBuffer`, `src/inference/statistics.jl`), never replayed or estimated: **one block for each attempt, in order** (`--- attempt 1: base run ---`, the retry with the longer warm-up, each ladder rung with `triggeredBy` the failure class, the `KinkDetected` stop and the sampled-c1 restart, the profiled fallback), each with the settings the attempt used (`targetAccept`, `nChains`, `nSamples`, `nAdapt`, `nDraws`, `rngSeed`, `chainStartRadii`, `c1Mode` profiled or sampled, the MAP search's limits), the MAP search (starts ok and made, modes, evaluations, the MAP in z, and for each optimum its −log π, Laplace log mass and the eigenvalues of the Hessian), a table with a row for each chain (start in posterior standard deviations, pooled and why, mode, divergences in the warm-up and the draws, adapted step size, mean and largest tree depth, leapfrog steps, acceptance, E-BFMI, seconds), R̂ and the bulk and tail ESS of each parameter and of log π, the gate (`rhatMax`, `essMin`, `essTailMin`, `nDivergent`, `divergentShare`, `gate` passed or what failed it), the stage timings of that attempt and a `next` row (what the run did after it and why); the file ends with `--- result ---`: the attempts, which one is kept and why (or `failed`). A value that was not recorded is `unavailable` with its reason, never a zero; a failure of the statistics is a `statisticsError` row and never fails the fit (a failed run still gets its partial statistics, with `failed`). What needs the model again (gradient accuracy, curvature, axis scans, L-BFGS replays, the reference curve's χ²) stays in the dev tool `bysl fits diagnose`. The values are appended to a buffer as they appear and flushed to a scratch file in the system's temporary folder at every phase boundary and whenever the buffer passes `statisticsCap` (0.01 % of the memory budget of the static build, between 64 KiB and 64 MiB), so a run's memory use stays bounded; `results` moves them into the section. A `runModel` call without `results` writes no statistics file (the scratch file is removed at exit).

## Reading the logs (a guide)

A fit leaves two plain-text logs in its output folder: **the run log** `<folder>.LOG` (written by [`writeLog`](@ref BAYSOL.Pipeline.writeLog)) and **the statistics log** `statistics-<folder>.LOG` (written by [`writeStatistics`](@ref BAYSOL.Pipeline.writeStatistics)). `results` writes both, the statistics first and the run log last. This part is a how-to: which file to open, how to read a real one, how to tell whether a fit worked and what to change when it did not. The reference tables of every row, with units and what counts as a bad value, come after it ("Reference: the run log" and "Reference: the statistics log").

### 1. The two files and when to open which

- **The run log is the answer sheet.** One short row for each fact: what was fitted, the fitted parameters, the χ², whether the sampler converged, how long it took. It is small enough to read in a minute and to compare between runs, and it is what the Results table of `test/fitting_tests/README.md` and the dev tools (`bysl results table`, `bysl results compare`) read. Open it first, always.
- **The statistics log is the flight recorder.** It records what the sampler did, **attempt by attempt** (an attempt is one pass of the sampler: the first run, then, when its checks failed, each repeat with changed settings), chain by chain, with far more numbers than anyone needs for a run that went well. Open it when the run log says a run failed, or passed with a number you do not like (a pinned parameter, a low `essMin`, divergences), because it says which chain, which attempt and which parameter is to blame.

Both files follow the same layout, so what follows holds for both:

- **One file for each folder**, whatever the number of runs in it. The first line is `datetime`, a tab and the stamp of the last write of the file (`19-11-2026 14:49:23 -0500`: day-month-year, 24-hour time, offset from UTC, worked out in `_logStamp` from the civil time rather than from the C library's `%z`, which prints the zone name on Windows). The stamp belongs to the file, not to a run.
- Each run has a section headed `=== <run> ===`, after a blank line. The run is named after the workbook: `res_fit3.xlsx` is `fit3`, `res.xlsx` is the folder's own name. A folder with several scripts (`fit1`, `fit2`) therefore has several sections in the same file.
- **A rerun replaces its own section and nothing else.** The file is read, the section of that name is swapped for the new lines (or added at the end when it is new), the stamp is renewed, and the file is written beside itself and renamed over the old one, so an interrupted write never leaves half a file. The other runs' sections stay exactly as they were.
- A row is `name`, spaces, one tab, `value`. The name is padded with spaces to a multiple of 8 characters so that the values line up in any viewer, and a line still splits on its tab (trim the padding). Numbers have 6 significant figures; flags are `true`/`false`, or `0`/`1` where the row says so.
- A **row that is missing means "does not apply"**, not zero (the run log has no `modeShareMax` row for a run with a single posterior mode, no `ebfmi` when it could not be computed). In the statistics log a value that was not recorded is the word `unavailable`, never a zero.
- Dashed headings divide a section into blocks: `--- timing ---` and `--- machine ---` in the run log; `--- attempt N: <label> ---` and `--- result ---` in the statistics log, whose blocks are in turn divided by `-- <name> --` lines.

### 2. A worked walkthrough: a converged run

This is `test/fitting_tests/SASDMJ9/SASDMJ9.LOG`, read from the top; rows are shown without their padding and some are left out. (This file was written before the `nQChi2` row and the readable `ladderRungs` line existed, so a fresh log has them and this one does not.)

```text
datetime        19-11-2026 14:49:23 -0500
=== SASDMJ9 ===
revision        02a565b-dirty
julia           1.12.7
refChi2         CRYSOL 1.37
structure       protein
pdb2pqrCache    hit
```

*Provenance.* `revision` ties the run to a commit, but `-dirty` means tracked files had uncommitted changes, so the run is not exactly reproducible from that commit (look for `-dirty` before you trust a before/after comparison of two logs). `refChi2` is the depositor's χ² and its program; BAYSOL never uses it, it is there to be compared with `chi2` below. `structure protein` says the structure was treated as protein; `pdb2pqrCache hit` says the protonated structure came from the cache, so the `pdb2pqr` timing row is near zero.

```text
temperatureC 20.0   ph 7.5   sigmaPh 0.1   energyEv 8050.92
nAtoms 2592   lmax 37   dmax 63.872   nQRaw 2048   nQ 137
nSamples 1000   nAdapt 300   rngSeed 0
c1Kink false   ladder base   ladderClass (empty)   ladderAttempts (empty)   ladderRung 0
```

*Setup.* Check that these are the conditions you meant: the buffer's temperature and pH, the X-ray energy, 2592 atoms, a curve of 2048 measured points that the sampler fitted as 137 binned points, 1000 iterations per chain of which 300 are warm-up (the part where the sampler tunes itself and whose draws are thrown away). `rngSeed 0` means that rerunning gives the same numbers. `c1Kink false`: the excluded-volume factor `c1` was handled as usual (fitted for each draw). `ladder base` with the empty `ladderClass`/`ladderAttempts` and `ladderRung 0` is the best possible entry: **the first attempt passed its checks and nothing was repeated.** (`ladderRungs` is only the menu of repeats that were available; it does not say what ran.)

```text
rhoE 0.336153   deltaRho1 -1.08707   deltaRho2 1.95645   deltaRho3 -6.12247
scale 8.11573e-6   bkgrndCorr 0.12526   c1 1.24844
chi2 0.850869
zRhoE -0.056   zDeltaRho1 -1.24   zDeltaRho2 4.37   zDeltaRho3 -0.89
c1Sat 0   cavityFrac 0.0028941
```

*The fit.* `chi2 0.85` is the reduced χ² of the best (MAP) curve; against `refChi2` 1.37 it is lower (section 5 says what that does and does not mean). The z scores say how far each parameter moved from what the buffer table predicted, in prior standard deviations: `zRhoE` is about 0 (the solvent density is what the buffer says), but `zDeltaRho2` is 4.4, so the data pushed the second hydration-shell contrast far from its prior; that deserves a sentence in a write-up, it is not a failure. `c1Sat 0`: `c1` (1.248) is inside its allowed interval, not pinned at an end. `cavityFrac` is tiny, so the third contrast has almost no influence on the curve.

```text
divergenceRate 0.0   nDivergent 0   rhatMax 1.00381   essMin 2106.6   essTailMin 2384.56
ebfmi 0.854734   meanAccept 0.959862   treeDepthAvg 2.90464   treeDepthMax 5
stepSize 0.460292   stepSizeMin 0.310131   iterations 5600
chainsPooled 8   chainsRun 8   modes 1   mapStartsOk 70   mapStartsTotal 70   mapModes 3
```

*Sampler health: the three gates.* These rows decide whether the run counts. `rhatMax` must be below 1.01 (here 1.004: the eight chains agree with each other). `essMin` and `essTailMin` must be above 400 (here 2107 and 2385: the 5600 kept draws are worth thousands of independent ones). The divergent share must be below 0.1 % (here 0). The other rows are context: the acceptance is near the 0.95 target, the trees are shallow (the limit is depth 10), the step size is 0.3 to 0.5 (a value near 0.002 would mean the adaptation collapsed) and `ebfmi` 0.85 is well above the 0.3 warning level. `chainsPooled 8` of `chainsRun 8`: no chain was thrown away. `modes 1` says all chains ended in one posterior mode. `mapModes 3` says the starting-point search found three different optima, but the chains, which started at several distances from the best one, all settled in the same mode, so the others do not matter here; with `modes` above 1 two more rows, `modeShareMax` and `modeShareMin`, appear.

```text
--- timing ---
wall clock   12.24   100.0   (7.0)   (0.7)   process start to end
  startup    4.30    35.1    ...
  sampling   4.47    36.5    (4.0)   (0.1)
  plotting   0.89    7.3     ...
--- machine ---
machine.os Linux aarch64-linux-gnu   machine.cpu apple-m2   machine.threads 4   machine.loadStart 1.57
```

*Timing and machine.* JIT is the time Julia spent compiling; in a fresh process it is most of the 12 s (here 7.0 s), so compare timings only between runs started the same way on a quiet machine (`machine.loadStart` is the load when the run began: a value above about 1 for each core spoils a timing).

**What the statistics log of this run shows** (`statistics-SASDMJ9.LOG`). One block, `--- attempt 1: base run ---`, with `triggerClass none` and `rung none` in `settings`. The `-- chains --` table has eight rows, all `pooled yes`, `kept 700`, `div 0`; the chains started 0, 4, 10 and 20 posterior standard deviations from the best optimum (`start σ`), on both sides, and all ended in `mode 1`. `-- gate --` ends with `gate passed`, `-- attempts --` has one row (`1  base run  kept`) and `-- result --` says `keptBecause  it passed its gates`. One thing the run log does not show: `-- residuals --` has `durbinWatson 0.63` and `runsZ -4.84`, meaning the residuals come in long stretches of one sign. The fit passes every gate and its χ² is below 1, yet the model misses a smooth feature of the curve, and only the statistics log says so.

### 3. A worked walkthrough: a failed run

A run that fails its checks after every repeat has no fit rows at all. This is the section of `test/fitting_tests/SASDAP8/SASDAP8.LOG`:

```text
=== SASDAP8 ===
status      failed
errorType   BAYSOL.Inference.NotConvergedError
error       NotConvergedError: the run did not converge: ladder exhausted:;
            base: the smallest tail ESS, 304.8, is not above 400.0;
            longer chains [marginal]: the smallest tail ESS, 304.8, is not above 400.0;
            longer chains + seed [marginal]: the worst R̂, 1.023, is not below 1.01;
            the smallest bulk ESS, 184.8, is not above 400.0; the smallest tail ESS, 47.3, ...
nSamples    14000   ph 7.6   ...
```

Read it like this. `status failed` with `NotConvergedError` is the sampler failing its gates, not a crash of the structure or file handling. The `error` row lists **every attempt** in order, each as `<attempt>: <the gates it missed>`: the base run had enough draws for R̂ but its tail ESS was 304.8 (needs more than 400); the repeat `longer chains` classed as `marginal` (a near miss) did not fix it; the last repeat, with a new seed, got worse (R̂ 1.023, bulk ESS 185, tail ESS 47). The word in brackets is the failure class (the sampler's own diagnosis, see the ladder in section 5). The `nSamples` row and the others after it are the settings recorded before the failure. Then open `statistics-SASDAP8.LOG`: it has one block for each of these attempts, with `triggeredBy` giving the reason it started, and the `-- chains --` and `-- bounds --` blocks of the last one show which chain strayed and which parameter sits at a prior bound.

A failure that is not `NotConvergedError` points elsewhere: `test/fitting_tests/SASDC57/SASDC57.LOG` section `fit2` has `errorType BAYSOL.Hydrogenator.Pdb2pqrError` and the message of pdb2pqr itself (a gap in the structure), so the problem is the input structure and no sampler setting will help. `errorType` is always the first thing to read.

### 4. Did my fit work? A checklist

Go through these in order, in the run log. A fit is **trustworthy** only if 1 to 3 pass; 4 to 7 say how to describe it.

1. **There are fit rows** (no `status failed`). If not, see section 3.
2. **`rhatMax` below 1.01.** R̂ compares the chains with each other; 1.01 or more means they have not settled on the same distribution.
3. **`essMin` and `essTailMin` above 400** (effective sample sizes: how many independent draws the correlated ones are worth, for the middle of the distribution and for its tails) **and `divergenceRate` below 0.001** (0.1 %; a divergent transition is a step where the sampler's numerical integration blew up, a sign of a sharp feature it cannot follow). A run that misses any of the three is repeated by the ladder and, if it still misses, fails: so a **logged fit that is present has passed all three**; the numbers still tell you how comfortably.
4. **`c1Sat`.** 0 is normal. `+1` or `-1` means the best `c1` sits at the end of its allowed interval (0.8 to 1.3, a deliberate hard bound): the data want a larger or smaller excluded-volume correction than the model allows. That is a finding, not an error, and it is not to be softened; check the structure (missing parts, wrong oligomer, ligands), the buffer and the q range.
5. **`c1Kink`.** `false` is normal. `true` means that the profile of `c1` had a kink (two competing solutions of `c1` for the same other parameters), so `c1` was sampled as a fifth parameter instead; the fit is valid. If `c1KinkFallback true` appears, the sampled-c1 run missed its gates and the plain run without the kink watch was kept instead (`c1KinkProblems` says what the first missed).
6. **`ladder`.** `base` is the ideal. A rung name (`delta 70`, `longer chains`) means the first attempt failed and that repeat passed: the result is valid, but check `ladderAttempts` for what was wrong at first and expect a slower run. Settings you gave yourself are never overridden by a rung when you set them (`CHAIN_START_RADII`, `RETRY_N_ADAPT`, `RETRY_N_DRAWS`).
7. **`modes`, `mapModes`, `zDeltaRho*`, `cavityFrac`.** A `modes` above 1 means the posterior has several separate peaks; read `modeShareMax`/`modeShareMin` for how much mass the main one has, and report the fit as multimodal. A z score beyond about 3 means that parameter was pulled far from its buffer prediction; a `cavityFrac` near 0 means `deltaRho3` is unconstrained by the data.

**When a run fails, which setting to try.** Match the failure text to a class (the ladder tries these itself, in this order, and stops after three repeats; do it by hand when you want a different outcome). Keywords are those of `runModel` (and the names in `settings.json`; see "The settings as keywords"):

| What the log says | Likely cause | Try |
|---|---|---|
| tail ESS or bulk ESS just under 400, R̂ under 1.05 (`[marginal]`) | too few draws | more draws: `nSamples`, `nAdapt` (positional arguments), `retryNAdapt`, `retryNDraws`; or another `rngSeed` |
| R̂ large and `stepSize` around 0.002, or deep trees (`stepCollapse`) | step-size adaptation collapsed | a lower target acceptance, `δ = 70`, then `35`, then `35` with the next seed |
| R̂ 1.05 or more and a `modes` row or chains with different `mode` in the statistics log (`splitChains`) | chains started far apart in a multimodal posterior | closer starts, `chainStartRadii = (2, 4, 6)`, then `(1, 2, 3)` with `retryNAdapt = retryNDraws = 4000`, then that with the next seed |
| divergent share 0.1 % or more with R̂ under 1.05 (`divergent`) | the sampler steps too boldly | a higher target acceptance, `δ = 99` (the ladder then also shortens the starts and lengthens the run) |
| divergences remain after `δ = 99` at 1 % or more (`structural`) | a kinked or sharp `c1` profile | sample `c1` (the last rung does it); check that the fitted q range (`qMin`, `qMax`) contains no point the model cannot fit |
| anything else (`generic`) | not diagnosed | longer chains and a new seed |
| `Pdb2pqrError`, an error before sampling | the input structure | fix the structure (gaps, odd residues); no sampler setting helps |

`retry = false` turns the whole ladder off (the first failure is final) and `ladder = ...` replaces its rungs (see the inference README, "The retry ladder").

### 5. Comparing `chi2` with the depositor's `refChi2`

`chi2` is the **reduced χ²**: the sum over the measured points of ((measured − model) / σ)², divided by the degrees of freedom `nQChi2 − 3` (`nQChi2` points, minus the scale, the background and `c1`, which are fitted for each draw). The sum runs over the raw measured points inside the range that was actually fitted, `q[1] ≤ q ≤ q[end]` of the fitted grid, and `nQChi2` is how many that is: a raw point below the first or above the last fitted bin is not scored. It is not `nQRaw` (all the points in the file) and not `nQ` (the points after binning, which is what the sampler fitted).

To compare with `refChi2` honestly:

- A reduced χ² near 1 means the model matches the data to within the stated errors; well above 1 means a misfit (or underestimated errors), well below 1 means overestimated errors or overfitting. A smaller number than the depositor's is **not** by itself "better".
- Compare like with like: the depositor's number comes from the program named in `refChi2` (CRYSOL, FoXS, ...), on **their** q range and number of points, which may differ from `nQChi2` (for example SASDWT5 and SASDMU4, noted in `test/fitting_tests/README.md`); and it is a point fit with its own free parameters, whereas BAYSOL reports the MAP of a posterior with an additional `c1`.
- Compare the **distribution**, not one fit, across entries: the Results table of `test/fitting_tests/README.md` (regenerated by `bysl results table --update`) puts `chi2`, `refChi2` and the gate rows side by side for every entry.

### 6. Finding things

From the shell (`LOG` rows are tab-separated, so `cut` and `awk -F'\t'` work; trim the padding):

```bash
grep -H "^chi2\|^rhatMax\|^essMin\|^ladder " test/fitting_tests/*/*.LOG | grep -v statistics     # the numbers of every entry
grep -L "^chi2" test/fitting_tests/*/*.LOG                          # files with a failed run (no fit rows)
grep -H "^status" test/fitting_tests/*/*.LOG                         # which sections failed
grep -H "^c1Sat\s*.*[1-9]\|^c1Kink\s*.*true" test/fitting_tests/*/*.LOG   # entries at a c1 bound, entries with a kink
awk '/^=== fit2 ===/{p=1;next} /^===/{p=0} p' SASDxxx.LOG            # one section of a file
grep -n "^--- attempt\|^gate" test/fitting_tests/SASDAP8/statistics-SASDAP8.LOG    # the attempts and their gate verdicts
```

(`grep -L "^chi2"` also lists a file whose other sections passed; open it to see which section failed.) The dev tools read the same files and never run a fit:

- `bysl results table` (`--update` to regenerate the Results table, `--check` to see that it is current) and `bysl results compare REV ...` (the working tree against git revisions or tags: `bysl results compare v0.4.0`) compare the run logs of different commits.
- `bysl fits diagnose --report ID[:tag]` prints the MAP search, step size, tree depth and modes; `--chains` every chain (start, mode, divergences, steps, acceptance); `--residuals` the residuals at the MAP. These **rerun the sampler** on the entry to build what the statistics log does not record (gradient accuracy, curvature, axis scans); the statistics log itself needs no rerun.
- In Julia, `BAYSOL.Inference.statParse` reads a statistics log back into data (`Inference.STAT_SECTIONS` lists the names and columns).

## Reference: the run log

Every row of a run section, in file order. *Unit* is empty for a pure number. *Bad value* says when to worry; "none" means a descriptive row. A row appears only when it applies.

### Provenance, structure, caches

| Row | Meaning | Unit | Bad value |
|---|---|---|---|
| `revision` | short git revision of the BAYSOL source; `-dirty` if tracked files had uncommitted changes, `unknown` outside a checkout | | `-dirty` (not reproducible from the commit alone) |
| `julia` | Julia version | | none |
| `baysol` | `v<version>-<release name>` of `Project.toml` | | none |
| `refChi2` | the reference χ² given to `results`, as text with its method (`CRYSOL 1.37`); never used by the fit | | none |
| `structure` | what the component table made of the input: `protein`, `nucleic` (DNA or RNA alone), `mixed` | | none |
| `pdb2pqrCache` | `hit`: the protonated structure came from `_cache/`; `miss`: pdb2pqr ran | | none (a miss costs time) |
| `componentDownloads` | residue names that needed a download of a component file | files | above 0 on a machine without network |

### Setup: conditions, choices, sizes, settings

| Row | Meaning | Unit | Bad value |
|---|---|---|---|
| `temperatureC`, `ph`, `sigmaPh`, `energyEv` | what `seedModel` was given: temperature, buffer pH and its uncertainty, X-ray energy | °C, –, –, eV | none |
| `qMin`, `qMax` | the fitted range was cropped to these (only when set) | Å⁻¹ | none |
| `sigmaScale` | factor the measured errors were multiplied by (only when not 1) | | far from 1 changes `chi2` by its square |
| `excludeQ` | excluded q intervals, `lo-hi; lo-hi` | Å⁻¹ | none |
| `nQInput`, `nQCropped`, `nQExcluded` | points given, left out by `qMin`/`qMax`, left out by `excludeQ` | points | none |
| `structureModel`, `structureChains` | the model number of a multi-model file, the chains kept (only when set) | | none |
| `addHydrogens` | `0`: the pipeline added no hydrogens | | none |
| `lmaxPinned` | `1`: `lmax` was set by hand, not from `q` | | none |
| `memoryHeadroom` | percent of the memory kept free in the scattering build | % | none |
| `forwardBlocks`, `forwardBlockQ` | the scattering build was cut into this many blocks of this many q values (1 block: all at once) | blocks, points | none |
| `forwardBudgetGib`, `forwardEstGib`, `forwardPeakGib` | memory budget, estimated size of one block, peak size after the build | GiB | peak above budget |
| `override<Setting>` | a setting this model got differently from its project (`model-settings.json`) | | none |
| `nAtoms` | atoms of the hydrogenated structure | atoms | none |
| `lmax` | highest spherical-harmonic degree of the scattering model | | none |
| `dmax` | diameter of the cloud of atoms and hydration-shell beads; fixes the Shannon binning | Å | none |
| `nQRaw` | measured points as read | points | none |
| `nQChi2` | raw points that `chi2` is summed over (inside the fitted range); `chi2` has `nQChi2 - 3` degrees of freedom | points | far below `nQRaw` (much of the curve not scored) |
| `nQ` | points fitted after Shannon binning | points | very few (under about 20) |
| `nSamples`, `nAdapt` | NUTS iterations of each chain, warm-up included; the warm-up part | iterations | `nAdapt` near `nSamples` leaves few draws |
| `rngSeed` | seed; the same seed reproduces the run | | none |
| `pmvFallbackUncert` | uncertainty given to a buffer solute whose table row states none | cm³ mol⁻¹ | none |
| `c1Kink` | `true`: `c1` had a kink and was sampled as a fifth parameter; `false`: profiled | | none (informational) |
| `c1KinkFallback`, `c1KinkProblems`, `c1KinkFallbackFailed` | after a kink: the plain profiled run was kept; the gates the sampled-c1 run missed; the gates the fallback missed too | | `c1KinkFallbackFailed` present |

### The retry ladder

| Row | Meaning | Unit | Bad value |
|---|---|---|---|
| `ladder` | `base`: the first run passed; a rung name (or its overrides as `KEY=value`): the repeat that passed; `failed`: all failed | | anything but `base` (read `ladderAttempts`) |
| `ladderClass` | failure class of each repeat that was made, in order, ` | `-separated; empty for `base` | | non-empty |
| `ladderAttempts` | for each failed attempt `<label>: <gates missed>`, ` | `-separated | | non-empty |
| `ladderRungs` | the menu: per class its rung names, classes separated by ` | ` (`stepCollapse: delta 70, delta 35, delta 35 + seed | ...`); what ran is in the three rows above | | none |
| `ladderRung` | number of repeats it took: 0 base, 1 first repeat, ..., -1 none passed | | above 0 |

### The fit (the MAP: the best draw by log density)

| Row | Meaning | Unit | Bad value |
|---|---|---|---|
| `rhoE` | solvent electron density the model used | in the units of the prior | none |
| `deltaRho1`, `deltaRho2`, `deltaRho3` | the three hydration-shell contrasts | in the units of the priors (`DRO_UNIT` = 0.03 converts to e⁻/Å³) | at a prior bound (see `bounds` in the statistics log) |
| `scale`, `bkgrndCorr` | overall intensity scale and constant background correction, solved by weighted least squares for each draw | intensity units | none |
| `c1` | excluded-volume correction factor, hard-bounded to 0.8 to 1.3 | | at a bound (`c1Sat`) |
| `chi2` | reduced χ² of the MAP curve on the `nQChi2` raw points, `Σ((I − model)/σ)² / (nQChi2 − 3)` | | far above 1 (misfit) or far below 1 (errors too large) |
| `zRhoE`, `zDeltaRho1`, `zDeltaRho2`, `zDeltaRho3` | distance of the MAP from the prior mean, in prior standard deviations | σ | beyond about 3: the data overrode the buffer prediction |
| `c1Sat` | 0 inside the bounds, +1 on the upper bound, −1 on the lower | | not 0 |
| `cavityFrac` | share of the hydration-shell volume carried by cavity beads | | near 0: `deltaRho3` has no likelihood |

### The sampler's health

| Row | Meaning | Unit | Bad value |
|---|---|---|---|
| `divergenceRate` | share of the pooled post-warm-up transitions that diverged | fraction | 0.001 or more fails the run |
| `nDivergent` | divergent transitions among the kept draws | draws | share 0.1 % or more |
| `rhatMax` | worst split R̂ (rank-normalised) over the four parameters and the log density | | 1.01 or more fails |
| `essMin`, `essTailMin` | smallest bulk and tail effective sample size over the same five | draws | 400 or below, or not computable, fails |
| `ebfmi` | energy-based fraction of missing information of the worst chain | | below about 0.3 |
| `meanAccept` | mean acceptance rate; target is `TARGET_ACCEPT`/100 | | far from the target |
| `treeDepthAvg`, `treeDepthMax` | NUTS tree depth of the pooled draws | levels | max at 10 (the limit) |
| `meanNSteps` | leapfrog steps for one iteration | steps | near 1000 (depth 10) |
| `stepSize`, `stepSizeMin` | median and minimum adapted step size of the pooled chains | | about 0.002 (collapsed) |
| `iterations` | post-warm-up transitions of the pooled chains | draws | none |
| `leapfrog` | leapfrog steps of the whole NUTS stage, warm-up and discarded chains included | steps | none |
| `msStep` | milliseconds per leapfrog step | ms | none (the cost of the model) |
| `chainsPooled`, `chainsRun` | chains whose draws were kept, of those run (chains started at optima included) | chains | fewer pooled than run |
| `mapStartsOk`, `mapStartsTotal` | L-BFGS starts that reached a finite optimum, of those made | starts | `Ok` well below `Total` |
| `mapModes` | distinct optima the starting-point search found | optima | none (see `modes`) |
| `modes` | posterior modes the chains settled in (1 when single) | modes | above 1: multimodal posterior |
| `modeShareMax`, `modeShareMin` | largest and smallest share of the posterior mass among the modes (rows with `modes`) | fraction | `Max` far below 1 |
| `optima` | local optima that carry mass (row when above 1 or when extra chains were started) | optima | none |
| `rewhitenedNats` | log-density gain when the chains found a better basin than the MAP search | nats | above 0 (the MAP search missed the best basin) |
| `retryFirstRhat`, `retryKept` | first run's R̂ when it was repeated; 1 if the repeat's draws were kept | | R̂ ≥ 1.01 |
| `retryCount` | number of sampler runs after the first (longer-warm-up retry, sampled-c1 restart, profiled fallback, ladder rungs); 0 when the first passed | runs | above 0 |
| `retryRungs` | number of rungs the ladder defines (all classes) | rungs | none |
| `attempt<k>Class`, `attempt<k>Label` | for run `k` (1 the first): what triggered it (`none`, `convergence`, `KinkDetected` or a ladder class) and its label | | `Class` other than `none` |
| `attempt<k>Seed`, `attempt<k>Delta`, `attempt<k>NAdapt`, `attempt<k>NDraws` | the seed, target acceptance (%), warm-up and post-warm-up iterations the run was given | | |
| `attempt<k>Rhat`, `attempt<k>Ess`, `attempt<k>Divergent`, `attempt<k>Seconds` | how it ended: worst R̂, smallest bulk/tail ESS, divergent share, wall seconds; no row for a run that was stopped before it finished (the kink watch) | | |

### The timing block

Written for a person to read, not to parse. Columns: `stage`, `seconds`, `% wall`, `(JIT)` (seconds spent compiling), `(GC)` (seconds of garbage collection) and `notes` (what the stage's name carried: NUTS iterations, leapfrog steps and ms/step, the MAP search's starts, `cache hit`). Rows are indented two spaces for each level. `wall clock` runs from the start of the process (Linux; elsewhere from the load of BAYSOL) to the end; `startup` is the part before `seedModel`; `static build` and `sampling` group the stages of `seedModel` and `runModel`; `plotting` the figures and the statistics write; `report write` the building of this log's text; `unaccounted` what no stage covers (mostly the first call's compilation). Then `GC:` (the process's total), `fit timing` (everything but the plotting) and `plot timing`. The final write of the file is in no row. A time below 0.01 s is in scientific notation, exactly 0 is `0`. A bad value is a big `unaccounted` share on a warm run, or a `(JIT)` share that differs from the run you compare with.

### The machine block

| Row | Meaning | Unit | Bad value |
|---|---|---|---|
| `machine.os`, `machine.cpu` | system and processor | | none |
| `machine.cpu_mhz` | clock the system reported (with frequency scaling it can be the idle clock) | MHz | none |
| `machine.cpus`, `machine.threads` | hardware threads, Julia threads | threads | `threads` 1 on a many-core machine |
| `machine.memory_gib`, `machine.free_gib_start`, `machine.free_gib_end` | total memory, free memory when the run started, free memory when the log was written | GiB | little free memory |
| `machine.peak_rss_gib` | peak resident set of the whole process since its start (`Sys.maxrss()`, JIT and structure loading included, not the fit alone); `unknown` if the system gives none | GiB | close to `machine.memory_gib` |
| `machine.loadStart` | load average when the run started | | above about 1 per core spoils a timing |

### A failed run

| Row | Meaning |
|---|---|
| `revision`, `julia`, `baysol` | as above |
| `status` | `failed`; there are no fit rows |
| `errorType` | the Julia exception type (`NotConvergedError` for missed gates after every repeat) |
| `error` | the message on one line, line breaks as ` | `, cut at 1000 characters; for `NotConvergedError` every attempt and the gates it missed |
| further rows | the scalar facts recorded before the failure (`ph`, `nSamples`, ...) |
| `workbook` / `workbookError` | the path of the workbook of divergent transitions, written when some had diverged / why it could not be written |

The timing and machine blocks follow as far as the run went; the run's statistics section is written too, with `failed` in its `result` block.

## Reference: the statistics log

The section of a run is a `--- attempt N: <label> ---` block for each attempt in order, then `--- result ---`. Attempts: the base run is 1; then the repeat with the longer warm-up, each ladder rung that ran (`ladder rung <name>`), the stop of the kink watch and the sampled-c1 restart, and the profiled fallback. Everything was recorded by the sampler as it happened; nothing is replayed or estimated (where `bysl fits diagnose` replays the model on a grid the log gives the same lines from the run's own draws, as proxies: see "Run statistics" of the inference README). A block is **scalars** (`name`, tab, `value` rows), a **table** (a tab-separated header, then one row for each item, ending at a blank line) or **text** (lines as `bysl fits diagnose` prints them). A recorder that fails writes a `statistics error` block (`statisticsError: <message>`) and never fails the fit. The divergent draws one by one are in the workbook's `divergences` sheet, not here. `Inference.STAT_SECTIONS` lists the names and columns.

*Whitened coordinates `w`* below are the sampled parameters rescaled by the MAP search's curvature, so that a Gaussian posterior has standard deviation 1 on every axis. "Nats" are units of log probability. *Bad* is when to look closer.

| Block (kind) | Row or column | Meaning | Unit | Bad value |
|---|---|---|---|---|
| `settings` (scalars) | `triggeredBy` | why this attempt started, as the gates the previous one missed (not on attempt 1) | | none |
| | `triggerClass`, `rung` | failure class and ladder rung that produced this attempt; `none` for the base run | | none |
| | `targetAccept` | dual-averaging target acceptance | % | none |
| | `nChains`, `nSamples`, `nAdapt`, `nDraws` | chains; iterations per chain; warm-up; kept draws, `nSamples − nAdapt` | | none |
| | `rngSeed` | seed of the attempt | | none |
| | `chainStartRadii` | start distance of the chains from the MAP, in posterior standard deviations, cycled over the chains | σ | none |
| | `c1Mode` | `profiled` or `sampled (fifth parameter)` | | none |
| | `kinkWatch` | whether the kink check ran | | none |
| | `mapNStarts`, `mapMaxIter` | starts of the MAP search; L-BFGS iteration limit | | none |
| `problem` (text) | header lines | the attempt's label, `nQ`, `nAtoms`, `lMax`, the tolerance of the `c1` solve, and the supports of the contrasts (`δρ₃ support`, `δρ₁,₂ support`) | | none |
| `map search` (text) | summary line | seconds; `nOk=<starts that reached an optimum>/<starts>`; `nModes` distinct optima; `whitened` (the sampler was whitened at the best one) | s | `nOk` well below the starts |
| | start lines | per L-BFGS start: `f` (minus log probability at the end; lowest is best), `iters`, `g_conv`/`iter_limit` (which stopping rule fired), `evals`, `|∇f|∞` (final gradient) or `infeasible` | | `iter_limit=true` on many starts |
| | Hessian line | eigenvalues of the curvature at the best optimum (floored at the constant named); a very small and a very large one = a parameter the data do not pin and one they pin hard | | none |
| | `distinct optima` | for each optimum its `f`, its position `ξ` (ρₑ, δρ₁, δρ₂, δρ₃), `H-eig` and its `log Laplace mass` with the difference from the best in nats | nats | several optima within a few nats of each other |
| `map search again` (text) | as `map search` | the same after a re-whitening, headed by its reason (numbered if repeated) | | none |
| `nuts` (text) | `NUTS:` line | seconds of the slowest chain; initial and final step size `ε`; mean leapfrog steps and tree depth; `frac(depth≥10)` share of trees at the limit; `diverged` count | s | `frac(depth≥10)` above 0 |
| | `mean nSteps by window` | mean leapfrog steps in the warm-up windows and the sampling | steps | not settling after the warm-up |
| | `mean accept`, `mean \|ΔH\|` | mean acceptance (should be near `targetAccept`/100); mean absolute energy error | | acceptance far from the target |
| `chains` (table, a row per chain) | `chain` | chain number | | none |
| | `start σ` | start of the chain, in posterior standard deviations from the MAP | σ | none |
| | `mode` | the posterior mode it settled in | | chains in different modes |
| | `pooled`, `kept` | `yes` when its draws are kept; post-warm-up draws kept | draws | `no` |
| | `div`, `div%` | divergent transitions after warm-up and their percentage of `kept` | draws, % | above 0.1 % |
| | `warm-up div`, `warm-up div%` | the same during warm-up (not counted by the gate) | draws, % | very high (a hard start) |
| | `ε`, `steps`, `accept` | mean step size, leapfrog steps and acceptance over the kept draws | | `ε` far below the other chains' |
| | `mean log π` | mean log posterior density of the chain | | well below the other chains' (stuck in a worse basin) |
| | `energy error sd`, `depth≥10`, `BFMI` | spread of the energy error; share of trees at the depth limit; E-BFMI of the chain | | `BFMI` below 0.3 |
| | `c1 at bound` | share of draws whose `c1` is within 10⁻⁶ of a bound | fraction | above 0 |
| | `gradient evals`, `non-finite` | gradient evaluations of the chain; those that were not finite | evals | many non-finite |
| | `note` | `not pooled: <reason>` or `chain stopped: <reason>` | | any note |
| `chain totals` (scalars) | `chainsRun`, `chainsPooled`, `pooledDraws` | chains run, pooled, draws in the pooled sample | | pooled < run |
| | `divergentDraws`, `warmupDivergentDraws` | divergences among the pooled draws (the gate's numerator); over the warm-up | draws | share 0.1 % or more |
| `kink check` (table, a row per chain; only when the watch ran) | `checks`, `drawsExamined`, `drawsTwoBasins`, `firedAtDraw` | checks made; draws the last one examined; how many had two `c1` basins; draw count at which the watch stopped the run (`none`) | draws | `firedAtDraw` not `none` (the run stopped and restarted with `c1` sampled) |
| `posterior` (text) | `post-warmup w: sd` | standard deviation of the draws on each whitened axis (1: the Laplace approximation is right) | | far above 1 (heavy tail or another mode) |
| | `cov(w) eigenvalues`, `skew`, `ESS` | eigenvalues of the covariance of `w` (all near 1 for a round posterior); skewness; effective sample size per axis | | eigenvalue far from 1; `\|skew\|` above 1 |
| | `ℓπ at L-BFGS mode` / `best draw` / `median draw` | log density at the mode and at the best and median draw (for a 4-D Gaussian the median is about 1.7 below the mode) | nats | a median much further down |
| | `sampled sd in z / Laplace σ_z` | sampled spread over the Laplace approximation's, per axis | | far from 1 |
| `bounds` (table, a row per sampled coordinate) | `coordinate` | `slvntEDns` (ρₑ), `deltaRho1..3`, `c1` when sampled | | none |
| | `median`, `sd` | of the draws | units of the coordinate | none |
| | `distanceSd` | distance of the median from the nearer end of the prior's range, in `sd` | σ | below about 2 |
| | `shareNearBound` | share of the draws within 0.1 `sd` of that end | fraction | above 0.05: pinned at a prior bound |
| `axes` (text) | ratio lines `w1`..`w4` | for each distance `s` along an axis (listed in the heading), the excess of minus log π over `s²/2`, divided by `s²/2` (1 = Gaussian); `unavailable` where fewer than 5 draws lie in that bin | | far from 1 |
| | `wN scan` lines | median and largest second derivative `f''` of the binned excess and where the largest sits; range of the re-profiled `c1` along the axis; `jumps` (neighbouring draws whose `c1` differ by more than 0.05); `c1-tol noise` is always `unavailable` | | `jumps` above 0 |
| | `local λ_max` | largest curvature seen between consecutive draws (a lower bound of the true one), the stable step size it implies (an upper bound), and the adapted `ε` | | adapted `ε` above the stable one |
| `correlation` (table) | one column per parameter | correlation of the sampled parameters over the pooled draws | | magnitude near 1 |
| `residuals` (scalars) | `residualSource`, `residualCount` | the best sampled draw (with its log π) whose residuals are tested; their number | | none |
| | `durbinWatson` | 2 for uncorrelated residuals, near 0 for a smooth systematic misfit | | below about 1 |
| | `runsCount`, `runsExpected`, `runsZ`, `runsP` | runs of equal sign observed; expected for independent residuals; their z score and two-sided p | | `runsZ` below about −3 (long stretches of one sign) |
| `convergence` (table, a row per parameter and `logDensity`) | `rhat`, `essBulk`, `essTail` | split R̂; bulk and tail effective sample sizes | , draws | 1.01 or more; 400 or below |
| | `sd`, `mcse` | standard deviation of the draws; Monte Carlo standard error of the mean, `sd/√essBulk` | units of the coordinate | `mcse` not small against `sd` |
| `gate` (scalars) | `rhatMax`, `essMin`, `essTailMin`, `nDivergent`, `divergentShare` | the three gate numbers | | as in the run log |
| | `gate` | `passed`, or `failed: <the gates missed>` | | `failed` |
| `modes` (scalars) | `modes` | posterior modes the chains settled in | | above 1 |
| | `modeWeights`, `modeLogMass`, `modeLogMassErr` | posterior mass share of each mode; its log mass and the error of the log mass (bridge sampling) | fraction, nats | large `modeLogMassErr` |
| | `weightsUncertain` | whether the bridge estimate is itself uncertain | | `true` |
| | `rewhitenedNats` | log-density gain when the chains found a better basin than the MAP search | nats | above 0 |
| `health` (scalars) | `stepSizeInitial`, `stepSizeReached` | mean step size at the start of the adaptation and at the end | | `Reached` about 0.002 |
| | `leapfrogTotal`, `leapfrogSampling` | leapfrog steps of all chains with warm-up; of the post-warm-up draws only | steps | none |
| | `leapfrogPerEss` | `leapfrogTotal / essMin`: the cost of one effective sample at the worst parameter | steps | hundreds or more |
| | `gradientEvals`, `nonFiniteEvals` | gradient evaluations of all chains; those that were not finite and were rejected | evals | many non-finite |
| | `curvatureSamples` | pairs of draws behind the `local λ_max` line | | none |
| | `c1AtLowerBound`, `c1AtUpperBound` | share of re-profiled `c1` within 10⁻⁶ of the bound | fraction | above 0 |
| `c1 search` (scalars) | `c1Solves`, `c1BrentIterations`, `c1BrentPerSolve` | solves of the one-dimensional `c1` problem; their Brent iterations; the mean | | `c1BrentPerSolve` much above 10 |
| | `c1ScanAtEdge` | solves whose coarse scan ended at an edge of the interval | solves | a large share of `c1Solves` |
| | `c1WlsErrors` | weighted least-squares failures inside the solves | | above 0 |
| `stage timings` (table) | `stage`, `seconds`, `jit`, `gc`, `notes` | the stages this attempt added to the timing block | s | none |
| `outcome` (scalars; only when something stopped or followed) | `stopped`, `next` | why the attempt ended early; what the run did after it and why | | none |
| `statistics error` (text) | `statisticsError: ...` | a recorder that failed (the fit is unaffected) | | any |
| `attempts` (table, end of the run) | `attempt`, `label`, `outcome` | each attempt and whether it was kept | | more than one row |
| `result` (scalars) | `attempts`, `keptAttempt`, `keptLabel`, `keptBecause` | how many attempts; which one is the result and why | | `attempts` above 1 |
| | `failed` | the failure text (a failed run only) | | present |
| | `statisticsFlushes`, `statisticsFlushSeconds` | flushes of the recorder to its scratch file and their time (the recorder's own bookkeeping) | count, s | none |

## The settings as keywords

**Every setting is a keyword.** The settings of `settings.json` are not the only way to give a value: each one is a keyword of `seedModel`, `runModel`, `results` or (in the terminal interface) `runProject`, named after the setting in lower case (`MAP_N_STARTS` is `mapNStarts`; the older keywords keep their names: `thickness` for `SHELL_THICKNESS`, `probe`, `sigma` for `VAL_SIGMA`, `δ` for `TARGET_ACCEPT`, `nAdapt` and `nSamples = N_ADAPT + N_DRAWS`, `tex`, `compile` and `formats` for the `FIGURES_*`), with the `params.jl` constant as its default, so a library user passes what the interface would have saved. `seedModel` takes the geometry, hydration-shell, prior and c1 settings, the data and structure settings (below) and (`thickness`, `probe`, `κ_δρ₁₂`, `κ_δρ₃`, `pmvFallbackUncert`, `bounds_δρ₁₂`, `mode_δρ₁₂`, `φ_max`, `exclVolCorrBounds`, `exclVolCorrEps`, `shellAreaPerPoint`, `shellMinPoints`, `shellSample`, `sasaNOcc`, `beadRayRange`, `beadRayDirs`), `runModel` the sampler (`sigma`, `δ`, `rngSeed`, `nChains`, `retryNAdapt`, `retryNDraws`, `chainStartRadii`, `optimumChainCap`, `optimumMinChains`, `optimumChainRadius`, `optimumChainFraction`, `mapMaxIter`, `mapNStarts`, `mapFSuccessive`, `mapOptimaKept`, `mapJitterRadii`, `mapJitterDirections`, `mapJitterMaxOptima`, `mapJitterWithinNats`, `basinRestartNats`, `harvestCover`, `harvestDivergent`, `ladder`: the retry ladder, a list of rungs `{name?, overrides}` that replaces the default `LADDER`, an empty list or `false` for none, also as JSON text or the path of a JSON file; see the inference README) and `results` the table precision `tableSigfigs`, `tex`, `compile`, `formats`, `plotTuiSizes` (with the folder `tuiDir` to write the sizes into) and the `style` (a `PlotStyle`, the plot look). The keywords that are new (everything of the sampler and the model that had none) are checked **as `loadSettings` checks the setting of the same name**: the type, the limits and the rules between settings (`MODE_δρ₁₂` strictly inside `BOUNDS_δρ₁₂`, `EXCL_VOL_CORR_EPS` within the width of `EXCL_VOL_CORR_BOUNDS`, `SASA_N_OCC` at most `SHELL_SAMPLE`, positive radii), and a bad value throws the same `InvalidSettingsError`, with the line `SETTING = value: what is wrong` that the file would give (its closing sentence says that the values were keywords). The older keywords keep their own errors. The constants of `params.jl` stay the single definition: the keyword's default is the constant, and nothing is a mutable global.

Three helpers turn a settings `Dict` (every setting by name, what the interface's `loadSettings` returns, or `Dict(n => default ...)`) into the keywords, to splat: `BAYSOL.seedKeywords(settings)` for `seedModel(...; seedKeywords(settings)...)` (24 keywords), `BAYSOL.runKeywords(settings)` for `runModel(seed, args...; runKeywords(settings)...)` (22) and `BAYSOL.resultsKeywords(settings)` for `results(...; resultsKeywords(settings)...)` (`tableSigfigs`, `tex`, `compile`, `formats`, `plotDir`, `latexCompiler` and the `style` of the `PLOT_*` settings). `nSamples` and `nAdapt` of `runModel` are positional, so `BAYSOL.runArguments(settings)` gives `(nSamples, nAdapt)` for `runModel(seed, runArguments(settings)...; runKeywords(settings)...)`. The table behind them is `SETTING_KEYWORDS` (setting, keyword, entry point); a test checks that every setting of the catalog is in it and that its keyword exists.

`runProject` of the terminal interface takes all of these keywords too (each defaults to `nothing`: take the project's `settings.json`; for the settings that may be `nothing` itself, `qMin`, `qMax` and `lMax`, the default is `:settings` and a `nothing` clears a saved value); a value overrides the file, and the merged set is checked once, before any model, with the checks of this module (`_applyKeywords!`), so a bad value or a broken rule fails the run with an `inputs` error.

### The data and the structure of a fit

Eight settings choose what is fitted, each a keyword of `seedModel` (and of `runProject`), a row of the catalog and, where it differs from its default, a row of the run's LOG and `run` sheet. **With every one at its default the seed is what it was before they existed** (a test compares the seeds and a seeded run).

| Setting | Keyword | Default | Meaning |
| --- | --- | --- | --- |
| `Q_MIN`, `Q_MAX` | `qMin`, `qMax` | none (`nothing`) | fit only the points with `qMin ≤ q ≤ qMax`, Å⁻¹; `Q_MIN` must be below `Q_MAX` |
| `SIGMA_SCALE` | `sigmaScale` | 1 | multiply the measured errors by this factor (above 0) |
| `EXCLUDE_Q` | `excludeQ` | `()` | ranges `((q_lo, q_hi), ...)` whose points are left out, `0 ≤ q_lo < q_hi` |
| `LMAX` | `lMax` | automatic (`nothing`) | pin the spherical-harmonic band limit (an integer at least 1) |
| `CHAINS` | `chains` | `()` (all) | keep only these chain ids (one character each, case counts) |
| `MODEL` | `model` | 1 | which model of a multi-model file (counted from 1 in file order) |
| `ADD_HYDROGENS` | `addHydrogens` | `true` | add hydrogens with PROPKA and pdb2pqr |

The three data keywords act first, on the measured curve, before the structure is touched and before the Shannon binning, so the channels, the band limit and the bias bound of the binning follow the range that is fitted, and the curve the range leaves is the measured curve of the run (the chi-squared and the plots on the measured grid are over those points; `nQRaw` counts them, and `nQInput`, `nQCropped` and `nQExcluded` say what was left out). A bad point inside an excluded range is never looked at. A range that leaves fewer than 3 points, or a curve that has fewer than 3 after the binning and the dropping of non-positive bins, is an `ArgumentError` that names `qMin`, `qMax` and `excludeQ` (the scale and the background are fitted, so 3 points are the least), where it was once a `WLSError` in the middle of the build. `qMin`, `qMax` and `lMax` take `nothing` for "no limit" and "automatic": in `settings.json` that is JSON `null`.

What the structure reader does, and what a keyword changes:

| | Today |
| --- | --- |
| Model of a multi-model file | the first whatever its number; `model` picks the k-th (a .pdb: its k-th `MODEL` block, written to its own file of the store; an mmCIF or download: the k-th BioStructures lists) |
| Chains | all; `chains` keeps some (a text filter on the .pdb before the hydrogens are added; a chain the file lacks is an error that lists the chains it has) |
| Ligands (heme, nucleotide triphosphates, sugars, glycerol), ions | part of the model as heavy atoms without hydrogens when the component table gives them a known element composition (`MolecularStructure.KEEP_LIGANDS`, owner 2026-11-11; the `ligands` keyword of `loadMolecule`); not a setting |
| Waters, `UNK` and other placeholders, residues of unknown composition | never part of the model; not a keyword: waters would count the hydration shell twice |
| Modified residues (`MSE`, `SEP`, `PSU`) | kept, hydrogenated through their standard parent or base |
| Alternate locations | the conformer BioStructures makes the default (highest occupancy, the first on a tie); not a keyword |
| Hydrogens already in the file | kept as they are when `addHydrogens` is off; with it on, pdb2pqr places the hydrogens |
| Hydrogens | `addHydrogens` (setting `ADD_HYDROGENS`) |
| Titration method (PROPKA or none) and force field | chosen from the residue content (PARSE, AMBER for a nucleic acid alone); a guardrail, not a setting |
| pH | the buffer's, `buffer.json` |

The functions are public in `BAYSOL` (reached qualified, like the other entry points: `BAYSOL.seedKeywords`, `BAYSOL.runKeywords`, `BAYSOL.runArguments`, `BAYSOL.resultsKeywords`, `BAYSOL.InvalidSettingsError`) and exported from `Pipeline`.

## The project folder, the settings file and the run

`loadSettings`, `settingsFile`, `loadBuffer`, `loadBufferPh` and `runProject` are not part of this module: the project folder, the files the terminal interface keeps (`settings.json`, `model-settings.json`, `buffer.json`, `model-references.json`) and the run folder are its business, and their Julia code lives with the interface, in `tui/julia/src/*.jl` (the package `BAYSOLRun`); see the section "The Julia side of the interface" of `tui/INTERNALS.md`. The module here reads no settings file: the caller passes the settings as keywords, or as the `Dict` that `seedKeywords`, `runKeywords`, `runArguments` and `resultsKeywords` take.

## Colours

A colour of a figure setting (`PLOT_COLOUR_*`, `PLOT_COMPARE_COLOURS`) is read by `colourRgb` (`colour-notation.jl`): a name that Colors.jl knows (the CSS and X11 names, any case, blanks ignored) or a code: `#rgb`, `#rrggbb`, `rgb(r, g, b)` (whole numbers 0 to 255), `hsl(h, s%, l%)` or `cmyk(c%, m%, y%, k%)`. The numbers of a code are read as written and rounded once, to 8 bits; `colourNotations` writes a colour in every notation with enough digits to be read back as the same 8-bit colour (the unit tests check every colour of the interface's list; the terminal interface has the same maths line for line, and both test it against the golden file `test/fixtures/colours/notations.json`). The long list of names that the picker of the terminal interface offers (about 4,200: CSS, X11, xkcd, Tailwind, Federal Standard 595C, NBS/ISCC, Winsor & Newton, Crayola, Paul Tol, Resene and government, international and university colours) is the interface's own and is not in this package: it saves a CSS name or a code as it is and any other name as the `#rrggbb` of its colour, so a `settings.json` never holds a name Julia does not know. How the list is made and the licence of each source: `tui/assets/data/colour-sets/README.md`.
