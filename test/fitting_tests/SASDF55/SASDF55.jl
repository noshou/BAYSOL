# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDF55")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDF55.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDF55: LukG (monomer, 35.573 kDa); LukH (monomer, 37.619 kDa); Fab (monomer,
# 47.441 kDa), measured at EMBL P12. Publication: Trstenjak N et al., "Molecular mechanism
# of leukocidin GH-integrin CD11b/CD18 recognition and species specificity." Proc Natl Acad
# Sci U S A 2019, DOI 10.1073/pnas.1913690116 (SASBDB metadata only; the paper was not
# consulted). Entry: https://www.sasbdb.org/data/SASDF55/.
#
# Instrument (SASBDB): wavelength 0.12 nm (hc/lambda = 10332 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM Hepes, 300 mM NaCl, 1 mM MgCl2', pH 7.5. Paper not
# consulted (SASBDB metadata only). LukG, LukH and Fab (SASBDB molecules); the model has
# chains E-H.
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.04682-3.774 nm-1), converted to A-1 (divide
# by 10): q 0.00468-0.3774 A-1, 1784 rows, 0 with sigma <= 0, 29 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 1.8.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'LuGHFAB1 Dro:0.075 Ra:1.640
# RGT:45.72 Vol:128750. Chi^2: 1.857'; SASBDB chi2 1.857) against SASDF55_fit1_model1.pdb:
# single atomic model: 7154 heavy atoms, chain(s) EFGH, 3801 hydrogens, HETATM DMS x60. The
# .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column 4, not
# rescaled. Header Chi^2 1.857 = SASBDB 1.857; recomputed 1.852. The depositor's fit covers
# q up to 0.300 A-1 while the curve extends to 0.377 A-1, so refChi2 is not like for like
# with the fitted range (no q cut is applied).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.2   # wavelength 1.2 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 20 mM at pH 7.5, 10 C (hepes template, Davies at I =
# 0.312 M): 8.68 mM Na+ from the NaOH titration (sigma 1.32 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.5, 8.68 mM
    NonBiological(0.008681, 0.001323, "sodium(1+)"),
    NonBiological(0.3, 0.006, "sodium chloride"),   # 300 mM NaCl, +-2%
    NonBiological(0.001, 2e-05, "magnesium chloride"),   # 1 mM MgCl2, +-2%
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
    refChi2 = "CRYSOL 1.857",
    pdb = "SASDF55_fit1_model1.pdb",
    fit = "SASDF55_fit1.fit",
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

# Builds the Seed that `runSasdf55` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdf55` below is the whole story).
function seedSasdf55(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdf55(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdf55(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdf55(run)

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

    # `@__DIR__` (this SASDF55/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
