# dev

Developer tools. Every one is a [Babashka](https://babashka.org) script in this folder, with its Julia
helper beside it where it needs one, and has a short **`bb <task>`** name defined in `bb.edn` at the
repository root; `bb help` lists them with a line each.

```bash
bb unit                                               # the whole Julia unit suite
bb unit shannon wls                                   # only the test files whose name contains one of these words
bb fitting-tests                                           # every fitting test
bb fitting-tests SASDMJ9 SASDBS6                           # just these
bb fitting-tests SASDMJ9 --report                          # run it, then print its Results-table row
bb fitting-tests --no-fit --table                          # rewrite the Results table in fitting_tests/README.md from the run logs
bb fitting-tests SASDMJ9 --fixme                           # run it, then the sampler diagnostics
bb fitting-tests SASDMJ9 --bench                           # prints the benchmark plan; runs no benchmark
bb fitting-tests SASDMJ9 --bench --approved                # runs the benchmark (see below)
bb fitting-tests --list                                    # the IDs of the fitting tests, one per line
bb render-plots test/fitting_tests --recursive        # render the figures' .tex files to PDF (--type svg|png|jpeg)
bb fonts "TeX Gyre Pagella"                           # is a font available to LaTeX? prints true or false (--list: every font)
bb diagnose --residuals                               # no fit named: every run of every fitting test (53)
bb diagnose SASDMJ9                                   # every diagnostic part on this fit
bb diagnose --chains --seeds 1,2,3 SASDMJ9            # only the chains, three RNG seeds
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

Every script prints its usage with `--help`, and the ones that start long jobs (`fitting-tests`, `bench`,
`diagnose`, `precommit`) accept `--dry-run` (print the commands, run nothing). They stop before running anything if a name you give does not exist.

## Tasks and files

`bb.edn` (repository root) gives each tool a `bb <task>` name and a one-line description (`bb help`). Run
`bb <task>` from the repository root; the scripts themselves work from anywhere (`bb dev/fitting_tests.clj ...` is
the same as `bb fitting-tests ...`). To add a tool, give it a task in `bb.edn` with the `script` helper
(`mytool {:doc "..." :task (script "dev/mytool.clj")}`) and a section below if it needs one.
`bb tasks` prints `bb.edn` itself (it overrides Babashka's built-in `tasks`). `bb.edn` is formatted by
`bb fmt` (zprint, 4-space indent), which also decides the order of the keys inside a task. The
repository's `.editorconfig` sets 4-space indentation and no trailing whitespace for `.clj`, `.edn`
and `.jl`, so Tab inserts spaces; literal tabs are flagged by `bb linelen`.

The files of this folder that are not tasks:


| File                                                      | What it is                                                                                                                                   |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `common.clj`                                              | helpers shared by the scripts: the repository root, running programs, git, the fitting-test lookups, command lines, number formatting        |
| `report.clj`                                              | `parse-log`: the runs of a fitting-test run log (`<ID>.LOG`) into maps of numbers; `parse` reads the text reports (`res*.txt`) of older revisions; used by `compare.clj` and `results_table.clj` |
| `workbook.clj`                                            | reads the sheets of an `.xlsx` (a zip of XML, JDK only): the one tool that reads a workbook                                                                |
| `reflow.clj`                                              | re-wraps long comments and docstrings; `bb fmt` runs it after the formatters                                                                 |
| `child.jl`, `diagnose.jl`, `profile_seed.jl`, `format.jl` | the Julia side of `bench.clj`, `diagnose.clj`, `profile.clj` and `format.clj`                                                                |
| `fit_seed.jl`, `seed_diagnostics.jl`                      | the `Seed` a fitting test would sample, built without fitting, and the sampler diagnostics that run on any `Seed`; a unit test includes them |
| `tool_tests/`                                             | the `clojure.test` files for the scripts (`*_test.clj`), `helpers.clj` and `data/`; run by `bb test`                                         |

## bb compare results-table | bench | extract-formfactor

```bash
bb compare v0.2.0-soukouratou HEAD          # any revisions; the working tree is added last
bb compare HEAD~2 HEAD --no-tree --csv out.csv
bb compare --bench new.json                 # against the latest release's baseline in test/baselines/
bb compare --bench baseline.json new.json
bb results-table --update       # regenerate the Results table in test/fitting_tests/README.md
bb results-table --check        # exit 1 if that table is stale
bb bench --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3
bb extract-formfactor xraydb.sqlite src/Scattering/form_factors.sqlite3
```

- **`compare.clj`** compares fitting-test results (the run logs `test/fitting_tests/*/<ID>.LOG`) between git revisions and the working tree: timing totals, χ² and parameter distributions, the fits with the deepest NUTS trees.
- **`results_table.clj`** generates the Results table of `test/fitting_tests/README.md` from the run logs (`--update` rewrites it in place, `--check` exits 1 if it is stale, `--tsv FILE` writes every quantity read from the reports).
- **`bench.clj`** is the cold / steady-state benchmark driver (protocol below): a throwaway depot and repository copy, one `child.jl` process per fit, one JSON result.
- **`extract_formfactor.clj`** rebuilds `src/Scattering/form_factors.sqlite3` from xraydb's `xraydb.sqlite` (Waasmaier-Kirfel f0, Chantler f1/f2, and deuterium as a copy of hydrogen). Offline; the result is checked in.

## bb fitting-tests

```
bb fitting-tests --list
bb fitting-tests [ID ...] [--no-fit] [--bench] [--approved] [--report] [--table] [--fixme] [--trace-compile FILE] [--dry-run]
```

- **`--list`** prints the ID of every fitting test, one per line, and runs nothing.
- **`ID ...`** are folders of `test/fitting_tests/` (`SASDMJ9`, `SASDBS6`, ...). If none exist, nothing runs and the available folders are listed. With none given, every fitting test runs. Each fit is its script run with the `test/fitting_tests` environment; it rewrites its workbook, its figures and its section of the folder's run log (`<ID>.LOG`).
- **`--no-fit`** skips the fits themselves, for when only a later step is wanted.
- The steps run in a fixed order: the fits, then `--bench`, then `--report`, then `--table`, then `--fixme`. A failing step does not stop the later ones; the exit status is 1 if any failed.
- **`--bench`** also runs the cold / steady-state benchmark (`bench.clj`) on the selected fits, one `ID[:tag]` per run of each script. **Without `--approved` this only prints the benchmark's plan and runs nothing.** **`--approved`** is passed to the benchmark. Benchmark timings are only meaningful on a quiet machine, so a benchmark runs only after the repository owner has approved that run. `--approved` without `--bench` is an error.
- **`--report`** prints the Results-table rows of the selected fits (`results_table.clj`), from the run logs the fits just wrote. To rewrite the table in `fitting_tests/README.md`, use `bb results-table --update`.
- **`--table`** rewrites the Results table in `fitting_tests/README.md` from every run log (`results_table.clj --update`), whatever IDs are named.
- **`--trace-compile FILE`** runs the fits with Julia's `--trace-compile=FILE`: the file lists the methods each fit's process had to compile at run time, i.e. what a precompile workload has not covered.
- **`--fixme`** runs the sampler diagnostics (`diagnose.clj --report`) on every run of the selected fits: MAP starts, Hessian, step size and tree depth, gradient error, modes. Use it when a fit looks wrong.

## bb profile

```
bb profile ID[:tag] [ID[:tag] ...] [--delay SECONDS] [--dry-run]
```

Builds the `Seed` of each fitting test twice in one process (the first call warms the compiler) and profiles the second with Julia's sampling profiler: the stage timings of that build (each static stage with its note, e.g. `[cache hit]` or the residue counts of the nucleotide stages; see "Reports" below) and the samples by function, charged to the innermost BAYSOL function (its own code plus the libraries it calls) and inclusive. The profiler slows the code by a factor of several, so read the proportions, not the seconds. It is how the time in `forward_cache` was found; use `bb fitting-tests --bench --approved` or the reports to measure a change.

## bb vis

```
bb vis [NAME ...] [--list] [--dry-run]
```

- **`NAME ...`** are the visual checks (see `--list`): `plastic_2d`, `plastic_3d`, `sasa_hydro` and `sasa_hydro_report`. An unknown name stops the run before anything starts. With none given, every check runs, one after the other.
- Each check is one call in a fresh Julia process in `test/visualize`'s own environment. Everything but `sasa_hydro_report` opens a window, so it needs a display; `sasa_hydro_report` prints numbers only.

## bb unit

Runs every `../test/unit_tests/units/test_*.jl` (or, given words, the files whose name contains one of them; a word that matches no file is an error); a new test file is picked up by creating it there. Each file is also runnable on its own (`julia --project=test test/unit_tests/units/test_sampler.jl`).

## bb test

Runs the [clojure.test](https://clojure.github.io/clojure/clojure.test-api.html) files `tool_tests/*_test.clj`, which cover the dev tools (`common.clj`, `report.clj`, `workbook.clj`, `results_table.clj`, `compare.clj`, `bench.clj`, `extract_formfactor.clj`, `extract_components.clj` and the command-line front ends). They run no Julia, no fit and no benchmark (`bench.clj` is tested only without `--approved`, on a sandbox). Given words, only the test files whose name contains one of them run (`bb test compare bench`); the exit status is 1 if a test fails.

## bb extract-components

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

## bb fmt | lint | linelen

```
bb fmt [--julia|--clj] [PATH ...]          # format and re-wrap (rewrite the files)
bb fmt-check [--julia|--clj] [PATH ...]    # only list what is not formatted
bb lint                                    # clj-kondo
bb linelen --check [PATH ...]              # report lines over 92 characters and tabs
```

The code rule of the repository is **at most 92 characters per line** in code files (`.jl`, `.clj`, `.edn`,
`.scss`, `.yml`; not Markdown or data). `format.clj` formats the Julia files with
[JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl) (settings in `.JuliaFormatter.toml`, environment `test/format`) and the Clojure and EDN files with [zprint](https://github.com/kkinnear/zprint) (needs `java`) followed by a re-indentation in multiples of 4. Neither wraps comments or docstring text, so `format.clj` then runs `reflow.clj`: every comment block and docstring paragraph that contains a line over the limit is re-wrapped, balanced; a block that fits is left alone, so a second `bb fmt` changes nothing. `bb fmt-check` lists the files that the formatters or the re-wrapping would change. Long string literals and symbols are split by hand: `bb linelen --check` reports every line still over the limit, and the precommit refuses the commit while there is one.

**Private functions** are written `(defn ^:private name ...)`, as a private `def` is (`def ^:private`), never `defn-`. `bb fmt` rewrites a top-level `(defn- ` into it before zprint runs, and `bb fmt-check` (so `bb precommit`) fails on one.

## bb render-plots

```
bb render-plots DIR [--recursive] [--type pdf|svg|png|jpeg]
```

Renders the `.tex` figures that `results` writes. `DIR` is the folder with the files; `--recursive` also takes its subfolders. Each file is compiled with `lualatex` (or `xelatex`) in its own folder, with `-interaction=nonstopmode -halt-on-error`, and its `.aux` and `.log` are removed afterwards; a file that fails keeps its `.log` and the others still run. The default `--type pdf` needs only the engine; `svg`, `png` and `jpeg` convert the PDF with poppler's `pdftocairo` and remove it. Output files sit next to their `.tex`. The exit status is 1 if any file failed or no engine is installed. SVG is about four to five times the size of the PDF and its text is outlines, not text, so it is for web pages and slides.

## bb fonts

```
bb fonts NAME [NAME ...]
bb fonts --list
```

Asks the TeX Live installation whether a font can be used for the figures. For each `NAME` (a `fontspec` name such as `TeX Gyre Pagella` or `Latin Modern Math`; case and spaces do not matter) it prints `NAME: true` or `NAME: false`, and the exit status is 1 if any is `false`. Any font that says `true` is a valid `font` of `results`, as the text font, or as the second entry of a `("Text font", "Math font")` pair. `--list` prints every installed font family (from `fc-list`, or from LuaLaTeX's index where there is none), the math fonts first. The check is `luaotfload-tool --find`, which comes with TeX Live, and it does not rebuild the font database: a font installed since the database was last built needs `luaotfload-tool --update` first. Without `luaotfload-tool` the tool stops with a message, since nothing can be said about a font. `BAYSOL.font_available("NAME")` is the same question from Julia.

## bb docs

```
bb docs
```

Builds the site with Documenter.jl in `../docs/` (`julia --project=docs docs/make.jl`), strict: a broken cross-reference or an undocumented docstring fails the build. It first copies the READMEs of `src/`, `test/` and `dev/` into `docs/src/` (edit a README, never its copy) and writes the site to `../docs/build/`. `bb precommit` runs the same build as its last step.

## bb precommit

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

[Babashka](https://babashka.org) (its `bb` also runs the tasks of `bb.edn`), `java` (for zprint) and [clj-kondo](https://github.com/clj-kondo/clj-kondo) on the `PATH`, and `julia` (or `JULIA=/path/to/julia`) for everything that runs Julia. `--bench`, `--report` and `--fixme` use `bench.clj`, `results_table.clj` and `diagnose.clj` (described above). `extract_formfactor.clj` fetches the `org.babashka/go-sqlite3` pod on first use.

## Reports

The run log (`test/fitting_tests/<ID>/<ID>.LOG`, one file per fitting-test folder, tracked in git, a section for each run) is the one file the tools read: flat tab-aligned `name<TAB>value` rows (the timing table as a person reads it, between `--- timing ---` and `--- machine ---`), see `BAYSOL.write_log` and the Pipeline README. `report.clj` turns a section into the map of numbers every tool uses; older revisions keep their results in `res*.txt` text reports (the timing table printed the stages of the static build in the order the pipeline recorded them, a stage's note in square brackets on the lines under it), which `report/parse` still reads. Only `workbook.clj` reads a workbook.


| Stage (depth 1 of the static build)                             | When                                                                                   | Note                                                                                                                                                                                                                         |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `resolve_structure`                                             | always                                                                                 |                                                                                                                                                                                                                              |
| `components`                                                    | always: the component table load and the lookups (builtin table, cache, RCSB download) | `[17 residue names: 17 builtin, 0 cache, 0 download]`                                                                                                                                                                        |
| `structure checks`                                              | always                                                                                 | `[N chains relabelled, M duplicate atoms dropped, K dummy-like findings]`                                                                                                                                                    |
| `classify`                                                      | with hydrogens                                                                         | `[nucleic: AMBER, titration none]`, `[mixed: PARSE, titration propka]`, `[protein: PARSE, titration propka]`, then optional `; N legacy-named ...`, `; N chains relabelled`, `; N dummy-like residues (undefined behaviour)` |
| `propka`                                                        | protein-only and mixed inputs                                                          | `[cache hit]` / `[cache miss]`                                                                                                                                                                                               |
| `pdb2pqr`, `pdb2pqr (nucleic, none)`, `pdb2pqr (mixed, propka)` | one of the three per run (protein-only, nucleic-only, mixed)                           | `[cache hit]` / `[cache miss]`                                                                                                                                                                                               |
| `modified nucleotide hydrogens`                                 | only when the structure has modified nucleotides                                       | `[14 residues: 14 hydrogenated through their base, 0 without a base; 149 hydrogens placed, 232 in the free components' formulas]`                                                                                            |
| `modified amino acid hydrogens`                                 | only when the file has modified amino acids (HETATM, e.g. MSE), on every route         | `[20 residues: 20 hydrogenated through their parent, 0 without a parent; 183 hydrogens placed]`                                                                                                                              |
| `heavy atoms`                                                   | with hydrogens                                                                         | `[N in, N out; R restored, A added by pdb2pqr]`                                                                                                                                                                              |
| `load_molecule`, `SASA`, ...                                    | always                                                                                 |                                                                                                                                                                                                                              |

How the tools read them (`report.clj`, by stage name over the `--- timing ---` block of the run log; a run that lacks a stage, or to which it did not apply, has `""` for it):

- **Keys.** Seconds: `:components`, `:structure_checks`, `:classify`, `:propka`, `:pdb2pqr`, `:modified_hydrogens` (nucleotides), `:modified_amino_hydrogens`, `:heavy_atoms` (and the existing `:resolve_structure`, `:load_molecule`, ...). `:pdb2pqr` is the `pdb2pqr*` stage of the run, whichever of the three variants it was (the patterns match on the prefix, like `propka*`); a run records exactly one. `:components_download` is the `N` of the components note. The notes themselves are in `(:stage_notes report)`, a map from stage name to note (`report/stage-notes`), not among the ordered keys, so the TSV (`results_table.clj --tsv`) and `--csv-all` outputs (numbers only) do not change shape.
- **Wall clock without external tools (`:wall_ex`, the convention of every comparison).** wall clock minus `:startup` (process start to `seed_model`) minus `:plot_timing` minus `:propka` minus `:pdb2pqr` (every `pdb2pqr*` stage) minus, only when `:components_download` is above 0, the seconds of `components` (a download is network time, and the stage cannot separate it from the table load; a lookup that downloaded nothing is computing and stays in). Everything else (`classify`, `modified amino acid hydrogens`, `structure checks`, `heavy atoms`, `modified nucleotide hydrogens`, `resolve_structure`) is in-process work and stays in the wall clock. A stage a report lacks contributes nothing, so the 53 reports of the original suite give exactly the numbers they always gave.
- **`compare.clj`.** The timing table has a row for each stage above (a stage no report of a column has shows `-`, not 0, and its ratio `n/a`; the `pdb2pqr (any variant)` row sums the variant of each run). Below it, the stage notes of the judged revision for every fit that is not a protein-only run with all caches hit (nucleic and mixed fits, a `cache miss`, a download), so the cache and the nucleotide counts behind a time are visible. `--bench` sums the stages by name prefix (`pdb2pqr` takes all three variants; the two `modified ... hydrogens` stages are separate prefixes) and shows a stage that a run did not have as `-`.
- **`profile_seed.jl`** (`bb profile`) prints every static stage with its note.

## Sampler Diagnostics

`dev/diagnose.clj` has three parts: `--residuals` (are the residuals at the MAP white) and two that answer "where do this fit's divergences and slow mixing come from?": `--report` (one NUTS chain started at the MAP, with the MAP search, the Hessian and the shape of the posterior around it) and `--chains` (the chains `run_model` actually runs, one line each: eight at the start, then up to a few more started at optima that carry mass; `--retry 1` shows the longer rerun `infer` does when R̂ is above 1.01). The output below is a real run on SASDX52 (16,882 atoms, `lMax` 38, 137 binned points), at the defaults of `run_model` (300 warm-up, 700 draws, target acceptance 95 %). It is cut into numbered blocks, each followed by what the block is for and how SASDX52 reads. Lines left out are marked `[…]`.

```bash
bb diagnose --report SASDX52
bb diagnose --chains --seeds 6252506411145483830 SASDX52
bb diagnose --chains --retry 1 --seeds 6252506411145483830 SASDX52
```

`6252506411145483830` is the `rng_seed` row of the fit's own run log, so `--chains` replays that very run; without `--seeds` the seed is 7. The thread count does not change any number.

### Part 1: --report

**1. The fit.** What was loaded: the number of fitted points, atoms, `lMax`, the c1 tolerance, the support of the sampled contrasts, and the χ² of the deposited reference curve on our q set (a floor to compare the fit against).

```text
SASDX52   n_q=137  n_atoms=16882  lMax=38  c1 tol=1.0e-8
δρ₃ support = [-11.35, 2.839]   δρ₁,₂ support = [-10.0, 2.0]
reference curve on our q-set (n=409): χ²_red raw = 0.699, with free scale+offset = 0.701
```

**2. The MAP search and the NUTS run.** `n_ok/n_starts` is how many of the L-BFGS starts made gave a result (64 random starts, then a second round of jittered starts around the optima of the first; block 5 lists the 64) and `n_modes` how many distinct optima they found. The NUTS line is one chain started at the MAP: the step size ε before and after adaptation, the leapfrog steps and tree depth, and the number of divergent transitions. The window means show whether the trees grow or shrink during warm-up; acceptance should sit at the target (0.95) and `|ΔH|`, the energy error, should be small.

```text
MAP search: 0.1s  n_ok=70/70  n_modes=2  whitened=true
NUTS: 0.1s  init ε=1.6  final ε=0.4087  mean n_steps=11.8 mean depth=3.33  frac(depth≥10)=0.000  diverged=2
mean n_steps by window: [1:75]=12  [76:450]=12  [251:300]=10  [301:1000]=12
mean accept = 0.927   mean |ΔH| = 0.070
```

SASDX52: two optima, two divergent transitions, acceptance 0.927 (target 0.95), no deep trees, and a final ε of 0.41 against 0.24 and 0.26 for the two chains of Part 2 that start at the MAP. This one chain is mostly healthy; the divergences show up in the chains of Part 2.

**3. Is the Laplace whitening right?** The sampler works in coordinates `w` where the posterior is meant to be a unit Gaussian. `sd` should be near 1 for every axis; the eigenvalues of the draws' covariance say the same without the axes; `skew` away from 0 means a lopsided direction; `ESS` is the effective sample size per axis. The last two lines compare log π at the optimizer's mode with the draws (for a 4-D Gaussian the median draw sits about 1.7 below the mode) and the sampled spread with the Laplace one in the optimizer's coordinates.

```text
post-warmup w: sd = [0.9863, 1.556, 2.145, 1.218]   (1 = the Laplace whitening is right)
  cov(w) eigenvalues = [0.9438, 0.98, 1.236, 6.32]   skew = [0.2042, -0.1343, 1.292, -0.2866]   ESS = [568.7, 44.39, 86.5, 209.9]
ℓπ at L-BFGS mode = 855.8603   best draw = 855.7956   median draw = 854.1010   (4-D Gaussian: median ≈ mode − 1.7)
sampled sd in z / Laplace σ_z = [0.9863, 1.083, 1.074, 2.047]
```

SASDX52: the second and third whitened axes are 1.6 and 2.1 times wider than the Laplace guess, the third has skew 1.29, and the effective sample sizes of those two axes are 44 and 87 out of 700 draws. In the optimizer's coordinates the last axis is 2.0 times wider. The mode and the best draw agree to 0.07 nats, and the median draw sits 1.76 below the mode, as a Gaussian would.

**4. How far each parameter is from its support bound.** In posterior standard deviations. A parameter within a few sd of a bound is cut by the prior's support and its posterior is not Gaussian there.

```text
coordinate   median ξ       sd ξ     distance to nearest support bound / sd
  ρₑ         0.34061    0.000194       1.76e+03
  δρ₁       -0.23194      0.0834           26.8
  δρ₂        -3.4491         1.1           4.97
  δρ₃         1.4416        2.13          0.657
```

SASDX52: δρ₃ is 0.66 sd from its upper bound (2.839) and has a wide posterior (sd 2.13); δρ₂ is 5 sd from its bound and the others are far from theirs.

**5. The 64 L-BFGS starts.** One line per start in the optimizer's coordinates: the final `f = −log π`, the iterations, whether it stopped on the gradient (`g_conv`) or on the iteration limit, how much the gradient changes between the working c1 tolerance and a much tighter one (a small value means the stop is not a gradient-error artefact) and c1 at the end. Starts that end on the same `f` found the same optimum.

```text
  start 1: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=0.00e+00 c1=1.0875
  start 2: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=3.17e-04 c1=1.0875
  start 3: f=-855.8603 iters=117 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=5.91e-06 c1=1.2335
  start 4: f=-831.7659 iters=119 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=1.43e-04 c1=1.0875
  […]  (60 more lines, same format)
```

SASDX52: 52 of the 64 starts end at `f = −831.77` (c1 1.0875) and 12 at `f = −855.86` (c1 1.2335), the better optimum by 24 nats in `f`. Most starts land in the poor one, which is why the search runs many starts and picks by Laplace mass. The list reports two optima only; the third optimum of the closing list is not among them.

**6. The Hessian at the mode.** Eigenvalues of the second derivative of `f` in the optimizer's coordinates (floor 1.0). Pass 1 is the Hessian used for whitening; pass 2 repeats it at several finite-difference step sizes to show it is stable.

```text
MAP Hessian eigenvalues (floor 1.0): pass 1 = [0.6629, 3.194, 19.44, 1319]
  pass 2, step 0.30·σ_lap: [1, 2.967, 20.16, 1342]
  pass 2, step 0.10·σ_lap: [1, 2.957, 19.65, 1334]
  pass 2, step 0.03·σ_lap: [0.9999, 2.966, 19.57, 1332]
  pass 2, step 0.01·σ_lap: [1, 2.97, 19.54, 1330]
```

SASDX52: pass 2 is stable to the step size; the spread of eigenvalues (1 to about 1330) is the conditioning that `w` has to undo.

**7. Shape along each whitened axis.** `Δf/(s²/2)` at displacements `s` (in whitened sd) from the mode: 1 everywhere is a Gaussian, above 1 is steeper than the whitening assumed (a wall), below 1 is flatter (a tail). The scans below it report, per axis, the noise from the c1 tolerance, the median and maximum curvature `f''` and the range of the profiled c1, with `jumps` counting discontinuities of c1 (a jump would break the gradient).

```text
Δf/(s²/2) along whitened axes (1 = Gaussian), s = -10,-5,-3,-2,-1,-0.5,0.5,1,2,3,5,10
  w1:        1        1        1        1        1        1        1        1        1        1        1        1
  w2:    0.714    0.727    0.852    0.988     1.02     1.01     0.99    0.985    0.995     1.05     1.66     3.66
  w3:     2.36       13     3.27     2.02     1.37     1.16     0.87    0.768    0.617    0.512    0.381     0.24
  w4:    0.384    0.589    0.717    0.796     0.89    0.942     1.06     1.13     1.29     1.47     1.98        5
  w1 scan: c1-tol noise=8.55e-10  f''(median)=1 f''(max)=1 at s=1.88  c1 range=[1.2327,1.2342] jumps=0
  w2 scan: c1-tol noise=1.04e-09  f''(median)=0.997 f''(max)=2 at s=2.98  c1 range=[1.2046,1.2389] jumps=0
  w3 scan: c1-tol noise=1.03e-09  f''(median)=0.997 f''(max)=19.6 at s=-2.98  c1 range=[1.2170,1.2461] jumps=0
  w4 scan: c1-tol noise=7.37e-10  f''(median)=0.999 f''(max)=2.87 at s=2.98  c1 range=[1.2255,1.2420] jumps=0
```

SASDX52: w3 is a wall on its negative side (13 times a Gaussian at s = −5, local curvature 19.6 near s = −3) and a long flat tail on its positive side (0.24 at s = +10). w2 is flat on its negative side (0.71 at s = −10) and steep on its positive side (3.66 at s = +10), and w4 is flat on its negative side and steep on its positive side (5 at s = +10). c1 is smooth on all four axes (no jumps).

**8. The distinct optima.** Each optimum with its position ξ, the Hessian eigenvalues and its Laplace log-mass, `−f − ½ log det H`, and the difference from the best: a mode that merely exists is told from one that carries probability.

```text
distinct optima: 2
  mode 1: f=-855.860 ξ=[0.3406, -0.2077, -3.239, 1.172]  H-eig=[0.9999, 2.96, 19.16, 1332]  log Laplace mass=850.244 (Δ vs best = 0 nats)
  mode 2: f=-831.766 ξ=[0.3406, 0.753, 1.627, -5.62]  H-eig=[0.9955, 1.213, 3.198, 90.48]  log Laplace mass=828.838 (Δ vs best = -21.4 nats)
```

SASDX52: the second optimum is 21.4 nats lighter and carries no mass.

**9. Gradient error and the stable step size.** The first line is the error the c1 tolerance puts in the gradient NUTS uses, against the size of the gradient (error ≪ gradient means it is not the cause of trouble). The second is the largest curvature `λ_max` along the draws and the step size ε a leapfrog integrator is stable for at that curvature, against the ε the sampler adapted.

```text
gradient error from the c1 tolerance in w: min/median/max = [0, 6.698e-05, 0.001394]  vs |∇ℓπ| median = 1.63   (posterior-scale gradient ≈ 1)
local λ_max(−∇²ℓπ) min/median/max = [0.9999, 1.139, 63.91]  → stable ε < [0.2502, 1.874] (worst, median);  adapted ε = 0.4087
```

SASDX52: the gradient error (median 6.7e-5, at most 1.4e-3) is four orders of magnitude below the median gradient (1.63) and three below it at the worst draw, so it does not cause the divergences. The adapted ε (0.41) is above the step that is stable at the worst curvature along the draws (0.25, where `λ_max` reaches 64), and below the one stable at the median curvature (1.87): a step size that suits most of the posterior but not its steepest corner, which fits the two divergent transitions of block 2.

### Part 2: --chains

One line per chain of `infer`, the chains `run_model` pools, for the run with the run's own `rng_seed` (the `run` sheet). The first eight chains are fixed: two at the MAP and three mirrored pairs further out. Chains after the eighth are started at optima that the harvest of the first chains' draws found to carry mass (see below), and their `start σ` is the optimum's distance from the MAP. Columns: `start σ`, the distance of the chain's start from the MAP in posterior sd (negative is the mirrored chain of a pair); `mode`, the posterior mode it settled in; `pooled`; `kept`, its post-warm-up draws that the pool keeps (a chain in a mode with no mass keeps none); `div` and `div%`, divergent transitions among them; `warm-up div`, divergences during warm-up (not part of the posterior); `ε`, `steps` and `accept`, its mean step size, leapfrog steps and acceptance; `mean log π`. After the table, every divergent draw: chain, iteration, ξ = (ρₑ, δρ₁, δρ₂, δρ₃), log π against the chain's median, leapfrog steps and tree depth.

**10. The run `run_model` does** (300 warm-up, 700 draws):

```text
SASDX52: 10 chains, 300 warm-up + 700 draws, rng_seed 6252506411145483830, δ 95
chain  start σ   mode  pooled  kept  div  div%  warm-up div       ε  steps  accept   mean log π
    1    +0.00      1  yes      700    0   0.0            1  0.2561   14.6   0.980       853.72
    2    +0.00      1  yes      700    1   0.1            4  0.2429   13.0   0.944       853.68
    3    +4.00      1  yes      700    0   0.0            4  0.1704   18.9   0.985       853.64
    4    -4.00      1  yes      700    0   0.0            4  0.2886   10.7   0.952       853.50
    5   +10.00      1  yes      700    0   0.0            3  0.4885    7.3   0.953       853.37
    6   -10.00      1  yes      700    0   0.0            4  0.0849   39.4   0.979       853.59
    7   +20.00      2  yes        0  no post-warm-up draws kept (negligible mode)
    8   -20.00      1  yes      700    1   0.1            5  0.5129    6.8   0.933       853.61
    9    +5.43      1  yes      700    3   0.4            3  0.3687    9.9   0.947       853.31
   10    +5.43      1  yes      700    0   0.0            3  0.2283   15.2   0.976       853.58
pooled kept draws: 6300, divergent: 5 (0.08 %)
divergent draws:
  chain 2 iteration 616  ξ = [0.34048, -0.40858, -5.7518, -6.1068]  log π +853.76 vs chain median +854.01  steps 14  depth 3
  chain 8 iteration 439  ξ = [0.34071, -0.23005, -2.8651, 2.5518]  log π +853.26 vs chain median +854.00  steps 9  depth 3
  chain 9 iteration 507  ξ = [0.34036, -0.14617, -2.2836, 2.7934]  log π +849.58 vs chain median +853.73  steps 11  depth 3
  chain 9 iteration 584  ξ = [0.34106, -0.31662, -5.6875, -3.7399]  log π +849.42 vs chain median +853.73  steps 11  depth 3
  chain 9 iteration 688  ξ = [0.34038, -0.52483, -7.2085, -5.0625]  log π +846.99 vs chain median +853.73  steps 4  depth 2
```

SASDX52: the run has 10 chains. Chains 9 and 10 are the extra ones; both start 5.43 sd from the MAP, the position of the optimum the harvest found (the third optimum of the closing list), and both end in mode 1, with the other chains. Chain 7 (the +20 sd start) ends in the second optimum and keeps no draws. There are 5 divergent draws in 6300 (0.08 %), spread over chains 2, 8 and 9: no chain has more than three, and chain 6 (ε = 0.085, 39 steps per iteration) has none. The draw of chain 2 lies at δρ₂ = −5.75 and δρ₃ = −6.11, far from the main mode's (−3.24, 1.17), with log π near that chain's median. The three of chain 9 are 4 to 7 nats below the chain's median log π, at δρ₃ = 2.79 (next to the upper bound 2.839), −3.74 and −5.06.

**11. The retry** (`--retry 1`: 2000 warm-up, 2000 draws, seeds derived from the run's, as `infer` does when R̂ is above 1.01):

```text
SASDX52: 9 chains, 2000 warm-up + 2000 draws, rng_seed 6252506411145483830, δ 95  (the rerun)
chain  start σ   mode  pooled  kept  div  div%  warm-up div       ε  steps  accept   mean log π
    1    +0.00      1  yes     2000   26   1.3            9  0.2622   11.7   0.909       853.64
    2    +0.00      2  yes     2000  886  44.3            7  0.1827    8.9   0.405       853.24
    3    +4.00      1  yes     2000    4   0.2            7  0.3180   10.7   0.957       853.55
    4    -4.00      1  yes     2000   16   0.8            8  0.3053   11.4   0.952       853.76
    5   +10.00      1  yes     2000    4   0.2            8  0.5052    6.5   0.917       853.73
    6   -10.00      1  yes     2000   23   1.1            8  0.2737   11.8   0.918       853.53
    7   +20.00      3  yes        0  no post-warm-up draws kept (negligible mode)
    8   -20.00      1  yes     2000    2   0.1            5  0.2619   12.3   0.965       853.53
    9    +5.42      1  yes     2000    9   0.5            4  0.2907   11.6   0.942       853.51
pooled kept draws: 16000, divergent: 970 (6.06 %)
divergent draws (first 12 of 970):
  chain 1 iteration 3046  ξ = [0.3406, -0.39279, -4.999, -6.5333]  log π +854.76 vs chain median +853.96  steps 3  depth 1
  chain 1 iteration 3049  ξ = [0.3406, -0.36977, -4.8604, -6.2187]  log π +855.33 vs chain median +853.96  steps 4  depth 2
  […]  (10 more, all chain 1)
```

SASDX52: the longer run is worse, not better. The divergences go from 5 to 970 (6.1 %), 886 of them in chain 2, which settled apart from the others (mode 2) with the lowest acceptance (0.405). The divergent draws listed all belong to chain 1, at δρ₂ ≈ −4.7 to −5.5 and δρ₃ ≈ −6.0 to −6.8; several are the same point repeated, a chain rejected from there again and again. A longer run seems to reach that region more often, but this single run does not show why.

### What SASDX52 shows

* The divergences are not the c1 tolerance (block 9: gradient error three to four orders below the gradient) and not a discontinuity of the profiled c1 (block 7: `jumps=0` on all four axes).
* The posterior has a **third optimum** that the MAP search does not report (block 8 lists two). It carries about 4 % of the posterior mass by the Laplace estimate. No random start reaches it: 500 random L-BFGS starts gave 0 hits (a validation run, removed, in git history under `test/validation/optima_recall/`), and the 64 starts of block 5 end in the two known optima.
* The sampler finds it from the draws instead: the harvest of optima from the first chains' draws finds it, and `infer` starts more chains there (block 10). Those chains tend to leave it again, so it holds far fewer of the pooled draws than its Laplace share.
* The long retry (block 11) is where the divergences concentrate (chain 2: smaller ε, lowest acceptance), but this output does not show what puts it there.

## Benchmarks: cold start and steady state

Performance claims in this repository are measured from a **cold state** and reported next to a **steady state**, so a speedup never comes from a cache that a user does not have on first use.

```bash
bb bench --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3 SASDJ62
bb compare --bench new.json     # against the latest release's baseline
```

The cold state's temporary directory is deleted when the run ends (also on failure; the links to your depot are unlinked, never followed); `--keep` leaves it in place.

### What "cold" wipes

`bench.clj --state cold` never touches your real depot or repository. It builds, in a temporary directory:


| wiped (absent in the cold state)                                                                 | kept (a user has it after installing)                                                                                |
| -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| the Julia compiled caches (`compiled/`), so BAYSOL and its dependencies are precompiled for real | package sources, artifacts, registries (`packages/`, `artifacts/`, `registries/`, `clones/`)                         |
| `_cache/` (downloaded PDBs, `.pka` and protonated-PDB outputs): propka and pdb2pqr run for real  | the provisioned conda environment (`conda_environments/`): provisioning is a one-off network cost, not measured here |
| result files (`res*.xlsx`, figures; the run logs `*.LOG` are tracked), `docs/`, `sources/`, `manuscript/`, any local sysimage       | tracked and untracked-unignored files of the working tree                                                            |

### What is reported

For each fit, in a fresh process (`child.jl` does the fit **twice** in one process):

- **install**: `Pkg.instantiate()` + `Pkg.precompile()` seconds (zero extra work in the warm state);
- **using BAYSOL**: loading the precompiled package;
- **first fit**: script prelude and `seed_model` (`seed_s`), then `run_model` (`run_s`), with the per-stage
  seconds, compile seconds and GC seconds from the pipeline's own `Timing` log;
- **steady fit**: the second fit, with everything already compiled.

Keep the two apart: first-fit minus steady-fit is compilation, and PrecompileTools-style work trades first-fit time for install time, so both rows must be compared. Never quote a warm-state number as what a user gets. The report convention of the fitting tests (wall clock excluding propka, every pdb2pqr stage and a component download; see the stage section above) is unchanged; in the cold state those stages run for real and appear as their own rows.

### Rules

- **Benchmarks are only run with the repository owner's explicit approval, per run, because they need a quiet machine.** `bench.clj` prints its plan unless `--approved` is passed, and `--approved` is added only after the owner has said yes to this run (a safeguard against careless runs, not a security measure).
- One process at a time, a quiet machine (for example: check for `DisplayLinkManager` and `baloo` CPU use first), no parallel runs.
- Compare like with like: a cold run against a cold run of an earlier commit (use `git worktree`/`git stash` to build the earlier tree), never against warm numbers or the committed run logs (`*.LOG`) timings, which are warm-cache.
- [`../test/baselines/`](../test/baselines/README.md) holds the machine-specific reference run of each release (the default for `compare.clj --bench` is the latest release's; host and CPU are recorded in `meta`); compare only within a host.
