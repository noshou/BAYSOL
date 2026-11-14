# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDPN6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDPN6.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDPN6_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDPN6_fit1.fit")

# The .dat has 2 lines of header and 7 lines of processing history at the end (frame
# lists), which break `readdlm`, so `_readCurve` (common.jl, numeric rows only) reads it:
# 2650 points.
qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 2650

# qvals are in nm⁻¹ (0.024-7.37); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
# The curve runs to 0.74 Å⁻¹, still inside `Q_SANITY_RANGE`.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDPN6 (sasbdb.org/data/SASDPN6/); paper: Korn SM,
# Dhamotharan K, Jeffries CM, Schlundt A 2023, Nat. Commun., "The preference signature of
# the SARS-CoV-2 Nucleocapsid NTD for its 5'-genomic RNA elements", DOI
# 10.1038/s41467-023-38882-y (PMID 37286558). The paper's methods text was not consulted.
#
#     25 mM potassium phosphate, 150 mM KCl, 2 mM TCEP, pH 6.5
#
# Stem loop 4 with AU extension (69 nt, 22.1 kDa) of the SARS-CoV-2 5'-genomic RNA;
# in-line SEC-SAXS (Superdex 75 Increase 10/300) of a 90 µL, 6.2 mg/mL injection, cell
# at 20 °C (storage 5 °C), EMBL P12 (PETRA III), Pilatus 6M, wavelength 0.124 nm = 1.24 Å
# => energy = hc/λ ≈ 10 keV (hc = 12398.42 eV·Å); 9 frames averaged with CHROMIXS. The
# measured RNA is deliberately NOT a solute (see BulkElectronDensity.Solute).
#
# Model: SASDPN6_fit1_model1.pdb, one RNA chain (A, residues G/U/C/A, 69 nt) built with
# RNAMasonry; 2191 atoms of which 731 are hydrogens (names H01-H12, a numbering of the
# builder, and a 5'-terminal phosphate). The hydrogens are not kept: see ADD_HYDROGENS.
#
# Curve units: the SASBDB .dat is in nm⁻¹ and is converted to Å⁻¹ (÷10). The comparison
# curve is the depositor's Pepsi-SAXS fit (header "Dro: Rg: Vol: Chi^2: 1.143"; entry
# χ² 1.224; columns q, I_exp, σ, I_fit).

const PH, σ_PH = 6.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # ≈ 9999 eV, from the stated 0.124 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB (cell)

# Buffer components (the measured RNA is deliberately NOT listed). "25 mM potassium
# phosphate" is a mix of KH2PO4 and K2HPO4 at pH 6.5: the HPO4²⁻ fraction is 0.320 (pK2
# from Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI
# 10.1063/1.1416902; 7.198, ΔH 3.6 kJ/mol, ΔCp −230 J/K/mol) at 22 °C (pH set at room
# temperature), Davies-corrected at I ≈ 0.191 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of
# the Davies shift and ±2 % on C. Same treatment as SASDVX2. TCEP (usually supplied as
# the hydrochloride, which acidifies the stock) is taken as the neutral molecule; no
# titrant counter-ion is added.
const SOLUTES = Solute[
    # 25 mM KPi, H2PO4⁻ part
    NonBiological(0.017010, 0.001734, "potassium dihydrogen phosphate"),
    # 25 mM KPi, HPO4²⁻ part
    NonBiological(0.007990, 0.001734, "dipotassium hydrogen phosphate"),
    NonBiological(0.150, 0.0015, "potassium chloride"),   # 150 mM KCl, ±1%
    NonBiological(0.002, 0.00004, "tcep"),                # 2 mM TCEP, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut: the whole deposited curve (q 0.0024-0.7368 Å⁻¹) is fitted, `seedModel` drops
# the non-positive bins. A cut at 0.3 Å⁻¹ was used before, but the 1576 points above 0.3
# Å⁻¹ (σ > 0) have a median I/σ of 0.85 and 27 % of them have I ≤ 0, so the data above it
# are not demonstrably unusable (median I/σ 0.85 ≥ 0.5; median I/σ 2.33 ≥ 1 in the
# lowest-q quarter (up to 0.41 Å⁻¹); rule in README.md).
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# The deposited RNAMasonry model carries 731 hydrogens (builder names H01-H12). Runs
# Pdb2pqr at PH (PARSE, no PROPKA for a nucleic-acid-only file), which rebuilds the
# hydrogens from the heavy atoms, as for the other models that arrive with hydrogens
# (SASDT55, SASDWZ9).
const ADD_HYDROGENS = true

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT`. (`seedModel`
bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(≤(Q_MAX_FIT), qvals)
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdpn6Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdpn6Fit1` below is the whole story (build the seed, then sample it).
function seedSasdpn6Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdpn6Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdpn6Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdpn6Fit1()

fit, divergenceRate, mapResult, quantileResult = result

# `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

# run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
crysol = readdlm(_FIT_PATH; skipstart = 1)
reference = BAYSOL.Reference(
    "Pepsi-SAXS fit1",
    Float64.(crysol[:, 1]),
    Float64.(crysol[:, 4]);
    qMax = Q_MAX_FIT,
)
BAYSOL.results(
    result, (qFit, iFit, σ_fit);
    dir = @__DIR__, name = "res_fit1", references = reference,
    formFactorLog = formFactorLog, nAtoms = nAtoms,
    refChi2 = "Pepsi-SAXS 1.224",
    runLog = true,
)

# `@__DIR__` (this SASDPN6/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
