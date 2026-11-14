# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDAQ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAQ2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDAQ2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDAQ2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# Audit 2026-11-13 (owner rule: papers first; a value is open only if neither the paper nor
# the SASBDB record states it): SASBDB lists no publication, and its record states the
# complete buffer, pH, temperature and wavelength used below, so nothing is assumed beyond
# the titrant/counter-ion convention.
#
# SASBDB SASDAQ2: bovine ubiquitin (UniProt P63048, 76 residues, 8.565 kDa), the
# "Standard proteins" project of the EMBL Hamburg outstation, in 40 mM sodium acetate,
# 150 mM NaCl, pH 5.5; the curve is extrapolated to infinite dilution (four parent
# curves, concentration_max 24.2 mg/ml, Nanodrop). SASBDB experimental MW 8.0 kDa.
# Entry: https://www.sasbdb.org/data/SASDAQ2/. SASBDB lists NO publication for this
# entry, and every condition below is the SASBDB entry metadata (no paper exists to
# consult).
#
# Instrument (SASBDB): EMBL beamline X33, DORIS III, DESY, Hamburg; Pilatus 1M-W;
# wavelength 0.15 nm = 1.5 Å (SASBDB `xray_energy` is null, so the energy is
# hc/λ ≈ 8266 eV); sample-detector distance 2.7 m; 8 frames of 15 s; cell and storage
# temperature 10 °C; measured 2012-09-18; contributor D. Ruskule.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.087 and s_max
# 6.015 nm⁻¹; three text lines, then q, I, σ, all skipped by `_readCurve`) and is
# converted to Å⁻¹ (÷10). The intensities are on an arbitrary scale. All 2168 points
# have I > 0 and σ > 0, so the whole curve (to 0.6015 Å⁻¹, the range of the deposited
# CRYSOL curve) is fitted (no q cut).
#
# Model and depositor fit: fit1 is CRYSOL 2.8 against PDB 1UBQ ("Structure of ubiquitin
# refined at 1.8 Å resolution"), fit2 is DAMMIF (dummy atoms, χ² 14.23; not used).
# SASDAQ2_fit1_model1.pdb is SASBDB's copy of 1UBQ: its 602 ATOM records (the 76
# residues, no hydrogens) were checked identical to the ones of 1UBQ.pdb from
# files.rcsb.org (both are beside each other in the fixture folder), and the 58 HOH
# HETATM records are dropped by the loader. The deposited fit header reads
# "1ubq.pdb  Dro:0.010  Ra:1.720  RGT:12.79  Vol: 11180.  Chi^2: 4.009". The label is
# χ² (CRYSOL's "Chi^2:", not "Chi:"), and SASBDB's chi_square_value is the rounded 4.0,
# so the depositor's χ² used here is the header's 4.009. The deposited curve is on the
# data scale (columns of the .fit file: q (Å⁻¹), I_exp, σ, I_fit; the rows below the
# first data point carry I_exp = σ = 0 and are the fitted curve alone).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 5.5, PH_METER_SIGMA   # SASBDB: pH 5.5 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, SASBDB wavelength 0.15 nm
const TEMPERATURE_C = 10.0                   # SASBDB cell temperature (also storage)

# Buffer as deposited (SASBDB buffer name): "40 mM Sodium acetate 150 mM NaCl", pH 5.5,
# NaCl 150 mM as the additive. The measured macromolecule is deliberately NOT a solute
# (see BulkElectronDensity.Solute).
#
# The entry gives total acetate and pH, not the salts, so the split is computed:
# acetate as sodium acetate and the protonated part as acetic acid (Na⁺ comes with the
# salt, so there is no separate counter-ion). Assumed: the pH is set with acetic acid
# (not stated). pK_a = 4.757 (the value of the SASDVN2 script, quoted from there and
# not re-checked; the 10 °C shift is under 0.01 and ignored, the pH being taken as set
# at room temperature), Davies-corrected (A = 0.509) at the self-consistent ionic
# strength I = 0.15 + 0.04 x (I ≈ 0.185 M) with x the acetate fraction: x = 0.8806, i.e.
# acetate 35.22 mM and acetic acid 4.78 mM (without the activity correction x would be
# 0.847). σ combines σ_pH = 0.1 (±0.0243 on x) and 30 % of the Davies shift (±0.0101),
# 1.05 mM for both species (they are anticorrelated, as the total is fixed, which the
# independent σ ignores).
const SOLUTES = Solute[
    NonBiological(0.03522, 0.00105, "sodium acetate"),   # acetate, 35.22 mM
    NonBiological(0.00478, 0.00105, "acetic acid"),      # protonated, 4.78 mM
    NonBiological(0.150, 0.0015, "sodium chloride"),     # 150 mM NaCl, ±1%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model (1UBQ) has no hydrogens: pdb2pqr/PROPKA place them at PH.
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdaq2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdaq2` below is the whole story (build the seed, then sample it).
function seedSasdaq2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdaq2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdaq2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdaq2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
shown = crysol[:, 1] .> 0   # the q = 0 row cannot be drawn on a log axis
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[shown, 1]),
    Float64.(crysol[shown, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 4.009",
    runLog = true,
)

# `@__DIR__` (this SASDAQ2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
