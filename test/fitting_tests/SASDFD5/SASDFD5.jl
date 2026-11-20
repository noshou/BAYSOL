# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDFD5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDFD5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDFD5: TetR(D) (dimer, 23.259 kDa), measured at EMBL P12. Publication: Palm GJ et
# al., "Thermodynamics, cooperativity and stability of the tetracycline repressor (TetR)
# upon tetracycline binding." Biochim Biophys Acta Proteins Proteom 2020, DOI
# 10.1016/j.bbapap.2020.140404 (SASBDB metadata only; the paper was not consulted). Entry:
# https://www.sasbdb.org/data/SASDFD5/.
#
# Instrument (SASBDB): wavelength 0.124 nm (hc/lambda = 9999 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: '50 mM Tris/HCl 150 mM NaCl 10 mM MgCl2', pH 8.0. Paper not
# consulted (SASBDB metadata only).
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.03858-4.458 nm-1), converted to A-1 (divide
# by 10): q 0.00386-0.4458 A-1, 1681 rows, 0 with sigma <= 0, 106 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 1.1.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header '4v2f_dim Dro:0.043 Ra:1.400
# RGT:24.67 Vol: 58722. Chi^2: 1.545'; SASBDB chi2 1.545) against SASDFD5_fit1_model1.pdb:
# single atomic model: 3082 heavy atoms, chain(s) AB, no hydrogens. The .fit has 4 columns
# (q, I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header Chi^2
# 1.545 = SASBDB 1.545; recomputed 1.547.
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
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Tris-HCl 50 mM at pH 8.0, 10 C (tris template: Clarke-Glew pK
# at the temperature, Davies activities at I = 0.221 M): 40.78 mM Cl- from the HCl titration
# (sigma 2.63 mM). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "tris"),   # 50 mM Tris-HCl, +-2%
    # Cl- of the HCl titration to pH 8.0, 40.78 mM
    NonBiological(0.040777, 0.002634, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, +-2%
    NonBiological(0.01, 0.0002, "magnesium chloride"),   # 10 mM MgCl2, +-2%
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
    refChi2 = "CRYSOL 1.545",
    pdb = "SASDFD5_fit1_model1.pdb",
    fit = "SASDFD5_fit1.fit",
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

# Builds the Seed that `runSasdfd5` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasdfd5` below is the whole story).
function seedSasdfd5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdfd5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdfd5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdfd5(run)

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

    # `@__DIR__` (this SASDFD5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
