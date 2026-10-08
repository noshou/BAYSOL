# Shannon binning

Does fitting the curve binned to `rebin` bins per Shannon channel π/D give the same answer as fitting every measured point? Run on the 53 fitting tests, 2026-10-08, for the default `rebin = 12` (and 8 and 16).

```bash
tclsh test/run/validate.tcl shannon_binning --approved        # prints its plan without --approved
```

The script (`validate.jl`) finds the MAP and the Laplace posterior width on the unbinned curve (`rebin = nothing`, same `lMax`) and on the binned curve, per fit and per k, and writes one row each to `results/shannon-<stamp>.tsv` (the committed run is `results/shannon-20261008-0112.tsv`). Two extra variants show what dropping non-positive points does: `12d` bins at k = 12 *with* the default drop of non-positive bins, `raw-d` leaves the curve unbinned but drops its non-positive points (what the fitting scripts used to do).

## Criteria and what happened

**First criteria** (fixed before the first run), per fit: in at least 95 % of the fits every MAP coordinate moves by at most 0.5σ of the unbinned fit, every Laplace σ is within [0.95, 1.05] of the unbinned one, and the reduced χ² on the measured grid is within 2 %. **Every k failed them** (k = 12: 94.3 / 94.3 / 96.2 %; k = 8: 79.2 / 90.6 / 96.2 %; k = 16: 98.1 / 92.5 / 98.1 %). They judge the binned fit in the unbinned fit's own σ, which is unrealistically small (the unbinned curve has ~60 points per channel and is overfit), and two of the four failures at k = 12 are fits where the binned fit has the *better* χ² (the unbinned reference MAP search missed the best basin).

**Replacement criteria**, set after that data was seen, judged over distributions on a fresh full rerun of the 53 fits against the previous results (`test/utils/compare.tcl`):

1. Fit quality: the median χ² on the measured grid within ±2 %, the quartiles within ±5 %, at most 3 fits worse by more than 5 %.
2. Parameter distribution: each median of ρₑ, δρ₁, δρ₂, δρ₃, c1 moves by less than 0.25 of its interquartile range; the counts of fits at a prior bound, with c1 saturated, or beyond 3σ from the δρ₃ prior change by at most 3.
3. Regression health: fits with more than 1 % divergent transitions increase by at most 2; the median steps per iteration and tree depth are not more than 25 % worse; E-BFMI stays above 0.3 where it was; no chain fails; the MAP search finds the same number of modes (±1) in at least 90 % of the fits.

**Outcome:** criteria 2 and 3 pass (median χ² −0.3 %, quartiles +1.5 / +1.3 %, parameter medians moved at most 0.013 of the IQR, divergent fits 3 → 2, steps per iteration −2.5 %, E-BFMI at least 0.81, modes within ±1 in 53 of 53). Criterion 1 fails on one clause: 5 fits were more than 5 % worse (limit 3). All five are fits whose previous χ² excluded non-positive raw points, while the new χ² includes them (FoXS computes its own χ² over all points); the owner accepted that. Default: `rebin = 12`, `drop_nonpositive = true`.

The per-fit table in `results/` is kept as the evidence behind the first criteria; it is a screen, not the verdict.
