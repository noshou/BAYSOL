# Threading

Does running a stage on several Julia threads change what it computes? Every threaded stage must give **bit-identical** results at any thread count (each random draw belongs to a work item, not a thread: `Parallel.stream`), and should be faster. Stages are added to this validation as they are threaded; so far: the static build (SASA, excluded volumes, `B_lm`, the Gram matrix) and, for the record, the multi-start MAP search.

```bash
tclsh dev/validate.tcl threading --threads 1 --approved    # one run per thread count; prints its plan without --approved
tclsh dev/validate.tcl threading --threads 4 --approved
tclsh dev/validate.tcl threading SASDMJ9 SASDBS6 --threads 4 --approved   # or on some fits
```

The script (`validate.jl`) runs the MAP search of each fit for three base values (`--bases 1,2,3`) and writes a fingerprint (a hash of the mode ẑ, the whitening S, the evaluation and mode counts, bit for bit) and the warm wall time per (fit, base) to `results/threading-<stamp>.tsv`. Each run then compares itself with every earlier file in `results/` made with another thread count.

## Criteria for the MAP search (fixed 2026-10-09, before the first run)

1. **Identical results:** for every (fit, base), the fingerprint at N threads equals the one at 1 thread. One mismatch fails.
2. **Faster:** the median over (fit, base) of the warm MAP wall time at 1 thread divided by the one at 4 threads is at least 1.8 (eight starts and the Hessian columns over four threads; a ceiling of 4 is not expected, the starts differ in length).

## Outcome (MAP search)

Run 2026-10-09 on SASDMJ9, SASDBS6 (five models) and SASDEP6 (two models), 3 bases, 1 and 4 threads: criterion 1 **passes** (24 of 24 fingerprints identical); criterion 2 **fails** (median wall ratio 0.71×: warm, the whole search is about 8 ms, a start about 1 ms, and task overhead exceeds the work). The MAP starts and Hessian were therefore returned to a serial loop (the per-start random streams stay). The criteria were not changed after the fact.

## Criteria for the static build (fixed 2026-10-09, before the first run)

Run with `--threads 1`, `2`, `4`, `8` (and `4,1`, `8,1`) on SASDUN5:fit1_model2, SASDJ62:model1, SASDVG2:fit3_model2 (heavy) and SASDMJ9 (small). Stage seconds are the best of three warm builds, each after a full collection (a collection of about 1 GiB of garbage otherwise lands in whichever stage crosses the budget and moves its time by seconds).

1. **Identical results:** the Gram matrix fingerprint equals the 1-thread one at every thread count. One mismatch fails (if the cause is OpenBLAS summing differently with its own threads at one Julia thread, that is reported, not hidden).
2. **Faster on the heavy fits:** median over the heavy fits of `forward_cache` at 1 thread divided by the one at 4 threads is at least 2.0, and the 8-thread ratio is at least the 4-thread one (the efficiency cores must not make it slower).
3. **No regression on the small fit:** SASDMJ9's `forward_cache` and SASA at 4 threads take at most 1.1× their 1-thread time.

## Outcome (static build)

Run 2026-10-09 (`--threads 1, 2, 4, 8`, results in `results/`), quiet machine (Apple M2, 4 performance + 4 efficiency cores). Best-of-three warm stage seconds; speedup = 1 thread / N threads.

| `forward_cache` | 1 thr | 2 thr | 4 thr | 8 thr |
|---|---|---|---|---|
| SASDUN5 fit1_model2 (60,302 atoms) | 3.45 s | 2.00 (1.72×) | 1.59 (2.17×) | 1.23 (2.81×) |
| SASDJ62 model1 (9,679) | 3.22 s | 2.13 (1.51×) | 1.68 (1.92×) | 1.49 (2.16×) |
| SASDVG2 fit3_model2 (21,581) | 2.17 s | 1.27–1.50 (1.5–1.7×)¹ | 1.02 (2.12×) | 0.91 (2.39×) |
| SASDMJ9 (2,592) | 0.089 s | 1.00× | 1.00× | 1.00× |

