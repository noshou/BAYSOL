# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDWW6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWW6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWW6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWW6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWW6: Apoferritin dimer (Ferritin light chain; Equus caballus; 19.846 kDa
# SASBDB molecule MW, other) in the SASBDB buffer "137 mM NaCl, 2.7 mM KCl, 10 mM
# phosphate buffer, 0.9 mM CaCl2, 0.5 mM MgCl2", pH 7.4. Sample: SEC-SAXS data for the
# total dimer (2 x 24mer) fraction of horse spleen apoferritin.
#
# Publication: no publication is listed in SASBDB for this entry. Entry:
# https://www.sasbdb.org/data/SASDWW6/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Shanghai Synchrotron Radiation Facility (SSRF),
# Shanghai, beamline BL19U2, X-ray synchrotron, detector Pilatus 1M; wavelength 0.1033 nm
# = 1.033 Å (the `wavelength` field is in nm; `xray_energy` is null, so the energy is hc/λ
# ≈ 12002 eV); cell temperature 20.0 °C; sample-detector distance 2.696 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.005798 to 0.4068 1/A, 1142 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 166 points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ
# > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.22); model:
# pdb 2w0o (identical); SASBDB model software: Chimera. SASDWW6_fit1_model1.pdb: 66288
# ATOM records (8160 residues, chains ABCDEFGHIJKLMNOPQRSTUVWXabcdefghijklmnopqrstuvwx),
# 66288 heavy atoms, no hydrogens, 1632 alternate-location records; one structure only.
# The fit file SASDWW6_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "crystal-
# Convex:  0.000  Concave:  2.000  Inner: -10.00  Chi^2: 1.220"; χ² recomputed from the
# file with the data's σ is 1.219 (label 1.22), so the reference curve is column 4; q in
# Å⁻¹ (SASBDB fit_unit "1/A").
#
# Flags: VERY LARGE structure (66288 heavy atoms): expect a long run time; alternate
# locations in the model; buffer from SASBDB only (paper not read); whole entry wired from
# the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, SASBDB wavelength 1.033 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "137 mM NaCl, 2.7 mM KCl, 10 mM phosphate buffer, 0.9 mM CaCl2, 0.5 mM MgCl2",
# pH 7.4 (SASBDB). Phosphate 10 mM is split into HPO₄²⁻ and H₂PO₄⁻ (pK₂ 7.198 at 25 °C,
# ΔH 3.6 kJ/mol, van't Hoff to 22 °C, Davies at I = 0.170 M: pK₂' = 6.837); HPO₄²⁻
# fraction 0.785; the counter-cations are taken as the Na⁺/K⁺ of the salts. σ 0.63 mM
# (σ_pH 0.1, ±0.02 pK, 30 % of the Davies shift, ±2 %).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.007853, 0.000625, "disodium hydrogen phosphate"),   # HPO₄²⁻, 7.85 mM
    NonBiological(0.002147, 0.000625, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 2.15 mM
    NonBiological(0.137, 0.00274, "sodium chloride"),   # 137 mM, ±2%
    NonBiological(0.0027, 5.4e-05, "potassium chloride"),   # 2.7 mM, ±2%
    NonBiological(0.0009, 1.8e-05, "calcium chloride"),   # 0.9 mM, ±2%
    NonBiological(0.0005, 1e-05, "magnesium chloride"),   # 0.5 mM, ±2%
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

# Builds the Seed that `runSasdww6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdww6` below is the whole story (build the seed, then sample it).
function seedSasdww6()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdww6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdww6()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdww6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.22",
)

# `@__DIR__` (this SASDWW6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
