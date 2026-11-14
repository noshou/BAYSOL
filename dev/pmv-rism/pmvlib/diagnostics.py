# SPDX-License-Identifier: LGPL-3.0-or-later

"""Read-only reports on the fit, the runs and the tables (`pmv.py diagnostics NAME`).

Every report prints an aligned table and writes the same rows as a TSV to
`<out>/diagnostics/<report>.tsv` (the folder is created on demand). Nothing here runs
RISM, and nothing writes outside `<out>`: the table checks only read the repository's
tables and results.tsv.

    residuals     per solute and per group feature: fit, LOO residual, z score
    cv            LOO and repeated k-fold RMS (Bayesian and ridge)
    holdout       held-out solutes (fit = 0) against the model, direct and anchored
    conformers    spread of the conformer volumes of every run, outliers flagged
    coefficients  prior, posterior mean and sd, ridge coefficient per group feature
    tables        every `estimated` row of the tables against results.tsv
    status        rows with no finished run (calibration, tables, spec files)
    all           residuals, cv, holdout, conformers, coefficients, tables
"""

import math
import re
import sys

import numpy as np

from . import config, model, tables

SPREAD_FLAG = 1.0  # cm3/mol: conformer SD above this is flagged
Z_FLAG = 2.5  # |LOO z| above this is flagged
# The note `rows.make_row` writes; only such rows can be reproduced from a run.
NOTE_RE = re.compile(
    r"3D-RISM raw value (?P<raw>[-\d.]+) \(SD (?P<sd>[-\d.]+|nan) over (?P<n>\d+) "
    r"conformers\) plus the Bayesian group correction (?P<corr>[-+\d.]+) "
    r"\(predictive sd (?P<psd>[\d.]+)\)"
)


def emit(report, header, rows, title=None):
    """Print an aligned table and write it to <out>/diagnostics/<report>.tsv."""
    cells = [[c if isinstance(c, str) else f"{c:.2f}" for c in r] for r in rows]
    widths = [
        max(len(h), *(len(r[i]) for r in cells)) if cells else len(h)
        for i, h in enumerate(header)
    ]
    if title:
        print(f"\n== {title}")
    print("  ".join(h.ljust(w) for h, w in zip(header, widths, strict=True)))
    for r in cells:
        print("  ".join(c.ljust(w) for c, w in zip(r, widths, strict=True)))
    d = config.ensure_out() / "diagnostics"
    d.mkdir(exist_ok=True)
    body = ["\t".join(header)] + ["\t".join(r) for r in cells]
    (d / f"{report}.tsv").write_text("\n".join(body) + "\n")


def setup():
    """The fitted calibration: (rows, names, X, y, R, prior centre, prior sd, fit dict)."""
    rows, X, y, R = model.calibration()
    if len(y) < len(model.NAMES):
        raise SystemExit(
            f"only {len(y)} calibration solutes have a run in "
            f"{config.results_path()}: nothing to diagnose"
        )
    names = [r["name"] for r in rows]
    m0, sd, _ = model.prior(names, R)
    return rows, names, X, y, R, m0, sd, model.fit_arrays(X, y, m0, sd)


def residuals(_a):
    """Per solute (worst LOO first) and per group feature residuals."""
    rows, names, X, y, R, _m0, _sd, f = setup()
    order = np.argsort(-np.abs(f["loo_bayes"]))
    out = []
    for i in order:
        flag = "!" if abs(f["z"][i]) > Z_FLAG else ""
        out.append(
            [
                rows[i]["id"],
                names[i],
                R[i],
                y[i] + R[i],
                y[i] - f["fitted"][i],
                f["loo_bayes"][i],
                f["loo_ridge"][i],
                f["z"][i],
                flag,
            ]
        )
    emit(
        "residuals_solutes",
        [
            "id",
            "name",
            "R",
            "V_meas",
            "resid_in",
            "resid_loo",
            "resid_loo_ridge",
            "z",
            "flag",
        ],
        out,
        "per solute (V_meas - R - x.beta; worst leave-one-out first)",
    )
    g = []
    for j, k in enumerate(model.NAMES):
        m = X[:, j] > 0
        if m.any():
            g.append(
                [
                    k,
                    str(int(m.sum())),
                    float(f["mn"][j]),
                    float(np.mean(y[m] - f["fitted"][m])),
                    model.rms(y[m] - f["fitted"][m]),
                    model.rms(f["loo_bayes"][m]),
                ]
            )
        else:
            g.append([k, "0", float(f["mn"][j]), math.nan, math.nan, math.nan])
    emit(
        "residuals_groups",
        ["group", "n_solutes", "coef", "mean_resid_in", "rms_resid_in", "rms_resid_loo"],
        g,
        "per group feature (solutes that contain the group)",
    )
    return 0


