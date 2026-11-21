# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJ92")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJ92.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJ92: Extracellular matrix binding protein F-repeats (rEmbp2588, Q5HPA2,
# Staphylococcus epidermidis, 70.44 kDa x 1). S. epidermidis extracellular matrix binding
# protein (Embp) F-repeats. Publication: Büttner H, Perbandt M, Kohler T, Kikhney A,
# Wolters M, Christner M, Heise M, Wilde J, Weißelberg S, Both A, Betzel C, Hammerschmidt
# S, Svergun D, Aepfelbacher M, Rohde H, "A Giant Extracellular Matrix Binding Protein of
# <i>Staphylococcus epidermidis</i> Binds Surface-Immobilized Fibronectin via a Novel
# Mechanism.", mBio (2020), DOI 10.1128/mBio.01612-20 (the paper was NOT consulted, except
# where stated: every condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDJ92/.
#
# Instrument (SASBDB): DORIS III, DESY EMBL X33 (Hamburg, Germany), detector Pilatus 1M-W;
# wavelength 1.5 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 10.1 C, SASBDB cell temperature. SASBDB experiment description: "".
#
# Buffer (SASBDB, NOT the paper; flagged): "50 mM MES, 150 mM NaCl", pH 6.0. Counter-ion:
# 50 mM MES (pK(22 C) = 6.296) at pH 6.0 with Davies activities at I = 0.1701 M: the
# anionic fraction is 0.4013, so Na+ = C x 0.4013 = 20.07 mM (sigma 3.16 mM, same sources
# as for Tris). The titrant is NaOH (not stated; the ordinary choice, assumed). The pH is
# taken as set at room temperature (22 +-3 C). Concentrations carry a 2 % sigma unless
# stated. Every solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.0855-6.032 nm-1),
# converted to A-1 (divide by 10): q 0.00855-0.6032 A-1, 2170 rows, 0 with sigma <= 0
# (dropped by the fit subset), 2 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'rEmbp2-9 Dro:0.000 Ra:1.800
# RGT:70.02 Vol: 95090. Chi^2: 2.236', SASBDB chi2 2.236; recomputed from the .fit columns
# 2-4: chi2 2.236. Model SASDJ92_fit1_model1.pdb: 4406 ATOM records (heavy atoms), no
# HETATM, chains ABCDEF, no hydrogens; SASBDB model = PDB 6GV8 (derived) (SASREF).
# Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 4406 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 6.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # wavelength 1.5 Å
const TEMPERATURE_C = 10.1

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 50 mM MES (pK(22 C) = 6.296) at pH 6.0 with
# Davies activities at I = 0.1701 M: the anionic fraction is 0.4013, so Na+ = C x 0.4013 =
# 20.07 mM (sigma 3.16 mM, same sources as for Tris). The titrant is NaOH (not stated; the
# ordinary choice, assumed). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.05, 0.001, "mes"),   # 50 mM MES, ±2%
    # Na+ counter-ion of the MES titration (see the note above)
    NonBiological(0.0200663, 0.00316018, "sodium(1+)"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
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
    refChi2 = "CRYSOL 2.236",
    pdb = "SASDJ92_fit1_model1.pdb",
    fit = "SASDJ92_fit1.fit",
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

# Builds the Seed that `runSasdj92` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdj92` below is the whole story (build the seed, then sample it).
function seedSasdj92(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdj92(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdj92(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdj92(run)

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

    # `@__DIR__` (this SASDJ92/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
