# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDNL8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNL8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNL8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNL8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDNL8: human histone-lysine N-methyltransferase NSD3 (UniProt Q9BZ95), the
# PWWP2-SET construct, 43.242 kDa, monomer, in 0.5 M NaCl, 20 mM Tris-HCl, 5 mM DTT, pH
# 8.5 (SASBDB buffer; the paper gives the same composition for the SAXS runs).
#
# Publication: Belviso BD, Shen Y, Carrozzini B, Morishita M, di Luccio E, Caliandro R,
# "Structural insights into the C-terminus of the histone-lysine N-methyltransferase NSD3
# by small-angle X-ray scattering", Front Mol Biosci 2024, DOI 10.3389/fmolb.2024.1191246,
# PMID 38516186 (open access; the buffer was read). SASDNK8 and SASDNL8 are the two NSD3
# constructs of that paper and share the buffer. Entry:
# https://www.sasbdb.org/data/SASDNL8/.
#
# Instrument and conditions: Diamond Light Source B21, SEC-SAXS, sample-detector distance
# 4.014 m, cell and storage temperature 20 °C (SASBDB). `xray_energy` is null; the
# wavelength is SASBDB's `wavelength` 0.1 nm (the field is in nm), 1.0 Å, hc/λ ≈ 12 398
# eV.
#
# Curve units: the SASBDB .dat is labelled "1/A" and its values (q from 0.0026 to 0.2321
# Å⁻¹, 737 points) are in Å⁻¹ already, so no conversion is applied (`checkQAngstrom`
# guards the range); 61 points have I ≤ 0 (`seedModel` drops the non-positive bins). The
# whole curve is fitted: the README's q-cut rule is not met (the curve ends at 0.2321 Å⁻¹
# and no cut qualifies).
#
# Model and depositor fit: SASDNL8 has two fits. fit1 is CRYSOL (chi_square_value 1.066)
# on a model that SASBDB describes as "RaptorX optimized against SAXS data by Molecular
# Dynamics Flexible Fitting (MDFF)" (type "Other", not a PDB entry):
# SASDNL8_fit1_model1.pdb has 3033 ATOM records (chain A residues 942-1318, chain C
# residues 1-3), no HETATM, no hydrogens; the zinc of the zinc-binding region is NOT in
# the model (as received). fit2 is DAMMIN (dummy atoms; not used). The fit file (666 rows,
# 0.0119-0.2321 Å⁻¹; header "Dro:0.048 Ra:1.780 RGT:31.69 Vol: 56904. Chi^2: 1.066")
# recomputed from its columns 2-4 gives χ² = 1.066 (label χ²). The model was fitted to
# this very curve (MDFF).
#
# Flags: MDFF model refitted to these SAXS data, no zinc; the depositor's curve starts at
# 0.0119 Å⁻¹ while the data start at 0.0026 Å⁻¹ (refChi2 is not like for like at low q).
# The wavelength comes from SASBDB (its `xray_energy` is null) except where stated; the
# whole entry is wired from the files above and has not been run.
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

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdnl8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdnl8` below is the whole story (build the seed, then sample it).
function seedSasdnl8(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdnl8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdnl8(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdnl8()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.066",
)

# `@__DIR__` (this SASDNL8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
