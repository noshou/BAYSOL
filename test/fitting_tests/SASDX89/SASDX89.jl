# SPDX-License-Identifier: LGPL-3.0-or-later

using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDX89")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDX89.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDX89: Arabidopsis alpha-amylase 3 catalytic domain (AMY3cat), AlphaFold model,
# protein.
#
# NOT YET RUN: this entry was wired on 2026-11-18 without a fit (no run was allowed); the
# first run has not been checked by the author.
#
# Paper: DOI 10.1186/s12870-026-10284-4. NOT read in this session; every condition below
# is the SASBDB one (paper preferred, SASBDB used: FLAGGED).
#
# Buffer (SASBDB only): "100 mM potassium phosphate", pH 7.4, 10 °C. Entered as the two
# potassium salts KH2PO4 and K2HPO4 (repository convention).
#
# Instrument and conditions: ALS SIBYLS 12.3.1 (SASBDB); wavelength 0.1127 nm = 1.127 Å
# (SASBDB), energy = hc/λ ≈ 11001 eV; temperature: SASBDB.
#
# Curve units: the SASBDB .dat is in Å⁻¹ (angular_unit 1/A); NO nm⁻¹ conversion is
# applied, 909 usable points, q from 0.0124 to 0.471 Å⁻¹. No q cut: the whole deposited
# curve is fitted, `seedModel` drops the non-positive bins.
#
# Model and depositor fit: SASDX89_fit1_model1.cif (one structure; 3362 heavy atoms + 0 H;
# 416 residues, 3362 atom records) and the SASBDB fit file SASDX89_fit1.fit (FoXS fit file
# (q, exp, error, model), column 4 = model intensity; the SASBDB header chi2 is 0.616;
# recomputed: 0.616; the depositor χ² used here is 0.616). The deposited hydrogens (if
# any) are replaced: pdb2pqr rebuilds them at PH.
#
# The model is an AlphaFold-Server mmCIF (one chain, no hydrogens); the fixture file is
# the SASBDB download renamed from ".pdb" to ".cif" because its content is mmCIF.
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
const TEMPERATURE_C = 10.0   # SASBDB

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density).
# 100 mM potassium phosphate at pH 7.4: H2PO4⁻ 20.4 mM and HPO4²⁻ 79.6 mM from pK2 7.198
# (Goldberg, Kishore & Lennen 2002, ΔH 3.6 kJ/mol), the pH taken as set at 22 ± 3 °C
# (repository convention, notes/buffer-templates.md section 2), Davies-corrected at the
# self-consistent I ≈ 0.26 M; σ 6 mM on each salt combines σ_pH = 0.1, ±3 °C, ±0.02 pK, 30
# % of the Davies shift and ±2 % on C. The macromolecule is deliberately NOT a solute.
const SOLUTES = Solute[
    NonBiological(0.020395, 0.006, "potassium dihydrogen phosphate"), # KH2PO4 at pH 7.4
    NonBiological(0.079601, 0.006, "dipotassium hydrogen phosphate"), # K2HPO4 at pH 7.4
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
    refChi2 = "FoXS 0.616",
    pdb = "SASDX89_fit1_model1.cif",
    fit = "SASDX89_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),   # deposited χ² FoXS 0.616
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

# Builds the Seed that `runSasdx89` samples. It is separate only because the developer tools
# in test/utils/ build a fit's Seed without running the fit; if you are reading this script
# as an example you can skip it: `runSasdx89` below is the whole story (build the seed, then
# sample it).
function seedSasdx89(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdx89(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdx89(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdx89(run)

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

    # `@__DIR__` (this SASDX89/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
