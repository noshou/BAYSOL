# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDGD6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDGD6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDGD6: CuGE (monomer, 43.178 kDa), measured at Xenocs BioXolver L with GeniX3D.
# Publication: Ernst HA et al., "The structural basis of fungal glucuronoyl esterase
# activity on natural substrates." Nat Commun 2020, DOI 10.1038/s41467-020-14833-9 (SASBDB
# metadata only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDGD6/.
#
# Instrument (SASBDB): wavelength 0.154 nm (hc/lambda = 8051 eV). Temperature: 21 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM sodium acetate', pH 5.0, 21 C. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01966-0.4805 A-1, 378 rows, 0
# with sigma <= 0, 41 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 0.6.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'dD_A.pdb Dro:0.015 Ra:1.800
# RGT:20.34 Vol: 50754. Chi^2: 1.054'; SASBDB chi2 1.054) against SASDGD6_fit1_model1.pdb:
# single atomic model: 2882 heavy atoms, chain(s) A, no hydrogens, HETATM NAG x14; 30 altloc
# atoms (counted twice, flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the
# reference curve is column 4, not rescaled. Header Chi^2 1.054 (SASBDB 1.054); recomputed
# 1.053. The depositor's fit covers q up to 0.471 A-1 while the curve extends to 0.480 A-1,
# so refChi2 is not like for like with the fitted range (no q cut is applied).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 5.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.54   # wavelength 1.54 Å
const TEMPERATURE_C = 21.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Acetate 20 mM at pH 5.0, 21 C (pK 4.756, Davies at I = -0.013
# M): acetate 13.27 mM, acetic acid 6.73 mM (sodium acetate assumed). Every solute below is
# in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.01327, 0.001132, "sodium acetate"),   # acetate, 13.27 mM
    NonBiological(0.00673, 0.001132, "acetic acid"),   # acetic acid, 6.73 mM
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
    refChi2 = "CRYSOL 1.054",
    pdb = "SASDGD6_fit1_model1.pdb",
    fit = "SASDGD6_fit1.fit",
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

# Builds the Seed that `runSasdgd6` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdgd6` below is the whole story).
function seedSasdgd6(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdgd6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdgd6(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdgd6(run)

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

    # `@__DIR__` (this SASDGD6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
