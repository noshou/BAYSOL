# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJX7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJX7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJX7: Similar to Aedes aegypti 34 kDa salivary secreted protein 34k-2 (LIPS-2,
# Q5MIU2, Aedes albopictus, 34.586 kDa x 1). Labrum-Interacting Proteins from Saliva 2
# (34k-2) - SEC-SAXS. Publication: Arnoldi I, Mancini G, Fumagalli M, Gastaldi D, D'Andrea
# L, Bandi C, Di Venere M, Iadarola P, Forneris F, Gabrieli P, "A salivary factor binds a
# cuticular protein and modulates biting by inducing morphological changes in the mosquito
# labrum.", Curr Biol (2022), DOI 10.1016/j.cub.2022.06.049 (the paper was NOT consulted,
# except where stated: every condition below is the SASBDB entry metadata, flagged).
# Entry: https://www.sasbdb.org/data/SASDJX7/.
#
# Instrument (SASBDB): ESRF BM29 (Grenoble, France), detector Pilatus 1M; wavelength
# 0.99187 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of labrum-interacting protein from saliva in 25 mM HEPES/NaOH,
# 0.1 M NaCl, pH 8 were collected on the BM29 beam line at the ESRF (Grenoble, France)
# using a Pilatus 1M detector at a sample-detector distance of 2.9 m and at a wavelength
# of λ = 0.099 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). Size
# exclusion chromatography coupled to SAXS (SEC-SAXS) was ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "25 mM HEPES, 0.1 M NaCl", pH 8.0. Counter-ion:
# 25 mM HEPES (pK(22 C) = 7.600) at pH 8.0 with Davies activities at I = 0.1191 M: the
# anionic fraction is 0.7648, so Na+ = C x 0.7648 = 19.12 mM (sigma 1.19 mM, same sources
# as for Tris). The titrant is NaOH (not stated; the ordinary choice, assumed). The pH is
# taken as set at room temperature (22 +-3 C). Concentrations carry a 2 % sigma unless
# stated. Every solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm), q 0.09133-4.694 nm-1
# = 0.009133-0.4694 A-1 (the depositor's .fit ends at 0.4694 A-1), 978
# rows, 0 with sigma <= 0 (dropped by the fit subset), 0 with a non-positive intensity
# (`seedModel` drops the non-positive bins). No q cut: the README noise-floor rule (median
# I/sigma below 0.5 together with about a quarter of the points non-positive) is not met
# over any useful part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'file.pdb Dro:0.025 Ra:1.800
# RGT:26.08 Vol: 46331. Chi^2: 1.666', SASBDB chi2 1.666; recomputed from the .fit columns
# 2-4: chi2 1.666. Model SASDJX7_fit1_model1.pdb: 2424 ATOM records (heavy atoms), no
# HETATM, chains A, no hydrogens; SASBDB model with no PDB link (AllosMod). Depositor chi2
# used as refChi2: SASBDB chi_square_value.
#
# Size: 2424 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹ (the file's `angular-unit: nanometer`); convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.99187   # wavelength 0.99187 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 25 mM HEPES (pK(22 C) = 7.600) at pH 8.0 with
# Davies activities at I = 0.1191 M: the anionic fraction is 0.7648, so Na+ = C x 0.7648 =
# 19.12 mM (sigma 1.19 mM, same sources as for Tris). The titrant is NaOH (not stated; the
# ordinary choice, assumed). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.025, 0.0005, "hepes"),   # 25 mM HEPES, ±2%
    # Na+ counter-ion of the HEPES titration (see the note above)
    NonBiological(0.019121, 0.0011887, "sodium(1+)"),
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM NaCl, ±2%
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
    refChi2 = "CRYSOL 1.666",
    pdb = "SASDJX7_fit1_model1.pdb",
    fit = "SASDJX7_fit1.fit",
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

# Builds the Seed that `runSasdjx7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjx7` below is the whole story (build the seed, then sample it).
function seedSasdjx7(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjx7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdjx7(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjx7(run)

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

    # `@__DIR__` (this SASDJX7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
