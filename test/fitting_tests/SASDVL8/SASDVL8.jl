# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVL8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVL8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVL8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVL8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVL8: McGlcH (glucan 1,3-beta-glucosidase; Mucor circinelloides; 44.696 kDa
# SASBDB molecule MW, monomer) in the SASBDB buffer "50 mM Tris, 150 mM NaCl", pH 7.1.
# Sample: Glycosidase/Rutinosidase from Mucor circinelloides - deglycosylated monomer.
#
# Publication: no publication is listed in SASBDB for this entry. Entry:
# https://www.sasbdb.org/data/SASDVL8/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Institute of Biotechnology, Czech Academy of
# Sciences/Centre of Molecular Structure, Vestec, beamline Anton Paar SAXSpoint 2.0, X-ray
# in house, detector Eiger R 1M; wavelength 0.134 nm = 1.34 Å (the `wavelength` field is
# in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9253 eV); cell temperature 20.0
# °C; sample-detector distance 0.825 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.08288 to 3.997 1/nm, 681 points)
# and is converted to Å⁻¹ (÷10); 114 points have I ≤ 0. q cut at 0.1954 Å⁻¹ (README rule):
# above it there are 355 points with a median I/σ of 0.50, 31 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.82.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.523); model:
# SASBDB model software: AlphaFold. SASDVL8_fit1_model1.pdb: 3019 ATOM records (379
# residues, chains A), 3019 heavy atoms, no hydrogens; one structure only.
# The fit file SASDVL8_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "McRutA.p
# Dro:0.043  Ra:1.500  RGT:21.41  Vol: 48986.  Chi^2: 1.523"; χ² recomputed from the file
# with the data's σ is 1.517 (label 1.523), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.1303 Å⁻¹ only while the data run to 0.3997 Å⁻¹, so the
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

const PH, σ_PH = 7.1, PH_METER_SIGMA   # SASBDB pH 7.1 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "50 mM Tris, 150 mM NaCl", pH 7.1 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.197 M gives pK' = 8.282. The protonated fraction of 50
# mM is 0.938; with HCl titration the counter-ion is chloride 46.92 mM (σ 1.37 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 46.92 mM
    NonBiological(0.046915, 0.00137, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.1954 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.50, 31 % of the points non-positive).
const Q_MAX_FIT = 0.1954

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

# Builds the Seed that `runSasdvl8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvl8` below is the whole story (build the seed, then sample it).
function seedSasdvl8(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvl8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvl8(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvl8()

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
    refChi2 = "CRYSOL 1.523",
)

# `@__DIR__` (this SASDVL8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
