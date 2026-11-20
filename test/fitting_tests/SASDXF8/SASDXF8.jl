# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDXF8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDXF8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDXF8: LILRB3 bound to the bacterial beta antigen C protein (FoXSDock model),
# protein.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1038/s41467-026-74098-6. NOT read in this session; every condition below
# is the SASBDB one (paper preferred, SASBDB used: FLAGGED).
#
# Buffer (SASBDB only): "20 mM HEPES, 140 mM NaCl", pH 7.4. SASBDB gives NEITHER a
# temperature NOR a wavelength: 25 °C and 1.127 Å (ALS SIBYLS) are assumed (FLAGGED).
# HEPES is titrated with NaOH (its Na⁺ counter-ion is entered).
#
# Instrument and conditions: ALS (SASBDB, SIBYLS); wavelength 1.127 Å (ALS SIBYLS,
# unstated for this entry: FLAGGED), energy = hc/λ ≈ 11001 eV; temperature: DEFAULT,
# unstated (FLAGGED).
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 913 usable points, q from 0.0109 to 0.473 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDXF8_fit1_model1.pdb (one structure; 11257 heavy atoms + 0
# H; 1421 residues, 11257 atom records) and the SASBDB fit file SASDXF8_fit1.fit (FoXS fit
# file (q, exp, error, model), column 4 = model intensity; the SASBDB header chi2 is
# 1.268; recomputed: 1.246; the depositor χ² used here is 1.268). The deposited hydrogens
# (if any) are replaced: pdb2pqr rebuilds them at PH. SIZE: 11257 heavy atoms.
#
# The model is a three-chain FoXSDock rigid-body complex (SASBDB lists LILRB3, 46.9 kDa,
# and the beta antigen C protein, 70.9 kDa).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 1.127   # ≈ 11001 eV, wavelength 1.127 Å
const TEMPERATURE_C = 25.0   # DEFAULT, unstated (FLAGGED)

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 20 mM HEPES titrated with NaOH to pH 7.4: the anionic fraction from pKa 7.564 at 25 °C
# moved to 22 °C (HEPES template of the repository: Goldberg, Kishore & Lennen 2002, ΔH
# 20.4 kJ/mol), the pH taken as set at 22 ± 3 °C (repository convention, notes/buffer-
# templates.md section 2), Davies-corrected at I ≈ 0.149 M: Na⁺ = 9.07 mM (σ 1.3 mM). Only
# the counter-ion is modelled. The macromolecules are deliberately NOT solutes.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),              # 20 mM HEPES, ±2 %
    # Na⁺ of the NaOH titration (see above)
    NonBiological(0.009068, 0.0013, "sodium(1+)"),
    NonBiological(0.14, 0.0028, "sodium chloride"),    # 140 mM NaCl, ±2 %
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
    refChi2 = "FoXS 1.268",
    pdb = "SASDXF8_fit1_model1.pdb",
    fit = "SASDXF8_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),   # deposited χ² FoXS 1.268
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

# Builds the Seed that `runSasdxf8` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdxf8` below is the whole story (build the seed, then
# sample it).
function seedSasdxf8(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdxf8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdxf8(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdxf8(run)

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

    # `@__DIR__` (this SASDXF8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
