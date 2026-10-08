# run

The entry points that run the tests.
[`../utils/`](../utils/README.md).


| script         | what it runs                                                                                                                                                    |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `unittests.jl` | the unit and integration suite: everything in`../unit_tests/units/`, in name order with `test_quality.jl` last                                                  |
| `fittings.tcl` | the end-to-end fitting tests in`../fitting_tests/`: the ones you name, or all of them; optionally the benchmark, the report and the sampler diagnostics on them |
| `vis.tcl`      | the visual checks in`../visualize/`: the ones you name, or all of them                                                                                          |
| `validate.tcl` | the validations in `../validation/`: slow, suite-wide checks of one change against criteria fixed before the run (`--list`; needs `--approved` to run) |
| `tcltests.tcl` | the tests of the Tcl tools in `../utils/` (`../utils/tests/*.test`, tcltest; ~1 s)                                                                               |
| `precommit.tcl` | everything to run before a commit: whitespace, Results table, Tcl-tool tests, unit suite, docs build (never a fit or a benchmark)                              |

```bash
julia --project=test test/run/unittests.jl                     # the whole unit suite (~90 s)
julia --project=test test/run/unittests.jl shannon wls         # only the test files whose name contains one of these words
tclsh test/run/fittings.tcl                                    # every fitting test
tclsh test/run/fittings.tcl SASDMJ9 SASDBS6                    # just these
tclsh test/run/fittings.tcl SASDMJ9 --report                   # run it, then print its Results-table row
tclsh test/run/fittings.tcl --no-fit --table                    # rewrite the Results table in fitting_tests/README.md from the reports
tclsh test/run/fittings.tcl SASDMJ9 --fixme                    # run it, then the sampler diagnostics
tclsh test/run/fittings.tcl SASDMJ9 --bench                    # prints the benchmark plan; runs no benchmark
tclsh test/run/fittings.tcl SASDMJ9 --bench --approved          # runs the benchmark (see below)
tclsh test/run/validate.tcl --list                              # the validations and their questions
tclsh test/run/validate.tcl map_fstop                           # prints the validation's plan; runs nothing
tclsh test/run/validate.tcl map_fstop --approved                # runs it on every fit (see below)
tclsh test/run/vis.tcl --list                                  # the visual checks
tclsh test/run/vis.tcl plastic_2d sasa_hydro_report            # just these
tclsh test/run/tcltests.tcl                                    # the Tcl tools' tests
tclsh test/run/precommit.tcl                                   # all pre-commit checks (~2 min)
tclsh test/run/precommit.tcl --quick                           # only the checks that take a second
```

Both Tcl scripts print their usage with `--help`, accept `--dry-run` (print the commands, run nothing), and
stop with a message before running anything if a name you give does not exist.

## `fittings.tcl`

```
tclsh test/run/fittings.tcl [ID ...] [--no-fit] [--bench] [--approved] [--report] [--table] [--fixme] [--dry-run]
```

- **`ID ...`** are folders of `test/fitting_tests/` (`SASDMJ9`, `SASDBS6`, ...). If none exist, nothing runs and the available folders are listed. With none given, every fitting test runs. Each fit is its script run with the `test/fitting_tests` environment; it rewrites its `res*.txt` and figures.
- **`--no-fit`** skips the fits themselves, for when only a later step is wanted.
- The steps run in a fixed order: the fits, then `--bench`, then `--report`, then `--table`, then `--fixme`. A failing step does not stop the later ones; the exit status is 1 if any failed.
- **`--bench`** also runs the cold / steady-state benchmark (`../utils/bench.tcl`) on the selected fits, one `ID[:tag]` per run of each script. **Without `--approved` this only prints the benchmark's plan and runs nothing.** **`--approved`** is passed to the benchmark. It exists because benchmark timings are only meaningful on a *quiet machine*, and AI agents tend to start a benchmark without checking that the machine is quiet; so a benchmark runs only after the repository owner has said yes to that run, which means they have confirmed nothing else is running. `--approved` without `--bench` is an error.
- **`--report`** prints the Results-table rows of the selected fits (`../utils/results_table.tcl`), from the reports the fits just wrote. To rewrite the table in `fitting_tests/README.md`, use `tclsh test/utils/results_table.tcl --update`.
- **`--table`** rewrites the Results table in `fitting_tests/README.md` from every report (`../utils/results_table.tcl --update`), whatever IDs are named.
- **`--fixme`** runs the sampler diagnostics (`../utils/diagnose.tcl report`) on every run of the selected fits: MAP starts, Hessian, step size and tree depth, gradient error, modes. Use it when a fit looks wrong.

## `validate.tcl`

```
tclsh test/run/validate.tcl --list
tclsh test/run/validate.tcl NAME [ID[:tag] ...] [--approved] [--dry-run]
```

Runs a **validation** (`../validation/NAME/`): a slow, suite-wide check of one change (the MAP search and Hessian of every fitting test, no sampling, no plotting) against criteria fixed before the run; see `../validation/README.md`. **Without `--approved` it only prints its plan and runs nothing**, because a validation takes minutes of one core and has to be approved per run. With it, the script runs in the `test/fitting_tests` environment, writes its per-fit rows to `../validation/NAME/results/NAME-<stamp>.tsv` and prints its verdict. An unknown name or fit ID stops before anything runs; a bare ID stands for every run of its script.

## `vis.tcl`

```
tclsh test/run/vis.tcl [NAME ...] [--list] [--dry-run]
```

- **`NAME ...`** are the visual checks (see `--list`): `plastic_2d`, `plastic_3d`, `sasa_hydro` and `sasa_hydro_report`. An unknown name stops the run before anything starts. With none given, every check runs, one after the other.
- Each check is one call in a fresh Julia process in `test/visualize`'s own environment. Everything but `sasa_hydro_report` opens a window, so it needs a display; `sasa_hydro_report` prints numbers only.

## `unittests.jl`

Runs every `../unit_tests/units/test_*.jl` (or, given words, the files whose name contains one of them; a word that matches no file is an error); a new test file is picked up by creating it there. Each file is also runnable on its own (`julia --project=test test/unit_tests/units/test_sampler.jl`).

## `tcltests.tcl`

Runs the [tcltest](https://www.tcl-lang.org/man/tcl9.0/TclCmd/tcltest.html) files `../utils/tests/*.test`, which cover the Tcl tools (`common.tcl`, `report.tcl`, `results_table.tcl`, `compare.tcl`, `bench.tcl`, `extract_formfactor.tcl` and the command-line front ends). They run no Julia, no fit and no benchmark (`bench.tcl` is tested only without `--approved`, on a sandbox). Any tcltest option is passed through (`-file 'compare*'`, `-verbose`); the exit status is 1 if a test fails.

## `precommit.tcl`

```
tclsh test/run/precommit.tcl [--quick] [--dry-run]
```

The single entry point to run before a commit. Steps, in order: **whitespace** (no trailing whitespace or conflict markers in what you changed, including untracked files), **results-table** (`results_table.tcl --check`: the Results table in `fitting_tests/README.md` is the one generated from the reports), **tcl-tests**, **unit-tests** (~90 s) and **docs-build** (~20 s, strict; the files it regenerates under `docs/src/` are listed, since they belong in the commit). Every step runs even if an earlier one failed, a summary says which did, and the exit status is 1 if any failed. `--quick` skips the two Julia steps; `--dry-run` prints the plan. It never runs a fitting test or a benchmark.

## Requirements

Tcl 9 and `julia` on the `PATH` (or `JULIA=/path/to/julia`). `--bench`, `--report` and `--fixme` use the tools in `../utils/`, which need Tcllib; see its README.
