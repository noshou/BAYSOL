# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDF75")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDF75.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDF75: Ric8a (monomer, 50.996 kDa), measured at BioCAT 18ID. Publication:
# Srivastava D et al., "Structural underpinnings of Ric8A function as a G-protein α-subunit
# chaperone and guanine-nucleotide exchange factor." Nat Commun 2019, DOI
# 10.1038/s41467-019-11088-x (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDF75/.
#
# Instrument (SASBDB): wavelength 0.1033 nm (hc/lambda = 12002 eV). Temperature: 25 C,
# SASBDB cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM Tris, 150 mM KCl, 5 % glycerol, 1 mM TCEP', pH 8.0.
# Paper not consulted (SASBDB metadata only). Glycerol read as v/v (flagged); TCEP taken as
# the free acid with no extra counter-ion (flagged).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.00541-0.3813 A-1, 1253 rows, 0
# with sigma <= 0, 37 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 1.2.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'noHis_12 Dro:0.013 Ra:1.800
# RGT:29.42 Vol: 68602. Chi^2: 1.815'; SASBDB chi2 None) against SASDF75_fit1_model1.pdb:
# single atomic model: 3562 heavy atoms, chain(s) A, 3632 hydrogens. The .fit has 4 columns
# (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header Chi^2
# equals the SASBDB value and the recomputation against the .dat (free scale) agrees.
# Recomputed 1.815.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # wavelength 1.033 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 20 mM at pH 8.0, 25 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.162 M): 12.19 mM Cl- from the HCl titration
# (sigma 1.52 mM). Glycerol 5 % (v/v assumed): 0.05 x 1261 g/L / 92.094 g/mol = 0.6846 M,
# +-5 %. Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, +-2%
    # Cl- of the HCl titration to pH 8.0, 12.19 mM
    NonBiological(0.01219, 0.001518, "chloride"),
    NonBiological(0.15, 0.003, "potassium chloride"),   # 150 mM KCl, +-2%
    # 5 % (v/v assumed) glycerol, 0.6846 M, +-5%
    NonBiological(0.6846, 0.0342, "glycerol"),
    NonBiological(0.001, 2e-05, "tcep"),   # 1 mM TCEP, +-2%
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
    refChi2 = "CRYSOL 1.815",
    pdb = "SASDF75_fit1_model1.pdb",
    fit = "SASDF75_fit1.fit",
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

# Builds the Seed that `runSasdf75` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdf75` below is the whole story).
function seedSasdf75(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdf75(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdf75(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdf75(run)

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

    # `@__DIR__` (this SASDF75/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
