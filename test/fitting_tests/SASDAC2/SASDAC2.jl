# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDAC2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAC2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDAC2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDAC2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# Audit 2026-11-13 (owner rule: papers first; a value is open only if neither the paper nor
# the SASBDB record states it): SASBDB lists no publication, and its record states the
# complete buffer, pH, temperature and wavelength used below, so nothing is assumed beyond
# the titrant/counter-ion convention.
#
# SASBDB SASDAC2: hen egg-white lysozyme (Gallus gallus, UniProt P00698, 14.3 kDa,
# monomer) in 40 mM sodium acetate, pH 3.8; measured at 8.09 mg/ml (SASBDB
# concentration_max; the .fit header: dar_218.dat minus the average of the buffer frames
# dar_217.dat and dar_219.dat, divided by 8.09). Project "Standard proteins" of the EMBL
# Hamburg outstation (contributor D. Ruskule).
#
# Publication: none listed by SASBDB (the project is the EMBL standard-protein series), so
# there is no DOI. Entry: https://www.sasbdb.org/data/SASDAC2/. The conditions below are
# the SASBDB entry metadata; no paper was consulted.
#
# Instrument (SASBDB): EMBL beamline X33, DORIS III (DESY, Hamburg), Pilatus 1M-W,
# sample-detector distance 2.7 m, wavelength 0.15 nm (SASBDB `xray_energy` is null, so the
# energy is hc/λ ≈ 8266 eV); 8 frames of 15 s; cell and storage temperature 10 °C;
# measured 2012-09-21.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.087 and s_max
# 6.015 nm⁻¹), converted to Å⁻¹ (÷10) below. The signal-to-noise stays above about 2.3
# up to the end of the curve and only 5 of the 2168 points are non-positive (all beyond
# 0.49 Å⁻¹; `seedModel` bins them away), so the whole curve is fitted (no q cut). The data
# go to 0.6015 Å⁻¹ but the depositor's CRYSOL curve ends at 0.5 Å⁻¹, so refChi2 is not
# like for like.
#
# Model and depositor fit: fit1 is CRYSOL (SASBDB lists no version) against
# SASDAC2_fit1_model1.pdb, whose header is PDB 1LYZ ("Real-space refinement of the
# structure of hen egg-white lysozyme"; 1102 ATOM records, chain A, plus 101 HOH, no
# hydrogens); SASBDB gives no pdb link for it. fit2 is DAMMIF (chi2 2.873; not used). The
# fit header reads "1LYZ_1.p  Dro:0.003  Ra:1.580  RGE:14.21  RGT:14.45  Vol: 18372.
# Chi:1.205" and SASBDB's chi_square_value is 1.452025. They DISAGREE only in what they
# are: 1.205² = 1.452, so the header "Chi:" is χ and SASBDB's number is χ², confirmed by
# recomputing from the .fit columns 2-4 (χ² ≈ 1.45). refChi2 is therefore 1.452, the χ²
# that the log compares with (the header value 1.205 would be a χ, not comparable). The
# .fit file has the CRYSOL layout: columns q (Å⁻¹), I_exp, σ, I_fit, with a leading q grid
# at which the experimental columns are placeholders and only I_fit is meaningful (all
# `Reference` uses). The waters are dropped by the loader.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 3.8, PH_METER_SIGMA   # SASBDB: pH 3.8 (no pH uncertainty stated)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # ≈ 8266 eV, SASBDB wavelength 0.15 nm
const TEMPERATURE_C = 10.0                    # SASBDB cell temperature (also storage)

# Buffer as deposited (SASBDB buffer fields): "40 mM Sodium Acetate", pH 3.8, no additive.
# The measured macromolecule is deliberately NOT a solute (see
# BulkElectronDensity.Solute).
#
# The entry gives total acetate and pH, not the salts, so the split is computed as in
# SASDAQ2: acetate as sodium acetate and the protonated part as acetic acid (Na⁺ comes
# with the salt, so there is no separate counter-ion). Assumed: the pH is set with acetic
# acid (not stated). pK_a = 4.757 (the value of the SASDAQ2 script, not re-checked here;
# the 10 °C shift is under 0.01 and ignored, the pH being taken as set at room
# temperature), Davies-corrected (A = 0.509) at the self-consistent ionic strength I =
# 0.04 x (I ≈ 0.0042 M) with x the acetate fraction: x = 0.1059, i.e. acetate 4.236 mM and
# acetic acid 35.764 mM. σ combines σ_pH = 0.1 and 30 % of the Davies shift (±0.88 mM on
# x·C), 0.88 mM for both species (they are anticorrelated, as the total is fixed, which
# the independent σ ignores).
const SOLUTES = Solute[
    NonBiological(0.004236, 0.00088, "sodium acetate"),   # acetate, 4.236 mM
    NonBiological(0.035764, 0.00088, "acetic acid"),      # protonated, 35.764 mM
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model has no hydrogens: pdb2pqr/PROPKA place them at PH (3.8 here).
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

# Builds the Seed that `runSasdac2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdac2` below is the whole story (build the seed, then sample it).
function seedSasdac2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdac2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdac2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdac2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]),
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.452",
    runLog = true,
)

# `@__DIR__` (this SASDAC2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
