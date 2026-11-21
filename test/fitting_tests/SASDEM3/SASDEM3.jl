# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDEM3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDEM3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDEM3: OXA-48 (dimer, 28.218 kDa), measured at BM29. Publication: Lund BA et al.,
# "The biological assembly of OXA-48 reveals a dimer interface with high charge
# complementarity and very high affinity." FEBS J 2018, DOI 10.1111/febs.14643 (SASBDB
# metadata only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDEM3/.
#
# Instrument (SASBDB): wavelength 0.09919 nm (hc/lambda = 12500 eV). Temperature: 25 C,
# SASBDB cell temperature.
#
# Buffer: SASBDB buffer fields: '50 mM HEPES 50 mM K2SO4', pH 7.0. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.07883-4.899 nm-1), converted to A-1 (divide
# by 10): q 0.00788-0.4899 A-1, 1025 rows, 0 with sigma <= 0, 0 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 8.7.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header '5dtk-A-D Dro:0.015 Ra:1.400
# RGT:24.69 Vol: 68804. Chi^2: 5.025'; SASBDB chi2 5.025) against SASDEM3_fit1_model1.pdb:
# single atomic model: 4119 heavy atoms, chain(s) AD, 3967 hydrogens, 655 water atoms
# (dropped by the loader), HETATM KCX x24, CL x1, EDO x50, 5F3 x64; 330 altloc atoms
# (counted twice, flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference
# curve is column 4, not rescaled. Header Chi^2 5.025 = SASBDB 5.025; recomputed 5.025 (a
# poor depositor fit; the model has 330 altloc atoms and hydrogens).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9919   # wavelength 0.9919 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 50 mM at pH 7.0, 25 C (hepes template, Davies at I =
# 0.163 M): 13.26 mM Na+ from the NaOH titration (sigma 2.58 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.0, 13.26 mM
    NonBiological(0.013263, 0.002581, "sodium(1+)"),
    NonBiological(0.05, 0.001, "potassium sulfate"),   # 50 mM K2SO4, +-2%
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
    refChi2 = "CRYSOL 5.025",
    pdb = "SASDEM3_fit1_model1.pdb",
    fit = "SASDEM3_fit1.fit",
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

# Builds the Seed that `runSasdem3` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdem3` below is the whole story).
function seedSasdem3(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdem3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdem3(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdem3(run)

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

    # `@__DIR__` (this SASDEM3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
