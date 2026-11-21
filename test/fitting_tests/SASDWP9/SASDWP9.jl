# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDWP9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWP9.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWP9_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWP9_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWP9: MDtxRGA G149 (Ratiometric matryoshka biosensor for Fe2+; synthetic
# construct; 84.189 kDa SASBDB molecule MW, monomer) in the SASBDB buffer "20 mM MOPS, 250
# mM KCl,", pH 7.0. Sample: Ratiometric matryoshka biosensor for Fe2+ – MDtxRGA_G149.
#
# Publication: Papadopoulos A, Anlauf M, Reiners J, Paik S, Krüger A, Lückel B, Bott M,
# Drepper T, Frunzke J, Gohlke H, Weidtkamp-Peters S, Smits S, Gertzen C, "A Novel
# Biosensor for Ferrous Iron Developed via CoBiSe: A Computational Method for Rapid
# Biosensor Design", ACS Sensors (2026 Jan 11), DOI 10.1021/acssensors.5c02481. Entry:
# https://www.sasbdb.org/data/SASDWP9/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): ESRF, Grenoble, beamline BM29, X-ray synchrotron,
# detector Pilatus3 2M; wavelength 0.099 nm = 0.99 Å (the `wavelength` field is in nm;
# `xray_energy` is null, so the energy is hc/λ ≈ 12524 eV); cell temperature 20.0 °C;
# sample-detector distance 2.827 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.08458 to 2.507 1/nm, 495 points)
# and is converted to Å⁻¹ (÷10); 32 points have I ≤ 0. q cut at 0.2242 Å⁻¹ (README rule):
# above it there are 54 points with a median I/σ of 0.49, 26 % of them non-positive, and
# the lowest-q quarter of them has a median I/σ of 0.52.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.084); model:
# SASBDB model software: AlphaFold. SASDWP9_fit1_model1.pdb: 5926 ATOM records (749
# residues, chains A), 5926 heavy atoms, no hydrogens; one structure only.
# The fit file SASDWP9_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "fold_241
# Dro:0.028  Ra:1.800  RGT:33.88  Vol: 96579.  Chi^2: 1.084"; χ² recomputed from the file
# with the data's σ is 1.084 (label 1.084), so the reference curve is column 4; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # SASBDB pH 7.0 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # ≈ 12524 eV, SASBDB wavelength 0.99 Å
const TEMPERATURE_C = 20.0   # SASBDB cell temperature

# Buffer "20 mM MOPS, 250 mM KCl,", pH 7.0 (SASBDB). MOPS pK 7.184 (25 °C, ΔH 21.1
# kJ/mol, dpK/dT -0.0124, the constants of tui/assets/data/buffer_templates.json) moved
# to 22 °C (the pH taken as set at 22 °C) gives 7.221; Davies (A = 0.509) at the self-
# consistent ionic strength I = 0.259 M gives pK' = 7.089. The deprotonated (anionic)
# fraction of 20 mM is 0.449; with NaOH titration the counter-ion is sodium 8.98 mM (σ
# 1.34 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the
# concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "mops"),   # 20 mM MOPS, ±2%
    NonBiological(0.25, 0.005, "potassium chloride"),   # 250 mM, ±2%
    # counter-ion of the NaOH titration, 8.98 mM
    NonBiological(0.008978, 0.00134, "sodium"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.2242 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.49, 26 % of the points non-positive).
const Q_MAX_FIT = 0.2242

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

# Builds the Seed that `runSasdwp9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdwp9` below is the whole story (build the seed, then sample it).
function seedSasdwp9()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwp9(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdwp9()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwp9()

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
    refChi2 = "CRYSOL 1.084",
)

# `@__DIR__` (this SASDWP9/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
