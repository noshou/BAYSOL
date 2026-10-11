# dev

Developer tools. Every one is a [Babashka](https://babashka.org) script in this folder (or in
`../test/utils/`) and has a short **`bb <task>`** name, defined in `bb.edn` at the repository root (see
*`bb.edn`: the `bb <task>` shortcuts* below); run `bb tasks` to list them.

```bash
bb unit                                              # the whole Julia unit suite (~5 min)
bb unit shannon wls                                  # only the test files whose name contains one of these words
bb fittings                                          # every fitting test
bb fittings SASDMJ9 SASDBS6                          # just these
bb fittings SASDMJ9 --report                         # run it, then print its Results-table row
bb fittings --no-fit --table                         # rewrite the Results table in fitting_tests/README.md from the reports
bb fittings SASDMJ9 --fixme                          # run it, then the sampler diagnostics
bb fittings SASDMJ9 --bench                          # prints the benchmark plan; runs no benchmark
bb fittings SASDMJ9 --bench --approved               # runs the benchmark (see below)
bb validate --list                                   # the validations and their questions
bb validate map_fstop                                # prints the validation's plan; runs nothing
bb validate map_fstop --approved                     # runs it on every fit (see below)
bb validate threading --threads 4 --approved         # any entry point takes --threads N (JULIA_NUM_THREADS: 4, auto, 4,1)
bb diagnose --warmup                                 # no fit named: every run of every fitting test (53)
bb diagnose SASDMJ9                                  # every diagnostic part on this fit
bb diagnose --warmup --seeds 1,2,3 SASDMJ9           # only the warm-up study, three RNG seeds
bb diagnose --report --out /tmp/d SASDBS6:fit2_model3   # one part, written to /tmp/d/report.txt
bb vis --list                                        # the visual checks
bb vis plastic_2d sasa_hydro_report                  # just these
bb test                                              # the dev tools' tests
bb test compare bench                                # only the test files with these words in their name
bb fmt                                               # format the Julia and Clojure/EDN code
bb fmt-check --clj                                   # only check the Clojure and EDN files
bb lint                                              # clj-kondo on the Clojure code
bb linelen --check                                   # lines over 92 characters, if any
bb docs                                              # build the documentation site (strict, ~20 s)
bb precommit                                         # all pre-commit checks (~6 min)
bb precommit --quick                                 # only the checks that take a second
```

Every script prints its usage with `--help`, and the ones that start work accept `--dry-run` (print the
commands, run nothing). They stop with a message before running anything if a name you give does not exist.
The scripts do not need `bb.edn`: `bb dev/fittings.clj SASDMJ9 --report` does the same as `bb fittings SASDMJ9
--report`, from any directory.

## `bb.edn`: the `bb <task>` shortcuts

`bb.edn` (at the repository root) is Babashka's project file, the counterpart of a `Makefile` or the `scripts` section of a
`package.json`. Here it only defines **tasks**: a short name for the command of each dev tool. `bb <task> args...`
runs the tool with the arguments you give (`bb fittings SASDMJ9 --report` runs `bb dev/fittings.clj SASDMJ9
--report`), and `bb tasks` lists them with a one-line description. Babashka reads the file from the current
directory, so run `bb <task>` from the repository root; the scripts themselves work from anywhere.

| Task | Runs | What it does |
|---|---|---|
| `bb fittings` | `dev/fittings.clj` | the fitting tests, with the report, table, diagnostics and benchmark steps |
| `bb diagnose` | `dev/diagnose.clj` | the sampler diagnostics on fits |
| `bb validate` | `dev/validate.clj` | the slow suite-wide validations (`--approved` to run) |
| `bb profile` | `dev/profile.clj` | profile the static build |
| `bb vis` | `dev/vis.clj` | the visual checks of the geometry code |
| `bb unit` | `julia dev/unittests.jl` | the Julia unit suite |
| `bb test` | `dev/tests.clj` | the tests of the dev tools |
| `bb precommit` | `dev/precommit.clj` | every check before a commit |
| `bb docs` | `julia docs/make.jl` | build the documentation site (docs/build) |
| `bb fmt`, `bb fmt-check` | `dev/format.clj --apply`, `--check` | format the code, or only list what is unformatted |
| `bb lint` | `clj-kondo --lint dev test/utils` | lint the Clojure code |
| `bb linelen` | `dev/linelen.clj` | the 92-character rule: `--check`, `--reflow`, `--snapshot`, `--verify` |
| `bb results-table` | `test/utils/results_table.clj` | the Results table in `fitting_tests/README.md` |
| `bb compare` | `test/utils/compare.clj` | compare fitting-test results between git revisions |
| `bb bench` | `test/utils/bench.clj` | the cold / steady-state benchmark (prints its plan without `--approved`) |
| `bb extract-formfactor` | `test/utils/extract_formfactor.clj` | rebuild the form-factor table from `xraydb.sqlite` |

