# Optima recall

Does the MAP search find every optimum of the posterior that carries probability mass, and if it misses some, which general rule for choosing the L-BFGS starts finds them, at what cost?

```bash
bb validate optima_recall --approved --threads 4,1        # all 53 fits
bb validate optima_recall SASDX52 --approved --threads 4,1   # or some
```

The script (`validate.jl`) writes `results/optima_recall-<stamp>.tsv` (one row per fit, rule and seed) and `results/optima_recall-<stamp>_optima.tsv` (one row per reference optimum), and prints its verdict against the criteria below. It runs the fit's `Seed` only (no plots, no report) and the sampler a few times for the harvest rule.

## Why this exists

The MAP search (`Inference/MAP.jl`) runs 32 L-BFGS starts and keeps the distinct optima. It finds the mode the sampler is whitened around, and its count of optima (`n_modes`) feeds the report. For SASDX52 the sampler's chains showed 9 divergent draws in a region of high density that the search had not reported as an optimum. Running L-BFGS from those draws converged to a third optimum, 0.18 nats higher in `-log π` than the best, carrying about 5 % of the Laplace mass, and none of 500 random starts reached it. So the search is incomplete there, and nothing in the pipeline measures how often that happens. This validation measures it on all 53 fits, and compares general ways of improving it. No rule here knows anything about a particular fit.

## Vocabulary

Everything is in z-space, the prior-standardized coordinates in which L-BFGS minimizes `f(z) = -log π(θ(z))` (the profiled c1 is part of `f`).

* **Optimum**: a local minimum of `f` that L-BFGS converges to. **Basin**: the starts that end there. **Hit rate** `p` of an optimum: the share of random starts (prior draws) that end there.
* **The same optimum**: two optima are the same when their Mahalanobis distance is at most `MAP_MODE_SEP`, under the Hessian of `f` at the best optimum with its eigenvalues floored at 1. This is the rule the production search uses.
* **Laplace mass** of an optimum: `exp(-f) (2π)^{d/2} det(H)^{-1/2}`, in logs `-f - ½ Σ log λ`. Its **share** is its mass over the total of the reference set. An optimum whose Hessian is not positive definite (typically one on a prior bound) has no Laplace mass; it is counted and listed, not judged. The Laplace mass is crude: it assumes a Gaussian bump, so a skewed mode is mis-weighed, by a factor of two or more.
* **Massive**: a reference optimum with a share of at least 1 %.

## What the literature says (the principles behind the rules)

