# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDCQ8")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDCQ8.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDCQ8: BSA (monomer, 66.462 kDa), measured at EMBL P12. No publication is linked
# in SASBDB. Entry: https://www.sasbdb.org/data/SASDCQ8/.
#
# Instrument (SASBDB): wavelength 0.124 nm (hc/lambda = 9999 eV). Temperature: 20 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: 'TRIS 50mM', pH 7.4. Paper not consulted (SASBDB metadata
# only). Nothing else is listed; no salt added (flagged).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.08668-5.504 nm-1), converted to A-1 (divide
# by 10): q 0.00867-0.5504 A-1, 2346 rows, 0 with sigma <= 0, 399 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 0.5.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'BSAMono3 Dro:0.043 Ra:1.400
# RGT:27.54 Vol: 72030. Chi^2: 1.055'; SASBDB chi2 1.055) against SASDCQ8_fit1_model1.pdb:
# single atomic model: 4385 heavy atoms, chain(s) A, no hydrogens; 18 altloc atoms (counted
# twice, flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is
# column 4, not rescaled. Header Chi^2 1.055 (SASBDB 1.055); recomputed 1.052. The
# depositor's fit covers q up to 0.500 A-1 while the curve extends to 0.550 A-1, so refChi2
# is not like for like with the fitted range (no q cut is applied).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 50 mM at pH 7.4, 20 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.044 M): 44.36 mM Cl- from the HCl titration
# (sigma 1.82 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris, +-2%
    # Cl- of the HCl titration to pH 7.4, 44.36 mM
    NonBiological(0.044363, 0.001821, "chloride"),
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
    refChi2 = "CRYSOL 1.055",
    pdb = "SASDCQ8_fit1_model1.pdb",
    fit = "SASDCQ8_fit1.fit",
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

# Builds the Seed that `runSasdcq8` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdcq8` below is the whole story).
function seedSasdcq8(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdcq8(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdcq8(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdcq8(run)

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

    # `@__DIR__` (this SASDCQ8/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
