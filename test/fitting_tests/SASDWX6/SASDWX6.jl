# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDWX6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDWX6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDWX6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDWX6_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDWX6: horse spleen apoferritin, presumably dynamic dimers (2 x 24mer)
# of the protein (SASBDB sample description)
# (SASBDB experimental MW 952.63 kDa; model 929 kDa, 48 chains).
#
# Publication: the record lists the project "Structural insights into the nature of
# static and dynamic apoferritin dimers" and NO publication; no PDF in sources/
# matches, so the paper was NOT consulted. All conditions below are the SASBDB entry's.
#
# Instrument (SASBDB): SSRF BL19U2 (Shanghai), Pilatus 1M, detector distance 2.7 m;
# wavelength 0.1033 nm = 1.033 Å, energy = hc/λ ≈ 12002 eV; 1 s exposures; cell 20 °C
# (storage 4 °C). The description says the sample was dialysed against 200 mM sodium
# acetate pH 5.0 and then (presumably) SEC-equilibrated in the buffer below.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit "1/A"), intensity 1/cm, 1142
# rows; NO nm⁻¹ conversion is applied. No q cut: the data end at 0.4068 Å⁻¹, the
# deposited fit at 0.3997 Å⁻¹ (refChi2 not exactly like for like).
#
# Model and depositor fit: fit1 is CRYSOL (header label starts "crystal-") against
# SASDWX6_fit1_model1.pdb (byte-identical to the SASDWY6 model file), the 2w0o-based
# model made with Chimera ("identical" to the PDB): 48 chains (A-X, a-x), 66,288 heavy
# atoms by line count, no HETATM, no hydrogens, no waters. ALTLOC: 816 'A' and 816 'B'
# records (64,656 blank), so the line count includes both conformers and one conformer
# gives about 65,472 atoms; CRYSOL reads all of them; the loader's altloc handling was
# NOT verified here (owner to check). The fit header reads
# "Convex 0.000 Concave 1.920 Inner -10.00 Chi^2: 1.257";
# recomputing from columns 2-4 over 1122 rows gives
# 1.2560, so the label is χ² (not χ) and the depositor's χ² is 1.257.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA   # SASBDB: pH 7.4 (no σ stated)
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, from the stated 0.1033 nm
const TEMPERATURE_C = 20.0                     # SASBDB cell temperature (storage 4 °C)

# Buffer (SASBDB buffer field): 137 mM NaCl, 2.7 mM KCl, 10 mM phosphate, 0.9 mM CaCl2,
# 0.5 mM MgCl2, pH 7.4 (a PBS with Ca and Mg). The macromolecule is deliberately NOT a
# solute. Phosphate split (convention of the SASDV62 script): pK₂ = 7.198 at 25 °C, ΔH
# = 3.6 kJ/mol (Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902), pH taken as set at 22 ± 3 °C: pK₂(22 °C) = 7.2044. Davies (A =
# 0.509) at I = Ibase + C (1 + 2 x), Ibase = 0.137 + 0.0027 + 0.0027 (CaCl2) + 0.0015
# (MgCl2) = 0.1439 M: x(HPO₄²⁻) = 0.7853, I = 0.1696 M, so HPO₄²⁻ = 7.853 mM and
# H₂PO₄⁻ = 2.147 mM. σx = 0.0657, i.e. 0.66 mM on both. The phosphate cation is not
# stated: Na⁺ is ASSUMED (the K⁺/Na⁺ split is negligible).
const SOLUTES = Solute[
    NonBiological(0.137, 0.00137, "sodium chloride"),   # 137 mM, ±1 %
    NonBiological(0.0027, 0.000027, "potassium chloride"),   # 2.7 mM, ±1 %
    NonBiological(0.0009, 0.000018, "calcium chloride"),   # 0.9 mM, ±2 %
    NonBiological(0.0005, 0.00001, "magnesium chloride"),   # 0.5 mM, ±2 %
    NonBiological(0.007853, 0.00066, "disodium hydrogen phosphate"),   # HPO₄²⁻
    NonBiological(0.002147, 0.00066, "sodium dihydrogen phosphate"),   # H₂PO₄⁻
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

# Builds the Seed that `runSasdwx6` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdwx6` below is the whole story (build the seed, then sample it).
function seedSasdwx6(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdwx6(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdwx6(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdwx6()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
fitCurve = _readFit(_FIT_PATH, 1.0, 4)
reference = BAYSOL.Reference("CRYSOL fit1", fitCurve...)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.257",
    runLog = true,
)

# `@__DIR__` (this SASDWX6/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
