# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDUU3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUU3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDUU3_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDUU3_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUU3: AOC3 (Membrane primary amine oxidase; Homo sapiens; 81.784 kDa SASBDB
# molecule MW, dimer) in the SASBDB buffer "137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8 mM
# KH2PO4", pH 7.4. Sample: Human primary amine oxidase copper-containing 3 (AOC3).
#
# Publication: no publication is listed in SASBDB for this entry. Entry:
# https://www.sasbdb.org/data/SASDUU3/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Diamond Light Source, Didcot, beamline B21, X-ray
# synchrotron, detector Pilatus 2M; wavelength 0.1 nm = 1 Å (the `wavelength` field is in
# nm; `xray_energy` is null, so the energy is hc/λ ≈ 12398 eV); cell temperature 25.0 °C;
# sample-detector distance 4.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.0035 to 0.37 1/A, 1653 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 529
# points have I ≤ 0. q cut at 0.05564 Å⁻¹ (README rule): above it there are 1417 points
# with a median I/σ of 0.36, 37 % of them non-positive, and the lowest-q quarter of them
# has a median I/σ of 0.98.
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 1.112); model:
# SASBDB model software: PyMOL. SASDUU3_fit2_model1.pdb: 11296 ATOM records (1434
# residues, chains CD), 11885 heavy atoms, no hydrogens; HETATM groups kept as ligands:
# TPQ 28 atoms, CA 4 atoms, CU 2 atoms, NAG 294 atoms, MAN 231 atoms, FUC 30 atoms; one
# structure only.
# The fit file SASDUU3_fit2.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.060
# Rg: 35.20 Vol: 210278. Chi^2: 1.112"; χ² recomputed from the file with the data's σ is
# 1.111 (label 1.112), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: large structure (11885 heavy atoms); ligand HETATM groups scattered with the
# protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell temperature;
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1   # ≈ 12398 eV, SASBDB wavelength 1 Å
const TEMPERATURE_C = 25.0   # SASBDB cell temperature

# Buffer "137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8 mM KH2PO4", pH 7.4 (SASBDB): the
# salts are stated explicitly (Na2HPO4 and KH2PO4 with the NaCl and KCl); no speciation
# is computed.
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

# No q cut: the whole curve is fitted (README, item 5 of the ladder). The cut at 0.05564
# Å⁻¹ of the README rule (a) left 27 binned points and 2.1 Shannon channels for four
# parameters on 22.7k atoms; the step size collapsed to 0.0016 (tree depth 10) and the
# chains split (R̂ 1.06 to 1.9 at every ladder rung, also with δ 70/99, close starts and
# a cut at 0.08 Å⁻¹). Uncut (152 binned points) the base run converges at the defaults.
const Q_MAX_FIT = Inf

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

# Builds the Seed that `runSasduu3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasduu3` below is the whole story (build the seed, then sample it).
function seedSasduu3(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasduu3(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasduu3(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasduu3()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.112",
)

# `@__DIR__` (this SASDUU3/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
