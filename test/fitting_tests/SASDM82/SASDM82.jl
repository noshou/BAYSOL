# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDM82")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDM82.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDM82: Ubiquitin fold modifer 1 (UFM1, P61960, Homo sapiens, 8.927 kDa x 1).
# Ubiquitin-fold modifier 1. Publication: Fuchs S, Kikhney A, Schubert R, Kaiser C, Liebau
# E, Svergun D, Betzel C, Perbandt M, "Structure and dynamics of UBA5-UFM1 complex
# formation showing new insights in the UBA5 activation mechanism", Journal of Structural
# Biology (2021), DOI 10.1016/j.jsb.2021.107796 (the paper was NOT consulted, except where
# stated: every condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDM82/.
#
# Instrument (SASBDB): PETRA III EMBL P12 (DESY; Hamburg, Germany), detector Pilatus 6M;
# wavelength 1.23982 A (SASBDB wavelength field / experiment description); energy
# HC/lambda. Temperature: 15 C, SASBDB cell temperature. SASBDB experiment description:
# "".
#
# Buffer (SASBDB, NOT the paper; flagged): "20 mM Tris, 150 mM NaCl, 2 mM DTT", pH 7.5.
# Counter-ion: setting the pH adds a titrant that the recipe does not list. 20 mM Tris
# (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I = 0.1671 M: the cationic
# (protonated) fraction is 0.8573, so Cl- = C x 0.8573 = 17.15 mM (sigma 0.90 mM: sigma_pH
# = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not
# stated; the ordinary choice, assumed). The pH is taken as set at room temperature (22
# +-3 C). Concentrations carry a 2 % sigma unless stated. Every solute below is in the
# bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.02384-7.313 nm-1),
# converted to A-1 (divide by 10): q 0.002384-0.7313 A-1, 1316 rows, 0 with sigma <= 0
# (dropped by the fit subset), 134 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header '1wxs.pdb Dro:0.007 Ra:1.800
# RGT:14.56 Vol: 12783. Chi^2: 1.011', SASBDB chi2 1.011; recomputed from the .fit columns
# 2-4: chi2 1.015. Model SASDM82_fit1_model1.pdb: 658 ATOM records (heavy atoms), no
# HETATM, chains A, 578 deposited hydrogens (replaced by pdb2pqr); SASBDB model = PDB 1WXS
# (identical) (PDB (Protein Data Bank)). Depositor chi2 used as refChi2: SASBDB
# chi_square_value.
#
# Size: 658 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.23982   # wavelength 1.23982 Å
const TEMPERATURE_C = 15.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 20 mM Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I =
# 0.1671 M: the cationic (protonated) fraction is 0.8573, so Cl- = C x 0.8573 = 17.15 mM
# (sigma 0.90 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.0171467, 0.000904, "chloride"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
    NonBiological(0.002, 4e-05, "dtt"),   # 2 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# No q cut (see the Source for the numbers): the README's noise-floor rule is not met over
# any useful part of the curve.
const Q_MAX_FIT = Inf

# The spherical-harmonic band limit lMax is not set here: `seedModel` takes it from
# the diameter of the scatterer cloud and the largest fitted q (ceil(qMax * D)), and
# bins the curve to the Shannon channels that diameter allows (see `rebin` there).

# pdb2pqr/PROPKA place the hydrogens at PH (any deposited ones are replaced); the loader
# drops HETATM waters.
const ADD_HYDROGENS = true

# One run per atomic model with a deposited fit; `fit` is that model's
# reference curve (q scaled to Å⁻¹ by `fitScale`; the fitted intensity is
# column `fitCol`; `rescale` = the file is normalized, scale it to the data).
const RUNS = [
    (
    tag = "fit1_model1",
    refChi2 = "CRYSOL 1.011",
    pdb = "SASDM82_fit1_model1.pdb",
    fit = "SASDM82_fit1.fit",
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

# Builds the Seed that `runSasdm82` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdm82` below is the whole story (build the seed, then sample it).
function seedSasdm82(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdm82(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdm82(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdm82(run)

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

    # `@__DIR__` (this SASDM82/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
