# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDSF7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSF7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDSF7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDSF7_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDSF7: Codanin1 (Codanin-1; Homo sapiens; 24.961 kDa SASBDB molecule MW,
# monomer) in the SASBDB buffer "20 mM Tris HCl, 150 mM NaCl", pH 8.0. Sample: Human
# Codanin1 (C-terminus): analysis of second monomeric SEC peak.
#
# Publication: no publication is listed in SASBDB for this entry. Entry:
# https://www.sasbdb.org/data/SASDSF7/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Institute of Biotechnology, Czech Academy of
# Sciences/Centre of Molecular Structure, Vestec, beamline Anton Paar SAXSpoint 2.0, X-ray
# in house, detector Eiger R 1M; wavelength 0.134 nm = 1.34 Å (the `wavelength` field is
# in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9253 eV); cell temperature 20.0
# °C; sample-detector distance 0.79262 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.08863 to 3.997 1/nm, 680 points)
# and is converted to Å⁻¹ (÷10); 119 points have I ≤ 0.
# Rule-(a) cut 0.2046 Å⁻¹ (see Q_MAX_FIT): above it there are 339 points with a median I/σ
# of 0.50, 32 % of them non-positive, and the lowest-q quarter of them has a median I/σ of
# 0.56.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.229); model:
# SASBDB model software: AlphaFold. SASDSF7_fit1_model1.pdb: 1743 ATOM records (223
# residues, chains A), 1743 heavy atoms, no hydrogens; one structure only. PDB title:
# "HEADER                                            01-JUL-21".
# The fit file SASDSF7_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "CDAN1_Ct
# Dro:0.075  Ra:1.800  RGT:23.73  Vol: 31049.  Chi^2: 1.229"; χ² recomputed from the file
# with the data's σ is 1.229 (label 1.229), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.1505 Å⁻¹ only while the data run to 0.3997 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM Tris HCl, 150 mM NaCl", pH 8.0 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.163 M gives pK' = 8.277. The protonated fraction of 20
# mM is 0.654; with HCl titration the counter-ion is chloride 13.09 mM (σ 1.49 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 13.09 mM
    NonBiological(0.013087, 0.00149, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.16 Å⁻¹ (README rule (b)). The rule-(a) cut of the first run, 0.2046 Å⁻¹,
# failed the gates (0.81 % divergent, every rung of the ladder exhausted, R̂ up to 1.84 on
# the sampled-c1 fallback): between 0.16 and 0.2046 Å⁻¹ the median I/σ of the points falls
# from 2.4 to 0.8 and those points carry no shape information. At 0.16 Å⁻¹ the median I/σ
# of the window just below the cut is 2.4, 263 of the 680 points are kept (above it: 417
# points, median I/σ 0.57, 28 % non-positive), which is also about where the depositor's
# fit file ends (0.15 Å⁻¹).
const Q_MAX_FIT = 0.16

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

# Builds the Seed that `runSasdsf7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdsf7` below is the whole story (build the seed, then sample it).
function seedSasdsf7(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdsf7(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdsf7(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdsf7()

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
    refChi2 = "CRYSOL 1.229",
)

# `@__DIR__` (this SASDSF7/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