SASA: 1.5–1.7× at 2, 1.9–2.5× at 4, 2.3–3.2× at 8 threads on the three heavy fits. Vacuum + excluded volume: 1.6–1.8× / 2.3–2.5× / 2.2–3.0×. Hydration is the weakest stage (1.4–1.5× at 2 and 4 threads, 2.2–2.5× at 8; its classes are small).

¹ The 2-thread SASDVG2 row of the recorded run shows a spike (`forward_cache` 2.71 s, hydration 1.62 s) that two standalone repeats did not reproduce (1.27 and 1.50 s): transient noise in that run, not a threading effect.

1. **Identical results: PASS.** The Gram matrix fingerprint is the same at 1, 2, 4 and 8 threads on all four fits (OpenBLAS threaded at one Julia thread, single-threaded inside the groups: the same bits).
2. **Faster on the heavy fits: PASS.** Median `forward_cache` speedup of the three heavy fits: 2.12× at 4 threads (criterion ≥ 2.0), 2.39× at 8 (≥ the 4-thread one).
3. **No regression on the small fit: PASS** after the size rules (the loops run threaded only from 4,096 atoms or beads, and the tile groups from `tiles × Q` ≥ 4,096): SASDMJ9 is 1.00× at every thread count. Before the rules it was 1.3–1.8× slower threaded; that first result failed this criterion and led to them.

Two bugs found by this validation and fixed: (a) `GCPause` left the garbage collector off for good when a worker thread ran a checkpoint (`GC.enable` is a per-thread switch), which took SASDUN5 to 6 GB; it is now the pausing thread that collects, while it waits for its tasks (peak 1.7 GB at any thread count); (b) the first design allocated one accumulator per tile group; the groups now run in waves with a pool of one per worker.

Memory: peak resident size of the static build of SASDUN5 is 1.7 GB at 1, 2, 4 and 8 threads.

### Sweep at 1, 2, 3, 4, 6, 7 and 8 threads (same day, after the group count went from 8 to 24)

24 groups divide evenly over 1, 2, 3, 4, 6, 8 and 12 workers (8 groups left 3, 5, 6 and 7 workers idle half the time). Gram fingerprints identical at all seven thread counts on all four fits. `forward_cache` speedups vs 1 thread (the 1-thread baseline of this particular run was inflated by a mistake of mine, a W budget divided by the group count, since corrected to a fixed 8 MiB per worker; at the corrected baseline, 6 threads give SASDUN5 3.48 s → 1.48 s, 2.4×, and SASDJ62 3.49 s → 1.85 s, 1.9×):

| | 2 thr | 3 | 4 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|
| SASDUN5 | 1.74 | 2.41 | 2.73 | 2.86 | 2.86 | 3.00 |
| SASDJ62 | 1.61 | 2.01 | 2.19 | 2.13 | 2.13 | 2.19 |
| SASDVG2 | 1.75 | 2.38 | 2.42 | 2.54 | 2.52 | 2.52 |
| SASDMJ9 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |

Forward cache plus SASA on the three heavy fits: 1.67× at 2, 2.19× at 3, 2.41× at 4, 2.46× at 6 and 7, 2.55× at 8 threads. The curve flattens above four threads. The 6-thread breakdown (indicative: the machine was not quiet) put the loss inside the parallel region of `B_lm`, not in serial code around it (SASDUN5 `B_lm` 2.33 s → 0.96 s, 2.4×; excluded volumes 4.2×; SASA 2.9×; hydration 1.7×). The likely cause is the machine's mixed cores (`cpu0–3` are efficiency cores at 2.4 GHz, `cpu4–7` performance cores at 3.2 GHz) and the barrier after every wave of groups, which waits for the slowest worker; dynamic scheduling with a fixed reduction order would address it, but the gain (a few tenths of a second on the largest structures) was judged not worth the complexity, and the experiment was not run.

### Bugs this validation and the concurrency suite found

See "Bugs this validation found" above. `test/unit_tests/units/test_concurrency.jl` now guards both: its worker-count and chaos-scheduling comparisons fail if workers share a buffer (checked by deliberately doing so), and its garbage-collector tests fail if a worker thread is allowed to switch the collector (also checked deliberately).
