#!/usr/bin/env python3
"""Turn the 3D-RISM runs of ~/pmv_work/rism4 plus table anchors into candidate rows (dry run: prints and writes rows.json).
Method of ~/pmv_work/rism2/final.py: V = R_mean + correction(group features), or anchored on a measured analogue,
V = V_anchor + (R_t - R_a) + (corr_t - corr_a). Uncertainty: seed sd, class sigma (3.5 direct = LOO RMS of the 72-solute fit,
2.0 anchored), fit variance, anchor uncertainty, and an extra term per unmodelled chemistry."""
import os, sys, json, csv, collections, statistics as st, math
import numpy as np
HERE = '/home/noso/pmv_work/rism4'
sys.path.insert(0, HERE); sys.path.insert(0, '/home/noso/pmv_work/names')
os.chdir('/home/noso/pmv_work/rism2')
exec(open('model2.py').read().split("sets={")[0])        # R (rism2 runs), J (jobs), P, feats, rows, run, base
cols = base + ['zwSO3']
cols, b, rms, loo, X, y = run(cols)
lam = 1e-3; Ainv = np.linalg.inv(X.T @ X + lam * np.eye(len(cols))); sig2 = np.mean(loo ** 2)
bd = dict(zip(cols, b))
corr_of = lambda f: -sum(bd[c] * f[c] for c in cols)
def fitvar(f): x = np.array([f[c] for c in cols], float); return sig2 * (x @ Ainv @ x)
import defs, defs2, defs3
SM = {**defs3.J, **defs2.J, **defs.J}
R4 = collections.defaultdict(list)
for l in open(HERE + '/results.tsv'):
    n, s, a, v, t, c = l.split('\t'); R4[n].append(float(v))
def smi_of(job):
    if job in SM: return SM[job][0]
    for r in J:
        if r[0] == job: return r[1]
    raise KeyError(job)
def rism(job):
    v = R4.get(job) or R.get(job)
    if not v: return None
    return st.mean(v), (st.stdev(v) if len(v) > 1 else 4.0), len(v)
def corr(job): return corr_of(feats(smi_of(job), 0))
def fv(job): return math.sqrt(fitvar(feats(smi_of(job), 0)))
T = json.load(open('/home/noso/BAYSOL/src/BulkElectronDensity/NonBiological/nonbiological.json'))
L = json.load(open('/home/noso/BAYSOL/src/BulkElectronDensity/NonBiological/nonbio_lookup.json'))
def tv(name):
    k = name.lower(); k = k if k in T else L[k].lower(); z, v, u = T[k]; return v, u
def q(*a): return math.sqrt(sum(x * x for x in a))
OUT = {}
def direct(job, extra, cls=3.5):
    r = rism(job)
    if r is None: return None
    m, sd, n = r; V = m + corr(job); return V, q(sd, cls, fv(job), extra), n
def anchored(job, ajob, va, ua, extra, cls=2.0, step=0.0, ustep=0.0):
    r, a = rism(job), rism(ajob)
    if r is None or a is None: return None
    V = va + (r[0] - a[0]) + (corr(job) - corr(ajob)) + step
    return V, q(r[1], a[1], ua, cls, extra, ustep), min(r[2], a[2])
