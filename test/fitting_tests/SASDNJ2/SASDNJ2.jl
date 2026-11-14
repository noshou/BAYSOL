# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDNJ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDNJ2.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDNJ2_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDNJ2_fit1.fit")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDNJ2: the KaiABC clock-protein complex, SEC-SAXS (24 chains A-X = KaiA 12 +
# KaiB 6 + KaiC 6, "A12B6C6", model 778.5 kDa).
#
# Paper: DOI 10.1038/s42003-022-03143-z (Communications Biology 2022; PMC8913699). The
# paper WAS consulted through the Europe PMC full text (no page numbers, so sections are
# cited). It confirms the SEC-SAXS setup (Photon Factory BL-10C, Pilatus3 2M,
# Superose 6 increase 10/300 GL, wavelength 1.50 Å, detector distance 3034.9 mm) and
# states that "all hydrogenated Kai proteins" were in H2O buffer for SAXS and AUC, but
# the SAXS buffer itself is NOT given in the text read: only a 20 mM Tris-HCl pH 8.0,
# 150 mM NaCl, 5 mM MgCl2, 0.5 mM EDTA, 1 mM DTT, 1 mM ATP buffer for preparing the
# B6C6 complex appears. This is a CONFLICT/GAP between the paper and the SASBDB buffer
# field below; the SASBDB buffer is used, and the owner should decide. Part of the text
# (about characters 94,000-100,000) was only partly seen. The SEC-SAXS temperature is
# not stated in the text read (25 °C appears for the AUC-SAXS section); the SASBDB cell
# temperature, 25 °C, is used.
#
# Instrument (SASBDB): KEK Photon Factory BL-10C, Pilatus3 2M; wavelength 0.15 nm =
# 1.50 Å, energy = hc/λ ≈ 8266 eV.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit "1/A"), 823 points, q from 0.00499
# to 0.2 Å⁻¹, intensity in 1/cm; NO conversion is applied. The whole curve is fitted.
#
# Model and depositor fit: fit1 is CRYSOL against SASDNJ2_fit1_model1.pdb (software
# "Other", comment "see a literature"; the paper's cryo-EM structure is PDB 5n8y): 24
# chains A-X, 54,814 heavy atoms + 54,830 H, no HETATM groups, no waters, no MODEL records,
# no altloc duplicates. The model has NO ATP although the buffer has 1 mM ATP. The fit
# file has padding rows (q = 0 and 0.002-0.004 with I_exp = 0) and rounded values (3
# significant digits). Its header reads "Chi^2: 4.549"; recomputing χ² with the
# σ of the .dat (row-by-row match of all 823 rows, 0 q mismatches) gives 4.624, 1.6 %
# above the header, plausibly because of the rounded fit columns. The label is χ², and
# the header value 4.549 is used (SASBDB chi_square_value is 4.549 too). The paper's own
# Fig. 1 gives χ² = 1195 for the cryo-EM structure and 366 for the model with
# supplemented domains; it does not describe this CRYSOL fit.
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.8, PH_METER_SIGMA   # SASBDB: pH 7.8 (no σ stated)
const ENERGY_EV     = HC_EV_ANGSTROM / 1.50   # ≈ 8266 eV, wavelength 0.15 nm
const TEMPERATURE_C = 25.0                    # SASBDB cell temperature

# Buffer (SASBDB buffer field): 50 mM sodium phosphate, 150 mM NaCl, 5 mM MgCl2, 0.5 mM
# EDTA, 1 mM ATP, 1 mM DTT, 50 mM arginine, 50 mM glutamine, pH 7.8. The paper does not
# confirm it (see the source block). The macromolecule is deliberately NOT a solute.
#
# Phosphate split (convention of the SASDV62 script): pK₂ = 7.198 at 25 °C, ΔH = 3.6
# kJ/mol (Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902), pH taken as set at 22 ± 3 °C: pK₂(22 °C) = 7.2044. Davies (A =
# 0.509) at the self-consistent ionic strength I = Ibase + C (1 + 2 x), x the HPO₄²⁻
# fraction, x = 1/(1 + 10^-(pH - pK₂ + 3 A g(I))), Ibase = 0.150 (NaCl) + 0.015 (MgCl2)
# = 0.165 M: x = 0.9089, I = 0.3059 M (Davies is past its range there), so HPO₄²⁻ =
# 45.45 mM and H₂PO₄⁻ = 4.55 mM. σx = 0.0387 (σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the
# Davies shift), i.e. 1.9 mM on both species (anticorrelated, as in SASDV62). Adding the
# Arg⁺ and ATP/EDTA charges to Ibase (0.215-0.225 M) moves x only to 0.9097, so they are
# neglected in the split. The phosphate cation (Na⁺ from the salts) is assumed.
# ATP and EDTA: ATP as the neutral acid (as in the SASDUP5 script), EDTA as the table's
# "edta"; the salt forms are not stated. Arginine as the neutral molecule (as SASDT55).
const SOLUTES = Solute[
    NonBiological(0.04545, 0.0019, "disodium hydrogen phosphate"),   # HPO₄²⁻, 45.45 mM
    NonBiological(0.00455, 0.0019, "sodium dihydrogen phosphate"),   # H₂PO₄⁻, 4.55 mM
    NonBiological(0.15, 0.0015, "sodium chloride"),   # 150 mM, ±1 %
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM, ±2 %
    NonBiological(0.0005, 0.00001, "edta"),   # 0.5 mM, ±2 %
    NonBiological(0.001, 0.00002, "atp"),   # 1 mM, ±2 %
    NonBiological(0.001, 0.00002, "dtt"),   # 1 mM, ±2 %
    NonBiological(0.05, 0.001, "arginine"),   # 50 mM, ±2 %
    NonBiological(0.05, 0.001, "glutamine"),   # 50 mM, ±2 %
]

# The omissions, one line each. Every run of this script, and every developer tool that
# loads it, warns about them.
const BUFFER_OMISSIONS = String[
    "arginine counter-anion (neutral molecule used) and ATP/EDTA counter-ions not stated",
    "Mg²⁺ complexation by ATP and EDTA not modelled",
    "the model has no ATP although the sample has 1 mM ATP",
]
isempty(BUFFER_OMISSIONS) ||
    @warn "SASDNJ2: buffer recipe is incomplete (known omissions, not modelled)" omissions =
        BUFFER_OMISSIONS

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited model carries 54,830 hydrogens already; pdb2pqr/PROPKA rebuild them at PH.
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

# Builds the Seed that `runSasdnj2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdnj2` below is the whole story (build the seed, then sample it).
function seedSasdnj2(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdnj2(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdnj2(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdnj2()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
# The .fit file is CRYSOL's (fit1) with THREE tab-separated columns: q (Å⁻¹), I_exp,
# I_fit (no σ column), so the fitted intensity is column 3.
fitCurve = _readFit(_FIT_PATH, 1.0, 3)
reference = BAYSOL.Reference("CRYSOL fit1", fitCurve...)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "CRYSOL 4.549",
    runLog = true,
)

# `@__DIR__` (this SASDNJ2/ folder), not the caller's cwd.

BAYSOL.printSummary(result)