To add a tool, give it a task in `bb.edn` with the `script` helper defined at the top of the file
(`mytool {:doc "..." :task (script "dev/mytool.clj")}`) and a row here. `bb.edn` is formatted like the code
(`bb fmt`), and its lines obey the 92-character rule.

## `bb fittings` (`fittings.clj`)

```
bb fittings [ID ...] [--no-fit] [--bench] [--approved] [--report] [--table] [--fixme] [--trace-compile FILE] [--dry-run]
```

- **`ID ...`** are folders of `test/fitting_tests/` (`SASDMJ9`, `SASDBS6`, ...). If none exist, nothing runs and the available folders are listed. With none given, every fitting test runs. Each fit is its script run with the `test/fitting_tests` environment; it rewrites its `res*.txt` and figures.
- **`--no-fit`** skips the fits themselves, for when only a later step is wanted.
- The steps run in a fixed order: the fits, then `--bench`, then `--report`, then `--table`, then `--fixme`. A failing step does not stop the later ones; the exit status is 1 if any failed.
- **`--bench`** also runs the cold / steady-state benchmark (`../test/utils/bench.clj`) on the selected fits, one `ID[:tag]` per run of each script. **Without `--approved` this only prints the benchmark's plan and runs nothing.** **`--approved`** is passed to the benchmark. It exists because benchmark timings are only meaningful on a *quiet machine*, and AI agents tend to start a benchmark without checking that the machine is quiet; so a benchmark runs only after the repository owner has said yes to that run, which means they have confirmed nothing else is running. `--approved` without `--bench` is an error.
- **`--report`** prints the Results-table rows of the selected fits (`../test/utils/results_table.clj`), from the reports the fits just wrote. To rewrite the table in `fitting_tests/README.md`, use `bb results-table --update`.
- **`--table`** rewrites the Results table in `fitting_tests/README.md` from every report (`../test/utils/results_table.clj --update`), whatever IDs are named.
- **`--trace-compile FILE`** runs the fits with Julia's `--trace-compile=FILE`: the file lists the methods each fit's process had to compile at run time, i.e. what a precompile workload has not covered.
- **`--fixme`** runs the sampler diagnostics (`diagnose.clj --report`) on every run of the selected fits: MAP starts, Hessian, step size and tree depth, gradient error, modes. Use it when a fit looks wrong.

## `bb profile` (`profile.clj`)

```
bb profile ID[:tag] [ID[:tag] ...] [--delay SECONDS] [--dry-run]
```

Builds the `Seed` of each fitting test twice in one process (the first call warms the compiler) and profiles the second with Julia's sampling profiler: the stage timings of that build and the samples by function, charged to the innermost BAYSOL function (its own code plus the libraries it calls) and inclusive. The profiler slows the code by a factor of several, so read the proportions, not the seconds. It is how the time in `forward_cache` was found; use `bb fittings --bench --approved` or the reports to measure a change.

## `bb validate` (`validate.clj`)

```
bb validate --list
bb validate NAME [ID[:tag] ...] [--approved] [--dry-run]
```

Runs a **validation** (`../test/validation/NAME/`): a slow, suite-wide check of one change (the MAP search and Hessian of every fitting test, no sampling, no plotting) against criteria fixed before the run; see `../test/validation/README.md`. **Without `--approved` it only prints its plan and runs nothing**, because a validation takes minutes of one core and has to be approved per run. With it, the script runs in the `test/fitting_tests` environment, writes its per-fit rows to `../test/validation/NAME/results/NAME-<stamp>.tsv` and prints its verdict. An unknown name or fit ID stops before anything runs; a bare ID stands for every run of its script.

## `bb vis` (`vis.clj`)

```
bb vis [NAME ...] [--list] [--dry-run]
```

- **`NAME ...`** are the visual checks (see `--list`): `plastic_2d`, `plastic_3d`, `sasa_hydro` and `sasa_hydro_report`. An unknown name stops the run before anything starts. With none given, every check runs, one after the other.
- Each check is one call in a fresh Julia process in `test/visualize`'s own environment. Everything but `sasa_hydro_report` opens a window, so it needs a display; `sasa_hydro_report` prints numbers only.

