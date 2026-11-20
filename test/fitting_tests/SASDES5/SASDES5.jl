# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDES5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDES5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDES5: mmNT-SRCR3 (monomer, 13.165 kDa), measured at BM29. Publication: Canciani
# A et al., "Structural characterization of the third scavenger receptor cysteine-rich
# domain of murine neurotrypsin." Protein Sci 2019, DOI 10.1002/pro.3587 (SASBDB metadata
# only; the paper was not consulted). Entry: https://www.sasbdb.org/data/SASDES5/.
#
# Instrument (SASBDB): wavelength 0.09919 nm (hc/lambda = 12500 eV). Temperature: 20 C,
# SASBDB cell temperature.
#
# Buffer: SASBDB buffer fields: '25 mM HEPES, 0.1 M NaCl', pH 8.0. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.03266-4.944 nm-1), converted to A-1 (divide
# by 10): q 0.00327-0.4944 A-1, 1043 rows, 0 with sigma <= 0, 30 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 1.6.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header 'A.pdb Dro:0.035 Ra:1.760
# RGT:14.61 Vol: 15511. Chi^2: 1.399'; SASBDB chi2 1.399) against SASDES5_fit1_model1.pdb:
# single atomic model: 827 heavy atoms, chain(s) A, no hydrogens. The .fit has 3 columns (q,
# I_exp, I_fit); the reference curve is column 3, not rescaled. Header Chi^2 equals the
# SASBDB value and the recomputation against the .dat (free scale) agrees. Recomputed 1.402.
#
# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.9919   # wavelength 0.9919 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). HEPES 25 mM at pH 8.0, 20 C (hepes template, Davies at I =
# 0.119 M): 18.86 mM Na+ from the NaOH titration (sigma 1.27 mM). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),   # 25 mM HEPES, +-2%
    # Na+ of the NaOH titration to pH 8.0, 18.86 mM
    NonBiological(0.018864, 0.00127, "sodium(1+)"),
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
    refChi2 = "CRYSOL 1.399",
    pdb = "SASDES5_fit1_model1.pdb",
    fit = "SASDES5_fit1.fit",
    fitScale = 1.0,
    fitCol = 3,
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

# Builds the Seed that `runSasdes5` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdes5` below is the whole story).
function seedSasdes5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdes5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdes5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdes5(run)

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

    # `@__DIR__` (this SASDES5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
