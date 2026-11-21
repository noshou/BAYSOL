# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDSQ9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSQ9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDSQ9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDSQ9_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDSQ9: NanoLuc (Oplophorus-luciferin 2-monooxygenase catalytic subunit;
# Oplophorus gracilirostris; 20.365 kDa SASBDB molecule MW, monomer) in the SASBDB buffer
# "10 mM Tris-HCl, 50 mM NaCl", pH 7.5. Sample: NanoLuc luciferase.
#
# Publication: Nemergut M, Pluskal D, Horackova J, Sustrova T, Tulis J, Barta T, Baatallah
# R, Gagnot G, Novakova V, Majerova M, Sedlackova K, Marques SM, Toul M, Damborsky J,
# Prokop Z, Bednar D, Janin YL, Marek M, "Illuminating the mechanism and allosteric
# behavior of NanoLuc luciferase.", Nat Commun (2023 Nov 29), DOI
# 10.1038/s41467-023-43403-y. Entry: https://www.sasbdb.org/data/SASDSQ9/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): CEITEC, Brno, beamline Rigaku BioSAXS-2000, X-ray in
# house, detector Rigaku HyPix-3000; wavelength 0.154 nm = 1.54 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 8051 eV); cell temperature 20.0
# °C; sample-detector distance 0.48 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.02671 to 0.4003 1/A, 261 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 9
# points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ > 0
# points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.216); model:
# pdb 8aq6 (identical); SASBDB model software: PDB (Protein Data Bank).
# SASDSQ9_fit1_model1.pdb: 1355 ATOM records (171 residues, chains A), 1484 heavy atoms,
# no hydrogens, 12 alternate-location records; HETATM groups kept as ligands: GOL 6 atoms,
# PG4 39 atoms, OXY 2 atoms, CL 3 atoms; one structure only. PDB title: "HEADER
# LUMINESCENT PROTEIN                     11-AUG-22   8AQ6".
# The fit file SASDSQ9_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "8aq6-A.p
# Dro:0.060  Ra:1.800  RGT:18.00  Vol: 23441.  Chi^2: 1.216"; χ² recomputed from the file
# with the data's σ is 1.216 (label 1.216), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: alternate locations in the model; ligand HETATM groups scattered with the
# protein; buffer from SASBDB only (paper not read); whole entry wired from the files
# above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # ≈ 8051 eV, SASBDB wavelength 1.54 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "10 mM Tris-HCl, 50 mM NaCl", pH 7.5 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.058 M gives pK' = 8.246. The protonated fraction of 10
# mM is 0.848; with HCl titration the counter-ion is chloride 8.48 mM (σ 0.46 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "tris"),   # 10 mM Tris, ±2%
    NonBiological(0.05, 0.001, "sodium chloride"),   # 50 mM, ±2%
    # counter-ion of the HCl titration, 8.48 mM
    NonBiological(0.008478, 0.000462, "chloride"),
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

# Builds the Seed that `runSasdsq9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdsq9` below is the whole story (build the seed, then sample it).
function seedSasdsq9()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdsq9(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdsq9()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdsq9()

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
    refChi2 = "CRYSOL 1.216",
)

# `@__DIR__` (this SASDSQ9/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
