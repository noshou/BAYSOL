# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJW5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJW5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJW5: Plasminogen activator inhibitor 1 (PAI-1, P05121, Homo sapiens, 42.73
# kDa x 1); VHH-s-a93 (Ig module Nb93) (Nb93, no UniProt, Vicugna pacos, 13.244 kDa x 1).
# Plasminogen activator inhibitor-1 (PAI-1) W175F bound to nanobody Nb93. Publication:
# Sillen M, Weeks S, Strelkov S, Declerck P, "Structural Insights into the Mechanism of a
# Nanobody That Stabilizes PAI-1 and Modulates Its Activity", International Journal of
# Molecular Sciences (2020), DOI 10.3390/ijms21165859 (the paper was NOT consulted, except
# where stated: every condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDJW5/.
#
# Instrument (SASBDB): SOLEIL SWING (Saint-Aubin, France), detector Eiger 4M; wavelength
# 1.0332 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 15 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of PAI-1 bound to Nb93 in 30 mM BIS-TRIS pH 5.5, 300 mM sodium
# chloride, 5% v/v glycerol were collected on the SWING beam line at SOLEIL (Saint-Aubin,
# France) using a Eiger 4M detector at a sample-detector distance of 2 m and at a
# wavelength of λ = 0.10332 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering
# angle). In-line size-exclusion chromatography (SEC) SAS was ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "30 mM BIS-TRIS pH 5.5, 300 mM sodium chloride,
# 5% v/v glycerol", pH 5.5. Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 30 mM Bis-Tris (pK(22 C) = 6.534) at pH 5.5 with Davies activities at I =
# 0.3281 M: the cationic (protonated) fraction is 0.9366, so Cl- = C x 0.9366 = 28.10 mM
# (sigma 0.78 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). The pH is taken as set at
# room temperature (22 +-3 C). Concentrations carry a 2 % sigma unless stated. Every
# solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.004105-0.566 A-1, 1237
# rows, 0 with sigma <= 0 (dropped by the fit subset), 157 with a non-positive intensity
# (`seedModel` drops the non-positive bins). Q cut 0.5 A-1: above 0.50 A-1 the median
# I/sigma is 0.3 and 39 % of the points have I <= 0 (the README noise-floor rule); the
# depositor's fit range is stated below.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'PAI_Nb93 Dro:0.060 Ra:1.800
# RGT:29.55 Vol: 72261. Chi^2: 1.392', SASBDB chi2 1.392; recomputed from the .fit columns
# 2-4: chi2 1.389. Model SASDJW5_fit1_model1.pdb: 3783 ATOM records (heavy atoms), no
# HETATM, chains ABS, no hydrogens; SASBDB model with no PDB link (Other). Depositor chi2
# used as refChi2: SASBDB chi_square_value.
#
# Size: 4098 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 5.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.0332   # wavelength 1.0332 Å
const TEMPERATURE_C = 15.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 30 mM Bis-Tris (pK(22 C) = 6.534) at pH 5.5 with Davies activities at I =
# 0.3281 M: the cationic (protonated) fraction is 0.9366, so Cl- = C x 0.9366 = 28.10 mM
# (sigma 0.78 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Glycerol: v/v assumed,
# volume fraction x 1261 g/L / 92.094 g/mol (+-5 %). Every solute below is in the bundled
# tables.
const SOLUTES = Solute[
    NonBiological(0.03, 0.0006, "bis-tris"),   # 30 mM Bis-Tris, ±2%
    # Cl- counter-ion of the Bis-Tris titration (see the note above)
    NonBiological(0.0280993, 0.0007822, "chloride"),
    NonBiological(0.3, 0.006, "sodium chloride"),   # 300 mM NaCl, ±2%
    NonBiological(0.684627, 0.0342313, "glycerol"),   # 5 % v/v glycerol (v/v assumed), ±5%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.5 Å⁻¹ (see the Source for the numbers).
const Q_MAX_FIT = 0.5

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
    refChi2 = "CRYSOL 1.392",
    pdb = "SASDJW5_fit1_model1.pdb",
    fit = "SASDJW5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` and `q ≤ Q_MAX_FIT` (0.5 Å⁻¹).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdjw5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjw5` below is the whole story (build the seed, then sample it).
function seedSasdjw5(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjw5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdjw5(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjw5(run)

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

    # `@__DIR__` (this SASDJW5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
