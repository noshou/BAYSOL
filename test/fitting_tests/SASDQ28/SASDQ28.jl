# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDQ28")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQ28.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDQ28_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDQ28_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQ28: USP14 (Ubiquitin carboxyl-terminal hydrolase 14; Homo sapiens; 46.243
# kDa SASBDB molecule MW, monomer) in the SASBDB buffer "20 mM HEPES, 150 mM NaCl, 2 mM
# TCEP", pH 7.5. Sample: Catalytic domain of ubiquitin-specific protease 14 (USP14).
#
# Publication: Salomonsson J, Wallner B, Sjöstrand L, D'Arcy P, Sunnerhagen M, Ahlner A,
# "Transient interdomain interactions in free USP14 shape its conformational ensemble.",
# Protein Sci (2024 May), DOI 10.1002/pro.4975. Entry:
# https://www.sasbdb.org/data/SASDQ28/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.124 nm = 1.24 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9999 eV); cell temperature 20.0
# °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.02245 to 7.318 1/nm, 2633 points)
# and is converted to Å⁻¹ (÷10); 65 points have I ≤ 0. q cut at 0.6949 Å⁻¹ (README rule):
# above it there are 133 points with a median I/σ of 0.49, 31 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.35.
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 1.056); model:
# alphafold P54578 (identical); SASBDB model software: AlphaFold Protein Structure
# Database. SASDQ28_fit2_model1.pdb: 3235 ATOM records (404 residues, chains A), 3235
# heavy atoms, no hydrogens; one structure only.
# The fit file SASDQ28_fit2.fit has 3 columns (q, I_exp, I_fit; no σ), header "core_AF.
# Dro:0.028  Ra:1.800  RGT:25.31  Vol: 59019.  Chi^2: 1.056"; label χ² 1.056 (not
# recomputed: the file has no σ column), so the reference curve is column 3; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.5 Å⁻¹ only while the data run to 0.7318 Å⁻¹, so the
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

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, SASBDB wavelength 1.24 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM HEPES, 150 mM NaCl, 2 mM TCEP", pH 7.5 (SASBDB). HEPES pK 7.564 (25 °C,
# ΔH 20.4 kJ/mol, dpK/dT -0.012, the constants of tui/assets/data/buffer_templates.json)
# moved to 22 °C (the pH taken as set at 22 °C) gives 7.600; Davies (A = 0.509) at the
# self-consistent ionic strength I = 0.160 M gives pK' = 7.479. The deprotonated
# (anionic) fraction of 20 mM is 0.512; with NaOH titration the counter-ion is sodium
# 10.24 mM (σ 1.32 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on
# the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM HEPES, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the NaOH titration, 10.24 mM
    NonBiological(0.010242, 0.00132, "sodium"),
    NonBiological(0.002, 4e-05, "tcep"),   # 2 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.6949 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.49, 31 % of the points non-positive).
const Q_MAX_FIT = 0.6949

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

# Builds the Seed that `runSasdq28` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdq28` below is the whole story (build the seed, then sample it).
function seedSasdq28(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdq28(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdq28(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdq28()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 2): columns q (Å⁻¹), I_exp, I_fit (no σ).
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 3]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.056",
)

# `@__DIR__` (this SASDQ28/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
