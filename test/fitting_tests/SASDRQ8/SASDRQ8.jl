# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDRQ8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDRQ8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDRQ8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDRQ8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDRQ8: BSA (Albumin; Bos taurus; 66.432 kDa SASBDB molecule MW, monomer) in the
# SASBDB buffer "10 mM HEPES, 5 mM NaCl, 0.1 mM EDTA", pH 7.4. Sample: Bovine serum
# albumin monomer separated using asymmetric flow field flow fractionation (AFFFF).
#
# Publication: Graewert MA, Wilhelmy C, Bacic T, Schumacher J, Blanchet C, Meier F, Drexel
# R, Welz R, Kolb B, Bartels K, Nawroth T, Klein T, Svergun D, Langguth P, Haas H,
# "Quantitative size-resolved characterization of mRNA nanoparticles by in-line coupling
# of asymmetrical-flow field-flow fractionation with small angle X-ray scattering.", Sci
# Rep (2023 Sep 22), DOI 10.1038/s41598-023-42274-z. Entry:
# https://www.sasbdb.org/data/SASDRQ8/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.155 nm = 1.55 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 7999 eV); cell temperature 20.0
# °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.04199 to 2.871 1/nm, 1291 points)
# and is converted to Å⁻¹ (÷10); 142 points have I ≤ 0. q cut at 0.2025 Å⁻¹ (README rule):
# above it there are 387 points with a median I/σ of 0.50, 34 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.81.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.095); model:
# pdb 4f5s (identical); SASBDB model software: PDB (Protein Data Bank).
# SASDRQ8_fit1_model1.pdb: 4672 ATOM records (583 residues, chains A), 4672 heavy atoms,
# no hydrogens, 38 alternate-location records; one structure only.
# The fit file SASDRQ8_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "4f5s_mon
# Dro:0.065  Ra:1.800  RGT:28.36  Vol: 76601.  Chi^2: 1.095"; χ² recomputed from the file
# with the data's σ is 1.095 (label 1.095), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: alternate locations in the model; buffer from SASBDB only (paper not read); whole
# entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.55   # ≈ 7999 eV, SASBDB wavelength 1.55 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "10 mM HEPES, 5 mM NaCl, 0.1 mM EDTA", pH 7.4 (SASBDB). HEPES pK 7.564 (25 °C,
# ΔH 20.4 kJ/mol, dpK/dT -0.012, the constants of tui/assets/data/buffer_templates.json)
# moved to 22 °C (the pH taken as set at 22 °C) gives 7.600; Davies (A = 0.509) at the
# self-consistent ionic strength I = 0.009 M gives pK' = 7.557. The deprotonated
# (anionic) fraction of 10 mM is 0.411; with NaOH titration the counter-ion is sodium
# 4.11 mM (σ 0.63 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on
# the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "hepes"),   # 10 mM HEPES, ±2%
    NonBiological(0.005, 0.0001, "sodium chloride"),   # 5 mM, ±2%
    # counter-ion of the NaOH titration, 4.11 mM
    NonBiological(0.004106, 0.000628, "sodium"),
    # 0.1 mM EDTA (taken as the H2EDTA part, as the repo does), ±2%
    NonBiological(0.0001, 2e-06, "H2EDTA"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.2025 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.50, 34 % of the points non-positive).
const Q_MAX_FIT = 0.2025

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

# Builds the Seed that `runSasdrq8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdrq8` below is the whole story (build the seed, then sample it).
function seedSasdrq8(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdrq8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdrq8(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdrq8()

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
    refChi2 = "CRYSOL 1.095",
)

# `@__DIR__` (this SASDRQ8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
