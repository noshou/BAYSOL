# utils

Shared helpers behind the tests: glue around the Julia package (reading reports, driving benchmark processes, inspecting a fit's sampler, regenerating a data file) and the two helper files the unit tests include.


| Script                   | What it does                                                                                                                                                                                                                                                                                                                                                     |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `compare.clj`            | Compares fitting-test results (`test/fitting_tests/*/res*.txt`) between git revisions and the working tree: timing totals, χ² and parameter distributions, the fits with the deepest NUTS trees, optional per-fit CSV. With `--bench`, compares benchmark JSON files instead. The default baseline is the latest release (newest `v<digit>` tag).              |
| `results_table.clj`      | Generates the Results table of`test/fitting_tests/README.md` from the reports (`--update` rewrites it in place, `--check` exits 1 if it is stale, `--tsv FILE` writes every quantity read from every report, one row per report). Only the depositor's χ² column is kept by hand, in `test/fitting_tests/depositor_chi2.tsv`.                                  |
| `bench.clj`              | The cold / steady-state benchmark driver (protocol below). Prepares a throwaway depot and repository copy (deleted afterwards, unless`--keep`), starts`child.jl` once per fit and writes one JSON result (to `test/baselines/results/` by default). **Only runs with `--approved`**, which must be passed only after the owner has approved that particular run. |
| `extract_formfactor.clj` | Rebuilds`src/Scattering/form_factors.sqlite3` from xraydb's `xraydb.sqlite` (Waasmaier-Kirfel f0 and Chantler f1/f2). Offline; the result is checked in.                                                                                                                                                                                                         |
| `common.clj`             | Shared by the Babashka scripts, not run: the repository root, the report-number regex,`usage`, the front ends' command-line helpers (`split-args`, `check-specs`, `check-folders`, `list-fits`), the git / file helpers, `latest-release` / `baseline-for`, the symlink-safe `rm-tree`, and the C-style number formatting (`fmt`) the tools' output depends on.  |
| `report.clj`             | Parses one fitting-test report (`res*.txt`) into a map of numbers (its keys in first-seen order); used by `compare.clj` and `results_table.clj`.                                                                                                                                                                                                                 |
| `child.jl`               | The process`bench.clj` measures: runs one fit twice in a fresh process and prints the timings as JSON, with the `run_model` defaults of the code it measures unless `--samples`/`--adapt` are given, and records the iterations used. Not run by hand.                                                                                                           |
| `diagnose.jl`            | The Julia side of`dev/diagnose.clj`: loads the fit's `Seed` and runs the chosen diagnostic.                                                                                                                                                                                                                                                                      |
| `fit_seed.jl`            | `load_fit_seed(id, tag; seed_options)`: the `Seed` a fitting test would sample, built without fitting (`seed_options` adds keywords such as `rebin` to its `seed_model` call). Used by `diagnose.jl`, `child.jl` and the validations in `../validation/`.                                                                                                        |
| `seed_diagnostics.jl`    | The diagnostics themselves (generic over any`Inference.Seed`); covered by `test/unit_tests/units/test_seed_diagnostics.jl`.                                                                                                                                                                                                                                      |
| `tests/`                 | The`clojure.test` files for the scripts above and the dev front ends (`*_test.clj`, `helpers.clj`, `data/`); run by `dev/tests.clj`.                                                                                                                                                                                                                             |
| `format.jl`              | The Julia side of`dev/format.clj`: formats the Julia files with JuliaFormatter.jl (`.JuliaFormatter.toml`, environment `test/format`).                                                                                                                                                                                                                           |
| `ast_same.jl`            | The Julia side of`dev/linelen.clj --verify`: compares Julia files before and after a re-wrap as syntax trees (comments, line breaks and the whitespace inside strings do not count).                                                                                                                                                                             |
| `profile_seed.jl`        | The Julia side of`dev/profile.clj`: profiles the second build of a fitting test's `Seed` and prints the samples by BAYSOL function.                                                                                                                                                                                                                              |
| `floatcompare.jl`        | `close_(a, b; atol)`: float comparison with an explicit per-call absolute tolerance. Included by the unit tests.                                                                                                                                                                                                                                                 |
| `geometry.jl`            | Synthetic point-cloud geometry (`sph`, the witness lattice, the surface-atom cases). Included by `test_sasa.jl`.                                                                                                                                                                                                                                                 |

```bash
bb compare v0.2.0-soukouratou HEAD          # any revisions; the working tree is added last
bb compare HEAD~2 HEAD --no-tree --csv out.csv
bb compare --bench new.json                 # against the latest release's baseline in test/baselines/
bb compare --bench baseline.json new.json
bb results-table --update       # regenerate the Results table in test/fitting_tests/README.md
bb results-table --check        # exit 1 if that table is stale
bb diagnose --report SASDBS6:fit2_model3    # one diagnostic part; with none named all six run
bb bench --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3
bb extract-formfactor xraydb.sqlite src/Scattering/form_factors.sqlite3
```

Every script prints its usage with `--help`. They start with `#!/usr/bin/env bb`, so they can also be
run directly (`./test/utils/compare.clj …`).

## Sampler diagnostics: reading the output of `dev/diagnose.clj`

`dev/diagnose.clj` has six parts. Two of them answer "where do this fit's divergences and slow mixing come from?": `--report` (one NUTS chain started at the MAP, with the MAP search, the Hessian and the shape of the posterior around it) and `--chains` (the chains `run_model` actually runs, one line each: eight at the start, then up to a few more started at optima that carry mass; `--retry 1` shows the longer rerun `infer` does when R̂ is above 1.01). The output below is a real run on SASDX52 (16,882 atoms, `lMax` 38, 137 binned points), at the defaults of `run_model` (300 warm-up, 700 draws, target acceptance 95 %). It is cut into numbered blocks, each followed by what the block is for and how SASDX52 reads. Lines left out are marked `[…]`.

```bash
bb diagnose --report SASDX52
bb diagnose --chains --seeds 6252506411145483830 SASDX52
bb diagnose --chains --retry 1 --seeds 6252506411145483830 SASDX52
```

`6252506411145483830` is the `rng_seed` of the fit's own report (`=== Run ===`), so `--chains` replays that very run; without `--seeds` the seed is 7. The thread count does not change any number.

### Part 1: `--report`

**1. The fit.** What was loaded: the number of fitted points, atoms, `lMax`, the c1 tolerance, the support of the sampled contrasts, and the χ² of the deposited reference curve on our q set (a floor to compare the fit against).

```text
SASDX52   n_q=137  n_atoms=16882  lMax=38  c1 tol=1.0e-8
δρ₃ support = [-11.35, 2.839]   δρ₁,₂ support = [-10.0, 2.0]
reference curve on our q-set (n=409): χ²_red raw = 0.699, with free scale+offset = 0.701
```

**2. The MAP search and the NUTS run.** `n_ok/n_starts` is how many of the L-BFGS starts made gave a result (64 random starts, then a second round of jittered starts around the optima of the first; block 5 lists the 64) and `n_modes` how many distinct optima they found. The NUTS line is one chain started at the MAP: the step size ε before and after adaptation, the leapfrog steps and tree depth, and the number of divergent transitions. The window means show whether the trees grow or shrink during warm-up; acceptance should sit at the target (0.95) and `|ΔH|`, the energy error, should be small.

```text
MAP search: 0.1s  n_ok=70/70  n_modes=2  whitened=true
NUTS: 0.1s  init ε=1.6  final ε=0.4087  mean n_steps=11.8 mean depth=3.33  frac(depth≥10)=0.000  diverged=2
mean n_steps by window: [1:75]=12  [76:450]=12  [251:300]=10  [301:1000]=12
mean accept = 0.927   mean |ΔH| = 0.070
```

SASDX52: two optima, two divergent transitions, acceptance 0.927 (target 0.95), no deep trees, and a final ε of 0.41 against 0.24 and 0.26 for the two chains of Part 2 that start at the MAP. This one chain is mostly healthy; the divergences show up in the chains of Part 2.

**3. Is the Laplace whitening right?** The sampler works in coordinates `w` where the posterior is meant to be a unit Gaussian. `sd` should be near 1 for every axis; the eigenvalues of the draws' covariance say the same without the axes; `skew` away from 0 means a lopsided direction; `ESS` is the effective sample size per axis. The last two lines compare log π at the optimizer's mode with the draws (for a 4-D Gaussian the median draw sits about 1.7 below the mode) and the sampled spread with the Laplace one in the optimizer's coordinates.

```text
post-warmup w: sd = [0.9863, 1.556, 2.145, 1.218]   (1 = the Laplace whitening is right)
  cov(w) eigenvalues = [0.9438, 0.98, 1.236, 6.32]   skew = [0.2042, -0.1343, 1.292, -0.2866]   ESS = [568.7, 44.39, 86.5, 209.9]
ℓπ at L-BFGS mode = 855.8603   best draw = 855.7956   median draw = 854.1010   (4-D Gaussian: median ≈ mode − 1.7)
sampled sd in z / Laplace σ_z = [0.9863, 1.083, 1.074, 2.047]
```

SASDX52: the second and third whitened axes are 1.6 and 2.1 times wider than the Laplace guess, the third has skew 1.29, and the effective sample sizes of those two axes are 44 and 87 out of 700 draws. In the optimizer's coordinates the last axis is 2.0 times wider. The mode and the best draw agree to 0.07 nats, and the median draw sits 1.76 below the mode, as a Gaussian would.

**4. How far each parameter is from its support bound.** In posterior standard deviations. A parameter within a few sd of a bound is cut by the prior's support and its posterior is not Gaussian there.

```text
coordinate   median ξ       sd ξ     distance to nearest support bound / sd
  ρₑ         0.34061    0.000194       1.76e+03
  δρ₁       -0.23194      0.0834           26.8
  δρ₂        -3.4491         1.1           4.97
  δρ₃         1.4416        2.13          0.657
```

SASDX52: δρ₃ is 0.66 sd from its upper bound (2.839) and has a wide posterior (sd 2.13); δρ₂ is 5 sd from its bound and the others are far from theirs.

**5. The 64 L-BFGS starts.** One line per start in the optimizer's coordinates: the final `f = −log π`, the iterations, whether it stopped on the gradient (`g_conv`) or on the iteration limit, how much the gradient changes between the working c1 tolerance and a much tighter one (a small value means the stop is not a gradient-error artefact) and c1 at the end. Starts that end on the same `f` found the same optimum.

```text
  start 1: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=0.00e+00 c1=1.0875
  start 2: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=3.17e-04 c1=1.0875
  start 3: f=-855.8603 iters=117 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=5.91e-06 c1=1.2335
  start 4: f=-831.7659 iters=119 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=1.43e-04 c1=1.0875
  […]  (60 more lines, same format)
```

SASDX52: 52 of the 64 starts end at `f = −831.77` (c1 1.0875) and 12 at `f = −855.86` (c1 1.2335), the better optimum by 24 nats in `f`. Most starts land in the poor one, which is why the search runs many starts and picks by Laplace mass. The list reports two optima only; the third optimum of the closing list is not among them.

**6. The Hessian at the mode.** Eigenvalues of the second derivative of `f` in the optimizer's coordinates (floor 1.0). Pass 1 is the Hessian used for whitening; pass 2 repeats it at several finite-difference step sizes to show it is stable.

```text
MAP Hessian eigenvalues (floor 1.0): pass 1 = [0.6629, 3.194, 19.44, 1319]
  pass 2, step 0.30·σ_lap: [1, 2.967, 20.16, 1342]
  pass 2, step 0.10·σ_lap: [1, 2.957, 19.65, 1334]
  pass 2, step 0.03·σ_lap: [0.9999, 2.966, 19.57, 1332]
  pass 2, step 0.01·σ_lap: [1, 2.97, 19.54, 1330]
```

SASDX52: pass 2 is stable to the step size; the spread of eigenvalues (1 to about 1330) is the conditioning that `w` has to undo.

**7. Shape along each whitened axis.** `Δf/(s²/2)` at displacements `s` (in whitened sd) from the mode: 1 everywhere is a Gaussian, above 1 is steeper than the whitening assumed (a wall), below 1 is flatter (a tail). The scans below it report, per axis, the noise from the c1 tolerance, the median and maximum curvature `f''` and the range of the profiled c1, with `jumps` counting discontinuities of c1 (a jump would break the gradient).

```text
Δf/(s²/2) along whitened axes (1 = Gaussian), s = -10,-5,-3,-2,-1,-0.5,0.5,1,2,3,5,10
  w1:        1        1        1        1        1        1        1        1        1        1        1        1
  w2:    0.714    0.727    0.852    0.988     1.02     1.01     0.99    0.985    0.995     1.05     1.66     3.66
  w3:     2.36       13     3.27     2.02     1.37     1.16     0.87    0.768    0.617    0.512    0.381     0.24
  w4:    0.384    0.589    0.717    0.796     0.89    0.942     1.06     1.13     1.29     1.47     1.98        5
  w1 scan: c1-tol noise=8.55e-10  f''(median)=1 f''(max)=1 at s=1.88  c1 range=[1.2327,1.2342] jumps=0
  w2 scan: c1-tol noise=1.04e-09  f''(median)=0.997 f''(max)=2 at s=2.98  c1 range=[1.2046,1.2389] jumps=0
  w3 scan: c1-tol noise=1.03e-09  f''(median)=0.997 f''(max)=19.6 at s=-2.98  c1 range=[1.2170,1.2461] jumps=0
  w4 scan: c1-tol noise=7.37e-10  f''(median)=0.999 f''(max)=2.87 at s=2.98  c1 range=[1.2255,1.2420] jumps=0
```

SASDX52: w3 is a wall on its negative side (13 times a Gaussian at s = −5, local curvature 19.6 near s = −3) and a long flat tail on its positive side (0.24 at s = +10). w2 is flat on its negative side (0.71 at s = −10) and steep on its positive side (3.66 at s = +10), and w4 is flat on its negative side and steep on its positive side (5 at s = +10). c1 is smooth on all four axes (no jumps).

**8. The distinct optima.** Each optimum with its position ξ, the Hessian eigenvalues and its Laplace log-mass, `−f − ½ log det H`, and the difference from the best: a mode that merely exists is told from one that carries probability.

```text
distinct optima: 2
  mode 1: f=-855.860 ξ=[0.3406, -0.2077, -3.239, 1.172]  H-eig=[0.9999, 2.96, 19.16, 1332]  log Laplace mass=850.244 (Δ vs best = 0 nats)
  mode 2: f=-831.766 ξ=[0.3406, 0.753, 1.627, -5.62]  H-eig=[0.9955, 1.213, 3.198, 90.48]  log Laplace mass=828.838 (Δ vs best = -21.4 nats)
```

SASDX52: the second optimum is 21.4 nats lighter and carries no mass.

**9. Gradient error and the stable step size.** The first line is the error the c1 tolerance puts in the gradient NUTS uses, against the size of the gradient (error ≪ gradient means it is not the cause of trouble). The second is the largest curvature `λ_max` along the draws and the step size ε a leapfrog integrator is stable for at that curvature, against the ε the sampler adapted.

```text
gradient error from the c1 tolerance in w: min/median/max = [0, 6.698e-05, 0.001394]  vs |∇ℓπ| median = 1.63   (posterior-scale gradient ≈ 1)
local λ_max(−∇²ℓπ) min/median/max = [0.9999, 1.139, 63.91]  → stable ε < [0.2502, 1.874] (worst, median);  adapted ε = 0.4087
```

SASDX52: the gradient error (median 6.7e-5, at most 1.4e-3) is four orders of magnitude below the median gradient (1.63) and three below it at the worst draw, so it does not cause the divergences. The adapted ε (0.41) is above the step that is stable at the worst curvature along the draws (0.25, where `λ_max` reaches 64), and below the one stable at the median curvature (1.87): a step size that suits most of the posterior but not its steepest corner, which fits the two divergent transitions of block 2.

### Part 2: `--chains`

One line per chain of `infer`, the chains `run_model` pools, for the run with the report's own `rng_seed`. The first eight chains are fixed: two at the MAP and three mirrored pairs further out. Chains after the eighth are started at optima that the harvest of the first chains' draws found to carry mass (see below), and their `start σ` is the optimum's distance from the MAP. Columns: `start σ`, the distance of the chain's start from the MAP in posterior sd (negative is the mirrored chain of a pair); `mode`, the posterior mode it settled in; `pooled`; `kept`, its post-warm-up draws that the pool keeps (a chain in a mode with no mass keeps none); `div` and `div%`, divergent transitions among them; `warm-up div`, divergences during warm-up (not part of the posterior); `ε`, `steps` and `accept`, its mean step size, leapfrog steps and acceptance; `mean log π`. After the table, every divergent draw: chain, iteration, ξ = (ρₑ, δρ₁, δρ₂, δρ₃), log π against the chain's median, leapfrog steps and tree depth.

**10. The run `run_model` does** (300 warm-up, 700 draws):

```text
SASDX52: 10 chains, 300 warm-up + 700 draws, rng_seed 6252506411145483830, δ 95
chain  start σ   mode  pooled  kept  div  div%  warm-up div       ε  steps  accept   mean log π
    1    +0.00      1  yes      700    0   0.0            1  0.2561   14.6   0.980       853.72
    2    +0.00      1  yes      700    1   0.1            4  0.2429   13.0   0.944       853.68
    3    +4.00      1  yes      700    0   0.0            4  0.1704   18.9   0.985       853.64
    4    -4.00      1  yes      700    0   0.0            4  0.2886   10.7   0.952       853.50
    5   +10.00      1  yes      700    0   0.0            3  0.4885    7.3   0.953       853.37
    6   -10.00      1  yes      700    0   0.0            4  0.0849   39.4   0.979       853.59
    7   +20.00      2  yes        0  no post-warm-up draws kept (negligible mode)
    8   -20.00      1  yes      700    1   0.1            5  0.5129    6.8   0.933       853.61
    9    +5.43      1  yes      700    3   0.4            3  0.3687    9.9   0.947       853.31
   10    +5.43      1  yes      700    0   0.0            3  0.2283   15.2   0.976       853.58
pooled kept draws: 6300, divergent: 5 (0.08 %)
divergent draws:
  chain 2 iteration 616  ξ = [0.34048, -0.40858, -5.7518, -6.1068]  log π +853.76 vs chain median +854.01  steps 14  depth 3
  chain 8 iteration 439  ξ = [0.34071, -0.23005, -2.8651, 2.5518]  log π +853.26 vs chain median +854.00  steps 9  depth 3
  chain 9 iteration 507  ξ = [0.34036, -0.14617, -2.2836, 2.7934]  log π +849.58 vs chain median +853.73  steps 11  depth 3
  chain 9 iteration 584  ξ = [0.34106, -0.31662, -5.6875, -3.7399]  log π +849.42 vs chain median +853.73  steps 11  depth 3
  chain 9 iteration 688  ξ = [0.34038, -0.52483, -7.2085, -5.0625]  log π +846.99 vs chain median +853.73  steps 4  depth 2
```

SASDX52: the run has 10 chains. Chains 9 and 10 are the extra ones; both start 5.43 sd from the MAP, the position of the optimum the harvest found (the third optimum of the closing list), and both end in mode 1, with the other chains. Chain 7 (the +20 sd start) ends in the second optimum and keeps no draws. There are 5 divergent draws in 6300 (0.08 %), spread over chains 2, 8 and 9: no chain has more than three, and chain 6 (ε = 0.085, 39 steps per iteration) has none. The draw of chain 2 lies at δρ₂ = −5.75 and δρ₃ = −6.11, far from the main mode's (−3.24, 1.17), with log π near that chain's median. The three of chain 9 are 4 to 7 nats below the chain's median log π, at δρ₃ = 2.79 (next to the upper bound 2.839), −3.74 and −5.06.

**11. The retry** (`--retry 1`: 2000 warm-up, 2000 draws, seeds derived from the run's, as `infer` does when R̂ is above 1.01):

```text
SASDX52: 9 chains, 2000 warm-up + 2000 draws, rng_seed 6252506411145483830, δ 95  (the rerun)
chain  start σ   mode  pooled  kept  div  div%  warm-up div       ε  steps  accept   mean log π
    1    +0.00      1  yes     2000   26   1.3            9  0.2622   11.7   0.909       853.64
    2    +0.00      2  yes     2000  886  44.3            7  0.1827    8.9   0.405       853.24
    3    +4.00      1  yes     2000    4   0.2            7  0.3180   10.7   0.957       853.55
    4    -4.00      1  yes     2000   16   0.8            8  0.3053   11.4   0.952       853.76
    5   +10.00      1  yes     2000    4   0.2            8  0.5052    6.5   0.917       853.73
    6   -10.00      1  yes     2000   23   1.1            8  0.2737   11.8   0.918       853.53
    7   +20.00      3  yes        0  no post-warm-up draws kept (negligible mode)
    8   -20.00      1  yes     2000    2   0.1            5  0.2619   12.3   0.965       853.53
    9    +5.42      1  yes     2000    9   0.5            4  0.2907   11.6   0.942       853.51
pooled kept draws: 16000, divergent: 970 (6.06 %)
divergent draws (first 12 of 970):
  chain 1 iteration 3046  ξ = [0.3406, -0.39279, -4.999, -6.5333]  log π +854.76 vs chain median +853.96  steps 3  depth 1
  chain 1 iteration 3049  ξ = [0.3406, -0.36977, -4.8604, -6.2187]  log π +855.33 vs chain median +853.96  steps 4  depth 2
  […]  (10 more, all chain 1)
```

SASDX52: the longer run is worse, not better. The divergences go from 5 to 970 (6.1 %) and chain 2 alone has 886 of its 2000 draws divergent with acceptance 0.405 (chain 2 settled apart from the others, in mode 2). The 12 divergent draws listed all belong to chain 1, at δρ₂ ≈ −4.7 to −5.5 and δρ₃ ≈ −6.0 to −6.8, log π ≈ 853.4 to 855.3; five of them are the same point (−0.36977, −4.8604, −6.2187) repeated, a chain that is rejected from there again and again. Only one extra chain (chain 9, +5.42 sd) is started here. A longer run seems to reach that region more often, but this single run does not show why.

### What SASDX52 shows

* The divergences are not the c1 tolerance (block 9: gradient error three to four orders below the gradient) and not a discontinuity of the profiled c1 (block 7: `jumps=0` on all four axes).
* The posterior has a **third optimum** that the MAP search does not report (block 8 lists two). It carries about 4 % of the posterior mass by the Laplace estimate. No random start reaches it: 500 random L-BFGS starts gave 0 hits (`test/validation/optima_recall/`), and the 64 starts of block 5 end in the two known optima.
* The sampler finds it from the draws instead. After the first eight chains the harvest of optima from their draws finds it, and `infer` starts two more chains there (chains 9 and 10 of block 10). In a one-off measurement with the final code (not reproducible from the three outputs above), those chains left it within a few hundred iterations, and 0.7 % of the pooled draws fall around it against its Laplace share of 4.2 %.
* The long retry (block 11) is where the divergences concentrate: chain 2 alone has 886 of the 970. Its ε is smaller (0.18) and its acceptance (0.405) is the lowest of all runs here, but this output does not show what puts it there.
* In the final suite run (53 fits) SASDX52 has 7 divergent draws out of 9300 and R̂ ≤ 1.01 holds on all fits.

## Requirements

[Babashka](https://babashka.org) (a single binary; JSON is built in). `extract_formfactor.clj` fetches the
`org.babashka/go-sqlite3` pod on first use. `bench.clj` (and `dev/diagnose.clj`) also need `julia` on the `PATH`
(or `JULIA=/path/to/julia`).

## Benchmarks: cold start and steady state

Performance claims in this repository are measured from a **cold state** and reported next to a **steady state**, so a speedup never comes from a cache that a user does not have on first use.

```bash
bb bench --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3 SASDJ62
bb compare --bench new.json     # against the latest release's baseline
```

The cold state's temporary directory is deleted when the run ends (also on failure; the links to your depot are unlinked, never followed); `--keep` leaves it in place.

### What "cold" wipes

`bench.clj --state cold` never touches your real depot or repository. It builds, in a temporary directory:


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

- **Benchmarks are only run with the repository owner's explicit approval, per run, because they need a quiet machine.** Timings are only meaningful when nothing else is using the CPU, and AI agents tend to start a benchmark without checking whether the machine is quiet. `bench.clj` therefore does nothing but print its plan unless `--approved` is passed, and `--approved` is added only after the owner has said yes to this run, which means they have confirmed the machine is quiet. It is a small safeguard against careless runs, not a security measure.
- One process at a time, a quiet machine (for example: check for `DisplayLinkManager` and `baloo` CPU use first), no parallel runs.
- Compare like with like: a cold run against a cold run of an earlier commit (use `git worktree`/`git stash` to build the earlier tree), never against warm numbers or the committed `res*.txt` timings, which are warm-cache.
- [`../baselines/`](../baselines/README.md) holds the machine-specific reference run of each release (the default for `compare.clj --bench` is that of the latest release) (host and CPU are recorded in `meta`); compare only within a host.