def cv(a):
    """LOO and repeated k-fold RMS; options --k N (default 10), --repeats N (default 20)."""
    k = int(a[a.index("--k") + 1]) if "--k" in a else 10
    reps = int(a[a.index("--repeats") + 1]) if "--repeats" in a else 20
    _rows, _names, X, y, _R, m0, sd, f = setup()
    rng = np.random.default_rng(0)
    folds = [model.rms(model.kfold_bayes(X, y, m0, sd, k, rng)) for _ in range(reps)]
    ridge_folds = []
    for _ in range(reps):
        sel = np.array_split(rng.permutation(len(y)), k)
        e = np.empty(len(y))
        for s in sel:
            keep = np.ones(len(y), bool)
            keep[s] = False
            b, _ = model.ridge(X[keep], y[keep])
            e[s] = y[s] - X[s] @ b
        ridge_folds.append(model.rms(e))
    emit(
        "cv",
        ["scheme", "bayes_rms", "ridge_rms", "note"],
        [
            [
                "in-sample",
                model.rms(y - f["fitted"]),
                model.rms(y - X @ f["rb"]),
                "n=" + str(len(y)),
            ],
            ["LOO", model.rms(f["loo_bayes"]), model.rms(f["loo_ridge"]), ""],
            [
                f"{k}-fold mean",
                float(np.mean(folds)),
                float(np.mean(ridge_folds)),
                f"{reps} random splits",
            ],
            [
                f"{k}-fold sd over splits",
                float(np.std(folds)),
                float(np.std(ridge_folds)),
                "",
            ],
        ],
        "cross-validation (RMS of V_meas - V_predicted, cm3/mol)",
    )
    return 0


def holdout_report(_a):
    """The held-out table: direct and anchored errors."""
    h = model.holdout(model.load_model(), tables.read_results())
    if not h:
        print("no held-out solute (fit = 0) has a run, or the anchor DM has none")
        return 1
    out = [
        [
            n,
            d["measured"],
            d["direct"],
            d["direct_err"],
            d.get("anchored_on_DM", math.nan),
            d.get("anchored_err", math.nan),
        ]
        for n, d in h.items()
    ]
    emit(
        "holdout",
        ["solute", "measured", "direct", "direct_err", "anchored", "anchored_err"],
        out,
        "held-out solutes (not in the fit)",
    )
    return 0


def conformers(a):
    """Conformer spread of every run; --flag X changes the SD threshold (default 1.0)."""
    flag = float(a[a.index("--flag") + 1]) if "--flag" in a else SPREAD_FLAG
    res = tables.read_results()
    out = []
    for name, (n, mu, sd) in sorted(
        res.items(), key=lambda kv: -(0 if math.isnan(kv[1][2]) else kv[1][2])
    ):
        sem = model.conformer_error(n, sd)
        why = (
            "single conformer, no spread"
            if n == 1
            else "SD above threshold"
            if sd > flag
            else ""
        )
        out.append([name, str(n), mu, sd, sem, why])
    emit(
        "conformers",
        ["run", "n", "mean", "sd", "sem", "flag"],
        out,
        f"conformer spread (flag: SD > {flag} or one conformer); {len(res)} runs",
    )
    spread = [sd for (_, _, sd) in res.values() if not math.isnan(sd)]
    if spread:
        print(
            f"median SD {np.median(spread):.2f}, max {max(spread):.2f}, "
            f"{sum(1 for (n, _, _) in res.values() if n == 1)} single-conformer runs"
        )
    return 0


def coefficients(_a):
    """Coefficient table with posterior sds (marginal Student-t)."""
    _rows, _names, _X, _y, _R, m0, sd, f = setup()
    psd = model.coefficient_sd(f["Vn"], f["an"], f["bn"])
    out = []
    for j, k in enumerate(model.NAMES):
        out.append(
            [
                k,
                float(m0[j]),
                float(sd[j]),
                float(f["mn"][j]),
                float(psd[j]),
                float((f["mn"][j] - m0[j]) / sd[j]),
                float(f["rb"][j]),
            ]
        )
    emit(
        "coefficients",
        [
            "group",
            "prior_mean",
            "prior_sd",
            "post_mean",
            "post_sd",
            "shift_in_prior_sd",
            "ridge",
        ],
        out,
        "coefficients (cm3/mol per group); residual scale s = "
        f"{math.sqrt(f['bn'] / (f['an'] - 1)):.2f}",
    )
    return 0


