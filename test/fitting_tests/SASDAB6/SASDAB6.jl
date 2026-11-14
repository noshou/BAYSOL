# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDAB6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDAB6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDAB6_fit2_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDAB6_fit2.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDAB6: xylose isomerase (glucose isomerase, Streptomyces rubiginosus, UniProt
# P24300, 43.2 kDa per chain; a tetramer in solution, SASBDB experimental MW 149 kDa;
# crystalline, Hampton Research) at 5.76 mg/ml (paper: 5.8 mg/ml) in 20 mM HEPES, 200 mM
# Na2SO4, 50 mM K2SO4, 1 mM MgCl2 and 50 % v/v D2O, pH 7.0 (paper; SASBDB: pH 6.6, see
# below). A single-concentration curve, the average of 20 frames.
#
# Publication (SASBDB): Franke D, Jeffries CM, Svergun DI, "Correlation Map, a
# goodness-of-fit test for one-dimensional X-ray scattering spectra", Nat Methods 2015,
# 12, 445, DOI 10.1038/nmeth.3358. Entry: https://www.sasbdb.org/data/SASDAB6/. The
# paper WAS read (round-6 audit, 2026-11-13; the PDF is in sources/, Online Methods,
# "Experimental SAXS and sample details" and "Experimental setup and data collection")
# and is the source of truth where it differs from SASBDB: "Continuous-flow sample
# injection was performed at 20 °C" (SASBDB: 10 °C); "glucose isomerase (Hampton
# Research): 5.8 mg/ml dialyzed against 200 mM Na2SO4, 50 mM K2SO4, 1 mM MgCl2, 50 %
# (v/v) 2H2O, 20 mM HEPES, pH 7.0" (SASBDB: pH 6.6 with the comment pD 7.0); "λ = 0.124
# nm ... EMBL BioSAXS P12 ... Pilatus 2M" (SASBDB: 0.12 nm, a rounding). The remaining
# values (sample-detector distance, frames, model) are the SASBDB entry metadata.
#
# Instrument (SASBDB): EMBL beamline P12, PETRA III (DESY, Hamburg), Pilatus 2M,
# sample-detector distance 3.1 m, wavelength 0.124 nm (paper; SASBDB `xray_energy` is null
# and gives 0.12 nm; the energy is hc/λ ≈ 9999 eV); 20 frames of 0.05 s (1 s in total);
# sample temperature 20 °C (paper; SASBDB cell and storage temperature 10 °C); measured
# 2013-12-10.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (angular_unit "1/nm"; s_min 0.091 and s_max
# 3.501 nm⁻¹), converted to Å⁻¹ (÷10) below. 75 of the 1297 points are non-positive (the
# first at 0.183 Å⁻¹). The whole curve is fitted (no q cut, see `Q_MAX_FIT`); the
# depositor's CRYSOL curve runs to 0.35 Å⁻¹.
#
# Model and depositor fit: of the four fits of the entry fit2 is the CRYSOL 3.0 fit
# against SASDAB6_fit2_model1.pdb ("Based on PDB 4E3V", SASBDB lists no identity flag):
# the tetramer, chains A-D, 12 056 ATOM and HETATM records, no hydrogens; 4E3V.pdb (chain
# A only, the asymmetric unit, 3396 records with 324 HOH) is kept beside it for comparison
# and is not used. fit1 is DAMMIF, fit3 and fit4 have no model; they are not used. The
# deposited tetramer carries the crystallisation ligands (40 SO4, 4 Mg²⁺, 4 Mn²⁺ and 24
# PRO, all known components, kept by the loader). Eight HETATM atoms (one proline in chain
# B) are named "d" instead of "PRO" in the deposited file (not in 4E3V, presumably a
# renaming by the depositors): "d" is not in the component table, so the loader drops them
# (with network access it first tries the RCSB component download, offline that raises
# `ComponentError`); it is 8 of 12 056 atoms and the file is NOT edited.
#
# The fit header reads "XI_PDB_4  Convex:  1.560  Concave:  0.000  Inner:   2.00
# Chi:1.188" (three parameters, labelled as printed); SASBDB's chi_square_value is
# 1.411344. The two DISAGREE only in what they are: 1.188² = 1.411, so the header "Chi:"
# is χ and SASBDB's number is χ², confirmed by recomputing from the .fit columns 2-4 (χ² ≈
# 1.41). refChi2 is therefore 1.411, the χ² that the log compares with (the header value
# 1.188 would be a χ, not comparable). The .fit file has four columns, q (Å⁻¹), I_exp, σ,
# I_fit, from 0.0091 to 0.35 Å⁻¹, without a leading grid.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.0, PH_METER_SIGMA   # paper: pH 7.0 (SASBDB: 6.6 = meter reading, pD 7.0)

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, paper wavelength 0.124 nm
const TEMPERATURE_C = 20.0                     # paper: injection at 20 °C (SASBDB: 10 °C)

