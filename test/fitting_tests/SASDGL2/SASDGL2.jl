# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDGL2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDGL2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDGL2: PaaZ (hexamer, 73.002 kDa), measured at 12.3.1 (SIBYLS). Publication:
# Sathyanarayanan N et al., "Molecular basis for metabolite channeling in a ring opening
# enzyme of the phenylacetate degradation pathway." Nat Commun 2019, DOI
# 10.1038/s41467-019-11931-1 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDGL2/.
#
# Instrument (SASBDB): wavelength 0.103 nm (hc/lambda = 12037 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '25 mM HEPES, 50 mM NaCl', pH 7.4. Paper not consulted
# (SASBDB metadata only). LARGE: PaaZ hexamer, 30564 heavy atoms.
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01186-0.3189 A-1, 506 rows, 0
# with sigma <= 0, 0 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 3.8.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'model-no Dro:0.040 Ra:1.800
# RGT:61.07 Vol:576962. Chi^2: 3.382'; SASBDB chi2 3.382) against SASDGL2_fit1_model1.pdb:
# single atomic model: 30564 heavy atoms, chain(s) 123456, no hydrogens. The .fit has 4
# columns (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header
# Chi^2 3.382 = SASBDB 3.382; recomputed 3.381.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # wavelength 1.03 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 25 mM at pH 7.4, 10 C (hepes template, Davies at I =
# 0.059 M): 8.87 mM Na+ from the NaOH titration (sigma 1.50 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),   # 25 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.4, 8.87 mM
    NonBiological(0.008871, 0.001497, "sodium(1+)"),
    NonBiological(0.05, 0.001, "sodium chloride"),   # 50 mM NaCl, +-2%
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
    refChi2 = "CRYSOL 3.382",
    pdb = "SASDGL2_fit1_model1.pdb",
    fit = "SASDGL2_fit1.fit",
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

# Builds the Seed that `runSasdgl2` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdgl2` below is the whole story).
function seedSasdgl2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdgl2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdgl2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdgl2(run)

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

    # `@__DIR__` (this SASDGL2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
