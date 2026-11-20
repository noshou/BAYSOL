# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDF93")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDF93.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDF93: unnamed (tetramer, 33.552 kDa), measured at BM29. Publication: Roche J et
# al., "The archaeal LDH-like malate dehydrogenase from Ignicoccus islandicus displays dual
# substrate recognition, hidden allostery and a non-canonical tetrameric oligomeric
# organization" Journal of Structural Biology 2019, DOI 10.1016/j.jsb.2019.07.006 (SASBDB
# metadata only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDF93/.
#
# Instrument (SASBDB): wavelength 0.125 nm (hc/lambda = 9919 eV). Temperature: 20 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '50 mM Tris-HCl 50 mM NaCl', pH 7.4. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.04474-4.946 nm-1), converted to A-1 (divide
# by 10): q 0.00447-0.4946 A-1, 1040 rows, 0 with sigma <= 0, 6 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 3.0.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'refine.p Dro:0.010 Ra:1.800
# RGT:32.25 Vol:163111. Chi^2: 1.678'; SASBDB chi2 1.678) against SASDF93_fit1_model1.pdb:
# single atomic model: 9395 heavy atoms, chain(s) ABCDEF, no hydrogens, 308 water atoms
# (dropped by the loader), HETATM TAC x58, TB x20, CL x1; 160 altloc atoms (counted twice,
# flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the reference curve is column
# 4, not rescaled. Header Chi^2 equals the SASBDB value and the recomputation against the
# .dat (free scale) agrees. Recomputed 1.678. The depositor's fit covers q up to 0.300 A-1
# while the curve extends to 0.495 A-1, so refChi2 is not like for like with the fitted
# range (no q cut is applied).
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
const ENERGY_EV     = HC_EV_ANGSTROM / 1.25   # wavelength 1.25 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl 50 mM at pH 7.4, 20 C (tris template: Clarke-Glew pK
# at the temperature, Davies activities at I = 0.095 M): 44.63 mM Cl- from the HCl titration
# (sigma 1.77 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris-HCl, +-2%
    # Cl- of the HCl titration to pH 7.4, 44.63 mM
    NonBiological(0.044629, 0.001773, "chloride"),
    NonBiological(0.05, 0.001, "sodium chloride"),   # 50 mM NaCl, +-2%
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
    refChi2 = "CRYSOL 1.678",
    pdb = "SASDF93_fit1_model1.pdb",
    fit = "SASDF93_fit1.fit",
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

# Builds the Seed that `runSasdf93` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdf93` below is the whole story).
function seedSasdf93(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdf93(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdf93(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdf93(run)

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

    # `@__DIR__` (this SASDF93/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
