# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDUW6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUW6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDUW6_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDUW6_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUW6: HpARI2 (Alarmin release inhibitor (Δ1-62); Heligmosomoides polygyrus;
# 25.998 kDa SASBDB molecule MW, monomer) in the SASBDB buffer "137 mM NaCl, 2.7 mM KCl,
# 10 mM phosphate buffer, 5% glycerol", pH 7.2. Sample: Alarmin release inhibitor
# (HpARI2), full-length.
#
# Publication: Jamwal A, Colomb F, McSorley HJ, Higgins MK, "Structural basis for IL-33
# recognition and its antagonism by the helminth effector protein HpARI2.", Nat Commun
# (2024 Jun 19), DOI 10.1038/s41467-024-49550-0. Entry:
# https://www.sasbdb.org/data/SASDUW6/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Diamond Light Source, Didcot, beamline B21, X-ray
# synchrotron, detector Eiger 4M; wavelength 0.09464 nm = 0.9464 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 13101 eV); cell temperature
# 15.0 °C; sample-detector distance 3.7025 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.0045 to 0.34 1/A, 2568 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 71
# points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ > 0
# points).
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 1.065); model:
# SASBDB model software: Chimera. SASDUW6_fit2_model1.pdb: 1792 ATOM records (236
# residues, chains A), 1792 heavy atoms, no hydrogens; one structure only. PDB title:
# "HEADER     SREFLEX MODEL rc01".
# The fit file SASDUW6_fit2.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.014
# Rg: 27.15 Vol:  31778. Chi^2: 1.065"; χ² recomputed from the file with the data's σ is
# 1.065 (label 1.065), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: buffer from SASBDB only (paper not read); glycerol percentage unit not stated,
# v/v assumed; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.2, PH_METER_SIGMA   # SASBDB pH 7.2 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.9464   # ≈ 13101 eV, SASBDB wavelength 0.9464 Å
const TEMPERATURE_C = 15.0   # SASBDB cell temperature

# Buffer "137 mM NaCl, 2.7 mM KCl, 10 mM phosphate buffer, 5% glycerol", pH 7.2
# (SASBDB). Phosphate 10 mM is split into HPO₄²⁻ and H₂PO₄⁻ (pK₂ 7.198 at 25 °C, ΔH 3.6
# kJ/mol, van't Hoff to 22 °C, Davies at I = 0.164 M: pK₂' = 6.840); HPO₄²⁻ fraction
# 0.696; the counter-cations are taken as the Na⁺/K⁺ of the salts. σ 0.76 mM (σ_pH 0.1,
# ±0.02 pK, 30 % of the Davies shift, ±2 %).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.006963, 0.000762, "disodium hydrogen phosphate"),   # HPO₄²⁻, 6.96 mM
    NonBiological(0.003037, 0.000762, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 3.04 mM
    NonBiological(0.137, 0.00274, "sodium chloride"),   # 137 mM, ±2%
    NonBiological(0.0027, 5.4e-05, "potassium chloride"),   # 2.7 mM, ±2%
    NonBiological(0.6848, 0.0342, "glycerol"),   # 5 % v/v glycerol (assumed v/v), ±5%
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

# Builds the Seed that `runSasduw6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasduw6` below is the whole story (build the seed, then sample it).
function seedSasduw6()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasduw6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasduw6()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasduw6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.065",
)

# `@__DIR__` (this SASDUW6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
