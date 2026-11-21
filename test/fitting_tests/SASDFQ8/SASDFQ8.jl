# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDFQ8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDFQ8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDFQ8: BSA (monomer, 66.432 kDa), measured at EMBL P12. Publication: Graewert M
# et al., "Adding Size Exclusion Chromatography (SEC) and Light Scattering (LS) Devices to
# Obtain High-Quality Small Angle X-Ray Scattering (SAXS) Data" Crystals 2020, DOI
# 10.3390/cryst10110975 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDFQ8/.
#
# Instrument (SASBDB): wavelength 0.123982 nm (hc/lambda = 10000 eV). Temperature: 20 C,
# SASBDB cell temperature.
#
# Buffer: SASBDB buffer fields: '50 mM HEPES, 150 mM NaCl, 2% v/v glycerol', pH 7.0
# (comment: running buffer for SEC-SAXS). Paper not consulted (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.09786-7.213 nm-1), converted to A-1 (divide
# by 10): q 0.00979-0.7213 A-1, 2575 rows, 0 with sigma <= 0, 4 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 5.3.
#
# Model and depositor fit (fit2_model1): CRYSOL fit (header '4F5S_mon Dro:0.018 Ra:1.780
# RGT:27.62 Vol: 84468. Chi^2: 1.332'; SASBDB chi2 1.332) against SASDFQ8_fit2_model1.pdb:
# single atomic model: 4666 heavy atoms, chain(s) B, no hydrogens; 26 altloc atoms (counted
# twice, flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is
# column 4, not rescaled. Header Chi^2 1.332 (SASBDB 1.332); recomputed 1.336. fit2 of
# SASBDB (fit1 is GASBOR). The depositor's fit covers q up to 0.600 A-1 while the curve
# extends to 0.721 A-1, so refChi2 is not like for like with the fitted range (no q cut is
# applied).
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
const ENERGY_EV     = HC_EV_ANGSTROM / 1.23982   # wavelength 1.23982 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 50 mM at pH 7.0, 20 C (hepes template, Davies at I =
# 0.162 M): 11.94 mM Na+ from the NaOH titration (sigma 2.41 mM). Glycerol 2 % v/v: 0.02 x
# 1261 g/L / 92.094 g/mol = 0.2739 M, +-5 %. Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "hepes"),   # 50 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.0, 11.94 mM
    NonBiological(0.011944, 0.002413, "sodium(1+)"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
    NonBiological(0.2739, 0.0137, "glycerol"),   # 2 % v/v glycerol, 0.2739 M, +-5%
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
    refChi2 = "CRYSOL 1.332",
    pdb = "SASDFQ8_fit2_model1.pdb",
    fit = "SASDFQ8_fit2.fit",
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

# Builds the Seed that `runSasdfq8` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdfq8` below is the whole story).
function seedSasdfq8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdfq8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdfq8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdfq8(run)

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

    # `@__DIR__` (this SASDFQ8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
