# utils

Shared helpers behind the tests: glue around the Julia package (reading reports, driving benchmark processes, inspecting a fit's sampler, regenerating a data file) and the two helper files the unit tests include.


| Script                   | What it does                                                                                                                                                                                                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compare.tcl`            | Compares fitting-test results (`test/fitting_tests/*/res*.txt`) between git revisions and the working tree: timing totals, χ² and parameter distributions, the fits with the deepest NUTS trees, optional per-fit CSV. With `--bench`, compares benchmark JSON files instead. The default baseline is the latest release (newest `v<digit>` tag). |
| `results_table.tcl`      | Generates the Results table of`test/fitting_tests/README.md` from the reports (`--update` rewrites it in place, `--check` exits 1 if it is stale). Only the depositor's χ² column is kept by hand, in `test/fitting_tests/depositor_chi2.tsv`.                                                                    |
| `bench.tcl`              | The cold / steady-state benchmark driver (protocol below). Prepares a throwaway depot and repository copy (deleted afterwards, unless `--keep`), starts`child.jl` once per fit and writes one JSON result (to `test/baselines/results/` by default). **Only runs with `--approved`**, which must be passed only after the owner has approved that particular run. |
| `diagnose.tcl`           | Command line for the sampler diagnostics on a fitting test, one part per call: `--report` (MAP starts, Hessian, step size and depth, gradient error, modes), `--ablate` (χ² with one shared shell contrast, with δρ₁=δρ₂, and the full model), `--residuals` (are the residuals at the MAP white), `--warmup` (how short can the warm-up be and how many draws are enough), `--tolerance` (is the c1 tolerance tight enough); `--list` shows the fits and tags. Checks the arguments, then starts `diagnose.jl`. `test/run/diagnose.tcl` runs several parts (all by default). |
| `extract_formfactor.tcl` | Rebuilds`src/Scattering/form_factors.sqlite3` from xraydb's `xraydb.sqlite` (Waasmaier-Kirfel f0 and Chantler f1/f2). Offline; the result is checked in.                                                                                                                          |
| `common.tcl`             | Shared by the Tcl scripts, not run: the repository root, the report-number regex,`usage`, the git / file helpers, `latest_release` / `baseline_for` and the symlink-safe `rm_tree`.                                                                                                                                                             |
| `report.tcl`             | Parses one fitting-test report (`res*.txt`) into a dict of numbers; used by `compare.tcl` and `results_table.tcl`.                                                                                                                                                                |
| `child.jl`               | The process`bench.tcl` measures: runs one fit twice in a fresh process and prints the timings as JSON, with the `run_model` defaults of the code it measures unless `--samples`/`--adapt` are given, and records the iterations used. Not run by hand.                                                                                                                                                           |
| `diagnose.jl`            | The Julia side of `diagnose.tcl`: loads the fit's `Seed` and runs the chosen diagnostic.                                                                                                                                                                                           |
| `fit_seed.jl`            | `load_fit_seed(id, tag; seed_options)`: the `Seed` a fitting test would sample, built without fitting (`seed_options` adds keywords such as `rebin` to its `seed_model` call). Used by `diagnose.jl`, `child.jl` and the validations in `../validation/`.                                    |
| `seed_diagnostics.jl`    | The diagnostics themselves (generic over any`Fitting.Seed`); covered by `test/unit_tests/units/test_seed_diagnostics.jl`.                                                                                                                                                         |
| `tests/`                 | The tcltest files for the Tcl scripts above (`*.test`, `helpers.tcl`, `data/`); run by `test/run/tcltests.tcl`.                                                                                                                                                                   |
| `profile_seed.jl`        | The Julia side of `test/run/profile.tcl`: profiles the second build of a fitting test's `Seed` and prints the samples by BAYSOL function.                                                                                                                  |
| `floatcompare.jl`        | `close_(a, b; atol)`: float comparison with an explicit per-call absolute tolerance. Included by the unit tests.                                                                                                                                                                  |
| `geometry.jl`            | Synthetic point-cloud geometry (`sph`, the witness lattice, the surface-atom cases). Included by `test_sasa.jl`.                                                                                                                                                                  |

```bash
tclsh test/utils/compare.tcl v0.2.0-soukouratou HEAD          # any revisions; the working tree is added last
tclsh test/utils/compare.tcl HEAD~2 HEAD --no-tree --csv out.csv
tclsh test/utils/compare.tcl --bench new.json                 # against the latest release's baseline in test/baselines/
tclsh test/utils/compare.tcl --bench baseline.json new.json
tclsh test/utils/results_table.tcl --update       # regenerate the Results table in test/fitting_tests/README.md
tclsh test/utils/results_table.tcl --check        # exit 1 if that table is stale
tclsh test/utils/diagnose.tcl --list
tclsh test/utils/diagnose.tcl --report SASDBS6:fit2_model3    # one diagnostic part; test/run/diagnose.tcl runs several
tclsh test/utils/bench.tcl --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3
tclsh test/utils/extract_formfactor.tcl xraydb.sqlite src/Scattering/form_factors.sqlite3
```

Every Tcl script prints its usage with `--help`. They start with `#!/usr/bin/env tclsh`, so they can also be
run directly (`./test/utils/compare.tcl …`).

## Requirements

Tcl 9 with Tcllib (`json`, `json::write`) for `compare.tcl` and `bench.tcl`, and the `sqlite3` package for
`extract_formfactor.tcl`. On Fedora: `dnf install tcl tcllib sqlite-tcl`. `bench.tcl` and `diagnose.tcl`
also need `julia` on the `PATH` (or `JULIA=/path/to/julia`).

## Benchmarks: cold start and steady state

Performance claims in this repository are measured from a **cold state** and reported next to a **steady state**, so a speedup never comes from a cache that a user does not have on first use.

```bash
tclsh test/utils/bench.tcl --approved --state cold --out test/baselines/<name>.json SASDMJ9 SASDBS6:fit2_model3 SASDJ62
tclsh test/utils/compare.tcl --bench new.json     # against the latest release's baseline
```

The cold state's temporary directory is deleted when the run ends (also on failure; the links to your depot are unlinked, never followed); `--keep` leaves it in place.

### What "cold" wipes

`bench.tcl --state cold` never touches your real depot or repository. It builds, in a temporary directory:


| wiped (absent in the cold state)                                                                 | kept (a user has it after installing)                                                                                |
| -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| the Julia compiled caches (`compiled/`), so BAYSOL and its dependencies are precompiled for real | package sources, artifacts, registries (`packages/`, `artifacts/`, `registries/`, `clones/`)                         |
| `_cache/` (downloaded PDBs, `.pka` and protonated-PDB outputs): propka and pdb2pqr run for real  | the provisioned conda environment (`conda_environments/`): provisioning is a one-off network cost, not measured here |
| result files (`res*.txt`, figures), `docs/`, `sources/`, `manuscript/`, any local sysimage       | tracked and untracked-unignored files of the working tree                                                            |

### What is reported

For each fit, in a fresh process (`child.jl` does the fit **twice** in one process):

- **install**: `Pkg.instantiate()` + `Pkg.precompile()` seconds (zero extra work in the warm state);
- **using BAYSOL**: loading the precompiled package;
- **first fit**: script prelude and `seed_model` (`seed_s`), then `run_model` (`run_s`), with the per-stage
  seconds, compile seconds and GC seconds from the pipeline's own `Timing` log;
- **steady fit**: the second fit, with everything already compiled.

Keep the two apart: first-fit minus steady-fit is compilation, and PrecompileTools-style work trades first-fit time for install time, so both rows must be compared. Never quote a warm-state number as what a user gets. The report convention of the fitting tests (wall clock excluding propka and pdb2pqr) is unchanged; in the cold state those stages run for real and appear as their own rows.

### Rules

- **Benchmarks are only run with the repository owner's explicit approval, per run, because they need a quiet machine.** Timings are only meaningful when nothing else is using the CPU, and AI agents tend to start a benchmark without checking whether the machine is quiet. `bench.tcl` therefore does nothing but print its plan unless `--approved` is passed, and `--approved` is added only after the owner has said yes to this run, which means they have confirmed the machine is quiet. It is a small safeguard against careless runs, not a security measure.
- One process at a time, a quiet machine (for example: check for `DisplayLinkManager` and `baloo` CPU use first), no parallel runs.
- Compare like with like: a cold run against a cold run of an earlier commit (use `git worktree`/`git stash` to build the earlier tree), never against warm numbers or the committed `res*.txt` timings, which are warm-cache.
- [`../baselines/`](../baselines/README.md) holds the machine-specific reference run of each release (the default for `compare.tcl --bench` is that of the latest release) (host and CPU are recorded in `meta`); compare only within a host.
