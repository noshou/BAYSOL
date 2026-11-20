# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXX4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXX4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDXX4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDXX4_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXX4: Serratia marcescens (Poly-beta-1,6-N-acetyl-D-glucosamine N-deacetylase
# PgaB; Serratia marcescens; 73.292 kDa SASBDB molecule MW, monomer) in the SASBDB buffer
# "phosphate-buffered saline", pH 7.4. Sample: Serratia marcescens poly-beta-1,6-N-acetyl-
# D-glucosamine N-deacetylase PgaB.
#
# Publication: Amanda Freitas Cruz, "Structural, biophysical and biochemical studies of
# CAZYmes involved in exopolysaccharides degradation of microbial biofilms", Universidade
# de São Paulo (2025 Sep 18), DOI None. Entry: https://www.sasbdb.org/data/SASDXX4/.
#
# BUFFER SOURCE: SASBDB buffer fields only (name, pH); SASBDB lists no publication for
# this entry, so there is no paper to check them against. PBS is entered as the standard
# recipe 137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4 and 1.8 mM KH2PO4 (the composition is
# stated neither in the paper nor in SASBDB); the salts are entered as such, so no
# speciation is computed.
#
# Instrument and conditions (SASBDB): Stanford Synchrotron Radiation Lightsource (SSRL),
# Menlo Park, CA, beamline BL4-2, X-ray synchrotron, detector Pilatus3 X 1M; wavelength
# 0.1127 nm = 1.127 Å (the `wavelength` field is in nm; `xray_energy` is null, so the
# energy is hc/λ ≈ 11001 eV); cell temperature 20.0 °C; sample-detector distance 1.7 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.006041 to 0.5045 1/A, 942 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 13 points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ >
# 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 4.912); model:
# SASBDB model software: AlphaFold. SASDXX4_fit1_model1.pdb: 5184 ATOM records (651
# residues, chains A), 5184 heavy atoms, no hydrogens; one structure only.
# The fit file SASDXX4_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.049
# Rg: 27.85 Vol:  91615. Chi^2: 4.912"; χ² recomputed from the file with the data's σ is
# 4.906 (label 4.912), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
# The depositor fit covers q ≤ 0.4293 Å⁻¹ only while the data run to 0.5045 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: AlphaFold prediction (no experimental structure); PBS composition not stated, the
# standard recipe is assumed; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.127   # ≈ 11001 eV, SASBDB wavelength 1.127 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "phosphate-buffered saline", pH 7.4 (SASBDB): no buffering species, only the
# salts below.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.137, 0.00274, "sodium chloride"),   # 137 mM, ±2%
    NonBiological(0.0027, 5.4e-05, "potassium chloride"),   # 2.7 mM, ±2%
    NonBiological(0.01, 0.0002, "disodium hydrogen phosphate"),   # 10 mM, ±2%
    NonBiological(0.0018, 3.6e-05, "potassium dihydrogen phosphate"),   # 1.8 mM, ±2%
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

# Builds the Seed that `runSasdxx4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdxx4` below is the whole story (build the seed, then sample it).
function seedSasdxx4(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxx4(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdxx4(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxx4()

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
    refChi2 = "CRYSOL 4.912",
)

# `@__DIR__` (this SASDXX4/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
