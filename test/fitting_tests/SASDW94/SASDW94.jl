# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDW94")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDW94.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDW94_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDW94_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDW94: apoferritin (Ferritin light chain; Equus caballus; 20.0 kDa SASBDB
# molecule MW, 24-mer) in the SASBDB buffer "phosphate buffered saline", pH 7.2. Sample:
# Horse apoferritin from AF4-SAXS measurements.
#
# Publication: Da Vela S, Bartels K, Franke D, Soloviov D, Gräwert T, Molodenskiy D, Kolb
# B, Wilhelmy C, Drexel R, Meier F, Haas H, Langguth P, Graewert MA, "AF4-to-SAXS:
# expanded characterization of nanoparticles and proteins at the P12 BioSAXS beamline.", J
# Synchrotron Radiat (2025 Jul 1), DOI 10.1107/S1600577525003959. Entry:
# https://www.sasbdb.org/data/SASDW94/.
#
# BUFFER SOURCE (paper first, SASBDB second): the paper (J Synchrotron Radiat 2025, see
# the Publication line) says only PBS; SASBDB gives "phosphate buffered saline", pH 7.2.
# PBS is entered as the standard recipe 137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4 and 1.8 mM
# KH2PO4 (the composition is stated neither in the paper nor in SASBDB); the salts are
# entered as such, so no speciation is computed.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.12 nm = 1.2 Å (the `wavelength` field is
# in nm; `xray_energy` is null, so the energy is hc/λ ≈ 10332 eV); cell temperature 20.0
# °C; sample-detector distance 6.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.05334 to 1.736 1/nm, 1169 points)
# and is converted to Å⁻¹ (÷10); 45 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.054); model:
# pdb 1ier (identical); SASBDB model software: PDB (Protein Data Bank).
# SASDW94_fit1_model1.pdb: 33552 ATOM records (4176 residues, chains
# ABCDEFGHIJKLMNOPQRSTUVWX), 33552 heavy atoms, no hydrogens, 144 alternate-location
# records; one structure only. PDB title: "HEADER     SAXS MODEL INCLUDED IN SASBDB ON THE
# 03-APR-14 CODE: D93".
# The fit file SASDW94_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.000
# Rg: 53.76 Vol: 593302. Chi^2: 1.054"; χ² recomputed from the file with the data's σ is
# 1.053 (label 1.054), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: large structure (33552 heavy atoms); alternate locations in the model; PBS
# composition not stated anywhere, the standard recipe is assumed; the SASBDB model mass
# (476 kDa) is far from the sample mass; kept at the owner's request; whole entry wired
# from the files above; not run.
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

# Buffer "phosphate buffered saline", pH 7.2 (SASBDB): no buffering species, only the
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

# Builds the Seed that `runSasdw94` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdw94` below is the whole story (build the seed, then sample it).
function seedSasdw94(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdw94(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdw94(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdw94()

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
    refChi2 = "CRYSOL 1.054",
)

# `@__DIR__` (this SASDW94/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
