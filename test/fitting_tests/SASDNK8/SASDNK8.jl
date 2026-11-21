# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDNK8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNK8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNK8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNK8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDNK8: human histone-lysine N-methyltransferase NSD3 (UniProt Q9BZ95), the
# PWWP2-SET-containing C-terminal construct, 40.109 kDa, monomer, in 0.5 M NaCl, 20 mM
# Tris-HCl, 5 mM DTT, pH 8.5 (SASBDB buffer; the paper gives the same composition for the
# SAXS runs).
#
# Publication: Belviso BD, Shen Y, Carrozzini B, Morishita M, di Luccio E, Caliandro R,
# "Structural insights into the C-terminus of the histone-lysine N-methyltransferase NSD3
# by small-angle X-ray scattering", Front Mol Biosci 2024, DOI 10.3389/fmolb.2024.1191246,
# PMID 38516186 (open access; the buffer was read). SASDNK8 and SASDNL8 are the two NSD3
# constructs of that paper and share the buffer. Entry:
# https://www.sasbdb.org/data/SASDNK8/.
#
# Instrument and conditions: Diamond Light Source B21, SEC-SAXS, sample-detector distance
# 4.014 m, cell and storage temperature 20 °C (SASBDB). `xray_energy` is null; the
# wavelength is SASBDB's `wavelength` 0.1 nm (the field is in nm), 1.0 Å, hc/λ ≈ 12 398
# eV.
#
# Curve units: the SASBDB .dat is labelled "1/A" and its values (q from 0.0027 to 0.2894
# Å⁻¹, 732 points) are in Å⁻¹ already, so no conversion is applied (`checkQAngstrom`
# guards the range); 96 points have I ≤ 0, dropped by `seedModel` where they survive the
# cut. q cut, from 0.25 Å⁻¹ (evidence at `Q_MAX_FIT`): above it there are 101 points with
# a median I/σ of 0.34, 36 % of them non-positive, and the lowest-q quarter of them has a
# median I/σ of 0.55 (the README rule: n ≥ 20, median below 0.5, at least 25 %
# non-positive, lowest-q quarter below 1). The data and the depositor's CRYSOL curve both
# end at 0.2894 Å⁻¹, so the refChi2 covers 0.0114-0.2894 Å⁻¹ while the fit here stops at
# 0.25 Å⁻¹: not like for like.
#
# Model and depositor fit: SASDNK8 has two fits. fit1 is CRYSOL (chi_square_value 1.228)
# on a model that SASBDB describes as "RaptorX optimized against SAXS data by Molecular
# Dynamics Flexible Fitting (MDFF)" (type "Other", not a PDB entry):
# SASDNK8_fit1_model1.pdb has 2806 ATOM records (chain A residues 1070-1424, chain C
# residues 1-7), no HETATM, no hydrogens; the zinc of the SET-associated zinc-binding
# region is NOT in the model (as received). fit2 is DAMMIN (dummy atoms; not used). The
# fit file (710 rows, 0.0114-0.2894 Å⁻¹; header "Dro:0.075 Ra:1.800 RGT:33.69 Vol: 52410.
# Chi^2: 1.228") recomputed from its columns 2-4 gives χ² = 1.23 (label χ²). The model was
# fitted to this very curve (MDFF), so χ² is a goodness of an adapted model, not a
# prediction.
#
# Flags: MDFF model refitted to these SAXS data, no zinc; the construct (PWWP2-SET) may
# carry a disordered N-terminal region not in the model (SASBDB model MW 40.55 kDa vs
# 40.109 kDa). The wavelength comes from SASBDB (its `xray_energy` is null) except where
# stated; the whole entry is wired from the files above and has not been run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.5, PH_METER_SIGMA   # pH 8.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.0   # ≈ 12 398 eV, SASBDB wavelength 1.0 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer: 0.5 M NaCl, 20 mM Tris-HCl, 5 mM DTT, pH 8.5 (SASBDB and the paper agree).
# Computed with the amine method of notes/buffer-templates.md (Davies, A = 0.509; the pH
# is taken as set at 22 °C and no shift of the pH to the measuring temperature is
# modelled): Tris pK 8.072 (25 °C, ΔH 47.45 kJ/mol, ΔCp -59 J/mol/K, the constants of
# tui/assets/data/buffer_templates.json), self-consistent ionic strength I = 0.51 M
# (Davies is at the edge of its range there). The pH is set with HCl, so the protonated
# fraction (0.382) of the amine comes with a chloride counter-ion: 0.382 x 20 mM = 7.64
# mM. σ = 1.51 mM (σ_pH 0.1, ±3 °C, ±0.02 pK and 30 % of the Davies shift in quadrature,
# and ±2 % on the concentrations).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2 %
    NonBiological(0.5, 0.005, "sodium chloride"),   # 500 mM, ±1 %
    NonBiological(0.005, 0.0001, "dtt"),   # 5 mM, ±2 %
    NonBiological(0.007638, 0.0015, "chloride"),   # counter-ion of Tris-HCl, 7.64 mM
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.25 Å⁻¹ by the README rule, numbers in the Curve units paragraph above (the
# data above it are a noise floor: median I/σ below 0.5, at least 25 % of the points
# non-positive).
const Q_MAX_FIT = 0.25

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

# Builds the Seed that `runSasdnk8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdnk8` below is the whole story (build the seed, then sample it).
function seedSasdnk8()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdnk8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdnk8()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdnk8()

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
    refChi2 = "CRYSOL 1.228",
)

# `@__DIR__` (this SASDNK8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
