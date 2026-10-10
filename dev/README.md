# dev

Developer tools.

```bash
julia --project=test dev/unittests.jl                     # the whole unit suite (~90 s)
julia --project=test dev/unittests.jl shannon wls         # only the test files whose name contains one of these words
tclsh dev/fittings.tcl                                    # every fitting test
tclsh dev/fittings.tcl SASDMJ9 SASDBS6                    # just these
tclsh dev/fittings.tcl SASDMJ9 --report                   # run it, then print its Results-table row
tclsh dev/fittings.tcl --no-fit --table                    # rewrite the Results table in fitting_tests/README.md from the reports
tclsh dev/fittings.tcl SASDMJ9 --fixme                    # run it, then the sampler diagnostics
tclsh dev/fittings.tcl SASDMJ9 --bench                    # prints the benchmark plan; runs no benchmark
tclsh dev/fittings.tcl SASDMJ9 --bench --approved          # runs the benchmark (see below)
tclsh dev/validate.tcl --list                              # the validations and their questions
tclsh dev/validate.tcl map_fstop                           # prints the validation's plan; runs nothing
tclsh dev/validate.tcl map_fstop --approved                # runs it on every fit (see below)
tclsh dev/validate.tcl threading --threads 4 --approved     # any entry point takes --threads N (JULIA_NUM_THREADS: 4, auto, 4,1)
tclsh dev/diagnose.tcl --warmup                            # no fit named: every run of every fitting test (53)
tclsh dev/diagnose.tcl SASDMJ9                              # every diagnostic part on this fit
tclsh dev/diagnose.tcl --warmup --seeds 1,2,3 SASDMJ9      # only the warm-up study, three RNG seeds
tclsh dev/diagnose.tcl --report --out /tmp/d SASDBS6:fit2_model3   # one part, written to /tmp/d/report.txt
tclsh dev/vis.tcl --list                                  # the visual checks
tclsh dev/vis.tcl plastic_2d sasa_hydro_report            # just these
tclsh dev/tcltests.tcl                                    # the Tcl tools' tests
tclsh dev/format.tcl --apply                              # format the Julia and Tcl code
tclsh dev/format.tcl --check --tcl                        # only check the Tcl files
tclsh dev/linelen.tcl --check                             # lines over 92 characters, if any
tclsh dev/precommit.tcl                                   # all pre-commit checks (~5 min)
tclsh dev/precommit.tcl --quick                           # only the checks that take a second
```

Both Tcl scripts print their usage with `--help`, accept `--dry-run` (print the commands, run nothing), and
stop with a message before running anything if a name you give does not exist.

## `fittings.tcl`

```
tclsh dev/fittings.tcl [ID ...] [--no-fit] [--bench] [--approved] [--report] [--table] [--fixme] [--trace-compile FILE] [--dry-run]
```

- **`ID ...`** are folders of `test/fitting_tests/` (`SASDMJ9`, `SASDBS6`, ...). If none exist, nothing runs and the available folders are listed. With none given, every fitting test runs. Each fit is its script run with the `test/fitting_tests` environment; it rewrites its `res*.txt` and figures.
- **`--no-fit`** skips the fits themselves, for when only a later step is wanted.
- The steps run in a fixed order: the fits, then `--bench`, then `--report`, then `--table`, then `--fixme`. A failing step does not stop the later ones; the exit status is 1 if any failed.
- **`--bench`** also runs the cold / steady-state benchmark (`../test/utils/bench.tcl`) on the selected fits, one `ID[:tag]` per run of each script. **Without `--approved` this only prints the benchmark's plan and runs nothing.** **`--approved`** is passed to the benchmark. It exists because benchmark timings are only meaningful on a *quiet machine*, and AI agents tend to start a benchmark without checking that the machine is quiet; so a benchmark runs only after the repository owner has said yes to that run, which means they have confirmed nothing else is running. `--approved` without `--bench` is an error.
- **`--report`** prints the Results-table rows of the selected fits (`../test/utils/results_table.tcl`), from the reports the fits just wrote. To rewrite the table in `fitting_tests/README.md`, use `tclsh test/utils/results_table.tcl --update`.
- **`--table`** rewrites the Results table in `fitting_tests/README.md` from every report (`../test/utils/results_table.tcl --update`), whatever IDs are named.
- **`--trace-compile FILE`** runs the fits with Julia's `--trace-compile=FILE`: the file lists the methods each fit's process had to compile at run time, i.e. what a precompile workload has not covered.
- **`--fixme`** runs the sampler diagnostics (`diagnose.tcl --report`) on every run of the selected fits: MAP starts, Hessian, step size and tree depth, gradient error, modes. Use it when a fit looks wrong.

## `profile.tcl`

```
tclsh dev/profile.tcl ID[:tag] [ID[:tag] ...] [--delay SECONDS] [--dry-run]
```

