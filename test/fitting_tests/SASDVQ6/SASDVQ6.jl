# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDVQ6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVQ6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVQ6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVQ6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDVQ6: VPS35L (VPS35 endosomal protein-sorting factor-like; Homo sapiens;
# 109.618 kDa SASBDB molecule MW, monomer) in the SASBDB buffer "50 mM Tris, 200 mM NaCl,
# 1 mM TCEP", pH 7.5. Sample: Retriever complex.
#
# Publication: Martín-González A, Méndez-Guzmán I, Zabala-Zearreta M, Quintanilla A,
# García-López A, Martínez-Lombardía E, Albesa-Jové D, Acosta J, Lucas M, "Selective cargo
# and membrane recognition by SNX17 regulates its interaction with Retriever", EMBO
# Reports (2024 Dec 09), DOI 10.1038/s44319-024-00340-1. Entry:
# https://www.sasbdb.org/data/SASDVQ6/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH); the publication was NOT read for
# this entry, so no value was checked against the paper.
#
# Instrument and conditions (SASBDB): Diamond Light Source, Didcot, beamline B21, X-ray
# synchrotron, detector Eiger 4M; wavelength 0.0954 nm = 0.954 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 12996 eV); cell temperature
# 15.0 °C; sample-detector distance 3.688 m.
#
# Curve units: the SASBDB .dat is labelled "1/A" (q 0.0045 to 0.34 1/A, 2567 points) and
# is in Å⁻¹ already, so no conversion is applied (`checkQAngstrom` guards the range); 193
# points have I ≤ 0. q cut at 0.2512 Å⁻¹ (README rule): above it there are 680 points with
# a median I/σ of 0.39, 25 % of them non-positive, and the lowest-q quarter of them has a
# median I/σ of 0.63.
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.502); model:
# SASBDB model software: AlphaFold. SASDVQ6_fit1_model1.pdb: 11455 ATOM records (1442
# residues, chains XYZ), 11455 heavy atoms, no hydrogens; one structure only.
# The fit file SASDVQ6_fit1.fit has 3 columns (q, I_exp, I_fit; no σ), header "MODELO C
# Dro:0.058  Ra:1.400  RGT:51.82  Vol:190268.  Chi^2: 1.502"; label χ² 1.502 (not
# recomputed: the file has no σ column), so the reference curve is column 3; q in Å⁻¹
# (SASBDB fit_unit "1/A").
#
# Flags: large structure (11455 heavy atoms); AlphaFold prediction (no experimental
# structure); buffer from SASBDB only (paper not read); whole entry wired from the files
# above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in Å⁻¹ already (the SASBDB label "1/A" is right for this entry).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.5, PH_METER_SIGMA   # SASBDB pH 7.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 0.954   # ≈ 12996 eV, SASBDB wavelength 0.954 Å
const TEMPERATURE_C = 15.0   # SASBDB cell temperature

# Buffer "50 mM Tris, 200 mM NaCl, 1 mM TCEP", pH 7.5 (SASBDB). Tris pK 8.072 (25 °C, ΔH
# 47.45 kJ/mol, dpK/dT -0.0279, the constants of tui/assets/data/buffer_templates.json)
# moved to 22 °C (the pH taken as set at 22 °C) gives 8.156; Davies (A = 0.509) at the
# self-consistent ionic strength I = 0.243 M gives pK' = 8.287. The protonated fraction
# of 50 mM is 0.860; with HCl titration the counter-ion is chloride 42.98 mM (σ 2.23 mM:
# σ_pH 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on the concentration in
# quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, ±2%
    NonBiological(0.2, 0.004, "sodium chloride"),   # 200 mM, ±2%
    # counter-ion of the HCl titration, 42.98 mM
    NonBiological(0.042976, 0.00223, "chloride"),
    NonBiological(0.001, 2e-05, "tcep"),   # 1 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.2512 Å⁻¹ by the README rule, numbers in the Curve units paragraph above
# (above it: median I/σ 0.39, 25 % of the points non-positive).
const Q_MAX_FIT = 0.2512

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

# Builds the Seed that `runSasdvq6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdvq6` below is the whole story (build the seed, then sample it).
function seedSasdvq6()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvq6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdvq6()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvq6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.

# The .fit file is CRYSOL's (fit 1): columns q (Å⁻¹), I_exp, I_fit (no σ).
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 3]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res",
    references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.502",
)

# `@__DIR__` (this SASDVQ6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
