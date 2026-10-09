# Pipeline


|                      | contents                                                                                                                                      |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `Pipeline.jl`         | the module: imports, the module-level constants `DEFAULT_QUANTILES` (`"16-84"`, the default `quantiles` of `run_model` and the label `write_report` prints) and `DEFAULT_N_ADAPT` / `DEFAULT_N_DRAWS` / `DEFAULT_N_SAMPLES` (300 / 700 / 1000, the default NUTS iterations of `run_model`), the result types `MAPParams`, `MAPResult`, `QuantileBounds`, `QuantileParams`, `QuantileCurves`, `QuantileResult`, includes, exports |
| `SeedModel.jl`      | `seed_model`: resolve the structure, PROPKA + Pdb2pqr, SASA and the diameter of the scatterer cloud, `Inference.shannon_data` (binning and `lMax`), `Scattering.forward_cache`, `Inference.seed_sampler`; starts the run's `Timing.StageLog` |
| `RunModel.jl`       | `run_model`: `Inference.infer`, drop warmup, pick the MAP draw (highest non-divergent log density), compute parameter and curve quantiles |
| `ReportSections.jl` | `_write_run_info` (`=== Run ===`) and `_write_timing` (`=== Timing ===`) |
| `WriteReport.jl`    | `write_report` and the parameter order/labels it prints |

The package root re-binds `seed_model`, `run_model` and `write_report`, so they are reachable as `BAYSOL.seed_model` etc.; the result types are `BAYSOL.Pipeline.MAPParams` etc.:

```julia
using BAYSOL
seed = BAYSOL.seed_model(src, energy, q, I, σ, pH, σ_pH, solutes)   # rebin = 12 per Shannon channel, lMax from the structure
res  = BAYSOL.run_model(seed)                                        # 300 warm-up + 700 draws; run_model(seed, n_samples, n_adapt) to change
BAYSOL.write_report(res)
```

The report's sections, in order: `=== Run ===` (the structure and model sizes, the sampler settings, and how the measured curve was binned to the fitted one), `=== Diagnostics ===` (the sampler's statistics, the cavity fraction, whether c1 hit its bound, and the divergence rate), `=== MAP ===`, `=== Quantiles (lo-hi) ===`, `=== Standard deviations from prior (θ-space z-score) ===`, an optional `=== Form-Factor Parsing Log ===`, and `=== Timing ===` (see the Timing README). The `χ²` of the MAP section is the reduced χ² on the measured points, with the number of points less 3 (scale, background and c1) as its degrees of freedom, so it is on the grid CRYSOL and FoXS evaluate whatever binning the fit used. The residual statistics (lag-1, runs z) are not in the report; `test/utils/diagnose.tcl --residuals` prints them.
