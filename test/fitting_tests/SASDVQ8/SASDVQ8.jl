# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVQ8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVQ8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVQ8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVQ8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVQ8: PcGlc (glucan 1,3-beta-glucosidase; Penicillium rubens (strain ATCC
# 28089 / DSM 1075 / NRRL 1951 / Wisconsin 54-1255); 42.461 kDa SASBDB molecule MW,
# monomer) in the SASBDB buffer "50 mM sodium citrate, 150 mM NaCl", pH 4.5. Sample:
# Glucosidase/Rutinosidase from Penicillium rubens - deglycosylated.
#
# Publication: no publication is listed in SASBDB for this entry. Entry:
# https://www.sasbdb.org/data/SASDVQ8/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Institute of Biotechnology, Czech Academy of
# Sciences/Centre of Molecular Structure, Vestec, beamline Anton Paar SAXSpoint 2.0, X-ray
# in house, detector Eiger R 1M; wavelength 0.134 nm = 1.34 Å (the `wavelength` field is
# in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9253 eV); cell temperature 20.0
# °C; sample-detector distance 0.7805 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.1637 to 5.496 1/nm, 738 points) and
# is converted to Å⁻¹ (÷10); 255 points have I ≤ 0. q cut at 0.1184 Å⁻¹ (README rule):
# above it there are 596 points with a median I/σ of 0.23, 43 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.90.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.094); model:
# SASBDB model software: AlphaFold. SASDVQ8_fit1_model1.pdb: 2820 ATOM records (356
# residues, chains A), 2820 heavy atoms, no hydrogens; one structure only.
# The fit file SASDVQ8_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Pa2_mono
# Dro:0.043  Ra:1.400  RGT:20.42  Vol: 45994.  Chi^2: 1.094"; χ² recomputed from the file
# with the data's σ is 1.101 (label 1.094), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.1806 Å⁻¹ only while the data run to 0.5496 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); citrate titrant not stated, Na-only charge balance assumed; whole entry wired
# from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 4.5, PH_METER_SIGMA   # SASBDB pH 4.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9253 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "50 mM sodium citrate, 150 mM NaCl", pH 4.5 (SASBDB). Citrate 50 mM (pK 3.128,
# 4.761, 6.396 at 25 °C, no temperature shift; the buffer constants of
# tui/assets/data/buffer_templates.json), Davies at I = 0.263 M, species at pH 4.5:
# H₃Cit 1.3 %, H₂Cit⁻ 40.3 %, HCit²⁻ 55.2 %, Cit³⁻ 3.2 %; the Na⁺ comes with the three
# sodium salts (the titrant is not stated; the charge balance with Na⁺ only is assumed).
# σ from σ_pH 0.1, ±0.02 pK, 30 % of the Davies shift, ±2 %.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.020169, 0.00457, "sodium dihydrogen citrate"),   # H₂Cit⁻, 20.17 mM
    NonBiological(0.027591, 0.00393, "disodium hydrogen citrate"),   # HCit²⁻, 27.59 mM
    NonBiological(0.001609, 0.000937, "trisodium citrate"),   # Cit³⁻, 1.61 mM
    NonBiological(0.000631, 0.000276, "citric acid"),   # H₃Cit, 0.63 mM
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.15 Å⁻¹ (README rule (b)); the median I/σ is 6.6 at 0.105 to 0.150 Å⁻¹ and
# about 0.3 above. The cut of the first run, 0.1184 Å⁻¹ (33 binned points are kept now),
# did not converge (0.22 % divergent at the base run, R̂ 1.9 at δ 99, R̂ 1.033 with ESS 164
# when c1 was sampled); at 0.15 the run converges after the ladder's close-starts rung.
const Q_MAX_FIT = 0.15

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

# Builds the Seed that `runSasdvq8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvq8` below is the whole story (build the seed, then sample it).
function seedSasdvq8(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvq8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvq8(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvq8()

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
    refChi2 = "CRYSOL 1.094",
)

# `@__DIR__` (this SASDVQ8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