def estimated_rows():
    """(table, row) of every `estimated` row of the polymers and nonbiological tables."""
    return [
        (t, r)
        for t, p in config.TABLES.items()
        for r in tables.read_tsv(p)
        if r.get("basis") == "estimated"
    ]


def match_runs(res, raw, n):
    """Names of the runs with n conformers and a mean within rounding of `raw`."""
    return [k for k, (kn, mu, _) in res.items() if kn == n and abs(mu - raw) <= 0.051]


def spec_smiles(path):
    """id -> smiles from a spec TSV (the `batch` format)."""
    return {r["id"]: r["smiles"] for r in tables.read_tsv(path)}


def check_row(table, r, res, smiles):
    """One estimated row: (status, run, detail): OK, MISMATCH, NO_RUN or FREE_TEXT."""
    m = NOTE_RE.search(r.get("doi", ""))
    if not m:
        return "FREE_TEXT", "", "note is not the pmv.py format (hand-derived or anchored)"
    raw, n, corr, psd = float(m["raw"]), int(m["n"]), float(m["corr"]), float(m["psd"])
    csd = math.nan if m["sd"] == "nan" else float(m["sd"])
    runs = match_runs(res, raw, n)
    if not runs:
        return "NO_RUN", "", f"no results.tsv entry with n={n} and mean {raw}"
    v, sd = float(r["v0_cm3_per_mol"]), float(r["uncertainty_cm3_per_mol"])
    bad = []
    if abs(raw + corr - v) > 0.11:
        bad.append(f"V {v} != raw+corr {raw + corr:.2f}")
    if abs(model.total_sd(psd, n, csd) - sd) > 0.1:
        bad.append(f"sd {sd} != {model.total_sd(psd, n, csd):.2f} from the note")
    drift = ""
    for run in runs:
        if run in smiles:
            c, p = model.correction(smiles[run], model.load_model())
            drift = f"; current model: corr {c:+.2f} (note {corr:+.1f}), psd {p:.2f}"
            if abs(c - corr) > 0.06:
                bad.append(f"correction drifted to {c:+.2f}")
    return ("MISMATCH" if bad else "OK"), "/".join(runs), "; ".join(bad) + drift


def tables_report(a):
    """Check every estimated row; --specs FILE adds SMILES and recomputes corrections."""
    res = tables.read_results()
    smiles = spec_smiles(a[a.index("--specs") + 1]) if "--specs" in a else {}
    out, counts = [], {}
    for t, r in estimated_rows():
        status, run, detail = check_row(t, r, res, smiles)
        counts[status] = counts.get(status, 0) + 1
        out.append([status, t, r["common_name"], r["v0_cm3_per_mol"], run, detail])
    emit(
        "tables",
        ["status", "table", "row", "V", "run", "detail"],
        out,
        f"estimated rows against {config.results_path()}",
    )
    print(counts)
    return 1 if counts.get("MISMATCH") or counts.get("NO_RUN") else 0


def status(a):
    """Rows with no finished run: calibration solutes, table rows, spec-file rows."""
    res = tables.read_results()
    out = [
        ["calibration", r["id"], r["name"], "fit" if r["fit"] == "1" else "holdout"]
        for r in tables.calibration_table()
        if r["id"] not in res
    ]
    for t, r in estimated_rows():
        s, _, d = check_row(t, r, res, {})
        if s == "NO_RUN":
            out.append([t, r["common_name"], r["v0_cm3_per_mol"], d])
    if "--specs" in a:
        out += [
            ["spec", r["id"], r["smiles"][:40], r.get("tier", "")]
            for r in tables.read_tsv(a[a.index("--specs") + 1])
            if r["id"] not in res
        ]
    emit(
        "status",
        ["kind", "id_or_row", "name_or_V", "detail"],
        out,
        f"no finished run in {config.results_path()} ({len(res)} runs there)",
    )
    return 0


def all_reports(a):
    """residuals, cv, holdout, conformers, coefficients, tables; the worst status."""
    worst = 0
    for fn in (residuals, cv, holdout_report, conformers, coefficients, tables_report):
        worst = max(worst, fn(a))
    return worst


REPORTS = {
    "residuals": residuals,
    "cv": cv,
    "holdout": holdout_report,
    "conformers": conformers,
    "coefficients": coefficients,
    "tables": tables_report,
    "status": status,
    "all": all_reports,
}


def main(argv):
    """`pmv.py diagnostics REPORT [options]`; returns the exit status."""
    if not argv or argv[0] not in REPORTS:
        print(__doc__, file=sys.stderr if argv else sys.stdout)
        return 2 if argv else 0
    return REPORTS[argv[0]](argv[1:])
