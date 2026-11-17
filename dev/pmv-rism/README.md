npm

# pmv-rism: partial molar volumes by 3D-RISM

Reconstructs the partial molar volume (PMV, cm3/mol) of a solute that has no measurement,
for the `estimated` rows of the bulk-electron-density tables
(`src/bulk-electron-density/polymers/` and `non-biological/`). The tools: a 3D-RISM
driver, a Bayesian group correction fitted to measured solutes (`data/calibration.tsv`),
and read-only diagnostics. A future developer should be able to redo any estimate, or
add a new one, from this folder alone.

    dev/src/pmv.jl       the tool (module `Pmv`, run as `bysl extract pmv SUBCOMMAND ...`)
    data/calibration.tsv the measured solutes
    data/results.tsv     the finished 3D-RISM runs (name n mean sd buffer grid tolerance)
    out/  work/          generated scratch, gitignored, created on demand (see "Using the data")

## Using the data

Nothing here is read at fit time: BAYSOL itself only reads the finished tables under
`src/bulk-electron-density/`. This folder is the workshop that produces their `estimated`
rows, and the two data files are the inputs of every command. Run everything from the
repository root through `bysl extract pmv ...`.

**`data/calibration.tsv`**: one measured solute per line, tab separated:
`id  name  smiles  charge  nconf  v_meas  provenance  fit`. `v_meas` is the measured PMV
(cm3/mol, 25 C, infinite dilution) with its DOI in `provenance`; `nconf` is how many
conformers its RISM run should use; `fit = 1` puts the line into the group-correction fit,
`fit = 0` holds it out (the `holdout` report checks it against the model). It is the *only*
place the model learns from, so a wrong `v_meas` here moves every estimate: change it by
hand, then run `fit` again. The `id` (`K001`...) doubles as the RISM name in `results.tsv`.

**`data/results.tsv`**: one finished 3D-RISM run per line, `name  n  mean  sd  buffer  grid tolerance`, written by `run` and `batch` (never edit it; the last line of a name wins, so a
re-run supersedes an old one). `mean` is the raw RISM volume R of the conformer mean,
`sd` the conformer spread (`nan` for one conformer). It is the record of hours of compute:
keep it, and `git add` new lines. A calibration line only enters the fit once its `id`
has a run here.

Typical questions:


| I want to                                                                 | do this                                                                                                                                                                                                            |
| --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| see which calibration solutes or table rows still have no run             | `bysl extract pmv status`                                                                                                                                                                                          |
| refit the group correction after editing `calibration.tsv` or adding runs | `bysl extract pmv fit` (writes `out/coefficients.json`)                                                                                                                                                            |
| know how good the fit is                                                  | `bysl extract pmv diagnostics cv`, then `residuals` (a large `z` marks a solute the 11 groups cannot describe)                                                                                                     |
| estimate a new compound                                                   | `run NAME SMILES NCONF CHARGE`, `fit` if needed, `estimate NAME SMILES` (section below)                                                                                                                            |
| check that the tables still agree with the runs                           | `bysl extract pmv diagnostics tables`                                                                                                                                                                              |
| try the tool without Amber or hours of compute                            | `bysl extract pmv selftest` (seconds, synthetic)                                                                                                                                                                   |
| test `run` on something tiny                                              | `bysl extract pmv --results /tmp/r.tsv --work /tmp/w --out /tmp/o run K001 CCO 1 0` (ethanol, about 7 s; the global options go BEFORE `run`, otherwise they are ignored and the real `results.tsv` is appended to) |

`out/` and `work/` are scratch: deleting them loses nothing but time (`fit` and
`diagnostics all` rebuild `out/`; `work/` holds the Amber files of each conformer).

## Install

- Julia only: the tool is the Julia package `Dev` (`dev/Project.toml`). RDKit is
  RDKitMinimalLib.jl, which has no MMFF and no multi-conformer call, so the conformers of
  a run are ETKDG embeddings from several seeds (`seed`, `seed + 1`, ...), not
  force-field relaxed (random-coordinate fallback if an embedding fails).
