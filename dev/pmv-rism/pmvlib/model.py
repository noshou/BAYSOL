# SPDX-License-Identifier: LGPL-3.0-or-later

"""The group-correction model: V = R + x . beta, fitted on the calibration solutes.

R is the 3D-RISM conformer mean, x the group counts of the molecule, beta the corrections
(cm3/mol per group). Conjugate normal-inverse-gamma model, ridge as the sanity check.
`fit_arrays` and the helpers below it are pure numpy (tested by `selftest`); only
`features` needs RDKit.
"""

import json
import math

import numpy as np

try:
    from rdkit import Chem  # type: ignore
except ImportError:  # selftest and fit-free reports run without it
    Chem = None

from . import config, tables

BUFFER, GRID, TOL = "25", "0.5", "1e-6"  # 3D-RISM box buffer (A), grid spacing, tolerance
CH2 = 15.93  # CH2 increment, cm3/mol (measured sulfonates, PEG)
# Decyl beta-maltoside: the validation anchor (published table value, unchanged here).
ANCHOR = ("DM", 373.3, 3.9)
ANCHOR_SMILES = (
    "CCCCCCCCCCO[C@H]1[C@@H]([C@H]([C@@H]([C@H](O1)CO)O[C@@H]2[C@@H]([C@H]"
    "([C@@H]([C@H](O2)CO)O)O)O)O)O"
)
# Extra variance terms in quadrature (cm3/mol), see README "Uncertainty".
EXTRA_SD, MIN_SD = 2.0, 4.0
# Group features of the correction (fixed before the LOO error was looked at).
PATTERNS = {
    "CH3_CH2": "[CX4;H2,H3]",
    "CH_C": "[CX4;H1,H0]",
    "OH": "[OX2H]",
    "ether_O": "[OX2;H0]",
    "carbonyl_O": "[OX1]=[#6,#16]",
    "N_neutral": "[NX3;+0]",
    "arom_C": "[c]",
    "charged": "[+,-]",
    "S": "[#16]",
    "nitrile": "[CX2]#[NX1]",
    "rings": None,
}
NAMES = list(PATTERNS)
RIDGE_LAMBDA = 1e-3
# Bayesian priors: the CH2 correction is centred on CH2 minus the RISM slope per CH2
# (fitted on the n-alkanols of the set); every other group on 0, sd 5;
# s ~ InvGamma(2, 2*3^2).
SD_GROUP, SD_CH2, A0, S0 = 5.0, 1.5, 2.0, 3.0
ALKANOLS = {"ethanol": 2, "1-propanol": 3, "1-butanol": 4, "1-pentanol": 5, "1-hexanol": 6}


def features(smiles):
    """Group counts (NAMES order) of a molecule (RDKit)."""
    if Chem is None:
        raise SystemExit("RDKit is not installed (run with the AmberTools environment)")
    m = Chem.MolFromSmiles(smiles)
    f = []
    for k in NAMES:
        if PATTERNS[k] is None:
            f.append(m.GetRingInfo().NumRings())
        else:
            f.append(len(m.GetSubstructMatches(Chem.MolFromSmarts(PATTERNS[k]))))
    return np.array(f, float)


def calibration(fit_only=True, res=None):
    """Rows of data/calibration.tsv with a finished RISM run (RISM name = the id column);
    rows with fit = 0 are held out: (rows, features, y = V - R, R)."""
    res = tables.read_results() if res is None else res
    rows, X, y, R = [], [], [], []
    for r in tables.calibration_table():
        if r["id"] not in res or (fit_only and r["fit"] != "1"):
            continue
        rows.append(r)
        X.append(features(r["smiles"]))
        R.append(res[r["id"]][1])
        y.append(float(r["v_meas"]) - R[-1])
    return rows, np.array(X), np.array(y), np.array(R)


