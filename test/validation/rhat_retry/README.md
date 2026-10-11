# R̂ retry and target acceptance

Does `infer` with the target acceptance raised from 80 % to 95 % and a single longer rerun when R̂ is above 1.01 (2000 warm-up and 2000 draws per chain, from seeds and jitter directions derived deterministically from the run's own) bring the 53 fits to converged, divergence-free posteriors without changing what they say?

This is not run through `validate.clj` (there is no `validate.jl`): the evidence is a full top-to-bottom run of the fitting tests, whose reports are tabulated by `test/utils/results_table.clj --tsv`.

```bash
bb fittings --table --threads 4,1                                  # all 53 fits at the defaults
bb results-table --tsv test/validation/rhat_retry/results/results_final.tsv
```

## Evidence already in `results/` (the study that led to the design, 2026-10-10)

`results_baseline.tsv` is the state before this change (300 warm-up, 700 draws, δ = 80 %, 8 chains). The four arms were run on all 53 fits with one seed pair, in series, `--threads 4,1`, with `BAYSOL_N_ADAPT`, `BAYSOL_N_DRAWS` and `BAYSOL_TARGET_ACCEPT` set for the run (since removed from `common.jl`):

| file | warm-up / draws | δ | worst R̂ | R̂ ≤ 1.01 | fits with > 1 % divergences | fits with divergences ≥ 0.05 % | leapfrog steps |
|---|---|---|---|---|---|---|---|
| `results_1.tsv` (= baseline, reproduces it exactly) | 300 / 700 | 80 % | 1.090 | 48 | 3 | 9 | 3.33 M |
| `results_2.tsv` | 1000 / 1000 | 80 % | 1.016 | 51 | 2 | 12 | 6.27 M |
| `results_3.tsv` | 300 / 700 | 95 % | 1.015 | 47 | 0 | 1 | 4.33 M |
| `results_4.tsv` | 1000 / 1000 | 95 % | 1.081 | 49 | 1 | 1 | 8.31 M |

`reports_N/` holds each arm's reports. The fit quality does not depend on the arm (median χ² change 0.004–0.008 %, largest 0.49 % on SASDX52). The retry rule and the 2000 / 2000 size were chosen after seeing this table; the criteria below were fixed after it and before the run they judge.

## Criteria (fixed 2026-10-10, before the full run of the final code)

Judged over the 53 fits of one run (`results_final.tsv`), against `results_baseline.tsv`:

1. **Convergence:** at least 95 % of the fits (51 of 53) have a worst within-mode R̂ ≤ 1.01 *after* the retry, and none is above 1.05. A fit that stays above 1.01 because its chains sit in different modes is listed with its mode shares, not excused.
2. **Divergences:** no fit has a divergence rate above 0.0 % as the report prints it, that is, none at or above 0.05 %. The number of fits with any divergent transition at all is reported next to it, not judged.
3. **The retry:** it fires on at most 20 % of the fits (10 of 53), and whenever it fires the returned run has a worst R̂ no larger than the first run's (`retry` line of the report; the first run is returned when the rerun is worse).
4. **Fit quality:** the median measured-grid χ² is within 0.1 % of the baseline's, and no fit is more than 1 % worse than in the baseline.
5. **Determinism:** rerunning a handful of fits (at least two that retried and two that did not) with the same seeds reproduces their reports exactly.
6. **Cost (reported, not judged):** the sampling-stage seconds summed over the fits, the number of retries, the leapfrog steps against the baseline.

## Outcome

Full run of the final code, 2026-10-10 (`results/results_final.tsv`, `reports_final/`, `fit_log_final.txt`; 53 fits, 300 / 700, δ = 95 %, retry on at 2000 / 2000, `--threads 4,1`, 17 minutes including the figures). Verdict: **criterion 2 failed, the others passed.**

1. **Convergence: passed.** 52 of 53 fits have R̂ ≤ 1.01 (baseline 48), none above 1.05, the worst is SASDX52 at 1.0154 (bulk ESS 693).
2. **Divergences: failed.** One fit is at or above 0.05 %: SASDX52 with 0.18 %. Six fits have any divergent transition (baseline 19; fits above 1 %: none, baseline 3). The criterion was not changed after the data was seen.
3. **The retry: passed.** It fired on 6 fits (SASDEP6 fit1_model2, SASDN32, SASDRN5 fit2_model1, SASDVG2 fit2_model1, SASDWZ9, SASDX52), first-run R̂ 1.013 to 1.015. The rerun was kept for five and fixed all five. For SASDX52 the rerun was no better and the first run was kept (it is the known two-mode fit, one chain in the second mode).
4. **Fit quality: passed.** Median measured-grid χ² 2.4366 against 2.4366 (change −0.0003 %), worst single fit +0.49 % (SASDX52), no fit more than 1 % worse.
5. **Determinism: passed.** SASDN32 and SASDWZ9 (retried) and SASDMJ9 and SASDBS6 (not retried; seven reports) rerun with the same seeds are identical in every section except `=== Timing ===`, which holds measured seconds.
6. **Cost (reported):** pipeline wall without PROPKA/pdb2pqr 142.0 s against 123.3 s (+15 %), NUTS 32.0 s against 28.8 s, leapfrog steps 4.33 M against 3.33 M (×1.30). Per stage (s, baseline → final): static build 36.0 → 37.2, sampling 57.0 → 68.7, MAP search 1.8 → 1.8, per-draw c1 re-profile 1.2 → 1.2, quantiles 20.8 → 19.7, report write 4.1 → 4.2, unaccounted 26.3 → 31.9, GC 7.3 → 5.6.

### Second full run: the pipeline with the optima work (2026-10-10, 23:24, `results/results_final2.tsv`, `reports_final2/`)

Same defaults (300 warm-up, 700 draws, δ = 95 %, retry at 2000 / 2000), 53 fits, `--threads 4,1`, 19 minutes including the figures. The code differs from the first run by what `test/validation/optima_recall/` led to: 64 MAP starts and a jitter round, L-BFGS from the draws of the first chains, chains started at optima that carry mass but have fewer than two chains, and the removal of a shortcut in `chain_modes` that pooled a single far-off chain with nine others. **Criterion 2 was amended by the owner after the first run's data were seen** (from "no fit at or above 0.05 %" to "at most 5 divergent post-warm-up draws per fit": SASDX52's remainder is a handful of draws in a curved tail), and this run is its check.