* **Multistart and its miss probability.** With uniform random starts, the chance that a start lands in a given basin is the basin's volume share `p`, so `K` starts miss it with probability `(1 − p)^K` (see [On the probability of finding local minima in optimization problems](https://digitalcommons.kean.edu/keanpublications/2586); the multistart weakness is that many starts repeat the same basin). A small basin needs `log 0.05 / log(1 − p)` starts for 95 % detection. This is what `hit_rate`, `miss32` and `starts_for_95` in the output report. When `p` is 0 among 500 starts, no number of random starts is a practical answer.
* **Multistart with a rule that avoids repeated descents.** Multi-Level Single Linkage (Rinnooy Kan & Timmer, 1987) samples many points, and starts a local search only from points that have no better sample point nearby, so it makes about one descent per basin instead of one per draw. Rule `S32` below is a version of it. TikTak, a multistart method that picks starts from the best of a quasi-random sample, ranked first in a benchmark of global optimizers ([Arnoud, Guvenen & Kleineberg, NBER w26340](https://www.nber.org/papers/w26340.pdf)); but it is built to find the global optimum, not to enumerate all optima, which is why it is not one of the rules here.
* **Local search in the neighbourhood of optima already found** (basin hopping, mode-neighbourhood starts): rule `J` below, with the same idea as the sampler's own jittered chain starts.
* **Mode discovery by the sampler itself.** [Pathfinder](https://arxiv.org/pdf/2108.03782) runs several L-BFGS paths and resamples from them with importance weights; the paper presents the multi-path version as the remedy for L-BFGS getting stuck in local optima, and its authors report it is much better for multimodal posteriors. Tempering methods find modes by sampling at higher temperature ([tempered HMC](https://arxiv.org/html/2111.06871v3), [parallel tempering and mode jumping, a survey](https://arxiv.org/html/2501.05908v1), [Annealed Leap-Point Sampler](https://ar5iv.labs.arxiv.org/html/2112.12908)). Not implemented here: they are the heavy end. Rule `H` is the cheap version of the same idea: the chains of the real sampler have already visited the high-density regions, so use their draws as starts for L-BFGS.
* **How many optima are left unseen.** Chao's (1984) lower bound (A. Chao, Scandinavian Journal of Statistics 11, 265-270; from memory, not from the search above) on the number of unseen categories, `f1² / (2 f2)` (with `f1` the optima seen once among the starts and `f2` twice; `f1 (f1 − 1)/2` if `f2 = 0`), is the standard way in ecology to estimate species not yet seen; here it estimates optima not yet seen. It is reported for the oracle's 500 starts (`oracle_chao1_unseen`) and for each rule (`chao1_unseen`). A bound from random starts cannot count basins with hit rate near 0, so it is a floor on what is missing, not a count.

## The reference set (the oracle)

It is the most this script can find, not the truth. It is the union, clustered with the rule above, of:

1. 500 L-BFGS runs from prior draws (`ORACLE_STARTS`; the production kind of start, 15 times as many);
2. every optimum any rule finds, for every seed;
3. L-BFGS from the draws of one long run of the real sampler (8 chains, 1000 warm-up and 3000 draws): a farthest-point cover of 32 of its post-warm-up draws and up to 16 of its divergent draws.

Each cluster is one reference optimum, with its best point, its Hessian, its Laplace log-mass and share. It is massive when the share is at least 1 %.

## The rules (arms)

Every rule includes the fit's own `θ₀` as a start, as the production search does. The seeds only change the random starts.

| arm | what it does | cost counted |
|---|---|---|
| `P32` | the production search replayed: 32 starts (θ₀ and 31 prior draws) | its L-BFGS evaluations |
| `A64`, `A128` | plain multistart with 64 and 128 starts (the first 32 are P32's) | idem |
| `S32` | sample, screen, descend: evaluate `f` at 3000 prior draws, keep those lowest among their 15 nearest neighbours (the local minima of the sampled landscape), L-BFGS from the 32 best | the 3000 evaluations plus the L-BFGS runs |
| `J` | P32 plus jitter: around each of at most 4 optima P32 found within 15 nats of the best, L-BFGS from 3 radii (3, 6, 12 posterior sd) × 2 random directions, in the optimum's own Hessian metric | P32 plus those runs |
| `H` | P32 plus harvest: after a production sampling round (1000 iterations, 8 chains, 300 warm-up, the `run_model` default), L-BFGS from a farthest-point cover of 16 of the post-warm-up draws and up to 8 divergent draws | P32 plus those runs (the chains run anyway; their leapfrog steps are in `chain_steps`) |
| `JH` | P32 plus the jitter of `J` plus the harvest of `H` | idem |

A **farthest-point cover** takes the draw of highest log π, then repeatedly the draw farthest (Euclidean in z) from those already taken, so the starts cover the sampled region evenly instead of piling up on the bulk.

## What is measured

Per fit, rule and seed (`optima_recall-<stamp>.tsv`):

| column | meaning |
|---|---|
| `n_ref`, `n_massive`, `n_unmassable` | reference optima, massive ones, ones with no Laplace mass |
| `recall_mass` | share of the massive reference mass in the optima the rule found (1: nothing with mass missed) |
| `n_missed` | massive reference optima the rule did not find |
| `evals` | objective plus gradient evaluations (the cost; machine independent) |
| `seconds` | wall time (depends on the machine and the threads) |
| `n_reported` | reference optima the rule found, massive or not |
| `chao1_unseen`, `oracle_chao1_unseen` | Chao's bound for the rule's starts and for the oracle's 500 |
| `chain_steps` | leapfrog steps of the chains behind the harvest, for `H` and `JH` |

Per reference optimum (`..._optima.tsv`): `f`, `log_mass`, `share`, `massive`, `hits` (of the 500 random starts), `hit_rate`, `miss32 = (1 − p)^32` (the probability that 32 random starts miss it), `starts_for_95`, `xi` (ρₑ, δρ₁, δρ₂, δρ₃) and `found_by` (the rule/seed pairs that found it).

## Criteria (fixed 2026-10-10, before the first full run)

Judged over all (fit, seed) pairs of a run:

1. **Nothing massive missed**: for a rule to be accepted, `n_missed = 0` in at least 95 % of the (fit, seed) pairs.
2. **A floor on the loss**: `recall_mass ≥ 0.9` in every pair.
3. **Cost**: the median of `evals` over P32's `evals` is at most 10 (a rule that costs ten times the search is still a few percent of the pipeline).
4. **No loss against production**: in no pair does a rule miss more massive optima than P32.

Reported, not judged: P32's own numbers (the baseline), the number of fits with an unmassable optimum, the massive optima no random start reached (`hits = 0`, the ones only the sampler-based rules can find), and the Chao bounds.

*History of the criteria.* The first draft of criterion 1 was "`recall_mass ≥ 0.95` in 95 % of the pairs". A smoke test of the script on two fits (SASDMJ9 and SASDX52, before any of the full runs) showed that this threshold passes a rule that misses a 5 % mode (recall 0.950), which is the very case that motivated the validation, so it was replaced, before the full run, by "no massive optimum missed" and a floor on the loss. The thresholds 95 %, 0.9 and 10 are judgments, not derived.

## Caveats

* The oracle is a lower bound on what exists. A mode neither the random starts, the rules nor the long run find is not counted, so recall can look better than it is.
* Laplace mass is crude; shares near the 1 % line can flip. A bridge-sampling check on a few fits would say by how much.
* Finding an optimum does not put it in the posterior. Chains have to start in it and its mass has to be estimated; that is a separate design.
* The replay of P32 is the same kind of search as the production one (`θ₀` and prior draws), not the same random numbers: the production search keeps its optima internally.
* Fits are run on the Julia threads (the L-BFGS starts are independent); the results do not depend on the thread count, the `seconds` column does.

## Outcome

Run on 2026-10-10 (`results/optima_recall-20261010-223448.tsv` and `..._optima.tsv`): all 53 fits, seeds 1 and 2, 4 Julia threads, about 6 minutes. The script's verdict, against the criteria above:

| rule | nothing missed | min recall | median evals / P32 | never worse than P32 | accepted |
|---|---|---|---|---|---|
| `P32` (production replay) | 96.2 % (102 of 106) | 0.000 | 1 | – | baseline |
| `A64` | 98.1 % | 0.950 | 2.0 | yes | yes |
| `A128` | 98.1 % | 0.950 | 4.0 | yes | yes |
| `S32` | 98.1 % | 0.940 | 1.1 | **no** | no |
| `J` | 97.2 % | **0.000** | 1.2 | yes | no |
| `H` | **100 %** | 1.000 | 1.5 | yes | yes |
| `JH` | **100 %** | 1.000 | 1.7 | yes | yes |

**What the reference set contains.** 58 massive optima in the 53 fits. 48 fits have one. Five have two: SASDKQ8 (shares 0.96 / 0.04), SASDN32 (0.94 / 0.06), SASDWZ9 (0.83 / 0.17), SASDX52 (0.95 / 0.05) and SASDZC6 (0.81 / 0.19). Three fits (SASDMZ9 model1, SASDUN5 fit1_model2, SASDZZ9) have 14 optima each with no Laplace mass (Hessian not positive definite, i.e. on a prior bound); they are not judged. The Chao bound is above 0 for two fits (SASDMZ9 model1, SASDUN5 fit1_model2), so the reference set may be missing optima there.

**What the production search misses.** In 4 of 106 pairs P32 misses a massive optimum:
* SASDX52, both seeds: the third mode (share 0.050). Hit rate 0 of 500 random starts, so no number of random starts finds it (`starts_for_95 = Inf`): `A64` and `A128` miss it every time. `H` and `JH` find it in both seeds; `S32` and `J` only in seed 1.
* SASDLP4 fit1_model2 and fit2_model1, seed 2: the *main* mode (share 1.0, recall 0.000). Hit rate 7.4 % per start, so 32 starts miss it with probability 8.5 %, and 39 starts are needed for 95 % detection. `A64`, `A128`, `S32`, `H` and `JH` find it; `J` cannot, as it starts from what P32 found. In the pipeline the sampler's re-whitening safety net (`BASIN_RESTART_NATS`) catches such a case, because the chains find a basin much better than the MAP.
* SASDN32, hit rate 8 % for a 6 % mode: P32 found it in both seeds by luck (miss probability 6.9 %); `S32` missed it in seed 1.
* Of the 58 massive optima, one (SASDX52's) was reached by no random start. Across them the hit rate has median 0.46, and 30 are below 0.5.

**Reading.** Two kinds of miss, which want two kinds of fix. A basin with a hit rate of a few percent (SASDLP4, SASDN32) is a matter of the number of starts: 64 starts fix those two, at twice the cost. A basin with a hit rate near zero (SASDX52's third mode) is not reachable by random starts at all, and only starting L-BFGS from the sampler's draws (`H`) found it every time. `H` and `JH` miss nothing, for about 1.5 to 1.7 times the evaluations of the search. The MAP search stage is 1.8 s of the 142 s the 53 fits take in the pipeline (1.3 %, final run of `rhat_retry`), so the extra is under 1 % of the wall; the chains whose draws are harvested run anyway.

**Caveats on this result.** (1) The reference set includes optima found from the long sampler run, which is the mechanism of `H`; so `H` finding everything in the set is partly by construction. That `S32` and `J` (random-start based) also found SASDX52's third mode in seed 1 shows that the mode is real, not an artefact of harvesting. (2) The 95 % threshold of criterion 1 lets a rule that systematically misses one fit in 53 (`A64`, `A128` on SASDX52) pass; by the intent of the validation only `H` and `JH` solve the case that motivated it. The criterion was not changed after the data was seen. (3) The Laplace shares are crude, so the 4 % to 6 % modes could be a factor of two off. (4) Only two seeds.

**What was done with it (same day).** The pipeline now runs 64 prior starts and a jitter round in the MAP search (rule `J`'s idea), harvests L-BFGS starts from the first round of chains (rule `H`), and starts chains at any optimum with a Laplace share of at least 1 % that has fewer than two chains at it; see the "More optima than the search found" paragraph of `src/Inference/README.md`. On SASDX52 the harvest finds the third mode and two chains are started there; they leave it within a few hundred iterations, and 0.71 % of the pooled draws fall around it against a Laplace share of 4.2 %: the region behaves like a sparse excursion from the main mode and not as a trap. Whether its true mass is 0.7 % or nearer 4 % is not settled (the Laplace mass is crude; divergent transitions there reject trajectories). The validation's `P32` arm is the old production search replayed, not the current one; rerunning the validation against the new pipeline would need an arm that calls `infer`.
