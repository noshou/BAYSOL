# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDTT4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTT4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDTT4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDTT4_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTT4: SLDCP (SnoaL-like domain-containing protein; Sphaerobacter thermophilus
# (strain DSM 20745 / S 6022); 12.105 kDa SASBDB molecule MW, monomer) in the SASBDB
# buffer "20 mM Tris, 150 mM NaCl, 3% glycerol", pH 7.6. Sample: SnoaL-like domain-
# containing protein apoform (SLDCP concentrated monomeric SEC peak).
#
# Publication: Likkei K, Moldenhauer M, Tavraz NN, Egorkin NA, Slonimskiy YB, Maksimov EG,
# Sluchanko NN, Friedrich T, "Elements of the C-terminal tail of a C-terminal domain
# homolog of the Orange Carotenoid Protein determining xanthophyll uptake from
# liposomes.", Biochim Biophys Acta Bioenerg (2024 Mar 23), DOI
# 10.1016/j.bbabio.2024.149043. Entry: https://www.sasbdb.org/data/SASDTT4/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 2M; wavelength 0.124 nm = 1.24 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9999 eV); cell temperature 20.0
# °C; sample-detector distance None m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.1107 to 5.519 1/nm, 1966 points)
# and is converted to Å⁻¹ (÷10); 0 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.409); model:
# pdb 5tgn (identical); SASBDB model software: PDB (Protein Data Bank).
# SASDTT4_fit1_model1.pdb: 824 ATOM records (107 residues, chains A), 840 heavy atoms, no
# hydrogens; HETATM groups kept as ligands: MSE 16 atoms; one structure only.
# The fit file SASDTT4_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "corrstar
# Dro:0.022  Ra:1.800  RGT:14.30  Vol: 14007.  Chi^2: 1.409"; χ² recomputed from the file
# with the data's σ is 1.409 (label 1.409), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.5002 Å⁻¹ only while the data run to 0.5519 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: ligand HETATM groups scattered with the protein; buffer from SASBDB only (paper
# not read); glycerol percentage unit not stated, v/v assumed; whole entry wired from the
# files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.6, PH_METER_SIGMA   # SASBDB pH 7.6 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, SASBDB wavelength 1.24 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM Tris, 150 mM NaCl, 3% glycerol", pH 7.6 (SASBDB). Tris pK 8.072 (25 °C,
# ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.167 M
# gives pK' = 8.278. The protonated fraction of 20 mM is 0.826; with HCl titration the
# counter-ion is chloride 16.53 mM (σ 1.02 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 16.53 mM
    NonBiological(0.016529, 0.00102, "chloride"),
    NonBiological(0.4109, 0.0205, "glycerol"),   # 3 % v/v glycerol (assumed v/v), ±5%
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

# Builds the Seed that `runSasdtt4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdtt4` below is the whole story (build the seed, then sample it).
function seedSasdtt4()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdtt4(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdtt4()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdtt4()

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
    refChi2 = "CRYSOL 1.409",
)

# `@__DIR__` (this SASDTT4/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
