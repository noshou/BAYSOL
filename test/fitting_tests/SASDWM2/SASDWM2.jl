# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDWM2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWM2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWM2_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWM2_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWM2: PRT1 (E3 ubiquitin-protein ligase PRT1; Arabidopsis thaliana; 45.936 kDa
# SASBDB molecule MW, monomer) in the SASBDB buffer "50 mM Tris-HCl, 150 mM NaCl, 1 mM
# TCEP, 2% w/v glycerol", pH 7.5. Sample: Wild-type E3 ubiquitin-protein ligase PRT1
# (Proteolysis1).
#
# Publication: Yang W, Kim S, Kim M, Shin H, Lee J, Sandmann A, Park O, Dissmeyer N, Song
# H, "Structural basis for the recognition and ubiquitylation of type-2 N-degron substrate
# by PRT1 plant N-recognin", Nature Communications (2025 Aug 21), DOI
# 10.1038/s41467-025-63282-9. Entry: https://www.sasbdb.org/data/SASDWM2/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Photon Factory (PF), High Energy Accelerator
# Research Organization (KEK), Tsukuba, beamline BL-10C, X-ray synchrotron, detector
# Pilatus3 2M; wavelength 0.15 nm = 1.5 Å (the `wavelength` field is in nm; `xray_energy`
# is null, so the energy is hc/λ ≈ 8266 eV); cell temperature 25.0 °C; sample-detector
# distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.003329 to 0.2809 1/A, 1170 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 128 points have I ≤ 0. q cut at 0.1847 Å⁻¹ (README rule): above it there are 405 points
# with a median I/σ of 0.50, 31 % of them non-positive, and the lowest-q quarter of them
# has a median I/σ of 0.86.
#
# Model and depositor fit: fit 2 of the entry is CRYSOL (chi_square_value 1.734); model:
# alphafold Q8LBL5 (identical); SASBDB model software: AlphaFold Protein Structure
# Database. SASDWM2_fit2_model1.pdb: 3200 ATOM records (410 residues, chains A), 3206
# heavy atoms, no hydrogens; HETATM groups kept as ligands: ZN 6 atoms; one structure
# only.
# The fit file SASDWM2_fit2.fit has 4 columns (q, I_exp, σ, I_fit), header "PRT1_Zn.
# Dro:0.010  Ra:1.800  RGT:39.56  Vol: 60633.  Chi^2: 1.734"; χ² recomputed from the file
# with the data's σ is 1.728 (label 1.734), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: AlphaFold prediction (no experimental structure); ligand HETATM groups scattered
# with the protein; buffer from SASBDB only (paper not read); 25 °C is the SASBDB cell
# temperature; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, SASBDB wavelength 1.5 Å
const TEMPERATURE_C = 25.0   # SASBDB cell temperature

# Buffer "50 mM Tris-HCl, 150 mM NaCl, 1 mM TCEP, 2% w/v glycerol", pH 7.5 (SASBDB).
# Tris pK 8.072 (25 °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.193 M
# gives pK' = 8.282. The protonated fraction of 50 mM is 0.858; with HCl titration the
# counter-ion is chloride 42.91 mM (σ 2.24 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 42.91 mM
    NonBiological(0.042905, 0.00224, "chloride"),
    NonBiological(0.001, 2e-05, "tcep"),   # 1 mM TCEP, ±2%
    NonBiological(0.2172, 0.0109, "glycerol"),   # 2 % w/v glycerol (w/v as stated), ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.1847 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.50, 31 % of the points non-positive).
const Q_MAX_FIT = 0.1847

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

# Builds the Seed that `runSasdwm2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdwm2` below is the whole story (build the seed, then sample it).
function seedSasdwm2()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwm2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdwm2()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwm2()

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
    refChi2 = "CRYSOL 1.734",
)

# `@__DIR__` (this SASDWM2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
