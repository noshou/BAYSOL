# baselines

Reference benchmark runs: one per release, kept so that a later change can be compared with the release it follows.
A baseline is the JSON result of `test/utils/bench.tcl` (see the Benchmarks section of
[`../utils/README.md`](../utils/README.md)), saved here when a release is made.

| file | what it is |
|---|---|
| `<release tag>-<state>-<host>.json` | the benchmark of that release on that machine: `state` is `cold` or `warm`, `host` the machine's name. For example `v0.3.0-wʋsg_n_yɩɩda-cold-asahi-box.json`. |
| `results/` | where `bench.tcl` writes a run when `--out` is not given. Not tracked (listed in `.gitignore`); move a result up a level and rename it to make it a baseline. |

```bash
# at a release, on a quiet machine, with the owner's approval of this run:
tclsh test/utils/bench.tcl --approved --state cold --out test/baselines/<release tag>-cold-$(hostname).json SASDMJ9 SASDBS6:fit2_model3 SASDJ62

# afterwards: compare a new run with the baseline of the latest release (the newest `v<digit>…` tag)
tclsh test/utils/compare.tcl --bench test/baselines/results/<new run>.json
```

## Rules

- A baseline is **machine-specific** (the host and CPU are recorded in its `meta`): only compare runs from the same host,
  and, like with like, a cold run with a cold run. `compare.tcl --bench` warns when the files differ in host or state.
- The default comparison is with the **latest release**, found by `compare.tcl` as the most recently created tag whose
  name starts with `v` and a digit. Name another baseline file explicitly to compare with anything else.
- A baseline is only ever captured with the repository owner's approval of that run (`bench.tcl` refuses to start without
  `--approved`), because a benchmark needs a quiet machine.
- There is no baseline for `v0.2.0-soukouratou`: it predates the benchmark tooling. Its timings exist only as the committed
  `res*.txt` reports, which are warm-cache and are compared with `compare.tcl` (no `--bench`).
