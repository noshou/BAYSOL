# dev

Developer tools. Every one is a [Babashka](https://babashka.org) script in this folder (or in
`../test/utils/`) and has a short **`bb <task>`** name, defined in `bb.edn` at the repository root (see
*`bb.edn`: the `bb <task>` shortcuts* below); run `bb tasks` to list them.

```bash
bb unit                                               # the whole Julia unit suite
bb unit shannon wls                                   # only the test files whose name contains one of these words
bb fittings                                           # every fitting test
bb fittings SASDMJ9 SASDBS6                           # just these
bb fittings SASDMJ9 --report                          # run it, then print its Results-table row
bb fittings --no-fit --table                          # rewrite the Results table in fitting_tests/README.md from the reports
bb fittings SASDMJ9 --fixme                           # run it, then the sampler diagnostics
bb fittings SASDMJ9 --bench                           # prints the benchmark plan; runs no benchmark
bb fittings SASDMJ9 --bench --approved                # runs the benchmark (see below)
bb validate --list                                    # the validations and their questions
bb validate map_fstop                                 # prints the validation's plan; runs nothing
bb validate map_fstop --approved                      # runs it on every fit (see below)
bb validate threading --threads 4 --approved          # any entry point takes --threads N (JULIA_NUM_THREADS: 4, auto, 4,1)
bb diagnose --warmup                                  # no fit named: every run of every fitting test (53)
bb diagnose SASDMJ9                                   # every diagnostic part on this fit
bb diagnose --warmup --seeds 1,2,3 SASDMJ9            # only the warm-up study, three RNG seeds
bb diagnose --report --out /tmp/d SASDBS6:fit2_model3 # one part, written to /tmp/d/report.txt
bb vis --list                                         # the visual checks
bb vis plastic_2d sasa_hydro_report                   # just these
bb test                                               # the dev tools' tests
bb test compare bench                                 # only the test files with these words in their name
bb fmt                                                # format the Julia and Clojure/EDN code
bb fmt-check --clj                                    # only check the Clojure and EDN files
bb lint                                               # clj-kondo on the Clojure code
bb linelen --check                                    # lines over 92 characters, if any
bb docs                                               # build the documentation site (strict)
bb precommit                                          # all pre-commit checks
bb precommit --quick                                  # only the checks that take a second
```

Every script prints its usage with `--help`, and the ones that start work accept `--dry-run` (print the
commands, run nothing). They stop before running anything if a name you give does not exist.

## Tasks

`bb.edn` (repository root) defines a short `bb <task>` name for each tool; `bb tasks` lists them. Run `bb <task>` from the repository root. The scripts themselves work from anywhere (`bb dev/fittings.clj ...` is the same as `bb fittings ...`).


| Task                     | Runs                                | What it does                                                                                         |
| -------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `bb fittings`            | `dev/fittings.clj`                  | the fitting tests, with the report, table, diagnostics and benchmark steps                           |
| `bb diagnose`            | `dev/diagnose.clj`                  | the sampler diagnostics on fits                                                                      |
| `bb validate`            | `dev/validate.clj`                  | the slow suite-wide validations (`--approved` to run)                                                |
| `bb profile`             | `dev/profile.clj`                   | profile the static build                                                                             |
| `bb vis`                 | `dev/vis.clj`                       | the visual checks of the geometry code                                                               |
| `bb unit`                | `julia dev/unittests.jl`            | the Julia unit suite                                                                                 |
| `bb test`                | `dev/tests.clj`                     | the tests of the dev tools                                                                           |
| `bb precommit`           | `dev/precommit.clj`                 | every check before a commit                                                                          |
| `bb docs`                | `julia docs/make.jl`                | build the documentation site (docs/build)                                                            |
| `bb fmt`, `bb fmt-check` | `dev/format.clj --apply`, `--check` | format the code, or only list what is unformatted                                                    |
| `bb lint`                | `clj-kondo --lint dev test/utils`   | lint the Clojure code                                                                                |
| `bb linelen`             | `dev/linelen.clj`                   | the 92-character rule: `--check`, `--reflow`, `--snapshot`, `--verify`                               |
| `bb results-table`       | `test/utils/results_table.clj`      | the Results table in `fitting_tests/README.md`                                                       |
| `bb compare`             | `test/utils/compare.clj`            | compare fitting-test results between git revisions                                                   |
| `bb bench`               | `test/utils/bench.clj`              | the cold / steady-state benchmark (prints its plan without `--approved`)                             |
| `bb extract-formfactor`  | `test/utils/extract_formfactor.clj` | rebuild the form-factor table from `xraydb.sqlite`                                                   |
| `bb extract-components`  | `dev/extract_components.clj`        | regenerate `src/MolecularStructure/components.tsv` from the wwPDB dictionary (`--check`, `--update`) |

To add a tool, give it a task in `bb.edn` with the `script` helper (`mytool {:doc "..." :task (script "dev/mytool.clj")}`) and a row here.

## `bb fittings` (`fittings.clj`)

