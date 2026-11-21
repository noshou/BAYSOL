# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJ75")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJ75.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJ75: Piwi protein AF_1318 (AfAgo, O28951, Archaeoglobus fulgidus, 49.243 kDa
# x 2). apo Archaeoglobus fulgidus Argonaute protein. Publication: , "", (), DOI not
# listed in SASBDB (the paper was NOT consulted, except where stated: every condition
# below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDJ75/.
#
# Instrument (SASBDB): PETRA III EMBL P12 (DESY; Hamburg, Germany), detector Pilatus 2M;
# wavelength 1.24 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of apo Archaeoglobus fulgidus Argonaute protein in 20 mM
# TrisHCl, pH 7.5, 5 mM MgCl2, 500 mM NaCl and 2 mM DTT, pH 7.5 were collected on the EMBL
# P12 beam line at PETRA III (Hamburg, Germany) using a Pilatus 2M detector at a
# sample-detector distance of 3 m and at a wavelength of λ = 0.124 nm (I(s) vs s, where s
# = 4πsinθ/λ, and 2θ is the scattering angle). One solute concentration ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "20 mM TrisHCl, pH 7.5, 5 mM MgCl2, 500 mM NaCl
# and 2 mM DTT", pH 7.5. Counter-ion: setting the pH adds a titrant that the recipe does
# not list. 20 mM Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I = 0.5322
# M: the cationic (protonated) fraction is 0.8605, so Cl- = C x 0.8605 = 17.21 mM (sigma
# 0.90 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The
# titrant is HCl (not stated; the ordinary choice, assumed). The pH is taken as set at
# room temperature (22 +-3 C). Concentrations carry a 2 % sigma unless stated. Every
# solute below is in the bundled tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm), q 0.02493-5.064 nm-1 =
# 0.002493-0.5064 A-1, 1827
# rows, 0 with sigma <= 0 (dropped by the fit subset), 482 with a non-positive intensity
# (`seedModel` drops the non-positive bins). Q cut 0.2 A-1: above 0.20 A-1 the median
# I/sigma is 0.3 and 35-45 % of the points have I <= 0 (0.10-0.20: 1.5, 13 %) (the README
# noise-floor rule); the depositor's fit range is stated below.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'dim-1w9h Dro:0.075 Ra:1.400
# RGT:38.93 Vol:125483. Chi^2: 1.699', SASBDB chi2 1.699; recomputed from the .fit columns
# 2-4: chi2 1.698. Model SASDJ75_fit1_model1.pdb: 6466 ATOM records (heavy atoms), HETATM
# groups CD x4 atoms, NI x10 atoms, CL x8 atoms (known components, kept by the loader),
# chains AD, no hydrogens; SASBDB model = PDB 1W9H (derived) (Other). Depositor chi2 used
# as refChi2: SASBDB chi_square_value.
#
# Model and depositor fit (fit2_model1): CRYSOL fit, header 'dim-1ytu Dro:0.060 Ra:1.400
# RGT:36.22 Vol:131855. Chi^2: 1.252', SASBDB chi2 1.252; recomputed from the .fit columns
# 2-4: chi2 1.253. Model SASDJ75_fit2_model1.pdb: 6654 ATOM records (heavy atoms), HETATM
# groups MSE x160 atoms, MG x2 atoms (known components, kept by the loader), chains AB, no
# hydrogens; SASBDB model with no PDB link (Other). Depositor chi2 used as refChi2: SASBDB
# chi_square_value.
#
# Size: 6964 heavy atoms in the largest model.

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹ (the file's `angular-unit: nanometer`; the depositor's .fit q equals
# these divided by 10); convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.5, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 20 mM Tris (pK(22 C) = 8.157) at pH 7.5 with Davies activities at I =
# 0.5322 M: the cationic (protonated) fraction is 0.8605, so Cl- = C x 0.8605 = 17.21 mM
# (sigma 0.90 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris-HCl, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.0172095, 0.0008959, "chloride"),
    NonBiological(0.005, 0.0001, "magnesium chloride"),   # 5 mM MgCl2, ±2%
    NonBiological(0.5, 0.01, "sodium chloride"),   # 500 mM NaCl, ±2%
    NonBiological(0.002, 4e-05, "dtt"),   # 2 mM DTT, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.2 Å⁻¹ (see the Source for the numbers).
const Q_MAX_FIT = 0.2

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
        refChi2 = "CRYSOL 1.699",
        pdb = "SASDJ75_fit1_model1.pdb",
        fit = "SASDJ75_fit1.fit",
        fitScale = 1.0,
        fitCol = 4,
        rescale = false,
        software = "CRYSOL",
    ),
    (
        tag = "fit2_model1",
        refChi2 = "CRYSOL 1.252",
        pdb = "SASDJ75_fit2_model1.pdb",
        fit = "SASDJ75_fit2.fit",
        fitScale = 1.0,
        fitCol = 4,
        rescale = false,
        software = "CRYSOL",
    ),
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` and `q ≤ Q_MAX_FIT` (0.2 Å⁻¹).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdj75` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdj75` below is the whole story (build the seed, then sample it).
function seedSasdj75(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdj75(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdj75(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdj75(run)

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

    # `@__DIR__` (this SASDJ75/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
