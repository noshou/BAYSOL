# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDJC5")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDJC5.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDJC5: SUN domain-containing protein 1 (SUN1, O94901, Homo sapiens, 22.51 kDa x
# 6); Nesprin-4 (SYNE4, Q8N205, Homo sapiens, 3.301 kDa x 6). LINC complex between the SUN
# domain of SUN1 and KASH domain of Nesprin-4 - SUN1-KASH4 6:6 complex. Publication:
# Gurusaran M, Davies OR, "A molecular mechanism for LINC complex branching by
# structurally diverse SUN-KASH 6:6 assemblies.", Elife (2021), DOI 10.7554/eLife.60175
# (the paper was NOT consulted, except where stated: every condition below is the SASBDB
# entry metadata, flagged). Entry: https://www.sasbdb.org/data/SASDJC5/.
#
# Instrument (SASBDB): Diamond Light Source B21 (Didcot, UK), detector Pilatus 2M;
# wavelength 0.95 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of the Nesprin-4-KASH/SUN1 6:6 complex in 20 mM Tris pH 8.0,
# 150 mM KCl, were collected on the B21 beam line at the Diamond Light Source (Didcot, UK)
# using a Pilatus 2M detector at a wavelength of λ = 0.095 nm (I(s) vs s, where s =
# 4πsinθ/λ, and 2θ is the scattering angle). In-line size-exclusion chromatography (SEC)
# SAS was employed. The SEC parameters were as follows: A 100.00 ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "20 mM Tris pH 8.0, 150 mM KCl", pH 8.0.
# Counter-ion: setting the pH adds a titrant that the recipe does not list. 20 mM Tris
# (pK(22 C) = 8.157) at pH 8.0 with Davies activities at I = 0.1631 M: the cationic
# (protonated) fraction is 0.6549, so Cl- = C x 0.6549 = 13.10 mM (sigma 1.50 mM: sigma_pH
# = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not
# stated; the ordinary choice, assumed). The pH is taken as set at room temperature (22
# +-3 C). Concentrations carry a 2 % sigma unless stated. Every solute below is in the
# bundled tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.0035-0.3698 A-1, 1649
# rows, 0 with sigma <= 0 (dropped by the fit subset), 163 with a non-positive intensity
# (`seedModel` drops the non-positive bins). Q cut 0.3 A-1: above 0.30 A-1 the median
# I/sigma is 0.4 and 33 % of the points have I <= 0 (0.20-0.30: 1.1, 13 %) (the README
# noise-floor rule); the depositor's fit range is stated below.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'SUN1-KAS Dro:0.025 Ra:1.400
# RGT:38.38 Vol:194026. Chi^2: 1.619', SASBDB chi2 1.619; recomputed from the .fit columns
# 2-4: chi2 1.619. Model SASDJC5_fit1_model1.pdb: 10451 ATOM records (heavy atoms), HETATM
# groups EDO x12 atoms, K x6 atoms, ZN x3 atoms (known components, kept by the loader),
# chains ABCDEFGHIJKLMPSZ, no hydrogens, 61 alternate-location atoms (the loader's altloc
# handling applies); SASBDB model = PDB 6R16 (identical) (PDB (Protein Data Bank)).
# Depositor chi2 used as refChi2: SASBDB chi_square_value.
#
# Size: 10562 heavy atoms in the largest model (VERY LARGE: plan the run time).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 8.0, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 0.95   # wavelength 0.95 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 20 mM Tris (pK(22 C) = 8.157) at pH 8.0 with Davies activities at I =
# 0.1631 M: the cationic (protonated) fraction is 0.6549, so Cl- = C x 0.6549 = 13.10 mM
# (sigma 1.50 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.0130974, 0.00149947, "chloride"),
    NonBiological(0.15, 0.003, "potassium chloride"),   # 150 mM KCl, ±2%
]

# ---------------------------------------------------------------------------
#                       Forward-model / sampler wiring
# ---------------------------------------------------------------------------

# q cut at 0.3 Å⁻¹ (see the Source for the numbers).
const Q_MAX_FIT = 0.3

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
    refChi2 = "CRYSOL 1.619",
    pdb = "SASDJC5_fit1_model1.pdb",
    fit = "SASDJC5_fit1.fit",
    fitScale = 1.0,
    fitCol = 4,
    rescale = false,
    software = "CRYSOL",
),
]

"""
    fitSubset() -> (q, I, σ)

`qvals`/`I_exp`/`σ_exp` restricted to `σ_exp > 0` and `q ≤ Q_MAX_FIT` (0.3 Å⁻¹).
(`seedModel` bins the curve and drops the bins with non-positive intensity.)
"""
function fitSubset()
    keep = findall(i -> qvals[i] ≤ Q_MAX_FIT && σ_exp[i] > 0, eachindex(qvals))
    return qvals[keep], iExp[keep], σ_exp[keep]
end

# Builds the Seed that `runSasdjc5` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdjc5` below is the whole story (build the seed, then sample it).
function seedSasdjc5(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdjc5(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdjc5(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdjc5(run)

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

    # `@__DIR__` (this SASDJC5/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
