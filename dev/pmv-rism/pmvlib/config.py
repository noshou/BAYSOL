# SPDX-License-Identifier: LGPL-3.0-or-later

"""Paths and the AmberTools environment.

Everything the tools generate goes below one output folder (`out_dir()`, default
`dev/pmv-rism/out/`, gitignored, created on demand by `ensure_out()`); the location of
`results.tsv` and of the scratch folder of the runs are separate settings. All are read
at call time, so a test or a `--out` option can change them after import.
"""

import os
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent  # dev/pmv-rism
REPO = HERE.parent.parent
DATA = HERE / "data"
POLYMERS = REPO / "src/bulk-electron-density/polymers"
NONBIOLOGICAL = REPO / "src/bulk-electron-density/non-biological"
TABLES = {
    "polymers": POLYMERS / "polymers.tsv",
    "nonbiological": NONBIOLOGICAL / "nonbiological.tsv",
}
NONBIO_LOOKUP = NONBIOLOGICAL / "nonbio_lookup.json"


def out_dir():
    """Output folder: env PMV_OUT, default `dev/pmv-rism/out` (not created here)."""
    return Path(os.environ.get("PMV_OUT", HERE / "out"))


def ensure_out():
    """`out_dir()`, created if it does not exist."""
    d = out_dir()
    d.mkdir(parents=True, exist_ok=True)
    return d


def results_path():
    """The results.tsv of the runs: env PMV_RESULTS, default `<out>/results.tsv`."""
    return Path(os.environ.get("PMV_RESULTS", out_dir() / "results.tsv"))


def work_dir():
    """Scratch folder of the runs (one folder per molecule): env PMV_WORK, default work/."""
    return Path(os.environ.get("PMV_WORK", HERE / "work"))


def amber_home():
    """AmberTools prefix: env AMBERHOME, default ~/.conda/envs/amber26."""
    return Path(os.environ.get("AMBERHOME", Path.home() / ".conda/envs/amber26"))


def amber_env():
    """Process environment with the AmberTools `bin` first on PATH."""
    a = amber_home()
    return dict(os.environ, PATH=f"{a}/bin:" + os.environ.get("PATH", ""), AMBERHOME=str(a))
