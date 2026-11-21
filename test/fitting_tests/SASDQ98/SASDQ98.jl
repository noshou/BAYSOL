# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDQ98")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQ98.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDQ98_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDQ98_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQ98: DPCD (Protein DPCD; Homo sapiens; 23.239 kDa SASBDB molecule MW,
# monomer) in the SASBDB buffer "25 mM Tris-HCl, 200 mM NaCl", pH 7.5. Sample: Full-length
# human DPCD.
#
# Publication: Mao YQ, Seraphim TV, Wan Y, Wu R, Coyaud E, Bin Munim M, Mollica A, Laurent
# E, Babu M, Mennella V, Raught B, Houry WA, "DPCD is a regulator of R2TP in ciliogenesis
# initiation through Akt signaling.", Cell Rep (2024 Jan 31), DOI
# 10.1016/j.celrep.2024.113713. Entry: https://www.sasbdb.org/data/SASDQ98/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): National Synchrotron Light Source II (NSLS-II),
# Upton, NY, beamline 16-ID (LiX), X-ray synchrotron, detector Pilatus 1M; wavelength
# 0.0819 nm = 0.819 Å (the `wavelength` field is in nm; `xray_energy` is null, so the
# energy is hc/λ ≈ 15138 eV); cell temperature 20.0 °C; sample-detector distance 2.3 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.005 to 0.99 1/A, 200 points) and is
# in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 0
# points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ > 0
# points).
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 0.932); model:
# SASBDB model software: AlphaFold. SASDQ98_fit2_model1.pdb: 1634 ATOM records (203
# residues, chains A), 1634 heavy atoms, no hydrogens; one structure only. PDB title:
# "HEADER                                            01-JUL-21".
# The fit file SASDQ98_fit2.fit has 3 columns (q, I_exp, I_fit; no σ), header "hDPCD.pd
# Dro:0.005  Ra:1.800  RGT:19.36  Vol: 29925.  Chi^2: 0.932"; label χ² 0.932 (not
# recomputed: the file has no σ column), so the reference curve is column 3; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.5 Å⁻¹ only while the data run to 0.99 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.819   # ≈ 15138 eV, SASBDB wavelength 0.819 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "25 mM Tris-HCl, 200 mM NaCl", pH 7.5 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.221 M gives pK' = 8.285. The protonated fraction of 25
# mM is 0.859; with HCl titration the counter-ion is chloride 21.47 mM (σ 1.12 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris, ±2%
    NonBiological(0.2, 0.004, "sodium chloride"),   # 200 mM, ±2%
    # counter-ion of the HCl titration, 21.47 mM
    NonBiological(0.021475, 0.00112, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`iExp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdq98` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdq98` below is the whole story (build the seed, then sample it).
function seedSasdq98()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdq98(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdq98()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdq98()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 2): columns q (Å⁻¹), I_exp, I_fit (no σ).
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 3]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 0.932",
)

# `@__DIR__` (this SASDQ98/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
