#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-3.0-or-later

"""3D-RISM partial molar volumes (PMV) with a Bayesian group correction.

One entry point, subcommands (details in README.md):

    pmv.py run NAME SMILES NCONF CHARGE [--seed N]
        conformers -> 3D-RISM -> results.tsv                      (heavy, AmberTools)
    pmv.py batch FILE.tsv [--tier T]
        run every row of a spec TSV (id, smiles, charge, nconf), sequentially (heavy)
    pmv.py fit
        ridge + Bayesian model on the calibration set -> <out>/coefficients.json
    pmv.py holdout
        the held-out solutes against the model
    pmv.py estimate NAME SMILES
        V and sd of a finished run, from the model
    pmv.py row NAME SMILES COMMON IUPAC FORMULA CHARGE [--alias A ...] [--apply]
        a polymers row for a finished run
    pmv.py diagnostics REPORT [options]
        residuals | cv | holdout | conformers | coefficients | tables | status | all
        (read-only; `pmv.py diagnostics` lists them)
    pmv.py status [--specs FILE]
        rows with no finished run (same as `diagnostics status`)
    pmv.py selftest
        the regression on a synthetic table, no RISM

Global options, before the subcommand: --out DIR (env PMV_OUT, default dev/pmv-rism/out),
--results FILE (env PMV_RESULTS, default <out>/results.tsv), --work DIR (env PMV_WORK,
default dev/pmv-rism/work). Everything generated lives under those and is gitignored.
Environment: AMBERHOME (default ~/.conda/envs/amber26: antechamber, parmchk2, tleap,
rism3d.snglpnt, RDKit in its Python). Run it with that environment's Python.
"""

import json
import os
import sys

from pmvlib import config, diagnostics, model, rism, rows, selftest, tables

GLOBAL_OPTIONS = {"--out": "PMV_OUT", "--results": "PMV_RESULTS", "--work": "PMV_WORK"}


def option_values(a, flag):
    """Every value following `flag` in the argument list a."""
    return [a[i + 1] for i, x in enumerate(a) if x == flag and i + 1 < len(a)]


def cmd_run(a):
    seed = int(a[a.index("--seed") + 1]) if "--seed" in a else 1
    return 0 if rism.run_molecule(a[0], a[1], int(a[2]), int(a[3]), seed) else 1


def cmd_batch(a):
    rism.batch(a[0], a[a.index("--tier") + 1] if "--tier" in a else None)
    return 0


def cmd_fit(_a):
    model.fit()
    return 0


def cmd_holdout(_a):
    print(json.dumps(model.holdout(model.load_model(), tables.read_results()), indent=1))
    return 0


def finished(name):
    """The results.tsv of the run `name`, or None after printing why there is none."""
    res = tables.read_results()
    if name not in res:
        print(f"no finished run named {name} in {config.results_path()}", file=sys.stderr)
        return None
    return res


def cmd_estimate(a):
    res = finished(a[0])
    if res is None:
        return 1
    mdl = model.load_model()
    v, sd = model.estimate(a[0], a[1], mdl, res)
    corr, psd = model.correction(a[1], mdl)
    print(
        f"{a[0]}: R {res[a[0]][1]:.2f} correction {corr:+.2f} (sd {psd:.2f}) "
        f"-> V {v:.2f} +- {sd:.2f}"
    )
    return 0


def cmd_row(a):
    res = finished(a[0])
    if res is None:
        return 1
    names = (a[2], a[3], a[4], int(a[5]))
    row = rows.make_row(
        a[0], a[1], names, option_values(a, "--alias"), model.load_model(), res
    )
    rows.wire([row], "--apply" in a)
    return 0


COMMANDS = {
    "run": cmd_run,
    "batch": cmd_batch,
    "fit": cmd_fit,
    "holdout": cmd_holdout,
    "estimate": cmd_estimate,
    "row": cmd_row,
    "diagnostics": diagnostics.main,
    "status": diagnostics.status,
    "selftest": selftest.main,
}


def main(argv):
    a = argv[1:]
    while len(a) >= 2 and a[0] in GLOBAL_OPTIONS:
        os.environ[GLOBAL_OPTIONS[a[0]]] = str(os.path.abspath(a[1]))
        a = a[2:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if a[0] not in COMMANDS:
        print("unknown subcommand", a[0], file=sys.stderr)
        return 2
    return COMMANDS[a[0]](a[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
