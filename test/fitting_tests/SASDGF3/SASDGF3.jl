# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDGF3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDGF3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDGF3, fit1: Xrn1-resistant RNA 1 (ZIKV-xrRNA1) from Zika virus, pure RNA. The
# paper's Data availability lists "ZIKV-xrRNA1: SASDGF3" (and xrRNA2: SASDGN3), so this
# entry is xrRNA1 (an earlier header said xrRNA2, which was wrong). FLAGGED CAVEAT, entry
# kept: the construct lengths differ between the sources. Paper (Appendix Table S4):
# ZIKV xrRNA1 72 nt (24.16 kDa predicted, Table S2); SASBDB molecule record: 68 nt,
# 22.1 kDa; deposited model: 74 residues (73 phosphorus atoms), 23.9 kDa. The model
# sequence is the ZIKV xrRNA1 region of the paper's full-length sfRNA, so it matches
# the paper's construct; the SASBDB record's length and mass match neither.
#
# Paper: Zhang Y, et al., "Long non-coding subgenomic flavivirus RNAs have extended 3D
# structures and are flexible in solution", EMBO Rep (2019), DOI 10.15252/embr.201847016
# (PMID 31502753); SASBDB entry https://www.sasbdb.org/data/SASDGF3/. Papers are the
# source of truth (owner rule, 2026-11-13). The paper's text and Appendix
# (EMBR-20-e47016-s001) state: models built with ModeRNA from the ZIKV xrRNA1 crystal
# structure (PDB 5TPY) as template, CRYSOL; buffer "20mM Tris-HCl at pH 7.5, 100mM NaCl,
# 5mM MgCl2" (Table S2 footnote); temperature 298 K and wavelength 0.8857 Å (Table S6;
# the main text says only "room temperature"). All agree with the SASBDB record.
#
# Sample: curve extrapolated to infinite dilution (0.25-3.0 mg/mL series), APS 12-ID-B,
# Pilatus 2M in SASBDB (Appendix Table S6 says Pilatus 1M; main text 2M), wavelength
# 0.8857 Å (Table S6 = SASBDB 0.08857 nm) => energy = hc/λ ≈ 13998 eV
# (hc = 12398.42 eV·Å). Temperature 298 K = 25 °C (Table S6 = SASBDB).
# Curve already in Å⁻¹: 151 rows,
# q 0-0.3 Å⁻¹; the first two rows (q = 0, 0.002) have σ = 0 and are dropped by
# `fitSubset`.
#
# Model: SASDGF3_fit1_model1.pdb, 1613 atoms, RNA only, residue names A/C/G/U, blank
# chain id, no element column (the same layout as the SASDDF7 model). It is
# the ModeRNA homology model of xrRNA1 and NOT the 5TPY crystal structure itself (5TPY
# is the 71-nt xrRNA1, with 8 HEZ, 10 HOH and one Mg²⁺; a copy of the RCSB file is kept
# beside the model for reference only and is not fitted). The model carries 29
# hydrogens (as far as checked, on the first residue only), so pdb2pqr
# rebuilds the hydrogens from the heavy atoms as for SASDM76/SASDM96. Unmodified.
#
# Depositor fit: CRYSOL, `.fit` header "Chi^2: 0.754" (Dro 0.075, Ra 1.400, RGT 23.50,
# Vol 23234). Recomputed from the `.fit` columns (q, I_exp, σ, I_fit; mean of
# ((I_exp - I_fit)/σ)² over the 149 points with σ > 0): 0.749, so the header is a chi2
# and not a chi. The SASBDB REST value agrees with the header (per
# notes/replacement-candidates.md). refChi2 = "CRYSOL 0.754".
#
# Buffer (paper, Appendix Table S2; SASBDB buffer name "20mM Tris-HCl, 100mM NaCl, 5mM
# MgCl2", pH 7.5 field; identical):
#
#     20 mM Tris-HCl, 100 mM NaCl, 5 mM MgCl2, pH 7.5
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
@assert length(qvals) == 151

checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.8857   # ≈ 13998 eV, from the stated 0.08857 nm
const TEMPERATURE_C = 25.0                      # paper Table S6 (298 K) = SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ions. Setting the pH adds titrant counter-ions that
# the deposited recipe does not list. Assumed: 20 mM Tris titrated with HCl (stated:
# "Tris-HCl") -> Cl⁻ = C·0.855 (pK(22 °C) = 8.156).
# The pH is taken as set at room temperature (22 ± 3 °C), which fixes the counter-ion
# amount whatever the measurement temperature. pK(T) from Goldberg, Kishore & Lennen 2002
# (J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902) pK/ΔH/ΔCp; the fraction is
# Davies-corrected at I ≈ 0.132 M. σ combines σ_PH, ±3 °C, ±0.02 pK, 30 % of the Davies
# shift, and ±2 % on C (same recipe and relative σ, 5 %, as SASDVV4; recomputed by hand,
# not by running code). Only the counter-ion is modelled; the volume change of the
# buffer's own (de)protonation is not.
const SOLUTES = Solute[
    NonBiological(0.020, 0.0004, "tris"),                 # 20 mM Tris, ±2%
    NonBiological(0.100, 0.001, "sodium chloride"),       # 100 mM NaCl, ±1%
    NonBiological(0.005, 0.00005, "magnesium chloride"),  # 5 mM MgCl2, ±1%
    # Cl⁻ counter-ion from HCl titration of Tris (see note above)
    NonBiological(0.01710, 0.000855, "chloride"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The data and the depositor's CRYSOL fit both stop at 0.3 Å⁻¹, so the
# whole curve is fitted.

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

const ADD_HYDROGENS = true   # runs Pdb2pqr at PH

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 0.754",
    pdb = "SASDGF3_fit1_model1.pdb",
    fit = "SASDGF3_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² = 0.754
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdgf3` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdgf3` below is the whole story (build the seed, then sample it).
function seedSasdgf3(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdgf3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdgf3(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end


for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdgf3(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this

    # run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
    fitCurve = try
        fc = _readFit(joinpath(_FIXTURE_DIR, run.fit), run.fitScale, run.fitCol)
        fc !== nothing && run.rescale ? _rescaleFit(fc, qFit, iFit) : fc
    catch e
        @warn "could not read the reference fit" run.fit exception = e
        nothing
    end
    references = BAYSOL.Reference[]
    if fitCurve !== nothing
        push!(
            references,
            BAYSOL.Reference(
                run.software * " " * run.tag * (run.rescale ? " (rescaled)" : ""),
                fitCurve...,
            ),
        )
    end
    BAYSOL.results(
        result, (qFit, iFit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        formFactorLog = formFactorLog, nAtoms = nAtoms,
        refChi2 = run.refChi2,
        runLog = true,
    )

    # `@__DIR__` (this SASDGF3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
