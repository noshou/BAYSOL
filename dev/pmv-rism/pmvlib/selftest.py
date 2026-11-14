# SPDX-License-Identifier: LGPL-3.0-or-later

"""`pmv.py selftest`: the regression on a tiny synthetic table; no RISM, no results.tsv.

The checks are the ones a change to `model.py` must keep: the posterior against a
brute-force normal-equation solution, the hat-matrix LOO against refits, recovery of a
known beta, the alkanol prior slope, the results.tsv reader, the electron count and
(when RDKit is installed) the group counts of two molecules.
"""

import os
import tempfile
from pathlib import Path

import numpy as np

from . import config, model, tables

TOL = 1e-8


def synthetic(rng, n=60, noise=2.5):
    """Random group counts, a known beta, y = X beta + noise."""
    X = rng.integers(0, 4, size=(n, len(model.NAMES))).astype(float)
    beta = rng.normal(0, 3, size=len(model.NAMES))
    return X, X @ beta + rng.normal(0, noise, n), beta


def run():
    """Run the checks; returns the list of failures (empty when all pass)."""
    rng = np.random.default_rng(1)
    X, y, beta = synthetic(rng)
    m0 = np.zeros(len(model.NAMES))
    sd = np.full(len(model.NAMES), 1e3)  # flat prior: posterior mean ~ least squares
    bad = []

    def check(ok, what):
        print(("ok    " if ok else "FAIL  ") + what)
        if not ok:
            bad.append(what)

    f = model.fit_arrays(X, y, m0, sd)
    ls = np.linalg.lstsq(X, y, rcond=None)[0]
    check(np.allclose(f["mn"], ls, atol=1e-4), "flat-prior posterior mean = least squares")
    check(np.allclose(f["mn"], beta, atol=1.0), "known beta recovered (noise 2.5)")
    # informative prior: posterior mean = (P0 + X'X)^-1 (P0 m0 + X'y), checked directly
    m1, s1 = np.ones(len(m0)), np.full(len(m0), 2.0)
    P0 = np.diag(1 / (s1 / model.S0) ** 2)
    direct = np.linalg.solve(P0 + X.T @ X, P0 @ m1 + X.T @ y)
    check(np.allclose(model.posterior(X, y, m1, s1)[0], direct, atol=TOL), "posterior mean")
    # hat-matrix LOO of ridge against explicit refits
    _, loo = model.ridge(X, y)
    ref = []
    for i in range(len(y)):
        k = np.arange(len(y)) != i
        b, _ = model.ridge(X[k], y[k])
        ref.append(y[i] - X[i] @ b)
    check(np.allclose(loo, ref, atol=1e-6), "ridge LOO shortcut = explicit refits")
    z = f["z"]
    check(
        0.6 < float(np.std(z)) < 1.5, f"LOO z scores are standardised (sd {np.std(z):.2f})"
    )
    kf = model.kfold_bayes(X, y, m0, sd, 5, np.random.default_rng(2))
    check(
        model.rms(kf) < 4.0 and np.isfinite(kf).all(), "k-fold residuals finite and small"
    )
    psd = model.coefficient_sd(f["Vn"], f["an"], f["bn"])
    check(bool((psd > 0).all()), "coefficient sds positive")
    # prior slope: alkanols with R = 10 + 14 n give slope 14, CH2 centre CH2 - 14
    names = ["ethanol", "1-propanol", "1-butanol", "1-pentanol"]
    _, _, slope = model.prior(names, [10 + 14 * model.ALKANOLS[n] for n in names])
    m, _, _ = model.prior(names, [10 + 14 * model.ALKANOLS[n] for n in names])
    check(
        abs(slope - 14) < 1e-6 and abs(m[0] - (model.CH2 - 14)) < 1e-6,
        "alkanol prior slope",
    )
    check(
        model.total_sd(1.0, 1, float("nan")) == model.MIN_SD,
        "sd floor and single conformer",
    )
    check(
        tables.electrons("C22H42O11") == 262 and tables.electrons("Na", 1) == 10,
        "electron count",
    )
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "results.tsv"
        p.write_text("A\t2\t1.5\t0.1\t25\t0.5\t1e-6\nA\t3\t2.5\tnan\t25\t0.5\t1e-6\n")
        r = tables.read_results(p)
        check(
            r["A"][0] == 3 and r["A"][1] == 2.5, "results.tsv: the last line of a name wins"
        )
        old = os.environ.get("PMV_OUT")
        os.environ["PMV_OUT"] = d
        check(config.results_path() == Path(d) / "results.tsv", "PMV_OUT moves results.tsv")
        os.environ["PMV_RESULTS"] = str(p)
        check(config.results_path() == p, "PMV_RESULTS overrides the location")
        del os.environ["PMV_RESULTS"]
        if old is None:
            del os.environ["PMV_OUT"]
        else:
            os.environ["PMV_OUT"] = old
    if model.Chem is None:
        print("skip  group counts (RDKit not installed)")
    else:
        got = model.features("OCC(O)CC")  # 1,2-butanediol
        want = {"CH3_CH2": 3, "CH_C": 1, "OH": 2, "rings": 0}
        check(all(got[model.NAMES.index(k)] == v for k, v in want.items()), "group counts")
    return bad


def main(_argv):
    """Print one line per check; exit status 1 on any failure."""
    bad = run()
    print(f"\n{len(bad)} failed" if bad else "\nall checks passed")
    return 1 if bad else 0
