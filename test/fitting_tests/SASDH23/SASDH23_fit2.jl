# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDH23")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDH23.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDH23: Alpha domain of Ag43a (Ag43, P39180, Escherichia coli, 49.087 kDa x 1).
# Antigen 43 alpha domain. Publication: Heras B, Totsika M, Peters KM, Paxman JJ, Gee CL,
# Jarrott RJ, Perugini MA, Whitten AE, Schembri MA, "The antigen 43 structure reveals a
# molecular Velcro-like mechanism of autotransporter-mediated bacterial clumping.", Proc
# Natl Acad Sci U S A (2014), DOI 10.1073/pnas.1311592111 (the paper was NOT consulted,
# except where stated: every condition below is the SASBDB entry metadata, flagged).
# Entry: https://www.sasbdb.org/data/SASDH23/.
#
# Instrument (SASBDB): Australian Synchrotron SAXS/WAXS (Melbourne, Australia), detector
# Pilatus 1M; wavelength 1.033 A (SASBDB wavelength field / experiment description);
# energy HC/lambda. Temperature: 10 C, SASBDB cell temperature. SASBDB experiment
# description: "X-ray synchrotron radiation scattering data from Ag43a in 25 mM HEPES 150
# mM NaCl, pH 7.0 were collected on the SAXS/WAXS beam line of the Australian Synchrotron
# (Melbourne, Australia) using a 2D Photon counting Pilatus 1M-W pixel detector (s = 4π
# sin θ/λ, where 2θ is the scattering angle). Six successive 2 second frames were
# collected at 3.4 mg/ml. The data were normalized to the intensity of the transmitted
# beam ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "25 mM HEPES, 150 mM NaCl", pH 7.0.
# Counter-ion: 25 mM HEPES (pK(22 C) = 7.600) at pH 7.0 with Davies activities at I =
# 0.1562 M: the anionic fraction is 0.2488, so Na+ = C x 0.2488 = 6.22 mM (sigma 1.28 mM,
# same sources as for Tris). The titrant is NaOH (not stated; the ordinary choice,
# assumed). The pH is taken as set at room temperature (22 +-3 C). Concentrations carry a
# 2 % sigma unless stated. Every solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.00987-0.5001 A-1, 158
# rows, 0 with sigma <= 0 (dropped by the fit subset), 0 with a non-positive intensity
# (`seedModel` drops the non-positive bins). No q cut: the README noise-floor rule (median
# I/sigma below 0.5 together with about a quarter of the points non-positive) is not met
# over any useful part of the curve.
#
# Model and depositor fit (fit2_model1): CRYSOL fit, header 'begostru Dro:0.063 Ra:1.780
# RGE:32.98 RGT:32.46 Vol: 55691. Chi:', SASBDB chi2 0.743044; the .fit has no sigma
# column to recompute from. Model SASDH23_fit2_model1.pdb: 3477 ATOM records (heavy
# atoms), no HETATM, chains A, no hydrogens; SASBDB model = PDB 4KH3 (identical) (PDB
# (Protein Data Bank)). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 3477 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.033   # wavelength 1.033 Å
const TEMPERATURE_C = 10.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 25 mM HEPES (pK(22 C) = 7.600) at pH 7.0 with
# Davies activities at I = 0.1562 M: the anionic fraction is 0.2488, so Na+ = C x 0.2488 =
# 6.22 mM (sigma 1.28 mM, same sources as for Tris). The titrant is NaOH (not stated; the
# ordinary choice, assumed). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),   # 25 mM HEPES, ±2%
    # Na+ counter-ion of the HEPES titration (see the note above)
    NonBiological(0.00622043, 0.00128349, "sodium(1+)"),
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
    tag = "fit2_model1",
    refChi2 = "CRYSOL 0.743044",
    pdb = "SASDH23_fit2_model1.pdb",
    fit = "SASDH23_fit2.fit",
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

# Builds the Seed that `runSasdh23` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdh23` below is the whole story (build the seed, then sample it).
function seedSasdh23(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdh23(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdh23(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdh23(run)

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

    # `@__DIR__` (this SASDH23/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
