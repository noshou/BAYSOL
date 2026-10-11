# utils

Shared helpers behind the tests: glue around the Julia package (reading reports, driving benchmark processes, inspecting a fit's sampler, regenerating a data file) and the two helper files the unit tests include.


| Script                   | What it does                                                                                                                                                                                                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compare.tcl`            | Compares fitting-test results (`test/fitting_tests/*/res*.txt`) between git revisions and the working tree: timing totals, χ² and parameter distributions, the fits with the deepest NUTS trees, optional per-fit CSV. With `--bench`, compares benchmark JSON files instead. The default baseline is the latest release (newest `v<digit>` tag). |
| `results_table.tcl`      | Generates the Results table of`test/fitting_tests/README.md` from the reports (`--update` rewrites it in place, `--check` exits 1 if it is stale, `--tsv FILE` writes every quantity read from every report, one row per report). Only the depositor's χ² column is kept by hand, in `test/fitting_tests/depositor_chi2.tsv`.                                                                    |
| `bench.tcl`              | The cold / steady-state benchmark driver (protocol below). Prepares a throwaway depot and repository copy (deleted afterwards, unless `--keep`), starts`child.jl` once per fit and writes one JSON result (to `test/baselines/results/` by default). **Only runs with `--approved`**, which must be passed only after the owner has approved that particular run. |
| `extract_formfactor.tcl` | Rebuilds`src/Scattering/form_factors.sqlite3` from xraydb's `xraydb.sqlite` (Waasmaier-Kirfel f0 and Chantler f1/f2). Offline; the result is checked in.                                                                                                                          |
| `common.tcl`             | Shared by the Tcl scripts, not run: the repository root, the report-number regex,`usage`, the front ends' command-line helpers (`split_args`, `check_specs`, `check_folders`, `list_fits`), the git / file helpers, `latest_release` / `baseline_for` and the symlink-safe `rm_tree`.                                                                                                                                                             |
| `report.tcl`             | Parses one fitting-test report (`res*.txt`) into a dict of numbers; used by `compare.tcl` and `results_table.tcl`.                                                                                                                                                                |
| `child.jl`               | The process`bench.tcl` measures: runs one fit twice in a fresh process and prints the timings as JSON, with the `run_model` defaults of the code it measures unless `--samples`/`--adapt` are given, and records the iterations used. Not run by hand.                                                                                                                                                           |
| `diagnose.jl`            | The Julia side of `dev/diagnose.tcl`: loads the fit's `Seed` and runs the chosen diagnostic.                                                                                                                                                                                           |
| `fit_seed.jl`            | `load_fit_seed(id, tag; seed_options)`: the `Seed` a fitting test would sample, built without fitting (`seed_options` adds keywords such as `rebin` to its `seed_model` call). Used by `diagnose.jl`, `child.jl` and the validations in `../validation/`.                                    |
| `seed_diagnostics.jl`    | The diagnostics themselves (generic over any`Inference.Seed`); covered by `test/unit_tests/units/test_seed_diagnostics.jl`.                                                                                                                                                         |
| `tests/`                 | The tcltest files for the Tcl scripts above (`*.test`, `helpers.tcl`, `data/`); run by `dev/tcltests.tcl`.                                                                                                                                                                   |
| `format.jl`              | The Julia side of `dev/format.tcl`: formats the Julia files with JuliaFormatter.jl (`.JuliaFormatter.toml`, environment `test/format`). |
| `ast_same.jl`            | The Julia side of `dev/linelen.tcl --verify`: compares Julia files before and after a re-wrap as syntax trees (comments, line breaks and the whitespace inside strings do not count). |
| `profile_seed.jl`        | The Julia side of `dev/profile.tcl`: profiles the second build of a fitting test's `Seed` and prints the samples by BAYSOL function.                                                                                                                  |
| `floatcompare.jl`        | `close_(a, b; atol)`: float comparison with an explicit per-call absolute tolerance. Included by the unit tests.                                                                                                                                                                  |
| `geometry.jl`            | Synthetic point-cloud geometry (`sph`, the witness lattice, the surface-atom cases). Included by `test_sasa.jl`.                                                                                                                                                                  |

```bash
tclsh test/utils/compare.tcl v0.2.0-soukouratou HEAD          # any revisions; the working tree is added last
tclsh test/utils/compare.tcl HEAD~2 HEAD --no-tree --csv out.csv
tclsh test/utils/compare.tcl --bench new.json                 # against the latest release's baseline in test/baselines/
tclsh test/utils/compare.tcl --bench baseline.json new.json
tclsh test/utils/results_table.tcl --update       # regenerate the Results table in test/fitting_tests/README.md
tclsh test/utils/results_table.tcl --check        # exit 1 if that table is stale
tclsh dev/diagnose.tcl --report SASDBS6:fit2_model3    # one diagnostic part; with none named all six run
tclsh test/utils/bench.tcl --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3
tclsh test/utils/extract_formfactor.tcl xraydb.sqlite src/Scattering/form_factors.sqlite3
```

Every Tcl script prints its usage with `--help`. They start with `#!/usr/bin/env tclsh`, so they can also be
run directly (`./test/utils/compare.tcl …`).

## Sampler diagnostics: reading the output of `dev/diagnose.tcl`

`dev/diagnose.tcl` has six parts. Two of them answer "where do this fit's divergences and slow mixing come from?": `--report` (one NUTS chain started at the MAP, with the MAP search, the Hessian and the shape of the posterior around it) and `--chains` (the eight chains `run_model` actually runs, one line each; `--retry 1` shows the longer rerun `infer` does when R̂ is above 1.01). The output below is a real run on SASDX52 (16,882 atoms, `lMax` 38, 137 binned points), at the defaults of `run_model` (300 warm-up, 700 draws, target acceptance 95 %). It is cut into numbered blocks, each followed by what the block is for and how SASDX52 reads. Lines left out are marked `[…]`.

```bash
tclsh dev/diagnose.tcl --report SASDX52
tclsh dev/diagnose.tcl --chains --seeds 6252506411145483830 SASDX52
tclsh dev/diagnose.tcl --chains --retry 1 --seeds 6252506411145483830 SASDX52
```

`6252506411145483830` is the `rng_seed` of the fit's own report (`=== Run ===`), so `--chains` replays that very run; without `--seeds` the seed is 7. The thread count does not change any number.

### Part 1: `--report`

**1. The fit.** What was loaded: the number of fitted points, atoms, `lMax`, the c1 tolerance, the support of the sampled contrasts, and the χ² of the deposited reference curve on our q set (a floor to compare the fit against).

```text
SASDX52   n_q=137  n_atoms=16882  lMax=38  c1 tol=1.0e-8
δρ₃ support = [-11.35, 2.839]   δρ₁,₂ support = [-10.0, 2.0]
reference curve on our q-set (n=409): χ²_red raw = 0.699, with free scale+offset = 0.701
```

**2. The MAP search and the NUTS run.** `n_ok` is how many of the 32 L-BFGS starts gave a result and `n_modes` how many distinct optima they found. The NUTS line is one chain started at the MAP: the step size ε before and after adaptation, the leapfrog steps and tree depth, and the number of divergent transitions. The window means show whether the trees grow or shrink during warm-up; acceptance should sit at the target (0.95) and `|ΔH|`, the energy error, should be small.

```text
MAP search: 0.0s  n_ok=32/32  n_modes=2  whitened=true
NUTS: 0.1s  init ε=1.6  final ε=0.3083  mean n_steps=10.5 mean depth=3.15  frac(depth≥10)=0.000  diverged=0
mean n_steps by window: [1:75]=11  [76:450]=12  [251:300]=12  [301:1000]=11
mean accept = 0.967   mean |ΔH| = 0.065
```

SASDX52: two optima, no divergences, acceptance 0.967 (target 0.95), no deep trees. This one chain is healthy; that is not what the eight chains show (Part 2).

**3. Is the Laplace whitening right?** The sampler works in coordinates `w` where the posterior is meant to be a unit Gaussian. `sd` should be near 1 for every axis; the eigenvalues of the draws' covariance say the same without the axes; `skew` away from 0 means a lopsided direction; `ESS` is the effective sample size per axis. The last two lines compare log π at the optimizer's mode with the draws (for a 4-D Gaussian the median draw sits about 1.7 below the mode) and the sampled spread with the Laplace one in the optimizer's coordinates.

```text
post-warmup w: sd = [0.9654, 1.126, 1.491, 1.084]   (1 = the Laplace whitening is right)
  cov(w) eigenvalues = [0.9196, 1.009, 1.178, 2.489]   skew = [0.001013, -0.3571, 1.161, -0.3481]   ESS = [434.1, 700, 281.2, 477.9]
ℓπ at L-BFGS mode = 855.8603   best draw = 855.8079   median draw = 854.0896   (4-D Gaussian: median ≈ mode − 1.7)
sampled sd in z / Laplace σ_z = [0.9654, 1.021, 1.007, 1.324]
```

SASDX52: the third whitened axis is 1.5 times wider than the Laplace guess, with skew 1.16 and the lowest ESS (281). The other axes are close to 1. The mode and the best draw agree to 0.05 nats.

**4. How far each parameter is from its support bound.** In posterior standard deviations. A parameter within a few sd of a bound is cut by the prior's support and its posterior is not Gaussian there.

```text
coordinate   median ξ       sd ξ     distance to nearest support bound / sd
  ρₑ         0.34062     0.00019        1.8e+03
  δρ₁       -0.22177      0.0781           28.5
  δρ₂        -3.2558        1.02           5.16
  δρ₃         1.5411       0.884           1.47
```

SASDX52: δρ₃ is 1.5 sd from its upper bound (2.839); the others are far from theirs.

**5. The 32 L-BFGS starts.** One line per start in the optimizer's coordinates: the final `f = −log π`, the iterations, whether it stopped on the gradient (`g_conv`) or on the iteration limit, how much the gradient changes between the working c1 tolerance and a much tighter one (a small value means the stop is not a gradient-error artefact) and c1 at the end. Starts that end on the same `f` found the same optimum.

```text
  start 1: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=0.00e+00 c1=1.0875
  start 2: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=3.17e-04 c1=1.0875
  start 3: f=-855.8603 iters=117 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=5.91e-06 c1=1.2335
  start 4: f=-831.7659 iters=119 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=1.43e-04 c1=1.0875
  […]  (28 more lines, same format)
```

SASDX52: 26 of the 32 starts end at `f = −831.77` (c1 1.0875) and 6 at `f = −855.86` (c1 1.2335), the better optimum by 24 nats in `f`. Most starts land in the poor one, which is why the search runs 32 and picks by Laplace mass.

**6. The Hessian at the mode.** Eigenvalues of the second derivative of `f` in the optimizer's coordinates (floor 1.0). Pass 1 is the Hessian used for whitening; pass 2 repeats it at several finite-difference step sizes to show it is stable.

```text
MAP Hessian eigenvalues (floor 1.0): pass 1 = [1, 3.81, 17.22, 1321]
  pass 2, step 0.30·σ_lap: [1, 2.961, 20.05, 1342]
  pass 2, step 0.10·σ_lap: [1, 2.957, 19.64, 1334]
  pass 2, step 0.03·σ_lap: [0.9996, 2.948, 19.59, 1333]
  pass 2, step 0.01·σ_lap: [1, 2.998, 19.6, 1333]
```

SASDX52: stable to the step size; the spread of eigenvalues (1 to 1333) is the conditioning that `w` has to undo.

**7. Shape along each whitened axis.** `Δf/(s²/2)` at displacements `s` (in whitened sd) from the mode: 1 everywhere is a Gaussian, above 1 is steeper than the whitening assumed (a wall), below 1 is flatter (a tail). The scans below it report, per axis, the noise from the c1 tolerance, the median and maximum curvature `f''` and the range of the profiled c1, with `jumps` counting discontinuities of c1 (a jump would break the gradient).

```text
Δf/(s²/2) along whitened axes (1 = Gaussian), s = -10,-5,-3,-2,-1,-0.5,0.5,1,2,3,5,10
  w1:        1        1        1        1        1        1        1        1        1        1        1        1
  w2:     3.67     1.65     1.05    0.995    0.985     0.99     1.01     1.02    0.988    0.851    0.727    0.714
  w3:     2.35       13     3.27     2.02     1.37     1.16     0.87    0.768    0.617    0.512    0.382    0.241
  w4:    0.384    0.589    0.717    0.797     0.89    0.942     1.06     1.13     1.29     1.47     1.99        5
  w1 scan: c1-tol noise=7.99e-10  f''(median)=1 f''(max)=1 at s=0.68  c1 range=[1.2327,1.2342] jumps=0
  w2 scan: c1-tol noise=9.36e-10  f''(median)=0.996 f''(max)=1.99 at s=-2.98  c1 range=[1.2046,1.2389] jumps=0
  w3 scan: c1-tol noise=9.11e-10  f''(median)=0.998 f''(max)=19.7 at s=-2.98  c1 range=[1.2170,1.2461] jumps=0
  w4 scan: c1-tol noise=8.50e-10  f''(median)=0.999 f''(max)=2.87 at s=2.98  c1 range=[1.2255,1.2420] jumps=0
```

SASDX52: w3 is a wall on its negative side (13 times a Gaussian at s = −5, local curvature 19.7 near s = −3) and a long flat tail on its positive side (0.24 at s = +10). c1 is smooth on all four axes (no jumps).

**8. The distinct optima.** Each optimum with its position ξ, the Hessian eigenvalues and its Laplace log-mass, `−f − ½ log det H`, and the difference from the best: a mode that merely exists is told from one that carries probability.

```text
distinct optima: 2
  mode 1: f=-855.860 ξ=[0.3406, -0.2077, -3.239, 1.172]  H-eig=[0.9998, 2.878, 19.36, 1332]  log Laplace mass=850.253 (Δ vs best = 0 nats)
  mode 2: f=-831.766 ξ=[0.3406, 0.753, 1.627, -5.62]  H-eig=[0.9683, 1.099, 3.675, 90.49]  log Laplace mass=828.831 (Δ vs best = -21.4 nats)
```

SASDX52: the second optimum is 21.4 nats lighter and carries no mass.

**9. Gradient error and the stable step size.** The first line is the error the c1 tolerance puts in the gradient NUTS uses, against the size of the gradient (error ≪ gradient means it is not the cause of trouble). The second is the largest curvature `λ_max` along the draws and the step size ε a leapfrog integrator is stable for at that curvature, against the ε the sampler adapted.

```text
gradient error from the c1 tolerance in w: min/median/max = [0, 2.904e-05, 0.0002562]  vs |∇ℓπ| median = 1.65   (posterior-scale gradient ≈ 1)
local λ_max(−∇²ℓπ) min/median/max = [0.9999, 1.2, 5.783]  → stable ε < [0.8317, 1.826] (worst, median);  adapted ε = 0.3083
```

SASDX52: the gradient error (median 2.9e-5, at most 2.6e-4) is four to five orders of magnitude below the gradient (median 1.65), and the adapted ε (0.31) is below the worst stable step (0.83).

### Part 2: `--chains`

One line per chain of `infer`, the chains `run_model` pools, for the run with the report's own `rng_seed`. Columns: `start σ`, the distance of the chain's start from the MAP in posterior sd (negative is the mirrored chain of a pair); `mode`, the posterior mode it settled in; `pooled`; `kept`, its post-warm-up draws that the pool keeps (a chain in a mode with no mass keeps none); `div` and `div%`, divergent transitions among them; `warm-up div`, divergences during warm-up (not part of the posterior); `ε`, `steps` and `accept`, its mean step size, leapfrog steps and acceptance; `mean log π`. After the table, every divergent draw: chain, iteration, ξ = (ρₑ, δρ₁, δρ₂, δρ₃), log π against the chain's median, leapfrog steps and tree depth.

**10. The run `run_model` does** (300 warm-up, 700 draws):

```text
SASDX52: 8 chains, 300 warm-up + 700 draws, rng_seed 6252506411145483830, δ 95
chain  start σ   mode  pooled  kept  div  div%  warm-up div       ε  steps  accept   mean log π
    1    +0.00      1  yes      700    0   0.0            3  0.2461   14.1   0.969       853.75
    2    +0.00      1  yes      700    0   0.0            2  0.2500   13.1   0.986       853.64
    3    +4.00      1  yes      700    0   0.0            4  0.2977   11.8   0.964       853.58
    4    -4.00      1  yes      700    1   0.1            1  0.4491    7.0   0.952       853.61
    5   +10.00      1  yes      700    0   0.0            2  0.3784   10.6   0.974       853.81
    6   -10.00      1  yes      700    0   0.0            3  0.5642    6.9   0.935       853.56
    7   +20.00      2  yes        0  no post-warm-up draws kept (negligible mode)
    8   -20.00      1  yes      700    8   1.1            4  0.5157    7.7   0.866       853.61
pooled kept draws: 4900, divergent: 9 (0.18 %)
divergent draws:
  chain 4 iteration 310  ξ = [0.34052, -0.2534, -1.9623, 2.797]  log π +848.93 vs chain median +854.02  steps 13  depth 3
  chain 8 iteration 757  ξ = [0.34063, -0.32957, -4.8003, -5.7236]  log π +855.24 vs chain median +854.07  steps 3  depth 1
  chain 8 iteration 763  ξ = [0.34058, -0.31519, -4.5421, -5.3301]  log π +855.16 vs chain median +854.07  steps 28  depth 4
  […]  (6 more, all chain 8, δρ₂ between −4.5 and −6.2 and δρ₃ between −5.0 and −6.2)
```

SASDX52: 8 of the 9 divergences are in chain 8 (the −20 sd start), which adapted to ε = 0.52 and has the lowest acceptance (0.866 against the 0.95 target); the MAP chains adapted to ε ≈ 0.25 and have none. The divergent draws of chain 8 lie in a region of δρ₂ ≈ −4.5 to −6.2 and δρ₃ ≈ −5.0 to −6.2, at log π close to the mode's. Chain 7 ends in the second optimum, which keeps no draws.

**11. The retry** (`--retry 1`: 2000 warm-up, 2000 draws, seeds derived from the run's, as `infer` does when R̂ is above 1.01):

```text
SASDX52: 8 chains, 2000 warm-up + 2000 draws, rng_seed 6252506411145483830, δ 95  (the rerun)
chain  start σ   mode  pooled  kept  div  div%  warm-up div       ε  steps  accept   mean log π
    1    +0.00      1  yes     2000   26   1.3            9  0.2622   11.7   0.909       853.64
    2    +0.00      2  yes     2000  886  44.3            7  0.1827    8.9   0.405       853.24
    3    +4.00      1  yes     2000    4   0.2            7  0.3180   10.7   0.957       853.55
    4    -4.00      1  yes     2000   16   0.8            8  0.3053   11.4   0.952       853.76
    5   +10.00      1  yes     2000    4   0.2            8  0.5052    6.5   0.917       853.73
    6   -10.00      1  yes     2000   23   1.1            8  0.2737   11.8   0.918       853.53
    7   +20.00      3  yes        0  no post-warm-up draws kept (negligible mode)
    8   -20.00      1  yes     2000    2   0.1            5  0.2619   12.3   0.965       853.53
pooled kept draws: 14000, divergent: 961 (6.86 %)
divergent draws (first 12 of 961):
  chain 1 iteration 3046  ξ = [0.3406, -0.39279, -4.999, -6.5333]  log π +854.76 vs chain median +853.96  steps 3  depth 1
  chain 1 iteration 3049  ξ = [0.3406, -0.36977, -4.8604, -6.2187]  log π +855.33 vs chain median +853.96  steps 4  depth 2
  […]  (10 more, all chain 1)
```

SASDX52: the longer run is worse, not better. The divergences go from 9 to 961 (6.9 %) and chain 2 alone has 886 of its 2000 draws divergent with acceptance 0.405; the 12 divergent draws listed lie in the same region as before (δρ₂ ≈ −4.7 to −5.5, δρ₃ ≈ −6.0 to −6.8, log π ≈ 853 to 855). `infer` compared the two runs by their worst R̂ and kept the first run, so the retry did not change the fit's result. A longer run seems to reach that region more often, but this single run does not show why.

### What SASDX52 shows

* The divergences are not the c1 tolerance (block 9) and not a discontinuity of the profiled c1: a one-off scan along the straight line from the mode to a divergent draw (a scratch script, not kept) gave c1 smoothly from 1.2335 to 1.1836 with no saturation.
* The same one-off scan found the fitted-grid χ² **lower** at the divergent point (57.96) than at the optimizer's mode (62.83), with a barrier between them (χ² 80.8). So the divergent region looks like a separate, narrow region of high density that the 32 L-BFGS starts did not report as an optimum, and that the chains may enter through the tail of w3 (the divergent draws sit at δρ₃ ≈ −5 to −6, far below the mode's 1.17).
* **The divergent region is a third mode.** A one-off L-BFGS run (scratch script, not kept) from four different divergent draws converged to the same point, ξ = (0.3406, −0.3314, −4.5116, −5.7881), with `f = −855.680` against `−855.860` at the main mode, so 0.18 nats higher in `f`. Its Hessian eigenvalues are (1, 13, 107, 13952) against (1, 3.1, 19.6, 1332) at the main mode, and its Laplace log-mass is about 847.3 against 850.2: about 2.9 nats lighter, roughly 5 % of the posterior mass by that approximation (a Laplace estimate, not a bridge-sampling one). The 32 L-BFGS starts of block 5 never reported it, and `n_modes` of block 2 is therefore 2 where it should be 3.
* Relative to the whitening, which comes from the main mode, the curvature in the new mode is about 4, 5.5 and 10.5 times higher on the last three axes. A chain whose warm-up settled on a large step (chain 8, ε = 0.52, acceptance 0.866) diverges when it enters; a chain with ε near 0.25 does not. The chains that wander in are grouped with the main mode, so the pooled draws carry that region at the weight the chains happened to give it, not a bridge-sampled one.
* A per-chain check on mean acceptance would have flagged chain 8 (0.866) and chain 2 of the retry (0.405), but dropping such a chain would remove real posterior mass, so it is not implemented. What to do about the missing mode (starts around the main mode at several radii, starts from outlying draws, a sampler of its own for the mode) is open.

## Requirements

Tcl 9 with Tcllib (`json`, `json::write`) for `compare.tcl` and `bench.tcl`, and the `sqlite3` package for
`extract_formfactor.tcl`. On Fedora: `dnf install tcl tcllib sqlite-tcl`. `bench.tcl` (and `dev/diagnose.tcl`)
also need `julia` on the `PATH` (or `JULIA=/path/to/julia`).

## Benchmarks: cold start and steady state

Performance claims in this repository are measured from a **cold state** and reported next to a **steady state**, so a speedup never comes from a cache that a user does not have on first use.

```bash
tclsh test/utils/bench.tcl --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3 SASDJ62
tclsh test/utils/compare.tcl --bench new.json     # against the latest release's baseline
```

The cold state's temporary directory is deleted when the run ends (also on failure; the links to your depot are unlinked, never followed); `--keep` leaves it in place.

### What "cold" wipes

`bench.tcl --state cold` never touches your real depot or repository. It builds, in a temporary directory:


| wiped (absent in the cold state)                                                                 | kept (a user has it after installing)                                                                                |
| -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| the Julia compiled caches (`compiled/`), so BAYSOL and its dependencies are precompiled for real | package sources, artifacts, registries (`packages/`, `artifacts/`, `registries/`, `clones/`)                         |
| `_cache/` (downloaded PDBs, `.pka` and protonated-PDB outputs): propka and pdb2pqr run for real  | the provisioned conda environment (`conda_environments/`): provisioning is a one-off network cost, not measured here |
| result files (`res*.txt`, figures), `docs/`, `sources/`, `manuscript/`, any local sysimage       | tracked and untracked-unignored files of the working tree                                                            |

### What is reported

For each fit, in a fresh process (`child.jl` does the fit **twice** in one process):

- **install**: `Pkg.instantiate()` + `Pkg.precompile()` seconds (zero extra work in the warm state);
- **using BAYSOL**: loading the precompiled package;
- **first fit**: script prelude and `seed_model` (`seed_s`), then `run_model` (`run_s`), with the per-stage
  seconds, compile seconds and GC seconds from the pipeline's own `Timing` log;
- **steady fit**: the second fit, with everything already compiled.

Keep the two apart: first-fit minus steady-fit is compilation, and PrecompileTools-style work trades first-fit time for install time, so both rows must be compared. Never quote a warm-state number as what a user gets. The report convention of the fitting tests (wall clock excluding propka and pdb2pqr) is unchanged; in the cold state those stages run for real and appear as their own rows.

### Rules

- **Benchmarks are only run with the repository owner's explicit approval, per run, because they need a quiet machine.** Timings are only meaningful when nothing else is using the CPU, and AI agents tend to start a benchmark without checking whether the machine is quiet. `bench.tcl` therefore does nothing but print its plan unless `--approved` is passed, and `--approved` is added only after the owner has said yes to this run, which means they have confirmed the machine is quiet. It is a small safeguard against careless runs, not a security measure.
- One process at a time, a quiet machine (for example: check for `DisplayLinkManager` and `baloo` CPU use first), no parallel runs.
- Compare like with like: a cold run against a cold run of an earlier commit (use `git worktree`/`git stash` to build the earlier tree), never against warm numbers or the committed `res*.txt` timings, which are warm-cache.
- [`../baselines/`](../baselines/README.md) holds the machine-specific reference run of each release (the default for `compare.tcl --bench` is that of the latest release) (host and CPU are recorded in `meta`); compare only within a host.
