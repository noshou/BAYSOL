# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDG97")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDG97.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDG97: tbMORNdelta1 (dimer, 39.15 kDa), measured at BM29. Publication: Sajko S et
# al., "Structures of three MORN repeat proteins and a re-evaluation of the proposed
# lipid-binding properties of MORN repeats." PLoS One 2020, DOI 10.1371/journal.pone.0242677
# (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDG97/.
#
# Instrument (SASBDB): wavelength 0.099 nm (hc/lambda = 12524 eV). Temperature: 20 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '20 mM Tris-HCl, 100 mM NaCl', pH 7.5. Paper not consulted
# (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.1007-4.942 nm-1), converted to A-1 (divide by
# 10): q 0.01007-0.4942 A-1, 1029 rows, 0 with sigma <= 0, 5 with a non-positive intensity.
# No q cut: the median I/sigma above 0.3 A-1 is 3.9.
#
# Model and depositor fit (fit2_model1): CRYSOL fit (header 'd1_Model Dro:0.070 Ra:1.400
# RGT:70.35 Vol: 83682. Chi^2: 2.201'; SASBDB chi2 2.201) against SASDG97_fit2_model1.pdb:
# single atomic model: 5262 heavy atoms, chain(s) AB, no hydrogens. The .fit has 4 columns
# (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header Chi^2
# 2.201 = SASBDB 2.201 (fit2, 'Custom in-house'); recomputed 2.201. fit2 of SASBDB (fit1 is
# DAMMIF).
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
const ENERGY_EV     = HC_EV_ANGSTROM / 0.99   # wavelength 0.99 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl 20 mM at pH 7.5, 20 C (tris template: Clarke-Glew pK
# at the temperature, Davies activities at I = 0.117 M): 17.40 mM Cl- from the HCl titration
# (sigma 0.80 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris-HCl, +-2%
    # Cl- of the HCl titration to pH 7.5, 17.40 mM
    NonBiological(0.017403, 0.000801, "chloride"),
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
    tag = "fit2_model1",
    refChi2 = "CRYSOL 2.201",
    pdb = "SASDG97_fit2_model1.pdb",
    fit = "SASDG97_fit2.fit",
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

# Builds the Seed that `runSasdg97` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdg97` below is the whole story).
function seedSasdg97(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdg97(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdg97(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdg97(run)

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

    # `@__DIR__` (this SASDG97/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
