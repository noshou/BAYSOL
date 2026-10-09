# c1 root-find

Does polishing the profiled excluded-volume correction c1 as the root of the analytic derivative of the profiled χ² (`Roots.A42`, one fused pass per step) locate the same minimum as `Brent()` on the χ² values, with fewer passes? The change exists because a value-only minimizer is limited to about √eps in c1 (about 1e-5 on a sharply curved χ²), and the gradient of the likelihood is exact only at the exact optimum (the envelope theorem), so a more accurate c1 also gives a more accurate gradient.

**Outcome: rejected, the change was reverted (2026-10-09).** The script is not kept, since it called the root-finding code that was removed; the rows of the run that decided it are in `results/`, and the criteria and numbers below are the record. The run built each fit's seed, finds its MAP, and then runs the c1 search at the MAP and at 60 prior draws of ξ (so poor, saturating and badly fitting parameter points are covered). At each point both polishers run on the same scan bracket, with the number of passes counted and the time measured over repeated calls. It never samples. One row per point is written to `results/c1_rootfind-<stamp>.tsv`.

## Criteria (fixed 2026-10-09, before the first run)

Judged over all points, not per fit:

1. **Agreement:** where the derivative changes sign over the bracket, the root's derivative is smaller in magnitude than Brent's in at least 99 % of the points (the root is at least as stationary), and |c1(root) − c1(Brent)| ≤ 1e-4 in at least 99 %. Everywhere: the root lies inside the scan window, and the saturation class (`excl_vol_saturation`) is the same for both in at least 99.5 %.
2. **Cost:** the median number of passes of the root-finder is at most 0.7 of Brent's, and the median time per polish at most 0.85 of Brent's. If either fails, the change is not worth the extra dependency and is reverted to Brent.
3. **Robustness:** the fallback to Brent (a bracket without a sign change away from the window edge) happens in at most 5 % of the points, and no search raises.

## Outcome

One run (2026-10-09, 53 fits × 61 points, `results/c1_rootfind-20261008-2152.tsv`; 2,452 of the 3,233 points had a sign change over the bracket, the rest ended at the edge of the scan window). The change **failed criteria 1 (as written), 2 and 3 (as written)** and was reverted to `Brent()`:

1. **Agreement:** |Δc1| between the two was at most 8.6e-7 (median 8e-9), and the saturation class was identical in 100 % of the points, so they find the same minimum. The criterion that the root's derivative is the smaller one held in 92.7 % (limit 99 %): where it failed (178 points, all on the fits with the largest χ², SASDBS6 above all), both c1 differ by about 1e-9 and the derivative differences are the tolerance level of a χ² with a curvature in the millions, so that wording of the criterion was too strict. Where they differ, the root-finder is the more accurate: the median |dχ²/dc1| at the result is 4e-5 for the root and 3.7e-2 for Brent (Brent on χ² values leaves c1 off by up to about 1e-6, the √eps limit of a value-only minimizer).
2. **Cost (decisive):** the median number of passes is **13 for both** (10th to 90th percentile 11 to 18 for both), against a criterion of at most 0.7 of Brent's; the time per polish was 8 µs against 10 µs (ratio 0.90, limit 0.85). The notes' estimate of "about 2× fewer passes" for a derivative-based search was wrong: `A42` needs about 11 evaluations plus the two end points that decide the bracket, and Brent needs about 13 from a bracket of 0.04 down to 1e-8.
3. **Robustness:** 24 % of the points had no sign change (394 ended at the lower window edge, 209 at the upper, 178 interior); most are saturating prior draws handled by the edge test, so this criterion's wording counted a legitimate case.

The polish is about a tenth of a leapfrog step, so even a clear pass count win would have bought at most a few percent, for a new direct dependency (`Roots`) and a fallback path. Not worth it: `Brent()` stays. Revisit only if the polish becomes a larger share of the step.