- AmberTools (antechamber, parmchk2, tleap, `rism3d.snglpnt`, `cSPCE_kh.xvv`) stays an
  external install, default `~/.conda/envs/amber26` (set `AMBERHOME` otherwise):
  `conda create -n amber26 -c conda-forge ambertools`. Only `run` and `batch` need it.
- `selftest`, `diagnostics`, `status`, `fit`, `estimate`, `row` and `holdout` need no
  external program.
- Run 3D-RISM one job at a time on a quiet machine: it takes every core (about 3 min per
  conformer for a decyl-maltoside-sized molecule).

## Settings (environment or global options before the subcommand)


| env           | option           | default                                                           |
| --------------- | ------------------ | ------------------------------------------------------------------- |
| `PMV_OUT`     | `--out DIR`      | `dev/pmv-rism/out` (coefficients, diagnostics; created on demand) |
| `PMV_RESULTS` | `--results FILE` | `data/results.tsv` (tracked: the finished runs)                   |
| `PMV_WORK`    | `--work DIR`     | `dev/pmv-rism/work` (one folder per molecule, per conformer)      |
| `AMBERHOME`   |                  | `~/.conda/envs/amber26`                                           |

`results.tsv` has one line per finished run: `name n mean sd buffer grid tolerance`
(tab separated; the last line of a name wins). Every command reads it from the place above.

## Method

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

## Subcommands

    bysl extract pmv run NAME SMILES NCONF CHARGE [--seed N]   one molecule -> results.tsv
    bysl extract pmv batch FILE.tsv [--tier T]                 rows id, smiles, charge, nconf [, tier];
                                                     skips ids already in results.tsv
    bysl extract pmv fit                                       <out></out>/coefficients.json, RMS numbers
    bysl extract pmv holdout                                   held-out solutes (JSON)
    bysl extract pmv estimate NAME SMILES                      V and sd of a finished run
    bysl extract pmv row NAME SMILES COMMON IUPAC FORMULA CHARGE [--alias A ...] [--apply]
    bysl extract pmv selftest                                  synthetic checks, no RISM, seconds
    bysl extract pmv status [--specs FILE]                     rows with no finished run
    bysl extract pmv diagnostics REPORT [options]              read-only reports, below

`row` prints a polymers row (basis `estimated`, the note format below) and with `--apply`
appends it to `polymers.tsv`, `polymers.json` and `polymers_lookup.json` (idempotent; an
alias another lookup owns is skipped; aliases are never inferred: pass alpha-anomer
spellings with `--alias`). Measured values are never overwritten.

Diagnostics (each prints a table and writes `<out>/diagnostics/<report>.tsv`; they never
run RISM and never write outside `<out>`):


| report         | content                                                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `residuals`    | per solute (worst LOO first: in-sample, LOO, ridge LOO, z, `!` for abs z above 2.5) and per group feature (n, mean/RMS residual)          |
| `cv`           | in-sample, LOO and repeated k-fold RMS, Bayesian and ridge (`--k 10 --repeats 20`)                                                        |
| `holdout`      | the solutes with `fit = 0` against the model, direct and anchored                                                                         |
| `conformers`   | n, mean, SD and standard error of every run; flags single-conformer runs and SD above `--flag 1.0`                                        |
| `coefficients` | prior, posterior mean and sd (Student-t marginal), shift in prior sds, ridge                                                              |
| `tables`       | every `estimated` row of both tables against `results.tsv`; `--specs FILE` also recomputes the correction from the SMILES of a batch spec |
| `status`       | calibration solutes, table rows (and `--specs` rows) with no run                                                                          |
| `all`          | all but `status`; exit status 1 if a table row is a MISMATCH or has no run                                                                |

`tables` statuses: OK (the raw value and conformer count of the row's note match a run, and
V = raw + correction and the sd reproduce from the note's numbers); MISMATCH (they do not,
or the correction drifted from the current model); NO_RUN (no run with that mean and n);
FREE_TEXT (the note is not the format `row` writes: a hand-derived or anchored row that no run
can reproduce, listed and not counted as failure). A row's run is found by value, not by
name, because the tables do not store the RISM name.

