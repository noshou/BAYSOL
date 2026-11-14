# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDTW4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDTW4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDTW4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDTW4_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDTW4: 24-mer (20.0 kDa subunit, 480 kDa; SASBDB experimental MW 480 kDa, Porod
# 560 kDa), in 20 mM Tris, pH 8.0 (no other component).
#
# Publication (SASBDB): DOI 10.1016/j.bbrc.2023.149276 (Biochem Biophys Res Commun 2023).
# Entry: https://www.sasbdb.org/data/SASDTW4/. The paper was NOT consulted (paywalled, not
# reachable); the buffer is the SASBDB field's.
#
# Instrument (SASBDB): wavelength 0.15406 nm (Cu K-alpha; SASBDB `xray_energy` is null, so
# the energy is hc/λ ≈ 8047 eV); sample-detector distance 2 m; cell temperature 20 °C
# (storage 4 °C).
#
# Curve units: the SASBDB .dat is already in Å⁻¹ (q from 0.0073 to 0.2103 Å⁻¹; three text
# lines that `_readCurve` skips). Intensities are arbitrary units; some points are
# negative (`seedModel` drops the non-positive bins).
#
# Model and depositor fit: SASBDB links PDB 3bve (the 24-mer); the fixture
# SASDTW4_fit1_model1.pdb is SASBDB's copy, unmodified: 34358 ATOM records (heavy atoms,
# no hydrogens) and 4 HETATM waters (dropped by the loader). The construct in the sample
# (His-tag and mutations, per the SASBDB description) differs from the 3bve model, so the
# model does not describe the sample exactly. The .fit header reads "3bve_24m Convex:
# 1.080 Concave: 2.000 Inner: 0.00 Chi^2: 1.343"; the label is χ² (SASBDB chi_square_value
# 1.343, the same).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A); no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 8.0, PH_METER_SIGMA   # SASBDB buffer pH 8.0

const ENERGY_EV     = HC_EV_ANGSTROM / 1.5406   # ≈ 8047 eV, SASBDB wavelength 0.15406 nm
const TEMPERATURE_C = 20.0   # SASBDB cell temperature (storage 4 °C)

# Counter-ion: Tris-HCl at a pH is modelled as Tris base plus HCl (the convention of the
# other scripts), the titrant amount from Goldberg's pK (Tris pK 8.072 at 25 °C, ΔH 47.45
# kJ/mol; Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902), moved to 22 °C (pH set at room temperature, 22 ± 3 °C, whatever the
# measurement temperature) by van't Hoff, Davies-corrected at the self-consistent ionic
# strength. The σ combines σ_pH, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
# Only the counter-ion is modelled. Here Tris 20 mM at pH 8.0, no other ion (I = 0.5 x
# [BH⁺ + Cl⁻]): protonated fraction 0.616, Cl⁻ = 12.32 mM, σ 1.53 mM.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),                   # 20 mM Tris, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.012322, 0.001531, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the curve ends at 0.2103 Å⁻¹ and so does the depositor's CRYSOL curve, so the
# whole curve is fitted.

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

# Builds the Seed that `runSasdtw4Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdtw4Fit1` below is the whole story (build the seed, then sample it).
function seedSasdtw4Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdtw4Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdtw4Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdtw4Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1): columns q (Å⁻¹), I_exp, σ, I_fit.
crysol = readdlm(_FIT_PATH; skipstart = 1)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "CRYSOL fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 1.343",
    runLog = true,
)

BAYSOL.printSummary(result)
