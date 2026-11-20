# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDSN8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSN8.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDSN8_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDSN8_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDSN8: Pro-Nivolumab, Lu02 (Pro-Nivolumab, Lu02; None; 54.366 kDa SASBDB
# molecule MW, monomer) in the SASBDB buffer "20 mM Tris, 100 mM NaCl", pH 8.0. Sample:
# Pro-Nivolumab, Lu02.
#
# Publication: Liao JM, Hong ST, Wang YT, Cheng YA, Ho KW, Toh SI, Shih O, Jeng US, Lyu
# PC, Hu IC, Huang MY, Chang CY, Cheng TL, "Integrating molecular dynamics simulation with
# small- and wide-angle X-ray scattering to unravel the flexibility, antigen-blocking, and
# protease-restoring functions in a hindrance-based pro-antibody.", Protein Sci (2024
# Sep), DOI 10.1002/pro.5124. Entry: https://www.sasbdb.org/data/SASDSN8/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): NSRRC, Hsinchu, beamline TPS13A, X-ray synchrotron,
# detector Eiger X 1M & 9M; wavelength 0.16 nm = 1.6 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 7749 eV); cell temperature 10.0 °C;
# sample-detector distance 2.5 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.01153 to 1.474 1/A, 539 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 0
# points have I ≤ 0. No q cut (the README noise-floor rule is not met: whole curve, σ > 0
# points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.876); model:
# SASBDB model software: AMBER. SASDSN8_fit1_model1.pdb: 7521 ATOM records (510 residues,
# chains  ), 3822 heavy atoms, 3699 hydrogens (replaced by pdb2pqr/PROPKA); one structure
# only.
# The fit file SASDSN8_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.013
# Rg: 29.93 Vol:  67320. Chi^2: 1.876"; χ² recomputed from the file with the data's σ is
# 1.873 (label 1.876), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
# The depositor fit covers q ≤ 1.396 Å⁻¹ only while the data run to 1.474 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: buffer from SASBDB only (paper not read); whole entry wired from the files above;
# not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB pH 8.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.6   # ≈ 7749 eV, SASBDB wavelength 1.6 Å
const TEMPERATURE_C = 10.0   # SASBDB cell temperature

# Buffer "20 mM Tris, 100 mM NaCl", pH 8.0 (SASBDB). Tris pK 8.072 (25 °C, ΔH 47.45
# kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.113 M gives pK' = 8.266. The protonated fraction of 20
# mM is 0.649; with HCl titration the counter-ion is chloride 12.98 mM (σ 1.49 mM: σ_pH
# 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM, ±2%
    # counter-ion of the HCl titration, 12.98 mM
    NonBiological(0.012975, 0.00149, "chloride"),
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

# Builds the Seed that `runSasdsn8` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdsn8` below is the whole story (build the seed, then sample it).
function seedSasdsn8(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdsn8(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdsn8(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdsn8()

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
    refChi2 = "CRYSOL 1.876",
)

# `@__DIR__` (this SASDSN8/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