def prior(names, R):
    """Prior centre and sd of the group corrections, and the RISM slope per CH2.

    `names` are the solute names (alkanols give the slope), R their raw values."""
    pts = [(ALKANOLS[n], R[i]) for i, n in enumerate(names) if n in ALKANOLS]
    slope = np.polyfit(*zip(*pts, strict=True), 1)[0] if len(pts) >= 3 else CH2 # type: ignore
    m0 = np.zeros(len(NAMES))
    sd = np.full(len(NAMES), SD_GROUP)
    k = NAMES.index("CH3_CH2")
    m0[k], sd[k] = CH2 - slope, SD_CH2
    return m0, sd, float(slope)


def ridge(X, y, lam=RIDGE_LAMBDA):
    """Ridge coefficients and the leave-one-out residuals (hat-matrix shortcut)."""
    A = X.T @ X + lam * np.eye(X.shape[1])
    b = np.linalg.solve(A, X.T @ y)
    h = np.einsum("ij,ji->i", X, np.linalg.solve(A, X.T))
    return b, (y - X @ b) / (1 - h)


def posterior(X, y, m0, sd):
    """Normal-inverse-gamma posterior (mean, covariance factor, shape, scale)."""
    P0 = np.diag(1 / (sd / S0) ** 2)
    Pn = P0 + X.T @ X
    Vn = np.linalg.inv(Pn)
    mn = Vn @ (P0 @ m0 + X.T @ y)
    an = A0 + len(y) / 2
    bn = A0 * S0**2 + 0.5 * (y @ y + m0 @ P0 @ m0 - mn @ Pn @ mn)
    return mn, Vn, an, bn


def rms(e):
    """Root mean square of a sequence."""
    return float(np.sqrt(np.mean(np.square(e))))


def predictive_sd(x, Vn, an, bn):
    """Predictive sd of the correction of a molecule with group counts x."""
    return math.sqrt(bn / an * (1 + x @ Vn @ x))


def coefficient_sd(Vn, an, bn):
    """Posterior sd of each coefficient (Student-t marginal)."""
    return np.sqrt(bn / an * np.diag(Vn) * an / (an - 1))


def loo_bayes(X, y, m0, sd):
    """Leave-one-out residual and standardised residual (z) of the Bayesian fit."""
    res, z = [], []
    for i in range(len(y)):
        k = np.arange(len(y)) != i
        m, V, a, b = posterior(X[k], y[k], m0, sd)
        res.append(float(y[i] - X[i] @ m))
        z.append(res[-1] / predictive_sd(X[i], V, a, b))
    return np.array(res), np.array(z)


def kfold_bayes(X, y, m0, sd, k, rng):
    """Out-of-fold residuals of the Bayesian fit for one random k-fold split."""
    folds = np.array_split(rng.permutation(len(y)), k)
    out = np.empty(len(y))
    for f in folds:
        keep = np.ones(len(y), bool)
        keep[f] = False
        m = posterior(X[keep], y[keep], m0, sd)[0]
        out[f] = y[f] - X[f] @ m
    return out


def fit_arrays(X, y, m0, sd):
    """Bayesian and ridge fits with every quantity the reports need (pure numpy)."""
    mn, Vn, an, bn = posterior(X, y, m0, sd)
    rb, loo_r = ridge(X, y)
    loo_b, z = loo_bayes(X, y, m0, sd)
    return {
        "mn": mn,
        "Vn": Vn,
        "an": an,
        "bn": bn,
        "rb": rb,
        "fitted": X @ mn,
        "loo_bayes": loo_b,
        "loo_ridge": loo_r,
        "z": z,
    }