The note of a `row` has the form `3D-RISM raw value R (SD s over n conformers) plus the Bayesian group correction c (predictive sd p); ...`; `tables` parses exactly this, so do
not reword it without changing `NOTE_RE` in `dev/src/pmv.jl`.

## Add a calibration solute

1. Append a line to `data/calibration.tsv`: `id name smiles charge nconf v_meas provenance fit`. Use the next free `K###` id, the measured PMV at 25 C and infinite dilution with
   its DOI in `provenance`, `fit = 1` (use `fit = 0` to hold it out of the fit).
2. `bysl extract pmv run K091 SMILES NCONF CHARGE` (the id is the RISM name; 1 conformer for rigid
   molecules, 3 to 5 for flexible ones).
3. `bysl extract pmv fit`, then `bysl extract pmv diagnostics residuals` (a new solute with a large z is
   a sign of a missing group) and `diagnostics cv`. Update the numbers below.

## Estimate a new compound end to end

1. `bysl extract pmv run NAME SMILES NCONF CHARGE` (charge of the species at the buffer pH, e.g. -1
   for a sulfonate; 6 to 10 conformers for flexible molecules, check `diagnostics conformers` afterwards).
2. `bysl extract pmv fit` if `coefficients.json` is missing or the calibration changed.
3. `bysl extract pmv estimate NAME SMILES` prints R, the correction and `V +- sd`.
4. `bysl extract pmv row NAME SMILES COMMON IUPAC FORMULA CHARGE --alias ...` to look at the row,
   then again with `--apply` to write it. Run `bysl extract pmv diagnostics tables` to confirm the
   row reproduces. Non-polymer rows of `nonbiological.tsv` are written by hand in the same
   note format.

## Validation (88 calibration solutes, 161 runs in the last harvest)


| quantity                | Bayesian | ridge |
| ------------------------- | ---------- | ------- |
| in-sample RMS           | 2.96     | 2.96  |
| leave-one-out RMS       | 3.52     | 3.53  |
| 10-fold RMS (20 splits) | 3.58     | 3.59  |

The worst solutes are betaine (LOO +17.9), 2-phenoxyethanol (+12.8), 18-crown-6 and
phenyl glucoside (about -9): zwitterions, aromatic ethers and crown ethers are poorly
described by 11 groups. Held out: octyl glucoside +4.2, sucrose +1.0 (direct model);
decyl maltoside direct 380.5 +- 4.3 against the measured-table 373.3 +- 3.9 (+7.2, about
1.3 sd). Of the table's `estimated` rows 103 reproduce from runs, 43 are free text and 7 are MISMATCH (working tree of 2026-11-15).
Regenerate with `bysl extract pmv fit` and `bysl extract pmv diagnostics all`. The Julia port reproduces the earlier Python numbers to 1e-6 relative (`dev/test/test-pmv.jl`).

## Limits

- The earlier +5.6 group correction (72 solutes, scripts lost) cannot be re-derived; the
  current fit replaces it, so decyl maltoside moved from 373.3 to 380.5 in the model value.
- Monomer at infinite dilution, not micellar. Anions and zwitterions are erratic in raw
  3D-RISM and the correction absorbs only part of it (charged: 9 solutes, RMS LOO 6.8).
  Elements without GAFF2/AM1-BCC parameters (As) and salts have no run. Arsenic rows are
  the phosphorus analogue (P for As) plus a P to As step of +5.29, the measured arsenic
  acid (53.0) minus phosphoric acid (47.71), once per arsenic atom; the step is
  unvalidated for other molecules.
- 11 groups from 88 solutes: sparse groups (S, nitrile, 2 solutes each) have posterior
  sds near the prior; aromatic C has 5 solutes. Extrapolating beyond the calibration
  chemistry (large sugars, long surfactants) rests on additivity.
- Large flexible molecules (LMNG) may fail to embed; a random-coordinate fallback exists
  but that run was never repeated.
- Rows are matched to runs by value; a re-run with another seed changes the mean and the
  row reports NO_RUN until the row is regenerated.
