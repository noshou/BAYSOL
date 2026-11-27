# dev

The developer tools of the repository: one Julia package, `Dev` (this folder: `Project.toml`, `src/`, `test/`), whose tools are run with the launcher `bysl.jl`. `bysl help` lists them with a line each.

```bash
julia --startup-file=no -O0 --compile=min dev/bysl.jl help      # any platform
dev/bysl.jl help                                                # Linux and macOS: the same, through the shebang
alias bysl='julia --startup-file=no -O0 --compile=min /path/to/BAYSOL/dev/bysl.jl'
```

The examples below use the alias, `bysl`.

```bash
bysl unit                                              # the whole Julia unit suite
bysl unit shannon wls                                  # only the test files whose name contains one of these words
bysl fits list                                         # the fitting tests and the tags each takes
bysl fits run                                          # every fitting test
bysl fits run SASDMJ9 SASDTK5                          # just these
bysl fits run SASDMJ9 --report                         # run it, then print its Results-table row
bysl fits run --no-fit --table                         # rewrite the Results table in fitting_tests/README.md from the run logs
bysl fits run SASDMJ9 --fixme                          # run it, then the sampler diagnostics
bysl fits run SASDMJ9 --bench                          # prints the benchmark plan; runs no benchmark
bysl fits run SASDMJ9 --bench --approved               # runs the benchmark (see below)
bysl fits diagnose --residuals                         # no fit named: every run of every fitting test
bysl fits diagnose SASDMJ9                             # every diagnostic part on this fit
bysl fits diagnose --chains --seeds 1,2,3 SASDMJ9      # only the chains, three RNG seeds
bysl fits diagnose --report --out /tmp/d `SASDTK5:fit3_model1`   # one part, written to /tmp/d/report.txt
bysl fits profile SASDMJ9                              # where the static build spends its time
bysl results table --update                            # regenerate the Results table in fitting_tests/README.md
bysl results table --check                             # exit 1 if that table is stale
bysl results compare v0.4.0                            # the working tree against a revision
bysl plots render test/fitting_tests --recursive       # render the figures' .tex files to PDF (--type svg|png|jpeg)
bysl plots fonts "TeX Gyre Pagella"                    # is a font available to LaTeX? prints true or false (--list: every font)
bysl vis --list                                        # the visual checks
bysl harvest                                           # regenerate the harvested files and constants
bysl harvest solutes --check                           # only compare the solute index with its sources
bysl extract components --check                        # is the bundled component table current?
bysl fmt                                               # format Julia, TypeScript and SCSS, re-wrap prose
bysl fmt --check --julia                               # only list the Julia files that are not formatted
bysl fmt --lines                                       # lines over 92 characters, tabs, TypeScript not indented in 4s
bysl test                                              # the dev tools' tests
bysl test fmt results                                  # only the test files with these words in their name
bysl docs                                              # build the documentation site (strict)
bysl precommit                                         # all pre-commit checks
bysl precommit --quick                                 # only the checks that take a second
bysl cache list                                        # what the tools' programs left in the cache
bysl fixtures list                                     # the archive sets, their archives, what is unpacked
bysl fixtures pack                                     # test/fixtures/experiments/<ID>/ -> <ID>.7z (all, or the IDs named)
bysl fixtures unpack SASDMJ9                           # the archive into the tmp folder (reused if complete)
bysl fixtures clean                                    # remove the unpacked copies (only the tool's own tmp folder)
bysl audit baysol                                      # the libraries a built bundle needs: bundle, system, relies, MISSING
bysl deps                                              # what a developer needs, what this machine has, how to install the rest
bysl deps --yes                                        # install the missing required items (no sudo, no prompts)
```

The whole unit suite (no file names given) runs in `UNIT_JOBS` Julia processes at once (default 2; `UNIT_JOBS=1` is a single process), with the files shared out by their measured times in `dev/scripts/unittests.jl`; a run that names files stays in one process. `bysl precommit` takes about 5.5 minutes with it.

Every tool prints its usage with `--help`; a tool with subcommands (`fits`, `harvest`, `results`, `plots`, `extract`) lists them, and `bysl fits run --help` describes one. The ones that start long jobs (`fits run`, `fits diagnose`, `fits profile`, `fits bench`, `precommit`) accept `--dry-run` or print their plan (print the commands, run nothing). They stop before running anything if a name you give does not exist.

## How the tools run

`bysl.jl` is a small client. The tools themselves run in a **daemon**, a Julia process that stays alive with them compiled: the first command starts it and waits until it answers, later commands connect to it, so a command costs about 100 ms instead of a Julia start-up and a compile. The client needs nothing but Julia, and the daemon listens on a Unix domain socket (Linux, macOS) or a named pipe (Windows) that only the user can reach. A command gets its own exit status, its stdout and stderr on separate streams, the working directory it was typed in, and `BAYSOL_ROOT`, `JULIA`, `BIOME` and `NO_COLOR` from the environment.

- The daemon restarts by itself when a source file of the tools has changed, and stops after 8 hours without a command (`BYSL_IDLE=seconds` changes that, `0` means never). `bysl daemon start|stop|status|restart` manages it.
- `BYSL_DIRECT=1` runs a command in a fresh Julia process instead. The tools that start long Julia processes (`fits`, `docs`, `unit`, `test`, `precommit`, `vis`) always do, since the daemon runs one command at a time.
- Julia comes from `JULIA` if that is set, otherwise from the `PATH`. `--threads N` (4, auto, 4,1; as `julia -t N`) sets the thread count of the Julia processes a tool starts; the default is one.
- The `-O0 --compile=min` flags of the launcher make Julia interpret the client script instead of compiling it, which takes a command from about 430 ms to about 140 ms.

**The cache.** The programs the tools start (the unit suite, the fits, the benchmark) keep their downloads and derived files in the structure cache, the folder the terminal interface and the launcher use: `BAYSOL_CACHE` if that is an absolute path, otherwise `_structures` in the caches folder (`Platform.cache_dir`: `baysol` in the cache home, `$XDG_CACHE_HOME` or `~/.cache`, `~/Library/Caches` on macOS; on Windows the sibling `%LOCALAPPDATA%\baysol-cache`, since `%LOCALAPPDATA%\baysol` is the projects folder), never a folder of the repository (the old `<repo>/_cache/` is no longer used and can be deleted). What a program creates there is recorded in `dev-cache-manifest.txt` beside the cache, and the daemon removes those files when it exits. Downloaded structures (`.pdb`, `.cif`, `.mmcif`, `.ent`), the component files under `components/` and everything that was in the cache before a program ran stay. `bysl cache list` shows what would go; `bysl cache clear` removes it at once.

## Files


