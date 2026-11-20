# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVR6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVR6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVR6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVR6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVR6: human vacuolar protein sorting-associated protein 26C (VPS26C, UniProt
# O14972, 33.01 kDa, monomer) in 50 mM Tris, 150 mM NaCl, 1 mM TCEP, pH 7.5 (SASBDB
# buffer; the paper's SAXS section names the same composition).
#
# Publication: Martín-González A, Méndez-Guzmán I, Zabala-Zearreta M, Quintanilla A,
# García-López A, Martínez-Lombardía E, Albesa-Jové D, Acosta J, Lucas M, "Selective cargo
# and membrane recognition by SNX17 regulates its interaction with Retriever", EMBO
# Reports 2024 (2024 Dec 09), DOI 10.1038/s44319-024-00340-1 (open access; the SAXS
# methods and the buffer were read). Entry: https://www.sasbdb.org/data/SASDVR6/.
#
# Instrument and conditions: Diamond Light Source B21, SEC-SAXS, sample-detector distance
# 3.69 m, cell temperature 25 °C (SASBDB; storage -80 °C). `xray_energy` is null; the
# wavelength is SASBDB's `wavelength` 0.0954 nm (the field is in nm), 0.954 Å, hc/λ ≈ 12
# 996 eV.
#
# Curve units: the SASBDB .dat is labelled "1/A" and its values (q from 0.0045 to 0.34
# Å⁻¹, 2555 points) are in Å⁻¹ already, so no conversion is applied (`checkQAngstrom`
# guards the range); 197 points have I ≤ 0. q cut, from 0.26 Å⁻¹ (evidence at
# `Q_MAX_FIT`): above it there are 610 points with a median I/σ of 0.44, 30 % of them
# non-positive, and the lowest-q quarter of them has a median I/σ of 0.91 (the README
# rule: n ≥ 20, median below 0.5, at least 25 % non-positive, lowest-q quarter below 1;
# the lowest-q quarter is close to the limit). The depositor's CRYSOL curve covers the
# whole 0.0045-0.34 Å⁻¹, so the refChi2 (all 2555 points) is not like for like: over q ≤
# 0.26 Å⁻¹ the same fit has χ² 1.202.
#
# Model and depositor fit: SASDVR6 has two fits. fit1 is CRYSOL (chi_square_value 1.152)
# on an AlphaFold v2.0 prediction of VPS26C (header "ALPHAFOLD V2.0 PREDICTION FOR
# VACUOLAR PROTEIN SORTING-ASSOCIATED PROTEIN 26C"): SASDVR6_fit1_model1.pdb has 2319 ATOM
# records (chain A residues 1-297), no hydrogens. fit2 is DAMMIN (dummy atoms; not used).
# The fit file has THREE columns (q, I_exp, I_fit; no σ), 2555 data rows from 0.0045 Å⁻¹
# after the q = 0 placeholder row (header "Dro:0.030 Ra:1.800 RGT:26.61 Vol: 44578. Chi^2:
# 1.152"); χ² recomputed with the data's σ gives 1.152 (label χ²), so the reference curve
# is column 3. An unrefined AlphaFold model, so the fit measures the prediction against
# the solution.
#
# Flags: AlphaFold prediction (no experimental structure); fit file has three columns;
# TCEP taken as a neutral solute row. The wavelength comes from SASBDB (its `xray_energy`
# is null) except where stated; the whole entry is wired from the files above and has not
# been run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.954   # ≈ 12 996 eV, SASBDB wavelength 0.954 Å
const TEMPERATURE_C = 25.0   # SASBDB cell temperature (storage -80 °C)

# Buffer: 50 mM Tris, 150 mM NaCl, 1 mM TCEP, pH 7.5 (paper and SASBDB agree). Computed
# with the amine method of notes/buffer-templates.md (Davies, A = 0.509; the pH is taken
# as set at 22 °C and no shift of the pH to the measuring temperature is modelled): Tris
# pK 8.072 (25 °C, ΔH 47.45 kJ/mol, ΔCp -59 J/mol/K, the constants of
# tui/assets/data/buffer_templates.json), self-consistent ionic strength I = 0.19 M
# (Davies is at the edge of its range there). The pH is set with HCl, so the protonated
# fraction (0.858) of the amine comes with a chloride counter-ion: 0.858 x 50 mM = 42.92
# mM. σ = 2.10 mM (σ_pH 0.1, ±3 °C, ±0.02 pK and 30 % of the Davies shift in quadrature,
# and ±2 % on the concentrations).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2 %
    NonBiological(0.15, 0.0015, "sodium chloride"),   # 150 mM, ±1 %
    NonBiological(0.001, 2e-05, "tcep"),   # 1 mM, ±2 %
    NonBiological(0.042919, 0.0021, "chloride"),   # counter-ion of Tris-HCl, 42.92 mM
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.26 Å⁻¹ by the README rule, numbers in the Curve units paragraph above (the
# data above it are a noise floor: median I/σ below 0.5, at least 25 % of the points
# non-positive).
const Q_MAX_FIT = 0.26

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

# Builds the Seed that `runSasdvr6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvr6` below is the whole story (build the seed, then sample it).
function seedSasdvr6(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvr6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvr6(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvr6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, I_fit (no σ).
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 3]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.152",
)

# `@__DIR__` (this SASDVR6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
