# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDGH2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDGH2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDGH2: IL11 (monomer, 18.249 kDa), measured at SAXS/WAXS. Publication: Metcalfe R
# et al., "The structure of the extracellular domains of human interleukin 11 α-receptor
# reveals mechanisms of cytokine engagement" Journal of Biological Chemistry 2020, DOI
# 10.1074/jbc.RA119.012351 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDGH2/.
#
# Instrument (SASBDB): wavelength 0.1078 nm (hc/lambda = 11501 eV). Temperature: 20 C,
# SASBDB cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM Tris, 150 mM NaCl, 0.2% sodium azide', pH 8.5. Paper
# not consulted (SASBDB metadata only). Azide read as w/v (flagged).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.00737-0.6639 A-1, 672 rows, 1
# with sigma <= 0, 13 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 3.1.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header '6O4O_IL1 Dro:0.005 Ra:1.800
# RGT:17.41 Vol: 24931. Chi^2: 1.428'; SASBDB chi2 1.428) against SASDGH2_fit1_model1.pdb:
# single atomic model: 1325 heavy atoms, chain(s) A, 1388 hydrogens, 145 water atoms
# (dropped by the loader), HETATM SO4 x5, CL x1; 130 altloc atoms (counted twice, flagged).
# The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column 4, not
# rescaled. Header Chi^2 equals the SASBDB value and the recomputation against the .dat
# (free scale) agrees. Recomputed 1.428.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.078   # wavelength 1.078 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 20 mM at pH 8.5, 20 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.188 M): 8.17 mM Cl- from the HCl titration
# (sigma 1.56 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, +-2%
    # Cl- of the HCl titration to pH 8.5, 8.17 mM
    NonBiological(0.008173, 0.001556, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
    # 0.2 % w/v NaN3 (65.01 g/mol), 30.8 mM, +-5%
    NonBiological(0.03076, 0.00154, "sodium azide"),
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
    refChi2 = "CRYSOL 1.428",
    pdb = "SASDGH2_fit1_model1.pdb",
    fit = "SASDGH2_fit1.fit",
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

# Builds the Seed that `runSasdgh2` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdgh2` below is the whole story).
function seedSasdgh2(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdgh2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdgh2(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdgh2(run)

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

    # `@__DIR__` (this SASDGH2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
