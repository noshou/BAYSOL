# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDFC3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDFC3.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDFC3_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDFC3_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDFC3: human ATP citrate lyase (ACLY tetramer, 114.6 kDa subunit, 458 kDa;
# SASBDB experimental MW 500 kDa, Porod 484 kDa), in 20 mM HEPES, 150 mM NaCl, 50 mM Tris,
# 20 mM citrate, 2 mM CoA, pH 7.2.
#
# Publication (SASBDB): DOI 10.1038/s41586-019-1095-5 (Nature 2019). Entry:
# https://www.sasbdb.org/data/SASDFC3/. The paper was NOT consulted (paywalled, not
# reachable); the buffer is the SASBDB field's.
#
# Instrument (SASBDB): wavelength 0.124 nm (SASBDB `xray_energy` is null, so the energy is
# hc/λ ≈ 9998 eV); sample-detector distance 3.1 m; temperature 20 °C.
#
# Curve units: the SASBDB .dat is in nm⁻¹ (q from 0.025 to 5.06 nm⁻¹; 7 text header lines
# that `_readCurve` skips); converted to Å⁻¹. Intensities are arbitrary units.
#
# Model and depositor fit: fit1 of SASBDB (FoXS 5.473). The fixture
# SASDFC3_fit1_model1.pdb is SASBDB's copy, unmodified: 34656 ATOM records (heavy atoms,
# no hydrogens), no HETATM (no ligand in the model although the sample has CoA and
# citrate). The fit file's header reads "SAXS profile: number of points = 1797, q_min =
# 0.00415, q_max = 0.49978 ... offset = 0, scaling c = 7.689e-05, Chi^2 = 5.47305", FoXS's
# format; the label is χ² (SASBDB chi_square_value 5.473051, the same).
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH = 7.2, PH_METER_SIGMA   # SASBDB buffer pH 7.2

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9998 eV, SASBDB wavelength 0.124 nm
const TEMPERATURE_C = 20.0   # SASBDB cell and storage temperature

# Three buffers titrate each other (Tris, HEPES, citrate), so the net chloride is solved
# jointly: Tris pK 8.072 (ΔH 47.45 kJ/mol) and HEPES pK 7.564 (ΔH 21.0 kJ/mol), Goldberg
# 2002 as above, moved to 22 °C by van't Hoff; citrate third pK 6.396 at 25 °C with no
# temperature shift (assumed); Davies activities at the self-consistent ionic strength (I
# = 0.315 M). Charge balance with Na⁺ = 150 + 3 x 20 mM (NaCl and trisodium citrate) and
# Cl⁻ = 150 mM + x gives x = 50 f(Tris⁺) + 20 f(HCit²⁻) - 20 f(HEPES⁻) = 39.87 mM of HCl
# added (Tris protonated 0.925, HEPES ionized 0.351, citrate protonated 0.032), σ 2.58 mM
# (σ_pH, ±3 °C, ±0.02 pK, 30 % of the Davies shift, ±2 % on C). ASSUMED: that the 20 mM
# citrate is the trisodium salt (the SASBDB field does not say); another salt form changes
# the Na⁺ and the HCl amount. Coenzyme A 2 mM is the solute `coenzyme A` (neutral form),
# its charge (about -4) not balanced.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),                    # 50 mM Tris, ±2%
    NonBiological(0.02, 0.0004, "hepes"),                  # 20 mM HEPES, ±2%
    NonBiological(0.15, 0.003, "sodium chloride"),         # 150 mM NaCl, ±2%
    NonBiological(0.02, 0.0004, "trisodium citrate"),      # 20 mM citrate, ±2%
    NonBiological(0.002, 0.00004, "coenzyme A"),           # 2 mM CoA, ±2%
    # net Cl⁻ from the joint Tris/HEPES/citrate titration (see note above)
    NonBiological(0.039871, 0.002576, "chloride"),
]
# The omissions listed above, one line each. Every run of this script, and every
# developer tool that loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "citrate salt form assumed (trisodium); CoA charge and counter-ions not modelled",
    "ligands (CoA, citrate) are in the sample but not in the model",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDFC3: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0025-0.5064 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.47 Å⁻¹ was used before, but the 132 points above 0.47
# Å⁻¹ (σ > 0) have a median I/σ of 1.36 and 13 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 1.36 ≥ 0.5; I ≤ 0 share 13 % < 25 %; median
# I/σ 1.99 ≥ 1 in the lowest-q quarter (up to 0.48 Å⁻¹); rule in README.md).
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

# Builds the Seed that `runSasdfc3Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdfc3Fit1` below is the whole story (build the seed, then sample it).
function seedSasdfc3Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdfc3Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdfc3Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdfc3Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is FoXS's (fit1): three '#' header lines, then columns q (Å⁻¹),
# I_exp, σ, I_fit (the fit is the model with FoXS's scale applied).
crysol = readdlm(_FIT_PATH; skipstart = 3)
crysol = crysol[crysol[:, 1] .> 0, :]   # drop the q = 0 row(s), if any
reference = BAYSOL.Reference(
    "FoXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "FoXS 5.473",
    runLog = true,
)

BAYSOL.printSummary(result)
