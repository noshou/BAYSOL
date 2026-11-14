# Legacy helpers of the first 3D-RISM estimates (recovered copies)

Plain, unmodified copies (no SPDX header, long lines, hard-coded `~/pmv_work/...` paths: they
are records, not tools) of three scripts of the 2026-10-22 gap-filling session, recovered from
the editor's file history (`~/.claude/file-history/70c3ad07-847f-4f6f-86b3-cd2811db629e/`,
snapshot `@v2`; the originals stay there). The folder `~/pmv_work/` they ran in no longer exists.

| file here           | snapshot id        | what it did |
|---------------------|--------------------|-------------|
| `rows_from_rism.py` | `da22d4338c7bb64c` | turned 3D-RISM runs plus table anchors into candidate rows (`V = R_mean + correction`, or anchored `V = V_anchor + (R_t - R_a) + (corr_t - corr_a)`), with the uncertainty terms (seed sd, class sigma 3.5 direct or 2.0 anchored, fit variance, anchor sd, extra term per unmodelled chemistry) |
| `specs.py`          | `b621031ede4a32ee` | the list of every candidate row of that batch (Good-buffer anions anchored on the zwitterion, salts, DPC, ...), with names, notes and aliases |
| `apply_rism4.py`    | `259dab9765937226` | wrote the rows into `NonBiological/` and `Polymers/` (tsv, json, lookup), with backups |

## What cannot be reproduced

These scripts import modules that were NOT recovered:

- `model2.py` and `final.py` of `~/pmv_work/rism2/` (the group-wise ridge model: 72 solutes,
  lambda 1e-3, leave-one-out RMS 3.5; `rows_from_rism.py` `exec`s the top of `model2.py` for
  `R`, `J`, `P`, `feats`, `rows`, `run`, `base`). The model is REBUILT in `../pmv.py` (new
  calibration set, new features, Bayesian version); the old coefficients are gone, so old and
  new corrections are not the same numbers.
- `evaluate.py`, `defs.py`, `defs2.py`, `defs3.py` (`rism4/`): molecule definitions and the
  loader of the old runs; `apply_new.py`, `aledit.py`, `chem.py` (`rism3/`, `names/`): the
  table writers and the electron counter. `../pmv.py` has its own `electrons` and `wire`.
- The raw 3D-RISM runs of `rism2/` and `rism4/` (hence `../out/redone_rows.tsv`: old rows need
  new runs).

What survives and is still valid as a record: the row, note and uncertainty conventions in
`specs.py`, and the way `apply_rism4.py` writes a row (tsv columns, `polymers.json` entry
`[Z, v0, sd]` keyed by the lower-case `iupac_name`, lower-case aliases in the lookup).
