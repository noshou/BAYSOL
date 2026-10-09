# Tests

Everything under `test/` is a test, test data, an example fit that doubles as a test, or something that runs or
supports them.

| directory | contents |
|---|---|
| [`run/`](run/README.md) | the entry points: `unittests.jl`, `fittings.tcl` (fitting tests, with optional benchmark, report and diagnostics), `vis.tcl` (visual checks), `validate.tcl` (the validations), `tcltests.tcl` (tests of the Tcl tools) and `precommit.tcl` (every check to run before a commit) |
| [`unit_tests/`](unit_tests/README.md) | the unit and integration suite: one `test_*.jl` per module in `units/`, and the setup they share (`testsetup.jl`) |
| [`utils/`](utils/README.md) | the tools and shared helpers: result comparison, the Results-table generator, sampler diagnostics, the benchmark driver, the form-factor table builder, and the float-compare and geometry helpers the unit tests include, and the tests of those Tcl tools (`utils/tests/`) |
| [`baselines/`](baselines/README.md) | the reference benchmark run of each release, which `compare.tcl --bench` compares a new run with (and an untracked `results/` for runs that are not baselines) |
| [`validation/`](validation/README.md) | slow, suite-wide validations of one change against criteria fixed before the run (Shannon binning, the MAP f-stop), run by `run/validate.tcl`, each with its evidence |
| [`fixtures/`](fixtures/README.md) | the data the tests read: real PDB/mmCIF structures, the sequence corpus, form-factor oracle values and the SASBDB entries |
| [`fitting_tests/`](fitting_tests/README.md) | 27 end-to-end SASBDB fits (53 runs), each a script that doubles as a worked example, with the report and figures it wrote |
| [`visualize/`](visualize/README.md) | optional visual checks for the geometry code (plotting; not part of the suite) |

Four Julia environments are involved: `test/` (the unit suite), `test/fitting_tests/` (adds GLMakie for the figures),
`test/visualize/` (GLMakie for the visual checks), and the root package.

```bash
julia --project=test test/run/unittests.jl                 # the whole unit suite (~90 s)
tclsh test/run/fittings.tcl SASDMJ9                        # one fitting test (all of them if none is named)
tclsh test/run/vis.tcl --list                              # the visual checks
julia --project=test test/unit_tests/units/test_sampler.jl # one unit-test file
tclsh test/run/precommit.tcl                               # all checks before a commit (unit suite, docs build, Tcl tests, ...)
```
