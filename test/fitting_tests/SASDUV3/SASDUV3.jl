# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDUV3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUV3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDUV3_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDUV3_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUV3: LrpA (LPXTG-motif cell wall anchor domain protein; Ligilactobacillus
# ruminis ATCC 25644; 48.969 kDa SASBDB molecule MW, monomer) in the SASBDB buffer "20 mM
# Tris, 150 mM NaCl", pH 8.0. Sample: SAXS analysis of the LrpA backbone-Pilin Subunit
# from Ligilactobacillus ruminis.
#
# Publication: Prajapati A, Palva A, von Ossowski I, Krishnan V, "The crystal structure of
# the N-terminal domain of the backbone pilin LrpA reveals a new closure-and-twist motion
# for assembling dynamic pili in Ligilactobacillus ruminis", Acta Crystallographica
# Section D Structural Biology (2024 Jun 27), DOI 10.1107/S2059798324005114. Entry:
# https://www.sasbdb.org/data/SASDUV3/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.123983 nm = 1.24 Å (the `wavelength`
# field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 10000 eV); cell
# temperature 20.0 °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.1851 to 3.348 1/nm, 1142 points)
# and is converted to Å⁻¹ (÷10); 0 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.435); model:
# SASBDB model software: AlphaFold. SASDUV3_fit1_model1.pdb: 3317 ATOM records (437
# residues, chains A), 3317 heavy atoms, no hydrogens; one structure only. PDB title:
# "HEADER                                            01-JUN-22".
# The fit file SASDUV3_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.000
# Rg: 34.07 Vol:  58837. Chi^2: 1.435"; χ² recomputed from the file with the data's σ is
# 1.433 (label 1.435), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
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

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.2398   # ≈ 10000 eV, SASBDB wavelength 1.2398 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM Tris, 150 mM NaCl", pH 8.0 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.163 M gives pK' = 8.277. The protonated fraction of 20
# mM is 0.654; with HCl titration the counter-ion is chloride 13.09 mM (σ 1.49 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 13.09 mM
    NonBiological(0.013087, 0.00149, "chloride"),
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

# Builds the Seed that `runSasduv3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasduv3` below is the whole story (build the seed, then sample it).
function seedSasduv3(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasduv3(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasduv3(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasduv3()

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
    refChi2 = "CRYSOL 1.435",
)

# `@__DIR__` (this SASDUV3/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