## `bb unit` (`unittests.jl`)

Runs every `../test/unit_tests/units/test_*.jl` (or, given words, the files whose name contains one of them; a word that matches no file is an error); a new test file is picked up by creating it there. Each file is also runnable on its own (`julia --project=test test/unit_tests/units/test_sampler.jl`).

## `bb test` (`tests.clj`)

Runs the [clojure.test](https://clojure.github.io/clojure/clojure.test-api.html) files `../test/utils/tests/*_test.clj`, which cover the dev tools (`common.clj`, `report.clj`, `results_table.clj`, `compare.clj`, `bench.clj`, `extract_formfactor.clj` and the command-line front ends). They run no Julia, no fit and no benchmark (`bench.clj` is tested only without `--approved`, on a sandbox). Given words, only the test files whose name contains one of them run (`bb test compare bench`); the exit status is 1 if a test fails.

## `bb fmt`, `bb lint` and `bb linelen` (`format.clj`, `linelen.clj`)

```
bb fmt [--julia|--clj] [PATH ...]          # format (rewrite the files)
bb fmt-check [--julia|--clj] [PATH ...]    # only list what is not formatted
bb lint                                    # clj-kondo
bb linelen --check [PATH ...]
bb linelen --reflow [PATH ...]
```

The code rule of the repository is **at most 92 characters per line** in code files (`.jl`, `.clj`, `.edn`,
`.scss`, `.yml`; not Markdown or data). `format.clj` formats the Julia files with
[JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl) (settings in `.JuliaFormatter.toml` at the
root, its own environment in `test/format`) and the Clojure and EDN files (`bb.edn`, `.clj-kondo/config.edn`) with [zprint](https://github.com/kkinnear/zprint) (code lines wrapped at 84 characters, which leaves
room for the re-indentation below; the options are `zprint-options` in `format.clj`, which runs it through Babashka's
dependency support and needs `java`) followed by `reindent`, which sets the indentation: a continuation line is
indented 4 more than the line that opened its bracket, plus 4 for each further bracket still open from that same
line, so every indentation is a multiple of 4 and inherits from its parent line (zprint alone aligns arguments under
the first one, which depends on where the bracket sits on its line). Both wrap code lines but not comments, docstring text or string literals:
`linelen.clj --reflow` re-wraps the comment blocks and docstring paragraphs that contain an over-long line, with
the lines balanced (about equally long, no stray last word), and moves a trailing comment above its line when it
makes a line too long. `--snapshot DIR` and `--verify DIR` check that such a pass changed no code: Julia files are
compared as syntax trees (whitespace inside strings and docstrings normalized), Clojure files by their forms.
Lines that cannot be split automatically (long string literals) are split by hand.

## `bb docs`

```
bb docs
```

Builds the documentation site with Documenter.jl in `../docs/` (`julia --project=docs docs/make.jl`, with `JULIA`
honoured as for the other tools), strict: a broken cross-reference or an undocumented docstring fails the build.
First it copies the READMEs of `src/` and `test/` into `docs/src/guides/` and `docs/src/testing/` (edit a README,
never its copy), so this very page is part of the site. It takes about 20 s and writes the site to
`../docs/build/` (open `docs/build/index.html`). It is a task in `bb.edn` and not a script of its own, and
`bb precommit` runs the same build as its last step.

## `bb precommit` (`precommit.clj`)

```
bb precommit [--quick] [--dry-run]
```

The single entry point to run before a commit; a failing step does not stop the later ones and the exit status is 1
if any failed. Steps, in order: **tool-tests**, **unit-tests** (~5 min), **concurrency-tests**, **whitespace**
(trailing whitespace on the lines you changed, untracked files included, is stripped and reported, never a
failure; only a leftover conflict marker fails), **clj-format**, **julia-format**, **clj-lint** (clj-kondo,
settings in `.clj-kondo/config.edn`), **line-length** (a line over 92 characters refuses the commit),
**results-table** and **docs-build** (the strict documentation build, ~1 min). `--quick` skips the Julia steps
(unit-tests, concurrency-tests, julia-format, docs-build). It never runs a fitting test or a benchmark.

## Requirements

[Babashka](https://babashka.org) (its `bb` also runs the tasks of `bb.edn`), `java` (for zprint) and [clj-kondo](https://github.com/clj-kondo/clj-kondo) on the `PATH`, and `julia` (or `JULIA=/path/to/julia`) for everything that runs Julia. `--bench`, `--report` and `--fixme` use the tools in `../test/utils/`; see its README.
