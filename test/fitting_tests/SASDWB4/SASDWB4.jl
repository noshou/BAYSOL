# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDWB4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWB4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWB4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWB4_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWB4: b-AM (Beta-amylase; Ipomoea batatas; 56.079 kDa SASBDB molecule MW,
# tetramer) in the SASBDB buffer "phosphate buffered saline, 1% glycerol", pH 7.2. Sample:
# Sweet potato beta-amylase from AF4-SAXS measurement.
#
# Publication: Da Vela S, Bartels K, Franke D, Soloviov D, Gräwert T, Molodenskiy D, Kolb
# B, Wilhelmy C, Drexel R, Meier F, Haas H, Langguth P, Graewert MA, "AF4-to-SAXS:
# expanded characterization of nanoparticles and proteins at the P12 BioSAXS beamline.", J
# Synchrotron Radiat (2025 Jul 1), DOI 10.1107/S1600577525003959. Entry:
# https://www.sasbdb.org/data/SASDWB4/.
#
# BUFFER SOURCE (paper first, SASBDB second): the paper (see the Publication line) says
# PBS with 1 % glycerol, no composition and no glycerol unit; SASBDB agrees (PBS + 1 %
# glycerol, pH 7.2). PBS is entered as the standard recipe 137 mM NaCl, 2.7 mM KCl, 10 mM
# Na2HPO4 and 1.8 mM KH2PO4 (the composition is stated neither in the paper nor in
# SASBDB); the salts are entered as such, so no speciation is computed.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.12 nm = 1.2 Å (the `wavelength` field is
# in nm; `xray_energy` is null, so the energy is hc/λ ≈ 10332 eV); cell temperature 20.0
# °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.06059 to 2.611 1/nm, 886 points)
# and is converted to Å⁻¹ (÷10); 27 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.452); model:
# pdb 1fa2 (identical); SASBDB model software: PDB (Protein Data Bank).
# SASDWB4_fit1_model1.pdb: 15616 ATOM records (1992 residues, chains ABCD), 16288 heavy
# atoms, no hydrogens; HETATM groups kept as ligands: DTT 32 atoms, DOM 88 atoms; one
# structure only.
# The fit file SASDWB4_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.070
# Rg: 42.08 Vol: 278705. Chi^2: 1.452"; χ² recomputed from the file with the data's σ is
# 1.450 (label 1.452), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: large structure (16288 heavy atoms); ligand HETATM groups scattered with the
# protein; PBS composition not stated anywhere, the standard recipe is assumed; glycerol
# percentage unit not stated, v/v assumed; whole entry wired from the files above; not
# run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.2, PH_METER_SIGMA   # SASBDB pH 7.2 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # ≈ 10332 eV, SASBDB wavelength 1.2 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "phosphate buffered saline, 1% glycerol", pH 7.2 (SASBDB): no buffering
# species, only the salts below.
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.137, 0.00274, "sodium chloride"),   # 137 mM, ±2%
    NonBiological(0.0027, 5.4e-05, "potassium chloride"),   # 2.7 mM, ±2%
    NonBiological(0.01, 0.0002, "disodium hydrogen phosphate"),   # 10 mM, ±2%
    NonBiological(0.0018, 3.6e-05, "potassium dihydrogen phosphate"),   # 1.8 mM, ±2%
    NonBiological(0.137, 0.0068, "glycerol"),   # 1 % v/v glycerol (assumed v/v), ±5%
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

# Builds the Seed that `runSasdwb4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdwb4` below is the whole story (build the seed, then sample it).
function seedSasdwb4()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwb4(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdwb4()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwb4()

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
    refChi2 = "CRYSOL 1.452",
)

# `@__DIR__` (this SASDWB4/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
