# SPDX-License-Identifier: LGPL-3.0-or-later

"""TSV readers, results.tsv and the electron count (plain Python)."""

import re
from pathlib import Path

from . import config

ELEMENT_Z = {"H": 1, "C": 6, "N": 7, "O": 8, "P": 15, "S": 16, "Na": 11}


def read_tsv(path):
    """The rows of a TSV with a header line, as dicts."""
    lines = [ln.split("\t") for ln in Path(path).read_text().splitlines() if ln.strip()]
    return [dict(zip(lines[0], r, strict=False)) for r in lines[1:]]


def read_results(path=None):
    """name -> (n, mean, sd) from results.tsv (the last line of a name wins).

    Columns: name, n, mean, sd, buffer, grid, tolerance. Missing file: empty dict."""
    r = {}
    p = Path(path) if path else config.results_path()
    if p.exists():
        for line in p.read_text().splitlines():
            q = line.split("\t")
            if len(q) >= 4:
                r[q[0]] = (int(q[1]), float(q[2]), float(q[3]))
    return r


def calibration_table():
    """Every row of data/calibration.tsv (id, name, smiles, charge, nconf, v_meas, fit)."""
    return read_tsv(config.DATA / "calibration.tsv")


def electrons(formula, charge=0):
    """Electron count of a molecular formula such as C22H42O11, charge-corrected."""
    z = sum(
        ELEMENT_Z[e] * int(n or 1) for e, n in re.findall(r"([A-Z][a-z]?)(\d*)", formula)
    )
    return z - charge
