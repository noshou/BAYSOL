# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDMA9")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDMA9.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDMA9: Diacetylchitobiose deacetylase (Dac-74, A0A160VQZ8, Thermococcus
# chitonophagus, 30.931 kDa x 6). Diacetylchitobiose deacetylase (isolated hexamer from
# SEC-SAXS). Publication: Biniek-Antosiak K, Bejger M, Śliwiak J, Baranowski D, Mohammed
# ASA, Svergun DI, Rypniewski W, "Structural, Thermodynamic and Enzymatic Characterization
# of N,N-Diacetylchitobiose Deacetylase from Pyrococcus chitonophagus.", Int J Mol Sci
# (2022), DOI 10.3390/ijms232415736 (the paper was NOT consulted, except where stated:
# every condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDMA9/.
#
# Instrument (SASBDB): PETRA III EMBL P12 (DESY; Hamburg, Germany), detector Pilatus 6M;
# wavelength 1.24 A (SASBDB wavelength field / experiment description); energy HC/lambda.
# Temperature: 20 C, SASBDB cell temperature. SASBDB experiment description: "Synchrotron
# SAXS data from solutions of diacetylchitobiose deacetylase in 20 mM TRIS, 200 mM NaCl,
# pH 7.4 were collected on the EMBL P12 beam line at PETRA III (DESY, Hamburg, Germany)
# using a Pilatus 6M detector at a sample-detector distance of 3 m and at a wavelength of
# λ = 0.124 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). In-line
# size-exclusion chromatography (SEC) SAS was employed. The ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "20 mM TRIS, 200 mM NaCl", pH 7.4. Counter-ion:
# setting the pH adds a titrant that the recipe does not list. 20 mM Tris (pK(22 C) =
# 8.157) at pH 7.4 with Davies activities at I = 0.2177 M: the cationic (protonated)
# fraction is 0.8848, so Cl- = C x 0.8848 = 17.70 mM (sigma 0.79 mM: sigma_pH = 0.1, +-3
# C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C). The titrant is HCl (not stated; the
# ordinary choice, assumed). The pH is taken as set at room temperature (22 +-3 C).
# Concentrations carry a 2 % sigma unless stated. Every solute below is in the bundled
# tables.
#
# Curve units: The SASBDB .dat is in nm-1 (angular_unit 1/nm, q 0.1491-7.368 nm-1),
# converted to A-1 (divide by 10): q 0.01491-0.7368 A-1, 2605 rows, 0 with sigma <= 0
# (dropped by the fit subset), 86 with a non-positive intensity (`seedModel` drops the
# non-positive bins). No q cut: the README noise-floor rule (median I/sigma below 0.5
# together with about a quarter of the points non-positive) is not met over any useful
# part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header 'hexamer. Dro:0.048 Ra:1.800
# RGT:35.23 Vol:253804. Chi^2: 1.198', SASBDB chi2 1.198; recomputed from the .fit columns
# 2-4: chi2 1.197. Model SASDMA9_fit1_model1.pdb: 13066 ATOM records (heavy atoms), HETATM
# groups EDO x88 atoms, ZN x6 atoms (known components, kept by the loader), chains
# ABCDEFGHI, no hydrogens; SASBDB model = PDB 8BGN (identical) (PyMOL). Depositor chi2
# used as refChi2: SASBDB chi_square_value.
#
# Size: 13322 heavy atoms in the largest model (VERY LARGE: plan the run time).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are in nm⁻¹; must convert to Å⁻¹.
qvals = qvals ./ NM_INV_PER_ANGSTROM_INV
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.24   # wavelength 1.24 Å
const TEMPERATURE_C = 20.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Counter-ion: setting the pH adds a titrant that the recipe
# does not list. 20 mM Tris (pK(22 C) = 8.157) at pH 7.4 with Davies activities at I =
# 0.2177 M: the cationic (protonated) fraction is 0.8848, so Cl- = C x 0.8848 = 17.70 mM
# (sigma 0.79 mM: sigma_pH = 0.1, +-3 C, +-0.02 pK, 30 % of the Davies shift, +-2 % on C).
# The titrant is HCl (not stated; the ordinary choice, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    NonBiological(0.02, 0.0004, "tris"),   # 20 mM Tris, ±2%
    # Cl- counter-ion of the Tris titration (see the note above)
    NonBiological(0.0176958, 0.0007884, "chloride"),
    NonBiological(0.2, 0.004, "sodium chloride"),   # 200 mM NaCl, ±2%
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
    refChi2 = "CRYSOL 1.198",
    pdb = "SASDMA9_fit1_model1.pdb",
    fit = "SASDMA9_fit1.fit",
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

# Builds the Seed that `runSasdma9` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdma9` below is the whole story (build the seed, then sample it).
function seedSasdma9(run)
    qFit, iFit, σ_fit = fitSubset()

    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdma9(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
)
    s, data = seedSasdma9(run)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdma9(run)

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

    # `@__DIR__` (this SASDMA9/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
