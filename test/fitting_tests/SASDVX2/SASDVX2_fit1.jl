# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVX2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVX2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVX2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVX2_fit1.fit")

# The .dat has 3 lines of header and 45 lines of processing history at the end, and the
# latter break `readdlm` (SASDVV4's has quote characters), so `_readCurve` (common.jl,
# numeric rows only) reads it: 2625 points.
qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 2625

# qvals are in nm⁻¹ (0.0255-7.35); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDVX2 (sasbdb.org/data/SASDVX2/); paper: Mertinkus
# et al. 2024, J. Am. Chem. Soc., "Dissecting the Conformational Heterogeneity of
# Stem-Loop Substructures of the Fifth Element in the 5'-Untranslated Region of
# SARS-CoV-2", DOI 10.1021/jacs.4c08406 (PMID 39442924). The paper's methods text was not
# consulted.
#
#     25 mM potassium phosphate, 50 mM KCl, pH 6.2
#
# The SASBDB comment says the buffer was "also used with 10 mM Mg2+ or 10 mM Mg2+/5 mM
# GdnCl"; this curve is the "50_mM_KCl" sample (.dat header), so no Mg2+ is listed.
# Full-length stem-loop 5 RNA (48.3 kDa), 1.0 mg/mL, 10 °C (cell; storage 20 °C), EMBL P12
# (PETRA III), wavelength 0.124028 nm => energy = hc/λ ≈ 10 keV (hc = 12398.42 eV·Å).
# The model is a PyMOL-built all-atom RNA without hydrogens.

const PH, σ_PH = 6.2, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24028   # ≈ 9996 eV, from the stated 0.124028 nm
const TEMPERATURE_C = 10.0                       # 10 °C, SASBDB

# Buffer components. "25 mM potassium phosphate" is a mix of KH2PO4 and K2HPO4 at pH 6.2:
# the HPO4²⁻ fraction is 0.166 (pK2 from Goldberg, Kishore & Lennen 2002, J. Phys. Chem.
# Ref. Data 31, 231, DOI 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at
# 22 °C (pH set at room temperature), Davies-corrected at I ≈ 0.083 M. σ combines σ_PH,
# ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C. Same treatment as the sodium
# phosphate of SASDWZ9.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    # 25 mM KPi, H2PO4⁻ part
    NonBiological(0.020851, 0.000999, "potassium dihydrogen phosphate"),
    # 25 mM KPi, HPO4²⁻ part
    NonBiological(0.004149, 0.000999, "dipotassium hydrogen phosphate"),
    NonBiological(0.050, 0.0005, "potassium chloride"),   # 50 mM KCl, ±1%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 0.3 Å⁻¹. The data run to 0.735 Å⁻¹,
# but the 1559 points above 0.3 Å⁻¹ (σ > 0) have a median I/σ of -0.13 and 55 % of them
# have I ≤ 0; the lowest-q quarter of them (up to 0.41 Å⁻¹) has a median I/σ of 0.39.
const Q_MAX_FIT = 0.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE, no PROPKA for a
# nucleic-acid-only file)
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`. (`seedModel`
bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(≤(Q_MAX_FIT), qvals)
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdvx2Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdvx2Fit1` below is the whole story (build the seed, then sample it).
function seedSasdvx2Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvx2Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvx2Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvx2Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "Pepsi-SAXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "Pepsi-SAXS 6.974",
    runLog = true,
)

# `@__DIR__` (this SASDVX2/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
