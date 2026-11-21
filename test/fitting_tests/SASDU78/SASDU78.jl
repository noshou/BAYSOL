# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDU78")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDU78.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDU78_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDU78_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDU78: VFT2 (adenylate cyclase; Trypanosoma brucei; 42.755 kDa SASBDB molecule
# MW, monomer) in the SASBDB buffer "50 mM Tris-HCl, 500 mM NaCl", pH 8.0. Sample:
# Trypanosoma brucei ESAG4 membrane-proximal Venus Fly Trap domain 2 (VFT2).
#
# Publication: Alves DO, Geens R, da Silva Arruda HR, Jennen L, Corthaut S, Wuyts E, de
# Andrade GC, Prosdocimi F, Cordeiro Y, Pires JR, Vieira LR, de Oliveira GAP, Sterckx YG,
# Salmon D, "Biophysical analysis of the membrane-proximal Venus Flytrap domain of ESAG4
# receptor-like adenylate cyclase from Trypanosoma brucei.", Mol Biochem Parasitol (2024
# Dec), DOI 10.1016/j.molbiopara.2024.111653. Entry: https://www.sasbdb.org/data/SASDU78/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus 1M; wavelength 0.099 nm = 0.99 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 12524 eV); cell temperature 20.0 °C;
# sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.006285 to 0.521 1/A, 1000 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 0 points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ >
# 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.351); model:
# SASBDB model software: AlphaFold. SASDU78_fit1_model1.pdb: 5825 ATOM records (380
# residues, chains A), 2927 heavy atoms, 2898 hydrogens (replaced by pdb2pqr/PROPKA); one
# structure only.
# The fit file SASDU78_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "ESGA4_VF
# Dro:0.015  Ra:1.460  RGT:22.35  Vol: 53584.  Chi^2: 1.351"; χ² recomputed from the file
# with the data's σ is 1.378 (label 1.351), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
# The depositor fit covers q ≤ 0.4452 Å⁻¹ only while the data run to 0.521 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12524 eV, SASBDB wavelength 0.99 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "50 mM Tris-HCl, 500 mM NaCl", pH 8.0 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.533 M gives pK' = 8.289. The protonated fraction of 50
# mM is 0.661; with HCl titration the counter-ion is chloride 33.03 mM (σ 3.72 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.5, 0.01, "sodium chloride"),   # 500 mM, ±2%
    # counter-ion of the HCl titration, 33.03 mM
    NonBiological(0.033027, 0.00372, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The model has hydrogens, replaced here: pdb2pqr/PROPKA place them at PH.
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

# Builds the Seed that `runSasdu78` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdu78` below is the whole story (build the seed, then sample it).
function seedSasdu78()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdu78(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdu78()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdu78()

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
    refChi2 = "CRYSOL 1.351",
)

# `@__DIR__` (this SASDU78/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
