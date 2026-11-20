# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDEP7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDEP7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDEP7: FLNa3-5 P637Q (monomer, 30.791 kDa), measured at BM29. Publication:
# Haataja TJK et al., "Non-syndromic Mitral Valve Dysplasia Mutation Changes the Force
# Resilience and Interaction of Human Filamin A." Structure 2018, DOI
# 10.1016/j.str.2018.09.007 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDEP7/.
#
# Instrument (SASBDB): wavelength 0.1 nm (hc/lambda = 12398 eV). Temperature: 20 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM Tris, 100 mM NaCl, 1 mM DTT', pH 8.0. Paper not
# consulted (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.0553-4.833 nm-1), converted to A-1 (divide by
# 10): q 0.00553-0.4833 A-1, 1016 rows, 0 with sigma <= 0, 0 with a non-positive intensity.
# No q cut: the median I/sigma above 0.3 A-1 is 5.1.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'rc03.pdb Dro:0.020 Ra:1.460
# RGT:22.29 Vol: 40993. Chi^2: 1.123'; SASBDB chi2 1.123) against SASDEP7_fit1_model1.pdb:
# single atomic model: 2165 heavy atoms, chain(s) A, no hydrogens, 53 water atoms (dropped
# by the loader). The .fit has 3 columns (q, I_exp, I_fit); the reference curve is column 3,
# not rescaled. Header Chi^2 equals the SASBDB value and the recomputation against the .dat
# (free scale) agrees. Recomputed 1.124.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1   # wavelength 1 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 20 mM at pH 8.0, 20 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.114 M): 13.58 mM Cl- from the HCl titration
# (sigma 1.41 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, +-2%
    # Cl- of the HCl titration to pH 8.0, 13.58 mM
    NonBiological(0.013578, 0.001414, "chloride"),
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM NaCl, +-2%
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, +-2%
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
    refChi2 = "CRYSOL 1.123",
    pdb = "SASDEP7_fit1_model1.pdb",
    fit = "SASDEP7_fit1.fit",
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

# Builds the Seed that `runSasdep7` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdep7` below is the whole story).
function seedSasdep7(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdep7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdep7(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdep7(run)

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

    # `@__DIR__` (this SASDEP7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
