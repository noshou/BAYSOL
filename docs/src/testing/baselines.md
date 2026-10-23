# baselines

Reference benchmark runs: one per release, kept so that a later change can be compared with the release it follows.
A baseline is the JSON result of `dev/bench.clj` (see the Benchmarks section of
[`../../dev/README.md`](dev.md)), saved here when a release is made.

| file | what it is |
|---|---|
| `<release tag>-<state>-<host>.json` | the benchmark of that release on that machine: `state` is `cold` or `warm`, `host` the machine's name. For example `v0.3.0-wʋsg_n_yɩɩda-cold-asahi-box.json`. |
| `v0.3.0-wʋsg_n_yɩɩda-cold-asahi-box.json` | the first baseline: the release's cold benchmark (wiped depot, a real precompile, PROPKA and pdb2pqr run for real; SASDMJ9, SASDBS6:fit2_model3, SASDJ62; Apple M2, Asahi Linux, Julia 1.12.7, 4 threads), captured at the clean commit `cc3f962` with the Tcl version of `bench` just before the tools moved to Babashka. |
| `v0.3.0-wʋsg_n_yɩɩda-warm-asahi-box.json` | the same fits on the warm depot and repository, for the record (its revision is marked `+dirty`: the cold file was already in the tree). Never quote a warm number as what a user gets. |
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
  `res*.txt` reports, which are warm-cache and are compared with `compare.clj` (no `--bench`).
