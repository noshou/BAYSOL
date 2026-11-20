# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDUS8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDUS8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDUS8: DIS-C (RNA), RNA, FoXS reference fit.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1016/j.str.2025.01.017 (Structure 2025, "Selective deuteration of an
# RNA:RNA complex for structural analysis using small-angle scattering"). NOT read in this
# session (no open full text was fetched); the buffer is therefore the SASBDB one
# (FLAGGED: paper preferred, SASBDB used).
#
# Buffer (SASBDB only): "50 mM potassium phosphate buffer, 1 mM MgCl2, 50 mM NaCl", pH
# 7.5, 20 °C. SASBDB does not say whether the phosphate concentration is the total or the
# monobasic salt alone; the total is taken.
#
# Instrument and conditions: Advanced Photon Source BioCAT 18-ID (SASBDB); wavelength
# 0.1033 nm = 1.033 Å, energy = hc/λ ≈ 12002 eV; 20 °C (SASBDB).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 1678 usable points, q from 0.0028 to 0.416 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDUS8_fit1_model1.pdb (one structure; 616 heavy atoms + 0 H;
# 29 residues, 616 atom records) and the SASBDB fit file SASDUS8_fit1.fit (FoXS file,
# layout q, exp, model, error: column 3 = fitted intensity; the SASBDB header chi2 is
# 1.225; recomputed: 1.223; the depositor χ² used here is 1.225). The deposited hydrogens
# (if any) are replaced: pdb2pqr rebuilds them at PH.
#
# CAUTION: the deposited model was built with SAXS restraints (RNAMasonry, "DIS-C modeled
# with SAXS restraints"), so the depositor fit is not independent of this curve.
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
const TEMPERATURE_C = 20.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 50 mM potassium phosphate at pH 7.5: the species (H2PO4⁻ 8.9 mM, HPO4²⁻ 41.1 mM) are
# computed from the pH with the pK2 of Goldberg, Kishore & Lennen 2002 (7.198, ΔH 3.6
# kJ/mol, ΔCp -230 J/K/mol), the pH taken as set at 22 ± 3 °C (repository convention,
# notes/buffer-templates.md section 2), Davies-corrected at the self-consistent I ≈ 0.185
# M; σ combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30 % of the Davies shift and ±2 % on C.
# Potassium is the cation by the SASBDB wording ("potassium phosphate"); the 1 mM MgCl2
# and 50 mM NaCl are entered as listed. The RNA is deliberately NOT a solute.
const SOLUTES = Solute[
    # 50 mM phosphate, H2PO4⁻ part
    NonBiological(0.008906, 0.0026, "potassium dihydrogen phosphate"),
    # 50 mM phosphate, HPO4²⁻ part
    NonBiological(0.041092, 0.0027, "dipotassium hydrogen phosphate"),
    NonBiological(0.001, 2e-05, "magnesium chloride"), # 1 mM MgCl2, ±2 %
    NonBiological(0.05, 0.001, "sodium chloride"),     # 50 mM NaCl, ±2 %
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
    refChi2 = "FoXS 1.225",
    pdb = "SASDUS8_fit1_model1.pdb",
    fit = "SASDUS8_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
    rescale = false,
    software = "FoXS",
),   # deposited χ² FoXS 1.225
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

# Builds the Seed that `runSasdus8` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdus8` below is the whole story (build the seed, then
# sample it).
function seedSasdus8(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdus8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdus8(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdus8(run)

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

    # `@__DIR__` (this SASDUS8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
