# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDEK4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDEK4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDEK4: PmScsC&Delta;N (monomer, 20.15 kDa), measured at SAXS/WAXS. Publication:
# Furlong EJ et al., "Engineered variants provide new insight into the structural properties
# important for activity of the highly dynamic, trimeric protein disulfide isomerase ScsC
# from Proteus mirabilis." Acta Crystallogr D Struct Biol 2019, DOI
# 10.1107/S2059798319000081 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDEK4/.
#
# Instrument (SASBDB): wavelength 0.1033 nm (hc/lambda = 12002 eV). Temperature: 10 C,
# SASBDB cell temperature.
#
# Buffer: SASBDB buffer fields: '10mM HEPES, 150mM NaCl', pH 7.4. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01597-0.3634 A-1, 295 rows, 0
# with sigma <= 0, 30 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 0.5.
#
# Model and depositor fit (fit2_model1): CRYSOL fit (header 'PmScsCDN Dro:0.025 Ra:1.420
# RGT:16.77 Vol: 22984. Chi^2: 1.120'; SASBDB chi2 1.12) against SASDEK4_fit2_model1.pdb:
# single atomic model: 1376 heavy atoms, chain(s) A, no hydrogens. The .fit has 3 columns
# (q, I_exp, I_fit); the reference curve is column 3, not rescaled. Header Chi^2 equals the
# SASBDB value and the recomputation against the .dat (free scale) agrees. Recomputed 1.120.
# fit2 of SASBDB (fit1 is DAMFILT).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # wavelength 1.033 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 10 mM at pH 7.4, 10 C (hepes template, Davies at I =
# 0.154 M): 3.71 mM Na+ from the NaOH titration (sigma 0.62 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "hepes"),   # 10 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.4, 3.71 mM
    NonBiological(0.003705, 0.00062, "sodium(1+)"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
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
    tag = "fit2_model1",
    refChi2 = "CRYSOL 1.120",
    pdb = "SASDEK4_fit2_model1.pdb",
    fit = "SASDEK4_fit2.fit",
    fitScale = 1.0,
    fitCol = 3,
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

# Builds the Seed that `runSasdek4` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdek4` below is the whole story).
function seedSasdek4(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdek4(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdek4(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdek4(run)

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

    # `@__DIR__` (this SASDEK4/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
