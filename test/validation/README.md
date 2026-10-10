# Validation

Slow, suite-wide checks that a change does what it should, run once per change against criteria written down before the run. They are not unit tests (those take seconds and run on every commit, `../unit_tests/`), not fitting tests (worked examples, `../fitting_tests/`) and not benchmarks (timings on a quiet machine, `../utils/bench.tcl`): a validation runs part of the fitting pipeline (the MAP search, the Hessian) on every fitting test, takes minutes of one core, and its verdict is a statement about distributions over the 53 fits, not about one fit.

```bash
tclsh dev/validate.tcl --list                       # the validations and the question each answers
tclsh dev/validate.tcl map_fstop                    # prints the plan; runs nothing
tclsh dev/validate.tcl map_fstop --approved         # runs it on every fitting test
tclsh dev/validate.tcl map_fstop SASDMJ9 SASDBS6 --approved   # or on some
```

Like the benchmark, a validation only runs with `--approved`, after the repository owner has approved that run.

## Convention

Each validation is a folder with:

- `README.md`: the question (first paragraph, which `--list` prints), the criteria **with the date they were fixed**, and the outcome. Criteria are judged over distributions (fit quality, the distribution of the fitted parameters, the health of the regression), not by per-fit shifts in an unrealistically narrow posterior. A criterion changed after the data was seen is recorded as changed, with the reason, and checked on a fresh run.
- `validate.jl`: the Julia script, run in the `test/fitting_tests` environment; takes `--out FILE.tsv` and the `ID[:tag]` specs, builds each fit's `Seed` through `../utils/fit_seed.jl`, never samples and never plots.
- `results/`: the per-fit rows of the run that decided it, kept as evidence.

| validation | question |
|---|---|
| [`shannon_binning/`](shannon_binning/README.md) | Does fitting the curve binned to Shannon channels give the same answer as fitting every point? |
| [`map_fstop/`](map_fstop/README.md) | Does stopping each MAP start on f (not only on the gradient) change what the MAP search finds? |
| [`threading/`](threading/README.md) | Does threading a stage change what it computes (bit for bit) and is it faster? |

The feature-level correctness of what a validation covers is a unit test (for example `test_shannon.jl`, and the f-stop test in `test_sampler.jl`); the validation answers whether the change is safe on real data.
