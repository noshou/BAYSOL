# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDTT2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTT2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDTT2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDTT2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTT2: TuAsV 2A3 (Genome polyprotein; Turkey avisivirus; 13.349 kDa SASBDB
# molecule MW, monomer) in the SASBDB buffer "20 mM HEPES, 150 mM NaCl, 2 mM TECP, 1%
# Glycerol", pH 7.4. Sample: Turkey Avisivirus 2A3 (TuAsV 2A3) polyprotein fragment at pH
# 7.4.
#
# Publication: no publication is listed in SASBDB for this entry. Entry:
# https://www.sasbdb.org/data/SASDTT2/.
#
# BUFFER SOURCE: the SASBDB buffer fields (name, pH; comment: pH measured before addition
# of glycerol); the publication was NOT read for this entry, so no value was checked
# against the paper.
#
# Instrument and conditions (SASBDB): PETRA III, DESY; Hamburg, beamline EMBL P12, X-ray
# synchrotron, detector Pilatus 6M; wavelength 0.124 nm = 1.24 Å (the `wavelength` field
# is in nm; `xray_energy` is null, so the energy is hc/λ ≈ 9999 eV); cell temperature 25.0
# °C; sample-detector distance 3.0 m.
#
# Curve units: the SASBDB .dat is labelled "1/nm" (q 0.02225 to 5.828 1/nm, 2648 points)
# and is converted to Å⁻¹ (÷10); 67 points have I ≤ 0. No q cut (the README noise-floor
# rule is not met: whole curve, σ > 0 points).
#
# Model and depositor fit: fit 1 of the entry is CRYSOL (chi_square_value 1.207); model:
# SASBDB model software: AlphaFold. SASDTT2_fit1_model1.pdb: 1850 ATOM records (123
# residues, chains A), 936 heavy atoms, 914 hydrogens (replaced by pdb2pqr/PROPKA); one
# structure only.
# The fit file SASDTT2_fit1.fit has 4 columns (q, I_exp, σ, I_fit), header "Dro:  0.086
# Rg: 13.79 Vol:  16613. Chi^2: 1.207"; χ² recomputed from the file with the data's σ is
# 1.207 (label 1.207), so the reference curve is column 4; q in Å⁻¹ (SASBDB fit_unit
# "1/A").
# The depositor fit covers q ≤ 0.4999 Å⁻¹ only while the data run to 0.5828 Å⁻¹, so the
# depositor χ² is not like for like with a fit of the whole curve.
#
# Flags: AlphaFold prediction (no experimental structure); buffer from SASBDB only (paper
# not read); 25 °C is the SASBDB cell temperature; glycerol percentage unit not stated,
# v/v assumed; whole entry wired from the files above; not run.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV   # nm⁻¹ -> Å⁻¹
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.4, PH_METER_SIGMA   # SASBDB pH 7.4 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, SASBDB wavelength 1.24 Å
const TEMPERATURE_C = 25.0   # SASBDB cell temperature

# Buffer "20 mM HEPES, 150 mM NaCl, 2 mM TECP, 1% Glycerol", pH 7.4 (SASBDB). HEPES pK
# 7.564 (25 °C, ΔH 20.4 kJ/mol, dpK/dT -0.012, the constants of
# tui/assets/data/buffer_templates.json) moved to 22 °C (the pH taken as set at 22 °C)
# gives 7.600; Davies (A = 0.509) at the self-consistent ionic strength I = 0.159 M
# gives pK' = 7.479. The deprotonated (anionic) fraction of 20 mM is 0.455; with NaOH
# titration the counter-ion is sodium 9.09 mM (σ 1.32 mM: σ_pH 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on the concentration in quadrature).
#
# The measured macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM HEPES, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM, ±2%
    # counter-ion of the NaOH titration, 9.09 mM
    NonBiological(0.009091, 0.00132, "sodium"),
    NonBiological(0.002, 4e-05, "tcep"),   # 2 mM TCEP (SASBDB spells it TECP), ±2%
    NonBiological(0.137, 0.0068, "glycerol"),   # 1 % v/v glycerol (assumed v/v), ±5%
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

# Builds the Seed that `runSasdtt2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdtt2` below is the whole story (build the seed, then sample it).
function seedSasdtt2()
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdtt2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdtt2()
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdtt2()

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
    refChi2 = "CRYSOL 1.207",
)

# `@__DIR__` (this SASDTT2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
