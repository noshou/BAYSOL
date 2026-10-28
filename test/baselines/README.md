# baselines

Reference benchmark runs: one per release, kept so that a later change can be compared with the release it follows.
A baseline is the JSON result of `dev/bench.clj` (see the Benchmarks section of
[`../../dev/README.md`](../../dev/README.md)), saved here when a release is made.

| file | what it is |
|---|---|
| `<release tag>-<state>-<host>.json` | the benchmark of that release on that machine: `state` is `cold` or `warm`, `host` the machine's name. For example `v0.3.0-wʋsg_n_yɩɩda-cold-asahi-box.json`. |
| `v0.3.0-wʋsg_n_yɩɩda-cold-asahi-box.json` | the first baseline: the release's cold benchmark (wiped depot, a real precompile, PROPKA and pdb2pqr run for real; SASDMJ9, SASDBS6:fit2_model3, SASDJ62; Apple M2, Asahi Linux, Julia 1.12.7, 4 threads), captured at the clean commit `cc3f962` with the Tcl version of `bench` just before the tools moved to Babashka. |
| `v0.3.0-wʋsg_n_yɩɩda-warm-asahi-box.json` | the same fits on the warm depot and repository, for the record (its revision is marked `+dirty`: the cold file was already in the tree). Never quote a warm number as what a user gets. |
| `v0.4.0-yals-n-gɛsga-cold-asahi-box.json` | the cold benchmark of v0.4.0 (same fits, machine and protocol as the v0.3.0 baseline, **4 threads** and **`rng_seed = 1`** pinned in the measured process), captured at commit `dbe06ee` with uncommitted changes (`+dirty`): the release commit did not exist yet. Re-measuring v0.3.0 the same way on the same day (kept untracked): first fit SASDMJ9 15.2 s to 14.7 s, SASDJ62 4.9 s to 5.1 s; steady fit SASDMJ9 0.83 s to 0.80 s, SASDJ62 2.84 s to 2.92 s, the same eight chains in both (within 4 %). SASDBS6:fit2_model3 differs because its buffer prior changed with the solute table: the same seed starts two extra chains in v0.3.0 (10 chains, steady 2.20 s) and none in v0.4.0 (8 chains, steady 1.67 s). `using BAYSOL` 1.8 s to 2.5 s (UnicodePlots 0.5 s, XLSX 0.1 s); install and precompile 122 s to 163 s (v0.3.0 not re-measured). |
| `v0.4.0-yals-n-gɛsga-warm-asahi-box.json` | the same fits on the warm depot and repository, for the record (4 threads, `rng_seed = 1`). |
| `results/` | where `bench.clj` writes a run when `--out` is not given. Not tracked (listed in `.gitignore`); move a result up a level and rename it to make it a baseline. |

```bash
# at a release, on a quiet machine, with the owner's approval of this run:
bb bench --approved --state cold --out test/baselines/<release tag>-cold-$(hostname).json SASDMJ9 SASDBS6:fit2_model3 SASDJ62

# afterwards: compare a new run with the baseline of the latest release (the newest `v<digit>…` tag)
bb compare --bench test/baselines/results/<new run>.json
```

## Rules

- A baseline is **machine-specific** (the host and CPU are recorded in its `meta`): only compare runs from the same host,
  and, like with like, a cold run with a cold run. `compare.clj --bench` warns when the files differ in host or state.
- The default comparison is with the **latest release**, found by `compare.clj` as the most recently created tag whose
  name starts with `v` and a digit. Name another baseline file explicitly to compare with anything else.
- A baseline is only ever captured with the repository owner's approval of that run (`bench.clj` refuses to start without
  `--approved`), because a benchmark needs a quiet machine.
- There is no baseline for `v0.2.0-soukouratou`: it predates the benchmark tooling. Its timings exist only as the committed
  run logs (`<ID>.LOG`, or `res*.txt` reports before them), which are warm-cache and are compared with `compare.clj` (no `--bench`).
