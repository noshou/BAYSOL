# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDD33")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDD33.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDD33: MbcT (hexamer, 20.248 kDa); MbcA (hexamer, 12.616 kDa), measured at EMBL
# P12. Publication: Freire DM et al., "An NAD<sup>+</sup> Phosphorylase Toxin Triggers
# Mycobacterium tuberculosis Cell Death." Mol Cell 2019, DOI 10.1016/j.molcel.2019.01.028
# (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDD33/.
#
# Instrument (SASBDB): wavelength 0.124 nm (hc/lambda = 9999 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '100 mM HEPES, 100 mM NaCl', pH 7.5. Paper not consulted
# (SASBDB metadata only). MbcT/MbcA assembly (SASBDB lists both as hexamers; the model has
# 12 chains).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.09829-4.801 nm-1), converted to A-1 (divide
# by 10): q 0.00983-0.4801 A-1, 1781 rows, 0 with sigma <= 0, 209 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 0.9.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'AT1_dode Dro:0.010 Ra:1.620
# RGT:40.65 Vol:256535. Chi^2: 1.007'; SASBDB chi2 1.007) against SASDD33_fit1_model1.pdb:
# single atomic model: 13515 heavy atoms, chain(s) ABCDEFGHIJKL, no hydrogens; 72 altloc
# atoms (counted twice, flagged). The .fit has 4 columns (q, I_exp, sigma, I_fit); the
# reference curve is column 4, not rescaled. Header Chi^2 equals the SASBDB value and the
# recomputation against the .dat (free scale) agrees. Recomputed 1.007. The depositor's fit
# covers q up to 0.335 A-1 while the curve extends to 0.480 A-1, so refChi2 is not like for
# like with the fitted range (no q cut is applied).
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 100 mM at pH 7.5, 10 C (hepes template, Davies at I =
# 0.142 M): 42.44 mM Na+ from the NaOH titration (sigma 6.55 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.1, 0.002, "hepes"),   # 100 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 7.5, 42.44 mM
    NonBiological(0.042443, 0.006554, "sodium(1+)"),
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
    refChi2 = "CRYSOL 1.007",
    pdb = "SASDD33_fit1_model1.pdb",
    fit = "SASDD33_fit1.fit",
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

# Builds the Seed that `runSasdd33` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdd33` below is the whole story).
function seedSasdd33(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdd33(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdd33(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdd33(run)

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

    # `@__DIR__` (this SASDD33/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
