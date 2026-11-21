# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDE36")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDE36.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDE36: unnamed (tetramer, 114.58 kDa), measured at EMBL P12. Publication:
# Verschueren KHG et al., "Structure of ATP citrate lyase and the origin of citrate synthase
# in the Krebs cycle." Nature 2019, DOI 10.1038/s41586-019-1095-5 (SASBDB metadata only; the
# paper was not consulted). Entry: https://www.sasbdb.org/data/SASDE36/.
#
# Instrument (SASBDB): wavelength 0.124 nm (hc/lambda = 9999 eV). Temperature: 20 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '20mM HEPES, 150mM NaCl', pH 7.2. Paper not consulted
# (SASBDB metadata only). LARGE: 31604 heavy atoms (chains K-N).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.02386-7.297 nm-1), converted to A-1 (divide
# by 10): q 0.00239-0.7297 A-1, 2633 rows, 0 with sigma <= 0, 10 with a non-positive
# intensity. q cut (2026-11-19): q <= 0.4998 A-1, the end of the depositor's FoXS fit file
# (see below); the 832 points above (to 0.7297 A-1, median I/sigma 5.8 above 0.3 A-1) are
# left out so that BAYSOL's chi2 and the depositor's cover the same range.
#
# Model and depositor fit (fit1_model1): FoXS fit (header 'offset = 0.00000000000000,
# scaling c = 1.07105215486578e-05, Chi^2 = 2.82139543658743'; SASBDB chi2 2.821395) against
# SASDE36_fit1_model1.pdb: single atomic model: 31604 heavy atoms, chain(s) KLMN, no
# hydrogens. The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column
# 4, not rescaled. The .fit is a FoXS profile with a commented header (SASBDB chi2
# 2.821395); recomputed 2.823. The depositor's fit covers q up to 0.500 A-1 while the curve
# extends to 0.730 A-1; the fit therefore stops at the depositor's last point (`Q_MAX_FIT`),
# which makes refChi2 (same 1801 points, same sigma: the .fit I_exp and sigma equal the
# .dat) like for like with the fitted range.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.2, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 20 mM at pH 7.2, 20 C (hepes template, Davies at I =
# 0.157 M): 6.63 mM Na+ from the NaOH titration (sigma 1.17 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.2, 6.63 mM
    NonBiological(0.006634, 0.001173, "sodium(1+)"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
]

# q cut at the end of the depositor's fit file (last point 0.49976 A-1), so that BAYSOL
# and the depositor's FoXS χ² cover the same 1801 points (the data run to 0.7297 A-1).
const Q_MAX_FIT = 0.4998

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's reference curve (q
# scaled to Å⁻¹ by `fitScale`; the fitted intensity is column `fitCol`; `rescale` = the
# file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "FoXS 2.821",
    pdb = "SASDE36_fit1_model1.pdb",
    fit = "SASDE36_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "FoXS",
),
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

# Builds the Seed that `runSasde36` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasde36` below is the whole story).
function seedSasde36(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasde36(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasde36(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasde36(run)

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

    # `@__DIR__` (this SASDE36/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