def fit():
    """Ridge (sanity check) and conjugate Bayesian fit; writes <out>/coefficients.json."""
    rows, X, y, R = calibration()
    names = [r["name"] for r in rows]
    m0, sd, slope = prior(names, R)
    f = fit_arrays(X, y, m0, sd)
    out = {
        "n": len(y),
        "features": NAMES,
        "smarts": PATTERNS,
        "ridge_lambda": RIDGE_LAMBDA,
        "rism_ch2_slope": slope,
        "prior_centre": dict(zip(NAMES, m0.tolist(), strict=True)),
        "prior_sd": dict(zip(NAMES, sd.tolist(), strict=True)),
        "A0": A0,
        "S0": S0,
        "bayes_mean": dict(zip(NAMES, f["mn"].tolist(), strict=True)),
        "bayes_an": f["an"],
        "bayes_bn": f["bn"],
        "bayes_Vn": f["Vn"].tolist(),
        "ridge_coef": dict(zip(NAMES, f["rb"].tolist(), strict=True)),
        "raw_bias_rms_R_minus_V": rms(y),
        "in_rms_bayes": rms(y - f["fitted"]),
        "in_rms_ridge": rms(y - X @ f["rb"]),
        "loo_rms_bayes": rms(f["loo_bayes"]),
        "loo_rms_ridge": rms(f["loo_ridge"]),
        "loo_z_sd_bayes": float(np.std(f["z"])),
        "loo": {
            n: [float(a), float(b)]
            for n, a, b in zip(names, f["loo_bayes"], f["loo_ridge"], strict=True)
        },
    }
    (config.ensure_out() / "coefficients.json").write_text(json.dumps(out, indent=1))
    keys = ("n", "in_rms_bayes", "in_rms_ridge", "loo_rms_bayes", "loo_rms_ridge")
    print({k: out[k] for k in (*keys, "loo_z_sd_bayes")})
    return out


def load_model():
    """<out>/coefficients.json (written by `fit`)."""
    p = config.out_dir() / "coefficients.json"
    if not p.exists():
        raise SystemExit(f"{p} does not exist: run `pmv.py fit` first")
    return json.loads(p.read_text())


def correction(smiles, model):
    """Posterior mean and predictive sd (cm3/mol) of V - R_mean for one molecule."""
    x = features(smiles)
    mn = np.array([model["bayes_mean"][k] for k in NAMES])
    Vn = np.array(model["bayes_Vn"])
    return float(x @ mn), predictive_sd(x, Vn, model["bayes_an"], model["bayes_bn"])


def combine(*sds):
    """Quadrature sum."""
    return math.sqrt(sum(s * s for s in sds))


def conformer_error(n, csd):
    """Standard error of a conformer mean (0 for one conformer)."""
    return 0.0 if math.isnan(csd) else csd / math.sqrt(n)


def total_sd(psd, n, csd):
    """sd of a direct estimate: predictive, conformer error, unmodelled chemistry."""
    return max(MIN_SD, combine(psd, conformer_error(n, csd), EXTRA_SD))


def estimate(name, smiles, model, res):
    """V = R_mean + correction (direct); sd from the predictive sd, conformer SD, extra."""
    n, mu, csd = res[name]
    corr, psd = correction(smiles, model)
    return mu + corr, total_sd(psd, n, csd)


def anchored(name, anchor, res, class_sd=2.0):
    """V = V_a + (R_t - R_a): difference against an anchored analogue, same pipeline.

    anchor = (rism_name, V, sd). sd = anchor sd, both conformer errors of the mean, the
    class term and the unmodelled-chemistry term in quadrature (at least MIN_SD). The
    group-correction difference is not added: it is zero within one family."""
    an, av, asd = anchor
    n, mu, csd = res[name]
    n2, mu2, csd2 = res[an]
    sd = combine(
        asd, conformer_error(n, csd), conformer_error(n2, csd2), class_sd, EXTRA_SD
    )
    return av + (mu - mu2), max(MIN_SD, sd)


def holdout(model, res):
    """Direct vs anchored estimates of the held-out solutes (fit = 0) and the anchor."""
    out = {}
    for r in tables.calibration_table():
        if r["fit"] != "0" or r["id"] not in res or ANCHOR[0] not in res:
            continue
        vd, _ = estimate(r["id"], r["smiles"], model, res)
        va, _ = anchored(r["id"], ANCHOR, res)
        meas = float(r["v_meas"])
        out[r["name"]] = {
            "measured": meas,
            "direct": vd,
            "direct_err": vd - meas,
            "anchored_on_DM": va,
            "anchored_err": va - meas,
        }
    if ANCHOR[0] in res:
        vd, sdd = estimate(ANCHOR[0], ANCHOR_SMILES, model, res)
        out["decyl maltoside (anchor, direct model)"] = {
            "measured": ANCHOR[1],
            "direct": vd,
            "direct_sd": sdd,
            "direct_err": vd - ANCHOR[1],
        }
    return out
