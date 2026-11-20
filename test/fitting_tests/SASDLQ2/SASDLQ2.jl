# SPDX-License-Identifier: LGPL-3.0-or-later

using DelimitedFiles
using Statistics
using Random
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological
include(joinpath(@__DIR__, "..", "common.jl"))   # shared constants and helpers

const _FIXTURE_DIR = fixtureDir("SASDLQ2")
const _DATA_PATH   = joinpath(_FIXTURE_DIR, "experimental_data", "SASDLQ2.dat")

# ---------------------------------------------------------------------------
#                                 Source
# ---------------------------------------------------------------------------
#
# SASBDB SASDLQ2: L-lactate dehydrogenase (PfMDH, Q6VVP7, Plasmodium falciparum, 35.319
# kDa x 4). PfMDH L-lactate dehydrogenase, apo. Publication: Reyes Romero A, Lunev S,
# Popowicz G, Calderone V, Gentili M, Sattler M, Plewka J, Taube M, Kozak M, Holak T,
# Dömling A, Groves M, "A fragment-based approach identifies an allosteric pocket that
# impacts malate dehydrogenase activity", Communications Biology (2021), DOI
# 10.1038/s42003-021-02442-1 (the paper was NOT consulted, except where stated: every
# condition below is the SASBDB entry metadata, flagged). Entry:
# https://www.sasbdb.org/data/SASDLQ2/.
#
# Instrument (SASBDB): Department of Macromolecular Physics, Faculty of Physics, Adam
# Mickiewicz University Xenocs Xeuss 2.0 with MetalJet (Poznań, Poland), detector Pilatus3
# R 1M; wavelength 1.34 A (SASBDB wavelength field / experiment description); energy
# HC/lambda. Temperature: the 25 C DEFAULT (SASBDB gives no temperature for this entry;
# flagged). SASBDB experiment description: "SAXS data from solutions of apo PfMDH
# L-lactate dehydrogenase in 100 mM Na-phosphate buffer, 400 mM NaCl, pH 7.4 were measured
# using a Xenocs Xeuss 2.0 instrument equipped with a Pilatus3 R 1M detector (Department
# of Macromolecular Physics, Adam Mickiewicz University, Poznań, Poland) at a wavelength
# of λ = 0.134 nm (I(s) vs s, where s = 4πsinθ/λ, and 2θ is the scattering angle). One
# solute concentration of 2.49 ...".
#
# Buffer (SASBDB, NOT the paper; flagged): "100 mM Na-phosphate buffer, 400 mM NaCl", pH
# 7.4. Phosphate: 100 mM total sodium phosphate at pH 7.4 (pK2(22 C) = 7.205, Davies I =
# 0.6582 M): the HPO4(2-) fraction is 0.7908, so the mix is 79.08 mM of the dibasic and
# 20.92 mM of the monobasic salt (sigma 6.69 mM; the ratio is not stated, so it is the one
# that gives the stated pH, assumed). The pH is taken as set at room temperature (22 +-3
# C). Concentrations carry a 2 % sigma unless stated. Every solute below is in the bundled
# tables.
#
# Curve units: The SASBDB .dat is in A-1 (angular_unit 1/A), q 0.01881-0.2908 A-1, 421
# rows, 0 with sigma <= 0 (dropped by the fit subset), 27 with a non-positive intensity
# (`seedModel` drops the non-positive bins). No q cut: the README noise-floor rule (median
# I/sigma below 0.5 together with about a quarter of the points non-positive) is not met
# over any useful part of the curve.
#
# Model and depositor fit (fit1_model1): CRYSOL fit, header '6r8g.pdb Dro:0.052 Ra:1.400
# RGT:33.03 Vol:185378. Chi^2: 0.867', SASBDB chi2 0.867; recomputed from the .fit columns
# 2-4: chi2 0.865. Model SASDLQ2_fit1_model1.pdb: 9482 ATOM records (heavy atoms), HETATM
# groups JUT x56 atoms, NA x1 atoms, NAD x44 atoms (known components, kept by the loader),
# chains ABCD, no hydrogens; SASBDB model = PDB 6R8G (identical) (PyMOL). Depositor chi2
# used as refChi2: SASBDB chi_square_value.
#
# Size: 9848 heavy atoms in the largest model (VERY LARGE: plan the run time).

# ---------------------------------------------------------------------------

qvals, iExp, σ_exp = _readCurve(_DATA_PATH)

# qvals are already in Å⁻¹.
checkQAngstrom(qvals)

# ---------------------------------------------------------------------------
#                            Solution conditions
# ---------------------------------------------------------------------------

const PH, σ_PH      = 7.4, PH_METER_SIGMA
const ENERGY_EV     = HC_EV_ANGSTROM / 1.34   # wavelength 1.34 Å
const TEMPERATURE_C = 25.0

# Buffer components (the measured macromolecule is deliberately NOT listed: ρₑ is the
# buffer's electron density). Phosphate: 100 mM total sodium phosphate at pH 7.4 (pK2(22
# C) = 7.205, Davies I = 0.6582 M): the HPO4(2-) fraction is 0.7908, so the mix is 79.08
# mM of the dibasic and 20.92 mM of the monobasic salt (sigma 6.69 mM; the ratio is not
# stated, so it is the one that gives the stated pH, assumed). Every solute below is in
# the bundled tables.
const SOLUTES = Solute[
    # HPO4(2-) part (79.08 mM)
    NonBiological(0.0790766, 0.00669289, "disodium hydrogen phosphate"),
    # H2PO4(-) part (20.92 mM)
    NonBiological(0.0209234, 0.00669289, "sodium dihydrogen phosphate"),
    NonBiological(0.4, 0.008, "sodium chloride"),   # 400 mM NaCl, ±2%
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
    refChi2 = "CRYSOL 0.867",
    pdb = "SASDLQ2_fit1_model1.pdb",
    fit = "SASDLQ2_fit1.fit",
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

# Builds the Seed that `runSasdlq2` samples. It is separate only because
# the developer tools in test/utils/ build a fit's Seed without running
# the fit; if you are reading this script as an example you can skip it:
# `runSasdlq2` below is the whole story (build the seed, then sample it).
function seedSasdlq2(run; seed::Integer = SAMPLER_SEED)
    qFit, iFit, σ_fit = fitSubset()

    Random.seed!(seed)
    s = BAYSOL.seedModel(
        LocalPathSource(joinpath(_FIXTURE_DIR, run.pdb)), ENERGY_EV, qFit, iFit,
        σ_fit, PH, σ_PH, SOLUTES;
        addHydrogens = ADD_HYDROGENS, t = TEMPERATURE_C,
    )
    return s, (s.shannon.q, s.shannon.I, s.shannon.σ)   # the binned curve the fit saw
end

function runSasdlq2(
    run;
    nSamples::Int = N_SAMPLES,
    nAdapt::Int = N_ADAPT,
    seed::Integer = SAMPLER_SEED,
)
    s, data = seedSasdlq2(run; seed)
    res = BAYSOL.runModel(s, nSamples, nAdapt)
    return res, s.fw.formFactorLog, s.fw.nAtoms, data
end

for run in RUNS
    # one set of outputs per run; a single-run entry keeps the plain `res*` names
    suffix = length(RUNS) == 1 ? "" : "_" * run.tag

    result, formFactorLog, nAtoms, (qFit, iFit, σ_fit) = runSasdlq2(run)

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

    # `@__DIR__` (this SASDLQ2/ folder), not the caller's cwd.
    BAYSOL.printSummary(result)
end
