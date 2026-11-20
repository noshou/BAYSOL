# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDPV7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPV7.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDPV7_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDPV7_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDPV7: tetracycline-modifying flavin monooxygenase TetX from Stenotrophomonas
# maltophilia (SmTetX, UniProt A0A2Y9UCL1, variant M154I/A283T), monomer, 38.941 kDa, in
# 25 mM Bis-Tris, 150 mM NaCl, pH 6.5 (SASBDB buffer; the paper's SAXS section gives the
# same composition).
#
# Publication: Malý M, Kolenko P, Stránský J, Švecová L, Dušková J, Koval' T, Skálová T,
# Trundová M, Adámková K, Černý J, Božíková P, Dohnálek J, "Tetracycline-modifying enzyme
# SmTetX from Stenotrophomonas maltophilia", Acta Cryst F 2023 (2023 Jul 05), DOI
# 10.1107/S2053230X23005381 (open access; the SAXS methods and the buffer were read).
# Entry: https://www.sasbdb.org/data/SASDPV7/.
#
# Instrument and conditions: Anton Paar SAXSpoint 2.0, Institute of Biotechnology CAS /
# Centre of Molecular Structure (Vestec, Czech Republic), sample-detector distance 0.826
# m, cell and storage temperature 4 °C (SASBDB). `xray_energy` is null; the wavelength is
# SASBDB's `wavelength` 0.134 nm (the field is in nm), 1.34 Å, hc/λ ≈ 9252 eV.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.117 and s_max
# 3.997 nm⁻¹; text lines first, then q, I, σ) and is converted to Å⁻¹ (÷10): 676 points
# from 0.0117 to 0.3997 Å⁻¹, 99 of them with I ≤ 0. q cut, from 0.36 Å⁻¹ (evidence at
# `Q_MAX_FIT`): above it there are 70 points with a median I/σ of 0.41, 29 % of them
# non-positive, and the lowest-q quarter of them has a median I/σ of 0.43 (the README
# rule: n ≥ 20, median below 0.5, at least 25 % non-positive, lowest-q quarter below 1).
# The depositor's CRYSOL curve ends at 0.1503 Å⁻¹ (242 rows), far below the fitted range,
# so the refChi2 is NOT like for like.
#
# Model and depositor fit: SASDPV7 has two fits. fit1 is CRYSOL (chi_square_value 1.05) on
# a "Preliminary model of the structure PDB 8AQ8" (REFMAC output, not the released entry):
# SASDPV7_fit1_model1.pdb has 2665 records (chain C residues 4-358, 53 FAD atoms and one
# chloride ion as HETATM, no hydrogens). fit2 is DAMMIF (dummy atoms; not used). The FAD
# is the enzyme's cofactor and is kept by the loader as a known ligand. The fit file (242
# rows, only up to 0.1503 Å⁻¹; header "Dro:0.037 Ra:1.800 RGT:22.73 Vol: 49900. Chi^2:
# 1.050") recomputed from its columns 2-4 gives χ² = 1.058: the label is χ² and the
# depositor's χ² is 1.05 (SASBDB), over 0.0117-0.1503 Å⁻¹ only.
#
# Flags: 4 °C measurement with the pH assumed set at room temperature; the depositor fit
# covers 0.0117-0.1503 Å⁻¹ only; the model is a preliminary REFMAC model, not the released
# 8AQ8; FAD and one Cl⁻ in the model. The wavelength comes from SASBDB (its `xray_energy`
# is null) except where stated; the whole entry is wired from the files above and has not
# been run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 6.5, PH_METER_SIGMA   # pH 6.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # ≈ 9252 eV, SASBDB wavelength 1.34 Å
const TEMPERATURE_C = 4.0   # SASBDB cell temperature (4 °C)

# Buffer: 25 mM Bis-Tris, 150 mM NaCl, pH 6.5 (paper and SASBDB agree). Bis-Tris is
# titrated with HCl, so its protonated fraction comes with chloride. Method of
# notes/buffer-templates.md (Davies, A = 0.509; pH taken as set at 22 °C although the
# measurement is at 4 °C, no shift modelled): Bis-Tris pK 6.484 (25 °C, ΔH 28.4 kJ/mol,
# ΔCp +27 J/mol/K, Goldberg, Kishore & Lennen 2002, DOI 10.1063/1.1416902, constants of
# tui/assets/data/buffer_templates.json; the template flags this pK as not cross-checked
# against independent values) at the self-consistent I = 0.16 M gives a protonated
# fraction 0.589, i.e. 14.73 mM of chloride (σ 1.69 mM: σ_pH 0.1, ±3 °C, ±0.02 pK and 30 %
# of the Davies shift in quadrature, ±2 % on the concentrations).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "bis-tris"),   # 25 mM Bis-Tris, ±2 %
    NonBiological(0.15, 0.0015, "sodium chloride"),   # 150 mM, ±1 %
    NonBiological(0.014725, 0.0017, "chloride"),   # counter-ion of Bis-Tris-HCl, 14.73 mM
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.36 Å⁻¹ by the README rule, numbers in the Curve units paragraph above (the
# data above it are a noise floor: median I/σ below 0.5, at least 25 % of the points
# non-positive).
const Q_MAX_FIT = 0.36

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdpv7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdpv7` below is the whole story (build the seed, then sample it).
function seedSasdpv7(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpv7(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdpv7(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpv7()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.05",
)

# `@__DIR__` (this SASDPV7/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