| File or folder                                                                                                                    | What it is                                                                                                                                                                                                                                                       |
| ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bysl.jl`                                                                                                                         | the launcher: client of the daemon, `daemon` management, `BYSL_DIRECT`                                                                                                                                                                                           |
| `Project.toml`, `Manifest.toml`                                                                                                   | the environment of the package `Dev`                                                                                                                                                                                                                             |
| `src/Dev.jl`                                                                                                                      | the registry of the tools and the dispatcher; `server.jl` is the daemon, `common.jl` the helpers every tool shares (the repository root, running programs, git, the fitting-test lookups, number formatting, the cache), `precompile.jl` the precompile workload |
| `src/fmt.jl`, `harvest.jl`, `results.jl`, `fits.jl`, `fixtures.jl`, `fixture-store.jl`, `Plots.jl`, `extract.jl`, `checks.jl`, `vis.jl`, `cache.jl`, `audit.jl`, `deps.jl`, `Test.jl`     | one file per tool (`bysl fmt`, `harvest`, `results`, `fits`, `plots`, `extract`, `precommit` with `unit` and `docs`, `vis`, `cache`, `test`)                                                                                                                     |
| `src/report.jl`                                                                                                                   | the readers of a fitting-test run: `parse_log` turns the sections of a run log (`<ID>.LOG`) into maps of numbers, `parse_report` reads the text reports (`res*.txt`) of older revisions; used by `results.jl`                                                    |
| `test/`                                                                                                                           | the tests of the tools (`runtests.jl`, `test-*.jl`, `helpers.jl`, `data/`) and their own `Project.toml`; run by `bysl test`                                                                                                                                      |
| `scripts/child.jl`, `diagnose.jl`, `profile-seed.jl`, `format.jl`, `harvest-defaults.jl`, `extract-formfactor.jl`, `unittests.jl` | the Julia scripts the tools start in another environment: the benchmark's measured process, the diagnostics, the profiler, JuliaFormatter, the two that need BAYSOL or SQLite from the root project, and the runner of the unit suite                            |
| `src/fit-seed.jl`, `seed-diagnostics.jl`                                                                                          | the `Seed` a fitting test would sample, built without fitting, and the sampler diagnostics that run on any `Seed`; a unit test includes them (plain files, not part of the module `Dev`: `include`d by the scripts and the unit tests, which have BAYSOL)        |

To add a tool, write a module with a `run(argv::Vector{String})::Int` and a `USAGE` text in `src/`, include it in `src/Dev.jl` and add it to `TASKS` there; a tool with subcommands nests one module per subcommand (see `harvest.jl`). A tool returns its exit status and never exits the process, since it may run in the daemon; `fail(who, message)` stops it with status 2 and a message. Add its tests to a `test/test-*.jl` file.

## Code conventions

- **Layout.** `bysl fmt` formats the Julia, TypeScript and SCSS files and wraps the prose of the READMEs and docstrings; code lines are at most 92 characters (`bysl fmt --lines` finds the others). Every text file is LF, in the repository and in every checkout: `.gitattributes` says `* text=auto eol=lf` (only `.cmd`, `.bat` and `.ps1` are CRLF), because the tools and the tests compare bytes.
- **The operating system is read in one place.** In Julia that is the root file `platform.jl`, the module `Platform` (see [the operating-system module](#The-operating-system-module) below); in TypeScript it is `tui/src/core/environment.ts`. The rule: no `Sys.iswindows`, `Sys.isapple`, `Sys.islinux`, `Sys.isunix` or `Sys.which`, and no `process.platform`, anywhere else. Code that works the same on every system is preferred; where it cannot, the switch goes through `Platform` (`Platform.iswindows()`, `Platform.exe`, `Platform.find_tool`, `Platform.cache_dir`, ...) or the `System` of `environment.ts`, so that it is found, tested (with a made-up system or environment) and changed in one file.
- **Numerical tests.** Numbers are compared to rounding or statistically, never bit for bit: see [the unit tests](../test/unit-tests/README.md).

## The operating-system module

`platform.jl` has no dependencies and is not a package of its own: each package that needs it includes it by its relative path (`src/BAYSOL.jl`, `dev/src/Dev.jl`, the setup wizard, `tui/julia`, `dev/bysl.jl`), which is why the module is `BAYSOL.Platform`, `Dev.Platform`, `BAYSOLSetup.Platform` and so on, one copy in each. It holds the detection (`iswindows`, `ismacos`, `islinux`, `isunix`, `os`, `arch`, `describe`), the names (`exe`, `PATH_SEP`, `DIR_SEPARATORS`, `library_path_variable`, `shell`, `user_id`), the program lookup (`which`, which also sees the Windows app-execution aliases such as juliaup's `julia.exe` and the `npm.cmd` beside the extensionless `npm`; `tool_dirs` and `find_tool`, which look on the `PATH` first and then in the folders where the installers put 7-Zip and LLVM) and the folders: `data_home`, `cache_home`, `config_home`, `runtime_home`, the one cache layout, `cache_dir`, `default_cache`, `default_structure_cache`, `structure_cache`, `within`, and the temporary root, `tmp_dir` and `tmp_process_dir`. The reference of every function is the [Platform API page](@ref BAYSOL.Platform); the TypeScript twin is described in the internals of the terminal interface (`tui/INTERNALS.md`).

**The cache layout** is one default for the whole project. `Platform.cache_dir()` is `baysol` in the cache home (`$XDG_CACHE_HOME` or `~/.cache`; `~/Library/Caches`; on Windows `%LOCALAPPDATA%\baysol-cache`, a sibling of the projects folder `%LOCALAPPDATA%\baysol`, since Windows has one folder for data and caches). Under it, `_structures` is THE cache: `structureCache` in `install.json`, what the launcher exports as `BAYSOL_CACHE` and what the fit reads. It holds only what must last (structures, the font list, the native files of the app), never a temporary file, and only the setup wizard clears it (Clear cache, Uninstall). `install.json` has no `cache` field any more (an old file that still has one is read, the field ignored and not written back). `_cache` beside it, `Platform.default_cache()`, is for the developer tools only: the fixtures unpack to `_cache/fixtures/<set>`. The old `<repo>/_cache/` folder is not used any more (it can still exist, and is ignored by git).

**Temporary files** have one root too: `Platform.tmp_dir()`, `baysol` in the temporary folder of the system, with one folder per process, `Platform.tmp_process_dir()` (`<tmp>/baysol/<pid>/<purpose>/`). The terminal interface makes all of its scratch folders there (`tui/src/core/scratch.ts` is the only code that does) and removes its own on exit; see its internals page.

## bysl fmt

```
bysl fmt [--julia|--ts|--scss] [PATH ...]          # format and re-wrap (rewrite the files)
bysl fmt --check [--julia|--ts|--scss] [PATH ...]  # only list what is not formatted
bysl fmt --lines [PATH ...]                        # report lines over 92 characters, tabs, skewed TypeScript indentation
```

The code rule of the repository is **at most 92 characters per line** in code files (`.jl`, `.ts`, `.tsx`, `.mts`, `.cts`, `.scss`, `.yml`; not Markdown or data). `bysl fmt`:

- formats the Julia files with [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl) (settings in `.JuliaFormatter.toml`, environment `test/format`) and the SCSS files with its own indentation rules (4 spaces a level);
- trims the trailing white space of TypeScript files and gives them one final newline, then runs [Biome](https://biomejs.dev) on them for the lint only (`biome check`, with `--write` for its safe fixes; settings in `biome.json` at the repository root, where Biome's formatter is off so the author's own layout and alignment stay). The 92-column limit is `bysl fmt --lines`. Biome comes from `BIOME`, `node_modules/.bin/biome` in the root or a folder below it, or the `PATH`; TypeScript files without one are a failure (`npm install --save-dev @biomejs/biome`). With no TypeScript file Biome is not called;
- re-wraps comments and docstrings: every comment block and docstring paragraph that contains a line over the limit is filled again, balanced; a block that fits is left alone, so a second run changes nothing. Plain triple-quoted strings (such as the usage texts) are not docstrings and are left alone;
- gives every code file its license header, `SPDX-License-Identifier: LGPL-3.0-or-later` in the file's comment syntax (the second line after a shebang);
- checks the names (kebab-case files, camelCase and UPPER_CASE identifiers) in `src`, `dev`, `test`, `tui` and, since 2026-11-23, `setup-wizard/` (its entry file is `src/baysol-setup.jl`, the module keeps the name `BAYSOLSetup`; likewise `tui/julia/src/baysol-run.jl` holds `BAYSOLRun`; the `entryfile` of the `Project.toml` names the file);
- checks the release name in `Project.toml` (at most 35 characters) and the names of the constants of every `src/*/Params.jl` (at most 23 characters); both are hard caps, since a longer name is hard to read.

`--check` lists the files that the formatters or the re-wrapping would change, without touching anything. Long string literals and symbols are split by hand: `bysl fmt --lines` also fails on TypeScript indented by anything but a multiple of 4 spaces (a continuation line, such as a ternary arm or a wrapped argument, goes one whole level deeper, never half a level; doc-comment lines and template literals are exempt). It reports every line still over the limit and every tab character, and the precommit refuses the commit while there is one.

## bysl harvest

```
bysl harvest [defaults|solutes|residues|pmv-mean] [--check]
```

Keeps the generated files and constants in step with their sources; with no name all four run, and `--check` changes nothing and exits 1 when something is out of date. `bysl precommit` runs the first form, so what a commit changes belongs to it. The harvested files are JSON.

- **`defaults`** writes `tui/assets/data/default_settings.json` (every setting: its default, type, limits and, where they apply, its choices, shape and part names, in the order of the `SETTING_NAMES` of the `params.jl` files) and `setting_relations.json` (the rules that tie settings together). It runs `dev/scripts/harvest-defaults.jl` in the root project, since it reads the constants of the package. A table that names a setting `SETTING_NAMES` does not list, or a tuple with the wrong number of part names, is an error.
- **`solutes`** writes `tui/assets/data/solute_index.json`: every name a user may type for a solute, to its canonical target (the lower-case IUPAC name of a non-biological solute, the grade of a polymer, the id of a polymer family), from the alias and value tables of `src/bulk-electron-density` and `tui/resources/polymer_families.json`. A polymer's `basis` says what its molarity is per where that is not the moles of chains.
- **`residues`** writes `tui/assets/data/residues.json` from `src/molecular-structure/components.tsv` (three objects, name to letter: `protein` has every peptide-linking component with its one-letter code, the one of the parent for a modified residue, its own for the 22 standard ones, `X` when there is no single standard parent; `dna` and `rna` have every linking component of that class with its base, `N` when the table names none). The terminal interface reads it to turn the residue names of a structure file into a sequence. No cut was needed: the file has about 2,650 entries (37 KB).
- **`pmv-mean`** rewrites the literal of `NONBIO_MEAN_UNCERTAINTY` in `src/bulk-electron-density/bulk-electron-density.jl` to the mean of the stated uncertainties of `nonbiological.json`, rounded to six decimals.

## bysl results

```
bysl results table [--update|--check|--tsv FILE] [ID ...]
bysl results compare [REV ...] [--no-tree] [--csv FILE] [--csv-all FILE]
bysl results compare --bench [OLD.json] NEW.json
```

- **`table`** generates the Results table of `test/fitting_tests/README.md` from the run logs `test/fitting_tests/*/<ID>.LOG`: `--update` rewrites it in place, `--check` exits 1 if it is stale (it compares cell by cell, so padding does not matter), `--tsv FILE` writes every quantity read from the logs, one row per run.
- **`compare`** compares fitting-test results (the run logs) between git revisions and the working tree, which is the column that is judged. With no revision the comparison is with the latest release (the newest tag that starts with `v` and a digit). It prints the time of every stage, the χ² spread and the parameter distributions, the sampler health, the MAP search, the problem sizes, the posterior widths and the worst fits. A key a log does not carry (the dropped chains of an older format, say) shows `-`. `--bench` instead compares the JSON results of `bysl fits bench`: the last file is the one judged, and with a single file it is compared with the newest baseline of the latest release in `test/baselines/`.

## bysl fixtures

```
bysl fixtures list [--set NAME | --root DIR] [--tmp DIR]
bysl fixtures pack [NAME ...] [--set NAME | --root DIR] [--force] [--flat]
bysl fixtures unpack NAME ... [--set NAME | --root DIR] [--tmp DIR]
bysl fixtures clean [--set NAME | --root DIR] [--tmp DIR]
```

The experiment fixtures (`test/fixtures/experiments/<ID>/`) are kept as one archive per entry, `<ID>.7z` next to the folder: 7z, LZMA2, `-mx=9`, solid, 64 MiB dictionary, every entry path starting with `<ID>/` (so `7z x -o<tmp> <ID>.7z` yields `<tmp>/<ID>/`). The 122 entries of 2026-11-18 take 15.7 MB instead of 126 MB.

- **`pack`** writes the archive under a temporary name, checks it with `7z t` and against the folder's file list, and moves it into place; an archive newer than every file of its folder is skipped unless `--force`. Afterwards the plain folder is removed, but only once the archive has been extracted into a scratch folder and found identical to it byte for byte (a mismatch keeps the folder and fails); `--keep-source` keeps the folder. So a new entry is built as a plain folder, packed, and leaves only its `.7z`.
- **`unpack`** extracts into the tmp root, `$BAYSOL_FIXTURES` if set, else `fixtures/experiments` in the fixtures cache (`Platform.default_cache()`, i.e. `_cache` beside `_structures`; outside the repository). A copy is complete when its `<ID>.stamp` (archive size and mtime) matches, and is then reused. The extraction goes into a private folder and is moved into place, so an interrupted run leaves no half folder that looks complete.
- **`clean`** removes only what the tool put in its own tmp root (unpacked folders, stamps, partial folders, the `.baysol-fixtures` marker) and refuses a folder without the marker; a folder that is not empty and was not made by the tool is never used as a tmp root.
- **`fits run`** unpacks the fixtures of each fit BEFORE the fit's process (and clock) starts, exports `BAYSOL_FIXTURES` to it, and removes the copy afterwards, whether the fit succeeded or not, unless `--keep-fixtures`; a copy that was already there (an explicit `unpack`) is left. `fits diagnose` and `fits export` unpack on demand the same way. An entry with a stale archive (a file of the folder is newer) is read from its plain folder, and one without an archive too, until the owner removes the folders.

**Archive sets.** The tool is generic: an archive set is a root folder holding one `<name>.7z` per item (the item's folder `<name>/` inside, or with `pack --flat` the item's files at the top level; `unpack` detects either layout and always yields `<tmp root>/<name>/`). Registered sets (`SETS` in `fixture-store.jl`): `experiments` (`test/fixtures/experiments`, the default) and `synthetic` (`test/fixtures/synthetic`, no archives yet). `--set NAME` picks one, `--root DIR` any other directory (its set name is the folder name); `list` shows packed, stale and unpacked counts per set, and one line per item with `--set`/`--root`. `test/fixtures/molecules` holds loose files, not one folder per item, so it is not a set. The tmp root of a set is `$BAYSOL_FIXTURES` for `experiments` (kept for the fitting scripts), else `$BAYSOL_FIXTURES_<SET>` (upper case, other characters `_`), else `<cache>/fixtures/<set>` (`<cache>` = `Platform.default_cache()`); `--tmp DIR` overrides it. The marker-file safety is the same for every set. `fits run` handles `SYN-*` entries with the `synthetic` set (`$BAYSOL_FIXTURES_SYNTHETIC`, `--keep-fixtures` applies); the synthetic scripts still read `test/fixtures/synthetic/<ID>` by a fixed path, so they need the plain folder until they are switched to an env-aware lookup.

The scripts find their fixtures with `fixtureDir("<ID>")` of `test/fitting_tests/common.jl`: `$BAYSOL_FIXTURES/<ID>` if it exists, else the plain folder, else an error that names `bysl fixtures unpack`. The code is `src/fixture-store.jl` (a plain file, also included by `fit-seed.jl`) and `src/fixtures.jl`; tests in `test/test-fixtures.jl`.

## bysl fits

```
bysl fits list
bysl fits run [ID ...] [--no-fit] [--bench] [--approved] [--report] [--table] [--fixme] [--keep-fixtures] [--trace-compile DIR] [--scratch DIR] [--threads N] [--dry-run]
bysl fits diagnose [--report] [--residuals] [--chains] [options] [ID[:tag] ...]
bysl fits export [ID ...] [--all] [--out DIR] [--dry-run]
bysl fits units [ID ...]                                  # q-unit guard: each script converts nm⁻¹ data (footer or .dat/.fit q-max ratio), nothing else
bysl fits profile ID[:tag] [ID[:tag] ...] [--delay SECONDS] [--nuts] [--dry-run]
bysl fits bench --approved [--state cold|warm] [--out FILE.json] ID[:tag] ...
```

- **`list`** prints every fitting test with the tags it takes (`fit2_model1 ...`, or `(single run, no tag)`).
- **`run`**: `ID ...` are folders of `test/fitting_tests/` (`SASDMJ9`, `SASDTK5`, ...). If one does not exist, nothing runs and the available folders are listed. With none given, every fitting test runs. Each fit is its script run with the `test/fitting_tests` environment; it rewrites its workbook, its figures and its section of the folder's run log (`<ID>.LOG`).
  - **`--no-fit`** skips the fits themselves, for when only a later step is wanted.
  - The steps run in a fixed order: the fits, then `--bench`, then `--report`, then `--table`, then `--fixme`. A failing step does not stop the later ones; the exit status is 1 if any failed.
  - **`--bench`** also runs the cold / steady-state benchmark on the selected fits, one `ID[:tag]` per run of each script. **Without `--approved` this only prints the benchmark's plan and runs nothing.** **`--approved`** is passed to the benchmark. Benchmark timings are only meaningful on a quiet machine, so a benchmark runs only after the repository owner has approved that run. `--approved` without `--bench` is an error.
  - **`--report`** prints the Results-table rows of the selected fits, from the run logs the fits just wrote. **`--table`** rewrites the Results table in `fitting_tests/README.md` from every run log, whatever IDs are named.
  - **`--trace-compile DIR`** runs each fit with Julia's `--trace-compile=DIR/<ID>.jl` (one file per fit; the flag truncates its file at the start of a process): the file lists the methods the fit's process had to compile at run time, i.e. what a precompile workload has not covered.
  - **`--scratch DIR`** runs a copy of each entry under `DIR` (`mirror_entry` in `fits.jl`: the script, `common.jl` and a link to `test/fixtures` in the layout the scripts expect), so the workbook, the run log and the plots of the fit land in `DIR` and the tracked LOGs, workbooks and plots of the repository are not touched. `bysl pkg` uses it for every fit of its trace stage.
  - **`--fixme`** runs the sampler diagnostics (`bysl fits diagnose --report`) on every run of the selected fits: MAP starts, Hessian, step size and tree depth, gradient error, modes. Use it when a fit looks wrong.
- **`diagnose`** runs the diagnostic parts described under "Sampler Diagnostics" below, on fits that already exist, without rerunning their fits or reports.
- **`export`** turns finished fitting tests into projects of the terminal interface, so nothing is typed in by hand: `projects/<ID>/` with `data.tsv` (q in Å⁻¹, from the workbook's `data` sheet), `data.json`, `buffer.json` (the script's `SOLUTES`, the pH, σ, temperature of the folder LOG), `settings.json` (`{}`), `models/` (the fixtures' structures) and one packed run `runs/<stamp>.7z` (`run.json`, `run.LOG`, per model the workbook, its LOG section and the `.tex` figures). Name the IDs or give `--all`; `--out DIR` writes into another projects folder (default: the BAYSOL data folder, `$BAYSOL_HOME` or `$XDG_DATA_HOME/baysol`); `--dry-run` writes nothing. A project that exists is left alone (reported), an entry whose workbook, solutes or structure cannot be read is skipped with the reason and sets exit status 1. The run has no terminal-plot tabs (those exist only on a screen); rerun the model in the TUI for them. Which script a folder has: `<ID>.jl`, else its single `*.jl` (`SASDC57_fit2.jl`); the solutes block may be `SOLUTES` or `SOLUTES_FIT<n>`. `--all` skips folders without a script. A script that builds `SOLUTES` with an `if` (SASDVN2, `:paper`/`:sasbdb`) is skipped with that message: its buffer is typed in the terminal interface. Checked 2026-11-20 on all folders: 296 written, 3 existed, 1 skipped, and the terminal interface lists and reads every project; a real run of an exported SASDMJ9 finished. The sampler keywords of the script's `runModel` call (`δ`, `retryNAdapt`, `retryNDraws`, `chainStartRadii`, `ladder`) become the project's `settings.json`, and the run keeps its own copy of `settings.json`, `buffer.json`, `data.tsv` and `data.json`, so the logs menu's restore options work on it. The curves a script gave to `results` as references (the workbook's `ref_<name>` sheets) are packed as `reference-fit.7z`, with `model-references.json` naming each model's curve and its `{software, refChi2}` from the LOG row `refChi2` (`CRYSOL 1.523`); one model gives the entry `*`, several give one entry per model stem.

  **Parser of a script's `runModel` keywords (`script_overrides`).** The source of truth for what a keyword is: `SETTING_KEYWORDS` in `src/pipeline/settings.jl` (every setting is a keyword of `seedModel`/`runModel`/`results`). The export reads only the keywords in `_SCRIPT_KEYWORDS` (`fits-export.jl`): `δ` (`TARGET_ACCEPT`), `retryNAdapt`, `retryNDraws`, `chainStartRadii`, and `ladder` (one rung per class, `(name = "...", overrides = (SETTING = value,))`; other classes keep the default ladder). Any other keyword is an ERROR (an override is never dropped silently). To wire in or fix a fit's overrides: put them as keywords of the one `runModel(` call of the script, add a new keyword to `_SCRIPT_KEYWORDS` mapping it to its setting name, and add a case to `dev/test/test-export.jl`; a project already exported must be removed by the owner and exported again.
- **`profile`** builds the `Seed` of each fitting test twice in one process (the first call warms the compiler) and profiles the second with Julia's sampling profiler: the stage timings of that build (each static stage with its note, e.g. `[cache hit]` or the residue counts of the nucleotide stages; see "Reports" below) and the samples by function, charged to the innermost BAYSOL function (its own code plus the libraries it calls) and inclusive. The profiler slows the code by a factor of several, so read the proportions, not the seconds. It is how the time in `forwardCache` was found; use `bysl fits bench --approved` or the reports to measure a change.
- **`bench`** is the cold / steady-state benchmark driver (protocol below): a throwaway depot and repository copy, one `child.jl` process per fit, one JSON result.

## bysl vis

```
bysl vis [NAME ...] [--list] [--dry-run]
```

- **`NAME ...`** are the visual checks (see `--list`): `plastic_2d`, `plastic_3d`, `sasa_hydro` and `sasaHydroReport`. An unknown name stops the run before anything starts. With none given, every check runs, one after the other.
- Each check is one call in a fresh Julia process in `test/visualize`'s own environment. Everything but `sasaHydroReport` opens a window, so it needs a display; `sasaHydroReport` prints numbers only.

## bysl unit, bysl test

`bysl unit` runs every `../test/unit-tests/units/test-*.jl` (or, given words, the files whose name contains one of them; a word that matches no file is an error); a new test file is picked up by creating it there. Each file is also runnable on its own (`julia --project=test test/unit-tests/units/test-sampler.jl`).

`bysl test` runs the tests of the dev tools, `test/test-*.jl` in this folder, in their own environment (`test/Project.toml`, which has the package `Dev` as a path dependency). They cover the helpers, the formatter and its rules, the harvesters, the readers of the run logs and what is built on them, the extractors, the cache and the command lines of the tools. They run no fit and no benchmark (`fits bench` is tested only without `--approved`, on a sandbox). Given words, only the test files whose name contains one of them run (`bysl test fmt results`); the exit status is 1 if a test fails.

## bysl extract

```
bysl extract formfactor xraydb.sqlite src/scattering/form_factors.sqlite3
bysl extract components [--check|--update] [SOURCE [OUT]] [--val-inference]
bysl extract pmv SUBCOMMAND [args]        # run | batch | fit | holdout | estimate | row
```

Offline tools that regenerate the data bundled with the package; neither runs at run time, and the results are checked in.

**`formfactor`** rebuilds `src/scattering/form_factors.sqlite3` from xraydb's `xraydb.sqlite` (Waasmaier-Kirfel f0, Chantler f1/f2, and deuterium as a copy of hydrogen). It runs `dev/scripts/extract-formfactor.jl` in the root project, which needs SQLite.jl. The database is built in a temporary file next to the destination and renamed over it when it is complete.

**`components`**: `src/molecular-structure/components.tsv` is the built-in lookup of the component dictionary, so that a residue name is classified without a network. The tool regenerates it from the wwPDB file `components.cif.gz` (default `https://files.wwpdb.org/pub/pdb/data/monomers/components.cif.gz`, or a local copy or other URL given as the first argument), reading the gzip as a stream. The file starts with `#` lines (source URL, the file's Last-Modified, the fetch date, `# rows: N`, the column names), then one row per component sorted by id, tab separated:


| Column                | Content                                                                                                                                                            |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`                  | `_chem_comp.id`                                                                                                                                                    |
| `class`               | `dna` or `rna` when the type contains the word DNA or RNA (so `l-dna linking`, `l-rna linking` and the 3'/5' terminus types are nucleic acids), else `other`       |
| `type`                | `_chem_comp.type`, lower-cased (`non-polymer`, `l-peptide linking`, `dna linking`, ...)                                                                            |
| `parent`              | `_chem_comp.mon_nstd_parent_comp_id` (the standard residue a modified one derives from), `-` when there is none                                                    |
| `formula`             | `_chem_comp.formula` without its quotes (`C2 H4 O3`)                                                                                                               |
| `base`, `base_source` | the natural base (`A`, `C`, `G`, `U`, `T`, `-` when none) of a `dna` or `rna` component and where it comes from: `parent`, `self`, `letter`, `ring`, `name` or `-` |

**How `base` is inferred.** Offline, never at runtime. The signals, in order: the declared parent, the standard residues, the one-letter code, the ring chemistry, the name; when two signals that found a base disagree the result is `-` (no guess). The ring signal reads the bond graph of the heavy atoms by position: it finds the furanose ring (one O, four C), the glycosidic nitrogen on the carbon next to the ring O, prunes the base ring system and numbers it from that nitrogen. Pyrimidine: an amine on C4 and an oxygen on C2 is `C` (an amine only at C5 is not); oxygens on C2 and C4 are a uracil or a thymine, which the ring cannot tell apart (see below), so alone it gives `-` and agrees with a letter or name that says U or T. Purine: an amine on C6 with no amine or oxygen on C2 is `A`; an oxygen on C6 with an amine on C2 is `G`; inosine-like (C6 oxygen, no C2 amine), isoguanine-like and diaminopurine bases are `-`. Abasic sugars, C-nucleosides, dyes and anything without a recognisable base ring are `-`.

`--val-inference` applies the letter, ring and name signals blind to the nucleic components that declare a parent and compares with the base that parent leads to: per signal the coverage and precision, and the confusion counts. On the 2026-10-10 dictionary (562 components): letter 432 found, 100 % correct; ring 250 found, 99.2 % correct; name 404 found, 97.8 % correct; all together 512 found, 99.4 % correct. The ring signal does not decide U against T because the dictionary's parents do not follow the C5 methyl (5-methyluridines have parent `U` in 10 RNA components and `T` in 15; 5-substituted thymidines with another group on C5 have parent `DT`): taking methyl as T and the rest as U was right only 87 % of the time. That validation set is biased toward components whose letter and name were filled in with their parent; on the components without a parent the letter signal finds far fewer.

A missing field reads as `?`, and a tab inside a value becomes a space. `--check` compares the data only (the dates come from the checked-in header), so a newer dictionary shows as a diff of rows. `--update` writes today's date as the fetch date and the download's `Last-Modified` as the source date.

```bash
bysl extract components --check    # download the dictionary, compare with the table; exit 1 if stale
bysl extract components --update   # ... and rewrite src/molecular-structure/components.tsv
bysl extract components components.cif.gz --check   # from a local copy
bysl extract components --val-inference             # precision of the base inference (no table written)
```

## bysl plots

```
bysl plots render DIR [--recursive] [--type pdf|svg|png|jpeg]
bysl plots fonts NAME [NAME ...]
bysl plots fonts --list
```

**`render`** renders the `.tex` figures that `results` writes. `DIR` is the folder with the files; `--recursive` also takes its subfolders. Each file is compiled with `lualatex` (or `xelatex`) in its own folder, with `-interaction=nonstopmode -halt-on-error`, and its `.aux` and `.log` are removed afterwards; a file that fails keeps its `.log` and the others still run. The default `--type pdf` needs only the engine; `svg`, `png` and `jpeg` convert the PDF with poppler's `pdftocairo` and remove it. Output files sit next to their `.tex`. The exit status is 1 if any file failed or no engine is installed. SVG is about four to five times the size of the PDF and its text is outlines, not text, so it is for web pages and slides.

**`fonts`** asks the TeX Live installation whether a font can be used for the figures. For each `NAME` (a `fontspec` name such as `TeX Gyre Pagella` or `Latin Modern Math`; case and spaces do not matter) it prints `NAME: true` or `NAME: false`, and the exit status is 1 if any is `false`. Any font that says `true` is a valid `font` of `results`, as the text font, or as the second entry of a `("Text font", "Math font")` pair. `--list` prints every installed font family (from `fc-list`, or from LuaLaTeX's index where there is none), the math fonts first. The check is `luaotfload-tool --find`, which comes with TeX Live, and it does not rebuild the font database: a font installed since the database was last built needs `luaotfload-tool --update` first. Without `luaotfload-tool` the tool stops with a message, since nothing can be said about a font. `BAYSOL.fontAvailable("NAME")` is the same question from Julia.

## bysl pkg

```
bysl pkg [--out DIR] [--work DIR] [--workload DIR] [--stage NAME] [--resume] [--keep-work] [--dry-run]
```

Builds the packaged app for this system: ONE archive `baysol-<semver>-<os>-<arch>.zip` (7-Zip deflate, maximum settings) with the three executables, the runtime and one icon file. It runs long jobs (about 11 GB of memory in the image build): only with the owner's go-ahead, one heavy job at a time. `--dry-run` prints the plan and the preflight and builds nothing.

- **Icon:** the hand-made PNGs in the root of `icons/` (`icon_NxN.png`, `icon_NxN@2x.png`, checked against their headers, never resized or generated) are packed in Julia (`pack_icon`) into `baysol.icns` (macOS: only sizes macOS has a type for; Linux: also 22, 24 and 48 px under private codes, which the setup wizard unpacks into the `hicolor` theme) or `baysol.ico` (Windows: sizes up to 256 px, PNG entries). No `.iconset` folder, no `iconutil`.
- **Strip (stages `tui` and `bundle`):** `llvm-strip --strip-all` on ELF and PE (one tool for ELF, Mach-O and PE; no GNU fallback) on the bundle's own copies, never the Julia installation they came from: every `.so`/`.dylib`/`.dll`, the `baysol` executable (measured on linux-aarch64: 147 MiB from the libraries, 108 MiB from the executable; `--help`, a real fit and stack traces with file:line unchanged, since that metadata is Julia's, not DWARF) and `baysol-pytools` (with the frozen Python's `.so` files; still runs). The Node binary is stripped BEFORE `postject` injects the blob (147 to 112 MiB; a stripped Node takes the blob and runs), because any strip of the finished `baysol-tui` moves the injected segment and the program prints nothing (measured). `--strip-all` is used because llvm's saves only 17 KB over `--strip-unneeded` (measured; 12 fit runs of each passed, the earlier 12 MiB figure was GNU strip). macOS (`-x` on dylibs, `-S -x` on executables) and Windows are best effort and untested; sign after stripping. Each platform has its own function (`strip_linux`, `strip_macos`, `strip_windows`) building the command lines as pure functions of the tool path and file lists (`strip_command_lines`); `strip_bundle` and `strip_binary` run them and the report gets one `strip:` line with the size before and after. Without `llvm-strip` the step warns in the report and on the terminal and the file stays unstripped; a failing strip fails the stage.
- **Archive:** written to the folder the command is run from; `--out DIR` overrides it.
- **Scratch folder** (`--work`): by default `baysol/baysol-pkg-work` in the cache home of the system (`Common.cache_home()`: `~/.cache` on Linux, `~/Library/Caches` on macOS, `%LOCALAPPDATA%` on Windows), no longer under `/tmp` (a tmpfs is too small and is cleared by a reboot). **A build is always cold (owner, 2026-11-23):** without `--resume` an earlier folder is removed first, and every program runs with its own caches inside the folder (`cold_env`: `JULIA_DEPOT_PATH` = `<work>/depot`, filled once by `Pkg.instantiate` of `tui/julia`, `test` and `test/fitting_tests`; `UV_CACHE_DIR`, `NUITKA_CACHE_DIR`, and `BAYSOL_CACHE` for the fits' structure downloads), never the user's `~/.julia`. These caches are deleted when the archive is written (`remove_caches`, even with `--keep-work`), the folder too. A failed run keeps everything; `--resume` (implied by `--stage`) continues it (`<ID>.done` and stage markers are honoured only then). **`--keep-work`** keeps the rest after a success; it then also holds what the trace fits wrote (workbooks, run logs and plots under `<work>/trace/results`).
- **Stages** (`--stage NAME` runs one): `pytools` (propka and pdb2pqr frozen with Nuitka; its entry script is the text `PYTOOLS_ENTRY` inside `dev/src/pkg.jl`, written to `<work>/baysol-pytools.py`), `tui` (Node single executable), `trace`, `julia` (juliac: the `WORKLOAD` fits and the traced statements compiled into `baysol`), `bundle`.
- **Trace stage** (Julia `--trace-compile`, one file per program, one program at a time, 4 threads, the frozen Python tools through `BAYSOL_PYTOOLS`): it replaced the loop over all 300 fitting tests. It runs (1) the 14 entries of the `TRACE_ENTRIES` table of `pkg.jl` (`id`, `covers`, `workload`): SASDMJ9 protein (the output variants use it), SASDAN8 DNA, SASDAH5 protein and DNA, SASDVA2 ligands and c1 kink, SASDMC6 c1 kink, SASDUX3 99 000 atoms, SASDX52, SASDJ66 and SASDP74 (divergent, marginal, small divergent), SASDG44, SASDAP8, SASDT65 and SASDTV4 (one entry per ladder failure class), SASDCE8 (q blocking); the five with `workload = true` (the first five) are also the `WORKLOAD` compiled into the executable; plus all 34 synthetic entries (`Common.synthetic_ids()`), each by `bysl fits run ID --trace-compile ... --scratch <work>/trace/results --threads 4`, so no tracked file of the repository changes; (2) the unit suite (`UNIT_JOBS=1`) and each `tui/test/*.test.jl`; (3) `trace_project_runs`: every `WORKLOAD` project exported by `bysl fits export`, run once by the real `runProjectCli` and once by the real TUI (`tui/test/support/trace-run.ts`, started with `BAYSOL_TRACE_COMPILE`); (4) `trace_output_variants`: `runProject` five times on a copy of the first workload project with a second model (so `compareResults` draws), the settings of `OUTPUT_DRIVER`: `:tui` with the plot sizes, `.tex` figures, rendered pdf/png/svg, another LaTeX font, and two runs that force the `structural` rung (sample c1) and the `generic` rung (the next seed) of the retry ladder for every class through the `ladder` keyword (the rendered variants need `lualatex` and `pdftocairo`, else `.tex` only). A fit that fails is reported and does not stop the stage.
- **Runtime layout and natives (2026-11-23):** libjulia sits in `julia/` and the private libraries in `julia/julia/`, as libjulia expects (the executable's RUNPATH is patched to both); no symlinks, no `sys.so` (traced: never loaded). The non-stdlib JLL libraries (EarCut, Rmath, OpenSpecFun, Dierckx, SQLite) are found through generated preferences instead of the build machine's artifact path. CondaPkg is not a dependency of the app: `hydrogenator.jl` loads it by `PkgId` only for the development environments, the app uses `BAYSOL_PYTOOLS`. The interface's native files (resvg, pdf-raster + PDFium, 7-Zip) are SEA assets written to the cache on first use (`native_assets`; `notes/tui.md`); `sharp` is gone. The pytools stage drops docstrings and unittest/setuptools/pytest/pydoc (`requests` stays: `pdb2pqr/io.py` imports it).
- **Report (2026-11-23):** the terminal and `baysol-pkg-report.txt` (beside the archive) carry only the status, never the output of the programs. Every stage and every step (each fit, the unit suite, each TUI test, each project run, the output variants, juliac, the archive) runs through `step`: its whole output goes to `<work>/logs/<name>.log`, and the report gets one line with `ok` or `FAIL`, the wall time and the peak RAM and swap of the processes of that step (`watch_memory`: `VmRSS` and `VmSwap` summed over the process tree, sampled every 2 s, Linux; never the rest of the machine). A failed step adds the lines of its log that matter (`problems`: failed tests, errors) and the log's path; the juliac step adds the `statements: N compiled, M not` line and the workload's `model ... failed` lines. A failed stage ends the build (exit 1) and keeps the scratch folder. The swap guard (`guarded`, kills a job when free swap drops under 500 MiB) is separate.
- **Build log (2026-11-24):** a successful full build (no `--stage`) writes ONE tracked file, `dev/build-logs/baysol-<semver>-<os>-<arch>.LOG`, before the scratch folder is removed; nothing else of the build is kept. Rows `name<TAB>value` (datetime, version, archive, revision, julia, node, python, system), `--- stages ---` (the report: time, peak RAM and swap per stage), `--- step: <name> ---` per step and `--- machine ---`. A step log passes `clean_log` (ANSI colours, `\\r` progress redraws, terminal plots and their titles, blank runs and repeated lines removed, long lines cut) and `trim_log` (first 40 and last 120 lines); a step with nothing left is not listed. The tool tests cover the filter on canned input.
- **Merging** (`merge_statements(lines; allowed)`): the statements of all trace files, first occurrence kept. It drops those naming `Main`, `Test`, `Dev` or `PkgTool`, and, with `allowed = app_modules()` (the modules of `tui/julia/Manifest.toml` plus `Base` and `Core`), every statement that names a module the app does not hold: the unit suite's helper modules, JET, Aqua, LLVM, GPUCompiler and the like. Reason: 986 statements did not compile in the image (their modules are not in it), so the build failed or warned; the statements of the packages the app does ship keep their coverage. A printed `Char(0x...)` is rewritten to `reinterpret(Char, 0x...)` (the constructor refuses the printed value; the Printf formats of every fit are written that way), so those statements are kept instead of lost.

### Before the first build on Windows or macOS

Neither system has ever run `bysl pkg`. Checked WITHOUT a build (2026-11-24, on Windows 11, Julia 1.12.7):

- **`platform.jl` is found wherever the checkout is.** Every stage compiles in place from the checkout (`juliac` gets `tui/julia/app/baysol.jl` and the project `tui/julia`, whose `[sources]` are path dependencies `../..` and `../../setup-wizard`); the only copies of the tree are `mirror_entry` and `copy_repo` of `bysl fits`, and `copy_repo` takes every file that git lists (tracked or untracked, not ignored), so the root `platform.jl` goes along once it is not ignored. Proved by copying the checkout (no `node_modules`, `.git`, `_cache`) to a folder with spaces and an accent in its name and loading `BAYSOL`, `Dev`, `BAYSOLSetup` and `BAYSOLRun` from it.
- **Trace statements:** `BAYSOL.Platform.*`, `BAYSOLSetup.Platform.*` and `BAYSOLRun.Platform.*` are kept, `Dev.Platform.*` and anything else naming `Dev` or `Main` is dropped (unit test `the Platform module in the statements`).
- **Windows runtime DLLs:** all of Julia's `bin` (55 of 62 DLLs, `runtime_files`) is shipped; pruned are the test libraries (`libccalltest`, `libccalllazy*`, `libllvmcalltest`), `libgit2`, `libdSFMT` and `libgmpxx.dll`. Every DLL that `libjulia`, `libjulia-internal`, `libjulia-codegen`, `libopenblas64_` and the rest import (`llvm-objdump -p`) is either shipped or a system DLL. There is no `lib/julia` on Windows: `runtime_layout` puts every DLL, and the JLL libraries, beside the exe (a Windows exe has no RUNPATH).
- **Windows fixes made from reading, not from a run:** `--relative-rpath` is not passed (`juliac.jl` stops with "unimplemented" on Windows); the `gcc` preflight is dropped on Windows; `node.exe` is at the top of the Node zip, not in `bin/`; the zip is unpacked with 7-Zip (the `tar` on the PATH may be Git's GNU tar); `esbuild` and `postject` run as their `.cmd` shims; `patchelf` is installed on Linux only; the Nuitka output name carries `.exe`; `TMP`/`TEMP` point into the scratch folder; `node.exe` is not stripped; a file `llvm-strip` refuses is a warning in the report, no longer a failed build; on macOS `install_name_tool` adds the `julia/julia` rpath that `libjulia-internal` needs.

Facts about the compilers (read from `share/julia/juliac/juliac.jl` and the Nuitka documentation):

- **juliac on Windows** links with `gcc.exe`/`g++.exe` of the lazy artifact `mingw-w64` (GCC 14.2 posix-seh from the PackageCompiler releases), downloaded into the Julia depot by `LazyArtifacts` on first use: no compiler on the PATH, no MSVC `link.exe`, but network access during the `julia` stage (the build's cold depot downloads it each time). `JULIA_CC` overrides it. On Linux it looks for `g++`/`clang++`, then `gcc`/`clang`, on the PATH.
- **Nuitka 4.3.5 on Windows** uses the newest MSVC (Visual Studio Build Tools, workload "Desktop development with C++") when installed, else MinGW64 (winlibs) that it downloads itself; `--assume-yes-for-downloads`, which `stage_pytools` passes, answers its prompts (this also downloads the tools unchecked, see Nuitka issue 3997). Python is 3.12 (`PY_VERSION`); `uv` provides it.
- **Node single executable:** `--experimental-sea-config` and `postject` (sentinel `NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2`) work on `node.exe`; Windows needs no signature removal before injecting (macOS does: `codesign --remove-signature`). Node 26 also has `node --build-sea`, not used.
- **Needed on the PATH on Windows:** `uv`, `curl` (System32), `npm`, a Julia 1.12 (juliaup) and the checkout's `node_modules` (`npm ci`). 7-Zip (the `node_modules/7zip-bin` copy is used first) and `llvm-strip` (LLVM; without it the bundle is only unstripped) are found without the PATH too, in the folders the installers use (`Platform.find_tool`).

After the first build, check (each command reads files only):

1. `bysl audit baysol --files` (exit status 0, no MISSING; `relies` lines are what the bundle expects the machine to have) on the unpacked bundle: every import of every executable and DLL is shipped (on Windows the same as `llvm-objdump -p baysol.exe | findstr "DLL Name"` for `baysol.exe`, `baysol-tui.exe`, `lib\pytools\baysol-pytools.exe`).
2. `baysol.exe version`, then `baysol.exe run` on a small project: the first run proves that the JLL libraries (SQLite, Rmath, ...) are found beside the exe, and that the artifact marker folders `share\julia\artifacts\<hash>` are enough.
3. `baysol-tui.exe --help`: the SEA blob is injected and the assets are inside.
4. `lib\pytools\baysol-pytools.exe propka3 --help` and `... pdb2pqr --help`: the stripped, frozen Python runs (if it does not, the report's `strip:` line names the refused files; strip a smaller set).
5. `baysol-pkg-report.txt`: no `strip: WARNING` line, no `workload:` failures.
6. macOS only: `codesign -dv baysol` and `./baysol version`; `install_name_tool` and `llvm-strip` invalidate the signature, and Apple Silicon kills an unsigned binary: run `codesign --force --sign - <file>` on `baysol`, `baysol-tui` and every dylib as the last step if so.

Still uncertain, to look at in the first failure: `llvm-strip` on the Nuitka PE files; `uv`'s Python build under Nuitka on Windows; whether `libjulia-internal.dll` finds the JLL DLLs beside the exe through the default DLL search (the first `baysol.exe run` shows it); `addenv("PATH" => ...)` when the real variable is spelled `Path`.

## bysl audit

```
bysl audit DIR [--search DIR]... [--files] [--strict]
```

Audits a built bundle (the `baysol/` folder that `bysl pkg` stages, or any folder) without a build: every PE (`.exe`, `.dll`), ELF (`.so`) and Mach-O (`.dylib`) file under `DIR` is found by its signature and its imports are read from the headers, in Julia. That is the choice over `llvm-objdump -p`, `readelf`, `otool -L` or `dumpbin`: one parser per format of about 40 lines, no tool to install, the same result on every system, and the tests run it on files built in the test and on the real files of the machine (`julia`, Node). The allowlist is chosen by the format of the file, not by the system that audits, so a Windows bundle can be audited on Linux.

Each imported library gets one status, and the table shows the worst one per library with the files that need it:

- **bundle**: found in the bundle where the loader of that format looks. PE: beside the importing file, the bundle root and `julia/` (names compare without case). ELF: the `RUNPATH` (else `RPATH`) of the importing file with `$ORIGIN` expanded, nothing beside the file unless the path says so. Mach-O: `@rpath` through the `LC_RPATH` entries, `@loader_path` and `@executable_path` (taken as the bundle root). `--search DIR` adds a folder that the launcher puts on the loader's path (like `LD_LIBRARY_PATH`). A file outside the bundle never counts.
- **system**: present on every clean install. Windows 10 and 11: `kernel32`, `user32`, `advapi32`, `ws2_32`, `ntdll`, `msvcrt`, `ucrtbase`, `api-ms-win-*`, `ext-ms-win-*` and the other system DLLs of `WINDOWS_SYSTEM`. Linux: glibc (`libc`, `libm`, `libdl`, `libpthread`, `librt`, `libutil`, `libresolv`, `libanl`), the dynamic loader and the vDSO. macOS: anything under `/usr/lib/` and `/System/Library/`.
- **relies**: not carried and not always there, so the bundle depends on the machine: `libstdc++.so.6`, `libgcc_s.so.1`, `libgomp`, `libatomic`, `libgfortran` and `libquadmath` on Linux, the Visual C++ runtime (`vcruntime140`, `msvcp140`, `concrt140`, `vcomp140`, ...) on Windows. It is reported, never silently allowed; `--strict` makes it a failure.
- **MISSING**: none of the above. The MinGW runtime of Julia on Windows (`libgcc_s_seh-1`, `libgfortran-5`, `libstdc++-6`, `libwinpthread-1`, `libquadmath-0`) is not a system file, so it is MISSING unless the bundle carries it; a block after the table says for each how many binaries import it and whether the bundle holds it.

`--files` lists the imports of every binary. The exit status is 1 if anything is MISSING or a file with a binary signature cannot be read (the report names it), else 0; 2 for a wrong command line. Weak Mach-O imports (`LC_LOAD_WEAK_DYLIB`) are not needed by definition and are skipped. Run on the `bin/` folder of a Windows Julia 1.12.7 (63 programs and libraries, 263 imports) it finds every import in the folder or in the system list: the MinGW runtime is carried and nothing relies on the machine.

## bysl deps

```
bysl deps [--install NAME]... [--yes]
```

Prints what a developer needs and what this machine has, one line per item with its state (`ok`, `MISSING` for a required item that is absent, `missing` for an optional one, `n/a` for an item that is not for this system, `unavailable` for one that cannot work on it) and its version or the path found, then the exact install command for each missing item on this system (`winget` on Windows, `brew` on macOS, `apt-get` on Linux; a route that is no command, such as Node 24 on Linux, is printed as text). The exit status is 1 if a required item is missing, 2 for a wrong command line.

| Item | Required | Notes |
|---|---|---|
| `julia` | no | informational; 1.12 |
| `git` | yes | |
| `node` | yes | Node 24 or newer, with `npm` |
| `npm-packages` | yes | `node_modules` of the checkout; the install is `npm ci` |
| `7z` | yes | 7-Zip (`7z` or `7zz`) on the PATH for the tests and `bysl fixtures`; `bysl pkg` itself uses the npm `7zip-bin` |
| `uv`, `curl`, `tar`, `gcc` | yes | the programs of `PkgTool.preflight_programs` (one list for both tools). On Windows `gcc` and `tar` are `n/a`: juliac downloads its own MinGW-w64 gcc and Nuitka uses MSVC or downloads MinGW64 (network needed), and the Node zip goes through 7-Zip |
| `llvm-strip` | no | LLVM, the strip tool of `bysl pkg` (it warns without) |
| `patchelf` | no | Linux only; comes with the build's venv |
| `memory` | yes | Linux only: RAM plus swap of at least 24 GiB, the check of `bysl pkg` |
| `rdkit` | no | `RDKit_jll` for the pmv tools. **Windows: unavailable** (its `librdkitcffi.dll` exports none of the functions that RDKitMinimalLib calls, and the newest `RDKit_jll` has no such library): the report says the pmv tools are skipped and no install is ever offered |
| `ambertools` | no | 3D-RISM for `pmv run` and `batch`, through conda; not on Windows |
| `tex-engine`, `tex-packages`, `tex-fonts`, `pdftocairo` | no | TeX for the plots, all optional (see below) |

**TeX (optional).** BAYSOL does not need TeX: the figures are `.tex` files and compiling them is opt-in. When TeX is installed the four items say whether it is enough, each from the code that needs it (`kpsewhich` for files, `luaotfload-tool --find` for fonts, as `bysl plots fonts`). With no TeX they all read `TeX not installed (optional)` and the first prints the minimal install for the system; with TeX but something absent they read `incomplete: missing ...` and print one ready-to-run line per package manager (`tlmgr install ...`, plus `apt-get`, `dnf` and `pacman` on Linux). A TeX install is never run, and no TeX item changes the exit status.

| Need | What | Proof in the code |
|---|---|---|
| engine | `lualatex` (default, with `luaotfload`) or `xelatex`; `pdflatex` only for `font = nothing` or a compiler path that is set | `src/pipeline/results.jl:986-1007`; the default font `params.jl:226-232` |
| class and packages | `standalone.cls`, `tikz.sty`, `pgfplots.sty` (its libraries groupplots, polar, smithchart, statistics, dateplot, ternary, and `tikzlibraryfillbetween.code.tex`), `xcolor.sty`, `fontspec.sty`, `unicode-math.sty`, `lualatex-math.sty` | PGFPlotsX `tikzdocument.jl:135` and `build.jl:94-103`; `results.jl:432-445` |
| fonts | `TeX Gyre PagellaX` (TeX Live `newpx`) and `TeX Gyre Pagella Math` (`tex-gyre-math`) | `params.jl:226, 232`; `results.jl:404-419` |
| converter | `pdftocairo` (poppler) for PNG, SVG, JPEG; PGFPlotsX also accepts `pdftoppm` (PNG) or `pdf2svg` (SVG); the PDF needs none. No `dvisvgm`, and no TikZ library is loaded | `dev/src/plots.jl:79, 102`; PGFPlotsX `build.jl:140, 188`; `pkg.jl:1016` |

Minimal routes: Linux `apt-get install texlive-latex-base texlive-luatex texlive-latex-recommended texlive-latex-extra texlive-pictures texlive-fonts-extra fonts-texgyre-math poppler-utils` (the Debian package of each file was checked on packages.debian.org; the `dnf` and `pacman` names follow the distributions' naming and are unverified); macOS `brew install --cask basictex`, then `sudo tlmgr install luatex luaotfload standalone pgf pgfplots xcolor fontspec unicode-math lualatex-math newpx tex-gyre-math` and `brew install poppler` (MacTeX is much bigger); Windows: TeX Live's `install-tl-windows.exe` with `scheme-basic`, then the same `tlmgr install`, or MiKTeX, which installs missing packages on the fly (full TeX Live is large; the sizes of the minimal routes are unverified).

A program that is installed but not on the PATH (7-Zip, LLVM and MinGW are, on Windows, by default) is reported as such, with the advice to add its folder, and no second install. `npm` is looked up as `npm` and as `npm.cmd`: on Windows `Platform.which("npm")` alone misses it.

**Installing.** `--install NAME` installs one item (repeat the option for more; an optional one too), `--yes` every missing required item that applies to this system. The commands run through a runner that the tests replace, so the tests install nothing. There is no prompt (the daemon does not forward input) and nothing is elevated: a command that needs an administrator (the `sudo apt-get` lines) is printed with "run it yourself" and never run. After the commands the item is detected again, and one that is still absent (often a PATH that a new shell would see) is reported as a failure. Items that are `n/a` or `unavailable` here are never installed.

## bysl docs

```
bysl docs
```

Builds the site with Documenter.jl in `../docs/` (`julia --project=docs docs/make.jl`), strict: a broken cross-reference or an undocumented docstring fails the build. It first copies the READMEs of `src/`, `test/` and `dev/` into `docs/src/` (edit a README, never its copy) and writes the site to `../docs/build/`. `bysl precommit` runs the same build as its last step.

## bysl precommit

```
bysl precommit [--quick] [--dry-run] [--threads N]
```

The single entry point to run before a commit; a failing step does not stop the later ones and the exit status is 1 if any failed. Steps, in order: **tool-tests**, **pmv-mean**, **solute-index** and **residue-table** (the harvesters rewrite what is stale; the changed files belong in the commit), **unit-tests**, **concurrency-tests**, **whitespace** (trailing whitespace on the lines you changed, untracked files included, is stripped and reported, never a failure; only a leftover conflict marker fails), **default-settings** (the harvest of the defaults), **ts-format**, **ts-unused** ([Knip](https://knip.dev), config `knip.jsonc`: an unused dependency, file, export or type of `tui/` refuses the commit), **julia-format**, **line-length** (a line over 92 characters, a tab, or TypeScript, Julia or SCSS indented by anything but a multiple of 4 spaces refuses the commit; Julia lines that continue an expression after a trailing operator are exempt, JuliaFormatter aligns those), **results-table**, **q-units** (`bysl fits units`) and **docs-build** (the strict documentation build). `--quick` skips the Julia steps (unit-tests, concurrency-tests, default-settings, julia-format, docs-build). It never runs a fitting test or a benchmark.

**`pmv`** runs `dev/src/pmv.jl`, the 3D-RISM partial-molar-volume tools (conformers, AmberTools 3D-RISM with cSPC/E water and the KH closure, a Bayesian group correction fitted on measured solutes, candidate rows for `src/bulk-electron-density/polymers/`, and the redo of the old `estimated` rows). It is Julia (RDKit through RDKitMinimalLib.jl, no MMFF: several ETKDG seeds per run); only `run` and `batch` call the external AmberTools of `$AMBERHOME` (default `~/.conda/envs/amber26`). It is not part of `bysl precommit`: a run takes hours of every core. Every command needs `--out DIR`; the section "pmv: partial molar volumes by 3D-RISM" below has the commands, inputs, outputs, run times and the rebuild-from-scratch recipe.

## pmv: partial molar volumes by 3D-RISM

Reconstructs the partial molar volume (PMV, cm3/mol) of a solute that has no measurement,
for the `estimated` rows of the bulk-electron-density tables
(`src/bulk-electron-density/polymers/` and `non-biological/`). The tools: a 3D-RISM
driver, a Bayesian group correction fitted to measured solutes, and read-only diagnostics.
All of it is `dev/src/pmv.jl` (module `Pmv`, run as `bysl extract pmv --out DIR SUBCOMMAND
...`); the only other file is the queue of missing solutes, `dev/data/pmv-queue.tsv`.

### Data inside `pmv.jl`

Nothing is read at fit time: BAYSOL itself only reads the finished tables under
`src/bulk-electron-density/`. `pmv.jl` is the workshop that produces their `estimated`
rows, and its two bundled tables are the inputs of every command. Each is CSV text in the
source, aligned as a table (columns padded to one width and separated by `|`, which occurs in
no field; numbers right-aligned, text left-aligned; every line within 92 characters), read at
module load by CSV.jl with `stripwhitespace = true` into a named constant.

**`CALIBRATION_CSV` / `CALIBRATION`**: one measured solute per line, in three aligned tables
keyed by `id` (`CALIBRATION_CSV`: `id | charge | nconf | v_meas | fit | source`,
`CALIBRATION_NAMES_CSV`: `id | name`, `CALIBRATION_SMILES_CSV`: `id | smiles`; a SMILES
or a name is too long to share a line); `CALIBRATION` joins them into the rows
`id name smiles charge nconf v_meas provenance fit`. `source` is the DOI (`derived:DOI`,
`monomer:DOI`, or `unverified`), which becomes the provenance text. `v_meas` is the measured
PMV (cm3/mol, 25 C, infinite dilution) with its DOI in `source`; `nconf` is how many
conformers its RISM run should use; `fit = 1` puts the line into the group-correction fit,
`fit = 0` holds it out (the `holdout` report checks it against the model). It is the *only*
place the model learns from, so a wrong `v_meas` moves every estimate: change it by hand
in the source, then run `fit` again. The `id` (`K001`...) doubles as the RISM name.

**`RESULTS_CSV` / `RESULTS`**: the finished 3D-RISM runs the tool still reads, `name | n |
mean | sd` (`mean` is the raw RISM volume R of the conformer mean, `sd` the conformer
spread, `nan` for one conformer). It holds the 90 calibration solutes, the 105 runs behind
the `estimated` rows that `row` wrote (the `tables` check finds a row's run by n and mean)
and `TRIS0`, the anchor of the queue's bis-tris jobs: 196 runs. Runs nothing reads (the
runs of rows whose note is free text or anchored, superseded runs: OG, sucrose, R039 to
R041, LMNG, R045 to R078, A001 to A008) were dropped on 2026-11-19 together with the old data folder; a run made now lands in `<out>/results.tsv`, which is read on top
of the bundled runs (the last line of a name wins) and which `batch` resumes from. To keep
a new run, add its line to `RESULTS_CSV` by hand; a table row keeps its own numbers in its
note either way.

Typical questions:

| I want to | do this |
| --- | --- |
| see which calibration solutes or table rows still have no run | `bysl extract pmv --out DIR status` |
| refit the group correction after editing `CALIBRATION_CSV` or adding runs | `bysl extract pmv --out DIR fit` (writes `DIR/coefficients.json`) |
| know how good the fit is | `... diagnostics cv`, then `residuals` (a large `z` marks a solute the 11 groups cannot describe) |
| estimate a new compound | `run NAME SMILES NCONF CHARGE`, `fit` if needed, `estimate NAME SMILES` (section below) |
| check that the tables still agree with the runs | `... diagnostics tables` |
| try the tool without Amber or hours of compute | `bysl extract pmv --out DIR selftest` (seconds, synthetic) |
| test `run` on something tiny | `bysl extract pmv --out /tmp/o run K001 CCO 1 0` (ethanol, about 7 s) |

### Output folder

`--out DIR` is required (no default inside the repository) and holds everything the tool
generates: `DIR/work` (one folder per molecule and conformer, with the Amber files),
`DIR/results.tsv` (`name n mean sd buffer grid tolerance`, tab separated), `coefficients.json`
and `diagnostics/`. The global option goes BEFORE the subcommand. Deleting the folder loses
nothing but time (`fit` and `diagnostics all` rebuild their files).

### Install

- Julia only: the tool is the Julia package `Dev` (`dev/Project.toml`; CSV.jl reads the
  bundled tables, about 0.1 s to load). RDKit is RDKitMinimalLib.jl, which has no MMFF and
  no multi-conformer call, so the conformers of a run are ETKDG embeddings from several
  seeds (`seed`, `seed + 1`, ...), not force-field relaxed (random-coordinate fallback if
  an embedding fails).
- AmberTools (antechamber, parmchk2, tleap, `rism3d.snglpnt`, `cSPCE_kh.xvv`) stays an
  external install, default `~/.conda/envs/amber26` (set `AMBERHOME` otherwise):
  `conda create -n amber26 -c conda-forge ambertools`. Only `run` and `batch` need it.
- `selftest`, `diagnostics`, `status`, `fit`, `estimate`, `row` and `holdout` need no
  external program.
- Run 3D-RISM one job at a time on a quiet machine: it takes every core (about 3 min per
  conformer for a decyl-maltoside-sized molecule).

### Method

1. RDKit ETKDG conformers (one embedding per seed, no MMFF; random-coordinate fallback), antechamber
   AM1-BCC / GAFF2 charges, tleap.
2. `rism3d.snglpnt`, cSPC/E water, KH closure, buffer 25 A, grid 0.5 A, tolerance 1e-6,
   centering 2. PMV = `rism_partialMolarVolume` (A^3) x 0.602214076; the run's R is the
   conformer mean, its SD the conformer spread.
3. R is biased by chemical group. The correction `V - R = x . beta` has 11 features (SMARTS
   in `dev/src/pmv.jl`, module `Model`: CH3/CH2, CH/C, OH, ether O, carbonyl O, neutral N, aromatic C, charge, S,
   nitrile, rings), fitted on the measured solutes. Conjugate normal-inverse-gamma model:
   prior sd 5 per group, the CH2 term centred on 15.93 minus the RISM slope per CH2
   (n-alkanols of the set), sd 1.5, s ~ InvGamma(2, 2*3^2). A ridge fit (lambda 1e-3) is
   the sanity check. The features were fixed before the LOO error was looked at.
4. Direct estimate: `V = R + x . beta_mean`, sd = quadrature of the predictive sd, the
   conformer error of the mean (SD / sqrt n) and 2.0 for unmodelled chemistry, never below
   4.0. An anchored estimate `V = V_a + (R - R_a)` (anchor decyl maltoside) is reported for
   the held-out solutes only.

### Subcommands

    bysl extract pmv --out DIR run NAME SMILES NCONF CHARGE [--seed N]   one molecule -> results.tsv
    bysl extract pmv --out DIR batch FILE.tsv [--tier T ...] [--nice N]  rows id, smiles, charge, nconf [, tier];
                                                     skips ids already in the results
    bysl extract pmv --out DIR fit                                       DIR/coefficients.json, RMS numbers
    bysl extract pmv --out DIR holdout                                   held-out solutes (JSON)
    bysl extract pmv --out DIR estimate NAME SMILES                      V and sd of a finished run
    bysl extract pmv --out DIR row NAME SMILES COMMON IUPAC FORMULA CHARGE [--alias A ...] [--apply]
    bysl extract pmv selftest                                            synthetic checks, no RISM, seconds
    bysl extract pmv --out DIR status [--specs FILE]                     rows with no finished run
    bysl extract pmv --out DIR diagnostics REPORT [options]              read-only reports, below

`row` prints a polymers row (basis `estimated`, the note format below) and with `--apply`
appends it to `polymers.tsv`, `polymers.json` and `polymers_lookup.json` (idempotent; an
alias another lookup owns is skipped; aliases are never inferred: pass alpha-anomer
spellings with `--alias`). Measured values are never overwritten. Nonbiological rows are
written by hand in the same note format.

Diagnostics (each prints a table and writes `<out>/diagnostics/<report>.tsv`; they never
run RISM and never write outside `<out>`):

| report | content |
| --- | --- |
| `residuals` | per solute (worst LOO first: in-sample, LOO, ridge LOO, z, `!` for abs z above 2.5) and per group feature (n, mean/RMS residual) |
| `cv` | in-sample, LOO and repeated k-fold RMS, Bayesian and ridge (`--k 10 --repeats 20`) |
| `holdout` | the solutes with `fit = 0` against the model, direct and anchored |
| `conformers` | n, mean, SD and standard error of every run; flags single-conformer runs and SD above `--flag 1.0` |
| `coefficients` | prior, posterior mean and sd (Student-t marginal), shift in prior sds, ridge |
| `tables` | every `estimated` row of both tables against the runs; `--specs FILE` also recomputes the correction from the SMILES of a batch spec |
| `status` | calibration solutes, table rows (and `--specs` rows) with no run |
| `all` | all but `status`; exit status 1 if a table row is a MISMATCH or has no run |

`tables` statuses: OK (the raw value and conformer count of the row's note match a run, and
V = raw + correction and the sd reproduce from the note's numbers); MISMATCH (they do not,
or the correction drifted from the current model); `NO_RUN` (no run with that mean and n);
`FREE_TEXT` (the note is not the format `row` writes: a hand-derived or anchored row that no run
can reproduce, listed and not counted as failure). A row's run is found by value, not by
name, because the tables do not store the RISM name. On the tables of 2026-11-19: 105 OK,
49 FREE_TEXT.

The note of a `row` has the form `3D-RISM raw value R (SD s over n conformers) plus the Bayesian group correction c (predictive sd p); ...`; `tables` parses exactly this, so do
not reword it without changing `NOTE_RE` in `dev/src/pmv.jl`.

### The queue of missing solutes

`dev/data/pmv-queue.tsv` lists the solutes without a literature volume (`notes/solute-gaps.md`
ranks them): `id smiles charge nconf tier name anchor neededBy`. The first four columns
are the `batch` format, the others say what the job is for (`anchor` is the measured
solute the difference is read against, `neededBy` the fitting tests or buffer templates).
It stays a data file, not a constant (its lines are long and the job list is meant to be
edited), and `batch` takes its path as an argument, with no default: `bysl extract pmv
--out DIR batch dev/data/pmv-queue.tsv --nice 19` (`--tier 1 --tier 2` keeps those tiers;
no `--tier`: all). The rows go one at a time in file order, an id already in the results
(the bundled runs, or `DIR/results.tsv`) is skipped, so a stopped queue is started again
as it is, and a failed job is reported (`FAILED id`, exit status 1 at the end) while the
rest goes on (tier 1: the bis-tris propane species and the Tris anchors, done 2026-11-18;
2: the other template buffers; 3: further predicted solutes). Never start it beside a fit
or the unit suite. `test-solute-gaps.jl` keeps the table consistent (formal charge of each
SMILES, tier order, the columns batch reads); `dev/test/test-pmv.jl` tests the resume,
tier, failure and `--nice` behaviour of `batch` without AmberTools.

### Add a calibration solute

1. Append a line to each of the three calibration tables in `dev/src/pmv.jl` (`CALIBRATION_CSV`,
   `CALIBRATION_NAMES_CSV`, `CALIBRATION_SMILES_CSV`), padded to the column widths. Use the next free `K###` id, the measured PMV at 25 C and infinite dilution with
   its DOI in `source`, `fit = 1` (use `fit = 0` to hold it out of the fit).
2. `bysl extract pmv --out DIR run K091 SMILES NCONF CHARGE` (the id is the RISM name; 1 conformer for rigid
   molecules, 3 to 5 for flexible ones), then add its line to `RESULTS_CSV`.
3. `bysl extract pmv --out DIR fit`, then `diagnostics residuals` (a new solute with a large z is
   a sign of a missing group) and `diagnostics cv`.

### Estimate a new compound end to end

1. `bysl extract pmv --out DIR run NAME SMILES NCONF CHARGE` (charge of the species at the buffer pH, e.g. -1
   for a sulfonate; 6 to 10 conformers for flexible molecules, check `diagnostics conformers` afterwards).
2. `bysl extract pmv --out DIR fit` if `coefficients.json` is missing or the calibration changed.
3. `bysl extract pmv --out DIR estimate NAME SMILES` prints R, the correction and `V +- sd`.
4. `bysl extract pmv --out DIR row NAME SMILES COMMON IUPAC FORMULA CHARGE --alias ...` to look at the row,
   then again with `--apply` to write it. Put the run's numbers in the row's note (the note
   format above), and run `diagnostics tables` to confirm the row reproduces.

### Limits

- Monomer at infinite dilution, not micellar. Anions and zwitterions are erratic in raw
  3D-RISM and the correction absorbs only part of it (charged: 9 solutes, RMS LOO 6.8).
  Elements without GAFF2/AM1-BCC parameters (As) and salts have no run. Arsenic rows are
  the phosphorus analogue (P for As) plus a P to As step of +5.29, the measured arsenic
  acid (53.0) minus phosphoric acid (47.71), once per arsenic atom; the step is
  not checked for other molecules.
- 11 groups from 88 solutes: sparse groups (S, nitrile, 2 solutes each) have posterior
  sds near the prior; aromatic C has 5 solutes. Extrapolating beyond the calibration
  chemistry (large sugars, long surfactants) rests on additivity.
- Large flexible molecules (LMNG) may fail to embed; a random-coordinate fallback exists.
- Rows are matched to runs by value; a re-run with another seed changes the mean and the
  row reports `NO_RUN` until the row is regenerated.

## Requirements

`julia` (or `JULIA=/path/to/julia`) for everything. `bysl plots` needs a TeX Live installation (`lualatex` or `xelatex`, and `luaotfload-tool` for the fonts) and, for SVG, PNG and JPEG, poppler's `pdftocairo`. `bysl extract formfactor` runs in the root project, which has SQLite.jl.

## Reports

The run log (`test/fitting_tests/<ID>/<ID>.LOG`, one file per fitting-test folder, tracked in git, a section for each run) is the one file the tools read: flat tab-aligned `name<TAB>value` rows (the timing table as a person reads it, between `--- timing ---` and `--- machine ---`), see `BAYSOL.writeLog` and the Pipeline README. `src/report.jl` turns a section into the map of numbers every tool uses (`parse_log`); older revisions keep their results in `res*.txt` text reports (the timing table printed the stages of the static build in the order the pipeline recorded them, a stage's note in square brackets on the lines under it), which `parse_report` reads. No tool reads a workbook.


| Stage (depth 1 of the static build)                             | When                                                                                   | Note                                                                                                                                                                                                                         |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `resolveStruct`                                                 | always                                                                                 |                                                                                                                                                                                                                              |
| `components`                                                    | always: the component table load and the lookups (builtin table, cache, RCSB download) | `[17 residue names: 17 builtin, 0 cache, 0 download]`                                                                                                                                                                        |
| `structure checks`                                              | always                                                                                 | `[N chains relabelled, M duplicate atoms dropped, K dummy-like findings]`                                                                                                                                                    |
| `classify`                                                      | with hydrogens                                                                         | `[nucleic: AMBER, titration none]`, `[mixed: PARSE, titration propka]`, `[protein: PARSE, titration propka]`, then optional `; N legacy-named ...`, `; N chains relabelled`, `; N dummy-like residues (undefined behaviour)` |
| `propka`                                                        | protein-only and mixed inputs                                                          | `[cache hit]` / `[cache miss]`                                                                                                                                                                                               |
| `pdb2pqr`, `pdb2pqr (nucleic, none)`, `pdb2pqr (mixed, propka)` | one of the three per run (protein-only, nucleic-only, mixed)                           | `[cache hit]` / `[cache miss]`                                                                                                                                                                                               |
| `modified nucleotide hydrogens`                                 | only when the structure has modified nucleotides                                       | `[14 residues: 14 hydrogenated through their base, 0 without a base; 149 hydrogens placed, 232 in the free components' formulas]`                                                                                            |
| `modified amino acid hydrogens`                                 | only when the file has modified amino acids (HETATM, e.g. MSE), on every route         | `[20 residues: 20 hydrogenated through their parent, 0 without a parent; 183 hydrogens placed]`                                                                                                                              |
| `heavy atoms`                                                   | with hydrogens                                                                         | `[N in, N out; R restored, A added by pdb2pqr]`                                                                                                                                                                              |
| `loadMolecule`, `SASA`, ...                                     | always                                                                                 |                                                                                                                                                                                                                              |

How the tools read them (`src/report.jl`, by stage name over the `--- timing ---` block of the run log; a run that lacks a stage, or to which it did not apply, has `""` for it):

- **Keys.** Seconds: `:components`, `:struct_chk`, `:classify`, `:propka`, `:pdb2pqr`, `:moded_hyd` (nucleotides), `:modifiedAminoHydrogens`, `:heavy_atoms` (and the existing `:resolveStruct`, `:loadMolecule`, ...). `:pdb2pqr` is the `pdb2pqr*` stage of the run, whichever of the three variants it was (the patterns match on the prefix, like `propka*`); a run records exactly one. `:componentDownloads` is the `N` of the components note. The notes themselves are in the `stage_notes` of a run (a map from stage name to note; see `stage_notes` in `report.jl`), not among the ordered keys, so the TSV (`bysl results table --tsv`) and `--csv-all` outputs (numbers only) do not change shape.
- **Wall clock without external tools (`:wall_ex`, the convention of every comparison).** wall clock minus `:startup` (process start to `seedModel`) minus `:plot_timing` minus `:propka` minus `:pdb2pqr` (every `pdb2pqr*` stage) minus, only when `:componentDownloads` is above 0, the seconds of `components` (a download is network time, and the stage cannot separate it from the table load; a lookup that downloaded nothing is computing and stays in). Everything else (`classify`, `modified amino acid hydrogens`, `structure checks`, `heavy atoms`, `modified nucleotide hydrogens`, `resolveStruct`) is in-process work and stays in the wall clock. A stage a report lacks contributes nothing, so the 53 reports of the original suite give exactly the numbers they always gave.
- **`bysl results compare`.** The timing table has a row for each stage above (a stage no report of a column has shows `-`, not 0, and its ratio `n/a`; the `pdb2pqr (any variant)` row sums the variant of each run). Below it, the stage notes of the judged revision for every fit that is not a protein-only run with all caches hit (nucleic and mixed fits, a `cache miss`, a download), so the cache and the nucleotide counts behind a time are visible. `bysl results compare --bench` sums the stages by name prefix (`pdb2pqr` takes all three variants; the two `modified ... hydrogens` stages are separate prefixes) and shows a stage that a run did not have as `-`.
- **`profile-seed.jl`** (`bysl fits profile`) prints every static stage with its note.

## Sampler Diagnostics

`bysl fits diagnose` has three parts: `--residuals` (are the residuals at the MAP white) and two that answer "where do this fit's divergences and slow mixing come from?": `--report` (one NUTS chain started at the MAP, with the MAP search, the Hessian and the shape of the posterior around it) and `--chains` (the chains `runModel` actually runs, one line each: eight at the start, then up to a few more started at optima that carry mass; `--retry 1` shows the longer rerun `infer` does when R̂ is above 1.01). The output below is a real run on SASDX52 (16,882 atoms, `lMax` 38, 137 binned points), at the defaults of `runModel` (300 warm-up, 700 draws, target acceptance 95 %). It is cut into numbered blocks, each followed by what the block is for and how SASDX52 reads. Lines left out are marked `[…]`.

```bash
bysl fits diagnose --report SASDX52
bysl fits diagnose --chains --seeds 6252506411145483830 SASDX52
bysl fits diagnose --chains --retry 1 --seeds 6252506411145483830 SASDX52
```

`6252506411145483830` is the `rngSeed` row of the fit's own run log, so `--chains` replays that very run; without `--seeds` the seed is 7. The thread count does not change any number.

### Part 1: --report

**1. The fit.** What was loaded: the number of fitted points, atoms, `lMax`, the c1 tolerance, the support of the sampled contrasts, and the χ² of the deposited reference curve on our q set (a floor to compare the fit against).

```text
SASDX52   nQ=137  nAtoms=16882  lMax=38  c1 tol=1.0e-8
δρ₃ support = [-11.35, 2.839]   δρ₁,₂ support = [-10.0, 2.0]
reference curve on our q-set (n=409): χ²_red raw = 0.699, with free scale+offset = 0.701
```

**2. The MAP search and the NUTS run.** `nOk/nStarts` is how many of the L-BFGS starts made gave a result (64 random starts, then a second round of jittered starts around the optima of the first; block 5 lists the 64) and `nModes` how many distinct optima they found. The NUTS line is one chain started at the MAP: the step size ε before and after adaptation, the leapfrog steps and tree depth, and the number of divergent transitions. The window means show whether the trees grow or shrink during warm-up; acceptance should sit at the target (0.95) and `|ΔH|`, the energy error, should be small.

```text
MAP search: 0.1s  nOk=70/70  nModes=2  whitened=true
NUTS: 0.1s  init ε=1.6  final ε=0.4087  mean nSteps=11.8 mean depth=3.33  frac(depth≥10)=0.000  diverged=2
mean nSteps by window: [1:75]=12  [76:450]=12  [251:300]=10  [301:1000]=12
mean accept = 0.927   mean |ΔH| = 0.070
```

**3. Is the Laplace whitening right?** The sampler works in coordinates `w` where the posterior is meant to be a unit Gaussian. `sd` should be near 1 for every axis; the eigenvalues of the draws' covariance say the same without the axes; `skew` away from 0 means a lopsided direction; `ESS` is the effective sample size per axis. The last two lines compare log π at the optimizer's mode with the draws (for a 4-D Gaussian the median draw sits about 1.7 below the mode) and the sampled spread with the Laplace one in the optimizer's coordinates.

```text
post-warmup w: sd = [0.9863, 1.556, 2.145, 1.218]   (1 = the Laplace whitening is right)
  cov(w) eigenvalues = [0.9438, 0.98, 1.236, 6.32]   skew = [0.2042, -0.1343, 1.292, -0.2866]   ESS = [568.7, 44.39, 86.5, 209.9]
ℓπ at L-BFGS mode = 855.8603   best draw = 855.7956   median draw = 854.1010   (4-D Gaussian: median ≈ mode − 1.7)
sampled sd in z / Laplace σ_z = [0.9863, 1.083, 1.074, 2.047]
```

**4. How far each parameter is from its support bound.** In posterior standard deviations. A parameter within a few sd of a bound is cut by the prior's support and its posterior is not Gaussian there.

```text
coordinate   median ξ       sd ξ     distance to nearest support bound / sd
  ρₑ         0.34061    0.000194       1.76e+03
  δρ₁       -0.23194      0.0834           26.8
  δρ₂        -3.4491         1.1           4.97
  δρ₃         1.4416        2.13          0.657
```

**5. The 64 L-BFGS starts.** One line per start in the optimizer's coordinates: the final `f = −log π`, the iterations, whether it stopped on the gradient (`g_conv`) or on the iteration limit, how much the gradient changes between the working c1 tolerance and a much tighter one (a small value means the stop is not a gradient-error artefact) and c1 at the end. Starts that end on the same `f` found the same optimum.

```text
  start 1: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=0.00e+00 c1=1.0875
  start 2: f=-831.7659 iters=500 g_conv=false iter_limit=true |∇f(tol) − ∇f(ref)|∞=3.17e-04 c1=1.0875
  start 3: f=-855.8603 iters=117 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=5.91e-06 c1=1.2335
  start 4: f=-831.7659 iters=119 g_conv=true iter_limit=false |∇f(tol) − ∇f(ref)|∞=1.43e-04 c1=1.0875
  […]  (60 more lines, same format)
```

**6. The Hessian at the mode.** Eigenvalues of the second derivative of `f` in the optimizer's coordinates (floor 1.0). Pass 1 is the Hessian used for whitening; pass 2 repeats it at several finite-difference step sizes to show it is stable.

```text
MAP Hessian eigenvalues (floor 1.0): pass 1 = [0.6629, 3.194, 19.44, 1319]
  pass 2, step 0.30·σ_lap: [1, 2.967, 20.16, 1342]
  pass 2, step 0.10·σ_lap: [1, 2.957, 19.65, 1334]
  pass 2, step 0.03·σ_lap: [0.9999, 2.966, 19.57, 1332]
  pass 2, step 0.01·σ_lap: [1, 2.97, 19.54, 1330]
```

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

**8. The distinct optima.** Each optimum with its position ξ, the Hessian eigenvalues and its Laplace log-mass, `−f − ½ log det H`, and the difference from the best: a mode that merely exists is told from one that carries probability.

```text
distinct optima: 2
  mode 1: f=-855.860 ξ=[0.3406, -0.2077, -3.239, 1.172]  H-eig=[0.9999, 2.96, 19.16, 1332]  log Laplace mass=850.244 (Δ vs best = 0 nats)
  mode 2: f=-831.766 ξ=[0.3406, 0.753, 1.627, -5.62]  H-eig=[0.9955, 1.213, 3.198, 90.48]  log Laplace mass=828.838 (Δ vs best = -21.4 nats)
```

**9. Gradient error and the stable step size.** The first line is the error the c1 tolerance puts in the gradient NUTS uses, against the size of the gradient (error ≪ gradient means it is not the cause of trouble). The second is the largest curvature `λ_max` along the draws and the step size ε a leapfrog integrator is stable for at that curvature, against the ε the sampler adapted.

```text
gradient error from the c1 tolerance in w: min/median/max = [0, 6.698e-05, 0.001394]  vs |∇ℓπ| median = 1.63   (posterior-scale gradient ≈ 1)
local λ_max(−∇²ℓπ) min/median/max = [0.9999, 1.139, 63.91]  → stable ε < [0.2502, 1.874] (worst, median);  adapted ε = 0.4087
```

### Part 2: --chains

One line per chain of `infer`, the chains `runModel` pools, for the run with the run's own `rngSeed` (the `run` sheet). The first eight chains are fixed: two at the MAP and three mirrored pairs further out. Chains after the eighth are started at optima that the harvest of the first chains' draws found to carry mass (see below), and their `start σ` is the optimum's distance from the MAP. Columns: `start σ`, the distance of the chain's start from the MAP in posterior sd (negative is the mirrored chain of a pair); `mode`, the posterior mode it settled in; `pooled`; `kept`, its post-warm-up draws that the pool keeps (a chain in a mode with no mass keeps none); `div` and `div%`, divergent transitions among them; `warm-up div`, divergences during warm-up (not part of the posterior); `ε`, `steps` and `accept`, its mean step size, leapfrog steps and acceptance; `mean log π`. After the table, every divergent draw: chain, iteration, ξ = (ρₑ, δρ₁, δρ₂, δρ₃), log π against the chain's median, leapfrog steps and tree depth.

**10. The run `runModel` does** (300 warm-up, 700 draws):

```text
SASDX52: 10 chains, 300 warm-up + 700 draws, rngSeed 6252506411145483830, δ 95
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

**11. The retry** (`--retry 1`: 2000 warm-up, 2000 draws, seeds derived from the run's, as `infer` does when R̂ is above 1.01):

```text
SASDX52: 9 chains, 2000 warm-up + 2000 draws, rngSeed 6252506411145483830, δ 95
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

## Benchmarks: cold start and steady state

Performance claims in this repository are measured from a **cold state** and reported next to a **steady state**, so a speedup never comes from a cache that a user does not have on first use.

```bash
bysl fits bench --approved --state cold --out test/baselines/<name>.json SASDMJ9 `SASDTK5:fit3_model1` SASDN32
bysl results compare --bench new.json     # against the latest release's baseline
```

The cold state's temporary directory is deleted when the run ends (also on failure; the links to your depot are unlinked, never followed); `--keep` leaves it in place.

### What "cold" wipes

`bysl fits bench --state cold` never touches your real depot, cache or repository. It builds, in a temporary directory:


| wiped (absent in the cold state)                                                                                                               | kept (a user has it after installing)                                                                                |
| ------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| the Julia compiled caches (`compiled/`), so BAYSOL and its dependencies are precompiled for real                                               | package sources, artifacts, registries (`packages/`, `artifacts/`, `registries/`, `clones/`)                         |
| the cache (downloaded PDBs, `.pka` and protonated-PDB outputs; the cold state uses a cache folder of its own): propka and pdb2pqr run for real | the provisioned conda environment (`conda_environments/`): provisioning is a one-off network cost, not measured here |
| result files (`res*.xlsx`, figures; the run logs `*.LOG` are tracked), `docs/`, `sources/`, `manuscript/`, any local sysimage                  | tracked and untracked-unignored files of the working tree                                                            |

### What is reported

For each fit, in a fresh process (`child.jl` does the fit **twice** in one process):

- **install**: `Pkg.instantiate()` + `Pkg.precompile()` seconds (zero extra work in the warm state);
- **using BAYSOL**: loading the precompiled package;
- **first fit**: script prelude and `seedModel` (`seedS`), then `runModel` (`runS`), with the per-stage
  seconds, compile seconds and GC seconds from the pipeline's own `Timing` log;
- **steady fit**: the second fit, with everything already compiled.

Both fits run with the same pinned `rngSeed = 1` (`RNG_SEED` in `child.jl`; the JSON records it, and the number of chains), so a benchmark repeats the same work. A fresh seed each time does not: the MAP search can find a second optimum, which starts two extra chains and costs 60 to 90 % of `runModel` (on `SASDTK5:fit3_model1` about one seed in six). The same seed in two revisions is the same work only while the model inputs are the same: a change of the buffer table changes a prior, and so the starting points. Check `nChains` in both results before reading a difference as speed. `--threads N` sets `JULIA_NUM_THREADS` for the measured process (the v0.3.0 baseline was 4).

Keep the two apart: first-fit minus steady-fit is compilation, and PrecompileTools-style work trades first-fit time for install time, so both rows must be compared. Never quote a warm-state number as what a user gets. The report convention of the fitting tests (wall clock excluding propka, every pdb2pqr stage and a component download; see the stage section above) is unchanged; in the cold state those stages run for real and appear as their own rows.

### Rules

- **Benchmarks are only run with the repository owner's explicit approval, per run, because they need a quiet machine.** `bysl fits bench` prints its plan unless `--approved` is passed, and `--approved` is added only after the owner has said yes to this run (a safeguard against careless runs, not a security measure).
- One process at a time, a quiet machine (for example: check for `DisplayLinkManager` and `baloo` CPU use first), no parallel runs.
- Compare like with like: a cold run against a cold run of an earlier commit (use `git worktree`/`git stash` to build the earlier tree), never against warm numbers or the committed run logs (`*.LOG`) timings, which are warm-cache.
- [`../test/baselines/`](../test/baselines/README.md) holds the machine-specific reference run of each release (the default for `bysl results compare --bench` is the latest release's; host and CPU are recorded in `meta`); compare only within a host.
