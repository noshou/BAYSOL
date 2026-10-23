# Pipeline

The three entry points, re-bound by the package root as `BAYSOL.seed_model`, `BAYSOL.run_model` and `BAYSOL.write_report`:

```julia
using BAYSOL
seed = BAYSOL.seed_model(src, energy, q, I, σ, pH, σ_pH, solutes) # rebin = 12 per Shannon channel, lMax from the structure
res  = BAYSOL.run_model(seed) # 300 warm-up + 700 draws; run_model(seed, n_samples, n_adapt) to change
BAYSOL.write_report(res)
```


| File           | Contents                                                                                                                                                                                                                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Pipeline.jl`  | the module: constants `DEFAULT_QUANTILES` (`"16-84"`), `DEFAULT_N_ADAPT` / `DEFAULT_N_DRAWS` / `DEFAULT_N_SAMPLES` (300 / 700 / 1000), the result types `MAPParams`, `MAPResult`, `QuantileBounds`, `QuantileParams`, `QuantileCurves`, `QuantileResult` (as `BAYSOL.Pipeline.MAPParams` etc.) |
| `SeedModel.jl` | `seed_model`                                                                                                                                                                                                                                                                                   |
| `RunModel.jl`  | `run_model`                                                                                                                                                                                                                                                                                    |
| `Report.jl`    | `write_report` and the `=== Run ===` and `=== Timing ===` sections                                                                                                                                                                                                                             |

## The stages

`seed_model` (every step is a named stage of the `Runtime.StageLog`, cache hits marked):

1. resolve the structure (`MolecularStructure`), look its residue names up (`components`), run the `structure checks` (reused chain ids, duplicate atoms, dummy-like models) and choose the hydrogenation from the content (`classify`);
2. `Hydrogenator`: PROPKA unless the structure is a nucleic acid alone, then pdb2pqr (PARSE, or AMBER for a nucleic acid alone), with modified residues hydrogenated through their parent;
3. the solvent-accessible surface and the diameter `D` of the scatterer cloud (atoms **and** beads), `Utils.Shannon` binning of the curve to `rebin` bins per channel `π/D`, and `lMax = ⌈q_max D⌉`;
4. `Scattering.forward_cache` (the Gram matrix), the priors from the buffer `solutes` (`BulkElectronDensity.ρₑ`), and `Inference.seed_sampler`.

`run_model` calls `Inference.infer` (8 chains, MAP search, harvest, mode pooling, one R̂ retry), drops each chain's warm-up, picks the MAP draw (highest non-divergent `log π`) and computes the quantile intervals and bands. `write_report` prints only statistics meaningful to a user; developer diagnostics live in the dev tools (`bb diagnose`).

## The report

Sections, in order: `=== Run ===` (structure and model sizes, sampler settings, the Shannon binning, then the sampler's statistics, cavity fraction, whether `c1` hit its bound, divergence rate), `=== Data (Shannon) ===`, `=== MAP ===`, `=== Quantiles (lo-hi) ===`, `=== Standard deviations from prior (θ-space z-score) ===`, an optional `=== Form-Factor Parsing Log ===` and `=== Timing ===`. The χ² of the MAP section is the reduced χ² **on the measured points** with `n_raw − 3` degrees of freedom (scale, background, `c1`), the grid CRYSOL and FoXS evaluate, whatever the binning. Each timing stage's note is wrapped on lines of its own under it (80 columns); older reports have name, note and seconds on one line and the parsers in `dev/` read both. Residual statistics (lag-1, runs z) are not in the report; `bb diagnose --residuals ID` prints them. The fitting-test scripts under `test/fitting_tests/` are deliberately self-contained examples of these three calls.
