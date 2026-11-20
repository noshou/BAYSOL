# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDNP5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNP5.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNP5_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNP5_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDNP5: human TEX12 (testis-expressed protein 12, UniProt Q9BXU0), the
# coiled-coil tetramer (4 x 7.938 kDa), in 20 mM Tris, 150 mM KCl, pH 8.0 (the paper's
# SEC-SAXS buffer; SASBDB agrees).
#
# Publication: Dunce J, Salmon L, Davies O, "Coiled-coil structure of meiosis protein
# TEX12 and conformational regulation by its C-terminal tip", Communications Biology 2022
# (2022 Sep 07), DOI 10.1038/s42003-022-03886-9 (open access; the SAXS methods and the
# buffer were read). Entry: https://www.sasbdb.org/data/SASDNP5/.
#
# Instrument and conditions: Diamond Light Source B21, SEC-SAXS, sample-detector distance
# 4.014 m. Energy: the paper's 12.4 keV (SASBDB `wavelength` 0.095 nm would be 13.05 keV;
# the 12.4 keV of the paper is used). Temperature: stated neither in SASBDB
# (`cell_temperature` null) nor, in what was read, in the paper; 25 °C is the project's
# flagged default for an unknown temperature.
#
# Curve units: the SASBDB .dat is labelled "1/A" and its values (q from 0.0034 to 0.3696
# Å⁻¹, 1658 points) are in Å⁻¹ already, so no conversion is applied (`checkQAngstrom`
# guards the range); 3 points have I ≤ 0. The whole curve is fitted: the README's q-cut
# rule is not met.
#
# Model and depositor fit: SASDNP5 has two fits. fit1 is DAMMIF (dummy atoms; not used);
# fit2 is CRYSOL (chi_square_value 1.535) on the atomic model that SASBDB declares
# identical to PDB 6HK8 (TEX12 coiled-coil tetramer): SASDNP5_fit2_model1.pdb has 2444
# records in four TER-separated chains that reuse the ids A, B, A, B (the loader relabels
# them), residues about 47-113 each, 66 atoms with an alternate location, and 236
# hydrogens on 11 C-terminal residues only (the rest of the model has none). The fit file
# (1658 rows to 0.3696 Å⁻¹; header "Dro:0.075 Ra:1.400 RGT:31.96 Vol: 40977. Chi^2:
# 1.535") recomputed from its columns 2-4 gives χ² = 1.535 (label χ², same q range as the
# fit here). The depositor's χ² is high for a crystal structure of a tetramer in solution.
#
# Flags: temperature not stated (25 °C default); energy from the paper; the model carries
# alternate locations and partial hydrogens (11 C-terminal residues) and reuses chain ids
# in its four TER blocks. The wavelength comes from SASBDB (its `xray_energy` is null)
# except where stated; the whole entry is wired from the files above and has not been run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = 12400.0   # the paper's 12.4 keV (not SASBDB's 0.095 nm)
const TEMPERATURE_C = 25.0      # NOT STATED anywhere: the project's flagged default

# Buffer: 20 mM Tris, 150 mM KCl, pH 8.0 (paper and SASBDB agree). Computed with the amine
# method of notes/buffer-templates.md (Davies, A = 0.509; the pH is taken as set at 22 °C
# and no shift of the pH to the measuring temperature is modelled): Tris pK 8.072 (25 °C,
# ΔH 47.45 kJ/mol, ΔCp -59 J/mol/K, the constants of
# tui/assets/data/buffer_templates.json), self-consistent ionic strength I = 0.16 M
# (Davies is at the edge of its range there). The pH is set with HCl, so the protonated
# fraction (0.655) of the amine comes with a chloride counter-ion: 0.655 x 20 mM = 13.10
# mM. σ = 1.45 mM (σ_pH 0.1, ±3 °C, ±0.02 pK and 30 % of the Davies shift in quadrature,
# and ±2 % on the concentrations).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2 %
    NonBiological(0.15, 0.0015, "potassium chloride"),   # 150 mM, ±1 %
    NonBiological(0.013097, 0.0014, "chloride"),   # counter-ion of Tris-HCl, 13.10 mM
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# pdb2pqr/PROPKA place the hydrogens at PH (the model has them on 11 C-terminal
# residues only).
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

# Builds the Seed that `runSasdnp5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdnp5` below is the whole story (build the seed, then sample it).
function seedSasdnp5(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdnp5(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdnp5(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdnp5()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.535",
)

# `@__DIR__` (this SASDNP5/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
