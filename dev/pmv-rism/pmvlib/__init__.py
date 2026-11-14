# SPDX-License-Identifier: LGPL-3.0-or-later

"""Library of `pmv.py` (3D-RISM partial molar volumes); see ../README.md.

config       paths (PMV_OUT, PMV_RESULTS, PMV_WORK, AMBERHOME), the AmberTools environment
tables       TSV readers, results.tsv, electron counts (plain Python, no RDKit)
model        group features, the Bayesian correction, estimates (RDKit only in `features`)
rows         a polymers row for a finished run and its wiring into src/bulk-electron-density
rism         the 3D-RISM driver (antechamber, tleap, rism3d.snglpnt): the only heavy part
diagnostics  read-only reports on the fit, the runs and the tables
selftest     checks of the regression on a synthetic table, no RISM needed
"""
