# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDFQ6")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDFQ6.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDFQ6: unnamed (dimer, 9.534 kDa), measured at 12.3.1 (SIBYLS). Publication:
# Remesh SG et al., "Nucleoid remodeling during environmental adaptation is regulated by
# HU-dependent DNA bundling." Nat Commun 2020, DOI 10.1038/s41467-020-16724-5 (SASBDB
# metadata only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDFQ6/.
#
# Instrument (SASBDB): wavelength 0.103 nm (hc/lambda = 12037 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '10 mM Bis-Tris, 100 mM NaCl', pH 7.5. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01143-0.3236 A-1, 561 rows, 0
# with sigma <= 0, 0 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 30.3.
#
# Model and depositor fit (fit1_model1): FoXS fit (header 'offset = 0.00000000000000,
# scaling c = 0.000262229658083011, Chi^2 = 4.03449454684557'; SASBDB chi2 4.034495) against
# SASDFQ6_fit1_model1.pdb: single atomic model: 1282 heavy atoms, chain(s) BD, no hydrogens.
# The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column 4, not
# rescaled. The .fit is a FoXS profile (commented header: 'Chi^2 = 4.03449', SASBDB
# 4.034495); recomputed 4.167.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.03   # wavelength 1.03 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Bis-Tris 10 mM at pH 7.5, 10 C (bis-tris template: Clarke-Glew
# pK at the temperature, Davies activities at I = 0.102 M): 1.84 mM Cl- from the HCl
# titration (sigma 0.42 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "bis-tris"),   # 10 mM Bis-Tris, +-2%
    # Cl- of the HCl titration to pH 7.5, 1.84 mM
    NonBiological(0.00184, 0.000418, "chloride"),
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM NaCl, +-2%
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
    refChi2 = "FoXS 4.034",
    pdb = "SASDFQ6_fit1_model1.pdb",
    fit = "SASDFQ6_fit1.fit",
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

# Builds the Seed that `runSasdfq6` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdfq6` below is the whole story).
function seedSasdfq6(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdfq6(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdfq6(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdfq6(run)

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

    # `@__DIR__` (this SASDFQ6/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