```
bb fittings [ID ...] [--no-fit] [--bench] [--approved] [--report] [--table] [--fixme] [--trace-compile FILE] [--dry-run]
```

- **`ID ...`** are folders of `test/fitting_tests/` (`SASDMJ9`, `SASDBS6`, ...). If none exist, nothing runs and the available folders are listed. With none given, every fitting test runs. Each fit is its script run with the `test/fitting_tests` environment; it rewrites its `res*.txt` and figures.
- **`--no-fit`** skips the fits themselves, for when only a later step is wanted.
- The steps run in a fixed order: the fits, then `--bench`, then `--report`, then `--table`, then `--fixme`. A failing step does not stop the later ones; the exit status is 1 if any failed.
- **`--bench`** also runs the cold / steady-state benchmark (`../test/utils/bench.clj`) on the selected fits, one `ID[:tag]` per run of each script. **Without `--approved` this only prints the benchmark's plan and runs nothing.** **`--approved`** is passed to the benchmark. Benchmark timings are only meaningful on a quiet machine, so a benchmark runs only after the repository owner has approved that run. `--approved` without `--bench` is an error.
- **`--report`** prints the Results-table rows of the selected fits (`../test/utils/results_table.clj`), from the reports the fits just wrote. To rewrite the table in `fitting_tests/README.md`, use `bb results-table --update`.
- **`--table`** rewrites the Results table in `fitting_tests/README.md` from every report (`../test/utils/results_table.clj --update`), whatever IDs are named.
- **`--trace-compile FILE`** runs the fits with Julia's `--trace-compile=FILE`: the file lists the methods each fit's process had to compile at run time, i.e. what a precompile workload has not covered.
- **`--fixme`** runs the sampler diagnostics (`diagnose.clj --report`) on every run of the selected fits: MAP starts, Hessian, step size and tree depth, gradient error, modes. Use it when a fit looks wrong.

## `bb profile` (`profile.clj`)

```
bb profile ID[:tag] [ID[:tag] ...] [--delay SECONDS] [--dry-run]
```

Builds the `Seed` of each fitting test twice in one process (the first call warms the compiler) and profiles the second with Julia's sampling profiler: the stage timings of that build (each static stage with its note, e.g. `[cache hit]` or the residue counts of the nucleotide stages; see `test/utils/README.md`) and the samples by function, charged to the innermost BAYSOL function (its own code plus the libraries it calls) and inclusive. The profiler slows the code by a factor of several, so read the proportions, not the seconds. It is how the time in `forward_cache` was found; use `bb fittings --bench --approved` or the reports to measure a change.

## `bb validate` (`validate.clj`)

```
bb validate --list
bb validate NAME [ID[:tag] ...] [--approved] [--dry-run]
```

Runs a **validation** (`../test/validation/NAME/`): a slow, suite-wide check of one change against criteria fixed before the run; see `../test/validation/README.md`. **Without `--approved` it only prints its plan.** With it, the script writes its per-fit rows to `../test/validation/NAME/results/NAME-<stamp>.tsv` and prints its verdict. A bare ID stands for every run of its script.

## `bb vis` (`vis.clj`)

```
bb vis [NAME ...] [--list] [--dry-run]
```

- **`NAME ...`** are the visual checks (see `--list`): `plastic_2d`, `plastic_3d`, `sasa_hydro` and `sasa_hydro_report`. An unknown name stops the run before anything starts. With none given, every check runs, one after the other.
- Each check is one call in a fresh Julia process in `test/visualize`'s own environment. Everything but `sasa_hydro_report` opens a window, so it needs a display; `sasa_hydro_report` prints numbers only.

## `bb unit` (`unittests.jl`)

Runs every `../test/unit_tests/units/test_*.jl` (or, given words, the files whose name contains one of them; a word that matches no file is an error); a new test file is picked up by creating it there. Each file is also runnable on its own (`julia --project=test test/unit_tests/units/test_sampler.jl`).

## `bb test` (`tests.clj`)

