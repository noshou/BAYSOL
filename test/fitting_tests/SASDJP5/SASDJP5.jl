# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJP5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJP5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJP5: Tetanus toxin (TeNT/blHn, P04958, Clostridium tetani, 34.587 kDa x 1).
# Beltless isolated translocation domain of tetanus nerotoxin (TeNT/blHn). Publication:
# Zhang CM, Imoto Y, Hikima T, Inoue T, "Structural flexibility of the tetanus neurotoxin
# revealed by crystallographic and solution scattering analyses.", J Struct Biol X (2021),
# DOI 10.1016/j.yjsbx.2021.100045 (the paper was NOT consulted, except where stated: every
# condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDJP5/.
#
# Instrument (SASBDB): SPring-8 BL45XU (Hyōgo Prefecture, Japan), detector Pilatus3 X 2M;
# wavelength 1 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of the beltless isolated translocation domain of the tetanus
# nerotoxin (TeNT/blHn) in 10 mM HEPES 100 mM NaCl, pH 7.4 were collected on the BL45XU
# beam line at SPring-8 (Hyōgo Prefecture, Japan) using a Pilatus3 X 2M detector at a
# sample-detector distance of 2.1 m and at a wavelength of λ = 0.1 nm (I(s) vs s, where s
# = 4πsinθ/λ, and 2θ is the scattering angle). In-line ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "10 mM HEPES 100 mM NaCl", pH 7.4. Counter-ion:
# 10 mM HEPES (pK(22 C) = 7.600) at pH 7.4 with Davies activities at I = 0.1045 M: the
# anionic fraction is 0.4473, so Na+ = C x 0.4473 = 4.47 mM (sigma 0.65 mM, same sources
# as for Tris). The titrant is NaOH (not stated; the ordinary choice, assumed). The pH is
# taken as set at room temperature (22 +-3 C). Concentrations carry a 2 % sigma unless
# stated. Every solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.01204-0.3972 A-1, 738
# rows, 0 with sigma <= 0 (dropped by the fit subset), 4 with a non-positive intensity
# (`seedModel` drops the non-positive bins). No q cut: the README noise-floor rule (median
# I/sigma below 0.5 together with about a quarter of the points non-positive) is not met
# over any useful part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'TeNT_iHN Dro:0.025 Ra:1.800
# RGT:30.55 Vol: 45459. Chi^2: 1.297', SASBDB chi2 1.297; the .fit has no sigma column to
# recompute from. Model SASDJP5_fit1_model1.pdb: 2447 ATOM records (heavy atoms), no
# HETATM, chains A, no hydrogens, 8 alternate-location atoms (the loader's altloc handling
# applies); SASBDB model = PDB 7BXX (identical) (PDB (Protein Data Bank)). Depositor chi2
# used as refChi2: SASBDB chi_square_value.
#
# Size: 2447 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1   # wavelength 1 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: 10 mM HEPES (pK(22 C) = 7.600) at pH 7.4 with
# Davies activities at I = 0.1045 M: the anionic fraction is 0.4473, so Na+ = C x 0.4473 =
# 4.47 mM (sigma 0.65 mM, same sources as for Tris). The titrant is NaOH (not stated; the
# ordinary choice, assumed). Every solute below is in the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.01, 0.0002, "hepes"),   # 10 mM HEPES, ±2%
    # Na+ counter-ion of the HEPES titration (see the note above)
    NonBiological(0.0044734, 0.0006536, "sodium(1+)"),
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
    refChi2 = "CRYSOL 1.297",
    pdb = "SASDJP5_fit1_model1.pdb",
    fit = "SASDJP5_fit1.fit",
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

# Builds the Seed that `runSasdjp5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjp5` below is the whole story (build the seed, then sample it).
function seedSasdjp5(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjp5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdjp5(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjp5(run)

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

    # `@__DIR__` (this SASDJP5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
