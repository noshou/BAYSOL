# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDWN5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWN5.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWN5_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWN5_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWN5: DS6A (N-acetylmuramoyl-L-alanine amidase; Mycobacterium phage DS6A;
# 43.458 kDa SASBDB molecule MW, monomer) in the SASBDB buffer "20 mM Tris, 150 mM NaCl
# and 1 mM DTT", pH 8.0. Sample: N-acetylmuramoyl-L-alanine amidase (without His-Tag).
#
# Publication: Ceballos-Zúñiga F, Galvez-Larrosa L, Muñoz IG, Infantes L, Fernández-
# Carrillo J, Pérez-Dorado I, "Dissecting the molecular basis underlying mycobacterial
# cell-wall hydrolysis by the catalytic domains of D29LysA and DS6ALysA phage
# endolysins.", Int J Biol Macromol (2025 Nov 7), DOI 10.1016/j.ijbiomac.2025.148896.
# Entry: https://www.sasbdb.org/data/SASDWN5/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Diamond Light Source, Didcot, beamline B21, X-ray
# synchrotron, detector Eiger 4M; wavelength 1.0 nm = 10 Å (the `wavelength` field is in
# nm; `xray_energy` is null, so the energy is hc/λ ≈ 1240 eV); cell temperature 18.0 °C;
# sample-detector distance 3.7 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.0045 to 0.3399 1/A, 2572 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 115
# points have I ≤ 0. q cut at 0.3039 Å⁻¹ (README rule): above it there are 276 points with
# a median I/σ of 0.49, 26 % of them non-positive, and the lowest-q quarter of them has a
# median I/σ of 0.83.
#
# Model and depositor fit: fit 1 of the entry is FoXS (chi_square_value 1.628254); model:
# SASBDB model software: Coot. SASDWN5_fit1_model1.pdb: 5941 ATOM records (395 residues,
# chains A), 3046 heavy atoms, 2895 hydrogens (replaced by pdb2pqr/PROPKA); one structure
# only.
# The depositor's FoXS curve (SASDWN5_fit1.fit, 4 columns, χ² 1.628254) is kept in the
# fixtures but not drawn: FoXS output has a different layout, so this entry is wired
# WITHOUT a reference curve and WITHOUT `refChi2` (`results` is called without
# `references`).
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

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 10   # ≈ 1240 eV, SASBDB wavelength 10 Å
const TEMPERATURE_C = 18.0   # SASBDB cell temperature

# Buffer "20 mM Tris, 150 mM NaCl and 1 mM DTT", pH 8.0 (SASBDB). Tris pK 8.072 (25 °C,
# ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.163 M
# gives pK' = 8.277. The protonated fraction of 20 mM is 0.654; with HCl titration the
# counter-ion is chloride 13.09 mM (σ 1.49 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 13.09 mM
    NonBiological(0.013087, 0.00149, "chloride"),
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.3039 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.49, 26 % of the points non-positive).
const Q_MAX_FIT = 0.3039

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

# Builds the Seed that `runSasdwn5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdwn5` below is the whole story (build the seed, then sample it).
function seedSasdwn5()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwn5(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdwn5()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwn5()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log.
# No reference curve and no refChi2 for this entry (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
)

# `@__DIR__` (this SASDWN5/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