Runs the [clojure.test](https://clojure.github.io/clojure/clojure.test-api.html) files `../test/utils/tests/*_test.clj`, which cover the dev tools (`common.clj`, `report.clj`, `results_table.clj`, `compare.clj`, `bench.clj`, `extract_formfactor.clj`, `extract_components.clj` and the command-line front ends). They run no Julia, no fit and no benchmark (`bench.clj` is tested only without `--approved`, on a sandbox). Given words, only the test files whose name contains one of them run (`bb test compare bench`); the exit status is 1 if a test fails.

## `bb extract-components` (`extract_components.clj`)

`src/MolecularStructure/components.tsv` is the built-in lookup of the component dictionary, so that a residue name is classified without a network. `bb extract-components` regenerates it from the wwPDB file `components.cif.gz` (default `https://files.wwpdb.org/pub/pdb/data/monomers/components.cif.gz`, or a local copy or other URL given as the first argument), reading the gzip as a stream. The file starts with `#` lines (source URL, the file's Last-Modified, the fetch date, `# rows: N`, the column names), then one row per component sorted by id, tab separated:


| Column    | Content                                                                                                                                                      |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`      | `_chem_comp.id`                                                                                                                                              |
| `class`   | `dna` or `rna` when the type contains the word DNA or RNA (so `l-dna linking`, `l-rna linking` and the 3'/5' terminus types are nucleic acids), else `other` |
| `type`    | `_chem_comp.type`, lower-cased (`non-polymer`, `l-peptide linking`, `dna linking`, ...)                                                                      |
| `parent`  | `_chem_comp.mon_nstd_parent_comp_id` (the standard residue a modified one derives from), `-` when there is none                                              |
| `formula` | `_chem_comp.formula` without its quotes (`C2 H4 O3`)                                                                                                         |

**How `base` is inferred.** Offline, never at runtime. The signals, in order: the declared parent, the standard residues, the one-letter code, the ring chemistry, the name; when two signals that found a base disagree the result is `-` (no guess). The ring signal reads the bond graph of the heavy atoms by position: it finds the furanose ring (one O, four C), the glycosidic nitrogen on the carbon next to the ring O, prunes the base ring system and numbers it from that nitrogen. Pyrimidine: an amine on C4 and an oxygen on C2 is `C` (an amine only at C5 is not); oxygens on C2 and C4 are a uracil or a thymine, which the ring cannot tell apart (see below), so alone it gives `-` and agrees with a letter or name that says U or T. Purine: an amine on C6 with no amine or oxygen on C2 is `A`; an oxygen on C6 with an amine on C2 is `G`; inosine-like (C6 oxygen, no C2 amine), isoguanine-like and diaminopurine bases are `-`. Abasic sugars, C-nucleosides, dyes and anything without a recognisable base ring are `-`.

`bb extract-components --validate-inference` applies the letter, ring and name signals blind to the nucleic components that declare a parent and compares with the base that parent leads to: per signal the coverage and precision, and the confusion counts. On the 2026-10-10 dictionary (562 components): letter 432 found, 100 % correct; ring 250 found, 99.2 % correct; name 404 found, 97.8 % correct; all together 512 found, 99.4 % correct. The ring signal does not decide U against T because the dictionary's parents do not follow the C5 methyl (5-methyluridines have parent `U` in 10 RNA components and `T` in 15; 5-substituted thymidines with another group on C5 have parent `DT`): taking methyl as T and the rest as U was right only 87 % of the time. That validation set is biased toward components whose letter and name were filled in with their parent; on the components without a parent the letter signal finds far fewer.

A missing field reads as `?`, and a tab inside a value becomes a space. `--check` compares the data only (the dates come from the checked-in header), so a newer dictionary shows as a diff of rows. `--update` writes today's date as the fetch date and the download's `Last-Modified` as the source date.

```bash
bb extract-components --check    # download the dictionary, compare with the table; exit 1 if stale
bb extract-components --update   # ... and rewrite src/MolecularStructure/components.tsv
bb extract-components components.cif.gz --check   # from a local copy
bb extract-components --validate-inference        # precision of the base inference (no table written)
```

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
[JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl) (settings in `.JuliaFormatter.toml`, environment `test/format`) and the Clojure and EDN files with [zprint](https://github.com/kkinnear/zprint) (needs `java`) followed by a re-indentation in multiples of 4. Neither wraps comments, docstring text or string literals: `linelen.clj --reflow` re-wraps over-long comment blocks and docstring paragraphs, and `--snapshot DIR` / `--verify DIR` check that such a pass changed no code. Long string literals are split by hand.

## `bb docs`

```
bb docs
```

Builds the site with Documenter.jl in `../docs/` (`julia --project=docs docs/make.jl`), strict: a broken cross-reference or an undocumented docstring fails the build. It first copies the READMEs of `src/`, `test/` and `dev/` into `docs/src/` (edit a README, never its copy) and writes the site to `../docs/build/`. `bb precommit` runs the same build as its last step.

## `bb precommit` (`precommit.clj`)

```
bb precommit [--quick] [--dry-run]
```

The single entry point to run before a commit; a failing step does not stop the later ones and the exit status is 1
if any failed. Steps, in order: **tool-tests**, **unit-tests**, **concurrency-tests**, **whitespace**
(trailing whitespace on the lines you changed, untracked files included, is stripped and reported, never a
failure; only a leftover conflict marker fails), **clj-format**, **julia-format**, **clj-lint** (clj-kondo,
settings in `.clj-kondo/config.edn`), **line-length** (a line over 92 characters refuses the commit),
**results-table** and **docs-build** (the strict documentation build). `--quick` skips the Julia steps
(unit-tests, concurrency-tests, julia-format, docs-build). It never runs a fitting test or a benchmark.

## Requirements

[Babashka](https://babashka.org) (its `bb` also runs the tasks of `bb.edn`), `java` (for zprint) and [clj-kondo](https://github.com/clj-kondo/clj-kondo) on the `PATH`, and `julia` (or `JULIA=/path/to/julia`) for everything that runs Julia. `--bench`, `--report` and `--fixme` use the tools in `../test/utils/`; see its README.
