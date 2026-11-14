# Tests

Everything under `test/` is a test, test data, an example fit that doubles as a test, or something that runs or
supports them.

| directory | contents |
|---|---|
| [`../dev/`](../dev/README.md) | the tools, outside `test/`: the Julia package `Dev` (`bysl fits`, `results`, `plots`, `fmt`, `precommit`, ...), its tests in `dev/test/`, `scripts/unittests.jl` and the other scripts the tools start |
| [`unit-tests/`](unit-tests/README.md) | the unit and integration suite: one `test-*.jl` per module in `units/`, the setup they share (`testsetup.jl`) and the float-compare and geometry helpers they include |
| [`baselines/`](baselines/README.md) | the reference benchmark run of each release, which `bysl results compare --bench` compares a new run with (and an untracked `results/` for runs that are not baselines) |
| [`fixtures/`](fixtures/README.md) | the data the tests read: real PDB/mmCIF structures, the sequence corpus, form-factor oracle values and the SASBDB entries |
| [`fitting_tests/`](fitting_tests/README.md) | 57 end-to-end SASBDB entries (27 protein, 30 DNA/RNA; 84 fits), each a script that doubles as a worked example, with the workbook of numbers, the timing table and the figures (`.tex`) it wrote |
| [`visualize/`](visualize/README.md) | optional visual checks for the geometry code (plotting; not part of the suite) |

Four Julia environments are involved: `test/` (the unit suite), `test/fitting_tests/` (no plotting package: the figures come from `BAYSOL.results`),
`test/visualize/` (GLMakie for the visual checks), and the root package.

```bash
julia --project=test dev/scripts/unittests.jl                 # the whole unit suite
bysl fits list                            # the fitting tests and their tags
bysl fits run SASDMJ9                      # one fitting test (all of them if none is named)
bysl plots render test/fitting_tests --recursive   # render the figures they wrote (PDF)
bysl vis --list                            # the visual checks
julia --project=test test/unit-tests/units/test-sampler.jl # one unit-test file
bysl precommit                             # all checks before a commit (unit suite, docs build, tool tests, ...)
```
