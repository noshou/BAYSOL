# pmv-rism: partial molar volumes by 3D-RISM

Reconstructs the partial molar volume (PMV, cm3/mol) of a solute that has no measurement,
for the `estimated` rows of the bulk-electron-density tables
(`src/bulk-electron-density/polymers/` and `non-biological/`). The tools: a 3D-RISM
driver, a Bayesian group correction fitted to measured solutes (`data/calibration.tsv`),
and read-only diagnostics. A future developer should be able to redo any estimate, or
add a new one, from this folder alone.

    pmv.py               entry point (also `bysl extract pmv SUBCOMMAND ...`)
    pmvlib/              config, tables, model, rows, rism, diagnostics, selftest
    data/calibration.tsv the measured solutes (the only tracked data)
    out/  work/          generated, gitignored, created on demand

## Install

- AmberTools (antechamber, parmchk2, tleap, `rism3d.snglpnt`, `cSPCE_kh.xvv`) and RDKit
  in one conda environment, default `~/.conda/envs/amber26` (set `AMBERHOME` otherwise):
  `conda create -n amber26 -c conda-forge ambertools rdkit numpy`. Run `pmv.py` with that
  environment's Python (`bysl extract pmv` does).
- `selftest`, `diagnostics`, `status` and `fit` need only numpy and RDKit (the selftest
  skips the RDKit check without it); only `run` and `batch` need AmberTools.
- Run 3D-RISM one job at a time on a quiet machine: it takes every core (about 3 min per
  conformer for a decyl-maltoside-sized molecule).

## Settings (environment or global options before the subcommand)

| env | option | default |
|---|---|---|
| `PMV_OUT` | `--out DIR` | `dev/pmv-rism/out` (coefficients, diagnostics; created on demand) |
| `PMV_RESULTS` | `--results FILE` | `<out>/results.tsv` (no symlink needed) |
| `PMV_WORK` | `--work DIR` | `dev/pmv-rism/work` (one folder per molecule, per conformer) |
| `AMBERHOME` | | `~/.conda/envs/amber26` |

`results.tsv` has one line per finished run: `name n mean sd buffer grid tolerance`
(tab separated; the last line of a name wins). Every command reads it from the place above.

## Method

1. RDKit ETKDG conformers (MMFF-relaxed; random-coordinate fallback), antechamber
   AM1-BCC / GAFF2 charges, tleap.
2. `rism3d.snglpnt`, cSPC/E water, KH closure, buffer 25 A, grid 0.5 A, tolerance 1e-6,
   centering 2. PMV = `rism_partialMolarVolume` (A^3) x 0.602214076; the run's R is the
   conformer mean, its SD the conformer spread.
3. R is biased by chemical group. The correction `V - R = x . beta` has 11 features (SMARTS
   in `model.py`: CH3/CH2, CH/C, OH, ether O, carbonyl O, neutral N, aromatic C, charge, S,
   nitrile, rings), fitted on the measured solutes. Conjugate normal-inverse-gamma model:
   prior sd 5 per group, the CH2 term centred on 15.93 minus the RISM slope per CH2
   (n-alkanols of the set), sd 1.5, s ~ InvGamma(2, 2*3^2). A ridge fit (lambda 1e-3) is
   the sanity check. The features were fixed before the LOO error was looked at.
4. Direct estimate: `V = R + x . beta_mean`, sd = quadrature of the predictive sd, the
   conformer error of the mean (SD / sqrt n) and 2.0 for unmodelled chemistry, never below
   4.0. An anchored estimate `V = V_a + (R - R_a)` (anchor decyl maltoside) is reported for
   the held-out solutes only.

## Subcommands

    pmv.py run NAME SMILES NCONF CHARGE [--seed N]   one molecule -> results.tsv
    pmv.py batch FILE.tsv [--tier T]                 rows id, smiles, charge, nconf [, tier];
                                                     skips ids already in results.tsv
    pmv.py fit                                       <out>/coefficients.json, RMS numbers
    pmv.py holdout                                   held-out solutes (JSON)
    pmv.py estimate NAME SMILES                      V and sd of a finished run
    pmv.py row NAME SMILES COMMON IUPAC FORMULA CHARGE [--alias A ...] [--apply]
    pmv.py selftest                                  synthetic checks, no RISM, seconds
    pmv.py status [--specs FILE]                     rows with no finished run
    pmv.py diagnostics REPORT [options]              read-only reports, below

`row` prints a polymers row (basis `estimated`, the note format below) and with `--apply`
appends it to `polymers.tsv`, `polymers.json` and `polymers_lookup.json` (idempotent; an
alias another lookup owns is skipped; aliases are never inferred: pass alpha-anomer
spellings with `--alias`). Measured values are never overwritten.

Diagnostics (each prints a table and writes `<out>/diagnostics/<report>.tsv`; they never
run RISM and never write outside `<out>`):