# Buffer (paper, Online Methods, as quoted above): 20 mM HEPES, 200 mM Na2SO4, 50 mM
# K2SO4, 1 mM MgCl2, 50 % (v/v) 2H2O, pH 7.0; the SASBDB buffer fields agree on every
# component and concentration. The two sources differ in the pH: the paper says pH 7.0
# and SASBDB 6.6 with the comment "pD = 7.0" (the pH-meter reading in the D2O mixture,
# pD = reading + 0.4). The paper's value, 7.0, is used as the pH of the hydrogenation
# and of the counter-ion; it is also the pD the SASBDB comment gives, so the two
# sources do not contradict each other on the nominal value. The measured
# macromolecule is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# D2O 50 % v/v: 0.5 L/L x 1.1044 g/mL / 20.0276 g/mol = 27.57 M (as in SASDCA3, which has
# 10 %), ±5 %. D2O is a solute with its own volume (18.132 mL/mol) against the H2O
# solvent.
#
# Counter-ion. Setting the pH adds a titrant that the recipe does not list.
# Convention: 20 mM HEPES titrated with NaOH (Good's buffer) -> Na⁺ = C·f with f = r/(1
# + r), r = 10^(pH − pK)/γ₁, pK(22 °C) = 7.6 (the value of SASDB48 and SASDKQ8, not
# re-derived here). The pH is taken as set at room temperature (22 ± 3 °C), so the
# amount is the same whatever the 20 °C of the measurement. The anionic fraction is
# Davies-corrected (A = 0.509) at the self-consistent I ≈ 0.758 M (0.6 M Na2SO4 + 0.15 M
# K2SO4 + 0.003 M MgCl2 + 0.005 M Na-HEPES), ABOVE THE RANGE OF THE DAVIES EQUATION
# (about 0.5 M), so the fraction is indicative: log γ₁ = −0.509 (√I/(1 + √I) − 0.3 I) =
# −0.121, γ₁ = 0.756; r = 10^(7.0 − 7.6)/0.756 = 0.332, f = 0.249, Na⁺ = 4.99 mM. σ
# combines σ_pH = 0.1 (0.86 mM), ±3 °C (0.36 mM), ±0.02 pK (0.17 mM), 30 % of the Davies
# shift (0.29 mM) and ±2 % on C (0.10 mM): 1.00 mM. Only the counter-ion is modelled; the
# volume change of the buffer's own (de)protonation is not.
const SOLUTES = Solute[
    NonBiological(0.020, 0.0004, "hepes"),                 # 20 mM HEPES, ±2%
    NonBiological(0.200, 0.004, "sodium sulfate"),         # 200 mM Na2SO4, ±2%
    NonBiological(0.050, 0.001, "potassium sulfate"),      # 50 mM K2SO4, ±2%
    NonBiological(0.001, 0.00002, "magnesium chloride"),   # 1 mM MgCl2, ±2%
    NonBiological(27.572, 1.379, "d2o"),                   # 50 % v/v D2O, ±5%
    # Na⁺ counter-ion from NaOH titration of HEPES (see note above)
    NonBiological(0.00499, 0.001, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0091-0.3501 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.18 Å⁻¹ was used before, but the 647 points above 0.18
# Å⁻¹ (σ > 0) have a median I/σ of 1.23 and 12 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 1.23 ≥ 0.5; I ≤ 0 share 12 % < 25 %; median
# I/σ 1.32 ≥ 1 in the lowest-q quarter (up to 0.22 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

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

# Builds the Seed that `runSasdab6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdab6` below is the whole story (build the seed, then sample it).
function seedSasdab6(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdab6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdab6(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdab6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit2): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "CRYSOL fit2",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.411",
    runLog = true,
)

# `@__DIR__` (this SASDAB6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
