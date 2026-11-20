# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDKS7")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDKS7.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDKS7: HpcH/HpaI aldolase (, A5VH82, Rhizorhabdus wittichii RW1, 27.435 kDa x
# 6). Hydroxypyruvate aldolase (HpcH/HpaI aldolase), wild-type in HEPES, NaCl and MgCl2.
# Publication: Marsden S, Wijma H, Mohr M, Justo I, Hagedoorn P, Laustsen J, Jeffries C,
# Svergun D, Mestrom L, McMillan D, Bento I, Hanefeld U, "Substrate Induced Movement of
# the Metal Cofactor between Active and Resting State", Angewandte Chemie International
# Edition (2022), DOI 10.1002/anie.202213338 (the paper was NOT consulted, except where
# stated: every condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDKS7/.
#
# Instrument (SASBDB): PETRA III EMBL P12 (DESY; Hamburg, Germany), detector Pilatus 6M;
# wavelength 1.24 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of wild-type hydroxypyruvate aldolase in 20 mM HEPES, 100 mM
# NaCl, 20 mg/L MgCl2, pH 7.5 were collected using size exclusion chromatography SAXS
# (SEC-SAXS) on the EMBL P12 beam line at PETRA III (Hamburg, Germany) equipped with a
# Pilatus 6M detector at a sample-detector distance of 3 m and at a wavelength of λ =
# 0.124 nm (l(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "20 mM HEPES, 100 mM NaCl, 20 mg/l MgCl2", pH
# 7.5. Counter-ion: 20 mM HEPES (pK(22 C) = 7.600) at pH 7.5 with Davies activities at I =
# 0.1164 M: the anionic fraction is 0.5066, so Na+ = C x 0.5066 = 10.13 mM (sigma 1.32 mM,
# same sources as for Tris). The titrant is NaOH (not stated; the ordinary choice,
# assumed). The pH is taken as set at room temperature (22 +-3 C). Concentrations carry a
# 2 % sigma unless stated. Every solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.029-7.296 nm-1),
# converted to A-1 (divide by 10): q 0.0029-0.7296 A-1, 2624 rows, 0 with sigma <= 0
# (dropped by the fit subset), 109 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit2_model1): CRYSOL fit, header '6R62_hex Dro:0.005 Ra:1.400
# RGT:33.00 Vol:215378. Chi^2: 1.127', SASBDB chi2 1.127; recomputed from the .fit columns
# 2-4: chi2 1.127. Model SASDKS7_fit2_model1.pdb: 11298 ATOM records (heavy atoms), HETATM
# groups MG x6 atoms (known components, kept by the loader), chains ABCDEF, 8580 deposited
# hydrogens (replaced by pdb2pqr); SASBDB model = PDB 6R62 (identical), PDB 7NUJ (derived)
# (PDB (Protein Data Bank)). Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 11304 heavy atoms in the largest model (VERY LARGE: plan the run time).

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
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 20 mM HEPES (pK(22 C) = 7.600) at pH 7.5 with
# Davies activities at I = 0.1164 M: the anionic fraction is 0.5066, so Na+ = C x 0.5066 =
# 10.13 mM (sigma 1.32 mM, same sources as for Tris). The titrant is NaOH (not stated; the
# ordinary choice, assumed). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "hepes"),   # 20 mM HEPES, ±2%
    # Na+ counter-ion of the HEPES titration (see the note above)
    NonBiological(0.0101326, 0.00131665, "sodium(1+)"),
    NonBiological(0.1, 0.002, "sodium chloride"),   # 100 mM NaCl, ±2%
    NonBiological(0.0021006, 4.201e-05, "magnesium chloride"),   # 20 mg/l MgCl2 = 0.21 mM
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
    refChi2 = "CRYSOL 1.127",
    pdb = "SASDKS7_fit2_model1.pdb",
    fit = "SASDKS7_fit2.fit",
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

# Builds the Seed that `runSasdks7` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdks7` below is the whole story (build the seed, then sample it).
function seedSasdks7(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdks7(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdks7(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdks7(run)

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

    # `@__DIR__` (this SASDKS7/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
