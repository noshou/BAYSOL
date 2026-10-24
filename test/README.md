# Tests

Everything under `test/` is a test, test data, an example fit that doubles as a test, or something that runs or
supports them.

| directory | contents |
|---|---|
| [`../dev/`](../dev/README.md) | the tools, outside `test/`: `unittests.jl`, `fittings.clj` (fitting tests, with optional benchmark, report and diagnostics), `vis.clj`, `diagnose.clj`, `compare.clj`, `results_table.clj`, `bench.clj`, `tests.clj` with the tests of the tools (`tool_tests/`), the formatter, re-wrapping and line-length rule, and `precommit.clj` (every check to run before a commit) |
| [`unit_tests/`](unit_tests/README.md) | the unit and integration suite: one `test_*.jl` per module in `units/`, the setup they share (`testsetup.jl`) and the float-compare and geometry helpers they include |
| [`baselines/`](baselines/README.md) | the reference benchmark run of each release, which `compare.clj --bench` compares a new run with (and an untracked `results/` for runs that are not baselines) |
| [`fixtures/`](fixtures/README.md) | the data the tests read: real PDB/mmCIF structures, the sequence corpus, form-factor oracle values and the SASBDB entries |
| [`fitting_tests/`](fitting_tests/README.md) | 57 end-to-end SASBDB entries (27 protein, 30 DNA/RNA; 84 fits), each a script that doubles as a worked example, with the report and figures it wrote |
| [`visualize/`](visualize/README.md) | optional visual checks for the geometry code (plotting; not part of the suite) |

Four Julia environments are involved: `test/` (the unit suite), `test/fitting_tests/` (adds GLMakie for the figures),
`test/visualize/` (GLMakie for the visual checks), and the root package.

```bash
julia --project=test dev/unittests.jl                 # the whole unit suite
bb fittings SASDMJ9                        # one fitting test (all of them if none is named)
bb vis --list                              # the visual checks
julia --project=test test/unit_tests/units/test_sampler.jl # one unit-test file
bb precommit                               # all checks before a commit (unit suite, docs build, tool tests, lint, ...)
```
