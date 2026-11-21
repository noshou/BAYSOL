# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDU89")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDU89.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDU89_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDU89_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDU89: ApoA-I (Apolipoprotein A-I; Homo sapiens; 21.567 kDa SASBDB molecule MW,
# monomer) in the SASBDB buffer "20 mM Tris, 150 mM NaCl, 0.1% sodium azide", pH 7.4.
# Sample: Apolipoprotein A-I monomer, C-terminally truncated.
#
# Publication: Tou H, Rosenes Z, Khandokar Y, Zlatic C, Metcalfe R, Mok Y, Morton C,
# Gooley P, Griffin M, "The structure of the apolipoprotein A-I monomer provides insights
# into its oligomerisation and lipid-binding mechanisms", Journal of Molecular Biology
# (2025 Aug), DOI 10.1016/j.jmb.2025.169394. Entry: https://www.sasbdb.org/data/SASDU89/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Australian Synchrotron, Melbourne, beamline
# SAXS/WAXS, X-ray synchrotron, detector Pilatus3 S 2M; wavelength 0.1078 nm = 1.078 Å
# (the `wavelength` field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 11501
# eV); cell temperature 20.0 °C; sample-detector distance None m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.005221 to 0.6236 1/A, 1607 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 229 points have I ≤ 0. q cut at 0.5399 Å⁻¹ (README rule): above it there are 218 points
# with a median I/σ of 0.50, 33 % of them non-positive, and the lowest-q quarter of them
# has a median I/σ of 0.64.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.157); model:
# SASBDB model software: Coot. SASDU89_fit1_model1.pdb: 1471 ATOM records (178 residues,
# chains C), 1471 heavy atoms, no hydrogens; one structure only.
# The fit file SASDU89_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "refine 2
# Dro:0.025  Ra:1.800  RGT:23.26  Vol: 26845.  Chi^2: 1.157"; χ² recomputed from the file
# with the data's σ is 1.159 (label 1.157), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.5 Å⁻¹ only while the data run to 0.6236 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: buffer from SASBDB only (paper not read); whole entry wired from the files above;
# not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.078   # ≈ 11501 eV, SASBDB wavelength 1.078 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM Tris, 150 mM NaCl, 0.1% sodium azide", pH 7.4 (SASBDB). Tris pK 8.072
# (25 °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.183 M
# gives pK' = 8.280. The protonated fraction of 20 mM is 0.884; with HCl titration the
# counter-ion is chloride 17.67 mM (σ 0.79 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    NonBiological(0.01538, 0.000308, "sodium azide"),   # 15.38 mM, ±2%
    # counter-ion of the HCl titration, 17.67 mM
    NonBiological(0.017672, 0.000786, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.5399 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.50, 33 % of the points non-positive).
const Q_MAX_FIT = 0.5399

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

# Builds the Seed that `runSasdu89` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdu89` below is the whole story (build the seed, then sample it).
function seedSasdu89()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdu89(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdu89()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdu89()

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
    refChi2 = "CRYSOL 1.157",
)

# `@__DIR__` (this SASDU89/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