| report | content |
|---|---|
| `residuals` | per solute (worst LOO first: in-sample, LOO, ridge LOO, z, `!` for abs z above 2.5) and per group feature (n, mean/RMS residual) |
| `cv` | in-sample, LOO and repeated k-fold RMS, Bayesian and ridge (`--k 10 --repeats 20`) |
| `holdout` | the solutes with `fit = 0` against the model, direct and anchored |
| `conformers` | n, mean, SD and standard error of every run; flags single-conformer runs and SD above `--flag 1.0` |
| `coefficients` | prior, posterior mean and sd (Student-t marginal), shift in prior sds, ridge |
| `tables` | every `estimated` row of both tables against `results.tsv`; `--specs FILE` also recomputes the correction from the SMILES of a batch spec |
| `status` | calibration solutes, table rows (and `--specs` rows) with no run |
| `all` | all but `status`; exit status 1 if a table row is a MISMATCH or has no run |

`tables` statuses: OK (the raw value and conformer count of the row's note match a run, and
V = raw + correction and the sd reproduce from the note's numbers); MISMATCH (they do not,
or the correction drifted from the current model); NO_RUN (no run with that mean and n);
FREE_TEXT (the note is not the pmv.py format: a hand-derived or anchored row that no run
can reproduce, listed and not counted as failure). A row's run is found by value, not by
name, because the tables do not store the RISM name.

The note of a `row` has the form `3D-RISM raw value R (SD s over n conformers) plus the
Bayesian group correction c (predictive sd p); ...`; `tables` parses exactly this, so do
not reword it without changing `NOTE_RE` in `pmvlib/diagnostics.py`.

## Add a calibration solute

1. Append a line to `data/calibration.tsv`: `id name smiles charge nconf v_meas provenance
   fit`. Use the next free `K###` id, the measured PMV at 25 C and infinite dilution with
   its DOI in `provenance`, `fit = 1` (use `fit = 0` to hold it out of the fit).
2. `pmv.py run K091 SMILES NCONF CHARGE` (the id is the RISM name; 1 conformer for rigid
   molecules, 3 to 5 for flexible ones).
3. `pmv.py fit`, then `pmv.py diagnostics residuals` (a new solute with a large z is
   a sign of a missing group) and `diagnostics cv`. Update the numbers below.

## Estimate a new compound end to end

1. `pmv.py run NAME SMILES NCONF CHARGE` (charge of the species at the buffer pH, e.g. -1
   for a sulfonate; 6 to 10 conformers for flexible molecules, check `diagnostics
   conformers` afterwards).
2. `pmv.py fit` if `coefficients.json` is missing or the calibration changed.
3. `pmv.py estimate NAME SMILES` prints R, the correction and `V +- sd`.
4. `pmv.py row NAME SMILES COMMON IUPAC FORMULA CHARGE --alias ...` to look at the row,
   then again with `--apply` to write it. Run `pmv.py diagnostics tables` to confirm the
   row reproduces. Non-polymer rows of `nonbiological.tsv` are written by hand in the same
   note format.

## Validation (88 calibration solutes, 161 runs in the last harvest)

| quantity | Bayesian | ridge |
|---|---|---|
| in-sample RMS | 2.96 | 2.96 |
| leave-one-out RMS | 3.52 | 3.53 |
| 10-fold RMS (20 splits) | 3.58 | 3.59 |

The worst solutes are betaine (LOO +17.9), 2-phenoxyethanol (+12.8), 18-crown-6 and
phenyl glucoside (about -9): zwitterions, aromatic ethers and crown ethers are poorly
described by 11 groups. Held out: octyl glucoside +4.2, sucrose +1.0 (direct model);
decyl maltoside direct 380.5 +- 4.3 against the measured-table 373.3 +- 3.9 (+7.2, about
1.3 sd). Of the table's `estimated` rows 66 reproduce from runs and 87 are free text.
Regenerate with `pmv.py fit` and `pmv.py diagnostics all`.

## Limits

- The earlier +5.6 group correction (72 solutes, scripts lost) cannot be re-derived; the
  current fit replaces it, so decyl maltoside moved from 373.3 to 380.5 in the model value.
- Monomer at infinite dilution, not micellar. Anions and zwitterions are erratic in raw
  3D-RISM and the correction absorbs only part of it (charged: 9 solutes, RMS LOO 6.8).
  Elements without GAFF2/AM1-BCC parameters (As) and salts have no run.
- 11 groups from 88 solutes: sparse groups (S, nitrile, 2 solutes each) have posterior
  sds near the prior; aromatic C has 5 solutes. Extrapolating beyond the calibration
  chemistry (large sugars, long surfactants) rests on additivity.
- Large flexible molecules (LMNG) may fail to embed; a random-coordinate fallback exists
  but that run was never repeated.
- Rows are matched to runs by value; a re-run with another seed changes the mean and the
  row reports NO_RUN until the row is regenerated.
