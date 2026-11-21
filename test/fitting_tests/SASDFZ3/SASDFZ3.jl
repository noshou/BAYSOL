# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDFZ3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDFZ3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDFZ3: YjhC (dimer, 43.048 kDa), measured at SAXS/WAXS. Publication: Horne CR et
# al., "On the structure and function of Escherichia coli YjhC: an oxidoreductase involved
# in bacterial sialic acid metabolism." Proteins 2019, DOI 10.1002/prot.25846 (SASBDB
# metadata only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDFZ3/.
#
# Instrument (SASBDB): wavelength 0.10332 nm (hc/lambda = 12000 eV). Temperature: 12 C,
# SASBDB cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM Tris, 150 mM NaCl, 0.1 % (w/v) sodium azide, 5 %
# (v/v) glycerol', pH 8.0, 12 C. Paper not consulted (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/A, already A-1: q 0.01207-0.5001 A-1, 670 rows, 0
# with sigma <= 0, 2 with a non-positive intensity. No q cut: the median I/sigma above 0.3
# A-1 is 1.1.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'YjhC_ref Dro:0.048 Ra:1.800
# RGT:31.00 Vol:107040. Chi^2: 0.623'; SASBDB chi2 0.623) against SASDFZ3_fit1_model1.pdb:
# single atomic model: 5729 heavy atoms, chain(s) ABC, 5617 hydrogens, 678 water atoms
# (dropped by the loader), HETATM NAD x140, SO4 x15; 453 altloc atoms (counted twice,
# flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column
# 4, not rescaled. Header Chi^2 0.623 = SASBDB 0.623; recomputed 0.622. The model has chains
# A, B, C (SASBDB lists YjhC as a dimer), 140 NAD atoms and 453 altloc atoms.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹ (SASBDB angular_unit 1/A).
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0332   # wavelength 1.0332 Å
const TEMPERATURE_C = 12.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris 20 mM at pH 8.0, 12 C (tris template: Clarke-Glew pK at
# the temperature, Davies activities at I = 0.181 M): 15.82 mM Cl- from the HCl titration
# (sigma 1.13 mM). Glycerol 5 % v/v: 0.05 x 1261 g/L / 92.094 g/mol = 0.6846 M, +-5 %. Every
# solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, +-2%
    # Cl- of the HCl titration to pH 8.0, 15.82 mM
    NonBiological(0.015822, 0.001133, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
    # 0.1 % w/v NaN3 (65.01 g/mol), 15.4 mM, +-5%
    NonBiological(0.01538, 0.00077, "sodium azide"),
    NonBiological(0.6846, 0.0342, "glycerol"),   # 5 % v/v glycerol, 0.6846 M, +-5%
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
    refChi2 = "CRYSOL 0.623",
    pdb = "SASDFZ3_fit1_model1.pdb",
    fit = "SASDFZ3_fit1.fit",
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

# Builds the Seed that `runSasdfz3` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdfz3` below is the whole story).
function seedSasdfz3(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdfz3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdfz3(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdfz3(run)

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

    # `@__DIR__` (this SASDFZ3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
