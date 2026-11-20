# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDSU8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSU8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDSU8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDSU8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDSU8: Tha1 (L-threonine aldolase; Mus musculus; 41.366 kDa SASBDB molecule MW,
# tetramer) in the SASBDB buffer "20 mM Tris, 150 mM NaCl, 1 mM EDTA, 1 mM DTT", pH 7.8.
# Sample: Threonine aldolase 1 tetramer at neutral pH.
#
# Publication: Malatesta M, Fornasier E, Di Salvo ML, Tramonti A, Zangelmi E, Peracchi A,
# Secchi A, Polverini E, Giachin G, Battistutta R, Contestabile R, Percudani R, "One
# substrate many enzymes virtual screening uncovers missing genes of carnitine
# biosynthesis in human and mouse.", Nat Commun (2024 Apr 13), DOI
# 10.1038/s41467-024-47466-3. Entry: https://www.sasbdb.org/data/SASDSU8/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus3 2M; wavelength 0.099 nm = 0.99 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 12524 eV); cell temperature 20.0 °C;
# sample-detector distance 2.867 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.09441 to 3.145 1/nm, 592 points)
# and is converted to Å⁻¹ (÷10); 4 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.145); model:
# SASBDB model software: Phenix. SASDSU8_fit1_model1.pdb: 10976 ATOM records (1444
# residues, chains ABCD), 11130 heavy atoms, no hydrogens; HETATM groups kept as ligands:
# LLP 96 atoms; one structure only.
# The fit file SASDSU8_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.100
# Rg: 34.91 Vol: 195744. Chi^2: 1.145"; χ² recomputed from the file with the data's σ is
# 1.143 (label 1.145), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: large structure (11130 heavy atoms); ligand HETATM groups scattered with the
# protein; buffer from SASBDB only (paper not read); whole entry wired from the files
# above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.8, PH_METER_SIGMA   # SASBDB pH 7.8 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12524 eV, SASBDB wavelength 0.99 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM Tris, 150 mM NaCl, 1 mM EDTA, 1 mM DTT", pH 7.8 (SASBDB). Tris pK 8.072
# (25 °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.165 M
# gives pK' = 8.278. The protonated fraction of 20 mM is 0.750; with HCl titration the
# counter-ion is chloride 15.00 mM (σ 1.28 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 15.00 mM
    NonBiological(0.015004, 0.00128, "chloride"),
    NonBiological(0.001, 2e-05, "H2EDTA"),   # 1 mM EDTA as H2EDTA, ±2%
    NonBiological(0.002, 4e-05, "sodium"),   # the two Na+ of Na2EDTA, ±2%
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, ±2%
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

# Builds the Seed that `runSasdsu8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdsu8` below is the whole story (build the seed, then sample it).
function seedSasdsu8(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdsu8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdsu8(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdsu8()

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
    refChi2 = "CRYSOL 1.145",
)

# `@__DIR__` (this SASDSU8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
