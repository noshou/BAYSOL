# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDVV4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDVV4.dat")
const _PDB_PATH    = joinpath(_FIXTURE_DIR, "SASDVV4_fit1_model1.pdb")
const _FIT_PATH    = joinpath(_FIXTURE_DIR, "SASDVV4_fit1.fit")

# The .dat has 2 lines of header and 9 lines of processing history at the end, and the
# latter break `readdlm` (SASDVV4's has quote characters), so `_readCurve` (common.jl,
# numeric rows only) reads it: 273 points.
qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 273

# qvals are in nm⁻¹ (0.06-31.9); must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
# The curve runs to 3.19 Å⁻¹, beyond `Q_SANITY_RANGE`, so only the part up to 0.5 Å⁻¹
# is checked.
checkQAngstrom(filter(≤(0.5), qvals))

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------
#
# Source: SASBDB entry metadata for SASDVV4 (sasbdb.org/data/SASDVV4/); paper: Gezelle
# et al. 2025, Nucleic Acids Res., "A conserved viral RNA fold enables nuclease resistance
# across kingdoms of life", DOI 10.1093/nar/gkaf840 (PMID 40884403). The paper's methods
# text was not consulted.
#
#     50 mM Tris pH 7.5, 100 mM NaCl, 1 mM DTT, 10 mM MgCl2, 0.0002% w/v NaN3
#
# ST9 RNA, wild type (54 nt, 17.5 kDa), in-line SEC-SAXS (Superdex 200 Increase) of a
# 3 mg/mL injection, 20 °C, NSLS-II 16-ID (LiX), wavelength 0.082 nm => energy =
# hc/λ ≈ 15.1 keV (hc = 12398.42 eV·Å). SASBDB gives no separate pH field; the pH is the
# 7.5 of the buffer name. The model is the deposited RNA chain plus one Mg²⁺ HETATM.

const PH, σ_PH = 7.5, PH_METER_SIGMA

const ENERGY_EV     = HC_EV_ANGSTROM / 0.82   # ≈ 15120 eV, from the stated 0.082 nm
const TEMPERATURE_C = 20.0                    # 20 °C, SASBDB

# Buffer components. 0.0002 % w/v NaN3 = 0.002 g/L / 65.01 g/mol = 3.08e-5 M. Counter-ions.
# Setting the pH adds titrant counter-ions that the deposited recipe does not list.
# Assumed: 50 mM Tris titrated with HCl -> Cl⁻ = C·0.858 (pK(22 °C) = 8.156). The pH is
# taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion amount
# whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002 (J.
# Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is Davies-
# corrected at I ≈ 0.173 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies shift,
# and ±2 % on C. Only the counter-ion is modelled; the volume change of the buffer's own
# (de)protonation is not. Titrant: not stated; HCl for amine bases (Tris, imidazole,
# histidine, Bis-Tris), NaOH for Good's buffers.
const SOLUTES = Solute[
    # The measured macromolecule is deliberately NOT listed: ρₑ is the buffer's
    # electron density (see BulkElectronDensity.Solute).
    NonBiological(0.050, 0.001, "tris"),                  # 50 mM Tris, ±2%
    NonBiological(0.100, 0.001, "sodium chloride"),       # 100 mM NaCl, ±1%
    NonBiological(0.001, 0.00002, "dtt"),                 # 1 mM DTT, ±2%
    NonBiological(0.010, 0.0001, "magnesium chloride"),   # 10 mM MgCl2, ±1%
    NonBiological(3.076e-5, 6.2e-7, "sodium azide"),      # 0.0002 % w/v NaN3, ±2%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.042877, 0.002138, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut, kept (flat noise floor; rule in README.md): 1.3 Å⁻¹. The data run to 3.190 Å⁻¹,
# but the 63 points above 1.3 Å⁻¹ (σ > 0) have a median I/σ of -0.47 and 83 % of them have
# I ≤ 0; the lowest-q quarter of them (up to 1.75 Å⁻¹) has a median I/σ of 0.07. Below 1.3
# Å⁻¹ none of the 210 points has I ≤ 0 (above it the background looks over-subtracted).
const Q_MAX_FIT = 1.3

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# no hydrogens in the deposited model; runs Pdb2pqr at PH (PARSE, no PROPKA for a
# nucleic-acid-only file)
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

# Builds the Seed that `runSasdvv4Fit1` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running the
# fit; if you are reading this script as an example you can skip it:
# `runSasdvv4Fit1` below is the whole story (build the seed, then sample it).
function seedSasdvv4Fit1(; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(_PDB_PATH), ENERGY_EV, qFit, iFit, σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdvv4Fit1(;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdvv4Fit1(; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdvv4Fit1()

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
    refChi2 = "Pepsi-SAXS 0.876",
    runLog = true,
)

# `@__DIR__` (this SASDVV4/ folder), not the caller's cwd.
BAYSOL.printSummary(result)
