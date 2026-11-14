# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDQT9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDQT9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDQT9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDQT9_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDQT9: the human RAD51 mutant F86E/A89E (monomeric, 339 residues) in complex
# with the BRC4 peptide of BRCA2 (35 residues), in 20 mM HEPES, 50 mM sodium sulfate,
# 2 % sucrose, pH 8.0.
#
# Publication (SASBDB): Rinaldi et al., Angew Chem Int Ed 2023, DOI
# 10.1002/anie.202312517. Entry: https://www.sasbdb.org/data/SASDQT9/. Papers are the
# source of truth (owner rule, 2026-11-13); the paper and its SI
# (anie202312517-sup-0001-misc_information) were read. SI Methods and Table S3 state:
# buffer "20 mM Hepes pH 8.00, 50 mM Na2SO4, 2% sucrose" (= SASBDB), sample temperature
# 15 °C (= SASBDB), wavelength 0.9537 Å (Table S3).
#
# Instrument: Diamond Light Source beamline B21; wavelength 0.9537 Å (SI Table S3) =>
# energy hc/λ ≈ 13000 eV. SASBDB gives 0.09464 nm (0.9464 Å, 13101 eV): the two CONFLICT
# and the paper's value is used. Sample temperature 15 °C.
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (angular_unit "1/A"; 0.0045-0.34 Å⁻¹;
# the text lines, then q, I, σ, all skipped by `_readCurve`; the range is checked by
# `checkQAngstrom` below). The intensities are on an arbitrary scale. 50 points have
# I ≤ 0 below 0.3 Å⁻¹ and `seedModel` drops the non-positive bins. The fit is cut at
# `Q_MAX_FIT` = 0.3 Å⁻¹ (evidence at the constant).
#
# Model and depositor fit: fit1 is FoXS against an ALPHAFOLD 2.2 model of the complex
# (chain B RAD51 F86E/A89E, chain A BRC4, 5757 atoms; not a PDB entry), type "other".
# The model ALREADY CARRIES HYDROGENS (PDB-v3 names). The header of the fit file reads
# "Chi^2 = 9.30571913" and SASBDB's chi_square_value is 9.305719, so the two agree
# and the label is χ² (FoXS "Chi^2"); the paper's SI Table S3 gives the same
# AlphaFold-model FoXS χ² of 9.31. The FoXS file has "#" comment lines, then columns
# q (Å⁻¹), I_exp, err, I_fit; it is read with `comments = true`. FoXS's own fitted
# scale and the c1/c2 excluded-volume and hydration-layer terms are not BAYSOL's, so
# the curves are only comparable in shape.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (the SASBDB .dat range, 0.0045-0.34, is checked below).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB: pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.9537   # ≈ 13000 eV, SI Table S3 wavelength
const TEMPERATURE_C = 15.0                      # SI Table S3 = SASBDB

# Buffer as deposited (SASBDB buffer name): "20 mM HEPES, 50 mM sodium sulfate, 2 %
# sucrose", pH 8.0. The measured macromolecule is deliberately NOT a solute (see
# BulkElectronDensity.Solute).
#
# Counter-ion. HEPES is neutral in BAYSOL's table; setting the pH with NaOH (ASSUMED,
# not stated) leaves Na⁺ = c·f with f the deprotonated fraction. pK(22 °C) = 7.6 (the
# value the sibling scripts use for HEPES), Davies-corrected (A = 0.509) at I ≈ 0.16 M,
# f = 0.769, i.e. 15.38 mM Na⁺ in addition to the 100 mM of the sulfate salt; σ =
# 0.9 mM covers σ_pH = 0.1 and 30 % of the Davies shift. Sucrose: "2 %" without unit,
# taken as w/v (by convention for a bare % sucrose; 20 g/L / 342.30 g/mol = 58.4 mM),
# σ = 10 %. The HEPES titrant is not stated anywhere; NaOH is the sibling convention.
const SOLUTES = Solute[
    NonBiological(0.020, 0.0004, "hepes"),             # 20 mM HEPES, ±2%
    NonBiological(0.015377, 0.0009, "sodium(1+)"),     # Na⁺ from NaOH titration
    NonBiological(0.050, 0.0005, "sodium sulfate"),    # 50 mM Na₂SO₄, ±1%
    NonBiological(0.0584, 0.006, "sucrose"),           # 2 % (w/v assumed), 58.4 mM
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.340 Å⁻¹,
# but the 307 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of 0.49 and 30 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 0.31 Å⁻¹) has a median I/σ of 0.91.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The AlphaFold model carries its own hydrogens: pdb2pqr/PROPKA place them at PH.
# UNTESTED for this file; if pdb2pqr rejects it (compare SASDP48), set this to false
# and the model's own hydrogens are used.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdqt9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdqt9` below is the whole story (build the seed, then sample it).
function seedSasdqt9(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdqt9(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdqt9(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdqt9()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is FoXS's (fit1): "#" comment lines, then q (Å⁻¹), I_exp, err, I_fit.
foxs = readdlm(_FIT_PATH; comments = true, comment_char = '#')
shown = foxs[:, 1] .> 0
reference = BAYSOL.Reference(
    "FoXS fit1",
    Float64.(foxs[shown, 1]),
    Float64.(foxs[shown, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "FoXS 9.306",
    runLog = true,
)

# `@__DIR__` (this SASDQT9/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
