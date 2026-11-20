# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDTC5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTC5.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDTC5_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDTC5_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTC5: Full-length E3 ubiquitin-protein ligase HACE1 (E3 ubiquitin-protein
# ligase HACE1; Homo sapiens; 102.399 kDa SASBDB molecule MW, dimer) in the SASBDB buffer
# "50 mM HEPES, 50 mM NaCl, 5 mM DTT", pH 8.0. Sample: Full-length E3 ubiquitin-protein
# ligase HACE1.
#
# Publication: Düring J, Wolter M, Toplak J, Torres C, Dybkov O, Fokkens T, Bohnsack K,
# Urlaub H, Steinchen W, Dienemann C, Lorenz S, "Structural mechanisms of autoinhibition
# and substrate recognition by the ubiquitin ligase HACE1", Nature Structural & Molecular
# Biology (2024 Feb 08), DOI 10.1038/s41594-023-01203-4. Entry:
# https://www.sasbdb.org/data/SASDTC5/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.123974 nm = 1.24 Å (the `wavelength`
# field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 10001 eV); cell
# temperature 20.0 °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.07502 to 4.436 1/nm, 1517 points)
# and is converted to Å⁻¹ (÷10); 3 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 2 of the entry is FoXS (chi_square_value 1.011305); model:
# SASBDB model software: AllosMod. SASDTC5_fit2_model1.pdb: 14374 ATOM records (1820
# residues, chains AB), 14374 heavy atoms, no hydrogens; one structure only.
# The depositor's FoXS curve (SASDTC5_fit2.fit, 4 columns, χ² 1.011305) is kept in the
# fixtures but not drawn: FoXS output has a different layout, so this entry is wired
# WITHOUT a reference curve and WITHOUT `refChi2` (`results` is called without
# `references`).
#
# Flags: large structure (14374 heavy atoms); buffer from SASBDB only (paper not read);
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.2397   # ≈ 10001 eV, SASBDB wavelength 1.2397 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "50 mM HEPES, 50 mM NaCl, 5 mM DTT", pH 8.0 (SASBDB). HEPES pK 7.564 (25 °C, ΔH
# 20.4 kJ/mol, dpK/dT -0.012, the constants of tui/assets/data/buffer_templates.json)
# moved to 22 °C (the pH taken as set at 22 °C) gives 7.600; Davies (A = 0.509) at the
# self-consistent ionic strength I = 0.088 M gives pK' = 7.497. The deprotonated
# (anionic) fraction of 50 mM is 0.761; with NaOH titration the counter-ion is sodium
# 38.05 mM (σ 2.38 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on
# the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM HEPES, ±2%
    NonBiological(0.05, 0.001, "sodium chloride"),   # 50 mM, ±2%
    # counter-ion of the NaOH titration, 38.05 mM
    NonBiological(0.038051, 0.00238, "sodium"),
    NonBiological(0.005, 0.0001, "dtt"),   # 5 mM DTT, ±2%
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

# Builds the Seed that `runSasdtc5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdtc5` below is the whole story (build the seed, then sample it).
function seedSasdtc5(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdtc5(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdtc5(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdtc5()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log.
# No reference curve and no refChi2 for this entry (see the header).
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    formFactorLog = formFactorLog, nAtoms = nAtoms,
)

# `@__DIR__` (this SASDTC5/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
