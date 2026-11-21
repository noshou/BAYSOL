# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDSP8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDSP8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDSP8: apo-D43 (RNA device regulating PD-1 expression), RNA, CRYSOL reference
# fit.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1093/nar/gkaf156 (Nucleic Acids Res. 2025, "Structural investigation of an
# RNA device that regulates PD-1 expression in mammalian cells"). NOT read in this
# session; the buffer is the SASBDB one (FLAGGED: paper preferred, SASBDB used).
#
# Buffer (SASBDB only): "10 mM Bis-Tris, 100 mM KCl, and 1 mM MgCl2", pH 6.8, 20 °C. Bis-
# Tris is titrated with HCl (repository `bis-tris` template), so its chloride is the
# counter-ion.
#
# Instrument and conditions: NSLS-II (SASBDB); wavelength 0.08202 nm = 0.8202 Å, energy =
# hc/λ ≈ 15117 eV; 20 °C (SASBDB). q runs to 0.8 Å⁻¹ (SASBDB angular_unit "1/A").
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 181 usable points, q from 0.0050 to 0.800 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDSP8_fit1_model1.pdb (one structure; 2652 heavy atoms + 1202
# H; 124 residues, 3854 atom records) and the SASBDB fit file SASDSP8_fit1.fit (CRYSOL,
# column 4 = fitted intensity; the SASBDB header chi2 is 69.336; recomputed: 69.337; the
# depositor χ² used here is 69.336). The deposited hydrogens (if any) are replaced:
# pdb2pqr rebuilds them at PH.
#
# The deposited model is a cryo-EM structure with missing residues (SASBDB comment), which
# is why the depositor χ² is large (69); the fit and reference here are expected to
# disagree with the data the same way.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)
# qvals are already in Å⁻¹ (SASBDB angular_unit "1/A"): no conversion.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.8, PH_METER_SIGMA   # SASBDB
const ENERGY_EV     = HC_EV_ANGSTROM / 0.8202   # ≈ 15116 eV, wavelength 0.8202 Å
const TEMPERATURE_C = 20.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 10 mM Bis-Tris at pH 6.8 (bis-tris template, whose pK is not independently verified in
# the repository table: Clarke-Glew pK at 22 °C, pH taken as set at 22 ± 3 °C, repository
# convention, notes/buffer-templates.md section 2; Davies activities at the self-
# consistent I ≈ 0.107 M): 4.11 mM of the Bis-Tris is the protonated cation, whose
# counter-ion is Cl⁻ from the HCl titration (σ 0.67 mM from σ_pH = 0.1, ±3 °C, ±0.02 pK,
# 30 % of the Davies shift and ±2 % on C). The RNA is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "bis-tris"),           # 10 mM Bis-Tris, ±2 %
    # Cl⁻ of the HCl titration (see above)
    NonBiological(0.00411, 0.00067, "chloride"),
    NonBiological(0.1, 0.002, "potassium chloride"),   # 100 mM KCl, ±2 %
    NonBiological(0.001, 2e-05, "magnesium chloride"), # 1 mM MgCl2, ±2 %
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
    refChi2 = "CRYSOL 69.336",
    pdb = "SASDSP8_fit1_model1.pdb",
    fit = "SASDSP8_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),   # deposited χ² CRYSOL 69.336
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

# Builds the Seed that `runSasdsp8` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdsp8` below is the whole story (build the seed, then
# sample it).
function seedSasdsp8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdsp8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdsp8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdsp8(run)

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

    # `@__DIR__` (this SASDSP8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
