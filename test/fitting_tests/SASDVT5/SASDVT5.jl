# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVT5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVT5.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVT5_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVT5_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVT5: MpARF3 (Auxin response factor; Marchantia polymorpha; 45.502 kDa SASBDB
# molecule MW, monomer) in the SASBDB buffer "20 mM Tris-HCl, 150 mM NaCl, 1 mM DTT", pH
# 8.0. Sample: Marchantia polymorpha Auxin Response Factor 3.
#
# Publication: Crespo I, Malfois M, Rienstra J, Tarrés-Solé A, van den Berg W, Weijers D,
# Boer DR, "The structure and function of the DNA binding domain of class B MpARF2 share
# more traits with class A AtARF5 than to that of class B AtARF1.", Structure (2025 Mar
# 7), DOI 10.1016/j.str.2025.02.006. Entry: https://www.sasbdb.org/data/SASDVT5/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): ALBA, Cerdanyola del Vallès, Barcelona, beamline
# BL11 - NCD, X-ray synchrotron, detector ADSC Quantum 210r; wavelength 0.1 nm = 1 Å (the
# `wavelength` field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 12398 eV);
# cell temperature 20.0 °C; sample-detector distance 2.56 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.2363 to 5.82 1/nm, 1932 points) and
# is converted to Å⁻¹ (÷10); 186 points have I ≤ 0. q cut at 0.4143 Å⁻¹ (README rule):
# above it there are 580 points with a median I/σ of 0.46, 25 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.59.
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 0.747); model:
# SASBDB model software: SwissModel. SASDVT5_fit2_model1.pdb: 3133 ATOM records (417
# residues, chains A), 3133 heavy atoms, no hydrogens; one structure only. PDB title:
# "TITLE     SWISS-MODEL SERVER (https://swissmodel.expasy.org)".
# The fit file SASDVT5_fit2.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.000
# Rg: 26.61 Vol:  55060. Chi^2: 0.747"; χ² recomputed from the file with the data's σ is
# 0.747 (label 0.747), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
# The depositor fit covers q ≤ 0.4999 Å⁻¹ only while the data run to 0.582 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: buffer from SASBDB only (paper not read); whole entry wired from the files above;
# not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1   # ≈ 12398 eV, SASBDB wavelength 1 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM Tris-HCl, 150 mM NaCl, 1 mM DTT", pH 8.0 (SASBDB). Tris pK 8.072 (25 °C,
# ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.163 M
# gives pK' = 8.277. The protonated fraction of 20 mM is 0.654; with HCl titration the
# counter-ion is chloride 13.09 mM (σ 1.49 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 13.09 mM
    NonBiological(0.013087, 0.00149, "chloride"),
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.4143 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.46, 25 % of the points non-positive).
const Q_MAX_FIT = 0.4143

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

# Builds the Seed that `runSasdvt5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvt5` below is the whole story (build the seed, then sample it).
function seedSasdvt5(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvt5(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvt5(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvt5()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 0.747",
)

# `@__DIR__` (this SASDVT5/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
