# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVG6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVG6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVG6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVG6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVG6: NnhA (2-nitroimidazole nitrohydrolase (T2I, G14D, K73R); Mycobacterium
# sp. (strain JS330); 43.08 kDa SASBDB molecule MW, hexamer) in the SASBDB buffer "25 mM
# Tris-HCl, 150 mM NaCl, 5% (v/v) glycerol", pH 7.6. Sample: 2-nitroimidazole
# nitrohydrolase.
#
# Publication: Ahmed FH, Liu JW, Royan S, Warden AC, Esquirol L, Pandey G, Newman J, Scott
# C, Peat TS, "Structural insights into the enzymatic breakdown of azomycin-derived
# antibiotics by 2-nitroimdazole hydrolase (NnhA).", Commun Biol (2024 Dec 19), DOI
# 10.1038/s42003-024-07336-6. Entry: https://www.sasbdb.org/data/SASDVG6/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH; comment: TBS+G); the publication was
# NOT read for this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Australian Synchrotron, Melbourne, beamline BioSAXS,
# X-ray synchrotron, detector Pilatus3 X 2M; wavelength 0.1 nm = 1 Å (the `wavelength`
# field is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 12398 eV); cell
# temperature 25.0 °C; sample-detector distance 3.151 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.006751 to 0.3998 1/A, 840 points)
# and is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range);
# 245 points have I ≤ 0. q cut at 0.1178 Å⁻¹ (README rule): above it there are 603 points
# with a median I/σ of 0.13, 41 % of them non-positive, and the lowest-q quarter of them
# has a median I/σ of 1.00.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 2.404); model:
# SASBDB model software: REFMAC. SASDVG6_fit1_model1.pdb: 17628 ATOM records (2214
# residues, chains ABCDEF), 19390 heavy atoms, no hydrogens, 555 alternate-location
# records; HETATM groups kept as ligands: GOL 24 atoms, NA 3 atoms, CL 2 atoms; one
# structure only. PDB title: "HEADER    ----                                    25-AUG-15
# xxxx".
# The fit file SASDVG6_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.051
# Rg: 44.17 Vol: 306365. Chi^2: 2.404"; χ² recomputed from the file with the data's σ is
# 2.402 (label 2.404), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
#
# Flags: large structure (19390 heavy atoms); alternate locations in the model; ligand
# HETATM groups scattered with the protein; buffer from SASBDB only (paper not read); 25
# °C is the SASBDB cell temperature; glycerol percentage unit not stated, v/v assumed;
# whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.6, PH_METER_SIGMA   # SASBDB pH 7.6 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1   # ≈ 12398 eV, SASBDB wavelength 1 Å
const TEMPERATURE_C = 25.0   # SASBDB cell temperature

# Buffer "25 mM Tris-HCl, 150 mM NaCl, 5% (v/v) glycerol", pH 7.6 (SASBDB). Tris pK
# 8.072 (25 °C, ΔH 47.45 kJ/mol, dpK/dT -0.0279, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 8.156; Davies (A = 0.509) at the self-consistent ionic strength I = 0.171 M
# gives pK' = 8.278. The protonated fraction of 25 mM is 0.827; with HCl titration the
# counter-ion is chloride 20.67 mM (σ 1.28 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "tris"),   # 25 mM Tris, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the HCl titration, 20.67 mM
    NonBiological(0.020667, 0.00128, "chloride"),
    NonBiological(0.6848, 0.0342, "glycerol"),   # 5 % v/v glycerol (assumed v/v), ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.1178 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.13, 41 % of the points non-positive).
const Q_MAX_FIT = 0.1178

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

# Builds the Seed that `runSasdvg6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvg6` below is the whole story (build the seed, then sample it).
function seedSasdvg6(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvg6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvg6(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvg6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 2.404",
)

# `@__DIR__` (this SASDVG6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