Builds the `Seed` of each fitting test twice in one process (the first call warms the compiler) and profiles the second with Julia's sampling profiler: the stage timings of that build and the samples by function, charged to the innermost BAYSOL function (its own code plus the libraries it calls) and inclusive. The profiler slows the code by a factor of several, so read the proportions, not the seconds. It is how the time in `forward_cache` was found; use `fittings.tcl --bench --approved` or the reports to measure a change.

## `validate.tcl`

```
tclsh dev/validate.tcl --list
tclsh dev/validate.tcl NAME [ID[:tag] ...] [--approved] [--dry-run]
```

Runs a **validation** (`../test/validation/NAME/`): a slow, suite-wide check of one change (the MAP search and Hessian of every fitting test, no sampling, no plotting) against criteria fixed before the run; see `../test/validation/README.md`. **Without `--approved` it only prints its plan and runs nothing**, because a validation takes minutes of one core and has to be approved per run. With it, the script runs in the `test/fitting_tests` environment, writes its per-fit rows to `../test/validation/NAME/results/NAME-<stamp>.tsv` and prints its verdict. An unknown name or fit ID stops before anything runs; a bare ID stands for every run of its script.

## `vis.tcl`

```
tclsh dev/vis.tcl [NAME ...] [--list] [--dry-run]
```

- **`NAME ...`** are the visual checks (see `--list`): `plastic_2d`, `plastic_3d`, `sasa_hydro` and `sasa_hydro_report`. An unknown name stops the run before anything starts. With none given, every check runs, one after the other.
- Each check is one call in a fresh Julia process in `test/visualize`'s own environment. Everything but `sasa_hydro_report` opens a window, so it needs a display; `sasa_hydro_report` prints numbers only.

## `unittests.jl`

Runs every `../test/unit_tests/units/test_*.jl` (or, given words, the files whose name contains one of them; a word that matches no file is an error); a new test file is picked up by creating it there. Each file is also runnable on its own (`julia --project=test test/unit_tests/units/test_sampler.jl`).

## `tcltests.tcl`

Runs the [tcltest](https://www.tcl-lang.org/man/tcl9.0/TclCmd/tcltest.html) files `../test/utils/tests/*.test`, which cover the Tcl tools (`common.tcl`, `report.tcl`, `results_table.tcl`, `compare.tcl`, `bench.tcl`, `extract_formfactor.tcl` and the command-line front ends). They run no Julia, no fit and no benchmark (`bench.tcl` is tested only without `--approved`, on a sandbox). Any tcltest option is passed through (`-file 'compare*'`, `-verbose`); the exit status is 1 if a test fails.

## `format.tcl` and `linelen.tcl`

```
tclsh dev/format.tcl (--apply|--check) [--julia|--tcl] [PATH ...]
tclsh dev/linelen.tcl --check [PATH ...]
tclsh dev/linelen.tcl --reflow [PATH ...]
```

The code rule of the repository is **at most 92 characters per line** in code files (`.jl`, `.tcl`, `.test`,
`.scss`, `.yml`; not Markdown or data). `format.tcl` formats the Julia files with
[JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl) (settings in `.JuliaFormatter.toml` at the
root, its own environment in `test/format`) and the Tcl files with `tclfmt` (indentation and spacing only: it does
not wrap lines). JuliaFormatter wraps code lines but not comments, docstring text or string literals:
`linelen.tcl --reflow` re-wraps the comment blocks and docstring paragraphs that contain an over-long line, with
the lines balanced (about equally long, no stray last word), and moves a trailing comment above its line when it
makes a line too long. `--snapshot DIR` and `--verify DIR` check that such a pass changed no code: Julia files are
compared as syntax trees (whitespace inside strings and docstrings normalized), Tcl files by their words.
Lines that cannot be split automatically (long string literals) are split by hand.

## `precommit.tcl`

```
tclsh dev/precommit.tcl [--quick] [--dry-run]
```

The single entry point to run before a commit; a failing step does not stop the later ones and the exit status is 1
if any failed. Steps, in order: **tcl-tests**, **unit-tests** (~90 s), **concurrency-tests**, **tcl-format**,
**julia-format**, **line-length** (a line over 92 characters refuses the commit), **whitespace** (trailing
whitespace on the lines you changed, untracked files included, is stripped and reported, never a failure; only a
leftover conflict marker fails), **results-table** and **docs-build** (the strict documentation build, ~20 s).
`--quick` skips the Julia steps (unit-tests, concurrency-tests, julia-format, docs-build). It never runs a fitting
test or a benchmark.

## Requirements

Tcl 9 and `julia` on the `PATH` (or `JULIA=/path/to/julia`). `--bench`, `--report` and `--fixme` use the tools in `../test/utils/`, which need Tcllib; see its README.
