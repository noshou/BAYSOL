# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDDL3")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDDL3.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDDL3: RNase (monomer, 16.46 kDa), measured at EMBL P12. Publication: Franke D et
# al., "Machine Learning Methods for X-Ray Scattering Data Analysis from Biomacromolecular
# Solutions." Biophys J 2018, DOI 10.1016/j.bpj.2018.04.018 (SASBDB metadata only; the paper
# was not consulted). Entry: https://www.sasbdb.org/data/SASDDL3/.
#
# Instrument (SASBDB): wavelength 0.124 nm (hc/lambda = 9999 eV). Temperature: 10 C, SASBDB
# cell temperature.
#
# Buffer: SASBDB buffer fields: 'phosphate buffered saline (PBS)', pH 7.0 (SASBDB value;
# nominal PBS is 7.4). Paper not consulted (SASBDB metadata only). SASBDB gives no
# concentrations, so the standard 1x PBS recipe (137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4, 1.8
# mM KH2PO4) is assumed, as in the other PBS entries. The pH 7.0 is taken as given.
#
# Curve units: the SASBDB .dat is in 1/nm (q 0.05356-3.495 nm-1), converted to A-1 (divide
# by 10): q 0.00536-0.3495 A-1, 1723 rows, 0 with sigma <= 0, 75 with a non-positive
# intensity. No q cut: the median I/sigma above 0.3 A-1 is 0.7.
#
# Model and depositor fit (fit1_model1): CRYSOL fit (header '3mzq_RNA Dro:0.020 Ra:1.800
# RGT:15.24 Vol: 17808. Chi^2: 0.821'; SASBDB chi2 0.822) against SASDDL3_fit1_model1.pdb:
# single atomic model: 951 heavy atoms, chain(s) A, no hydrogens. The .fit has 4 columns (q,
# I_exp, sigma, I_fit); the reference curve is column 4, not rescaled. Header Chi^2 0.821
# (SASBDB 0.822); recomputed 0.822. The depositor's fit covers q up to 0.320 A-1 while the
# curve extends to 0.349 A-1, so refChi2 is not like for like with the fitted range (no q
# cut is applied).
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
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). PBS 1x taken as 137 mM NaCl, 2.7 mM KCl, 10 mM Na2HPO4 and 1.8
# mM KH2PO4, each +-5 % (the recipe is assumed: SASBDB gives none; the stated pH is used as
# given). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    # 137 mM NaCl, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.137, 0.00685, "sodium chloride"),
    # 2.7 mM KCl, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.0027, 0.000135, "potassium chloride"),
    # 10 mM Na2HPO4, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.01, 0.0005, "disodium hydrogen phosphate"),
    # 1.8 mM KH2PO4, standard 1x PBS, +-5% (assumed recipe)
    NonBiological(0.0018, 9e-05, "potassium dihydrogen phosphate"),
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
    refChi2 = "CRYSOL 0.821",
    pdb = "SASDDL3_fit1_model1.pdb",
    fit = "SASDDL3_fit1.fit",
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

# Builds the Seed that `runSasddl3` samples (separate only so the developer tools can
# build a fit's Seed without running it; `runSasddl3` below is the whole story).
function seedSasddl3(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasddl3(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasddl3(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasddl3(run)

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

    # `@__DIR__` (this SASDDL3/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
