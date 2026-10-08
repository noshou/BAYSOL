# MAP f-stop

Does stopping each L-BFGS start of the MAP search once f stops decreasing (`MAP_F_ABSTOL = 1e-6` for `MAP_F_SUCCESSIVE = 3` iterations), instead of only at the gradient tolerance, change what the search finds? The change exists to make the MAP stage faster (an earlier sweep measured 10.7× fewer objective evaluations).

```bash
tclsh test/run/validate.tcl map_fstop --approved        # prints its plan without --approved
```

The script (`validate.jl`) runs the multi-start MAP search of each fit twice from the same starting points, with the f-stop (the default) and with the gradient test alone (`f_abstol = 0`, as before), on three RNG seeds, and writes one row per fit and seed to `results/map-<stamp>.tsv`. It never samples.

## Criteria (fixed 2026-10-08, before the first run)

Judged over distributions, not per fit. Δf is −log π at the f-stop's mode minus that at the gradient-only mode, in nats (positive: the f-stop is worse), over every (fit, seed):

1. **Fit quality:** median Δf ≤ 1e-3; 95th percentile of Δf ≤ 0.05; no Δf above 1 (no lost basin); the median relative change of the reduced χ² at the mode within 0.1 % and its 95th percentile within 1 %.
2. **Parameter distribution:** over the fits (mean over seeds), each of ρₑ, δρ₁, δρ₂, δρ₃, c1 has its median moved by less than 0.05 of its interquartile range, and the number of fits with δρ₁ or δρ₂ at a prior bound or c1 saturated changes by at most 1.
3. **Health of the regression:** the number of distinct modes agrees within ±1 in at least 90 % of the (fit, seed) pairs; the Hessian-based whitening is available wherever it was without the f-stop; the median ratio of objective evaluations (gradient-only / f-stop) is at least 3.

## Outcome

The first run (2026-10-08, 53 fits × 3 seeds, `results/map-20261008-1303.tsv`) **passes all three criteria**:

1. **Fit quality:** median Δf 6.6e-11 nats, 95th percentile 2.1e-8, maximum 0.000; the reduced χ² at the mode changes by −1.8e-11 (median) and at most 5.5e-7 (95th percentile |·|).
2. **Parameter distribution:** every median (ρₑ, δρ₁, δρ₂, δρ₃, c1) moved by 0.000 of its interquartile range; fits at a bound 8 → 8.
3. **Health of the regression:** modes agree within ±1 in 100 % of the (fit, seed) pairs; whitening lost in none; objective evaluations gradient-only / f-stop: median 9.9×, minimum 1.0× (a fit whose search had nothing to cut).

The f-stop (`MAP_F_ABSTOL = 1e-6`, `MAP_F_SUCCESSIVE = 3`) is the default. The reduced χ² in these rows is on the *fitted* (binned) grid, which is why it is far above the measured-grid χ² the reports print for badly misfitting fits (the binned σ is smaller by the square root of the points per bin while a systematic misfit is not).
