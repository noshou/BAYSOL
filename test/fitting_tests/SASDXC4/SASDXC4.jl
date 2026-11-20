# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXC4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXC4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDXC4_fit1_model2.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDXC4_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXC4: Pex8 (Peroxisomal biogenesis factor 8; Komagataella pastoris; 78.017 kDa
# SASBDB molecule MW, monomer) in the SASBDB buffer "50 mM HEPES, 150 mM NaCl, 3% v/v
# glycerol", pH 7.5. Sample: Peroxisomal biogenesis factor 8 (Pex8) bound to the
# C-terminal domain of Peroxisomal targeting signal receptor, Pex5 (Pex8-Pex5CTD complex
# from P. pastoris).
#
# Publication: Ekal L, Wendscheck D, David Y, Chojnowski G, Jeffries C, Mullapudi E,
# Schuldiner M, Warscheid B, Zalckvar E, Wilmanns M, "Structure of Pex8 in complex with
# peroxisomal receptor Pex5 reveals its essential role in peroxisomal cargo
# translocation", preprint/unpublished (2025 Sep 02), DOI 10.1101/2025.08.30.673231.
# Entry: https://www.sasbdb.org/data/SASDXC4/.
#
# BUFFER SOURCE: SASBDB buffer fields ("50 mM HEPES, 150 mM NaCl, 3 % v/v glycerol", pH
# 7.5, v/v stated). The preprint (bioRxiv 2025.08.30.673231) is not available in the open
# full-text service, so it was not checked. Model 1 of the fit is empty (no atoms), so
# model 2 (SASDXC4_fit1_model2.pdb) is used; the entry is wired WITHOUT a reference curve
# and WITHOUT refChi2 (owner).
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.123982 nm = 1.24 Å (the `wavelength`
# field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 10000 eV); cell
# temperature 20.0 °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.02358 to 7.395 1/nm, 2648 points)
# and is converted to Å⁻¹ (÷10); 234 points have I ≤ 0. q cut at 0.6788 Å⁻¹ (README rule):
# above it there are 218 points with a median I/σ of 0.49, 30 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.92.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.093); model:
# SASBDB model software: Other [static image]. SASDXC4_fit1_model2.pdb: 15889 ATOM records
# (999 residues, chains AB), 10103 heavy atoms, 5786 hydrogens (replaced by
# pdb2pqr/PROPKA); one structure only.
# The depositor's CRYSOL curve (SASDXC4_fit1.fit, 4 columns, χ² 1.093) is kept in the
# fixtures but not drawn: CRYSOL output has a different layout, so this entry is wired
# WITHOUT a reference curve and WITHOUT `refChi2` (`results` is called without
# `references`).
# The depositor fit covers q ≤ 0.3402 Å⁻¹ only while the data run to 0.7395 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: large structure (10103 heavy atoms); fit1 model 1 is empty, model 2 used; paper
# not retrievable; glycerol percentage unit not stated, v/v assumed; whole entry wired
# from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.2398   # ≈ 10000 eV, SASBDB wavelength 1.2398 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "50 mM HEPES, 150 mM NaCl, 3% v/v glycerol", pH 7.5 (SASBDB). HEPES pK 7.564
# (25 °C, ΔH 20.4 kJ/mol, dpK/dT -0.012, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 7.600; Davies (A = 0.509) at the self-consistent ionic strength I = 0.176 M
# gives pK' = 7.476. The deprotonated (anionic) fraction of 50 mM is 0.514; with NaOH
# titration the counter-ion is sodium 25.68 mM (σ 3.32 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM HEPES, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the NaOH titration, 25.68 mM
    NonBiological(0.025676, 0.00332, "sodium"),
    NonBiological(0.4109, 0.0205, "glycerol"),   # 3 % v/v glycerol (assumed v/v), ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.6788 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.49, 30 % of the points non-positive).
const Q_MAX_FIT = 0.6788

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has hydrogens, replaced here: pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `runSasdxc4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdxc4` below is the whole story (build the seed, then sample it).
function seedSasdxc4(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxc4(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdxc4(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxc4()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log.
# No reference curve and no refChi2 for this entry (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
)

# `@__DIR__` (this SASDXC4/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
