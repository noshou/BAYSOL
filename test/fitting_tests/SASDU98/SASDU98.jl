# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDU98")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDU98.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDU98_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDU98_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDU98: MBP (Maltose/maltodextrin-binding periplasmic protein (D108A, K109A,
# E198A, N199A, K265A); Escherichia coli (strain K12); 40.248 kDa SASBDB molecule MW,
# dimer) in the SASBDB buffer "50 mM Tris pH 7.5, 150 mM NaCl", pH 7.5. Sample: SEC-SAXS
# of the fusion protein MPB-MabR(Rv2242) - dimeric peak.
#
# Publication: Megalizzi V, Tanina A, Grosse C, Mirgaux M, Legrand P, Mirandela G,
# Wohlkönig A, Bifani P, Wintjens R, "Domain architecture of the Mycobacterium
# tuberculosis MabR (Rv2242), a member of the PucR transcription factor family", Heliyon
# (2024 Nov), DOI 10.1016/j.heliyon.2024.e40494. Entry:
# https://www.sasbdb.org/data/SASDU98/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): SOLEIL, Saint-Aubin, beamline SWING, X-ray
# synchrotron, detector Eiger 4M; wavelength 0.1033 nm = 1.033 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 12002 eV); cell temperature
# 20.0 °C; sample-detector distance 2.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.003649 to 0.5538 1/A, 1211 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 453 points have I ≤ 0. rule-(a) cut 0.05154 Å⁻¹ (see Q_MAX_FIT): above it there are 1105
# points with a median I/σ of 0.25, 41 % of them non-positive, and the lowest-q quarter of
# them has a median I/σ of 0.99.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.399); model:
# SASBDB model software: AlphaFold. SASDU98_fit1_model1.pdb: 11730 ATOM records (1538
# residues, chains BC), 11730 heavy atoms, no hydrogens; one structure only.
# The fit file SASDU98_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.012
# Rg: 41.75 Vol: 208532. Chi^2: 1.399"; χ² recomputed from the file with the data's σ is
# 1.398 (label 1.399), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
# The depositor fit covers q ≤ 0.5 Å⁻¹ only while the data run to 0.5538 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: large structure (11730 heavy atoms); the SASBDB pH field is empty; the pH is the
# one in the buffer name; AlphaFold prediction (no experimental structure); buffer from
# SASBDB only (paper not read); whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, SASBDB wavelength 1.033 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "50 mM Tris pH 7.5, 150 mM NaCl", pH 7.5 (SASBDB). Tris pK 8.072 (25 °C, ΔH
# 47.45 kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json)
# moved to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the
# self-consistent ionic strength I = 0.193 M gives pK' = 8.282. The protonated fraction
# of 50 mM is 0.858; with HCl titration the counter-ion is chloride 42.91 mM (σ 2.24 mM:
# σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 42.91 mM
    NonBiological(0.042905, 0.00224, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.12 Å⁻¹ (README rule (b)); 0.09 Å⁻¹ still diverged (0.23 to 2 %) at every
# rung. The rule-(a) cut of the first run, 0.05154 Å⁻¹,
# kept 25 binned points and 1.9 Shannon channels for four parameters: the posterior was a
# long ridge (R̂ 1.19, bulk ESS 4.7, step size 0.002, tree depth 10, up to 15 % divergent
# on the lower-δ rungs of the ladder). The median I/σ of the window just below 0.09 Å⁻¹ is
# about 2 (3.6 below 0.08, 1.0 below 0.1), so this keeps the points that still carry signal
# (above 0.09: about 1020 points, median I/σ 0.13, 44 % non-positive).
const Q_MAX_FIT = 0.12

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`iExp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdu98` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdu98` below is the whole story (build the seed, then sample it).
function seedSasdu98()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdu98(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdu98()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdu98()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.399",
)

# `@__DIR__` (this SASDU98/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
