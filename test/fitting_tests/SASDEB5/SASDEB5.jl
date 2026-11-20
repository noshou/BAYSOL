# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDEB5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDEB5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDEB5: BSA (monomer, 66.432 kDa), measured at Xenocs BioXolver L with MetalJet.
# Publication: Bucciarelli S et al., "Size-exclusion chromatography small-angle X-ray
# scattering of water soluble proteins on a laboratory instrument." J Appl Crystallogr 2018,
# DOI 10.1107/S1600576718014462 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDEB5/.
#
# Instrument (SASBDB): wavelength 0.134 nm (hc/lambda = 9253 eV). Temperature: 25 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '50 mM HEPES', pH 7.5. Paper not consulted (SASBDB metadata
# only). No salt is listed (flagged).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01110-0.4480 A-1, 130 rows, 0
# with sigma <= 0, 0 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 1.0.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header '4f5s_BSA Dro:0.025 Ra:1.800
# RGT:28.05 Vol: 86952. Chi^2: 1.027'; SASBDB chi2 1.027) against SASDEB5_fit1_model1.pdb:
# single atomic model: 4672 heavy atoms, chain(s) A, no hydrogens; 38 altloc atoms (counted
# twice, flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is
# column 4, not rescaled. Header Chi^2 1.027 = SASBDB 1.027; recomputed 1.034.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # wavelength 1.34 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 50 mM at pH 7.5, 25 C (hepes template, Davies at I =
# 0.025 M): 25.05 mM Na+ from the NaOH titration (sigma 3.29 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.5, 25.05 mM
    NonBiological(0.02505, 0.00329, "sodium(1+)"),
]

# No q cut: the README noise-floor rule is not met over any useful part of the curve.
const Q_MAX_FIT = Inf

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the
# file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.027",
    pdb = "SASDEB5_fit1_model1.pdb",
    fit = "SASDEB5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` (no q cut: `Q_MAX_FIT` is infinite).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdeb5` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdeb5` below is the whole story).
function seedSasdeb5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdeb5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdeb5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdeb5(run)

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

    # `@__DIR__` (this SASDEB5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
