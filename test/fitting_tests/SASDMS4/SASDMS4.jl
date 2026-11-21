# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDMS4")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMS4.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMS4: Internalin B (InlB, P0DQD3, Listeria monocytogenes serotype 1/2a (strain
# EGD / Mackaness), 35.813 kDa x 1). Listeria monocytogenes invasion protein internalin B.
# Publication: Niemann H, Petoukhov M, Härtlein M, Moulin M, Gherardi E, Timmins P, Heinz
# D, Svergun D, "X-ray and Neutron Small-Angle Scattering Analysis of the Complex Formed
# by the Met Receptor and the Listeria monocytogenes Invasion Protein InlB", Journal of
# Molecular Biology (2008), DOI 10.1016/j.jmb.2008.01.027 (the paper was NOT consulted,
# except where stated: every condition below is the SASBDB entry metadata, flagged).
# Entry: https://www.sasbdb.org/data/SASDMS4/.
#
# Instrument (SASBDB): DORIS III, DESY EMBL X33 (Hamburg, Germany), detector 1D Gas
# detector; wavelength 1.5 A (SASBDB wavelength field / experiment description); energy
# HC/lambda. Temperature: the 25 C DEFAULT (SASBDB gives no temperature for this entry;
# flagged). SASBDB experiment description: "".
#
# Buffer (SASBDB, NOT the paper; flagged): "25mM Na-phosphate buffer, 150 mM NaCl, 1mM
# DTT", pH 7.5. Phosphate: 25 mM total sodium phosphate at pH 7.5 (pK2(22 C) = 7.205,
# Davies I = 0.2164 M): the HPO4(2-) fraction is 0.8274, so the mix is 20.68 mM of the
# dibasic and 4.32 mM of the monobasic salt (sigma 1.52 mM; the ratio is not stated, so it
# is the one that gives the stated pH, assumed). The pH is taken as set at room
# temperature (22 +-3 C). Concentrations carry a 2 % sigma unless stated. Every solute
# below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1602-3.254 nm-1),
# converted to A-1 (divide by 10): q 0.01602-0.3254 A-1, 881 rows, 0 with sigma <= 0
# (dropped by the fit subset), 28 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'inlb.pdb Dro:0.075 Ra:1.400
# RGT:26.50 Vol: 43655. Chi^2: 2.969', SASBDB chi2 2.969; recomputed from the .fit columns
# 2-4: chi2 2.969. Model SASDMS4_fit1_model1.pdb: 2257 ATOM records (heavy atoms), no
# HETATM, chains A, no hydrogens; SASBDB model = PDB 2UZX (identical) (PDB (Protein Data
# Bank)). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 2257 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.5   # wavelength 1.5 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Phosphate: 25 mM total sodium phosphate at pH 7.5 (pK2(22 C)
# = 7.205, Davies I = 0.2164 M): the HPO4(2-) fraction is 0.8274, so the mix is 20.68 mM
# of the dibasic and 4.32 mM of the monobasic salt (sigma 1.52 mM; the ratio is not
# stated, so it is the one that gives the stated pH, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    # HPO4(2-) part (20.68 mM)
    NonBiological(0.0206847, 0.0015156, "disodium hydrogen phosphate"),
    # H2PO4(-) part (4.32 mM)
    NonBiological(0.00431525, 0.0015156, "sodium dihydrogen phosphate"),
    NonBiological(0.15, 0.003, "sodium chloride"),   # 150 mM NaCl, ±2%
    NonBiological(0.001, 2e-05, "dtt"),   # 1 mM DTT, ±2%
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
    refChi2 = "CRYSOL 2.969",
    pdb = "SASDMS4_fit1_model1.pdb",
    fit = "SASDMS4_fit1.fit",
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

# Builds the Seed that `runSasdms4` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdms4` below is the whole story (build the seed, then sample it).
function seedSasdms4(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdms4(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdms4(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdms4(run)

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

    # `@__DIR__` (this SASDMS4/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
