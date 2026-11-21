# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDE35")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDE35.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDE35: OVA (monomer, 42.75 kDa), measured at Xenocs BioXolver L with MetalJet.
# Publication: Bucciarelli S et al., "Size-exclusion chromatography small-angle X-ray
# scattering of water soluble proteins on a laboratory instrument." J Appl Crystallogr 2018,
# DOI 10.1107/S1600576718014462 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDE35/.
#
# Instrument (SASBDB): wavelength 0.134 nm (hc/lambda = 9253 eV). Temperature: 23 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: 'PBS', pH 7.4. Paper not consulted (SASBDB metadata only).
# Concentrations are not stated; the standard 1x PBS recipe is assumed (137 mM NaCl, 2.7 mM
# KCl, 10 mM Na2HPO4, 1.8 mM KH2PO4).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01110-0.5022 A-1, 74 rows, 0 with
# sigma <= 0, 0 with a non-positive intensity. No q cut: the median I/sigma above 0.3 A-1 is
# 1.7.
#
# Model and depositor fit (fit1_model1): FoXS fit (header '1ova_ova Convex: 2.000
# Concave:-10.000 Inner: -10.00 Chi^2: 0.749'; SASBDB chi2 0.749) against
# SASDE35_fit1_model1.pdb: single atomic model: 2955 heavy atoms, chain(s) A, no hydrogens,
# 167 water atoms (dropped by the loader), HETATM ACE x3, SEP x20, NAG x14, CA x1. The .fit
# has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled.
# Header Chi^2 0.749 (SASBDB 0.749); recomputed 0.704 on the overlap (74 points, 6 % lower).
# The depositor's fit covers q up to 0.481 A-1 while the curve extends to 0.502 A-1, so
# refChi2 is not like for like with the fitted range (no q cut is applied).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # wavelength 1.34 Å
const TEMPERATURE_C = 23.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). PBS 1x taken as 137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4 and 1.8
# mM KH2PO4, each +-5 % (the recipe is assumed: SASBDB gives none; the stated pH is used as
# given). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    # 137 mM NaCl, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.137, 0.00685, "sodium chloride"),
    # 2.7 mM KCl, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.0027, 0.000135, "potassium chloride"),
    # 10 mM Na2HPO4, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.01, 0.0005, "disodium hydrogen phosphate"),
    # 1.8 mM KH2PO4, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.0018, 9e-05, "potassium dihydrogen phosphate"),
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
    refChi2 = "FoXS 0.749",
    pdb = "SASDE35_fit1_model1.pdb",
    fit = "SASDE35_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
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

# Builds the Seed that `runSasde35` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasde35` below is the whole story).
function seedSasde35(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasde35(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasde35(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasde35(run)

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

    # `@__DIR__` (this SASDE35/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