1. **Convergence: passed, better than before.** 53 of 53 fits have R̂ ≤ 1.01 (first run 52), worst 1.0063 (first run 1.0154).
2. **Divergences: failed, both as first fixed and as amended.** Only SASDX52 is at or above 0.05 % (0.08 %, 7 divergent draws of 9300); the amended limit of 5 draws misses it by 2. Every other fit has at most 2 divergent draws (0.04 %), and 8 fits have any at all (baseline 19, first run 6).
3. **The retry: passed.** It fired on 8 fits (SASDEP6 ×2, SASDLP4 ×2, SASDN32, SASDRN5, SASDVG2, SASDWZ9), first-run R̂ 1.010 to 1.052, and the rerun was kept for all 8.
4. **Fit quality: passed.** Median measured-grid χ² 2.43646 against 2.43662 (change 0.0000 %), worst single fit +0.11 % (SASDTK5 fit2_model1), none more than 1 % worse.
5. **Determinism: passed.** SASDN32 and SASDWZ9 (retried) and SASDMJ9 and SASDBS6 (not retried; eight reports) rerun with the same seeds are identical outside `=== Timing ===`.
6. **Cost (reported):** pipeline wall without PROPKA/pdb2pqr 163.9 s (first run 142.0 s, baseline 123.3 s); the MAP search stage 4.9 s (1.8 s); NUTS 40.8 s (32.0 s, baseline 28.8 s); leapfrog steps 4.50 M (4.33 M, baseline 3.33 M). Five fits list two optima that carry mass (SASDKQ8, SASDN32, SASDWZ9, SASDX52, SASDZC6) and three had chains added (SASDKQ8 +1, SASDN32 +2, SASDX52 +2).

