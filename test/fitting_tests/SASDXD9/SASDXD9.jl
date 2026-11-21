# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXD9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXD9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXD9: mascRNA (MALAT1-associated small cytoplasmic RNA), RNA, CRYSOL reference
# fit.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: none (SASBDB lists no publication for this entry, "Solution structure of human
# MALAT1-associated small cytoplasmic RNA (mascRNA)"), so every condition below is the
# SASBDB one (FLAGGED).
#
# Buffer (SASBDB only): "50 mM HEPES-NaOH, 150 NaCl, 10 mM MgCl2", pH 7.5, 25 °C. The unit
# of "150 NaCl" is missing in the SASBDB text; it is taken as 150 mM (FLAGGED, the only
# reading consistent with the HEPES-NaOH and MgCl2 mM values).
#
# Instrument and conditions: SOLEIL (SASBDB, SEC-SAXS Foxtrot reduction); wavelength
# 0.1033 nm = 1.033 Å (SASBDB), energy = hc/λ ≈ 12002 eV; 25 °C (SASBDB). The .dat has a
# first row q = 0 with nan intensity and error; `fitSubset` drops it (σ > 0 test) and
# `seedModel` drops non-positive bins.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 1093 usable points, q from 0.0036 to 0.500 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDXD9_fit1_model1.pdb (one structure; 1296 heavy atoms + 655
# H; 61 residues, 1951 atom records) and the SASBDB fit file SASDXD9_fit1.fit (CRYSOL,
# column 4 = fitted intensity; the SASBDB header chi2 is 1.252; recomputed: 1.248; the
# depositor χ² used here is 1.252). The deposited hydrogens (if any) are replaced: pdb2pqr
# rebuilds them at PH.
#
# The model comes from Rosetta (SASBDB).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # ≈ 12002 eV, wavelength 1.033 Å
const TEMPERATURE_C = 25.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# HEPES-NaOH 50 mM at pH 7.5 (Good buffer titrated with NaOH): the anionic fraction
# follows from the pH with pKa 7.564 at 25 °C moved to 22 °C (HEPES template of the
# repository: Goldberg, Kishore & Lennen 2002, ΔH 20.4 kJ/mol), the pH taken as set at 22
# ± 3 °C (repository convention, notes/buffer-templates.md section 2), Davies-corrected at
# the self-consistent I ≈ 0.206 M (0.15 M NaCl + 0.03 M MgCl2 + the Na-HEPES): Na⁺ = 25.78
# mM; σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C (3.3
# mM). Only the counter-ion is modelled. The RNA is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),               # 50 mM HEPES, ±2 %
    NonBiological(0.15, 0.003, "sodium chloride"),     # 150 mM NaCl (unit assumed mM), ±2 %
    NonBiological(0.01, 0.0002, "magnesium chloride"), # 10 mM MgCl2, ±2 %
    # Na⁺ of the NaOH titration (see above)
    NonBiological(0.025783, 0.0033, "sodium(1+)"),
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from the
# diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and bins the
# curve to the Shannon channels that diameter allows (see `rebin` there).

# ADD_HYDROGENS = true: the hydrogens are built by pdb2pqr at PH (see the model note above).
const ADD_HYDROGENS = true

# Largest q fitted (Å⁻¹); Inf = the whole curve (the whole curve is fitted).
const Q_MAX_FIT = Inf

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the file
# is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.252",
    pdb = "SASDXD9_fit1_model1.pdb",
    fit = "SASDXD9_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² CRYSOL 1.252
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `q ≤ Q_MAX_FIT` and `σ_exp > 0`.
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdxd9` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdxd9` below is the whole story (build the seed, then
# sample it).
function seedSasdxd9(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxd9(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdxd9(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxd9(run)

    # `results` writes the figures (terminal plots, pgfplots .tex), the workbook and this
    # run's section of the folder's run log; `refChi2` is the depositor's χ² for the log.
    fitCurve =
        run.fit === nothing ? nothing :
        try
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
                fitCurve...; qMax = Q_MAX_FIT,
            ),
        )
    end
    BAYSOL.results(
        result, (qFit, iFit, σ_fit);
        dir = @__DIR__, name = "res$(suffix)", references,
        formFactorLog = formFactorLog, nAtoms = nAtoms,
        refChi2 = run.refChi2,
    )

    # `@__DIR__` (this SASDXD9/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
